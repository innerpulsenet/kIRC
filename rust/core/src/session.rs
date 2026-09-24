//! Connection configuration, the client command / server event vocabulary, and
//! the async session state machine that drives an IRCv3 connection.

use std::collections::{BTreeSet, HashMap};
use std::error::Error;
use std::io;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use log::{debug, info, warn};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, ReadBuf};
use tokio::net::TcpStream;
use tokio::sync::mpsc::{Receiver, Sender};
use tokio::time::MissedTickBehavior;

use crate::caps::{self, CapLine, CapState};
use crate::parser::{parse_message, IrcMessage, MAX_LINE_LEN};
use crate::sasl::{SaslClient, SaslConfig, SaslMechanism};

/// How often the engine sends a keepalive `PING`.
pub const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(60);

/// How many consecutive unanswered keepalives trigger a disconnect.
pub const MAX_MISSED_PONGS: u32 = 2;

/// How long a TCP connect may take before the attempt is abandoned.
///
/// `TcpStream::connect` has no deadline of its own: against a blackholed route
/// (firewall dropping SYNs) it waits out the kernel's whole SYN-retry budget,
/// which reads to the user as a hung client stuck in Connecting.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

/// How long the TLS handshake may take, once TCP is up.
///
/// A listener that accepts the connection but never speaks TLS (stalled proxy,
/// plaintext port, half-open middlebox) makes the rustls handshake wait
/// forever: the session loop has not started yet, so neither the keepalive nor
/// the registration deadline can rescue the attempt.
pub const TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

/// How long a single outbound line may take to reach the socket.
///
/// The read side cannot wedge the session loop (`tokio::select!` keeps polling
/// the keepalive and registration timers while a read is stalled), but a write
/// can: `write_all` parks until the kernel accepts the bytes, so a peer that
/// stops reading while its receive window fills would freeze the whole loop —
/// no PING, no deadline, no commands — for the kernel's retransmission budget.
pub const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

/// Maximum IRC command payload excluding the terminating CRLF.
pub const MAX_OUTBOUND_LINE_LEN: usize = 510;

/// Defensive limits for server-controlled batch state.
const MAX_OPEN_BATCHES: usize = 32;
const MAX_HISTORY_BATCH_MESSAGES: usize = 5_000;
const MAX_NAMES_PER_CHANNEL: usize = 50_000;

