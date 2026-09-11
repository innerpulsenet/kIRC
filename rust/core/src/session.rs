//! Connection configuration, the client command / server event vocabulary, and
//! the async session state machine that drives an IRCv3 connection.

use std::collections::HashMap;
use std::error::Error;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use log::{debug, info, warn};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, ReadBuf};
use tokio::net::TcpStream;
use tokio::sync::mpsc::{Receiver, Sender};
use tokio::time::MissedTickBehavior;

use crate::caps::{self, CapLine, CapState};
use crate::parser::{parse_message, IrcMessage};
use crate::sasl::{SaslClient, SaslConfig};

/// How often the engine sends a keepalive `PING`.
pub const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(60);

/// How many consecutive unanswered keepalives trigger a disconnect.
pub const MAX_MISSED_PONGS: u32 = 2;

/// Everything needed to open and register a connection.
#[derive(Debug, Clone)]
pub struct ConnectionConfig {
    /// Server hostname (or IP literal).
    pub host: String,
    /// TCP port.
    pub port: u16,
    /// Whether to wrap the socket in TLS.
    pub tls: bool,
    /// Preferred nickname.
    pub nickname: String,
    /// Ident / username sent in the `USER` command.
    pub username: String,
    /// Real name sent in the `USER` command.
    pub realname: String,
    /// Password for the `PASS` command, if the server requires one.
    pub server_password: Option<String>,
    /// SASL credentials; `None` disables SASL negotiation.
    pub sasl: Option<SaslConfig>,
    /// Extra capabilities to request on top of the defaults.
    pub request_caps: Vec<String>,
}

impl Default for ConnectionConfig {
    fn default() -> Self {
        ConnectionConfig {
            host: String::new(),
            port: 6697,
            tls: true,
            nickname: String::new(),
            username: String::new(),
            realname: String::new(),
            server_password: None,
            sasl: None,
            request_caps: Vec::new(),
        }
    }
}

/// A request from the UI to the engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientCommand {
    /// Send a raw protocol line (newlines are split into separate lines).
    Raw(String),
    /// Send a `PRIVMSG`.
    Privmsg { target: String, text: String },
    /// Join a channel.
    Join(String),
    /// Leave a channel, optionally with a part message.
    Part {
        channel: String,
        reason: Option<String>,
    },
    /// Disconnect cleanly.
    Quit,
    /// Request recent history via `CHATHISTORY LATEST`.
    RequestHistory { target: String, limit: u32 },
}

/// A single message inside a `chathistory` batch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryMsg {
    /// IRCv3 `server-time` timestamp, if present.
    pub timestamp: Option<String>,
    /// Sender nickname.
    pub nick: String,
    /// Message body.
    pub text: String,
}

/// An event emitted by the engine towards the UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IrcEvent {
    /// A connection attempt is in progress.
    StateConnecting,
    /// The server accepted us (`RPL_WELCOME` / 001 seen).
    Registered { server_name: String },
    /// The connection ended.
    Disconnected { reason: String },
    /// A channel or query message.
    Msg {
        target: String,
        nick: String,
        text: String,
        timestamp: Option<String>,
        is_self: bool,
        is_highlight: bool,
    },
    /// A `NOTICE`.
    Notice { nick: String, text: String },
    /// Someone joined a channel.
    Join {
        channel: String,
        nick: String,
        account: Option<String>,
    },
    /// Someone left a channel.
    Part { channel: String, nick: String },
    /// A channel topic was set (or sent on join).
    Topic { channel: String, topic: String },
    /// A resolved `chathistory` batch.
    HistoryBatch { messages: Vec<HistoryMsg> },
    /// Informational text (MOTD, numerics summary).
    Info { text: String },
    /// An error worth surfacing to the user.
    Error { message: String },
}

