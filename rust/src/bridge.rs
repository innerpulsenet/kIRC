//! CXX-Qt bridge for kIRC.
//!
//! This file is the only place where the Qt/QML world and the pure-Rust IRC
//! engine (`kirc-core`) meet.
//!
//! * `IrcBridge` is the QML-facing singleton-ish object: it owns a tokio
//!   runtime, spawns a `kirc_core::run_session` task per connection, and
//!   ferries `IrcEvent`s back onto the Qt thread with the CXX-Qt threading
//!   helpers (`impl cxx_qt::Threading`, `qt_thread().queue(..)`).
//! * `MessageListModel` is a `QAbstractListModel` subclass that reads its rows
//!   out of the crate-level [`STORE`] buffer that `IrcBridge` fills in.
//!
//! Neither object talks to Qt off the GUI thread: every mutation happens inside
//! a closure queued onto the object's own thread.

use std::collections::BTreeMap;
use std::pin::Pin;
use std::sync::{Mutex, OnceLock};

use cxx_qt::{CxxQtType, Threading};
use cxx_qt_lib::{QByteArray, QHash, QHashPair_i32_QByteArray, QModelIndex, QString, QVariant};

use chrono::Datelike;
use kirc_core::{is_channel, ClientCommand, ConnectionConfig, IrcEvent, SaslConfig, SaslMechanism};

// ---------------------------------------------------------------------------
// Shared, cross-object message buffer
// ---------------------------------------------------------------------------

/// A single message as buffered for the QML models.
///
/// `nick`/`text`/`timestamp`/`is_self`/`is_highlight` are the raw row data.
/// `is_private`/`is_notice`/`is_action` are RAW arrival facts (see
/// [`StoreMsg::arrival`]) — they say which buffer the row landed in and how
/// the line arrived, and feed the `isPrivate`/`isNotice`/`isAction` roles
/// verbatim. `day` is the local calendar date the row's timestamp fell on
/// (`None` when the timestamp was unparseable); it is what the day-boundary
/// roles are computed from, because the display stamp alone ("HH:MM") carries
/// no date. `is_event`/`is_error`/`show_day`/`day_label` are DERIVED
/// presentation flags: they are left at their defaults in the [`STORE`] and
/// filled in by [`qobject::MessageListModel`] when a row is produced (single
/// pass in `load_channel`, O(1) in `append_message`).
#[derive(Clone, Debug, Default)]
pub struct StoreMsg {
    pub nick: String,
    pub text: String,
    pub timestamp: String,
    pub is_self: bool,
    pub is_highlight: bool,
    /// The row belongs to a query buffer (an ordinary nick), not a channel
    /// and not the server console.
    pub is_private: bool,
    /// The line arrived as a NOTICE; also set for the console lines a
    /// server-wide NOTICE produces.
    pub is_notice: bool,
    /// The line is (the rendering of) a CTCP ACTION — `/me`.
    pub is_action: bool,
    pub day: Option<chrono::NaiveDate>,
    pub is_event: bool,
    pub is_error: bool,
    pub show_day: bool,
    pub day_label: String,
}

impl StoreMsg {
    /// A raw buffered row. The derived flags start false/empty; the list model
    /// fills them in when the row is produced.
    fn new(
        nick: String,
        text: String,
        timestamp: String,
        is_self: bool,
        is_highlight: bool,
        day: Option<chrono::NaiveDate>,
    ) -> Self {
        Self {
            nick,
            text,
            timestamp,
            is_self,
            is_highlight,
            day,
            ..Self::default()
        }
    }

    /// Attach the row's arrival facts: the buffer `key` it is stored under
    /// (a query buffer or not) and whether the line arrived as a NOTICE / a
    /// CTCP ACTION. These are the raw values behind the `isPrivate` /
    /// `isNotice` / `isAction` model roles and are preserved across both the
    /// batch (`derive_rows`) and incremental (`append_message`) paths.
    fn arrival(mut self, key: &str, is_notice: bool, is_action: bool) -> Self {
        self.is_private = is_query_key(key);
        self.is_notice = is_notice;
        self.is_action = is_action;
        self
    }
}

/// True when a buffer key names a query (an ordinary nick) rather than a
/// channel or the server console — the join of `isPrivate`.
fn is_query_key(key: &str) -> bool {
    !is_channel(key) && key != SERVER_BUFFER
}

/// Global `target -> messages` buffer.
///
/// `IrcBridge` appends to it from the Qt thread; `MessageListModel` reads from
/// it on `load_channel(..)`.  Nothing else may mutate it.
pub static STORE: OnceLock<Mutex<BTreeMap<String, Vec<StoreMsg>>>> = OnceLock::new();

fn store() -> &'static Mutex<BTreeMap<String, Vec<StoreMsg>>> {
    STORE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub static NICKS: OnceLock<Mutex<BTreeMap<String, Vec<String>>>> = OnceLock::new();
fn nick_store() -> &'static Mutex<BTreeMap<String, Vec<String>>> {
    NICKS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub static TOPICS: OnceLock<Mutex<BTreeMap<String, String>>> = OnceLock::new();
fn topic_store() -> &'static Mutex<BTreeMap<String, String>> {
    TOPICS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn bare_nick(nick: &str) -> &str {
    nick.trim_start_matches(|c: char| matches!(c, '@' | '+' | '%' | '~' | '&'))
}

/// Reuse an existing buffer key when the only difference is ASCII case
/// (`nickserv` vs `NickServ`). Channels are folded the same way.
fn canon_map_key<V>(map: &BTreeMap<String, V>, target: &str) -> String {
    map.keys()
        .find(|k| k.eq_ignore_ascii_case(target))
        .cloned()
        .unwrap_or_else(|| target.to_string())
}

fn canon_key(map: &BTreeMap<String, Vec<StoreMsg>>, target: &str) -> String {
    canon_map_key(map, target)
}

/// The buffer currently shown in the UI, as last recorded by
/// `MessageListModel::load_channel(..)`.
///
/// Used only to suppress the unread badge for the channel the user is already
/// looking at. Empty until the first `load_channel` call.
static VISIBLE_TARGET: OnceLock<Mutex<String>> = OnceLock::new();
fn visible_target() -> &'static Mutex<String> {
    VISIBLE_TARGET.get_or_init(|| Mutex::new(String::new()))
}

/// Drop every buffered transcript, nick list and topic, and forget which
/// buffer is visible, so the next server never inherits the old one's state.
fn clear_all_stores() {
    store().lock().unwrap_or_else(|e| e.into_inner()).clear();
    nick_store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    topic_store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    visible_target()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
}

/// The process-wide tokio runtime that drives every IRC session.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("kirc-irc")
            .build()
            .expect("kIRC: failed to build the tokio runtime")
    })
}

/// Local-time `HH:MM` stamp, used for locally echoed messages.
fn now_string() -> String {
    chrono::Local::now().format("%H:%M").to_string()
}

/// Format an IRCv3 `server-time` value as a local-time `HH:MM` string, plus
/// the local calendar date it fell on (`None` when the value is unparseable).
///
/// The QML layer displays message timestamps verbatim (it does no date
/// formatting of its own), so the bridge is responsible for the presentation.
/// Anything unparseable is passed through untouched so no information is lost
/// — and, having no parseable date, can never start a day section.
fn fmt_timestamp(raw: Option<String>) -> (String, Option<chrono::NaiveDate>) {
    match raw.as_deref() {
        Some(value) if !value.is_empty() => match chrono::DateTime::parse_from_rfc3339(value) {
            Ok(datetime) => {
                let local = datetime.with_timezone(&chrono::Local);
                (
                    local.format("%H:%M").to_string(),
                    Some(local.date_naive()),
                )
            }
            Err(_) => (value.to_owned(), None),
        },
        _ => (now_string(), Some(now_day())),
    }
}

/// Local calendar date `now`.
fn now_day() -> chrono::NaiveDate {
    chrono::Local::now().date_naive()
}

/// True when `nick` marks a synthesized event line (joins, parts, quits,
/// modes, topics, server notices) — those are pushed with nick `"*"`.
fn nick_is_event(nick: &str) -> bool {
    nick.trim() == "*"
}

/// The numeric of a line that starts with a 3-digit IRC numeric.
///
/// The bridge formats every server-console info line as `"<numeric> <text>"`
/// (the core's `numeric_summary`: `format!("{} {}", message.command, body)`),
/// e.g. `"473 #pain Cannot join channel (+i)"`. The leading token must be
/// exactly three digits followed by whitespace (or end of line), so `"4730 …"`
/// and `"47 …"` are not numerics.
fn leading_numeric(text: &str) -> Option<u32> {
    let bytes = text.as_bytes();
    if bytes.len() < 3 || !bytes[..3].iter().all(u8::is_ascii_digit) {
        return None;
    }
    if bytes.len() > 3 && !bytes[3].is_ascii_whitespace() {
        return None;
    }
    text[..3].parse().ok()
}

/// Nicks of network services whose notices report account/access status.
fn is_service_nick(nick: &str) -> bool {
    let nick = nick.trim();
    nick.eq_ignore_ascii_case("nickserv") || nick.eq_ignore_ascii_case("chanserv")
}

