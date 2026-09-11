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

use kirc_core::{ClientCommand, ConnectionConfig, IrcEvent, SaslConfig, SaslMechanism};

// ---------------------------------------------------------------------------
// Shared, cross-object message buffer
// ---------------------------------------------------------------------------

/// A single message as buffered for the QML models.
#[derive(Clone, Debug, Default)]
pub struct StoreMsg {
    pub nick: String,
    pub text: String,
    pub timestamp: String,
    pub is_self: bool,
    pub is_highlight: bool,
}

/// Global `target -> messages` buffer.
///
/// `IrcBridge` appends to it from the Qt thread; `MessageListModel` reads from
/// it on `load_channel(..)`.  Nothing else may mutate it.
pub static STORE: OnceLock<Mutex<BTreeMap<String, Vec<StoreMsg>>>> = OnceLock::new();

fn store() -> &'static Mutex<BTreeMap<String, Vec<StoreMsg>>> {
    STORE.get_or_init(|| Mutex::new(BTreeMap::new()))
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

/// Format an IRCv3 `server-time` value as a local-time `HH:MM` string.
///
/// The QML layer displays message timestamps verbatim (it does no date
/// formatting of its own), so the bridge is responsible for the presentation.
/// Anything unparseable is passed through untouched so no information is lost.
fn fmt_timestamp(raw: Option<String>) -> String {
    match raw.as_deref() {
        Some(value) if !value.is_empty() => match chrono::DateTime::parse_from_rfc3339(value) {
            Ok(datetime) => datetime
                .with_timezone(&chrono::Local)
                .format("%H:%M")
                .to_string(),
            Err(_) => value.to_owned(),
        },
        _ => now_string(),
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
    #[qenum(MessageListModel)]
    enum Roles {
        Nick,
        Text,
        Timestamp,
        IsSelf,
        IsHighlight,
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
        #[qsignal]
        fn message_received(
            self: Pin<&mut Self>,
            target: QString,
            nick: QString,
            text: QString,
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

        /// Join a channel.
        #[qinvokable]
        fn join_channel(self: Pin<&mut Self>, channel: QString);

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
            obj.as_mut()
                .info(qs(&format!("Connected to {server_name}")));
        }

        IrcEvent::Disconnected { reason } => {
            obj.as_mut()
                .set_connection_state(qobject::ConnectionStatus::Disconnected);
            obj.as_mut()
                .state_changed(qobject::ConnectionStatus::Disconnected.repr);
            if !reason.is_empty() {
                obj.as_mut().info(qs(&format!("Disconnected: {reason}")));
            }
        }

        IrcEvent::Msg {
            target,
            nick,
            text,
            timestamp,
            is_self,
            is_highlight,
        } => {
            {
                let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
                guard
                    .entry(target.clone())
                    .or_default()
                    .push(StoreMsg {
                        nick: nick.clone(),
                        text: text.clone(),
                        timestamp: fmt_timestamp(timestamp),
                        is_self,
                        is_highlight,
                    });
            }

            if !is_self {
                let unread = *obj.as_ref().unread_count();
                obj.as_mut().set_unread_count(unread.saturating_add(1));
            }

            obj.as_mut().message_received(
                qs(&target),
                qs(&nick),
                qs(&text),
                is_self,
                is_highlight,
            );

            if is_highlight && !is_self {
                obj.as_mut()
                    .notification_fired(qs(&nick), qs(&text));
            }
        }

        IrcEvent::HistoryBatch { messages } => {
            let target = rs(obj.as_ref().history_target());
            {
                let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
                let entry = guard.entry(target.clone()).or_default();
                for msg in messages {
                    entry.push(StoreMsg {
                        nick: msg.nick,
                        text: msg.text,
                        timestamp: fmt_timestamp(msg.timestamp),
                        is_self: false,
                        is_highlight: false,
                    });
                }
            }
            obj.as_mut().history_batch_received(qs(&target));
        }

        IrcEvent::Notice { nick, text } => {
            obj.as_mut().info(qs(&format!("-{nick}- {text}")));
        }

        IrcEvent::Join {
            channel,
            nick,
            account,
        } => {
            let suffix = account
                .as_deref()
                .map(|a| format!(" ({a})"))
                .unwrap_or_default();
            obj.as_mut()
                .info(qs(&format!("{nick}{suffix} joined {channel}")));
        }

        IrcEvent::Part { channel, nick } => {
            obj.as_mut().info(qs(&format!("{nick} left {channel}")));
        }

        IrcEvent::Topic { channel, topic } => {
            obj.as_mut()
                .info(qs(&format!("Topic for {channel}: {topic}")));
        }

        IrcEvent::Info { text } => {
            obj.as_mut().info(qs(&text));
        }

        IrcEvent::Error { message } => {
            obj.as_mut().error_occurred(qs(&message));
        }
    }
}

// ===========================================================================
// IrcBridge implementation
// ===========================================================================

impl qobject::IrcBridge {
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

        // Drop the previous session and command channel first.
        self.as_mut().shutdown_session();

        let host_s = rs(&host);
        let nick_s = rs(&nickname);
        let sasl_user_s = rs(&sasl_user);
        let sasl_pass_s = rs(&sasl_pass);

        let sasl = if sasl_user_s.is_empty() {
            None
        } else {
            Some(SaslConfig {
                mechanism: SaslMechanism::Plain,
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
            server_password: None,
            sasl,
            request_caps: Vec::new(),
        };

        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<IrcEvent>(512);
        let (command_tx, command_rx) = tokio::sync::mpsc::channel::<ClientCommand>(128);

        self.as_mut().set_nickname(nickname);
        self.as_mut()
            .set_connected_server(qs(&format!("{host_s}:{port}")));
        self.as_mut().set_unread_count(0);
        self.as_mut().set_history_target(QString::default());
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
        self.as_mut().set_history_target(QString::default());
        self.as_mut()
            .set_connection_state(qobject::ConnectionStatus::Disconnected);
        self.as_mut()
            .state_changed(qobject::ConnectionStatus::Disconnected.repr);
    }

    /// Internal: ask the session to quit, then drop the command channel.
    ///
    /// Dropping the sender is what actually lets the `run_session` task wind
    /// down, so the connection is closed gracefully instead of aborted.
    fn shutdown_session(mut self: Pin<&mut Self>) {
        let mut rust = self.as_mut().rust_mut();
        if let Some(tx) = rust.command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Quit);
        }
        rust.command_tx = None;
        // Keep the JoinHandle around (but do not abort) so the task gets the
        // chance to send its final QUIT and `Disconnected` event.
        let _previous = rust.session.take();
    }

    /// Send a PRIVMSG and echo it locally.
    ///
    /// The QML layer does not echo what the user typed, so the bridge always
    /// re-emits it through `message_received(.., is_self = true, ..)` — even
    /// when there is no live session, so the UI is never dead.
    pub fn send_message(mut self: Pin<&mut Self>, target: QString, text: QString) {
        let target_s = rs(&target);
        let text_s = rs(&text);
        let nick = rs(self.as_ref().nickname());

        if let Some(tx) = self.as_ref().rust().command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Privmsg {
                target: target_s.clone(),
                text: text_s.clone(),
            });
        }

        {
            let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
            guard.entry(target_s.clone()).or_default().push(StoreMsg {
                nick: nick.clone(),
                text: text_s.clone(),
                timestamp: now_string(),
                is_self: true,
                is_highlight: false,
            });
        }

        self.as_mut()
            .message_received(qs(&target_s), qs(&nick), qs(&text_s), true, false);
    }

    /// Join a channel.
    pub fn join_channel(self: Pin<&mut Self>, channel: QString) {
        if let Some(tx) = self.rust().command_tx.as_ref() {
            let _ = tx.try_send(ClientCommand::Join(rs(&channel)));
        }
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
    pub fn load_channel(mut self: Pin<&mut Self>, target: QString) {
        let target_s = rs(&target);
        let rows = {
            let guard = store().lock().unwrap_or_else(|e| e.into_inner());
            guard.get(&target_s).cloned().unwrap_or_default()
        };

        unsafe {
            self.as_mut().begin_reset_model();
        }
        {
            let mut rust = self.as_mut().rust_mut();
            rust.rows = rows;
            rust.target = target_s;
        }
        unsafe {
            self.as_mut().end_reset_model();
        }
    }

    /// Append a row if `target` is the channel currently loaded.
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
        if target_s != self.as_ref().rust().target {
            return;
        }

        let row = StoreMsg {
            nick: rs(&nick),
            text: rs(&text),
            timestamp: rs(&timestamp),
            is_self,
            is_highlight,
        };

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
        roles
    }
}