/// Case-insensitive word-boundary match used for highlight detection.
///
/// A match only counts when the character on either side of the nickname is not
/// itself a valid nickname character, so `bob` matches `bob: hi` but not `bobcat`.
pub fn is_highlight(text: &str, nickname: &str) -> bool {
    let nick = nickname.to_lowercase();
    if nick.is_empty() {
        return false;
    }
    let lowered = text.to_lowercase();
    let haystack: Vec<char> = lowered.chars().collect();
    let needle: Vec<char> = nick.chars().collect();
    if needle.len() > haystack.len() {
        return false;
    }
    for i in 0..=(haystack.len() - needle.len()) {
        if haystack[i..i + needle.len()] == needle[..] {
            let before_ok = i == 0 || !is_nick_char(haystack[i - 1]);
            let after = i + needle.len();
            let after_ok = after == haystack.len() || !is_nick_char(haystack[after]);
            if before_ok && after_ok {
                return true;
            }
        }
    }
    false
}

fn is_nick_char(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '-' | '_' | '[' | ']' | '\\' | '`' | '{' | '}' | '|')
}

/// A socket that may or may not be TLS-wrapped.
enum Transport {
    Plain(TcpStream),
    Tls(Box<tokio_rustls::client::TlsStream<TcpStream>>),
}

impl AsyncRead for Transport {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        match self.get_mut() {
            Transport::Plain(s) => std::pin::Pin::new(s).poll_read(cx, buf),
            Transport::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Transport {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        match self.get_mut() {
            Transport::Plain(s) => std::pin::Pin::new(s).poll_write(cx, buf),
            Transport::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_write(cx, buf),
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        match self.get_mut() {
            Transport::Plain(s) => std::pin::Pin::new(s).poll_flush(cx),
            Transport::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_flush(cx),
        }
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        match self.get_mut() {
            Transport::Plain(s) => std::pin::Pin::new(s).poll_shutdown(cx),
            Transport::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_shutdown(cx),
        }
    }
}

/// Build a rustls client config using the ring provider and native roots,
/// falling back to the bundled `webpki-roots` set.
fn build_tls_config(
) -> Result<Arc<tokio_rustls::rustls::ClientConfig>, Box<dyn Error + Send + Sync>> {
    use tokio_rustls::rustls::crypto::ring;
    use tokio_rustls::rustls::{ClientConfig, RootCertStore};

    let mut roots = RootCertStore::empty();
    let native = rustls_native_certs::load_native_certs();
    let mut added = 0usize;
    for cert in native.certs {
        if roots.add(cert).is_ok() {
            added += 1;
        }
    }
    for err in native.errors {
        debug!("native certificate load error: {err}");
    }
    if added == 0 {
        warn!("no usable native root certificates; falling back to webpki-roots");
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    }

    let provider = Arc::new(ring::default_provider());
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Arc::new(config))
}

async fn connect(config: &ConnectionConfig) -> Result<Transport, Box<dyn Error + Send + Sync>> {
    info!(
        "connecting to {}:{} (tls={}) as {}",
        config.host, config.port, config.tls, config.nickname
    );
    let tcp = TcpStream::connect((config.host.as_str(), config.port)).await?;
    let _ = tcp.set_nodelay(true);

    if !config.tls {
        return Ok(Transport::Plain(tcp));
    }

    use tokio_rustls::rustls::pki_types::ServerName;
    use tokio_rustls::TlsConnector;

    let tls_config = build_tls_config()?;
    let server_name =
        ServerName::try_from(config.host.clone()).map_err(|e| -> Box<dyn Error + Send + Sync> {
            format!("invalid TLS server name {:?}: {e}", config.host).into()
        })?;
    let connector = TlsConnector::from(tls_config);
    let stream = connector.connect(server_name, tcp).await?;
    Ok(Transport::Tls(Box::new(stream)))
}

struct BatchBuffer {
    kind: String,
    #[allow(dead_code)]
    target: String,
    messages: Vec<HistoryMsg>,
}

struct Session {
    config: ConnectionConfig,
    events: Sender<IrcEvent>,
    writer: tokio::io::WriteHalf<Transport>,
    caps: CapState,
    sasl: Option<SaslClient>,
    sasl_configured: bool,
    sasl_active: bool,
    sasl_done: bool,
    cap_end_sent: bool,
    registered: bool,
    batches: HashMap<String, BatchBuffer>,
    ping_counter: u64,
    outstanding_ping: Option<String>,
    missed_pongs: u32,
    should_stop: bool,
    disconnect_reason: String,
}

impl Session {
    async fn send(&mut self, line: &str) -> io::Result<()> {
        debug!(">> {line}");
        self.writer.write_all(line.as_bytes()).await?;
        self.writer.write_all(b"\r\n").await?;
        self.writer.flush().await
    }