/// Failure phrasing, matched case-insensitively against synthesized lines and
/// service notices: NickServ/ChanServ auth failures, refusals and protocol
/// errors that carry no numeric of their own.
const FAILURE_PHRASES: &[&str] = &[
    "invalid password",
    "authentication failed",
    "identification failed",
    "not registered",
    "access denied",
    "you are not",
    "denied",
    "incorrect",
    // A refused JOIN explained in words ("473 ... Cannot join channel (+i)")
    // in case the reason ever arrives without its numeric prefix.
    "cannot join channel",
    // The requested nick was taken and the session fell back to an alternate
    // ("* alice_ is in use, trying alice__").
    "is in use, trying",
];

/// Success phrasing of an identify/login notice. Checked BEFORE the failure
/// list so "You are now identified" / "You are now logged in as X" can never
/// be flagged. Deliberately narrow: a bare "logged in" would also mask the
/// failure "You are not logged in".
const SUCCESS_PHRASES: &[&str] = &[
    "you are now identified",
    "you are now logged in",
    "logged in as",
    "password accepted",
    "you have been identified",
];

/// True when a row represents a failure and must render in the warn colour.
///
/// Classification is content-based because both write paths (`derive_rows` on
/// load, `derive_row` on append) only see the row's nick and text. Only
/// synthesized lines are classified:
///
/// * console/event lines (nick `"*"` — what `info_to_store` and
///   `push_channel_line` produce, numerics included), and
/// * service notices in their query buffer (`NickServ`/`ChanServ`).
///
/// Ordinary chatter is NEVER scanned, so a user typing "404 not found" or
/// "you are not funny" stays a normal line. A line that matches nothing here
/// stays non-error: MOTD (372/375/376), joins/parts, topics and the rest keep
/// their dim/primary rendering.
fn line_is_error(nick: &str, text: &str) -> bool {
    let console_line = nick_is_event(nick);
    if !console_line && !is_service_nick(nick) {
        return false;
    }

    // Numeric replies are classified by RANGE alone: 4xx/5xx fail, 3xx (MOTD
    // 372/375/376, WHOIS, topic, names) never do — whatever the text after the
    // numeric happens to say.
    if let Some(numeric) = leading_numeric(text) {
        return (400..=599).contains(&numeric);
    }

    let lower = text.to_ascii_lowercase();

    // The console line the bridge emits when the session ends with a reason
    // ("Disconnected: connection closed by server", "Disconnected: client
    // requested disconnect") — a disconnect is a failure worth noticing.
    if console_line && lower.starts_with("disconnected:") {
        return true;
    }

    if SUCCESS_PHRASES.iter().any(|phrase| lower.contains(phrase)) {
        return false;
    }
    FAILURE_PHRASES.iter().any(|phrase| lower.contains(phrase))
}

/// The model row's `dayLabel`: "Today", "Yesterday", else e.g. "Sep 11".
fn day_label_for(day: chrono::NaiveDate, today: chrono::NaiveDate) -> String {
    if day == today {
        return "Today".to_owned();
    }
    if Some(day) == today.pred_opt() {
        return "Yesterday".to_owned();
    }
    // chrono's %b is the English abbreviated month, so the label is stable
    // regardless of the process locale (the rest of this program is English).
    format!("{} {}", day.format("%b"), day.day())
}

/// Fill one row's derived presentation flags.
///
/// `prev_day` is the calendar day of the row *before* this one in the display
/// sequence (`None` for the first row, and for rows whose predecessor had an
/// unparseable timestamp). A day section starts only when both rows have a
/// parseable date and the dates differ — an unparseable timestamp is never a
/// day boundary.
///
/// `is_error` is derived here from the row's own content (see
/// [`line_is_error`]), so the batch pass (`derive_rows`) and the O(1) append
/// pass agree without the STORE having to carry the flag.
fn derive_row(prev_day: Option<chrono::NaiveDate>, row: &mut StoreMsg) {
    row.is_event = nick_is_event(&row.nick);
    row.is_error = line_is_error(&row.nick, &row.text);
    row.show_day = matches!((prev_day, row.day), (Some(prev), Some(day)) if prev != day);
    row.day_label = row.day.map(|day| day_label_for(day, now_day())).unwrap_or_default();
}

/// Derive every row's flags in ONE pass, front to back. Used by
/// `load_channel`, which produces all rows of a buffer at once.
fn derive_rows(rows: &mut [StoreMsg]) {
    let mut prev_day: Option<chrono::NaiveDate> = None;
    for row in rows.iter_mut() {
        derive_row(prev_day, row);
        prev_day = row.day;
    }
}

/// Copy a Qt string into a Rust `String`.
fn rs(q: &QString) -> String {
    String::from(q)
}

/// Convert a Rust string into a Qt `QString`.
fn qs(s: &str) -> QString {
    QString::from(s)
}

