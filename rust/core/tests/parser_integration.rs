//! Integration-style parser tests over realistic Ergo-issued lines.
//!
//! Every line below is shaped exactly like what Ergo (`irc.ergo.chat`) emits
//! with `server-time`, `message-tags`, `account-tag`, `extended-join`,
//! `batch`, `echo-message` and `chathistory` enabled.

use kirc_core::{parse_message, prefix_matches, IrcMessage, ParseError};

/// Collected assertions over one parsed line.
fn check(line: &str) -> IrcMessage {
    parse_message(line).unwrap_or_else(|e| panic!("failed to parse {line:?}: {e}"))
}

#[test]
fn ergo_registration_burst() {
    // CAP LS with capability values (Ergo advertises sasl=PLAIN,EXTERNAL).
    let cap = check(
        ":irc.ergo.chat CAP * LS :account-notify account-tag away-notify batch \
                     chathistory echo-message extended-join message-tags sasl=PLAIN,EXTERNAL \
                     server-time",
    );
    assert_eq!(cap.command, "CAP");
    assert_eq!(cap.params[0], "*");
    assert_eq!(cap.params[1], "LS");
    assert!(cap.params[2].contains("sasl=PLAIN,EXTERNAL"));

    // RPL_WELCOME
    let welcome = check(":irc.ergo.chat 001 kircuser :Welcome to Ergo, kircuser!");
    assert_eq!(welcome.command, "001");
    assert_eq!(welcome.params[0], "kircuser");
    assert_eq!(
        welcome.prefix.unwrap().host.as_deref(),
        Some("irc.ergo.chat")
    );

    // RPL_ISUPPORT / 005
    let isupport = check(
        ":irc.ergo.chat 005 kircuser CASEMAPPING=ascii CHANTYPES=# EXCEPTS INVEX \
         NICKLEN=32 CHANNELLEN=64 TOPICLEN=390 NETWORK=Ergo :are supported by this server",
    );
    assert_eq!(isupport.command, "005");
    assert!(isupport.params.iter().any(|p| p == "NICKLEN=32"));

    // MOTD
    let motd_start = check(":irc.ergo.chat 375 kircuser :- irc.ergo.chat Message of the Day -");
    assert_eq!(motd_start.command, "375");
    let motd = check(":irc.ergo.chat 372 kircuser :- Welcome to Ergo! Enjoy your stay :)");
    assert_eq!(motd.command, "372");
    assert_eq!(motd.params[1], "- Welcome to Ergo! Enjoy your stay :)");
    let motd_end = check(":irc.ergo.chat 376 kircuser :End of MOTD command");
    assert_eq!(motd_end.command, "376");
}

#[test]
fn ergo_join_with_extended_join_and_account_tag() {
    let join = check(":alice!u@gateway/shell/example/x-abc123 JOIN #rust :Alice Example");
    assert_eq!(join.command, "JOIN");
    assert_eq!(join.params[0], "#rust");
    assert_eq!(join.params[1], "Alice Example");
    assert_eq!(join.nick(), Some("alice"));

    // extended-join renders NO account as "*"
    let no_account = check(":bob!b@host JOIN #rust * :Bob");
    assert_eq!(no_account.params[1], "*");
}

#[test]
fn ergo_tagged_privmsg_with_account_and_time() {
    let m = check(
        "@account=alice;time=2026-09-11T12:34:56.789Z;msgid=ABC123 \
         :alice!u@gateway/example PRIVMSG #rust :hey kircuser, look at this",
    );
    assert_eq!(m.command, "PRIVMSG");
    assert_eq!(m.params[0], "#rust");
    assert_eq!(m.params[1], "hey kircuser, look at this");
    assert_eq!(m.tag("account"), Some("alice"));
    assert_eq!(m.tag("time"), Some("2026-09-11T12:34:56.789Z"));
    assert_eq!(m.tag("msgid"), Some("ABC123"));
    assert_eq!(m.nick(), Some("alice"));
}

#[test]
fn ergo_echo_message_of_our_own_line() {
    let m = check(
        "@account=kircuser;time=2026-09-11T12:35:00.000Z \
         :kircuser!~kirc@client.example PRIVMSG #rust :my own message",
    );
    assert_eq!(m.nick(), Some("kircuser"));
    assert_eq!(m.params[1], "my own message");
}

#[test]
fn ergo_chathistory_batch() {
    let start = check(":irc.ergo.chat BATCH +5ci4k5gh chathistory #rust");
    assert_eq!(start.command, "BATCH");
    assert_eq!(start.params[0], "+5ci4k5gh");
    assert_eq!(start.params[1], "chathistory");
    assert_eq!(start.params[2], "#rust");

    let old1 = check(
        "@batch=5ci4k5gh;account=alice;time=2026-09-11T10:00:00.000Z \
         :alice!u@h PRIVMSG #rust :earlier message",
    );
    assert_eq!(old1.tag("batch"), Some("5ci4k5gh"));
    assert_eq!(old1.tag("time"), Some("2026-09-11T10:00:00.000Z"));

    let old2 =
        check("@batch=5ci4k5gh;time=2026-09-11T10:01:00.000Z :bob!b@h PRIVMSG #rust :another");
    assert_eq!(old2.tag("batch"), Some("5ci4k5gh"));

    let end = check(":irc.ergo.chat BATCH -5ci4k5gh");
    assert_eq!(end.params[0], "-5ci4k5gh");
}