    async fn emit(&self, event: IrcEvent) {
        if self.events.send(event).await.is_err() {
            debug!("event receiver dropped; events are being discarded");
        }
    }

    /// Emit an error, send a clean QUIT and stop the session.
    async fn abort(&mut self, reason: &str) -> io::Result<()> {
        let reason = sanitize(reason);
        self.emit(IrcEvent::Error {
            message: reason.clone(),
        })
        .await;
        self.disconnect_reason = reason.clone();
        if self.send(&format!("QUIT :{reason}")).await.is_ok() {
            debug!("sent QUIT during abort");
        }
        self.should_stop = true;
        Ok(())
    }

    async fn handle_line(&mut self, line: &str) -> io::Result<()> {
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            return Ok(());
        }
        debug!("<< {trimmed}");
        let message = match parse_message(trimmed) {
            Ok(m) => m,
            Err(e) => {
                warn!("ignoring unparseable line: {e}");
                return Ok(());
            }
        };

        // Messages tagged with a known batch reference are consumed here.
        if let Some(Some(batch_ref)) = message.tags.get("batch").map(|v| v.as_ref()) {
            let batch_ref = batch_ref.clone();
            if let Some(buffer) = self.batches.get_mut(&batch_ref) {
                if buffer.kind == "chathistory" && message.command == "PRIVMSG" {
                    buffer.messages.push(HistoryMsg {
                        timestamp: message.tags.get("time").cloned().flatten(),
                        nick: source_name(&message),
                        text: message.params.get(1).cloned().unwrap_or_default(),
                    });
                }
                return Ok(());
            }
        }

        if let Ok(numeric) = message.command.parse::<u32>() {
            self.handle_numeric(numeric, &message).await;
            return Ok(());
        }

        match message.command.as_str() {
            "PING" => {
                let payload = if message.params.is_empty() {
                    String::new()
                } else {
                    message.params.join(" ")
                };
                self.send(&format!("PONG :{payload}")).await?;
            }
            "PONG" => {
                self.outstanding_ping = None;
                self.missed_pongs = 0;
            }
            "CAP" => self.handle_cap(&message).await?,
            "AUTHENTICATE" => self.handle_authenticate(&message).await?,
            "BATCH" => self.handle_batch(&message).await,
            "PRIVMSG" => self.handle_privmsg(&message).await,
            "NOTICE" => {
                let nick = source_name(&message);
                let text = message.params.last().cloned().unwrap_or_default();
                self.emit(IrcEvent::Notice { nick, text }).await;
            }
            "JOIN" => {
                let channel = message.params.first().cloned().unwrap_or_default();
                let nick = source_name(&message);
                // extended-join: JOIN <channel> <account> :<realname>
                let account = message.params.get(1).filter(|a| a.as_str() != "*").cloned();
                self.emit(IrcEvent::Join {
                    channel,
                    nick,
                    account,
                })
                .await;
            }
            "PART" => {
                let channel = message.params.first().cloned().unwrap_or_default();
                let nick = source_name(&message);
                self.emit(IrcEvent::Part { channel, nick }).await;
            }
            "TOPIC" => {
                let channel = message.params.first().cloned().unwrap_or_default();
                let topic = message.params.get(1).cloned().unwrap_or_default();
                self.emit(IrcEvent::Topic { channel, topic }).await;
            }
            "ERROR" => {
                let text = message.params.join(" ");
                let text = if text.is_empty() {
                    "server closed the connection".to_string()
                } else {
                    text
                };
                self.disconnect_reason = text.clone();
                self.emit(IrcEvent::Error {
                    message: text.clone(),
                })
                .await;
                self.emit(IrcEvent::Disconnected { reason: text }).await;
                self.should_stop = true;
            }
            other => {
                debug!("unhandled command: {other}");
            }
        }
        Ok(())
    }