// ===========================================================================
// The bridge
// ===========================================================================

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
        include!("cxx-qt-lib/qbytearray.h");
        type QByteArray = cxx_qt_lib::QByteArray;
        include!("cxx-qt-lib/qmodelindex.h");
        type QModelIndex = cxx_qt_lib::QModelIndex;
        include!("cxx-qt-lib/qvariant.h");
        type QVariant = cxx_qt_lib::QVariant;
        include!("cxx-qt-lib/qhash.h");
        type QHash_i32_QByteArray = cxx_qt_lib::QHash<cxx_qt_lib::QHashPair_i32_QByteArray>;
    }

    // Base class for the list model.  `QAbstractListModel` is a Qt type, it is
    // only ever opaque here.
    unsafe extern "C++Qt" {
        include!(<QtCore/QAbstractListModel>);
        #[qobject]
        type QAbstractListModel;
    }

    // -----------------------------------------------------------------------
    // Shared enums
    // -----------------------------------------------------------------------

    /// Connection state of the IRC session, exposed to QML as
    /// `IrcBridge.Disconnected` / `IrcBridge.Connecting` / `IrcBridge.Connected`.
    #[qenum(IrcBridge)]
    enum ConnectionStatus {
        Disconnected,
        Connecting,
        Connected,
    }

    /// Roles of [`MessageListModel`].
    ///
    /// `isEvent`/`isError`/`showDay`/`dayLabel` are computed in Rust when a row
    /// is produced (see `derive_rows` / `derive_row`); QML binds them directly.
    ///
    /// `isPrivate`/`isNotice`/`isAction` are the row's raw arrival facts (see
    /// [`super::StoreMsg::arrival`]): which buffer the row belongs to (a query
    /// rather than a channel) and how the line arrived (NOTICE / CTCP ACTION).
    /// They are ADDITIVE — the existing names and order are frozen, so the new
    /// roles are appended after `IsError`.
    #[qenum(MessageListModel)]
    enum Roles {
        Nick,
        Text,
        Timestamp,
        IsSelf,
        IsHighlight,
        IsEvent,
        ShowDay,
        DayLabel,
        IsError,
        IsPrivate,
        IsNotice,
        IsAction,
    }

    // -----------------------------------------------------------------------
    // IrcBridge
    // -----------------------------------------------------------------------

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(ConnectionStatus, connection_state)]
        #[qproperty(i32, unread_count)]
        #[qproperty(QString, nickname)]
        #[qproperty(QString, connected_server)]
        #[qproperty(QString, history_target)]
        type IrcBridge = super::IrcBridgeRust;

        /// A chat line arrived (or was locally echoed).
        ///
        /// `timestamp` is the preformatted "HH:MM" string the log renders
        /// verbatim ("" when unknown) — the very string the [`STORE`] row for
        /// this line carries, so the incremental
        /// `MessageListModel::append_message` path and a later
        /// `load_channel(..)` reload show the identical stamp.
        #[qsignal]
        fn message_received(
            self: Pin<&mut Self>,
            target: QString,
            nick: QString,
            text: QString,
            timestamp: QString,
            is_self: bool,
            is_highlight: bool,
        );

        /// A batch of buffered history for `target` was loaded into [`STORE`].
        #[qsignal]
        fn history_batch_received(self: Pin<&mut Self>, target: QString);

        /// The connection state changed.
        ///
        /// The payload is the `ConnectionStatus` repr as an `i32`: cxx-qt
        /// 0.10 emits broken C++ when a class-attached `#[qenum]` is used as a
        /// signal parameter (the `using ConnectionStatus = ::IrcBridge::ConnectionStatus;`
        /// alias is generated *after* the CXX header that needs it).  QML still
        /// compares against `IrcBridge.Disconnected` / `.Connecting` / `.Connected`.
        #[qsignal]
        fn state_changed(self: Pin<&mut Self>, state: i32);

        /// Something happened that deserves a desktop notification.
        #[qsignal]
        fn notification_fired(self: Pin<&mut Self>, title: QString, body: QString);

        /// Informational status line.
        #[qsignal]
        fn info(self: Pin<&mut Self>, text: QString);

        /// Something went wrong.
        #[qsignal]
        fn error_occurred(self: Pin<&mut Self>, message: QString);

        /// We successfully joined `channel` (our own JOIN).
        #[qsignal]
        fn channel_joined(self: Pin<&mut Self>, channel: QString);

        /// We left `channel` (our own PART).
        #[qsignal]
        fn channel_parted(self: Pin<&mut Self>, channel: QString);

        /// A JOIN was rejected. The channel must not appear as joined.
        #[qsignal]
        fn join_failed(self: Pin<&mut Self>, channel: QString, reason: QString);

        /// Topic for `channel` changed (or arrived on join).
        #[qsignal]
        fn topic_changed(self: Pin<&mut Self>, channel: QString, topic: QString);

        /// Nick list for `channel` was replaced. `nicks` is space-separated,
        /// prefixes (`@%+~&`) kept.
        #[qsignal]
        fn names_updated(self: Pin<&mut Self>, channel: QString, nicks: QString);

        /// A query buffer should exist for `nick`.
        #[qsignal]
        fn query_opened(self: Pin<&mut Self>, nick: QString);

        /// Select the SASL mechanism for the next connection. Must be called
        /// BEFORE `connect_server` (which snapshots it into the session
        /// config): 0 = auto (SCRAM-SHA-256 when the server advertises it,
        /// else PLAIN), 1 = PLAIN, 2 = EXTERNAL. Out-of-range ids fall back
        /// to 0 (auto).
        #[qinvokable]
        fn set_sasl_mechanism(self: Pin<&mut Self>, mechanism: i32);

        /// Set the IRC `PASS` password for the next connection. Must be
        /// called BEFORE `connect_server`, which snapshots it into the
        /// session config (same contract as `set_sasl_mechanism`).
        ///
        /// Session-only secret: held in memory, never persisted, never logged
        /// (`PASS` is redacted by the engine's log path), and cleared as soon
        /// as the session is torn down. An empty string disables `PASS`.
        #[qinvokable]
        fn set_server_password(self: Pin<&mut Self>, password: QString);

        /// Whether to answer an incoming CTCP VERSION request with
        /// `NOTICE <nick> :\x01VERSION kIRC <version>\x01`. Must be called
        /// BEFORE `connect_server`, which snapshots it into the session
        /// config (same contract as `set_sasl_mechanism`), so a reconnect
        /// after changing it uses the new value. Defaults to `true`.
        ///
        /// Privacy-relevant: answering reveals the client's name and its
        /// exact version to anyone who asks. Only VERSION is gated — CTCP
        /// PING, TIME and CLIENTINFO are answered regardless of this switch.
        /// A CTCP that arrives inside a NOTICE is never answered either way.
        #[qinvokable]
        fn set_ctcp_version_reply(self: Pin<&mut Self>, enabled: bool);

        /// Start a new IRC session (replacing any existing one).
        #[qinvokable]
        fn connect_server(
            self: Pin<&mut Self>,
            host: QString,
            port: i32,
            tls: bool,
            nickname: QString,
            sasl_user: QString,
            sasl_pass: QString,
        );

        /// Tear down the current IRC session.
        #[qinvokable]
        fn disconnect_server(self: Pin<&mut Self>);

        /// Send a PRIVMSG to `target`.
        #[qinvokable]
        fn send_message(self: Pin<&mut Self>, target: QString, text: QString);

        /// Send a raw IRC line (no CR/LF).
        #[qinvokable]
        fn send_raw(self: Pin<&mut Self>, line: QString);

        /// Drop the local history for `target`.
        #[qinvokable]
        fn clear_buffer(self: Pin<&mut Self>, target: QString);

        /// Zero the unread badge. QML calls this when a channel is opened.
        #[qinvokable]
        fn mark_read(self: Pin<&mut Self>);

        /// Join a channel.
        #[qinvokable]
        fn join_channel(self: Pin<&mut Self>, channel: QString);

        /// Leave a channel.
        #[qinvokable]
        fn part_channel(self: Pin<&mut Self>, channel: QString);

        /// Space-separated nick list for `channel` (prefixes kept).
        #[qinvokable]
        fn nicks_for(self: &Self, channel: QString) -> QString;

        /// Current topic for `channel`.
        #[qinvokable]
        fn topic_for(self: &Self, channel: QString) -> QString;

        /// Ask the server for scrollback for `target`.
        #[qinvokable]
        fn request_history(self: Pin<&mut Self>, target: QString, limit: i32);
    }

    // Gives us `qt_thread()` / `update_requester()` so background tasks can
    // hop back onto this QObject's thread.
    impl cxx_qt::Threading for IrcBridge {}

    // -----------------------------------------------------------------------
    // MessageListModel
    // -----------------------------------------------------------------------

    extern "RustQt" {
        #[qobject]
        #[base = QAbstractListModel]
        #[qml_element]
        type MessageListModel = super::MessageListModelRust;

        /// Drop every row and load the buffered messages for `target`.
        #[qinvokable]
        fn load_channel(self: Pin<&mut Self>, target: QString);

        /// Append one row, but only if it belongs to the currently loaded
        /// channel.  QML calls this from `IrcBridge.onMessageReceived`.
        #[qinvokable]
        fn append_message(
            self: Pin<&mut Self>,
            target: QString,
            nick: QString,
            text: QString,
            timestamp: QString,
            is_self: bool,
            is_highlight: bool,
        );

        /// Empty the model.
        #[qinvokable]
        fn clear(self: Pin<&mut Self>);

        // QAbstractListModel overrides -------------------------------------
        /// `QVariant MessageListModel::data(const QModelIndex&, int) const`
        #[qinvokable]
        #[cxx_override]
        #[cxx_name = "data"]
        fn data(self: &MessageListModel, index: &QModelIndex, role: i32) -> QVariant;

        /// `int MessageListModel::rowCount(const QModelIndex&) const`
        #[qinvokable]
        #[cxx_override]
        #[cxx_name = "rowCount"]
        fn row_count_as_int(self: &MessageListModel, parent: &QModelIndex) -> i32;

        /// `QHash<int, QByteArray> MessageListModel::roleNames() const`
        #[qinvokable]
        #[cxx_override]
        #[cxx_name = "roleNames"]
        fn role_names(self: &MessageListModel) -> QHash_i32_QByteArray;
    }

    // Inherited QAbstractItemModel notifications.  See
    // https://kdab.github.io/cxx-qt/book/concepts/inheritance.html
    extern "RustQt" {
        /// # Safety
        ///
        /// Inherited `beginInsertRows` from the base class.  If you call
        /// `begin_insert_rows` you must guarantee `end_insert_rows` is called.
        #[inherit]
        #[cxx_name = "beginInsertRows"]
        unsafe fn begin_insert_rows(
            self: Pin<&mut MessageListModel>,
            parent: &QModelIndex,
            first: i32,
            last: i32,
        );

        /// # Safety
        ///
        /// Inherited `endInsertRows` from the base class.
        #[inherit]
        #[cxx_name = "endInsertRows"]
        unsafe fn end_insert_rows(self: Pin<&mut MessageListModel>);

        /// # Safety
        ///
        /// Inherited `beginRemoveRows` from the base class.  If you call
        /// `begin_remove_rows` you must guarantee `end_remove_rows` is called.
        #[inherit]
        #[cxx_name = "beginRemoveRows"]
        unsafe fn begin_remove_rows(
            self: Pin<&mut MessageListModel>,
            parent: &QModelIndex,
            first: i32,
            last: i32,
        );

        /// # Safety
        ///
        /// Inherited `endRemoveRows` from the base class.
        #[inherit]
        #[cxx_name = "endRemoveRows"]
        unsafe fn end_remove_rows(self: Pin<&mut MessageListModel>);

        /// # Safety
        ///
        /// Inherited `beginResetModel` from the base class.  If you call
        /// `begin_reset_model` you must guarantee `end_reset_model` is called.
        #[inherit]
        #[cxx_name = "beginResetModel"]
        unsafe fn begin_reset_model(self: Pin<&mut MessageListModel>);

        /// # Safety
        ///
        /// Inherited `endResetModel` from the base class.
        #[inherit]
        #[cxx_name = "endResetModel"]
        unsafe fn end_reset_model(self: Pin<&mut MessageListModel>);
    }
}

// ===========================================================================
// Backing Rust structs
// ===========================================================================

impl Default for qobject::ConnectionStatus {
    fn default() -> Self {
        Self::Disconnected
    }
}

/// Inner storage of `IrcBridge`.
pub struct IrcBridgeRust {
    /// Q_PROPERTY connectionState
    connection_state: qobject::ConnectionStatus,
    /// Q_PROPERTY unreadCount
    unread_count: i32,
    /// Q_PROPERTY nickname
    nickname: QString,
    /// Q_PROPERTY connectedServer
    connected_server: QString,
    /// Q_PROPERTY historyTarget
    history_target: QString,

    /// Sender half of the command channel for the live session.
    command_tx: Option<tokio::sync::mpsc::Sender<ClientCommand>>,
    /// Handle of the running `run_session` task, if any.
    session: Option<tokio::task::JoinHandle<()>>,
    /// SASL mechanism id selected via `set_sasl_mechanism`, snapshotted by
    /// the next `connect_server` call: 0 = auto (SCRAM-SHA-256 when the
    /// server advertises it, else PLAIN), 1 = PLAIN, 2 = EXTERNAL.
    sasl_mechanism: i32,
    /// IRC `PASS` password for the next connection (`set_server_password`).
    ///
    /// Memory only: never written to any settings store, never logged, and
    /// nulled as soon as the session is torn down. `None` sends no `PASS`.
    server_password: Option<String>,
    /// Whether to answer an incoming CTCP VERSION request
    /// (`set_ctcp_version_reply`); snapshotted by `connect_server` into the
    /// session config. Defaults to `true`. Only VERSION is gated: CTCP
    /// PING/TIME/CLIENTINFO are answered regardless.
    ctcp_version_reply: bool,
    /// Monotonic id of the session whose events may still be applied.
    ///
    /// Bumped by `connect_server` / `disconnect_server`; the event pump and
    /// the session task of an older epoch compare it and drop what they
    /// carry. Without this, a `Disconnected` that the *replaced* session had
    /// already queued can land after the new session's `Connecting` /
    /// `Registered` — flipping the UI back to Disconnected and wiping the new
    /// session's buffers through `clear_all_stores`.
    session_epoch: u64,
}

