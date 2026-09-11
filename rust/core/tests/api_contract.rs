//! Compile-time contract checks for the public API.
//!
//! The Qt bridge is built against these exact signatures. If a type, field or
//! function signature drifts, this test stops compiling.

use std::collections::BTreeMap;

use kirc_core::{
    parse_message, run_session, ClientCommand, ConnectionConfig, HistoryMsg, IrcEvent, IrcMessage,
    ParseError, Prefix, SaslConfig, SaslMechanism,
};
use tokio::sync::mpsc;

/// `run_session` must have exactly the contracted signature.
fn assert_run_session<F, Fut>(_: F)
where
    F: FnOnce(ConnectionConfig, mpsc::Sender<IrcEvent>, mpsc::Receiver<ClientCommand>) -> Fut,
    Fut: std::future::Future<Output = Result<(), Box<dyn std::error::Error + Send + Sync>>>,
{
}

#[test]
fn parse_message_signature() {
    let f: fn(&str) -> Result<IrcMessage, ParseError> = parse_message;
    let msg = f(":n!u@h PRIVMSG #c :hi").unwrap();
    // Field access asserts the exact field names and types.
    let _: &BTreeMap<String, Option<String>> = &msg.tags;
    let _: &Option<Prefix> = &msg.prefix;
    let _: &String = &msg.command;
    let _: &Vec<String> = &msg.params;
}

#[test]
fn prefix_fields() {
    let p = Prefix {
        nick: Some("n".into()),
        ident: Some("u".into()),
        host: Some("h".into()),
        raw: "n!u@h".into(),
    };
    let _: Option<String> = p.nick;
    let _: Option<String> = p.ident;
    let _: Option<String> = p.host;
    let _: String = p.raw;
}

#[test]
fn sasl_config_fields() {
    let cfg = SaslConfig {
        mechanism: SaslMechanism::Plain,
        username: "u".into(),
        password: "p".into(),
    };
    let _: SaslMechanism = cfg.mechanism;
    let _: String = cfg.username;
    let _: String = cfg.password;
    // All three mechanisms must exist.
    let _ = (
        SaslMechanism::Plain,
        SaslMechanism::ScramSha256,
        SaslMechanism::External,
    );
}

#[test]
fn connection_config_fields() {
    let cfg = ConnectionConfig {
        host: "h".into(),
        port: 6697u16,
        tls: true,
        nickname: "n".into(),
        username: "u".into(),
        realname: "r".into(),
        server_password: Some("s".into()),
        sasl: Some(SaslConfig {
            mechanism: SaslMechanism::Plain,
            username: "u".into(),
            password: "p".into(),
        }),
        request_caps: vec!["draft/example".into()],
    };
    let _: String = cfg.host;
    let _: u16 = cfg.port;
    let _: bool = cfg.tls;
    let _: String = cfg.nickname;
    let _: String = cfg.username;
    let _: String = cfg.realname;
    let _: Option<String> = cfg.server_password;
    let _: Option<SaslConfig> = cfg.sasl;
    let _: Vec<String> = cfg.request_caps;
}

#[test]
fn client_command_variants() {
    let cmds = [
        ClientCommand::Raw("WHOIS x".into()),
        ClientCommand::Privmsg {
            target: "#c".into(),
            text: "hi".into(),
        },
        ClientCommand::Join("#c".into()),
        ClientCommand::Part {
            channel: "#c".into(),
            reason: Some("bye".into()),
        },
        ClientCommand::Part {
            channel: "#c".into(),
            reason: None,
        },
        ClientCommand::Quit,
        ClientCommand::RequestHistory {
            target: "#c".into(),
            limit: 50u32,
        },
    ];
    assert_eq!(cmds.len(), 7);
}

#[test]
fn irc_event_variants() {
    let events = [
        IrcEvent::StateConnecting,
        IrcEvent::Registered {
            server_name: "irc.test".into(),
        },
        IrcEvent::Disconnected {
            reason: "bye".into(),
        },
        IrcEvent::Msg {
            target: "#c".into(),
            nick: "n".into(),
            text: "t".into(),
            timestamp: Some("2026-09-11T00:00:00.000Z".into()),
            is_self: false,
            is_highlight: true,
        },
        IrcEvent::Notice {
            nick: "n".into(),
            text: "t".into(),
        },
        IrcEvent::Join {
            channel: "#c".into(),
            nick: "n".into(),
            account: Some("acct".into()),
        },
        IrcEvent::Join {
            channel: "#c".into(),
            nick: "n".into(),
            account: None,
        },
        IrcEvent::Part {
            channel: "#c".into(),
            nick: "n".into(),
        },
        IrcEvent::Topic {
            channel: "#c".into(),
            topic: "t".into(),
        },
        IrcEvent::Names {
            channel: "#c".into(),
            nicks: vec!["@op".into(), "nick".into()],
        },
        IrcEvent::JoinFailed {
            channel: "#c".into(),
            reason: "invite only".into(),
        },
        IrcEvent::Quit {
            nick: "n".into(),
            reason: "bye".into(),
        },
        IrcEvent::NickChanged {
            nick: "n_".into(),
        },
        IrcEvent::HistoryBatch {
            messages: vec![HistoryMsg {
                timestamp: None,
                nick: "n".into(),
                text: "t".into(),
            }],
        },
        IrcEvent::Info { text: "i".into() },
        IrcEvent::Error {
            message: "e".into(),
        },
    ];
    assert_eq!(events.len(), 16);
}

#[test]
fn history_msg_fields() {
    let h = HistoryMsg {
        timestamp: Some("2026-09-11T09:00:00.000Z".into()),
        nick: "n".into(),
        text: "t".into(),
    };
    let _: Option<String> = h.timestamp;
    let _: String = h.nick;
    let _: String = h.text;
}

#[test]
fn run_session_signature() {
    assert_run_session(run_session);
}