    async fn handle_numeric(&mut self, numeric: u32, message: &IrcMessage) {
        match numeric {
            1 => {
                self.registered = true;
                let server_name = message
                    .prefix
                    .as_ref()
                    .and_then(|p| p.host.clone().or_else(|| p.nick.clone()))
                    .or_else(|| message.params.first().cloned())
                    .unwrap_or_default();
                info!("registered with {server_name}");
                self.emit(IrcEvent::Registered { server_name }).await;
            }
            2..=5 => {
                self.emit(IrcEvent::Info {
                    text: numeric_summary(message),
                })
                .await;
            }
            372 | 375 | 376 => {
                self.emit(IrcEvent::Info {
                    text: numeric_summary(message),
                })
                .await;
            }
            400..=499 => {
                self.emit(IrcEvent::Error {
                    message: numeric_summary(message),
                })
                .await;
            }
            900 | 903 => {
                self.sasl_done = true;
                self.sasl_active = false;
                self.maybe_send_cap_end().await;
            }
            904..=907 => {
                self.abort(&format!(
                    "SASL authentication failed: {}",
                    numeric_summary(message)
                ))
                .await
                .ok();
            }
            _ => {
                debug!("unhandled numeric {numeric}");
            }
        }
    }

    async fn handle_cap(&mut self, message: &IrcMessage) -> io::Result<()> {
        let cap: CapLine = match caps::parse_cap(&message.params) {
            Some(c) => c,
            None => {
                warn!("malformed CAP message");
                return Ok(());
            }
        };
        match cap.subcommand.as_str() {
            "LS" => {
                self.caps.add_available(&cap.caps);
                if !cap.multiline {
                    self.caps.ls_complete = true;
                    self.begin_cap_request().await?;
                }
            }
            "ACK" => {
                self.caps.add_acked(&cap.caps);
                if self.sasl_configured
                    && self.caps.has("sasl")
                    && !self.sasl_active
                    && !self.sasl_done
                {
                    self.start_sasl().await?;
                } else {
                    self.maybe_send_cap_end().await;
                }
            }
            "NAK" => {
                let denied_sasl = cap.caps.iter().any(|c| c == "sasl");
                if self.sasl_configured && denied_sasl {
                    self.abort("SASL capability was rejected by the server (CAP NAK)")
                        .await?;
                } else {
                    self.maybe_send_cap_end().await;
                }
            }
            "NEW" => self.caps.add_available(&cap.caps),
            "DEL" => {
                for c in &cap.caps {
                    self.caps.available.remove(c);
                }
            }
            other => debug!("unhandled CAP subcommand: {other}"),
        }
        Ok(())
    }

    /// Decide which capabilities to request once `CAP LS` is complete.
    async fn begin_cap_request(&mut self) -> io::Result<()> {
        let mut wanted: Vec<String> = Vec::new();
        for cap in caps::DEFAULT_CAPS {
            if *cap == "sasl" && !self.sasl_configured {
                continue;
            }
            wanted.push((*cap).to_string());
        }
        for cap in &self.config.request_caps {
            if !wanted.contains(cap) {
                wanted.push(cap.clone());
            }
        }

        if self.sasl_configured && !self.caps.supports("sasl") {
            self.abort("SASL was configured but the server does not advertise the sasl capability")
                .await?;
            return Ok(());
        }

        let requested: Vec<String> = wanted
            .into_iter()
            .filter(|c| self.caps.supports(c))
            .collect();

        if requested.is_empty() {
            self.maybe_send_cap_end().await;
            return Ok(());
        }
        for cap in &requested {
            self.caps.requested.insert(cap.clone());
        }
        self.send(&format!("CAP REQ :{}", requested.join(" ")))
            .await
    }

    async fn maybe_send_cap_end(&mut self) {
        if self.cap_end_sent || self.sasl_active {
            return;
        }
        self.cap_end_sent = true;
        if self.send("CAP END").await.is_err() {
            debug!("failed to send CAP END");
        }
    }

    async fn start_sasl(&mut self) -> io::Result<()> {
        if let Some(config) = self.config.sasl.clone() {
            let client = SaslClient::new(&config);
            let mechanism = client.mechanism_name().to_string();
            self.sasl = Some(client);
            self.sasl_active = true;
            info!("starting SASL {mechanism}");
            self.send(&format!("AUTHENTICATE {mechanism}")).await?;
        }
        Ok(())
    }