impl Default for IrcBridgeRust {
    fn default() -> Self {
        Self {
            connection_state: qobject::ConnectionStatus::Disconnected,
            unread_count: 0,
            nickname: QString::default(),
            connected_server: QString::default(),
            history_target: QString::default(),
            command_tx: None,
            session: None,
            sasl_mechanism: 0,
            server_password: None,
            ctcp_version_reply: true,
            session_epoch: 0,
        }
    }
}

/// Inner storage of `MessageListModel`.
pub struct MessageListModelRust {
    rows: Vec<StoreMsg>,
    target: String,
}

impl Default for MessageListModelRust {
    fn default() -> Self {
        Self {
            rows: Vec::new(),
            target: String::new(),
        }
    }
}

// ===========================================================================
// IrcEvent -> Qt bridge
// ===========================================================================

/// Target key of the persistent server-console buffer in [`STORE`].
///
/// Informational lines (MOTD, numerics, joins/parts, notices) used to surface
/// as transient passive popups; they now live in a real, scrollable buffer the
/// user can select like a channel.
pub const SERVER_BUFFER: &str = "*server*";

/// Append one informational line to the server-console buffer and notify the
/// UI through the regular `message_received` path (a page showing the buffer
/// reloads; no popup, no unread badge inflation).
fn info_to_store(obj: Pin<&mut qobject::IrcBridge>, text: &str) {
    push_console_line(obj, text, false);
}

/// A console line that arrived as a NOTICE (server-wide notices): the
/// `isNotice` role's source on the console path.
fn notice_to_store(obj: Pin<&mut qobject::IrcBridge>, text: &str) {
    push_console_line(obj, text, true);
}

fn push_console_line(mut obj: Pin<&mut qobject::IrcBridge>, text: &str, is_notice: bool) {
    // One clock read: the buffered row and the announced line must carry the
    // same stamp, or a later `load_channel` reload would show a different time
    // than the live insert did.
    let stamp = now_string();
    {
        let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
        guard
            .entry(SERVER_BUFFER.to_owned())
            .or_default()
            .push(
                StoreMsg::new(
                    "*".to_owned(),
                    text.to_owned(),
                    stamp.clone(),
                    false,
                    false,
                    Some(now_day()),
                )
                .arrival(SERVER_BUFFER, is_notice, false),
            );
    }
    obj.as_mut().message_received(
        qs(SERVER_BUFFER),
        qs("*"),
        qs(text),
        qs(&stamp),
        false,
        false,
    );
}

fn push_channel_line(mut obj: Pin<&mut qobject::IrcBridge>, channel: &str, text: &str) {
    // One lock and one fold for both the append and the signal (this used to
    // take the store lock twice and scan the keys twice per line), and one
    // clock read so the store row and the announced line agree.
    let stamp = now_string();
    let key = {
        let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
        let key = canon_map_key(&guard, channel);
        guard
            .entry(key.clone())
            .or_default()
            .push(
                StoreMsg::new(
                    "*".to_owned(),
                    text.to_owned(),
                    stamp.clone(),
                    false,
                    false,
                    Some(now_day()),
                )
                .arrival(&key, false, false),
            );
        key
    };
    obj.as_mut().message_received(
        qs(&key),
        qs("*"),
        qs(text),
        qs(&stamp),
        false,
        false,
    );
}

/// The buffer a command reply is filed in: the one the user is currently
/// looking at, or the server console when no buffer is visible (during
/// registration, for instance).
///
/// The reply NEVER gets a buffer of its own — in particular it must not open
/// a query window for the nick the command was about (`/whois alice` renders
/// where the user typed it, not in a chat with alice).
fn command_reply_key(visible: &str) -> String {
    if visible.is_empty() {
        SERVER_BUFFER.to_owned()
    } else {
        visible.to_owned()
    }
}

/// True when the user is already looking at `target` (case-insensitive).
fn is_visible_target(target: &str) -> bool {
    visible_target()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .eq_ignore_ascii_case(target)
}

/// Bump unread for `target` unless it is the visible buffer / console.
fn bump_unread_for(mut obj: Pin<&mut qobject::IrcBridge>, target: &str, is_self: bool) {
    if is_self || is_visible_target(target) || target == SERVER_BUFFER {
        return;
    }
    let unread = *obj.as_ref().unread_count();
    obj.as_mut().set_unread_count(unread.saturating_add(1));
}

fn add_nick(channel: &str, nick: &str) {
    let mut guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
    let key = canon_map_key(&guard, channel);
    let list = guard.entry(key).or_default();
    if !list
        .iter()
        .any(|n| bare_nick(n).eq_ignore_ascii_case(bare_nick(nick)))
    {
        list.push(nick.to_owned());
        list.sort_by(|a, b| bare_nick(a).to_lowercase().cmp(&bare_nick(b).to_lowercase()));
    }
}

fn remove_nick(channel: &str, nick: &str) -> bool {
    let mut guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
    let key = canon_map_key(&guard, channel);
    if let Some(list) = guard.get_mut(&key) {
        let before = list.len();
        list.retain(|n| !bare_nick(n).eq_ignore_ascii_case(bare_nick(nick)));
        return list.len() != before;
    }
    false
}

/// Remove the whole nick list for `channel` (case-folded key lookup).
fn drop_nick_store(channel: &str) {
    let mut guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
    let key = canon_map_key(&guard, channel);
    guard.remove(&key);
}

fn emit_names(obj: Pin<&mut qobject::IrcBridge>, channel: &str) {
    let (key, joined) = {
        let guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
        let key = canon_map_key(&guard, channel);
        let joined = guard
            .get(&key)
            .map(|n| n.join(" "))
            .unwrap_or_default();
        (key, joined)
    };
    obj.names_updated(qs(&key), qs(&joined));
}