/// How long the registration handshake (CAP LS/REQ/END, SASL, 001) may take.
///
/// This is what stops a missed `CAP END` from being a *silent* connect hang: a
/// server that keeps answering keepalives but never completes registration
/// (dropped CAP ACK, AUTHENTICATE never answered, no 001) leaves the PING/PONG
/// watchdog quiet, so only a deadline can end the attempt with a reason.
pub const REGISTRATION_TIMEOUT: Duration = Duration::from_secs(45);

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
    /// SASL mechanism preference, same mapping as
    /// `IrcBridge::set_sasl_mechanism`: 0 = auto (SCRAM-SHA-256 when the
    /// server advertises it, else PLAIN), 1 = PLAIN, 2 = EXTERNAL.
    /// Out-of-range values behave as 0. Only used when `sasl` is `Some`;
    /// when the id names an explicit mechanism it overrides
    /// `sasl.mechanism`.
    pub sasl_mechanism: i32,
    /// Whether to answer an incoming CTCP VERSION *request* (sent as a
    /// PRIVMSG) with `NOTICE <nick> :\x01VERSION kIRC <version>\x01`.
    /// Set by `IrcBridge::set_ctcp_version_reply`; default `true`.
    ///
    /// Only VERSION is gated: PING, TIME and CLIENTINFO are answered
    /// unconditionally. A CTCP that arrives in a NOTICE is never answered,
    /// whatever this switch says.
    pub ctcp_version_reply: bool,
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
            sasl_mechanism: 0,
            ctcp_version_reply: true,
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
        /// The line arrived as a `NOTICE`, not a `PRIVMSG`. The bridge
        /// forwards this as the `isNotice` model role.
        is_notice: bool,
        /// The line is a CTCP `ACTION` (`/me`). The bridge forwards this as
        /// the `isAction` model role.
        is_action: bool,
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
    /// Server-confirmed channel flag state (`RPL_CHANNELMODEIS` / 324, kept
    /// current by incremental `MODE`).
    ///
    /// `modes` is the canonical letter set without `+`/`-` or arguments
    /// (`"imnt"`, `""` when no flag is set). Only what the server
    /// confirmed: the properties dialog reads this instead of guessing.
    ChannelModes { channel: String, modes: String },
    /// One membership-status change from a channel `MODE` (`+o alice`).
    ///
    /// The bridge applies this to the live nick list; the engine already
    /// folded it into any pending NAMES snapshot. `prefix` is the status
    /// prefix from the negotiated `PREFIX=` mapping (`@`, `+`, …), never
    /// the mode letter, so the bridge needs no ISUPPORT knowledge.
    MemberMode {
        channel: String,
        nick: String,
        add: bool,
        prefix: char,
    },
    /// Someone changed nick (including self).
    NickRename {
        old: String,
        new: String,
        is_self: bool,
    },
    /// Our nick changed (433 fallback, or the nick the server accepted in 001).
    NickChanged { nick: String },
    /// A resolved `chathistory` batch, tied to the target named by the server.
    ///
    /// Carrying the target with the result is essential when several history
    /// requests are in flight: servers may complete those batches in any
    /// order, so a UI-side "last requested target" cannot route them safely.
    HistoryBatch {
        target: String,
        messages: Vec<HistoryMsg>,
    },
    /// Informational text (MOTD, numerics summary).
    Info { text: String },
    /// An error worth surfacing to the user.
    Error { message: String },
    /// Text that answers something the user asked for: a reply to a command
    /// they issued (`/whois`, `/whowas`, `/who`, `/ison`, `/userhost`,
    /// `/motd`, `/list`, …).
    ///
    /// It belongs in the buffer the user is looking at, and it must never
    /// open a query buffer — whatever nick or channel it happens to be
    /// about. (Filing the WHOIS family under the queried nick is what used
    /// to pop a chat window for every `/whois`.)
    CommandReply { text: String },
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
    let tcp = match tokio::time::timeout(
        CONNECT_TIMEOUT,
        TcpStream::connect((config.host.as_str(), config.port)),
    )
    .await
    {
        Ok(Ok(tcp)) => tcp,
        Ok(Err(e)) => return Err(e.into()),
        Err(_) => {
            return Err(format!(
                "timed out after {}s connecting to {}:{}",
                CONNECT_TIMEOUT.as_secs(),
                config.host,
                config.port
            )
            .into())
        }
    };
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
    let stream = match tokio::time::timeout(
        TLS_HANDSHAKE_TIMEOUT,
        connector.connect(server_name, tcp),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(e)) => return Err(e.into()),
        Err(_) => {
            return Err(format!(
                "TLS handshake with {}:{} timed out after {}s",
                config.host,
                config.port,
                TLS_HANDSHAKE_TIMEOUT.as_secs()
            )
            .into())
        }
    };
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
    /// Server-advertised channel-status mapping as (mode, prefix) pairs,
    /// from RPL_ISUPPORT (005) `PREFIX=(modes)prefixes`. Defaults to the
    /// Ergo/Libera-style set; used to interpret MODE changes against a
    /// pending NAMES snapshot (see `split_mode_changes`).
    prefix_modes: Vec<(char, char)>,
    /// Server-advertised parameter policy for channel modes, from
    /// RPL_ISUPPORT (005) `CHANMODES=a,b,c,d`. Defaults to the
    /// Ergo/Libera-style set; used with `prefix_modes` to split MODE
    /// changes against a pending NAMES snapshot.
    chanmode_args: ChanModeArgs,
    /// Server-confirmed channel flag sets (`i`/`m`/`n`/`t`, also list/key
    /// letters), keyed by ASCII-lowercased channel. Established by
    /// `RPL_CHANNELMODEIS` (324) and kept current by incremental channel
    /// `MODE`; read out as [`IrcEvent::ChannelModes`].
    channel_modes: HashMap<String, BTreeSet<char>>,
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
        if line.contains(['\r', '\n']) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "outbound IRC command contains a line break",
            ));
        }
        if line.len() > MAX_OUTBOUND_LINE_LEN {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("outbound IRC command exceeds {MAX_OUTBOUND_LINE_LEN} bytes"),
            ));
        }
        debug!(">> {}", redact_log_line(line));
        write_line(&mut self.writer, line).await
    }

    async fn emit(&self, event: IrcEvent) {
        if self.events.send(event).await.is_err() {
            debug!("event receiver dropped; events are being discarded");
        }
    }

    /// File a numeric that answers a command the user issued (WHOIS, WHOWAS,
    /// WHO, ISON, USERHOST, MOTD, LIST, …) as an [`IrcEvent::CommandReply`].
    ///
    /// The UI renders a command reply in the buffer the user is looking at.
    /// It never opens a buffer — in particular never a query window for the
    /// nick the command happened to mention.
    async fn command_reply(&self, message: &IrcMessage) {
        self.emit(IrcEvent::CommandReply {
            text: numeric_summary(message),
        })
        .await;
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
                if buffer.kind == "chathistory"
                    && message.command == "PRIVMSG"
                    && buffer.messages.len() < MAX_HISTORY_BATCH_MESSAGES
                {
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
            "PRIVMSG" => self.handle_privmsg(&message).await?,
            "NOTICE" => self.handle_notice(&message).await?,
            "JOIN" => {
                let channel = message.params.first().cloned().unwrap_or_default();
                let nick = source_name(&message);
                // extended-join: JOIN <channel> <account> :<realname>
                let account = message.params.get(1).filter(|a| a.as_str() != "*").cloned();
                let is_self = nick.eq_ignore_ascii_case(&self.config.nickname);
                if !is_self && !channel.is_empty() {
                    // A membership change that lands while a NAMES snapshot
                    // for this channel is still accumulating must fold into
                    // the snapshot, or the 366 flush overwrites it and the
                    // user list goes stale.
                    names_acc_add(&mut self.names_acc, &channel, &nick, &self.prefix_modes);
                }
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
                if !channel.is_empty() {
                    if nick.eq_ignore_ascii_case(&self.config.nickname) {
                        self.names_acc.remove(&channel.to_ascii_lowercase());
                        self.channel_modes.remove(&channel.to_ascii_lowercase());
                    } else {
                        names_acc_remove(
                            &mut self.names_acc,
                            &channel,
                            &nick,
                            &self.prefix_modes,
                        );
                    }
                }
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
                if !nick.is_empty() {
                    names_acc_remove_nick(&mut self.names_acc, &nick, &self.prefix_modes);
                }
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
                if is_self {
                    self.names_acc.remove(&channel.to_ascii_lowercase());
                    self.channel_modes.remove(&channel.to_ascii_lowercase());
                } else {
                    names_acc_remove(&mut self.names_acc, &channel, &nick, &self.prefix_modes);
                }
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
                if is_channel(&target) {
                    // Fold status changes (+o/-o/+v/…) into a pending NAMES
                    // snapshot the same way JOIN/PART do, so the 366 flush
                    // carries the fresh prefixes — and report each one as a
                    // MemberMode so the bridge can move the live nick list
                    // too. Plain flags (i/m/n/t/…) update the tracked
                    // server-confirmed set behind ChannelModes.
                    let parts: Vec<String> =
                        modes.split_whitespace().map(str::to_string).collect();
                    if let Some((change, args)) = parts.split_first() {
                        let changes = split_mode_changes(
                            &self.prefix_modes,
                            &self.chanmode_args,
                            change,
                            args,
                        );
                        let mut flags_changed = false;
                        for (add, mode, arg) in changes {
                            if let Some(prefix) = mode_prefix(&self.prefix_modes, mode) {
                                if let Some(nick) = arg {
                                    names_acc_apply_mode(
                                        &mut self.names_acc,
                                        &target,
                                        add,
                                        mode,
                                        &nick,
                                        &self.prefix_modes,
                                    );
                                    self.emit(IrcEvent::MemberMode {
                                        channel: target.clone(),
                                        nick,
                                        add,
                                        prefix,
                                    })
                                    .await;
                                }
                                continue;
                            }
                            if apply_flag_change(&mut self.channel_modes, &target, add, mode) {
                                flags_changed = true;
                            }
                        }
                        if flags_changed {
                            let modes = canonical_modes(&self.channel_modes, &target);
                            self.emit(IrcEvent::ChannelModes {
                                channel: target.clone(),
                                modes,
                            })
                            .await;
                        }
                    }
                }
                self.emit(IrcEvent::Mode { target, modes }).await;
            }
            "NICK" => {
                let old = source_name(&message);
                let new_nick = message.params.first().cloned().unwrap_or_default();
                if new_nick.is_empty() {
                    return Ok(());
                }
                // A rename is not a quit — even inside a pending NAMES
                // snapshot: keep the member, preserving their prefixes.
                if !old.is_empty() {
                    names_acc_rename(&mut self.names_acc, &old, &new_nick, &self.prefix_modes);
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
            2..=4 => {
                self.emit(IrcEvent::Info {
                    text: numeric_summary(message),
                })
                .await;
            }
            5 => {
                // RPL_ISUPPORT: learn the server's PREFIX mapping (mode
                // letters to status prefixes) and CHANMODES parameter policy
                // before any NAMES/MODE that needs them. The line still
                // reaches the console as before.
                if let Some(mapping) = parse_isupport_prefix(&message.params) {
                    self.prefix_modes = mapping;
                }
                if let Some(chanmodes) = parse_isupport_chanmodes(&message.params) {
                    self.chanmode_args = chanmodes;
                }
                self.emit(IrcEvent::Info {
                    text: numeric_summary(message),
                })
                .await;
            }
            372 | 375 | 376 => {
                // MOTD. It answers the user's `/motd` when they typed it,
                // and at registration it falls back to the console (no
                // buffer is visible yet), exactly as before.
                self.emit(IrcEvent::CommandReply {
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
                        if !nick.is_empty() && entry.len() < MAX_NAMES_PER_CHANNEL {
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
            // ---- Command replies ------------------------------------------
            // Every numeric below answers something the user just issued
            // (/whois, /whowas, /who, /ison, /userhost, /away, /monitor,
            // /motd, /list, /version, /time, /stats, /lusers, /admin, /info,
            // /links, /invite, mode/ban listings). A reply belongs in the
            // buffer the user is looking at, never in a buffer keyed by the
            // nick or channel it happens to be about: filing the WHOIS
            // family under the queried nick is what popped a query window
            // for every /whois.
            301 | 307 | 311 | 312 | 313 | 317 | 318 | 319 | 330 | 335 | 338 | 378 | 379
            | 671 => {
                // WHOIS family.
                self.command_reply(message).await;
            }
            302 | 303 => {
                // USERHOST / ISON.
                self.command_reply(message).await;
            }
            305 | 306 => {
                // UNAWAY / NOWAWAY: the answer to /away.
                self.command_reply(message).await;
            }
            314 | 369 => {
                // WHOWAS / ENDOFWHOWAS.
                self.command_reply(message).await;
            }
            315 | 352 => {
                // WHO reply / end of WHO.
                self.command_reply(message).await;
            }
            241..=259 | 265 | 266 => {
                // STATS (241-250), LUSERS (251-255, 265, 266) and ADMIN
                // (256-259).
                self.command_reply(message).await;
            }
            321..=323 => {
                // LIST / LISTSTART / LISTEND.
                self.command_reply(message).await;
            }
            324 => {
                // RPL_CHANNELMODEIS: <client> <channel> <modeline> [args…].
                // Server-confirmed flag state: replace the tracked set and
                // tell the UI (the properties dialog reads ChannelModes),
                // then keep the command-reply line the /mode output always
                // produced.
                let channel = channel_from_numeric(message);
                if !channel.is_empty() {
                    if let Some(modeline) = message.params.get(2) {
                        let set: BTreeSet<char> = modeline
                            .chars()
                            .filter(|c| *c != '+' && *c != '-')
                            .collect();
                        if set.is_empty() {
                            self.channel_modes.remove(&channel.to_ascii_lowercase());
                        } else {
                            self.channel_modes.insert(channel.to_ascii_lowercase(), set);
                        }
                        let modes = canonical_modes(&self.channel_modes, &channel);
                        self.emit(IrcEvent::ChannelModes {
                            channel: channel.clone(),
                            modes,
                        })
                        .await;
                    }
                }
                self.command_reply(message).await;
            }
            329 | 346..=349 | 367 | 368 => {
                // Channel creation time, invite/except/ban listings — the
                // output of /mode.
                self.command_reply(message).await;
            }
            341 => {
                // INVITING: the confirmation of /invite.
                self.command_reply(message).await;
            }
            351 | 371 | 374 => {
                // VERSION / INFO / ENDOFINFO.
                self.command_reply(message).await;
            }
            364 | 365 => {
                // LINKS / ENDOFLINKS.
                self.command_reply(message).await;
            }
            381 => {
                // YOUREOPER: the confirmation of /oper.
                self.command_reply(message).await;
            }
            391 => {
                // TIME.
                self.command_reply(message).await;
            }
            730..=733 => {
                // MONITOR online/offline notifications and list replies
                // (/monitor), which arrive asynchronously after the command.
                self.command_reply(message).await;
            }
            401 => {
                // ERR_NOSUCHNICK answers the command that named the nick
                // (/whois, /msg, …). It is a command reply, not a message
                // from the nick: routing it as a `Msg` targeting that nick
                // is what opened a query window for a nick that does not
                // even exist. The Error keeps the failure visible as a
                // notification, exactly as before.
                let text = numeric_summary(message);
                self.emit(IrcEvent::CommandReply { text: text.clone() })
                    .await;
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
            463..=466 if !self.registered => {
                // Dead-session numerics: 463 (no permission for host), 464
                // (bad password), 465 (banned), 466 (you will be banned). The
                // server will never register this connection, and some daemons
                // keep the socket open after sending one, so a plain Error
                // would leave the client in Connecting until the registration
                // deadline. Keep the raw numeric text so an auth failure
                // ("464 Password incorrect") stays recognisable to the UI and
                // to the reconnect policy.
                self.abort(&format!(
                    "server rejected the connection: {}",
                    numeric_summary(message)
                ))
                .await
                .ok();
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
                // Capability names are case-insensitive.  A server is allowed
                // to answer with `SASL` even though we requested `sasl`; an
                // exact lower-case comparison would miss the rejection and
                // leave registration waiting for SASL until its deadline.
                let denied_sasl = cap
                    .caps
                    .iter()
                    .any(|c| c.trim_start_matches('-').eq_ignore_ascii_case("sasl"));
                if self.sasl_configured && denied_sasl {
                    self.abort("SASL capability was rejected by the server (CAP NAK)")
                        .await?;
                } else {
                    self.maybe_send_cap_end().await;
                }
            }
            "NEW" => self.caps.add_available(&cap.caps),
            "DEL" => self.caps.remove_available(&cap.caps),
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
            // Explicit ids override the stored mechanism: 1 = PLAIN,
            // 2 = EXTERNAL. Auto (0, or anything out of range) honours the
            // mechanism already in the config — EXCEPT the bridge's
            // "auto" default snapshot (SCRAM-SHA-256), which is only a
            // preference: downgrade it to PLAIN when the server's `sasl=...`
            // advertisement does not offer SCRAM-SHA-256.
            let mechanism = match self.config.sasl_mechanism {
                1 => SaslMechanism::Plain,
                2 => SaslMechanism::External,
                _ => {
                    if config.mechanism == SaslMechanism::ScramSha256 {
                        let offered = self.caps.sasl_mechanisms_offered();
                        if offered.iter().any(|m| m == "SCRAM-SHA-256") {
                            SaslMechanism::ScramSha256
                        } else {
                            SaslMechanism::Plain
                        }
                    } else {
                        config.mechanism
                    }
                }
            };
            let mut effective = config.clone();
            effective.mechanism = mechanism;
            let client = SaslClient::new(&effective);
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
            // 400 bytes per chunk, the protocol limit. Step back to a UTF-8
            // boundary so a multi-byte character split across the cut cannot
            // turn the chunk into an empty string (which used to be sent
            // silently: a corrupted SASL exchange at best, a rejected login
            // at worst).
            let mut end = (offset + 400).min(bytes.len());
            while end > offset && !payload.is_char_boundary(end) {
                end -= 1;
            }
            if end == offset {
                // Cannot happen for UTF-8 (4 bytes max per char), but never
                // loop without progress.
                end = bytes.len();
            }
            let chunk = &payload[offset..end];
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
            if self.batches.len() >= MAX_OPEN_BATCHES {
                warn!("ignoring BATCH {id}: too many batches are already open");
                return;
            }
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
                        target: buffer.target,
                        messages: buffer.messages,
                    })
                    .await;
                }
            }
        }
    }

    async fn handle_privmsg(&mut self, message: &IrcMessage) -> io::Result<()> {
        let raw_target = message.params.first().cloned().unwrap_or_default();
        let raw_text = message.params.get(1).cloned().unwrap_or_default();
        let nick = source_name(message);
        let timestamp = message.tags.get("time").cloned().flatten();
        let is_self = !nick.is_empty() && nick.eq_ignore_ascii_case(&self.config.nickname);
        let is_highlight = !is_self && is_highlight(&raw_text, &self.config.nickname);
        let target = conversation_target(&self.config.nickname, &nick, &raw_target, is_self);

        // CTCP is routed separately from chat text: without this, the `\x01`
        // delimiters are stripped as formatting and a request like
        // `\x01VERSION\x01` is shown as the bare word "VERSION".
        if let Some(ctcp) = parse_ctcp(&raw_text) {
            return self
                .handle_ctcp(ctcp, &nick, &target, is_self, is_highlight, timestamp, false)
                .await;
        }

        let text = display_privmsg(&raw_text);
        if text.trim().is_empty() {
            return Ok(());
        }
        // Swallow only our own NickServ IDENTIFY echo (seen via
        // echo-message); channel traffic starting with "identify" displays.
        if is_self && is_identify_echo(&raw_target, &text) {
            return Ok(());
        }
        self.emit(IrcEvent::Msg {
            target,
            nick,
            text,
            timestamp,
            is_self,
            is_highlight,
            is_notice: false,
            is_action: false,
        })
        .await;
        Ok(())
    }

    /// User/service NOTICE (NickServ, ChanServ, queries) lands in that
    /// conversation. Server-wide NOTICE stays on the console.
    async fn handle_notice(&mut self, message: &IrcMessage) -> io::Result<()> {
        let raw_target = message.params.first().cloned().unwrap_or_default();
        let raw_text = message
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
            self.emit(IrcEvent::Notice { nick, text: raw_text }).await;
            return Ok(());
        }
        let is_self = !nick.is_empty() && nick.eq_ignore_ascii_case(&self.config.nickname);
        let target = conversation_target(&self.config.nickname, &nick, &raw_target, is_self);
        let timestamp = message.tags.get("time").cloned().flatten();
        // A CTCP in a NOTICE is displayed like any other CTCP — and, crucially,
        // is never answered: that is how CTCP reply loops start.
        if let Some(ctcp) = parse_ctcp(&raw_text) {
            return self
                .handle_ctcp(ctcp, &nick, &target, is_self, false, timestamp, true)
                .await;
        }
        let text = display_privmsg(&raw_text);
        if text.trim().is_empty() {
            return Ok(());
        }
        self.emit(IrcEvent::Msg {
            target,
            nick,
            text,
            timestamp,
            is_self,
            is_highlight: false,
            is_notice: true,
            is_action: false,
        })
        .await;
        Ok(())
    }

    /// Handle one inbound CTCP message, from a PRIVMSG or a NOTICE.
    ///
    /// Loop safety: only a request that arrived as a PRIVMSG is ever
    /// answered, our own echo is ignored outright, and every command that is
    /// not an explicit request (DCC, SOURCE, FINGER, …) stays unanswered. An
    /// answer goes back as `NOTICE <nick> :\x01<reply>\x01` addressed to the
    /// sender.
    ///
    /// Display: ACTION keeps its `/me` rendering; every other CTCP becomes a
    /// dim system-style line (the `"*"` nick is the existing event marker)
    /// naming the kind and the sender, so a request or reply is never shown
    /// as ordinary chat and never silently dropped.
    #[allow(clippy::too_many_arguments)]
    async fn handle_ctcp(
        &mut self,
        ctcp: Ctcp,
        nick: &str,
        target: &str,
        is_self: bool,
        is_highlight: bool,
        timestamp: Option<String>,
        in_notice: bool,
    ) -> io::Result<()> {
        // ACTION is a CTCP but not a request: it stays chat, and is never
        // answered — from a NOTICE either.
        if let Ctcp::Action(action) = &ctcp {
            let action = strip_irc_formatting(action);
            if action.trim().is_empty() {
                return Ok(());
            }
            self.emit(IrcEvent::Msg {
                target: target.to_string(),
                nick: nick.to_string(),
                text: format!("* {action}"),
                timestamp,
                is_self,
                is_highlight,
                is_notice: in_notice,
                is_action: true,
            })
            .await;
            return Ok(());
        }

        // Our own echo (echo-message) must never be answered — it is not an
        // incoming request — and a source we cannot address cannot be
        // answered either.
        if is_self || nick.is_empty() {
            debug!("ignoring CTCP {} without an answerable sender", ctcp.kind());
            return Ok(());
        }

        self.emit(IrcEvent::Msg {
            target: target.to_string(),
            nick: "*".to_string(),
            text: ctcp_display_line(&ctcp, nick, in_notice),
            timestamp,
            is_self: false,
            is_highlight: false,
            is_notice: in_notice,
            is_action: false,
        })
        .await;

        if in_notice {
            // Never answer a NOTICE: a CTCP in a NOTICE is protocol-wise a
            // reply (a VERSION answer, for instance), not a request.
            return Ok(());
        }
        if let Some(reply) = ctcp_reply(&ctcp, self.config.ctcp_version_reply, unix_now()) {
            self.send(&format!("NOTICE {nick} :\u{1}{reply}\u{1}")).await?;
        }
        Ok(())
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
                let lines = split_privmsg_lines(&target, &text)?;
                for line in &lines {
                    self.send(&format!("PRIVMSG {target} :{line}")).await?;
                }
                if !self.echo_message {
                    for line in &lines {
                        // An outbound CTCP query is not chat: the
                        // echo-message replay takes the CTCP path and never
                        // shows a self chat line, so the local mirror must
                        // agree (this is the path `/ctcp` and
                        // `/version <nick>` take — the UI prints its own
                        // local line for those). ACTION is the exception:
                        // `/me` stays a chat row in both modes.
                        let is_action = match parse_ctcp(line) {
                            Some(Ctcp::Action(_)) => true,
                            Some(_) => continue,
                            None => false,
                        };
                        self.emit(IrcEvent::Msg {
                            target: target.clone(),
                            nick: self.config.nickname.clone(),
                            text: display_privmsg(line),
                            timestamp: None,
                            is_self: true,
                            is_highlight: false,
                            is_notice: false,
                            is_action,
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

/// True when `target` is a channel name (`#`, `&`, `+`, `!` prefixes).
pub fn is_channel(target: &str) -> bool {
    matches!(target.as_bytes().first(), Some(b'#' | b'&' | b'+' | b'!'))
}

/// Split outbound PRIVMSG text into wire-safe lines: split on CR/LF and
/// drop empty lines so no raw newline ever goes out in a single send().
fn split_privmsg_lines(target: &str, text: &str) -> io::Result<Vec<String>> {
    let prefix_len = "PRIVMSG ".len() + target.len() + " :".len();
    let budget = MAX_OUTBOUND_LINE_LEN.checked_sub(prefix_len).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "message target is too long")
    })?;
    if budget == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "message target leaves no room for text",
        ));
    }

    let mut output = Vec::new();
    for line in text.split(['\n', '\r']).filter(|line| !line.is_empty()) {
        if let Some(action) = line
            .strip_prefix("\u{1}ACTION ")
            .and_then(|body| body.strip_suffix('\u{1}'))
        {
            let action_budget = budget.checked_sub("\u{1}ACTION \u{1}".len()).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "message target is too long")
            })?;
            if action_budget == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "message target leaves no room for action text",
                ));
            }
            for chunk in split_utf8_chunks(action, action_budget) {
                output.push(format!("\u{1}ACTION {chunk}\u{1}"));
            }
        } else if parse_ctcp(line).is_some() && line.len() > budget {
            // Splitting an arbitrary CTCP query would create malformed
            // fragments that look like ordinary chat. Actions are the only
            // CTCP payload whose semantics can safely be preserved in chunks.
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "CTCP query exceeds the IRC line limit",
            ));
        } else {
            output.extend(split_utf8_chunks(line, budget).map(str::to_owned));
        }
    }
    Ok(output)
}