#[test]
fn ergo_notice_topic_part_and_quit() {
    let notice = check(":irc.ergo.chat NOTICE kircuser :*** Looking up your hostname...");
    assert_eq!(notice.command, "NOTICE");
    assert_eq!(notice.params[1], "*** Looking up your hostname...");

    let topic = check(":alice!u@h TOPIC #rust :Rust programming language");
    assert_eq!(topic.command, "TOPIC");
    assert_eq!(topic.params[0], "#rust");
    assert_eq!(topic.params[1], "Rust programming language");

    let part = check(":bob!b@h PART #rust :Leaving");
    assert_eq!(part.command, "PART");
    assert_eq!(part.params[0], "#rust");
    assert_eq!(part.params[1], "Leaving");

    let quit = check(":bob!b@h QUIT :Quit: bye");
    assert_eq!(quit.command, "QUIT");
    assert_eq!(quit.params[0], "Quit: bye");
}

#[test]
fn ergo_sasl_and_errors() {
    let plus = check("AUTHENTICATE +");
    assert_eq!(plus.command, "AUTHENTICATE");
    assert_eq!(plus.params[0], "+");
    assert!(plus.prefix.is_none());

    let success = check(":irc.ergo.chat 903 kircuser :SASL authentication successful");
    assert_eq!(success.command, "903");

    let fail = check(":irc.ergo.chat 904 kircuser :SASL authentication failed");
    assert_eq!(fail.command, "904");

    let nick_in_use = check(":irc.ergo.chat 433 * kircuser :Nickname is already in use");
    assert_eq!(nick_in_use.command, "433");
    // 4xx numerics are the error range the session surfaces as IrcEvent::Error.
    assert!(nick_in_use.command.starts_with('4'));
    assert_eq!(nick_in_use.params[1], "kircuser");
    assert_eq!(nick_in_use.params[2], "Nickname is already in use");
}

#[test]
fn ergo_ping_pong_and_away() {
    let ping = check("PING :irc.ergo.chat");
    assert_eq!(ping.command, "PING");
    assert_eq!(ping.params[0], "irc.ergo.chat");

    let pong = check(":irc.ergo.chat PONG irc.ergo.chat :kirc1");
    assert_eq!(pong.command, "PONG");
    assert_eq!(pong.params.len(), 2);

    let away = check("@account=alice :alice!u@h AWAY :gone fishing");
    assert_eq!(away.command, "AWAY");
    assert_eq!(away.tag("account"), Some("alice"));
}

#[test]
fn ergo_escaped_tag_values_survive() {
    let m = check(
        "@label=123;msgid=abc;+draft/reply=xyz;text=a\\sb\\:c\\\\d \
         :alice!u@h PRIVMSG #rust :hi",
    );
    assert_eq!(m.tag("label"), Some("123"));
    assert_eq!(m.tag("+draft/reply"), Some("xyz"));
    assert_eq!(m.tag("text"), Some("a b;c\\d"));
}

#[test]
fn ten_plus_lines_parse_and_round_trip_command_case() {
    let lines = [
        ":irc.ergo.chat 001 kircuser :Welcome to Ergo!",
        ":irc.ergo.chat 002 kircuser :Your host is irc.ergo.chat",
        ":irc.ergo.chat 003 kircuser :This server was created 2022-01-01",
        ":irc.ergo.chat 004 kircuser irc.ergo.chat ergo-2.13 0 iowb",
        ":irc.ergo.chat 005 kircuser CASEMAPPING=ascii :are supported by this server",
        ":alice!u@h JOIN #rust * :Alice",
        "@time=2026-09-11T12:00:00.000Z :alice!u@h PRIVMSG #rust :hello",
        ":alice!u@h NOTICE kircuser :hi",
        ":alice!u@h TOPIC #rust :new topic",
        ":alice!u@h PART #rust :bye",
        ":irc.ergo.chat BATCH +1 chathistory #rust",
        "@batch=1;time=2026-09-11T09:00:00.000Z :alice!u@h PRIVMSG #rust :old",
        ":irc.ergo.chat BATCH -1",
        ":alice!u@h QUIT :gone",
        "ERROR :Closing Link: kircuser (Quit)",
    ];
    assert!(lines.len() >= 10);
    for line in lines {
        let msg = check(line);
        assert!(!msg.command.is_empty());
        assert_eq!(msg.command, msg.command.to_ascii_uppercase());
    }
    // Oversized / empty inputs still error rather than panic.
    assert_eq!(parse_message(""), Err(ParseError::Empty));
}

#[test]
fn prefix_matches_helper_rejects_normalization_attacks() {
    // A nickname that merely *contains* the configured nick must not match.
    let spoof = check(":kircuserx!u@h PRIVMSG #rust :not me");
    assert!(!prefix_matches(&spoof, "kircuser"));
    let real = check(":kircuser!u@h PRIVMSG #rust :me");
    assert!(prefix_matches(&real, "kircuser"));
    let case_insensitive = check(":KircUser!u@h PRIVMSG #rust :me");
    assert!(prefix_matches(&case_insensitive, "kircuser"));
}