/// Apply one `IrcEvent` to `IrcBridge`.  Always called on the Qt thread.
fn handle_event(mut obj: Pin<&mut qobject::IrcBridge>, event: IrcEvent) {
    match event {
        IrcEvent::StateConnecting => {
            obj.as_mut()
                .set_connection_state(qobject::ConnectionStatus::Connecting);
            obj.as_mut()
                .state_changed(qobject::ConnectionStatus::Connecting.repr);
        }

        IrcEvent::Registered { server_name } => {
            obj.as_mut().set_connected_server(qs(&server_name));
            obj.as_mut()
                .set_connection_state(qobject::ConnectionStatus::Connected);
            obj.as_mut()
                .state_changed(qobject::ConnectionStatus::Connected.repr);
            info_to_store(obj.as_mut(), &format!("Connected to {server_name}"));
        }

        IrcEvent::Disconnected { reason } => {
            // A dead server's logs must not leak into the next one. The
            // disconnect line below (if any) becomes the only console row.
            clear_all_stores();
            obj.as_mut()
                .set_connection_state(qobject::ConnectionStatus::Disconnected);
            obj.as_mut()
                .state_changed(qobject::ConnectionStatus::Disconnected.repr);
            if !reason.is_empty() {
                info_to_store(obj.as_mut(), &format!("Disconnected: {reason}"));
            }
        }

        IrcEvent::Msg {
            target,
            nick,
            text,
            timestamp,
            is_self,
            is_highlight,
            is_notice,
            is_action,
        } => {
            if text.trim().is_empty() {
                return;
            }
            // Format the stamp once — the STORE row and the QML row must show
            // the identical string (a second `now_string()` could tick over).
            let (stamp, day) = fmt_timestamp(timestamp);
            // One lock, one fold: append to the buffer and keep the folded key
            // for the signal (this used to take the store lock twice per line).
            let target = {
                let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
                let key = canon_key(&guard, &target);
                guard
                    .entry(key.clone())
                    .or_default()
                    .push(
                        StoreMsg::new(
                            nick.clone(),
                            text.clone(),
                            stamp.clone(),
                            is_self,
                            is_highlight,
                            day,
                        )
                        .arrival(&key, is_notice, is_action),
                    );
                key
            };

            bump_unread_for(obj.as_mut(), &target, is_self);

            obj.as_mut().message_received(
                qs(&target),
                qs(&nick),
                qs(&text),
                qs(&stamp),
                is_self,
                is_highlight,
            );

            if is_highlight && !is_self {
                obj.as_mut()
                    .notification_fired(qs(&nick), qs(&text));
            }
            if !is_channel(&target) && target != SERVER_BUFFER {
                obj.as_mut().query_opened(qs(&target));
            }
        }

        IrcEvent::CommandReply { text } => {
            // Text that answers a command the user issued. It belongs in the
            // buffer they are looking at right now; with no buffer visible
            // yet (during registration, say) it falls back to the server
            // console. Crucially it never opens a query window, never bumps
            // unread, and never creates a buffer of its own — a `/whois`
            // reply renders right where the user typed the command.
            if text.trim().is_empty() {
                return;
            }
            let stamp = now_string();
            let target = {
                let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
                let visible = visible_target().lock().unwrap_or_else(|e| e.into_inner()).clone();
                // Fold onto the key the UI actually opened, so the reply
                // lands in the buffer the user sees even when its case
                // differs from what the session reported.
                let key = canon_map_key(&guard, &command_reply_key(&visible));
                guard
                    .entry(key.clone())
                    .or_default()
                    .push(
                        StoreMsg::new(
                            "*".to_owned(),
                            text.clone(),
                            stamp.clone(),
                            false,
                            false,
                            Some(now_day()),
                        )
                        .arrival(&key, false, false),
                    );
                key
            };

            obj.as_mut().message_received(
                qs(&target),
                qs("*"),
                qs(&text),
                qs(&stamp),
                false,
                false,
            );
        }

        IrcEvent::HistoryBatch { messages } => {
            // Scrollback is older than whatever is buffered live, so it goes
            // in FRONT (oldest first). `history_target` records which buffer
            // the batch was requested for.
            let target = {
                let requested = rs(obj.as_ref().history_target());
                let guard = store().lock().unwrap_or_else(|e| e.into_inner());
                canon_map_key(&guard, &requested)
            };
            {
                let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
                let key = canon_map_key(&guard, &target);
                let rows: Vec<StoreMsg> = messages
                    .into_iter()
                    .map(|msg| {
                        let (timestamp, day) = fmt_timestamp(msg.timestamp);
                        StoreMsg::new(msg.nick, msg.text, timestamp, false, false, day)
                            .arrival(&key, false, false)
                    })
                    .collect();
                let entry = guard.entry(key).or_default();
                entry.splice(..0, rows);
            }
            obj.as_mut().history_batch_received(qs(&target));
        }

        IrcEvent::Notice { nick, text } => {
            notice_to_store(obj.as_mut(), &format!("-{nick}- {text}"));
        }

        IrcEvent::Join {
            channel,
            nick,
            account,
            is_self,
        } => {
            let suffix = account
                .as_deref()
                .map(|a| format!(" ({a})"))
                .unwrap_or_default();
            let line = if is_self {
                format!("You joined {channel}")
            } else {
                format!("{nick}{suffix} joined {channel}")
            };
            push_channel_line(obj.as_mut(), &channel, &line);
            if is_self {
                obj.as_mut().channel_joined(qs(&channel));
            } else {
                add_nick(&channel, &nick);
                emit_names(obj.as_mut(), &channel);
            }
        }

        IrcEvent::Part { channel, nick } => {
            let ours = rs(obj.as_ref().nickname());
            let is_self = nick.eq_ignore_ascii_case(&ours);
            let line = if is_self {
                format!("You left {channel}")
            } else {
                format!("{nick} left {channel}")
            };
            push_channel_line(obj.as_mut(), &channel, &line);
            if is_self {
                drop_nick_store(&channel);
                obj.as_mut().channel_parted(qs(&channel));
            } else {
                remove_nick(&channel, &nick);
                emit_names(obj.as_mut(), &channel);
            }
        }

        IrcEvent::Kick {
            channel,
            nick,
            kicker,
            reason,
            is_self,
        } => {
            let line = if reason.trim().is_empty() {
                format!("{kicker} kicked {nick}")
            } else {
                format!("{kicker} kicked {nick} ({reason})")
            };
            push_channel_line(obj.as_mut(), &channel, &line);
            if is_self {
                drop_nick_store(&channel);
                obj.as_mut().channel_parted(qs(&channel));
            } else {
                remove_nick(&channel, &nick);
                emit_names(obj.as_mut(), &channel);
            }
        }

        IrcEvent::Mode { target, modes } => {
            let line = format!("mode {modes} on {target}");
            if is_channel(&target) {
                push_channel_line(obj.as_mut(), &target, &line);
            } else {
                info_to_store(obj.as_mut(), &line);
            }
        }

        IrcEvent::NickRename { old, new, is_self } => {
            if is_self {
                obj.as_mut().set_nickname(qs(&new));
            }
            // A rename is not a quit: keep the user in every channel they
            // share with us, preserving their op/voice prefix where present.
            let channels = {
                let guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
                guard.keys().cloned().collect::<Vec<_>>()
            };
            for channel in channels {
                let renamed = {
                    let mut guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
                    let key = canon_map_key(&guard, &channel);
                    match guard.get_mut(&key) {
                        Some(list) => {
                            let mut hit = false;
                            for entry in list.iter_mut() {
                                if bare_nick(entry).eq_ignore_ascii_case(&old) {
                                    let prefix: String = entry
                                        .chars()
                                        .take_while(|c| {
                                            matches!(c, '@' | '+' | '%' | '~' | '&')
                                        })
                                        .collect();
                                    *entry = format!("{prefix}{new}");
                                    hit = true;
                                }
                            }
                            if hit {
                                list.sort_by(|a, b| {
                                    bare_nick(a)
                                        .to_lowercase()
                                        .cmp(&bare_nick(b).to_lowercase())
                                });
                            }
                            hit
                        }
                        None => false,
                    }
                };
                if renamed {
                    push_channel_line(
                        obj.as_mut(),
                        &channel,
                        &format!("{old} is now {new}"),
                    );
                    emit_names(obj.as_mut(), &channel);
                }
            }
        }

        IrcEvent::Topic { channel, topic } => {
            let key = {
                let guard = topic_store().lock().unwrap_or_else(|e| e.into_inner());
                canon_map_key(&guard, &channel)
            };
            {
                let mut guard = topic_store().lock().unwrap_or_else(|e| e.into_inner());
                let key = canon_map_key(&guard, &key);
                guard.insert(key.clone(), topic.clone());
            }
            push_channel_line(
                obj.as_mut(),
                &channel,
                &format!("Topic for {channel}: {topic}"),
            );
            // Folded key: QML compares with strict `===` against currentChannel.
            obj.as_mut().topic_changed(qs(&key), qs(&topic));
        }

        IrcEvent::Names { channel, nicks } => {
            {
                let mut guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
                let key = canon_map_key(&guard, &channel);
                guard.insert(key, nicks.clone());
            }
            emit_names(obj.as_mut(), &channel);
        }

        IrcEvent::JoinFailed { channel, reason } => {
            info_to_store(obj.as_mut(), &reason);
            obj.as_mut().join_failed(qs(&channel), qs(&reason));
        }

        IrcEvent::Quit { nick, reason } => {
            let channels = {
                let guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
                guard.keys().cloned().collect::<Vec<_>>()
            };
            for channel in channels {
                if remove_nick(&channel, &nick) {
                    push_channel_line(
                        obj.as_mut(),
                        &channel,
                        &format!("{nick} quit ({reason})"),
                    );
                    emit_names(obj.as_mut(), &channel);
                }
            }
        }

        IrcEvent::Info { text } => {
            info_to_store(obj.as_mut(), &text);
        }

        IrcEvent::Error { message } => {
            obj.as_mut().error_occurred(qs(&message));
        }

        IrcEvent::NickChanged { nick } => {
            obj.as_mut().set_nickname(qs(&nick));
        }
    }
}

// ===========================================================================
// IrcBridge implementation
// ===========================================================================

impl qobject::IrcBridge {
    /// Select the SASL mechanism used by the NEXT `connect_server` call.
    ///
    /// 0 = auto: SCRAM-SHA-256 when the server advertises it, else PLAIN.
    /// 1 = PLAIN. 2 = EXTERNAL. Out-of-range values fall back to 0.
    ///
    /// Auto is resolved at connect time: the bridge inspects the server's
    /// `CAP LS` advertisement (`sasl=...` value) recorded in `CapState` and
    /// picks SCRAM-SHA-256 only when present, otherwise PLAIN. EXTERNAL is
    /// only attempted when the user explicitly selects it (2): it needs a
    /// TLS client certificate, so auto must never pick it.
    pub fn set_sasl_mechanism(mut self: Pin<&mut Self>, mechanism: i32) {
        let normalized = if (0..=2).contains(&mechanism) {
            mechanism
        } else {
            0
        };
        self.as_mut().rust_mut().sasl_mechanism = normalized;
    }

    /// Store the `PASS` password used by the NEXT `connect_server` call.
    ///
    /// Additive to the frozen bridge contract (same pattern as
    /// `set_sasl_mechanism`). The value is deliberately kept out of every
    /// persistent store and out of the log: it lives in this field until the
    /// connection supersedes it, and `shutdown_session` clears it on every
    /// disconnect. An empty string means "no PASS".
    pub fn set_server_password(mut self: Pin<&mut Self>, password: QString) {
        let password = rs(&password);
        self.as_mut().rust_mut().server_password = if password.is_empty() {
            None
        } else {
            Some(password)
        };
    }

    /// Allow or suppress the CTCP VERSION reply used by the NEXT
    /// `connect_server` call.
    ///
    /// Additive to the frozen bridge contract (same pattern as
    /// `set_sasl_mechanism`): the value is snapshotted into the session
    /// config, so it must be set before connecting and a reconnect picks up
    /// the latest value. `false` suppresses VERSION only — CTCP PING, TIME
    /// and CLIENTINFO are still answered, and a CTCP that arrived in a
    /// NOTICE is never answered regardless.
    pub fn set_ctcp_version_reply(mut self: Pin<&mut Self>, enabled: bool) {
        self.as_mut().rust_mut().ctcp_version_reply = enabled;
    }