    async fn handle_authenticate(&mut self, message: &IrcMessage) -> io::Result<()> {
        let arg = message
            .params
            .first()
            .cloned()
            .unwrap_or_else(|| "+".to_string());

        let result = {
            let client = match self.sasl.as_mut() {
                Some(c) => c,
                None => {
                    warn!("received AUTHENTICATE without an active SASL exchange");
                    return Ok(());
                }
            };
            if arg == "+" {
                Ok(Some(client.initial()))
            } else {
                client.feed(&arg)
            }
        };

        match result {
            Ok(Some(payload)) => self.send_authenticate(&payload).await?,
            Ok(None) => debug!("SASL payload complete; awaiting final numeric"),
            Err(e) => {
                self.abort(&format!("SASL failed: {e}")).await?;
            }
        }
        Ok(())
    }

    /// Send an `AUTHENTICATE` payload, chunking at 400 bytes as required.
    async fn send_authenticate(&mut self, payload: &str) -> io::Result<()> {
        let bytes = payload.as_bytes();
        if bytes.is_empty() {
            return self.send("AUTHENTICATE +").await;
        }
        let mut offset = 0usize;
        while offset < bytes.len() {
            let end = (offset + 400).min(bytes.len());
            let chunk = std::str::from_utf8(&bytes[offset..end]).unwrap_or_default();
            self.send(&format!("AUTHENTICATE {chunk}")).await?;
            offset = end;
        }
        if bytes.len() % 400 == 0 {
            self.send("AUTHENTICATE +").await?;
        }
        Ok(())
    }

    async fn handle_batch(&mut self, message: &IrcMessage) {
        let reference = match message.params.first() {
            Some(r) => r.clone(),
            None => return,
        };
        if let Some(id) = reference.strip_prefix('+') {
            let kind = message.params.get(1).cloned().unwrap_or_default();
            let target = message.params.get(2).cloned().unwrap_or_default();
            self.batches.insert(
                id.to_string(),
                BatchBuffer {
                    kind,
                    target,
                    messages: Vec::new(),
                },
            );
        } else if let Some(id) = reference.strip_prefix('-') {
            if let Some(buffer) = self.batches.remove(id) {
                if buffer.kind == "chathistory" {
                    self.emit(IrcEvent::HistoryBatch {
                        messages: buffer.messages,
                    })
                    .await;
                }
            }
        }
    }

    async fn handle_privmsg(&mut self, message: &IrcMessage) {
        let target = message.params.first().cloned().unwrap_or_default();
        let text = message.params.get(1).cloned().unwrap_or_default();
        let nick = source_name(message);
        let timestamp = message.tags.get("time").cloned().flatten();
        let is_self = !nick.is_empty() && nick.eq_ignore_ascii_case(&self.config.nickname);
        let is_highlight = !is_self && is_highlight(&text, &self.config.nickname);
        self.emit(IrcEvent::Msg {
            target,
            nick,
            text,
            timestamp,
            is_self,
            is_highlight,
        })
        .await;
    }

    async fn handle_command(&mut self, command: ClientCommand) -> io::Result<()> {
        match command {
            ClientCommand::Raw(raw) => {
                for line in raw.split('\n') {
                    let line = line.trim_end_matches(['\r', '\n']);
                    if !line.is_empty() {
                        self.send(line).await?;
                    }
                }
            }
            ClientCommand::Privmsg { target, text } => {
                self.send(&format!("PRIVMSG {target} :{text}")).await?;
            }
            ClientCommand::Join(channel) => {
                self.send(&format!("JOIN {channel}")).await?;
            }
            ClientCommand::Part { channel, reason } => match reason {
                Some(reason) => self.send(&format!("PART {channel} :{reason}")).await?,
                None => self.send(&format!("PART {channel}")).await?,
            },
            ClientCommand::Quit => {
                self.disconnect_reason = "client requested disconnect".to_string();
                self.send("QUIT :Client shutting down").await.ok();
                self.should_stop = true;
            }
            ClientCommand::RequestHistory { target, limit } => {
                self.send(&format!("CHATHISTORY LATEST {target} * {limit}"))
                    .await?;
            }
        }
        Ok(())
    }