fn split_utf8_chunks(mut text: &str, max_bytes: usize) -> impl Iterator<Item = &str> {
    std::iter::from_fn(move || {
        if text.is_empty() || max_bytes == 0 {
            return None;
        }
        let mut end = text.len().min(max_bytes);
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        if end == 0 {
            return None;
        }
        let (chunk, rest) = text.split_at(end);
        text = rest;
        Some(chunk)
    })
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

/// Default channel-status mapping as (mode, prefix) pairs: `q` → `~`
/// (owner), `a` → `&` (admin), `o` → `@` (operator), `h` → `%` (halfop),
/// `v` → `+` (voice). This is what Ergo and Libera advertise; a server with
/// a different `PREFIX=` in RPL_ISUPPORT (005) overrides it per connection
/// (see [`parse_isupport_prefix`]).
pub fn default_prefix_modes() -> Vec<(char, char)> {
    vec![('q', '~'), ('a', '&'), ('o', '@'), ('h', '%'), ('v', '+')]
}

/// Parse the `PREFIX=(modes)prefixes` token out of RPL_ISUPPORT (005)
/// params into (mode, prefix) pairs. `None` when the token is absent or
/// malformed (the caller keeps its current mapping).
///
/// Accepts the token with or without a leading `:` (some daemons attach the
/// trailing-parameter colon to the last ISUPPORT token).
pub fn parse_isupport_prefix(params: &[String]) -> Option<Vec<(char, char)>> {
    let token = params
        .iter()
        .find(|p| p.trim_start_matches(':').starts_with("PREFIX="))?;
    let token = token.trim_start_matches(':');
    let inner = token.strip_prefix("PREFIX=(")?;
    let (modes, prefixes) = inner.split_once(')')?;
    if modes.is_empty() || modes.len() != prefixes.len() {
        return None;
    }
    let mapping: Vec<(char, char)> = modes.chars().zip(prefixes.chars()).collect();
    if mapping.is_empty() {
        return None;
    }
    Some(mapping)
}

/// Which channel modes take a parameter, from RPL_ISUPPORT (005)
/// `CHANMODES=a,b,c,d`: list modes (a, e.g. `b`) and "always take one" modes
/// (b, e.g. `k`) take a parameter in both directions; "set-only" modes (c,
/// e.g. `l`) take one only while being set (`+`); plain toggles (d, e.g.
/// `i m n t`) never do. Status modes (the PREFIX set) always take a nick and
/// are handled separately.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChanModeArgs {
    /// Modes that always take a parameter (`CHANMODES` groups a+b).
    pub always: Vec<char>,
    /// Modes that take one only while being set (`CHANMODES` group c).
    pub on_set: Vec<char>,
}

