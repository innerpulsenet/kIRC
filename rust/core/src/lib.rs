//! # kirc-core
//!
//! A pure-Rust IRCv3 protocol engine for the kIRC client.
//!
//! This crate contains **no Qt / cxx dependencies** — it is a plain Rust
//! library intended to be consumed by a separate bridge crate (e.g. via
//! cxx-qt). The public API here is a stable contract for that bridge.
//!
//! ## Layers
//!
//! * [`parser`] — synchronous IRCv3 line parsing ([`parse_message`]).
//! * [`caps`] — `CAP` negotiation helpers.
//! * [`sasl`] — PLAIN / SCRAM-SHA-256 / EXTERNAL authentication.
//! * [`session`] — the async [`run_session`] state machine.
//!
//! ## Example
//!
//! ```no_run
//! use kirc_core::{ConnectionConfig, IrcEvent, ClientCommand, run_session};
//! use tokio::sync::mpsc;
//!
//! # async fn demo() {
//! let config = ConnectionConfig {
//!     host: "irc.example.org".into(),
//!     port: 6697,
//!     tls: true,
//!     nickname: "kircuser".into(),
//!     username: "kirc".into(),
//!     realname: "kIRC test".into(),
//!     server_password: None,
//!     sasl: None,
//!     request_caps: vec![],
//! };
//! let (event_tx, mut event_rx) = mpsc::channel::<IrcEvent>(64);
//! let (_cmd_tx, cmd_rx) = mpsc::channel::<ClientCommand>(64);
//! tokio::spawn(async move {
//!     while let Some(ev) = event_rx.recv().await {
//!         println!("{ev:?}");
//!     }
//! });
//! let _ = run_session(config, event_tx, cmd_rx).await;
//! # }
//! ```

#![forbid(unsafe_code)]
#![cfg_attr(not(test), deny(clippy::unwrap_used))]

pub mod caps;
pub mod parser;
pub mod sasl;
pub mod session;

pub use caps::{CapLine, CapState, DEFAULT_CAPS};
pub use parser::{
    escape_tag_value, parse_message, prefix_matches, unescape_tag_value, IrcMessage, ParseError,
    Prefix, MAX_LINE_LEN,
};
pub use sasl::{SaslClient, SaslConfig, SaslError, SaslMechanism};
pub use session::{
    is_channel, is_highlight, run_session, ClientCommand, ConnectionConfig, HistoryMsg, IrcEvent,
    KEEPALIVE_INTERVAL, MAX_MISSED_PONGS,
};