    async fn handle_ping_tick(&mut self) -> io::Result<()> {
        if let Some(token) = self.outstanding_ping.take() {
            self.missed_pongs += 1;
            warn!(
                "keepalive PONG missing ({} of {})",
                self.missed_pongs, MAX_MISSED_PONGS
            );
            if self.missed_pongs >= MAX_MISSED_PONGS {
                self.disconnect_reason =
                    "ping timeout: no PONG received for two keepalives".to_string();
                self.send("QUIT :Ping timeout").await.ok();
                self.should_stop = true;
                return Ok(());
            }
            self.outstanding_ping = Some(token);
            return Ok(());
        }
        self.ping_counter += 1;
        let token = format!("kirc{}", self.ping_counter);
        self.send(&format!("PING :{token}")).await?;
        self.outstanding_ping = Some(token);
        Ok(())
    }
}

/// Display name of a message's source: the nick when the prefix is a user,
/// otherwise the server name (so server NOTICEs are attributed, not blank).
fn source_name(message: &IrcMessage) -> String {
    message
        .prefix
        .as_ref()
        .map(|p| p.name().to_string())
        .unwrap_or_default()
}

/// Describe a numeric for the UI: everything after the recipient parameter.
fn numeric_summary(message: &IrcMessage) -> String {
    let body = if message.params.len() > 1 {
        message.params[1..].join(" ")
    } else {
        message.params.first().cloned().unwrap_or_default()
    };
    format!("{} {}", message.command, body)
        .trim_end()
        .to_string()
}

fn sanitize(text: &str) -> String {
    text.replace(['\r', '\n'], " ")
}

/// Drive an IRC session until it ends.
///
/// Events flow engine -> UI on `events`; commands flow UI -> engine on
/// `commands`. The function returns `Ok(())` on a normal disconnect and `Err`
/// when the connection could not be established or dropped unexpectedly.
pub async fn run_session(
    config: ConnectionConfig,
    events: Sender<IrcEvent>,
    mut commands: Receiver<ClientCommand>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    if events.send(IrcEvent::StateConnecting).await.is_err() {
        // The UI is already gone; nothing to do.
        return Ok(());
    }

    let transport = match connect(&config).await {
        Ok(t) => t,
        Err(e) => {
            let reason = e.to_string();
            warn!("connect failed: {reason}");
            let _ = events
                .send(IrcEvent::Error {
                    message: reason.clone(),
                })
                .await;
            let _ = events
                .send(IrcEvent::Disconnected {
                    reason: reason.clone(),
                })
                .await;
            return Err(e);
        }
    };

    let (read_half, write_half) = tokio::io::split(transport);
    let sasl_configured = config.sasl.is_some();

    let mut session = Session {
        config,
        events: events.clone(),
        writer: write_half,
        caps: CapState::default(),
        sasl: None,
        sasl_configured,
        sasl_active: false,
        sasl_done: false,
        cap_end_sent: false,
        registered: false,
        batches: HashMap::new(),
        ping_counter: 0,
        outstanding_ping: None,
        missed_pongs: 0,
        should_stop: false,
        disconnect_reason: "connection closed".to_string(),
    };

    // Registration handshake.
    session.send("CAP LS 302").await?;
    if let Some(pass) = session.config.server_password.clone() {
        session.send(&format!("PASS {pass}")).await?;
    }
    session
        .send(&format!("NICK {}", session.config.nickname))
        .await?;
    session
        .send(&format!(
            "USER {} 0 * :{}",
            session.config.username, session.config.realname
        ))
        .await?;

    let mut reader = BufReader::new(read_half);
    let mut ping = tokio::time::interval(KEEPALIVE_INTERVAL);
    ping.set_missed_tick_behavior(MissedTickBehavior::Delay);
    ping.tick().await; // consume the immediate first tick

    loop {
        tokio::select! {
            line = read_line(&mut reader) => {
                match line {
                    Ok(Some(l)) => {
                        if let Err(e) = session.handle_line(&l).await {
                            warn!("write error: {e}");
                            session.disconnect_reason = format!("write error: {e}");
                            break;
                        }
                        if session.should_stop {
                            break;
                        }
                    }
                    Ok(None) => {
                        session.disconnect_reason = "connection closed by server".to_string();
                        break;
                    }
                    Err(e) => {
                        session.disconnect_reason = format!("read error: {e}");
                        break;
                    }
                }
            }
            command = commands.recv() => {
                match command {
                    Some(cmd) => {
                        if let Err(e) = session.handle_command(cmd).await {
                            warn!("write error: {e}");
                            session.disconnect_reason = format!("write error: {e}");
                            break;
                        }
                        if session.should_stop {
                            break;
                        }
                    }
                    None => {
                        session.disconnect_reason = "client shut down".to_string();
                        session.send("QUIT :Client shutting down").await.ok();
                        break;
                    }
                }
            }
            _ = ping.tick() => {
                if let Err(e) = session.handle_ping_tick().await {
                    warn!("keepalive write error: {e}");
                    session.disconnect_reason = format!("write error: {e}");
                    break;
                }
                if session.should_stop {
                    break;
                }
            }
        }
    }

    let reason = session.disconnect_reason.clone();
    session.emit(IrcEvent::Disconnected { reason }).await;
    Ok(())
}