/// The Ergo/Libera-style default: `b e I` (ban/except/invite lists) always
/// take a mask, `k l` (key/limit) take one only while being set.
pub fn default_chanmode_args() -> ChanModeArgs {
    ChanModeArgs {
        always: vec!['b', 'e', 'I'],
        on_set: vec!['k', 'l'],
    }
}

/// Parse the `CHANMODES=a,b,c,d` token out of RPL_ISUPPORT (005) params.
/// `None` when the token is absent or malformed (the caller keeps its
/// current mapping).
pub fn parse_isupport_chanmodes(params: &[String]) -> Option<ChanModeArgs> {
    let token = params
        .iter()
        .find(|p| p.trim_start_matches(':').starts_with("CHANMODES="))?;
    let token = token.trim_start_matches(':');
    let inner = token.strip_prefix("CHANMODES=")?;
    let mut groups = inner.split(',');
    let a = groups.next().unwrap_or("");
    let b = groups.next().unwrap_or("");
    let c = groups.next().unwrap_or("");
    // A fourth group (d, the plain toggles) carries no parameters and needs
    // no storage; a fifth group is malformed.
    let _d = groups.next();
    if groups.next().is_some() {
        return None;
    }
    let mut always: Vec<char> = a.chars().chain(b.chars()).collect();
    always.sort_unstable();
    always.dedup();
    let mut on_set: Vec<char> = c.chars().collect();
    on_set.sort_unstable();
    on_set.dedup();
    if always.is_empty() && on_set.is_empty() {
        return None;
    }
    Some(ChanModeArgs { always, on_set })
}

/// The prefix char a status mode maps to, if any.
pub fn mode_prefix(prefix_modes: &[(char, char)], mode: char) -> Option<char> {
    prefix_modes
        .iter()
        .find(|(m, _)| *m == mode)
        .map(|(_, p)| *p)
}

/// Split a channel MODE change (`+ov-v`, `+m`, …) plus its parameter list
/// into `(add, mode, arg)` triples.
///
/// Argument consumption is PREFIX/CHANMODES-aware: status modes (the
/// server's PREFIX set) always take a nick; `ChanModeArgs.always` modes take
/// one in both directions; `ChanModeArgs.on_set` modes take one only while
/// being set (`+`). Anything else (`i`/`m`/`n`/`t`/…) takes none. Keeping
/// consumption exact matters: skipping a mask would misalign every nick
/// after it.
pub fn split_mode_changes(
    prefix_modes: &[(char, char)],
    chanmode_args: &ChanModeArgs,
    change: &str,
    args: &[String],
) -> Vec<(bool, char, Option<String>)> {
    let mut out = Vec::new();
    let mut adding = true;
    let mut arg_index = 0usize;
    for mode in change.chars() {
        match mode {
            '+' => {
                adding = true;
            }
            '-' => {
                adding = false;
            }
            _ => {
                let takes_arg = if prefix_modes.iter().any(|(m, _)| *m == mode)
                    || chanmode_args.always.contains(&mode)
                {
                    true
                } else if chanmode_args.on_set.contains(&mode) {
                    adding
                } else {
                    false
                };
                let arg = if takes_arg {
                    let arg = args.get(arg_index).cloned();
                    arg_index += 1;
                    arg
                } else {
                    None
                };
                out.push((adding, mode, arg));
            }
        }
    }
    out
}

/// Split a nick-list entry into its status prefixes and its bare nick, using
/// the server's prefix set. `@+bob` → (`@+`, `bob`); `bob` → (``, `bob`).
fn split_entry_prefixes<'a>(entry: &'a str, prefix_modes: &[(char, char)]) -> (&'a str, &'a str) {
    let prefixes: Vec<char> = prefix_modes.iter().map(|(_, p)| *p).collect();
    let cut = entry
        .char_indices()
        .find(|(_, c)| !prefixes.contains(c))
        .map(|(i, _)| i)
        .unwrap_or(entry.len());
    entry.split_at(cut)
}

/// True when `entry` names `nick` (prefixes ignored, ASCII
/// case-insensitive).
fn entry_matches(entry: &str, nick: &str, prefix_modes: &[(char, char)]) -> bool {
    let (_, bare) = split_entry_prefixes(entry, prefix_modes);
    bare.eq_ignore_ascii_case(nick)
}

/// Order index of a status prefix for display, strongest first, using the
/// server's own PREFIX order (its first mode is the strongest). A prefix the
/// server never advertised sorts last.
fn prefix_order(prefix_modes: &[(char, char)], prefix: char) -> usize {
    prefix_modes
        .iter()
        .position(|(_, p)| *p == prefix)
        .unwrap_or(usize::MAX)
}

/// Recombine prefix chars (strongest first) with a bare nick.
fn join_prefixes(prefix_modes: &[(char, char)], prefixes: &[char], bare: &str) -> String {
    let mut sorted = prefixes.to_vec();
    sorted.sort_by_key(|p| prefix_order(prefix_modes, *p));
    sorted.dedup();
    format!("{}{}", sorted.iter().collect::<String>(), bare)
}

