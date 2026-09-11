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
        is_self: bool,
    },
    /// Someone left a channel.
    Part { channel: String, nick: String },
    /// A channel topic was set (or sent on join).
    Topic { channel: String, topic: String },
    /// End of `/NAMES` for a channel (full snapshot, prefixes kept).
    Names { channel: String, nicks: Vec<String> },
    /// A `JOIN` was rejected (invite-only, keyed, full, banned, …).
    JoinFailed { channel: String, reason: String },
    /// Someone quit the network.
    Quit { nick: String, reason: String },
    /// Someone was kicked from a channel.
    Kick {
        channel: String,
        nick: String,
        kicker: String,
        reason: String,
        is_self: bool,
    },
    /// A MODE change (channel or user).
    Mode { target: String, modes: String },
    /// Someone changed nick (including self).
    NickRename {
        old: String,
        new: String,
        is_self: bool,
    },
    /// Our nick changed (433 fallback, or the nick the server accepted in 001).
    NickChanged { nick: String },
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
    /// Accumulated RPL_NAMREPLY (353) nicks, flushed on RPL_ENDOFNAMES (366).
    names_acc: HashMap<String, Vec<String>>,
    ping_counter: u64,
    outstanding_ping: Option<String>,
    missed_pongs: u32,
    should_stop: bool,
    disconnect_reason: String,
    /// How many 433/432 fallbacks we have already tried this session.
    nick_attempts: u8,
    /// True after CAP ACK of echo-message — the server will replay our PRIVMSG.
    echo_message: bool,
    /// Set when ERROR already emitted Disconnected, so run_session skips its own.
    error_disconnect_emitted: bool,
}