    /// Invalidate every event the current session still has queued, and
    /// return the new epoch. See `IrcBridgeRust::session_epoch`.
    fn bump_session_epoch(mut self: Pin<&mut Self>) -> u64 {
        let mut rust = self.as_mut().rust_mut();
        rust.session_epoch = rust.session_epoch.wrapping_add(1);
        rust.session_epoch
    }

    /// Start a fresh IRC session, replacing any existing one.
    pub fn connect_server(
        mut self: Pin<&mut Self>,
        host: QString,
        port: i32,
        tls: bool,
        nickname: QString,
        sasl_user: QString,
        sasl_pass: QString,
    ) {
        // kirc-core installs the process-wide rustls crypto provider; doing it
        // again here is harmless *if* we tolerate the "already installed" error.
        let _ = rustls::crypto::ring::default_provider().install_default();

        // Read the server password BEFORE the teardown below, which clears
        // it: this connection owns the copy from here on.
        let server_password = self.rust().server_password.clone();

        // Drop the previous session and command channel first.
        self.as_mut().shutdown_session();
        // Whatever the replaced session still has queued is stale: bumping
        // the epoch makes the pump drop it instead of clobbering this one.
        let epoch = self.as_mut().bump_session_epoch();

        let host_s = rs(&host);
        let nick_s = rs(&nickname);
        let sasl_user_s = rs(&sasl_user);
        let sasl_pass_s = rs(&sasl_pass);

        // Snapshot the mechanism id chosen via set_sasl_mechanism (0 = auto).
        // The core resolves "auto" against the server's CAP LS advertisement
        // at SASL start, so auto needs no advertisement data here — just the
        // preference id plus the raw creds.
        let mechanism_id = self.rust().sasl_mechanism;
        // Snapshot the CTCP VERSION switch (default true) for the same reason.
        let ctcp_version_reply = self.rust().ctcp_version_reply;
        let mechanism = match mechanism_id {
            1 => SaslMechanism::Plain,
            2 => SaslMechanism::External,
            // Auto: pick SCRAM-SHA-256 when the server offers it, else PLAIN.
            // The core re-resolves this against the live CAP LS at SASL
            // start (see Session::start_sasl); defaulting the snapshot to
            // SCRAM-SHA-256 is safe because the core overrides it when the
            // advertisement lacks SCRAM.
            _ => SaslMechanism::ScramSha256,
        };

        let sasl = if sasl_user_s.is_empty() {
            None
        } else {
            Some(SaslConfig {
                mechanism,
                username: sasl_user_s,
                password: sasl_pass_s,
            })
        };

        let config = ConnectionConfig {
            host: host_s.clone(),
            port: port.clamp(0, u16::MAX as i32) as u16,
            tls,
            nickname: nick_s.clone(),
            username: nick_s.clone(),
            realname: nick_s.clone(),
            server_password,
            sasl,
            sasl_mechanism: mechanism_id,
            ctcp_version_reply,
            request_caps: Vec::new(),
        };

        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<IrcEvent>(512);
        let (command_tx, command_rx) = tokio::sync::mpsc::channel::<ClientCommand>(128);

        self.as_mut().set_nickname(nickname);
        self.as_mut()
            .set_connected_server(qs(&format!("{host_s}:{port}")));
        self.as_mut().set_unread_count(0);
        self.as_mut().set_history_target(QString::default());
        // A new server must not inherit the old one's logs, nicks or topics.
        clear_all_stores();
        self.as_mut()
            .set_connection_state(qobject::ConnectionStatus::Connecting);
        self.as_mut()
            .state_changed(qobject::ConnectionStatus::Connecting.repr);

        let qt_thread = self.qt_thread();

        // ---- event pump: tokio -> Qt thread -----------------------------
        let qt_thread_events = qt_thread.clone();
        runtime().spawn(async move {
            while let Some(event) = event_rx.recv().await {
                let queued = qt_thread_events.queue(move |mut qobject| {
                    // An event from a session that has since been replaced is
                    // dropped: it would otherwise undo the new session's
                    // state and clear its buffers.
                    if qobject.as_ref().rust().session_epoch != epoch {
                        return;
                    }
                    handle_event(qobject.as_mut(), event);
                });
                if queued.is_err() {
                    // The QObject is gone; stop pumping.
                    break;
                }
            }
        });

        // ---- the session itself -----------------------------------------
        let qt_thread_session = qt_thread.clone();
        let session = runtime().spawn(async move {
            if let Err(err) = kirc_core::run_session(config, event_tx, command_rx).await {
                let message = format!("IRC session ended: {err}");
                let _ = qt_thread_session.queue(move |mut qobject| {
                    // Same epoch rule as the event pump: a replaced session's
                    // failure must not touch the new session's UI state.
                    if qobject.as_ref().rust().session_epoch != epoch {
                        return;
                    }
                    qobject
                        .as_mut()
                        .set_connection_state(qobject::ConnectionStatus::Disconnected);
                    qobject
                        .as_mut()
                        .state_changed(qobject::ConnectionStatus::Disconnected.repr);
                    qobject.as_mut().error_occurred(qs(&message));
                });
            }
        });

        let mut rust = self.as_mut().rust_mut();
        rust.command_tx = Some(command_tx);
        rust.session = Some(session);
    }

    /// Tear down the current IRC session.
    pub fn disconnect_server(mut self: Pin<&mut Self>) {
        self.as_mut().shutdown_session();
        // No straggler event from the session being torn down may touch the
        // UI after this point: the state set below is the final word.
        self.as_mut().bump_session_epoch();
        // Forget the old server's logs outright; the Disconnected handler's
        // console line (if any) is added after its own clear.
        clear_all_stores();
        self.as_mut().set_unread_count(0);
        self.as_mut().set_history_target(QString::default());
        self.as_mut()
            .set_connection_state(qobject::ConnectionStatus::Disconnected);
        self.as_mut()
            .state_changed(qobject::ConnectionStatus::Disconnected.repr);
    }

    /// Internal: ask the session to quit, then kill it.
    ///
    /// A graceful QUIT is attempted first so a live server connection drops the
    /// nick. The JoinHandle is then aborted so a handshake stuck in `connect()`
    /// (or an unregistered 433 wait) cannot pin the UI in Connecting.
    fn shutdown_session(mut self: Pin<&mut Self>) {
        let mut rust = self.as_mut().rust_mut();
        // A server password never outlives the session it was set for. The
        // value handed to `connect_server` is snapshotted before this runs.
        rust.server_password = None;
        if let Some(tx) = rust.command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Quit);
        }
        rust.command_tx = None;
        if let Some(handle) = rust.session.take() {
            handle.abort();
        }
    }

    /// Send a PRIVMSG. Local echo is the engine's job when the server did not
    /// ACK `echo-message`; with echo-message we wait for the replay so the
    /// line is not shown twice (the NickServ "help" duplication).
    pub fn send_message(self: Pin<&mut Self>, target: QString, text: QString) {
        let mut target_s = rs(&target);
        {
            let guard = store().lock().unwrap_or_else(|e| e.into_inner());
            target_s = canon_key(&guard, &target_s);
        }
        let text_s = rs(&text);
        if let Some(tx) = self.rust().command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Privmsg {
                target: target_s,
                text: text_s,
            });
        }
    }

    /// Send a raw protocol line.
    pub fn send_raw(self: Pin<&mut Self>, line: QString) {
        if let Some(tx) = self.rust().command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Raw(rs(&line)));
        }
    }

    /// Forget the local transcript of `target`.
    pub fn clear_buffer(self: Pin<&mut Self>, target: QString) {
        let target_s = rs(&target);
        let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
        let key = canon_map_key(&guard, &target_s);
        guard.remove(&key);
    }

    /// Zero the unread badge. QML calls this when a channel is opened.
    pub fn mark_read(mut self: Pin<&mut Self>) {
        self.as_mut().set_unread_count(0);
    }

    /// Join a channel.
    pub fn join_channel(self: Pin<&mut Self>, channel: QString) {
        if let Some(tx) = self.rust().command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Join(rs(&channel)));
        }
    }

    /// Leave a channel.
    pub fn part_channel(self: Pin<&mut Self>, channel: QString) {
        if let Some(tx) = self.rust().command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Part {
                channel: rs(&channel),
                reason: None,
            });
        }
    }

    pub fn nicks_for(self: &Self, channel: QString) -> QString {
        let channel_s = rs(&channel);
        let joined = {
            let guard = nick_store().lock().unwrap_or_else(|e| e.into_inner());
            let key = canon_map_key(&guard, &channel_s);
            guard
                .get(&key)
                .map(|n| n.join(" "))
                .unwrap_or_default()
        };
        qs(&joined)
    }

    pub fn topic_for(self: &Self, channel: QString) -> QString {
        let channel_s = rs(&channel);
        let topic = {
            let guard = topic_store().lock().unwrap_or_else(|e| e.into_inner());
            let key = canon_map_key(&guard, &channel_s);
            guard.get(&key).cloned().unwrap_or_default()
        };
        qs(&topic)
    }

    /// Ask the server for scrollback.
    pub fn request_history(mut self: Pin<&mut Self>, target: QString, limit: i32) {
        let target_s = rs(&target);
        self.as_mut().set_history_target(qs(&target_s));

        if let Some(tx) = self.as_ref().rust().command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::RequestHistory {
                target: target_s,
                limit: limit.max(0) as u32,
            });
        }
    }
}