/// Fold a JOIN into a pending NAMES snapshot (deduped by bare nick).
fn names_acc_add(
    acc: &mut HashMap<String, Vec<String>>,
    channel: &str,
    nick: &str,
    prefix_modes: &[(char, char)],
) {
    let entry = acc.entry(channel.to_ascii_lowercase()).or_default();
    if !entry
        .iter()
        .any(|n| split_entry_prefixes(n, prefix_modes).1.eq_ignore_ascii_case(nick))
    {
        entry.push(nick.to_string());
    }
}

/// Fold a PART/KICK out of a pending NAMES snapshot. No entry (or no
/// member) is a silent no-op.
fn names_acc_remove(
    acc: &mut HashMap<String, Vec<String>>,
    channel: &str,
    nick: &str,
    prefix_modes: &[(char, char)],
) {
    if let Some(list) = acc.get_mut(&channel.to_ascii_lowercase()) {
        list.retain(|n| !entry_matches(n, nick, prefix_modes));
    }
}

/// Fold a QUIT out of every pending NAMES snapshot.
fn names_acc_remove_nick(
    acc: &mut HashMap<String, Vec<String>>,
    nick: &str,
    prefix_modes: &[(char, char)],
) {
    for list in acc.values_mut() {
        list.retain(|n| !entry_matches(n, nick, prefix_modes));
    }
}

/// Fold a NICK rename into every pending NAMES snapshot, preserving the
/// member's status prefixes.
fn names_acc_rename(
    acc: &mut HashMap<String, Vec<String>>,
    old: &str,
    new: &str,
    prefix_modes: &[(char, char)],
) {
    for list in acc.values_mut() {
        for entry in list.iter_mut() {
            if entry_matches(entry, old, prefix_modes) {
                let (prefixes, _) = split_entry_prefixes(entry, prefix_modes);
                *entry = format!("{prefixes}{new}");
            }
        }
    }
}

/// Fold one status MODE change into a pending NAMES snapshot: `+o alice`
/// adds `@`, `-v bob` drops `+`. A nick that is not in the snapshot is a
/// silent no-op (it will arrive via 353/JOIN like any other member).
fn names_acc_apply_mode(
    acc: &mut HashMap<String, Vec<String>>,
    channel: &str,
    add: bool,
    mode: char,
    nick: &str,
    prefix_modes: &[(char, char)],
) {
    let Some(prefix) = mode_prefix(prefix_modes, mode) else {
        return;
    };
    let Some(list) = acc.get_mut(&channel.to_ascii_lowercase()) else {
        return;
    };
    for entry in list.iter_mut() {
        if entry_matches(entry, nick, prefix_modes) {
            let (prefixes, bare) = split_entry_prefixes(entry, prefix_modes);
            let mut kept: Vec<char> = prefixes.chars().collect();
            if add {
                if !kept.contains(&prefix) {
                    kept.push(prefix);
                }
            } else {
                kept.retain(|p| *p != prefix);
            }
            *entry = join_prefixes(prefix_modes, &kept, bare);
        }
    }
}

/// Track one non-status channel flag (`i`/`m`/`n`/`t`, also list/key
/// letters) in the per-channel set. Keys are ASCII-lowercased channels.
/// Returns true when the set changed (so the caller knows whether a
/// `ChannelModes` event is due); an emptied set is dropped.
fn apply_flag_change(
    modes: &mut HashMap<String, BTreeSet<char>>,
    channel: &str,
    add: bool,
    mode: char,
) -> bool {
    let key = channel.to_ascii_lowercase();
    if add {
        modes.entry(key).or_default().insert(mode)
    } else {
        let removed = modes
            .get_mut(&key)
            .map(|set| set.remove(&mode))
            .unwrap_or(false);
        if modes.get(&key).is_some_and(|set| set.is_empty()) {
            modes.remove(&key);
        }
        removed
    }
}

/// Canonical flag letters for `channel` (`"imnt"`, `""` when unset or
/// unknown) — what `ChannelModes` carries to the UI.
fn canonical_modes(modes: &HashMap<String, BTreeSet<char>>, channel: &str) -> String {
    modes
        .get(&channel.to_ascii_lowercase())
        .map(|set| set.iter().collect())
        .unwrap_or_default()
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

// ===========================================================================
// CTCP
// ===========================================================================

/// A CTCP message parsed out of an inbound PRIVMSG or NOTICE.
///
/// CTCP is a sub-protocol carried inside ordinary messages: the body is
/// wrapped in `\x01` delimiters and starts with a command word, optionally
/// followed by arguments. The delimiters are the only thing that
/// distinguishes `\x01VERSION\x01` from a user typing the word VERSION, so
/// detection happens before any chat-text rendering.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Ctcp {
    /// `/me` text — rendered as chat, never answered.
    Action(String),
    Version(String),
    Ping(String),
    Time(String),
    ClientInfo(String),
    /// File transfer / chat requests — never answered, surfaced explicitly.
    Dcc(String),
    /// Any other CTCP command (`SOURCE`, `FINGER`, …) — never answered.
    Other { kind: String, payload: String },
}

impl Ctcp {
    /// The command word as shown to the user (normalized upper-case).
    fn kind(&self) -> &str {
        match self {
            Ctcp::Action(_) => "ACTION",
            Ctcp::Version(_) => "VERSION",
            Ctcp::Ping(_) => "PING",
            Ctcp::Time(_) => "TIME",
            Ctcp::ClientInfo(_) => "CLIENTINFO",
            Ctcp::Dcc(_) => "DCC",
            Ctcp::Other { kind, .. } => kind,
        }
    }

    /// Command arguments, `""` when the sender omitted them.
    fn payload(&self) -> &str {
        match self {
            Ctcp::Action(p)
            | Ctcp::Version(p)
            | Ctcp::Ping(p)
            | Ctcp::Time(p)
            | Ctcp::ClientInfo(p)
            | Ctcp::Dcc(p) => p,
            Ctcp::Other { payload, .. } => payload,
        }
    }
}

/// Parse a message body as CTCP; `None` for ordinary chat text.
///
/// An unterminated body (`\x01VERSION` with no closing delimiter — some
/// clients send it) and anything after the closing delimiter are tolerated;
/// the command is everything before the first space.
fn parse_ctcp(text: &str) -> Option<Ctcp> {
    let body = text.strip_prefix('\u{1}')?;
    let body = match body.find('\u{1}') {
        Some(end) => &body[..end],
        None => body,
    };
    let (kind, payload) = match body.split_once(' ') {
        Some((kind, payload)) => (kind, payload),
        None => (body, ""),
    };
    if kind.is_empty() {
        return None;
    }
    // CTCP command words are case-insensitive on the wire.
    let kind = kind.to_ascii_uppercase();
    Some(match kind.as_str() {
        "ACTION" => Ctcp::Action(payload.to_string()),
        "VERSION" => Ctcp::Version(payload.to_string()),
        "PING" => Ctcp::Ping(payload.to_string()),
        "TIME" => Ctcp::Time(payload.to_string()),
        "CLIENTINFO" => Ctcp::ClientInfo(payload.to_string()),
        "DCC" => Ctcp::Dcc(payload.to_string()),
        _ => Ctcp::Other {
            kind,
            payload: payload.to_string(),
        },
    })
}

/// Client name reported in the CTCP VERSION reply. The version part is the
/// kirc-core crate version, which `packaging/set-version.sh` keeps in step
/// with the release tag — never a hand-written string.
const CTCP_CLIENT_NAME: &str = "kIRC";

/// Commands advertised in the CLIENTINFO reply.
const CTCP_CLIENTINFO: &str = "ACTION CLIENTINFO PING TIME VERSION";

/// Seconds since the Unix epoch (0 if the clock is somehow before 1970).
fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The reply payload (without `\x01` delimiters) for an inbound CTCP
/// *request*, or `None` when the command must not be answered.
///
/// `version_enabled` is [`ConnectionConfig::ctcp_version_reply`]: it gates
/// VERSION only — PING, TIME and CLIENTINFO are unconditional. `now` is
/// epoch seconds, injected so the TIME reply is testable.
fn ctcp_reply(ctcp: &Ctcp, version_enabled: bool, now: u64) -> Option<String> {
    match ctcp {
        Ctcp::Version(_) => {
            version_enabled.then(|| format!("VERSION {CTCP_CLIENT_NAME} {}", env!("CARGO_PKG_VERSION")))
        }
        // Echo the payload verbatim.
        Ctcp::Ping(payload) if payload.is_empty() => Some("PING".to_string()),
        Ctcp::Ping(payload) => Some(format!("PING {payload}")),
        Ctcp::Time(_) => Some(format!("TIME {}", format_utc(now))),
        Ctcp::ClientInfo(_) => Some(format!("CLIENTINFO {CTCP_CLIENTINFO}")),
        // ACTION is chat, DCC is unsupported, and every other command
        // (SOURCE, FINGER, …) gets no automatic reply.
        Ctcp::Action(_) | Ctcp::Dcc(_) | Ctcp::Other { .. } => None,
    }
}