/// Read one CRLF-terminated line, sans terminator. `Ok(None)` means EOF.
async fn read_line<R>(reader: &mut BufReader<R>) -> io::Result<Option<String>>
where
    R: AsyncRead + Unpin,
{
    let mut buf = Vec::with_capacity(512);
    let read = reader.read_until(b'\n', &mut buf).await?;
    if read == 0 {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&buf).into_owned();
    Ok(Some(text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse_message;

    #[test]
    fn highlight_word_boundaries() {
        assert!(is_highlight("bob: hello", "bob"));
        assert!(is_highlight("hello bob", "bob"));
        assert!(is_highlight("hey BOB!", "bob"));
        assert!(is_highlight("bob", "Bob"));
        assert!(!is_highlight("bobcat", "bob"));
        assert!(!is_highlight("bobbing", "bob"));
        assert!(!is_highlight("nobody here", "bob"));
        assert!(!is_highlight("", "bob"));
        assert!(!is_highlight("anything", ""));
        assert!(is_highlight("(bob) hi", "bob"));
        assert!(is_highlight("hi, bob.", "bob"));
    }

    #[test]
    fn numeric_summary_strips_recipient() {
        let m = parse_message(":s 372 me :- MOTD line").unwrap();
        assert_eq!(numeric_summary(&m), "372 - MOTD line");
        // A MOTD line whose body itself starts with a space keeps it.
        let spaced = parse_message(":s 372 me : - indented").unwrap();
        assert_eq!(numeric_summary(&spaced), "372  - indented");
    }

    #[test]
    fn transport_is_object_safe_enough_to_split() {
        fn assert_async<T: AsyncRead + AsyncWrite + Unpin>() {}
        assert_async::<Transport>();
    }

    /// The TLS path must produce a usable client config: the ring provider is
    /// selected explicitly and roots come from the native store (or webpki).
    #[test]
    fn tls_config_builds_with_ring_provider() {
        let cfg = build_tls_config().expect("TLS client config should build");
        // A ClientConfig with no ALPN and no client auth is what we expect.
        assert!(cfg.alpn_protocols.is_empty());
        let _ = format!("{cfg:?}").len();
    }

    /// A TLS connection to a plaintext listener must fail cleanly (no panic),
    /// proving the rustls handshake path is wired up.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn tls_connect_to_plaintext_listener_fails_cleanly() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        // Accept and immediately close, so the TLS handshake cannot complete.
        tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                drop(stream);
            }
        });
        let config = ConnectionConfig {
            host: "127.0.0.1".to_string(),
            port,
            tls: true,
            nickname: "n".to_string(),
            username: "u".to_string(),
            realname: "r".to_string(),
            server_password: None,
            sasl: None,
            request_caps: vec![],
        };
        let (etx, mut erx) = tokio::sync::mpsc::channel::<IrcEvent>(8);
        let (_ctx, crx) = tokio::sync::mpsc::channel::<ClientCommand>(8);
        let result = run_session(config, etx, crx).await;
        assert!(result.is_err(), "TLS to a plaintext port must fail");
        // The UI still gets an Error + Disconnected pair.
        let mut saw_error = false;
        let mut saw_disconnect = false;
        while let Ok(ev) = erx.try_recv() {
            match ev {
                IrcEvent::Error { .. } => saw_error = true,
                IrcEvent::Disconnected { .. } => saw_disconnect = true,
                _ => {}
            }
        }
        assert!(saw_error && saw_disconnect);
    }
}