// ===========================================================================
// MessageListModel implementation
// ===========================================================================

impl qobject::MessageListModel {
    /// Replace the model contents with the buffered messages of `target`.
    ///
    /// The rows' derived presentation flags (`isEvent`/`showDay`/`dayLabel`)
    /// are computed here in a single pass over the buffer.
    pub fn load_channel(mut self: Pin<&mut Self>, target: QString) {
        let target_s = rs(&target);
        let (key, mut rows) = {
            let guard = store().lock().unwrap_or_else(|e| e.into_inner());
            let key = canon_key(&guard, &target_s);
            let rows = guard.get(&key).cloned().unwrap_or_default();
            (key, rows)
        };
        derive_rows(&mut rows);
        // Remember which buffer the user is viewing (folded key) so incoming
        // lines for it do not inflate the unread badge.
        *visible_target()
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = key.clone();

        unsafe {
            self.as_mut().begin_reset_model();
        }
        {
            let mut rust = self.as_mut().rust_mut();
            rust.rows = rows;
            rust.target = key;
        }
        unsafe {
            self.as_mut().end_reset_model();
        }
    }

    /// Append a row if `target` is the channel currently loaded.
    ///
    /// This is the fast path for live traffic: exactly one `rowsInserted` per
    /// message, never a model reset — a busy channel must not rebuild its
    /// whole log (and every delegate) per line.  A `target` that does not
    /// match the loaded buffer (ASCII case-insensitive), including any call
    /// before the first `load_channel`, is a silent no-op.
    ///
    /// The row's derived flags are computed in O(1): `showDay`/`dayLabel` come
    /// from comparing the new row against the previous row already in the
    /// buffer. The live signal only carries the preformatted "HH:MM" stamp
    /// (which has no date), so the row's calendar day is read from the STORE
    /// row the bridge appended just before announcing it — the same buffer
    /// `load_channel` serves from, so both paths agree.
    pub fn append_message(
        mut self: Pin<&mut Self>,
        target: QString,
        nick: QString,
        text: QString,
        timestamp: QString,
        is_self: bool,
        is_highlight: bool,
    ) {
        let target_s = rs(&target);
        // Case-insensitive match: the store key (`#Kirc`) and the announced
        // target (`#kirc`) may differ only by case.  Nothing is loaded while
        // `target` is empty, so an empty-loaded model takes no rows either.
        let matches_loaded = {
            let this = self.as_ref();
            let loaded = &this.rust().target;
            !loaded.is_empty() && target_s.eq_ignore_ascii_case(loaded)
        };
        if !matches_loaded {
            return;
        }

        let loaded_key = self.as_ref().rust().target.clone();
        // The live signal carries only the display payload; the row's other
        // raw facts — its calendar `day`, and the `isPrivate`/`isNotice`/
        // `isAction` arrival flags — are read from the STORE row the bridge
        // appended just before announcing this line. That is the same row
        // `load_channel` would serve, so both paths agree.
        let (day, is_private, is_notice, is_action) = {
            let guard = store().lock().unwrap_or_else(|e| e.into_inner());
            guard
                .get(&loaded_key)
                .and_then(|rows| rows.last())
                .map(|row| (row.day, row.is_private, row.is_notice, row.is_action))
                .unwrap_or((None, false, false, false))
        };

        let mut row = StoreMsg::new(
            rs(&nick),
            rs(&text),
            rs(&timestamp),
            is_self,
            is_highlight,
            day,
        );
        row.is_private = is_private;
        row.is_notice = is_notice;
        row.is_action = is_action;
        let prev_day = self.as_ref().rust().rows.last().and_then(|prev| prev.day);
        derive_row(prev_day, &mut row);

        // Insert at the end.  When the model is empty (or was just reset by a
        // `load_channel`) this is row 0 and still a plain insert — no reset.
        let first = self.as_ref().rust().rows.len() as i32;
        unsafe {
            self.as_mut()
                .begin_insert_rows(&QModelIndex::default(), first, first);
        }
        self.as_mut().rust_mut().rows.push(row);
        unsafe {
            self.as_mut().end_insert_rows();
        }
    }

    /// Empty the model.
    pub fn clear(mut self: Pin<&mut Self>) {
        unsafe {
            self.as_mut().begin_reset_model();
        }
        self.as_mut().rust_mut().rows.clear();
        unsafe {
            self.as_mut().end_reset_model();
        }
    }

    /// `QAbstractListModel::data()`
    pub fn data(&self, index: &QModelIndex, role: i32) -> QVariant {
        let role = qobject::Roles { repr: role };
        let Some(row) = self.rust().rows.get(index.row() as usize) else {
            return QVariant::default();
        };

        match role {
            qobject::Roles::Nick => {
                let value = qs(&row.nick);
                QVariant::from(&value)
            }
            qobject::Roles::Text => {
                let value = qs(&row.text);
                QVariant::from(&value)
            }
            qobject::Roles::Timestamp => {
                let value = qs(&row.timestamp);
                QVariant::from(&value)
            }
            qobject::Roles::IsSelf => QVariant::from(&row.is_self),
            qobject::Roles::IsHighlight => QVariant::from(&row.is_highlight),
            qobject::Roles::IsEvent => QVariant::from(&row.is_event),
            qobject::Roles::IsError => QVariant::from(&row.is_error),
            qobject::Roles::IsPrivate => QVariant::from(&row.is_private),
            qobject::Roles::IsNotice => QVariant::from(&row.is_notice),
            qobject::Roles::IsAction => QVariant::from(&row.is_action),
            qobject::Roles::ShowDay => QVariant::from(&row.show_day),
            qobject::Roles::DayLabel => {
                let value = qs(&row.day_label);
                QVariant::from(&value)
            }
            _ => QVariant::default(),
        }
    }

    /// `QAbstractListModel::rowCount()`
    pub fn row_count_as_int(&self, _parent: &QModelIndex) -> i32 {
        self.rust().rows.len() as i32
    }

    /// `QAbstractListModel::roleNames()`
    pub fn role_names(&self) -> QHash<QHashPair_i32_QByteArray> {
        let mut roles = QHash::<QHashPair_i32_QByteArray>::default();
        roles.insert(qobject::Roles::Nick.repr, QByteArray::from("nick"));
        roles.insert(qobject::Roles::Text.repr, QByteArray::from("text"));
        roles.insert(
            qobject::Roles::Timestamp.repr,
            QByteArray::from("timestamp"),
        );
        roles.insert(qobject::Roles::IsSelf.repr, QByteArray::from("isSelf"));
        roles.insert(
            qobject::Roles::IsHighlight.repr,
            QByteArray::from("isHighlight"),
        );
        roles.insert(qobject::Roles::IsEvent.repr, QByteArray::from("isEvent"));
        roles.insert(qobject::Roles::IsError.repr, QByteArray::from("isError"));
        roles.insert(qobject::Roles::ShowDay.repr, QByteArray::from("showDay"));
        roles.insert(qobject::Roles::DayLabel.repr, QByteArray::from("dayLabel"));
        roles.insert(
            qobject::Roles::IsPrivate.repr,
            QByteArray::from("isPrivate"),
        );
        roles.insert(qobject::Roles::IsNotice.repr, QByteArray::from("isNotice"));
        roles.insert(qobject::Roles::IsAction.repr, QByteArray::from("isAction"));
        roles
    }
}