impl Session {
    async fn send(&mut self, line: &str) -> io::Result<()> {
        debug!(">> {}", redact_log_line(line));
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
            "NOTICE" => self.handle_notice(&message).await,
            "JOIN" => {
                let channel = message.params.first().cloned().unwrap_or_default();
                let nick = source_name(&message);
                // extended-join: JOIN <channel> <account> :<realname>
                let account = message.params.get(1).filter(|a| a.as_str() != "*").cloned();
                let is_self = nick.eq_ignore_ascii_case(&self.config.nickname);
                self.emit(IrcEvent::Join {
                    channel,
                    nick,
                    account,
                    is_self,
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
            "QUIT" => {
                let nick = source_name(&message);
                let reason = message.params.first().cloned().unwrap_or_default();
                self.emit(IrcEvent::Quit { nick, reason }).await;
            }
            "KICK" => {
                let channel = message.params.first().cloned().unwrap_or_default();
                let nick = message.params.get(1).cloned().unwrap_or_default();
                if channel.is_empty() || nick.is_empty() {
                    debug!("ignoring malformed KICK");
                    return Ok(());
                }
                let reason = message.params.get(2).cloned().unwrap_or_default();
                let kicker = source_name(&message);
                let is_self = nick.eq_ignore_ascii_case(&self.config.nickname);
                self.emit(IrcEvent::Kick {
                    channel,
                    nick,
                    kicker,
                    reason,
                    is_self,
                })
                .await;
            }
            "MODE" => {
                let target = message.params.first().cloned().unwrap_or_default();
                if target.is_empty() {
                    return Ok(());
                }
                let modes = message.params.get(1..).unwrap_or_default().join(" ");
                self.emit(IrcEvent::Mode { target, modes }).await;
            }
            "NICK" => {
                let old = source_name(&message);
                let new_nick = message.params.first().cloned().unwrap_or_default();
                if new_nick.is_empty() {
                    return Ok(());
                }
                let ours = self.config.nickname.clone();
                if old.eq_ignore_ascii_case(&ours) {
                    self.config.nickname = new_nick.clone();
                }
                for event in nick_rename_events(&old, &new_nick, &ours) {
                    self.emit(event).await;
                }
            }
            "INVITE" => {
                let from = source_name(&message);
                // RFC 2812 params are <invitee> <channel>. Auto-join only
                // invites addressed to us; invites for other nicks are
                // ignored (Info still emitted for ours).
                if let Some((_, channel, true)) =
                    parse_invite(&message.params, &self.config.nickname)
                {
                    self.emit(IrcEvent::Info {
                        text: format!("Invited to {channel} by {from}"),
                    })
                    .await;
                    let _ = self.send(&format!("JOIN {channel}")).await;
                }
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
                self.error_disconnect_emitted = true;
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
                if let Some(nick) = message.params.first().cloned() {
                    if !nick.is_empty() {
                        self.config.nickname = nick.clone();
                        self.emit(IrcEvent::NickChanged { nick }).await;
                    }
                }
                let server_name = message
                    .prefix
                    .as_ref()
                    .and_then(|p| p.host.clone().or_else(|| p.nick.clone()))
                    .unwrap_or_else(|| self.config.host.clone());
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
            332 => {
                // RPL_TOPIC: <client> <channel> :<topic>
                let channel = channel_from_numeric(message);
                let topic = message.params.last().cloned().unwrap_or_default();
                if !channel.is_empty() {
                    self.emit(IrcEvent::Topic { channel, topic }).await;
                }
            }
            333 => {
                // RPL_TOPICWHOTIME: <client> <channel> <setter> <unixtime>
                let channel = message.params.get(1).cloned().unwrap_or_default();
                let setter = message.params.get(2).cloned().unwrap_or_default();
                if !channel.is_empty() && !setter.is_empty() {
                    self.emit(IrcEvent::Info {
                        text: format!("topic in {channel} set by {setter}"),
                    })
                    .await;
                }
            }
            353 => {
                // RPL_NAMREPLY: <client> <symbol> <channel> :<names>
                let channel = channel_from_numeric(message);
                let names = message.params.last().cloned().unwrap_or_default();
                if !channel.is_empty() {
                    let entry = self
                        .names_acc
                        .entry(channel.to_ascii_lowercase())
                        .or_default();
                    for nick in names.split_whitespace() {
                        if !nick.is_empty() {
                            entry.push(nick.to_string());
                        }
                    }
                }
            }
            366 => {
                // RPL_ENDOFNAMES: <client> <channel> :End of /NAMES
                let channel = channel_from_numeric(message);
                let nicks = self
                    .names_acc
                    .remove(&channel.to_ascii_lowercase())
                    .unwrap_or_default();
                self.emit(IrcEvent::Names { channel, nicks }).await;
            }
            301 | 307 | 311 | 312 | 313 | 317 | 318 | 319 | 330 | 335 | 338 | 378 | 379 | 671 => {
                // WHOIS family — file under the queried nick so NickServ/whois
                // replies show in that query window, not as a toast.
                let nick = message.params.get(1).cloned().unwrap_or_default();
                if !nick.is_empty() {
                    self.emit(IrcEvent::Msg {
                        target: nick,
                        nick: "*".to_string(),
                        text: numeric_summary(message),
                        timestamp: None,
                        is_self: false,
                        is_highlight: false,
                    })
                    .await;
                }
            }
            401 => {
                let nick = message.params.get(1).cloned().unwrap_or_default();
                let text = numeric_summary(message);
                if !nick.is_empty() {
                    self.emit(IrcEvent::Msg {
                        target: nick.clone(),
                        nick: "*".to_string(),
                        text: text.clone(),
                        timestamp: None,
                        is_self: false,
                        is_highlight: false,
                    })
                    .await;
                }
                self.emit(IrcEvent::Error { message: text }).await;
            }
            432 | 433 | 436 => {
                self.handle_nick_unavailable(message).await;
            }
            437 if !self.registered => {
                // ERR_UNAVAILRESOURCE is also used for nicks during split/reg.
                self.handle_nick_unavailable(message).await;
            }
            437 => {
                // After registration 437 targets either a channel (join
                // throttled) or a nick (momentarily unavailable). Never
                // report a nick as a failed channel join.
                let target = message.params.get(1).cloned().unwrap_or_default();
                let reason = numeric_summary(message);
                if is_channel(&target) {
                    self.emit(IrcEvent::JoinFailed {
                        channel: target,
                        reason,
                    })
                    .await;
                } else {
                    self.emit(IrcEvent::Error { message: reason }).await;
                }
            }
            403 | 405 | 471 | 473 | 474 | 475 | 476 | 477 | 479 => {
                let channel = channel_from_numeric(message);
                let reason = numeric_summary(message);
                self.emit(IrcEvent::JoinFailed { channel, reason }).await;
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

    /// 432/433/436 during registration: try an alternate nick a few times,
    /// then abort so the UI cannot sit in Connecting forever.
    async fn handle_nick_unavailable(&mut self, message: &IrcMessage) {
        let summary = numeric_summary(message);
        if self.registered {
            self.emit(IrcEvent::Error { message: summary }).await;
            return;
        }
        self.nick_attempts = self.nick_attempts.saturating_add(1);
        const MAX_ATTEMPTS: u8 = 4;
        if self.nick_attempts >= MAX_ATTEMPTS {
            let _ = self
                .abort(&format!("nickname is already in use ({summary})"))
                .await;
            return;
        }
        let taken = message
            .params
            .get(1)
            .cloned()
            .unwrap_or_else(|| self.config.nickname.clone());
        let next = alternate_nick(&taken, self.nick_attempts);
        self.config.nickname = next.clone();
        self.emit(IrcEvent::Info {
            text: format!("{taken} is in use, trying {next}"),
        })
        .await;
        self.emit(IrcEvent::NickChanged { nick: next.clone() })
            .await;
        let _ = self.send(&format!("NICK {next}")).await;
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
                if self.caps.has("echo-message") {
                    self.echo_message = true;
                }
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
        let raw_target = message.params.first().cloned().unwrap_or_default();
        let text = message.params.get(1).cloned().unwrap_or_default();
        let nick = source_name(message);
        let timestamp = message.tags.get("time").cloned().flatten();
        let is_self = !nick.is_empty() && nick.eq_ignore_ascii_case(&self.config.nickname);
        let is_highlight = !is_self && is_highlight(&text, &self.config.nickname);
        let target = conversation_target(&self.config.nickname, &nick, &raw_target, is_self);
        let text = display_privmsg(&text);
        if text.trim().is_empty() {
            return;
        }
        // Swallow only our own NickServ IDENTIFY echo (seen via
        // echo-message); channel traffic starting with "identify" displays.
        if is_self && is_identify_echo(&raw_target, &text) {
            return;
        }
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

    /// User/service NOTICE (NickServ, ChanServ, queries) lands in that
    /// conversation. Server-wide NOTICE stays on the console.
    async fn handle_notice(&mut self, message: &IrcMessage) {
        let raw_target = message.params.first().cloned().unwrap_or_default();
        let text = message
            .params
            .get(1)
            .cloned()
            .unwrap_or_else(|| message.params.last().cloned().unwrap_or_default());
        let nick = source_name(message);
        let userish = message.prefix.as_ref().is_some_and(|p| {
            p.ident.is_some()
                || p.nick
                    .as_ref()
                    .is_some_and(|n| !n.contains('.'))
        });
        if !userish {
            self.emit(IrcEvent::Notice { nick, text }).await;
            return;
        }
        let is_self = !nick.is_empty() && nick.eq_ignore_ascii_case(&self.config.nickname);
        let target = conversation_target(&self.config.nickname, &nick, &raw_target, is_self);
        let text = display_privmsg(&text);
        if text.trim().is_empty() {
            return;
        }
        self.emit(IrcEvent::Msg {
            target,
            nick,
            text,
            timestamp: message.tags.get("time").cloned().flatten(),
            is_self,
            is_highlight: false,
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
                // One PRIVMSG per line: a raw newline must never go out in a
                // single send(). Local echo mirrors the same split.
                let lines = split_privmsg_lines(&text);
                for line in &lines {
                    self.send(&format!("PRIVMSG {target} :{line}")).await?;
                }
                if !self.echo_message {
                    for line in &lines {
                        self.emit(IrcEvent::Msg {
                            target: target.clone(),
                            nick: self.config.nickname.clone(),
                            text: display_privmsg(line),
                            timestamp: None,
                            is_self: true,
                            is_highlight: false,
                        })
                        .await;
                    }
                }
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

/// True when `target` is a channel name (`#`, `&`, `+`, `!` prefixes).
pub fn is_channel(target: &str) -> bool {
    matches!(target.as_bytes().first(), Some(b'#' | b'&' | b'+' | b'!'))
}

/// Split outbound PRIVMSG text into wire-safe lines: split on CR/LF and
/// drop empty lines so no raw newline ever goes out in a single send().
fn split_privmsg_lines(text: &str) -> Vec<&str> {
    text.split(|c| c == '\n' || c == '\r')
        .filter(|line| !line.is_empty())
        .collect()
}

/// Split an incoming INVITE into `(invitee, channel, is_for_us)`.
///
/// RFC 2812 parameters are `<invitee> <channel>`. A lone channel parameter
/// implies the invite is for us. Returns `None` when no usable channel is
/// present.
fn parse_invite(params: &[String], ours: &str) -> Option<(String, String, bool)> {
    let (invitee, channel) = match params {
        [invitee, channel, ..] => (invitee.clone(), channel.clone()),
        [only] if is_channel(only) => (ours.to_string(), only.clone()),
        _ => return None,
    };
    if channel.is_empty() {
        return None;
    }
    let is_for_us = invitee.eq_ignore_ascii_case(ours);
    Some((invitee, channel, is_for_us))
}

/// Events for an incoming NICK rename. A rename is never a Quit — not even
/// for other users — and our own rename additionally reports NickChanged.
fn nick_rename_events(old: &str, new: &str, ours: &str) -> Vec<IrcEvent> {
    let is_self = old.eq_ignore_ascii_case(ours);
    let mut events = Vec::with_capacity(2);
    if is_self {
        events.push(IrcEvent::NickChanged {
            nick: new.to_string(),
        });
    }
    events.push(IrcEvent::NickRename {
        old: old.to_string(),
        new: new.to_string(),
        is_self,
    });
    events
}

/// True when an echoed self-PRIVMSG is really our NickServ IDENTIFY (which
/// must be swallowed). Only the NickServ target counts: channel traffic
/// starting with "identify" must still display.
fn is_identify_echo(target: &str, text: &str) -> bool {
    target.eq_ignore_ascii_case("NickServ")
        && text
            .split_whitespace()
            .next()
            .is_some_and(|w| w.eq_ignore_ascii_case("IDENTIFY"))
}

/// Redact secrets from an outbound line before it reaches the debug log.
/// SASL base64, IDENTIFY passwords and PASS values must never be logged.
fn redact_log_line(line: &str) -> String {
    let mut parts = line.splitn(3, ' ');
    let head = parts.next().unwrap_or_default();
    if head.eq_ignore_ascii_case("AUTHENTICATE") {
        return "AUTHENTICATE *".to_string();
    }
    if head.eq_ignore_ascii_case("PASS") || head.eq_ignore_ascii_case("IDENTIFY") {
        return format!("{head} *");
    }
    // NickServ IDENTIFY over PRIVMSG/NOTICE: redact only the NickServ
    // target so channel chat starting with "identify" still logs.
    if head.eq_ignore_ascii_case("PRIVMSG") || head.eq_ignore_ascii_case("NOTICE") {
        let mut rest = parts;
        let target = rest.next().unwrap_or_default();
        let trailing = rest.next().unwrap_or_default();
        if target.eq_ignore_ascii_case("NickServ") {
            if let Some(first) = trailing.strip_prefix(':').unwrap_or(trailing).split_whitespace().next() {
                if first.eq_ignore_ascii_case("IDENTIFY") || first.eq_ignore_ascii_case("PASS") {
                    return format!("{head} {target} :{first} *");
                }
            }
        }
    }
    line.to_string()
}

/// Buffer key for a PRIVMSG: channels stay as-is; incoming queries are filed
/// under the sender's nick rather than our own.
fn conversation_target(our_nick: &str, sender: &str, raw_target: &str, is_self: bool) -> String {
    if is_channel(raw_target) {
        return raw_target.to_string();
    }
    if is_self || sender.is_empty() {
        raw_target.to_string()
    } else if raw_target.eq_ignore_ascii_case(our_nick) {
        sender.to_string()
    } else {
        raw_target.to_string()
    }
}

/// Render CTCP ACTION as `/me` text. Strip mIRC formatting so control
/// bytes never show up as tofu in the UI.
fn display_privmsg(text: &str) -> String {
    let bytes = text.as_bytes();
    let body = if bytes.first() == Some(&0x01) && bytes.last() == Some(&0x01) && text.len() > 9 {
        let inner = &text[1..text.len() - 1];
        if let Some(action) = inner.strip_prefix("ACTION ") {
            format!("* {action}")
        } else {
            text.to_string()
        }
    } else {
        text.to_string()
    };
    strip_irc_formatting(&body)
}

/// Remove mIRC/IRC formatting codes (bold, italic, underline, colours, reset).
pub fn strip_irc_formatting(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '\u{02}' | '\u{0f}' | '\u{16}' | '\u{1d}' | '\u{1e}' | '\u{1f}' | '\u{11}' => {
                i += 1;
            }
            '\u{03}' => {
                i += 1;
                i += take_color_digits(&chars, i);
                if i < chars.len() && chars[i] == ',' {
                    i += 1;
                    i += take_color_digits(&chars, i);
                }
            }
            '\u{04}' => {
                i += 1;
                let mut hex = 0;
                while i < chars.len() && hex < 6 && chars[i].is_ascii_hexdigit() {
                    i += 1;
                    hex += 1;
                }
            }
            c if c.is_control() && c != '\n' && c != '\t' => {
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

fn take_color_digits(chars: &[char], start: usize) -> usize {
    let mut n = 0;
    while start + n < chars.len() && n < 2 && chars[start + n].is_ascii_digit() {
        n += 1;
    }
    n
}

/// First channel-like parameter after the client nick, else params[1].
fn channel_from_numeric(message: &IrcMessage) -> String {
    message
        .params
        .iter()
        .skip(1)
        .find(|p| is_channel(p))
        .cloned()
        .or_else(|| message.params.get(1).cloned())
        .unwrap_or_default()
}

/// Fallback nick when `base` is taken. Attempt 1 → `base_`, 2 → `base__`,
/// then numeric suffixes. Capped at 16 chars (common NICKLEN).
fn alternate_nick(base: &str, attempt: u8) -> String {
    let suffix = match attempt {
        1 => "_".to_string(),
        2 => "__".to_string(),
        n => n.to_string(),
    };
    let budget = 16usize.saturating_sub(suffix.len()).max(1);
    let stem: String = base.chars().take(budget).collect();
    format!("{stem}{suffix}")
}

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
        names_acc: HashMap::new(),
        ping_counter: 0,
        outstanding_ping: None,
        missed_pongs: 0,
        should_stop: false,
        disconnect_reason: "connection closed".to_string(),
        nick_attempts: 0,
        echo_message: false,
        error_disconnect_emitted: false,
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
    // ERROR already emitted Disconnected; don't send it twice.
    if !session.error_disconnect_emitted {
        session.emit(IrcEvent::Disconnected { reason }).await;
    }
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
    fn strip_bold_and_color_around_register() {
        assert_eq!(strip_irc_formatting("  \u{2}REGISTER\u{2}  ").trim(), "REGISTER");
        assert_eq!(strip_irc_formatting("\u{3}04REGISTER\u{3}"), "REGISTER");
        assert_eq!(strip_irc_formatting("\u{3}04,08REGISTER\u{3}"), "REGISTER");
        assert_eq!(strip_irc_formatting("\u{4}ff0000REGISTER"), "REGISTER");
        assert_eq!(display_privmsg("  \u{2}REGISTER\u{2}  ").trim(), "REGISTER");
    }

    #[test]
    fn strip_nested_codes_and_reset() {
        assert_eq!(
            strip_irc_formatting("\u{2}bold \u{1f}underline\u{1f}\u{2} \u{3}04red\u{3} \u{f}plain"),
            "bold underline red plain"
        );
        assert_eq!(
            strip_irc_formatting("\u{1d}italic\u{1d} \u{16}reverse\u{16} \u{11}mono\u{11}"),
            "italic reverse mono"
        );
        // CTCP ACTION body is also stripped of formatting.
        assert_eq!(
            display_privmsg("\u{1}ACTION \u{2}waves\u{2}\u{1}"),
            "* waves"
        );
    }

    #[test]
    fn strip_format_only_is_empty() {
        let only_codes = "\u{2}\u{3}\u{f}\u{16}\u{1d}\u{1f}\u{11}\u{1e}\u{3}04,08\u{4}ff0000";
        assert_eq!(strip_irc_formatting(only_codes), "");
        assert!(strip_irc_formatting(only_codes).trim().is_empty());
        assert!(strip_irc_formatting("  \u{2}\u{f}  ").trim().is_empty());
        // Leftover C0 controls (except \n) are dropped too.
        assert!(strip_irc_formatting("\u{0}\u{1}\u{7}").is_empty());
        assert_eq!(strip_irc_formatting("a\nb"), "a\nb");
    }

    #[test]
    fn strip_leaves_normal_utf8_text() {
        assert_eq!(strip_irc_formatting("héllo wörld ✓ — test"), "héllo wörld ✓ — test");
        assert_eq!(strip_irc_formatting("plain message"), "plain message");
        assert_eq!(strip_irc_formatting("emoji 🎉 test"), "emoji 🎉 test");
        assert_eq!(display_privmsg("héllo ✓"), "héllo ✓");
    }

    #[test]
    fn query_buffer_keys_are_case_insensitive() {
        // conversation_target routes to the sender regardless of our-nick case.
        assert_eq!(conversation_target("MyNick", "alice", "mynick", false), "alice");
        assert_eq!(conversation_target("MyNick", "alice", "MYnick", false), "alice");
        assert_eq!(conversation_target("MyNick", "alice", "MYNICK", false), "alice");
        // Service/query names compare case-insensitively.
        assert!("nickserv".eq_ignore_ascii_case("NickServ"));
        assert!("NickServ".eq_ignore_ascii_case("NICKSERV"));
        // Channels still key on the raw target.
        assert_eq!(conversation_target("me", "alice", "#C", false), "#C");
    }

    #[test]
    fn channel_detection_and_query_target() {
        assert!(is_channel("#kirc"));
        assert!(is_channel("&local"));
        assert!(!is_channel("alice"));
        assert!(!is_channel(""));
        assert_eq!(conversation_target("me", "alice", "#c", false), "#c");
        assert_eq!(conversation_target("me", "alice", "me", false), "alice");
        assert_eq!(conversation_target("me", "me", "alice", true), "alice");
        assert_eq!(display_privmsg("hello"), "hello");
        let m = parse_message(":s 473 me #pain :Cannot join channel (+i)").unwrap();
        assert_eq!(channel_from_numeric(&m), "#pain");
        let names = parse_message(":s 353 me = #kirc :@op +voice nick").unwrap();
        assert_eq!(channel_from_numeric(&names), "#kirc");
    }

    #[test]
    fn alternate_nick_stays_short_and_distinct() {
        assert_eq!(alternate_nick("bob", 1), "bob_");
        assert_eq!(alternate_nick("bob", 2), "bob__");
        assert_eq!(alternate_nick("bob", 3), "bob3");
        let long = "abcdefghijklmnop";
        assert!(alternate_nick(long, 1).len() <= 16);
        assert_ne!(alternate_nick(long, 1), long);
    }

    #[test]
    fn privmsg_split_skips_empty_lines() {
        assert_eq!(split_privmsg_lines("one\ntwo"), vec!["one", "two"]);
        assert_eq!(
            split_privmsg_lines("one\r\ntwo\n\nthree\r\n"),
            vec!["one", "two", "three"]
        );
        assert!(split_privmsg_lines("\n\r\n").is_empty());
        assert_eq!(split_privmsg_lines("single"), vec!["single"]);
        for line in split_privmsg_lines("a\nb\r\nc") {
            assert!(!line.contains('\n') && !line.contains('\r'));
        }
    }

    #[test]
    fn invite_parses_rfc_params() {
        // RFC order: <invitee> <channel>. Only our own invites join.
        let p = |a: &str, b: &str| vec![a.to_string(), b.to_string()];
        assert!(parse_invite(&p("KircUser", "#c"), "kircuser")
            .is_some_and(|(_, ch, ours)| ch == "#c" && ours));
        assert!(parse_invite(&p("someone", "#c"), "kircuser")
            .is_some_and(|(_, _, ours)| !ours));
        assert!(parse_invite(&p("someone", ""), "kircuser").is_none());
        assert!(parse_invite(&["#c".to_string()], "kircuser")
            .is_some_and(|(_, ch, ours)| ch == "#c" && ours));
        assert!(parse_invite(&[], "kircuser").is_none());
    }

    #[test]
    fn nick_rename_is_never_quit() {
        let self_events = nick_rename_events("me", "me_", "Me");
        assert!(matches!(
            self_events[0],
            IrcEvent::NickChanged { ref nick } if nick == "me_"
        ));
        assert!(matches!(
            self_events[1],
            IrcEvent::NickRename { is_self: true, .. }
        ));
        let other = nick_rename_events("alice", "alice2", "me");
        assert_eq!(other.len(), 1);
        assert!(matches!(
            other[0],
            IrcEvent::NickRename { is_self: false, .. }
        ));
        assert!(!other.iter().any(|e| matches!(e, IrcEvent::Quit { .. })));
    }

    #[test]
    fn identify_swallow_requires_nickserv_target() {
        assert!(is_identify_echo("NickServ", "IDENTIFY hunter2"));
        assert!(is_identify_echo("nickserv", "identify hunter2"));
        // Channel traffic or other targets starting with identify display.
        assert!(!is_identify_echo("#c", "identify this song"));
        assert!(!is_identify_echo("alice", "IDENTIFY me"));
        assert!(!is_identify_echo("NickServ", "hello there"));
    }

    #[test]
    fn secret_lines_are_redacted() {
        assert_eq!(redact_log_line("AUTHENTICATE c2VjcmV0"), "AUTHENTICATE *");
        assert_eq!(redact_log_line("authenticate +"), "AUTHENTICATE *");
        assert_eq!(redact_log_line("PASS hunter2"), "PASS *");
        assert_eq!(redact_log_line("PASS :hunter2"), "PASS *");
        assert_eq!(
            redact_log_line("NOTICE NickServ :identify hunter2"),
            "NOTICE NickServ :identify *"
        );
        assert_eq!(
            redact_log_line("PRIVMSG NickServ :IDENTIFY hunter2"),
            "PRIVMSG NickServ :IDENTIFY *"
        );
        assert_eq!(
            redact_log_line("PRIVMSG #c :identify this song"),
            "PRIVMSG #c :identify this song"
        );
        assert_eq!(
            redact_log_line("PRIVMSG #c :hello"),
            "PRIVMSG #c :hello"
        );
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