/// The dim system-style line shown for an inbound CTCP that is not ACTION.
///
/// Emitted through the ordinary `Msg` vocabulary with nick `"*"` — the
/// existing event-row marker — so no new model role is needed. A CTCP that
/// arrived inside a NOTICE is protocol-wise a *reply* (a VERSION answer, for
/// instance) and is labelled as one.
fn ctcp_display_line(ctcp: &Ctcp, nick: &str, in_notice: bool) -> String {
    let nick = strip_irc_formatting(nick);
    let kind = strip_irc_formatting(ctcp.kind());
    let payload = strip_irc_formatting(ctcp.payload());
    if matches!(ctcp, Ctcp::Dcc(_)) {
        return format!("CTCP DCC from {nick} (DCC is not supported)");
    }
    if !in_notice {
        return format!("CTCP {kind} request from {nick}");
    }
    if payload.is_empty() {
        format!("CTCP {kind} reply from {nick}")
    } else {
        format!("CTCP {kind} reply from {nick}: {payload}")
    }
}

/// `Thu Sep 11 21:05:00 2026` (UTC) for a CTCP TIME reply.
fn format_utc(timestamp: u64) -> String {
    const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let days = (timestamp / 86_400) as i64;
    let secs = timestamp % 86_400;
    let (year, month, day) = civil_from_days(days);
    // 1970-01-01 was a Thursday, so `days + 4` indexes a Sunday-first week.
    let weekday = WEEKDAYS[(days + 4).rem_euclid(7) as usize];
    format!(
        "{weekday} {} {day:02} {:02}:{:02}:{:02} {year}",
        MONTHS[(month - 1) as usize],
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}

/// Days since the epoch to `(year, month, day)` — Howard Hinnant's
/// `civil_from_days`, proleptic Gregorian.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097); // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if month <= 2 { year + 1 } else { year }, month, day)
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

/// Validate fields that are interpolated into registration commands.
///
/// The QML form performs the same user-facing checks, but the engine is a
/// public boundary and must not rely on one caller to prevent malformed NICK,
/// USER or PASS lines (especially embedded CR/LF command injection).
fn validate_config(config: &ConnectionConfig) -> io::Result<()> {
    fn is_middle_param(value: &str) -> bool {
        !value.is_empty()
            && !value.starts_with(':')
            && !value
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || c == ',')
    }

    if config.host.is_empty()
        || config
            .host
            .chars()
            .any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "server host is empty or contains whitespace",
        ));
    }
    if config.port == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "server port must be between 1 and 65535",
        ));
    }
    if !is_middle_param(&config.nickname) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "nickname is empty or contains invalid characters",
        ));
    }
    if !is_middle_param(&config.username) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "username is empty or contains invalid characters",
        ));
    }
    if config.realname.contains(['\r', '\n', '\0']) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "real name contains an invalid control character",
        ));
    }
    if config
        .server_password
        .as_deref()
        .is_some_and(|password| password.contains(['\r', '\n', '\0']))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "server password contains an invalid control character",
        ));
    }
    Ok(())
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

    if let Err(error) = validate_config(&config) {
        let reason = error.to_string();
        let _ = events
            .send(IrcEvent::Error {
                message: reason.clone(),
            })
            .await;
        let _ = events.send(IrcEvent::Disconnected { reason }).await;
        return Err(error.into());
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
        prefix_modes: default_prefix_modes(),
        chanmode_args: default_chanmode_args(),
        channel_modes: HashMap::new(),
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

    // One-shot registration deadline, armed at connect and never extended.
    // See `REGISTRATION_TIMEOUT`: without it a handshake that never completes
    // (missing CAP END/001, AUTHENTICATE left unanswered) hangs the session
    // forever whenever the server keeps answering keepalives.
    let registration_deadline = tokio::time::sleep(REGISTRATION_TIMEOUT);
    tokio::pin!(registration_deadline);

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
                            if e.kind() == io::ErrorKind::InvalidInput {
                                session.emit(IrcEvent::Error { message: e.to_string() }).await;
                                continue;
                            }
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
            _ = &mut registration_deadline, if !session.registered => {
                // Never registered in time: the server either stopped talking
                // mid-handshake or is waiting for something we already sent.
                // Abort loudly instead of sitting in Connecting forever.
                let reason = format!(
                    "registration did not complete within {}s",
                    REGISTRATION_TIMEOUT.as_secs()
                );
                warn!("{reason}");
                if let Err(e) = session.abort(&reason).await {
                    warn!("write error during registration-timeout abort: {e}");
                }
                break;
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

/// Write one outbound line plus its CRLF, bounded by [`WRITE_TIMEOUT`].
///
/// See [`WRITE_TIMEOUT`] for why the write path needs the bound while the read
/// path does not.
async fn write_line<W>(writer: &mut W, line: &str) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let write = async {
        writer.write_all(line.as_bytes()).await?;
        writer.write_all(b"\r\n").await?;
        writer.flush().await
    };
    match tokio::time::timeout(WRITE_TIMEOUT, write).await {
        Ok(result) => result,
        Err(_) => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "write timed out: the peer stopped reading",
        )),
    }
}