// ===========================================================================
// Derived-role unit tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn date(y: i32, m: u32, d: u32) -> Option<NaiveDate> {
        NaiveDate::from_ymd_opt(y, m, d)
    }

    fn row(nick: &str, day: Option<NaiveDate>) -> StoreMsg {
        StoreMsg::new(nick.to_owned(), "text".to_owned(), "12:00".to_owned(), false, false, day)
    }

    #[test]
    fn derive_rows_marks_day_sections() {
        let mut rows = vec![
            row("alice", date(2026, 9, 10)),
            row("*", date(2026, 9, 10)),
            row("bob", date(2026, 9, 11)),
            row("carol", date(2026, 9, 11)),
        ];
        derive_rows(&mut rows);

        // The first row has no predecessor: no day section.
        assert!(!rows[0].show_day);
        // Event rows are the synthesized `*` lines, on either day.
        assert!(!rows[0].is_event);
        assert!(rows[1].is_event);
        assert!(!rows[2].is_event);
        // The day rolls over exactly once, at the row whose date changed.
        assert!(!rows[1].show_day);
        assert!(rows[2].show_day);
        assert!(!rows[3].show_day);
        // Day labels are per-row, and every row carries one when parseable.
        assert!(!rows[2].day_label.is_empty());
    }

    #[test]
    fn day_labels_are_relative_to_today() {
        let today = date(2026, 9, 11).unwrap();
        assert_eq!(day_label_for(today, today), "Today");
        assert_eq!(day_label_for(today.pred_opt().unwrap(), today), "Yesterday");
        assert_eq!(day_label_for(date(2026, 9, 5).unwrap(), today), "Sep 5");
        assert_eq!(day_label_for(date(2026, 8, 31).unwrap(), today), "Aug 31");
        assert_eq!(day_label_for(date(2025, 12, 31).unwrap(), today), "Dec 31");
    }

    #[test]
    fn unparseable_timestamps_never_start_a_day() {
        let mut rows = vec![
            row("a", None),
            row("b", date(2026, 9, 10)),
            row("c", None),
            row("d", date(2026, 9, 11)),
            row("e", date(2026, 9, 11)),
            row("f", date(2026, 9, 12)),
        ];
        derive_rows(&mut rows);
        assert!(!rows[0].show_day); // nothing before it
        assert!(!rows[1].show_day); // predecessor had no parseable date
        assert!(!rows[2].show_day); // this row has no parseable date
        assert!(!rows[3].show_day); // predecessor (row "c") was unparseable
        assert!(!rows[4].show_day); // same day, both parseable
        assert!(rows[5].show_day); // 09-12 vs 09-11, both parseable
        assert!(rows[0].day_label.is_empty());
        assert!(rows[2].day_label.is_empty());
    }

    #[test]
    fn append_path_derives_from_previous_row_only() {
        // The O(1) append path: the new row's flags depend on its predecessor
        // and nothing else — same result as the batch pass above.
        let previous = row("alice", date(2026, 9, 10));
        let mut next = row("bob", date(2026, 9, 11));
        derive_row(previous.day, &mut next);
        assert!(next.show_day);
        assert!(!next.is_event);

        let mut event = row("*", date(2026, 9, 11));
        derive_row(date(2026, 9, 11), &mut event);
        assert!(event.is_event);
        assert!(!event.show_day);
    }

    #[test]
    fn nick_is_event_only_for_the_star_marker() {
        assert!(nick_is_event("*"));
        assert!(nick_is_event(" * "));
        assert!(!nick_is_event("bob"));
        assert!(!nick_is_event("*bob"));
        assert!(!nick_is_event(""));
    }

    fn row_text(nick: &str, text: &str) -> StoreMsg {
        StoreMsg::new(
            nick.to_owned(),
            text.to_owned(),
            "12:00".to_owned(),
            false,
            false,
            date(2026, 9, 11),
        )
    }

    #[test]
    fn failing_lines_are_classified_as_errors() {
        // Join failures — the user's "473 ... Cannot join channel (+i)".
        assert!(line_is_error("*", "403 #pain No such channel"));
        assert!(line_is_error("*", "405 #pain You have joined too many channels"));
        assert!(line_is_error("*", "437 #pain Cannot join channel (temporarily unavailable)"));
        assert!(line_is_error("*", "471 #pain Cannot join channel (+l)"));
        assert!(line_is_error("*", "473 #pain Cannot join channel (+i)"));
        assert!(line_is_error("*", "474 #pain Cannot join channel (+b)"));
        assert!(line_is_error("*", "475 #pain Cannot join channel (+k)"));
        assert!(line_is_error("*", "476 #pain Bad Channel Mask"));
        assert!(line_is_error("*", "477 #pain Cannot join channel (+r)"));
        assert!(line_is_error("*", "479 #pain Illegal channel name"));
        // Any other 4xx/5xx numeric.
        assert!(line_is_error("*", "401 ghost No such nick/channel"));
        assert!(line_is_error("*", "404 #pain Cannot send to channel"));
        assert!(line_is_error("*", "433 * alice :Nickname is already in use"));
        assert!(line_is_error("*", "500 Unknown command"));
        assert!(line_is_error("*", "599 Unknown error"));
        // The nick fallback ("* alice_ is in use, trying alice__").
        assert!(line_is_error("*", "alice_ is in use, trying alice__"));
        // Disconnect-with-reason console lines.
        assert!(line_is_error("*", "Disconnected: connection closed by server"));
        assert!(line_is_error(
            "*",
            "Disconnected: SASL authentication failed: 904 SASL authentication failed"
        ));
        // NickServ / ChanServ failure notices.
        assert!(line_is_error("NickServ", "Invalid password."));
        assert!(line_is_error("ChanServ", "Access denied."));
        assert!(line_is_error("NickServ", "You are not registered"));
        assert!(line_is_error("nickserv", "You are not logged in"));
        assert!(line_is_error("NickServ", "Password incorrect"));
        assert!(line_is_error("NickServ", "Identification failed for alice"));
        assert!(line_is_error("ChanServ", "Nickname is not registered"));
    }

    #[test]
    fn non_failing_lines_stay_dim() {
        // MOTD and friends (3xx numerics) stay dim even when the text after
        // the numeric sounds alarming — the range decides, not the words.
        assert!(!line_is_error(
            "*",
            "372 - MOTD: do not use incorrect settings or you will be denied"
        ));
        assert!(!line_is_error("*", "375 - Start of /MOTD command"));
        assert!(!line_is_error("*", "376 - End of /MOTD command"));
        assert!(!line_is_error("*", "001 alice Welcome to the network"));
        // Joins/parts/modes/topics and ordinary console lines.
        assert!(!line_is_error("*", "alice joined #kirc"));
        assert!(!line_is_error("*", "bob left #kirc"));
        assert!(!line_is_error("*", "mode +o alice on #kirc"));
        assert!(!line_is_error("*", "Topic for #kirc: kIRC development"));
        assert!(!line_is_error("*", "Connected to irc.libera.chat"));
        assert!(!line_is_error("*", "kircuser is now known as kircuser_afk"));
        // Ordinary chatter is never scanned, whatever it says.
        assert!(!line_is_error("alice", "404 skill not found"));
        assert!(!line_is_error("alice", "you are not funny"));
        assert!(!line_is_error("alice", "Disconnected: my wifi died"));
        assert!(!line_is_error("bob", "incorrect usage of the word literally"));
        // Successful identify/log-in notices are not errors.
        assert!(!line_is_error("NickServ", "You are now identified for alice."));
        assert!(!line_is_error("NickServ", "You are now logged in as alice"));
        assert!(!line_is_error("NickServ", "You are already logged in as alice"));
        assert!(!line_is_error("NickServ", "Password accepted - you are now recognized"));
        // A 3-digit token that is not a numeric reply is not a numeric.
        assert!(!line_is_error("*", "4730 not a numeric"));
        assert!(!line_is_error("*", "47 too short"));
    }

    #[test]
    fn derive_rows_flag_error_rows_only() {
        let mut rows = vec![
            row_text("alice", "morning everyone"),
            row_text("*", "473 #pain Cannot join channel (+i)"),
            row_text("*", "372 - MOTD: welcome to the test network"),
            row_text("NickServ", "Invalid password."),
            row_text("*", "bob left #kirc"),
        ];
        derive_rows(&mut rows);
        assert!(!rows[0].is_error);
        assert!(rows[1].is_error && rows[1].is_event);
        assert!(!rows[2].is_error);
        assert!(rows[3].is_error);
        assert!(!rows[4].is_error);

        // The O(1) append path derives the identical flag from the row alone.
        let mut appended = row_text("*", "473 #pain Cannot join channel (+i)");
        derive_row(None, &mut appended);
        assert!(appended.is_error && appended.is_event);
        let mut motd = row_text("*", "372 - MOTD: welcome to the test network");
        derive_row(None, &mut motd);
        assert!(!motd.is_error);
    }

    #[test]
    fn command_replies_fall_back_to_the_console_with_no_visible_buffer() {
        // The frozen policy: a reply goes to the buffer the user is looking
        // at; with none visible (registration time) it goes to the console.
        // It never gets a buffer of its own.
        assert_eq!(command_reply_key(""), SERVER_BUFFER);
        assert_eq!(command_reply_key("#kirc"), "#kirc");
        assert_eq!(command_reply_key("alice"), "alice");
        assert_eq!(command_reply_key(SERVER_BUFFER), SERVER_BUFFER);
    }

    #[test]
    fn query_keys_are_private_channels_and_console_are_not() {
        // `isPrivate` is about the buffer a row belongs to: query buffers
        // (ordinary nicks, services included) yes; channels and the server
        // console no.
        assert!(is_query_key("alice"));
        assert!(is_query_key("NickServ"));
        assert!(is_query_key("guest_12345"));
        assert!(!is_query_key("#kirc"));
        assert!(!is_query_key("&local"));
        assert!(!is_query_key("!ABCDEchan"));
        assert!(!is_query_key(SERVER_BUFFER));
    }

    #[test]
    fn arrival_facts_survive_derivation() {
        // A query row that arrived as a NOTICE (the isPrivate + isNotice case).
        let mut notice = row("alice", date(2026, 9, 11)).arrival("alice", true, false);
        assert!(notice.is_private && notice.is_notice && !notice.is_action);
        // A channel row that is a CTCP ACTION (`/me`).
        let mut action = row("bob", date(2026, 9, 11)).arrival("#kirc", false, true);
        assert!(!action.is_private && !action.is_notice && action.is_action);
        // A console row from a server NOTICE: not private, but a notice.
        let console = row("*", date(2026, 9, 11)).arrival(SERVER_BUFFER, true, false);
        assert!(!console.is_private && console.is_notice && !console.is_action);

        // Neither derivation pass may clobber the arrival facts — they are
        // raw, not derived.
        derive_row(None, &mut notice);
        derive_row(None, &mut action);
        assert!(notice.is_private && notice.is_notice && !notice.is_action);
        assert!(!action.is_private && action.is_action);
        assert!(!notice.is_event);

        let mut rows = vec![notice, action, console];
        derive_rows(&mut rows);
        assert!(rows[0].is_private && rows[0].is_notice);
        assert!(rows[1].is_action && !rows[1].is_private);
        assert!(!rows[2].is_private && rows[2].is_notice);
    }
}