/// Read one CRLF-terminated line, sans terminator. `Ok(None)` means EOF.
///
/// The line is length-capped at [`MAX_LINE_LEN`] payload bytes (plus 2 for the
/// CRLF). An overlong line is read to its terminator but discarded, and an
/// empty string is returned so the caller skips it: `read_until` had no cap at
/// all, so one endless line from a server or a broken proxy could grow the
/// buffer without bound and stall the read loop.
async fn read_line<R>(reader: &mut BufReader<R>) -> io::Result<Option<String>>
where
    R: AsyncRead + Unpin,
{
    /// Longest accepted line, terminator included.
    const MAX_READ: usize = MAX_LINE_LEN + 2;

    let mut buf: Vec<u8> = Vec::with_capacity(512);
    let mut overlong = false;
    loop {
        let (consumed, found_newline) = {
            let available = reader.fill_buf().await?;
            if available.is_empty() {
                // EOF. Hand back a trailing partial line once, then None.
                if buf.is_empty() || overlong {
                    return Ok(None);
                }
                return Ok(Some(String::from_utf8_lossy(&buf).into_owned()));
            }
            match available.iter().position(|&b| b == b'\n') {
                Some(pos) => {
                    let take = pos + 1;
                    if buf.len() + take > MAX_READ {
                        overlong = true;
                    }
                    if !overlong {
                        buf.extend_from_slice(&available[..take]);
                    }
                    (take, true)
                }
                None => {
                    let take = available.len();
                    if buf.len() + take > MAX_READ || overlong {
                        overlong = true;
                    } else {
                        buf.extend_from_slice(available);
                    }
                    (take, false)
                }
            }
        };
        reader.consume(consumed);
        if overlong {
            // Discard everything until the terminator arrives, so the next
            // read starts on a fresh line.
            buf.clear();
            if found_newline {
                warn!("dropping overlong line (> {MAX_LINE_LEN} bytes)");
                return Ok(Some(String::new()));
            }
            continue;
        }
        if found_newline {
            return Ok(Some(String::from_utf8_lossy(&buf).into_owned()));
        }
    }
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
    fn registration_config_rejects_broken_or_injected_fields() {
        let mut config = ConnectionConfig {
            host: "irc.example.org".to_string(),
            nickname: "kircuser".to_string(),
            username: "kircuser".to_string(),
            realname: "kIRC user".to_string(),
            ..ConnectionConfig::default()
        };
        assert!(validate_config(&config).is_ok());

        config.nickname = "bad nick".to_string();
        assert!(validate_config(&config).is_err());
        config.nickname = "kircuser".to_string();
        config.server_password = Some("secret\r\nOPER attacker password".to_string());
        assert!(validate_config(&config).is_err());
        config.server_password = None;
        config.port = 0;
        assert!(validate_config(&config).is_err());
    }

    #[test]
    fn privmsg_split_skips_empty_lines() {
        assert_eq!(split_privmsg_lines("#c", "one\ntwo").unwrap(), vec!["one", "two"]);
        assert_eq!(
            split_privmsg_lines("#c", "one\r\ntwo\n\nthree\r\n").unwrap(),
            vec!["one", "two", "three"]
        );
        assert!(split_privmsg_lines("#c", "\n\r\n").unwrap().is_empty());
        assert_eq!(split_privmsg_lines("#c", "single").unwrap(), vec!["single"]);
    }

    #[test]
    fn privmsg_chunks_respect_wire_limit_and_utf8_boundaries() {
        let text = "🙂".repeat(300);
        let chunks = split_privmsg_lines("#rust", &text).unwrap();
        assert!(chunks.len() > 1);
        assert_eq!(chunks.concat(), text);
        assert!(chunks.iter().all(|chunk| {
            format!("PRIVMSG #rust :{chunk}").len() <= MAX_OUTBOUND_LINE_LEN
        }));

        let action = format!("\u{1}ACTION {}\u{1}", "waves ".repeat(200));
        let actions = split_privmsg_lines("#rust", &action).unwrap();
        assert!(actions.len() > 1);
        assert!(actions
            .iter()
            .all(|chunk| chunk.starts_with("\u{1}ACTION ") && chunk.ends_with('\u{1}')));
        let long_ctcp = format!("\u{1}VERSION {}\u{1}", "x".repeat(600));
        assert!(split_privmsg_lines("#rust", &long_ctcp).is_err());
        for line in split_privmsg_lines("#rust", "a\nb\r\nc").unwrap() {
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

    fn isupport_params(tokens: &[&str]) -> Vec<String> {
        tokens.iter().map(|t| t.to_string()).collect()
    }

    #[test]
    fn isupport_prefix_parses_ergo_style_token() {
        let params = isupport_params(&[
            "kircuser",
            "PREFIX=(qaohv)~&@%+",
            "CHANTYPES=#",
            ":are supported by this server",
        ]);
        assert_eq!(
            parse_isupport_prefix(&params),
            Some(vec![
                ('q', '~'),
                ('a', '&'),
                ('o', '@'),
                ('h', '%'),
                ('v', '+')
            ])
        );
        // Some daemons attach the trailing colon to the last token.
        let params = isupport_params(&["kircuser", ":PREFIX=(ov)@+"]);
        assert_eq!(
            parse_isupport_prefix(&params),
            Some(vec![('o', '@'), ('v', '+')])
        );
        // No PREFIX token: keep the current mapping.
        assert_eq!(
            parse_isupport_prefix(&isupport_params(&["kircuser", "NICKLEN=32"])),
            None
        );
        // Modes/prefixes length mismatch is malformed.
        assert_eq!(
            parse_isupport_prefix(&isupport_params(&["kircuser", "PREFIX=(ov)@"])),
            None
        );
    }

    #[test]
    fn isupport_chanmodes_parses_standard_token() {
        // Classic four-group shape (a=list, b=always-param, c=set-param,
        // d=plain toggles): b/k always take one, l only while setting.
        let params = isupport_params(&["kircuser", "CHANMODES=b,k,l,imnt"]);
        assert_eq!(
            parse_isupport_chanmodes(&params),
            Some(ChanModeArgs {
                always: vec!['b', 'k'],
                on_set: vec!['l'],
            })
        );
        assert_eq!(
            parse_isupport_chanmodes(&isupport_params(&["kircuser", "NICKLEN=32"])),
            None
        );
        // Five groups is malformed.
        assert_eq!(
            parse_isupport_chanmodes(&isupport_params(&["kircuser", "CHANMODES=a,b,c,d,e"])),
            None
        );
    }

    #[test]
    fn mode_prefix_maps_status_letters() {
        let defaults = default_prefix_modes();
        assert_eq!(mode_prefix(&defaults, 'o'), Some('@'));
        assert_eq!(mode_prefix(&defaults, 'v'), Some('+'));
        assert_eq!(mode_prefix(&defaults, 'q'), Some('~'));
        assert_eq!(mode_prefix(&defaults, 'm'), None);
        let minimal = vec![('o', '@'), ('v', '+')];
        assert_eq!(mode_prefix(&minimal, 'o'), Some('@'));
        assert_eq!(mode_prefix(&minimal, 'q'), None);
    }

    fn mode_args(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    #[test]
    fn split_mode_changes_consumes_args_chanmodes_aware() {
        let prefixes = default_prefix_modes();
        let chanmodes = default_chanmode_args();
        // Status modes each take a nick.
        assert_eq!(
            split_mode_changes(&prefixes, &chanmodes, "+ov", &mode_args(&["a", "b"])),
            vec![
                (true, 'o', Some("a".to_string())),
                (true, 'v', Some("b".to_string())),
            ]
        );
        // Mixed add/remove keeps each nick aligned.
        assert_eq!(
            split_mode_changes(&prefixes, &chanmodes, "+o-v", &mode_args(&["a", "b"])),
            vec![
                (true, 'o', Some("a".to_string())),
                (false, 'v', Some("b".to_string())),
            ]
        );
        // A ban mask must not eat the nick that follows it.
        assert_eq!(
            split_mode_changes(
                &prefixes,
                &chanmodes,
                "+b+o",
                &mode_args(&["*!*@evil", "alice"])
            ),
            vec![
                (true, 'b', Some("*!*@evil".to_string())),
                (true, 'o', Some("alice".to_string())),
            ]
        );
        // Plain toggles take nothing; key/limit only while setting.
        assert_eq!(
            split_mode_changes(&prefixes, &chanmodes, "+m", &[]),
            vec![(true, 'm', None)]
        );
        assert_eq!(
            split_mode_changes(&prefixes, &chanmodes, "+k", &mode_args(&["secret"])),
            vec![(true, 'k', Some("secret".to_string()))]
        );
        assert_eq!(
            split_mode_changes(&prefixes, &chanmodes, "-k", &mode_args(&["secret"])),
            vec![(false, 'k', None)]
        );
        assert_eq!(
            split_mode_changes(&prefixes, &chanmodes, "-l", &[]),
            vec![(false, 'l', None)]
        );
        // A mode the server never advertised as a status or list mode takes
        // no argument.
        let minimal = vec![('o', '@'), ('v', '+')];
        assert_eq!(
            split_mode_changes(&minimal, &chanmodes, "+q", &mode_args(&["alice"])),
            vec![(true, 'q', None)]
        );
    }

    #[test]
    fn flag_changes_track_case_folded_sets() {
        let mut modes: HashMap<String, BTreeSet<char>> = HashMap::new();
        assert!(apply_flag_change(&mut modes, "#chan", true, 'm'));
        assert!(apply_flag_change(&mut modes, "#CHAN", true, 't'));
        // Re-adding a set flag is a no-op (no ChannelModes due).
        assert!(!apply_flag_change(&mut modes, "#chan", true, 'm'));
        assert_eq!(canonical_modes(&modes, "#chan"), "mt");
        // Removing what was never set is a no-op too.
        assert!(!apply_flag_change(&mut modes, "#chan", false, 'i'));
        assert!(apply_flag_change(&mut modes, "#chan", false, 'm'));
        assert_eq!(canonical_modes(&modes, "#chan"), "t");
        // The last flag out drops the channel entry.
        assert!(apply_flag_change(&mut modes, "#chan", false, 't'));
        assert_eq!(canonical_modes(&modes, "#chan"), "");
        assert!(!modes.contains_key("#chan"));
        assert_eq!(canonical_modes(&modes, "#never"), "");
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
            sasl_mechanism: 0,
            ctcp_version_reply: true,
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

    /// `read_line` with a wall-clock bound, so a harness mistake fails the
    /// test instead of wedging the suite.
    async fn read_line_bounded<R>(reader: &mut BufReader<R>) -> io::Result<Option<String>>
    where
        R: AsyncRead + Unpin,
    {
        tokio::time::timeout(Duration::from_secs(5), read_line(reader))
            .await
            .expect("read_line blocked past 5s")
    }

    /// The read path is length-capped: an overlong line is consumed to its
    /// terminator and dropped (empty string), and the stream stays
    /// line-synchronised. The old `read_until` buffered without any cap, so a
    /// single endless line could grow the buffer without bound.
    #[tokio::test]
    async fn overlong_line_is_dropped_and_stream_stays_synced() {
        let (mut client, mut server) = tokio::io::duplex(64 * 1024);
        let junk = "z".repeat(MAX_LINE_LEN + 500);
        server.write_all(junk.as_bytes()).await.unwrap();
        server.write_all(b"\r\n").await.unwrap();
        server.write_all(b"PING :probe\r\n").await.unwrap();

        let mut reader = BufReader::new(&mut client);
        assert_eq!(
            read_line_bounded(&mut reader).await.unwrap(),
            Some(String::new()),
            "an overlong line must be dropped, not parsed"
        );
        assert_eq!(
            read_line_bounded(&mut reader).await.unwrap().as_deref(),
            Some("PING :probe\r\n"),
            "the reader must resync on the next line"
        );

        // A line exactly at the parser limit still goes through untouched.
        let edge = "y".repeat(MAX_LINE_LEN);
        server.write_all(edge.as_bytes()).await.unwrap();
        server.write_all(b"\r\n").await.unwrap();
        server.write_all(b"QUIT :bye\r\n").await.unwrap();
        assert_eq!(
            read_line_bounded(&mut reader).await.unwrap().map(|l| l.len()),
            Some(MAX_LINE_LEN + 2)
        );
        assert_eq!(
            read_line_bounded(&mut reader).await.unwrap().as_deref(),
            Some("QUIT :bye\r\n")
        );

        // EOF between lines is None. The write half must be closed for the
        // read to see EOF at all.
        drop(server);
        assert_eq!(read_line_bounded(&mut reader).await.unwrap().as_deref(), None);
    }

    /// The keepalive must notice a link that has stopped answering: two
    /// unanswered periods set `should_stop` and put a QUIT on the wire.
    #[tokio::test]
    async fn missed_pongs_stop_the_session() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let peer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (r, _w) = tokio::io::split(stream);
            let mut lines = BufReader::new(r).lines();
            let mut seen = Vec::new();
            // Read until the peer goes away, recording what the client sent.
            while let Ok(Some(line)) = lines.next_line().await {
                seen.push(line);
            }
            seen
        });
        let stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let (read_half, write_half) = tokio::io::split(Transport::Plain(stream));
        // Both halves are held so the peer's reads keep working; the test
        // drops them at the end to close the socket and let the peer finish.
        let (events, _rx) = tokio::sync::mpsc::channel::<IrcEvent>(16);
        let mut session = Session {
            config: ConnectionConfig {
                host: "127.0.0.1".to_string(),
                port,
                tls: false,
                nickname: "n".to_string(),
                username: "u".to_string(),
                realname: "r".to_string(),
                server_password: None,
                sasl: None,
                sasl_mechanism: 0,
                ctcp_version_reply: true,
                request_caps: vec![],
            },
            events,
            writer: write_half,
            caps: CapState::default(),
            sasl: None,
            sasl_configured: false,
            sasl_active: false,
            sasl_done: false,
            cap_end_sent: false,
            registered: false,
            batches: HashMap::new(),
            names_acc: HashMap::new(),
            prefix_modes: default_prefix_modes(),
            chanmode_args: default_chanmode_args(),
            channel_modes: HashMap::new(),
            ping_counter: 0,
            outstanding_ping: None,
            missed_pongs: 0,
            should_stop: false,
            disconnect_reason: "connection closed".to_string(),
            nick_attempts: 0,
            echo_message: false,
            error_disconnect_emitted: false,
        };
        let held_read_half = read_half;

        // A period with nothing outstanding sends a fresh PING and tracks it.
        session.handle_ping_tick().await.unwrap();
        assert!(!session.should_stop);
        assert!(session.outstanding_ping.is_some());
        assert_eq!(session.missed_pongs, 0);
        // Any PONG resets the miss counter and retires the token.
        session.handle_line("PONG :kirc1").await.unwrap();
        assert_eq!(session.missed_pongs, 0);
        assert!(session.outstanding_ping.is_none());
        // The next period sends a new PING; that same PING stays outstanding
        // while unanswered periods elapse, and MAX_MISSED_PONGS of them trip
        // the disconnect.
        session.handle_ping_tick().await.unwrap();
        assert_eq!(session.ping_counter, 2, "a fresh period must PING again");
        assert_eq!(session.missed_pongs, 0);
        session.handle_ping_tick().await.unwrap();
        assert_eq!(session.missed_pongs, 1);
        assert!(!session.should_stop, "one missed period is below the limit");
        session.handle_ping_tick().await.unwrap();
        assert_eq!(session.missed_pongs, MAX_MISSED_PONGS);
        assert!(
            session.should_stop,
            "MAX_MISSED_PONGS missed periods must disconnect"
        );
        assert!(session.disconnect_reason.contains("ping timeout"));
        // Closing both halves is what ends the peer's read loop.
        drop(session);
        drop(held_read_half);
        let seen = tokio::time::timeout(Duration::from_secs(5), peer)
            .await
            .expect("peer read loop did not finish")
            .unwrap();
        assert!(
            seen.iter().any(|l| l == "PING :kirc1"),
            "keepalive PING missing: {seen:?}"
        );
        assert!(
            seen.iter().any(|l| l == "QUIT :Ping timeout"),
            "QUIT on ping timeout missing: {seen:?}"
        );
    }

    #[test]
    fn ctcp_parsing_needs_delimiters_and_normalizes_the_kind() {
        // Ordinary chat text is never CTCP, even when it is a command word.
        assert_eq!(parse_ctcp("hello"), None);
        assert_eq!(parse_ctcp("VERSION"), None);
        assert_eq!(parse_ctcp(" PING 12345"), None);
        assert_eq!(parse_ctcp("\u{1}"), None);
        assert_eq!(parse_ctcp("\u{1}\u{1}"), None);

        assert_eq!(
            parse_ctcp("\u{1}VERSION\u{1}"),
            Some(Ctcp::Version(String::new()))
        );
        // Case-insensitive on the wire.
        assert_eq!(
            parse_ctcp("\u{1}version\u{1}"),
            Some(Ctcp::Version(String::new()))
        );
        // An unterminated body still parses.
        assert_eq!(parse_ctcp("\u{1}VERSION"), Some(Ctcp::Version(String::new())));
        assert_eq!(
            parse_ctcp("\u{1}PING 12345\u{1}"),
            Some(Ctcp::Ping("12345".to_string()))
        );
        // The payload keeps interior spacing so PING can be echoed verbatim.
        assert_eq!(
            parse_ctcp("\u{1}PING  hello  42 \u{1}"),
            Some(Ctcp::Ping(" hello  42 ".to_string()))
        );
        assert_eq!(
            parse_ctcp("\u{1}ACTION waves at you\u{1}"),
            Some(Ctcp::Action("waves at you".to_string()))
        );
        assert_eq!(
            parse_ctcp("\u{1}DCC SEND f.txt 1 2 3\u{1}"),
            Some(Ctcp::Dcc("SEND f.txt 1 2 3".to_string()))
        );
        assert_eq!(
            parse_ctcp("\u{1}source\u{1}"),
            Some(Ctcp::Other {
                kind: "SOURCE".to_string(),
                payload: String::new(),
            })
        );
        // Junk after the closing delimiter is dropped, never displayed.
        assert_eq!(
            parse_ctcp("\u{1}VERSION\u{1}trailing"),
            Some(Ctcp::Version(String::new()))
        );
    }

    #[test]
    fn ctcp_replies_are_limited_to_requests() {
        let version = ctcp_reply(&Ctcp::Version(String::new()), true, 0).unwrap();
        assert_eq!(
            version,
            format!("VERSION kIRC {}", env!("CARGO_PKG_VERSION")),
            "the reply must report the crate version, not an invented string"
        );
        // A request payload is not reflected back.
        assert_eq!(
            ctcp_reply(&Ctcp::Version("ignored".to_string()), true, 0).unwrap(),
            version
        );

        // The toggle suppresses VERSION only.
        assert_eq!(ctcp_reply(&Ctcp::Version(String::new()), false, 0), None);
        assert_eq!(
            ctcp_reply(&Ctcp::Ping("12345".to_string()), false, 0).unwrap(),
            "PING 12345"
        );
        assert_eq!(
            ctcp_reply(&Ctcp::Time(String::new()), false, 0).unwrap(),
            "TIME Thu Jan 01 00:00:00 1970"
        );
        assert_eq!(
            ctcp_reply(&Ctcp::ClientInfo(String::new()), false, 0).unwrap(),
            "CLIENTINFO ACTION CLIENTINFO PING TIME VERSION"
        );

        // PING echoes the payload verbatim, empty payload included.
        assert_eq!(
            ctcp_reply(&Ctcp::Ping(String::new()), true, 0).unwrap(),
            "PING"
        );
        assert_eq!(
            ctcp_reply(&Ctcp::Ping(" hello  42 ".to_string()), true, 0).unwrap(),
            "PING  hello  42 "
        );
        assert_eq!(
            ctcp_reply(&Ctcp::Time(String::new()), true, 951_827_696).unwrap(),
            "TIME Tue Feb 29 12:34:56 2000"
        );

        // Chat, file transfers and everything else are never answered.
        assert_eq!(ctcp_reply(&Ctcp::Action("waves".to_string()), true, 0), None);
        assert_eq!(
            ctcp_reply(&Ctcp::Dcc("SEND f.txt 1 2 3".to_string()), true, 0),
            None
        );
        assert_eq!(
            ctcp_reply(
                &Ctcp::Other {
                    kind: "SOURCE".to_string(),
                    payload: String::new(),
                },
                true,
                0
            ),
            None
        );
    }

    #[test]
    fn ctcp_display_lines_name_kind_and_sender() {
        let dcc = Ctcp::Dcc("SEND evil.exe 3232235777 6667 0".to_string());
        let line = ctcp_display_line(&dcc, "alice", false);
        assert!(
            line.contains("DCC") && line.contains("alice") && line.contains("not supported"),
            "DCC must be surfaced explicitly: {line}"
        );
        assert!(
            !line.contains("evil.exe"),
            "the DCC payload must not leak into the log line: {line}"
        );

        assert_eq!(
            ctcp_display_line(&Ctcp::Version(String::new()), "alice", false),
            "CTCP VERSION request from alice"
        );
        // A reply (a CTCP inside a NOTICE) shows the remote client's string.
        assert_eq!(
            ctcp_display_line(&Ctcp::Version("SomeClient 1.2".to_string()), "alice", true),
            "CTCP VERSION reply from alice: SomeClient 1.2"
        );
        assert_eq!(
            ctcp_display_line(&Ctcp::ClientInfo(String::new()), "bob", true),
            "CTCP CLIENTINFO reply from bob"
        );
    }

    #[test]
    fn utc_formatting_matches_known_timestamps() {
        assert_eq!(format_utc(0), "Thu Jan 01 00:00:00 1970");
        assert_eq!(format_utc(951_827_696), "Tue Feb 29 12:34:56 2000"); // leap day
        assert_eq!(format_utc(1_789_160_700), "Fri Sep 11 21:05:00 2026");
        // 2100 is a century that is NOT a leap year.
        assert_eq!(format_utc(4_107_542_400), "Mon Mar 01 00:00:00 2100");
        assert_eq!(format_utc(1_735_689_599), "Tue Dec 31 23:59:59 2024");
    }
}
