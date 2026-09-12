//! End-to-end session tests against an in-process mock IRC server.
//!
//! These exercise the real `run_session` state machine over a loopback TCP
//! socket: CAP negotiation, SASL (PLAIN and the full SCRAM-SHA-256 exchange),
//! registration, tagged messages, `echo-message`, highlight detection,
//! `chathistory` batches, outbound commands and the clean CAP-NAK abort.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use hmac::{Hmac, Mac};
use kirc_core::session::{REGISTRATION_TIMEOUT, TLS_HANDSHAKE_TIMEOUT};
use kirc_core::{
    run_session, ClientCommand, ConnectionConfig, IrcEvent, KEEPALIVE_INTERVAL, SaslConfig,
    SaslMechanism, MAX_LINE_LEN,
};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::OwnedWriteHalf;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

type HmacSha256 = Hmac<Sha256>;
type Lines = Arc<Mutex<Vec<String>>>;

/// The capability set Ergo advertises for the test server.
const LS_CAPS: &str = "account-notify account-tag away-notify batch chathistory echo-message \
                       extended-join message-tags sasl=PLAIN,SCRAM-SHA-256,EXTERNAL server-time";

async fn send(w: &mut OwnedWriteHalf, line: &str) {
    let _ = w.write_all(line.as_bytes()).await;
    let _ = w.write_all(b"\r\n").await;
    let _ = w.flush().await;
}

fn record(store: &Lines, line: &str) {
    if let Ok(mut v) = store.lock() {
        v.push(line.to_string());
    }
}

fn hmac(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut m = HmacSha256::new_from_slice(key).expect("hmac key");
    m.update(data);
    m.finalize().into_bytes().to_vec()
}

fn pbkdf2(pw: &[u8], salt: &[u8], iters: u32) -> Vec<u8> {
    let mut block = salt.to_vec();
    block.extend_from_slice(&1u32.to_be_bytes());
    let mut u = hmac(pw, &block);
    let mut acc = u.clone();
    for _ in 1..iters {
        u = hmac(pw, &u);
        for i in 0..acc.len() {
            acc[i] ^= u[i];
        }
    }
    acc
}

fn apply_req(line: &str) -> Option<String> {
    line.strip_prefix("CAP REQ :").map(|s| s.to_string())
}

/// Mock server: full PLAIN handshake, then a realistic post-registration burst.
async fn server_plain(stream: TcpStream, lines: Lines, sasl_seen: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        match line.as_str() {
            l if l.starts_with("CAP LS") => {
                send(&mut w, &format!(":irc.test CAP * LS :{LS_CAPS}")).await;
            }
            l if apply_req(l).is_some() => {
                let req = apply_req(&line).unwrap_or_default();
                send(&mut w, &format!(":irc.test CAP * ACK :{req}")).await;
            }
            "AUTHENTICATE PLAIN" => send(&mut w, "AUTHENTICATE +").await,
            l if l.starts_with("AUTHENTICATE ") => {
                let payload = &l["AUTHENTICATE ".len()..];
                if let Ok(decoded) = B64.decode(payload.as_bytes()) {
                    record(&sasl_seen, &String::from_utf8_lossy(&decoded));
                }
                send(
                    &mut w,
                    ":irc.test 903 kircuser :SASL authentication successful",
                )
                .await;
            }
            "CAP END" => {
                send(&mut w, ":irc.test 001 kircuser :Welcome to Ergo, kircuser!").await;
                send(
                    &mut w,
                    ":irc.test 005 kircuser CASEMAPPING=ascii NICKLEN=32 :are supported by this server",
                )
                .await;
                send(
                    &mut w,
                    ":irc.test 375 kircuser :- irc.test Message of the Day -",
                )
                .await;
                send(
                    &mut w,
                    ":irc.test 372 kircuser :- Welcome to the test server!",
                )
                .await;
                send(&mut w, ":irc.test 376 kircuser :End of MOTD command").await;
                send(
                    &mut w,
                    "@time=2026-09-11T12:00:00.000Z;account=alice;msgid=m1 \
                     :alice!a@host PRIVMSG #rust :hey kircuser, welcome",
                )
                .await;
                send(
                    &mut w,
                    "@time=2026-09-11T12:00:01.000Z :bob!b@host PRIVMSG #rust :just chatting",
                )
                .await;
                send(&mut w, ":kircuser!k@host PRIVMSG #rust :my own echoed line").await;
                send(&mut w, ":alice!a@host JOIN #rust account/alice :Alice").await;
                send(&mut w, ":irc.test NOTICE kircuser :hello notice").await;
                send(&mut w, ":irc.test BATCH +1 chathistory #rust").await;
                send(
                    &mut w,
                    "@batch=1;time=2026-09-11T09:00:00.000Z :carol!c@host PRIVMSG #rust :old one",
                )
                .await;
                send(
                    &mut w,
                    "@batch=1;time=2026-09-11T09:01:00.000Z :dave!d@host PRIVMSG #rust :old two",
                )
                .await;
                send(&mut w, ":irc.test BATCH -1").await;
            }
            l if l.starts_with("QUIT") => break,
            _ => {}
        }
    }
}

/// Mock server: full SCRAM-SHA-256 server side (RFC 5802).
async fn server_scram(stream: TcpStream, lines: Lines, sasl_seen: Lines) {
    const PASSWORD: &str = "pencil";
    const SALT: &[u8] = b"SCRAMsalt0123456";
    const ITERS: u32 = 4096;
    const SERVER_NONCE: &str = "SERVERnonceXYZ";

    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();

    let mut client_first_bare: Option<String> = None;
    let mut server_first: Option<String> = None;
    let mut salted: Option<Vec<u8>> = None;
    let mut awaiting_first = false;

    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        match line.as_str() {
            l if l.starts_with("CAP LS") => {
                send(
                    &mut w,
                    ":irc.test CAP * LS :server-time message-tags batch chathistory echo-message sasl=SCRAM-SHA-256",
                )
                .await;
            }
            l if apply_req(l).is_some() => {
                let req = apply_req(&line).unwrap_or_default();
                send(&mut w, &format!(":irc.test CAP * ACK :{req}")).await;
            }
            "AUTHENTICATE SCRAM-SHA-256" => {
                awaiting_first = true;
                send(&mut w, "AUTHENTICATE +").await;
            }
            l if l.starts_with("AUTHENTICATE ") && awaiting_first => {
                awaiting_first = false;
                let payload = &l["AUTHENTICATE ".len()..];
                let decoded = String::from_utf8(B64.decode(payload.as_bytes()).unwrap()).unwrap();
                // "n,,n=user,r=<client nonce>"
                let bare = decoded.trim_start_matches("n,,").to_string();
                let client_nonce = bare
                    .split(',')
                    .find_map(|p| p.strip_prefix("r="))
                    .unwrap_or_default()
                    .to_string();
                let combined = format!("{client_nonce}{SERVER_NONCE}");
                let sf = format!("r={combined},s={},i={ITERS}", B64.encode(SALT));
                record(&sasl_seen, &format!("client-first-bare:{bare}"));
                client_first_bare = Some(bare);
                server_first = Some(sf.clone());
                salted = Some(pbkdf2(PASSWORD.as_bytes(), SALT, ITERS));
                send(
                    &mut w,
                    &format!("AUTHENTICATE {}", B64.encode(sf.as_bytes())),
                )
                .await;
            }
            l if l.starts_with("AUTHENTICATE ") => {
                let payload = &l["AUTHENTICATE ".len()..];
                let decoded = String::from_utf8(B64.decode(payload.as_bytes()).unwrap()).unwrap();
                let without_proof = decoded.split(",p=").next().unwrap_or_default().to_string();
                let received_proof_b64 =
                    decoded.split(",p=").nth(1).unwrap_or_default().to_string();
                let cfb = client_first_bare.clone().unwrap_or_default();
                let sf = server_first.clone().unwrap_or_default();
                let salted = salted.clone().unwrap_or_default();
                let auth_message = format!("{cfb},{sf},{without_proof}");
                let client_key = hmac(&salted, b"Client Key");
                let stored_key = Sha256::digest(&client_key).to_vec();
                let client_sig = hmac(&stored_key, auth_message.as_bytes());
                let expected: Vec<u8> = client_key
                    .iter()
                    .zip(client_sig.iter())
                    .map(|(a, b)| a ^ b)
                    .collect();
                if B64.encode(&expected) == received_proof_b64 {
                    record(&sasl_seen, "proof-ok");
                    let server_key = hmac(&salted, b"Server Key");
                    let server_sig = hmac(&server_key, auth_message.as_bytes());
                    let final_msg = format!("v={}", B64.encode(&server_sig));
                    send(
                        &mut w,
                        &format!("AUTHENTICATE {}", B64.encode(final_msg.as_bytes())),
                    )
                    .await;
                    send(
                        &mut w,
                        ":irc.test 903 kircuser :SASL authentication successful",
                    )
                    .await;
                } else {
                    record(&sasl_seen, "proof-BAD");
                    send(&mut w, ":irc.test 904 kircuser :SASL authentication failed").await;
                }
            }
            "CAP END" => {
                send(&mut w, ":irc.test 001 kircuser :Welcome to Ergo, kircuser!").await;
            }
            l if l.starts_with("QUIT") => break,
            _ => {}
        }
    }
}

/// Mock server: advertises sasl but denies the REQ.
async fn server_nak(stream: TcpStream, lines: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        if line.starts_with("CAP LS") {
            send(&mut w, ":irc.test CAP * LS :server-time sasl=PLAIN").await;
        } else if apply_req(&line).is_some() {
            send(&mut w, ":irc.test CAP * NAK :sasl server-time").await;
        } else if line.starts_with("QUIT") {
            break;
        }
    }
}

fn base_config(port: u16, sasl: Option<SaslConfig>) -> ConnectionConfig {
    ConnectionConfig {
        host: "127.0.0.1".to_string(),
        port,
        tls: false,
        nickname: "kircuser".to_string(),
        username: "kircuser".to_string(),
        realname: "kIRC test".to_string(),
        server_password: None,
        sasl,
        sasl_mechanism: 0,
        request_caps: vec![],
    }
}

/// Drain events until `stop` returns true for the collected set, or timeout.
async fn collect_events(
    rx: &mut mpsc::Receiver<IrcEvent>,
    deadline: Duration,
    stop: impl Fn(&[IrcEvent]) -> bool,
) -> Vec<IrcEvent> {
    let end = tokio::time::Instant::now() + deadline;
    let mut events = Vec::new();
    loop {
        if stop(&events) {
            break;
        }
        tokio::select! {
            maybe = rx.recv() => match maybe {
                Some(e) => events.push(e),
                None => break,
            },
            _ = tokio::time::sleep_until(end) => break,
        }
    }
    events
}

/// Poll the mock's recorded lines until `done` accepts them or `deadline`
/// passes, then return whatever was seen. Bounded on purpose: a scheduling
/// hiccup must fail an assertion, never wedge the suite.
async fn wait_until(
    store: &Lines,
    deadline: Duration,
    done: impl Fn(&[String]) -> bool,
) -> Vec<String> {
    let end = tokio::time::Instant::now() + deadline;
    loop {
        let seen = store.lock().unwrap().clone();
        if done(&seen) || tokio::time::Instant::now() >= end {
            return seen;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Drive a paused-clock test forward in 1 ms pumps.
///
/// Every `sleep` parks the runtime, which both delivers loopback I/O and lets
/// the virtual clock auto-advance, so long timers fire without real waiting.
/// The pump stops when `done` accepts the collected events or the tick budget
/// is spent — it is never unbounded.
async fn pump_paused_clock(
    rx: &mut mpsc::Receiver<IrcEvent>,
    max_ticks: usize,
    done: impl Fn(&[IrcEvent]) -> bool,
) -> Vec<IrcEvent> {
    let mut events = Vec::new();
    for _ in 0..max_ticks {
        while let Ok(e) = rx.try_recv() {
            events.push(e);
        }
        if done(&events) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    while let Ok(e) = rx.try_recv() {
        events.push(e);
    }
    events
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn plain_sasl_session_end_to_end() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    let sasl_seen: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        let sasl_seen = sasl_seen.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_plain(stream, lines, sasl_seen).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(256);
    let (ctx, crx) = mpsc::channel::<ClientCommand>(64);
    let sasl = SaslConfig {
        mechanism: SaslMechanism::Plain,
        username: "kircuser".to_string(),
        password: "hunter2".to_string(),
    };
    let handle = tokio::spawn(run_session(base_config(port, Some(sasl)), etx, crx));

    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter()
            .any(|e| matches!(e, IrcEvent::HistoryBatch { .. }))
    })
    .await;

    assert!(
        matches!(events.first(), Some(IrcEvent::StateConnecting)),
        "first event should be StateConnecting, got {:?}",
        events.first()
    );
    assert!(
        events.iter().any(
            |e| matches!(e, IrcEvent::Registered { server_name } if server_name == "irc.test")
        ),
        "expected Registered from 001, got {events:?}"
    );

    let msgs: Vec<&IrcEvent> = events
        .iter()
        .filter(|e| matches!(e, IrcEvent::Msg { .. }))
        .collect();
    // alice's line is a highlight, bob's is not, and our own line is `is_self`.
    assert!(msgs.iter().any(|e| matches!(e, IrcEvent::Msg { nick, is_highlight: true, timestamp: Some(_), .. } if nick == "alice")), "alice highlight missing: {msgs:?}");
    assert!(msgs
        .iter()
        .any(|e| matches!(e, IrcEvent::Msg { nick, is_highlight: false, .. } if nick == "bob")));
    assert!(
        msgs.iter()
            .any(|e| matches!(e, IrcEvent::Msg { is_self: true, nick, .. } if nick == "kircuser")),
        "echo-message is_self missing: {msgs:?}"
    );

    assert!(events.iter().any(|e| matches!(e, IrcEvent::Join { channel, nick, account: Some(a), is_self: false } if channel == "#rust" && nick == "alice" && a == "account/alice")), "extended-join account missing");
    assert!(events.iter().any(|e| matches!(e, IrcEvent::Notice { nick, text } if nick == "irc.test" && text == "hello notice")));
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Info { text } if text.contains("MOTD"))),
        "MOTD info missing"
    );

    let history = events
        .iter()
        .find_map(|e| match e {
            IrcEvent::HistoryBatch { messages } => Some(messages.clone()),
            _ => None,
        })
        .expect("HistoryBatch should have been emitted");
    assert_eq!(history.len(), 2, "history: {history:?}");
    assert_eq!(history[0].nick, "carol");
    assert_eq!(history[0].text, "old one");
    assert_eq!(
        history[0].timestamp.as_deref(),
        Some("2026-09-11T09:00:00.000Z")
    );

    // SASL PLAIN payload decoded on the server: \0user\0pass
    let seen = sasl_seen.lock().unwrap().clone();
    assert!(
        seen.iter().any(|s| s == "\0kircuser\0hunter2"),
        "PLAIN payload wrong: {seen:?}"
    );

    // Outbound commands.
    ctx.send(ClientCommand::Privmsg {
        target: "#rust".to_string(),
        text: "hi from ui".to_string(),
    })
    .await
    .unwrap();
    ctx.send(ClientCommand::Join("#other".to_string()))
        .await
        .unwrap();
    ctx.send(ClientCommand::Part {
        channel: "#other".to_string(),
        reason: Some("brb".to_string()),
    })
    .await
    .unwrap();
    ctx.send(ClientCommand::RequestHistory {
        target: "#rust".to_string(),
        limit: 25,
    })
    .await
    .unwrap();
    ctx.send(ClientCommand::Quit).await.unwrap();

    tokio::time::sleep(Duration::from_millis(400)).await;
    let sent = lines.lock().unwrap().clone();
    assert!(sent.iter().any(|l| l == "CAP LS 302"));
    assert!(sent.iter().any(|l| l == "NICK kircuser"));
    assert!(sent.iter().any(|l| l == "USER kircuser 0 * :kIRC test"));
    assert!(sent.iter().any(|l| l == "CAP END"));
    assert!(
        sent.iter().any(|l| l == "PRIVMSG #rust :hi from ui"),
        "sent: {sent:?}"
    );
    assert!(sent.iter().any(|l| l == "JOIN #other"));
    assert!(sent.iter().any(|l| l == "PART #other :brb"));
    assert!(
        sent.iter().any(|l| l == "CHATHISTORY LATEST #rust * 25"),
        "sent: {sent:?}"
    );

    let joined = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(joined.is_ok(), "run_session did not return after Quit");
    assert!(joined.unwrap().is_ok(), "run_session returned an error");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn scram_sha256_session_against_rfc5802_server() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    let sasl_seen: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        let sasl_seen = sasl_seen.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_scram(stream, lines, sasl_seen).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let sasl = SaslConfig {
        mechanism: SaslMechanism::ScramSha256,
        username: "user".to_string(),
        password: "pencil".to_string(),
    };
    let handle = tokio::spawn(run_session(base_config(port, Some(sasl)), etx, crx));

    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter().any(|e| matches!(e, IrcEvent::Registered { .. }))
    })
    .await;
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. })),
        "SCRAM session never registered: {events:?}"
    );
    assert!(
        !events.iter().any(|e| matches!(e, IrcEvent::Error { .. })),
        "unexpected error during SCRAM: {events:?}"
    );

    let seen = sasl_seen.lock().unwrap().clone();
    assert!(
        seen.iter().any(|s| s == "proof-ok"),
        "server rejected the SCRAM proof: {seen:?}"
    );
    assert!(
        seen.iter()
            .any(|s| s.starts_with("client-first-bare:n=user,r=")),
        "client-first not sent: {seen:?}"
    );

    ctx.send(ClientCommand::Quit).await.unwrap();
    let joined = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(joined.is_ok());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cap_nak_of_sasl_aborts_with_quit_and_error() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_nak(stream, lines).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (_ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let sasl = SaslConfig {
        mechanism: SaslMechanism::Plain,
        username: "u".to_string(),
        password: "p".to_string(),
    };
    let handle = tokio::spawn(run_session(base_config(port, Some(sasl)), etx, crx));

    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter()
            .any(|e| matches!(e, IrcEvent::Disconnected { .. }))
    })
    .await;
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Error { message } if message.contains("CAP NAK"))),
        "expected a CAP NAK error, got {events:?}"
    );

    let returned = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(returned.is_ok(), "session did not stop after NAK");
    assert!(returned.unwrap().is_ok());

    // Give the mock server a moment to consume the QUIT we wrote.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let sent = lines.lock().unwrap().clone();
    assert!(
        sent.iter().any(|l| l.starts_with("QUIT")),
        "expected a clean QUIT on NAK, got {sent:?}"
    );
    assert!(
        !sent.iter().any(|l| l == "CAP END"),
        "CAP END must not be sent when aborting: {sent:?}"
    );
}

/// First NICK is rejected with 433; the fallback nick is accepted.
async fn server_nick_in_use_then_ok(stream: TcpStream, lines: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    let mut nicks = 0u8;
    let mut accepted = String::from("kircuser_");
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        if line.starts_with("CAP LS") {
            send(&mut w, &format!(":irc.test CAP * LS :{LS_CAPS}")).await;
        } else if apply_req(&line).is_some() {
            let req = apply_req(&line).unwrap_or_default();
            send(&mut w, &format!(":irc.test CAP * ACK :{req}")).await;
        } else if let Some(nick) = line.strip_prefix("NICK ") {
            nicks += 1;
            if nicks == 1 {
                send(
                    &mut w,
                    &format!(":irc.test 433 * {nick} :Nickname is already in use"),
                )
                .await;
            } else {
                accepted = nick.to_string();
            }
        } else if line == "CAP END" {
            send(
                &mut w,
                &format!(":irc.test 001 {accepted} :Welcome"),
            )
            .await;
        } else if line.starts_with("QUIT") {
            break;
        }
    }
}

/// Every NICK is 433 — the client must abort rather than spin.
async fn server_nick_always_taken(stream: TcpStream, lines: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        if line.starts_with("CAP LS") {
            send(&mut w, ":irc.test CAP * LS :server-time").await;
        } else if apply_req(&line).is_some() {
            let req = apply_req(&line).unwrap_or_default();
            send(&mut w, &format!(":irc.test CAP * ACK :{req}")).await;
        } else if let Some(nick) = line.strip_prefix("NICK ") {
            send(
                &mut w,
                &format!(":irc.test 433 * {nick} :Nickname is already in use"),
            )
            .await;
        } else if line.starts_with("QUIT") {
            break;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nick_in_use_retries_alternate_and_registers() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_nick_in_use_then_ok(stream, lines).await;
        });
    }
    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let handle = tokio::spawn(run_session(base_config(port, None), etx, crx));
    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. }))
    })
    .await;
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::NickChanged { nick } if nick == "kircuser_")),
        "expected NickChanged to kircuser_, got {events:?}"
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. })),
        "expected registration after nick fallback, got {events:?}"
    );
    ctx.send(ClientCommand::Quit).await.ok();
    let _ = tokio::time::timeout(Duration::from_secs(5), handle).await;
    let sent = lines.lock().unwrap().clone();
    assert!(
        sent.iter().any(|l| l == "NICK kircuser_"),
        "expected fallback NICK, got {sent:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nick_in_use_exhausted_aborts_and_disconnects() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_nick_always_taken(stream, lines).await;
        });
    }
    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (_ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let handle = tokio::spawn(run_session(base_config(port, None), etx, crx));
    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter()
            .any(|e| matches!(e, IrcEvent::Disconnected { .. }))
    })
    .await;
    assert!(
        events.iter().any(|e| matches!(e, IrcEvent::Error { message } if message.contains("already in use"))),
        "expected abort error, got {events:?}"
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Disconnected { .. })),
        "must leave Connecting: {events:?}"
    );
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. })),
        "must not register: {events:?}"
    );
    let returned = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(returned.is_ok(), "session did not stop after 433 exhaustion");
    tokio::time::sleep(Duration::from_millis(200)).await;
    let sent = lines.lock().unwrap().clone();
    let nick_sends = sent.iter().filter(|l| l.starts_with("NICK ")).count();
    assert!(
        nick_sends >= 2 && nick_sends <= 5,
        "expected a few NICK retries then QUIT, got {sent:?}"
    );
    assert!(
        sent.iter().any(|l| l.starts_with("QUIT")),
        "expected QUIT after giving up, got {sent:?}"
    );
}

/// Cancel-during-connect: the session task must never pin the UI in
/// Connecting.
///
/// `run_session` blocks in `TcpStream::connect()` with no cancellation
/// point, so the bridge (`shutdown_session` in rust/src/bridge.rs) aborts
/// the JoinHandle. This test proves both cancel paths finish:
///
/// 1. Silent server (connect succeeds, server never speaks): dropping the
///    command channel — the graceful Quit/teardown path — ends the task
///    and emits Disconnected.
/// 2. Same silent server, but cancelled via `handle.abort()` (exactly what
///    the bridge does): finishes within 2s.
/// 3. Unreachable host where `connect()` itself hangs until TCP timeout:
///    only `handle.abort()` can end it. (If the sandbox fails fast with
///    ENETUNREACH instead of hanging, the abort is a no-op and the join
///    still succeeds — the assertion holds either way.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancel_during_connect_abort_always_finishes() {
    // Phase 1: graceful teardown via the command channel.
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        // Hold the connection open but never speak: the client sits in the
        // pre-registration read loop.
        tokio::time::sleep(Duration::from_secs(30)).await;
        drop(stream);
    });

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let handle = tokio::spawn(run_session(base_config(port, None), etx, crx));
    tokio::time::sleep(Duration::from_millis(200)).await;
    drop(ctx);
    let finished = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(finished.is_ok(), "session hung after command channel dropped");
    let events = collect_events(&mut erx, Duration::from_millis(500), |_| false).await;
    assert!(
        events.iter().any(|e| matches!(e, IrcEvent::Disconnected { .. })),
        "silent-server cancel must emit Disconnected, got {events:?}"
    );

    // Phase 2: bridge-style abort of a task stuck mid-handshake.
    let listener2 = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port2 = listener2.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (stream, _) = listener2.accept().await.unwrap();
        tokio::time::sleep(Duration::from_secs(30)).await;
        drop(stream);
    });
    let (etx2, _erx2) = mpsc::channel::<IrcEvent>(64);
    let (_ctx2, crx2) = mpsc::channel::<ClientCommand>(16);
    let handle2 = tokio::spawn(run_session(base_config(port2, None), etx2, crx2));
    tokio::time::sleep(Duration::from_millis(200)).await;
    handle2.abort();
    let finished2 = tokio::time::timeout(Duration::from_secs(2), handle2).await;
    assert!(finished2.is_ok(), "aborted handshake task did not finish in 2s");

    // Phase 3: connect() itself hanging (blackhole host) — abort is the
    // only way out, which is why shutdown_session aborts the JoinHandle.
    let (etx3, _erx3) = mpsc::channel::<IrcEvent>(64);
    let (_ctx3, crx3) = mpsc::channel::<ClientCommand>(16);
    let mut blackhole = base_config(6667, None);
    blackhole.host = "10.255.255.1".to_string();
    let handle3 = tokio::spawn(run_session(blackhole, etx3, crx3));
    tokio::time::sleep(Duration::from_millis(200)).await;
    handle3.abort();
    let finished3 = tokio::time::timeout(Duration::from_secs(2), handle3).await;
    assert!(finished3.is_ok(), "aborted connect() task did not finish in 2s");
}

// ---------------------------------------------------------------------------
// Connectivity-audit regression tests
//
// Every case below is a connection that used to fail, hang, drop or spam the
// reconnect path. The paused-clock ones (`tokio::time::pause` + `advance`)
// drive the real timers over a real loopback socket; the wire bytes and the
// recorded server-side lines are asserted, not just the events.
// ---------------------------------------------------------------------------

/// Mock server: accepts, records every line, answers nothing.
///
/// The handshake can never complete, and the server never closes either, so
/// the client cannot escape through EOF — the way out is the registration
/// deadline.
async fn server_silent(stream: TcpStream, lines: Lines) {
    let (r, _w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
    }
}

/// Mock server: completes the TCP handshake, then never speaks TLS.
async fn server_tls_stall(stream: TcpStream) {
    let _held = stream; // keep the socket open
    tokio::time::sleep(Duration::from_secs(600)).await;
}

/// Mock server: refuses the server password with 464 and then keeps the
/// socket open and silent (a daemon that rejects without closing).
async fn server_bad_password(stream: TcpStream, lines: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    let mut refused = false;
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        if refused {
            // Nothing is answered after the refusal: no 001, no ERROR, no
            // close. Only the client can end this.
            continue;
        }
        if line.starts_with("CAP LS") {
            send(&mut w, ":irc.test CAP * LS :server-time").await;
        } else if line.starts_with("PASS") {
            refused = true;
            send(&mut w, ":irc.test 464 * :Password incorrect").await;
        }
    }
}

/// Mock server: registers the client, then goes deaf — it keeps reading (so
/// the keepalives reach the wire) but never answers a PING.
async fn server_deaf_after_registration(stream: TcpStream, lines: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    let mut registered = false;
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        if line.starts_with("CAP LS") {
            send(&mut w, ":irc.test CAP * LS :server-time").await;
        } else if apply_req(&line).is_some() {
            let req = apply_req(&line).unwrap_or_default();
            send(&mut w, &format!(":irc.test CAP * ACK :{req}")).await;
        } else if line == "CAP END" && !registered {
            registered = true;
            send(&mut w, ":irc.test 001 kircuser :Welcome").await;
        }
        // PINGs are recorded and deliberately never answered.
    }
}

/// Mock server: after registration it sends one line far past the parser's
/// limit, then a PING and a PRIVMSG.
async fn server_overlong_line(stream: TcpStream, lines: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    let mut greeted = false;
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        if line.starts_with("CAP LS") {
            send(&mut w, ":irc.test CAP * LS :server-time").await;
        } else if apply_req(&line).is_some() {
            let req = apply_req(&line).unwrap_or_default();
            send(&mut w, &format!(":irc.test CAP * ACK :{req}")).await;
        } else if line == "CAP END" && !greeted {
            greeted = true;
            send(&mut w, ":irc.test 001 kircuser :Welcome").await;
            send(&mut w, &"z".repeat(MAX_LINE_LEN * 2)).await;
            send(&mut w, "PING :probe").await;
            send(&mut w, ":alice!a@host PRIVMSG #rust :still alive").await;
        }
    }
}

/// A server that accepts and then says nothing must not pin the session in
/// Connecting: the registration deadline ends it with a reason and a QUIT.
#[tokio::test(start_paused = true)]
async fn silent_server_ends_at_the_registration_deadline() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_silent(stream, lines).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (_ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let handle = tokio::spawn(run_session(base_config(port, None), etx, crx));

    // Paused clock pumped in 1 ms steps: the deadline fires after 45 s of
    // *virtual* time, and each pump parks the runtime so the loopback
    // handshake bytes are really delivered.
    let events = pump_paused_clock(
        &mut erx,
        (REGISTRATION_TIMEOUT.as_secs() as usize + 15) * 1000,
        |evs| {
            evs.iter()
                .any(|e| matches!(e, IrcEvent::Disconnected { .. }))
        },
    )
    .await;
    tokio::time::resume();
    assert!(
        events.iter().any(|e| matches!(e, IrcEvent::Error { message } if message.contains("registration did not complete"))),
        "expected a registration-timeout error, got {events:?}"
    );
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. })),
        "must not register: {events:?}"
    );

    let joined = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(joined.is_ok(), "session hung past the registration deadline");
    // A deadline abort is a clean teardown -> Ok(()), not an error.
    let outcome = joined.unwrap().expect("session task must not panic");
    assert!(outcome.is_ok(), "deadline abort must return Ok");

    let sent = wait_until(&lines, Duration::from_secs(5), |seen| {
        seen.iter().any(|l| l.starts_with("QUIT"))
    })
    .await;
    assert!(sent.iter().any(|l| l == "CAP LS 302"), "sent: {sent:?}");
    assert!(sent.iter().any(|l| l.starts_with("NICK ")), "sent: {sent:?}");
    assert!(
        sent.iter().any(|l| l.starts_with("QUIT")),
        "expected a QUIT on the deadline abort, got {sent:?}"
    );
}

/// A listener that accepts TCP but never completes the TLS handshake must be
/// abandoned by the handshake timeout instead of hanging `run_session`.
#[tokio::test(start_paused = true)]
async fn stalled_tls_handshake_times_out_instead_of_hanging() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        server_tls_stall(stream).await;
    });

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(16);
    let (_ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let mut config = base_config(port, None);
    config.tls = true;
    let handle = tokio::spawn(run_session(config, etx, crx));
    let events = pump_paused_clock(
        &mut erx,
        (TLS_HANDSHAKE_TIMEOUT.as_secs() as usize + 15) * 1000,
        |evs| {
            evs.iter()
                .any(|e| matches!(e, IrcEvent::Disconnected { .. }))
        },
    )
    .await;
    tokio::time::resume();
    assert!(
        events.iter().any(|e| matches!(e, IrcEvent::Error { message } if message.contains("TLS handshake") && message.contains("timed out"))),
        "expected a TLS-handshake timeout, got {events:?}"
    );
    // `timeout(join_handle)` nests two Results: the join result, then the
    // session's own Result.
    let joined = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(joined.is_ok(), "session hung in the TLS handshake");
    let outcome = joined.unwrap().expect("session task must not panic");
    assert!(
        outcome.is_err(),
        "a failed connect must report an error to the bridge"
    );
}

/// Mock server: PLAIN SASL that records every AUTHENTICATE chunk and answers
/// 903 once the client has sent everything — a short final chunk, or the `+`
/// terminator after an exact multiple of 400 bytes.
async fn server_plain_chunked(stream: TcpStream, lines: Lines) {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();
    while let Ok(Some(line)) = reader.next_line().await {
        record(&lines, &line);
        if line.starts_with("CAP LS") {
            send(&mut w, ":irc.test CAP * LS :sasl=PLAIN").await;
        } else if apply_req(&line).is_some() {
            let req = apply_req(&line).unwrap_or_default();
            send(&mut w, &format!(":irc.test CAP * ACK :{req}")).await;
        } else if line == "AUTHENTICATE PLAIN" {
            send(&mut w, "AUTHENTICATE +").await;
        } else if let Some(payload) = line.strip_prefix("AUTHENTICATE ") {
            if payload == "+" || payload.len() < 400 {
                send(&mut w, ":irc.test 903 kircuser :SASL successful").await;
            }
        } else if line == "CAP END" {
            send(&mut w, ":irc.test 001 kircuser :Welcome").await;
        }
    }
}

/// The AUTHENTICATE payload chunks the client sent, in order, after the
/// mechanism line. The `+` terminator shows up as its own chunk.
fn sasl_payload_chunks(sent: &[String]) -> Vec<String> {
    let mut chunks = Vec::new();
    let mut in_payload = false;
    for line in sent {
        if line == "AUTHENTICATE PLAIN" {
            in_payload = true;
        } else if in_payload {
            match line.strip_prefix("AUTHENTICATE ") {
                Some(payload) => chunks.push(payload.to_string()),
                None => break,
            }
        }
    }
    chunks
}

/// A payload that is not a multiple of 400 bytes is split 400/400/tail with
/// no terminator, and reassembles to the exact base64 blob.
#[tokio::test]
async fn long_sasl_payload_is_chunked_at_400_bytes() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_plain_chunked(stream, lines).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (ctx, crx) = mpsc::channel::<ClientCommand>(16);
    // "\0" + 250 u's + "\0" + 350 p's = 602 bytes -> 804 base64 chars, i.e.
    // 400 + 400 + a 4-char tail, so no "+" terminator is expected.
    let sasl = SaslConfig {
        mechanism: SaslMechanism::Plain,
        username: "u".repeat(250),
        password: "p".repeat(350),
    };
    let handle = tokio::spawn(run_session(base_config(port, Some(sasl)), etx, crx));
    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. }))
    })
    .await;
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. })),
        "chunked SASL never registered: {events:?}"
    );
    ctx.send(ClientCommand::Quit).await.ok();
    let _ = tokio::time::timeout(Duration::from_secs(5), handle).await;

    let sent = wait_until(&lines, Duration::from_secs(5), |seen| {
        sasl_payload_chunks(seen).len() >= 3
    })
    .await;
    let chunks = sasl_payload_chunks(&sent);
    assert_eq!(chunks.len(), 3, "expected 400+400+4, got {sent:?}");
    assert_eq!(chunks[0].len(), 400);
    assert_eq!(chunks[1].len(), 400);
    assert_eq!(chunks[2].len(), 4);
    assert!(
        !chunks.iter().any(|c| c == "+"),
        "a non-multiple of 400 must not be terminated with +: {sent:?}"
    );
    let joined: String = chunks.concat();
    let decoded = B64.decode(joined.as_bytes()).expect("valid base64");
    assert_eq!(
        String::from_utf8(decoded).unwrap(),
        format!("\0{}\0{}", "u".repeat(250), "p".repeat(350))
    );
}

/// A payload whose base64 length is an exact multiple of 400 needs the
/// explicit `AUTHENTICATE +` terminator to end it.
#[tokio::test]
async fn sasl_payload_of_exact_multiple_of_400_sends_terminator() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_plain_chunked(stream, lines).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (ctx, crx) = mpsc::channel::<ClientCommand>(16);
    // 1 + 250 + 1 + 348 = 600 bytes -> exactly 800 base64 chars = 2 x 400.
    let sasl = SaslConfig {
        mechanism: SaslMechanism::Plain,
        username: "u".repeat(250),
        password: "p".repeat(348),
    };
    let handle = tokio::spawn(run_session(base_config(port, Some(sasl)), etx, crx));
    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. }))
    })
    .await;
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. })),
        "terminated SASL never registered: {events:?}"
    );
    ctx.send(ClientCommand::Quit).await.ok();
    let _ = tokio::time::timeout(Duration::from_secs(5), handle).await;

    let sent = wait_until(&lines, Duration::from_secs(5), |seen| {
        sasl_payload_chunks(seen).iter().any(|c| c == "+")
    })
    .await;
    let chunks = sasl_payload_chunks(&sent);
    assert_eq!(chunks.len(), 3, "two chunks plus the terminator: {sent:?}");
    assert_eq!(chunks[0].len(), 400);
    assert_eq!(chunks[1].len(), 400);
    assert_eq!(chunks[2], "+", "a 400-multiple payload must be terminated");
    let joined: String = chunks[..2].concat();
    let decoded = B64.decode(joined.as_bytes()).expect("valid base64");
    assert_eq!(
        String::from_utf8(decoded).unwrap(),
        format!("\0{}\0{}", "u".repeat(250), "p".repeat(348))
    );
}

/// PASS must go out before NICK/USER, and a 464 refusal must end the session
/// even though the server keeps the socket open.
#[tokio::test]
async fn server_password_precedes_nick_and_a_464_ends_the_session() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_bad_password(stream, lines).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (_ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let mut config = base_config(port, None);
    config.server_password = Some("hunter2".to_string());
    let handle = tokio::spawn(run_session(config, etx, crx));

    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter()
            .any(|e| matches!(e, IrcEvent::Disconnected { .. }))
    })
    .await;
    assert!(
        events.iter().any(|e| matches!(e, IrcEvent::Error { message } if message.contains("464") && message.contains("Password incorrect"))),
        "expected the 464 to surface, got {events:?}"
    );

    let returned = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(
        returned.is_ok(),
        "464 without a server-side close must still end the session"
    );
    let outcome = returned.unwrap().expect("session task must not panic");
    assert!(outcome.is_ok(), "a 464 abort is a clean teardown");

    let sent = wait_until(&lines, Duration::from_secs(5), |seen| {
        seen.iter().any(|l| l.starts_with("QUIT"))
    })
    .await;
    let pos = |needle: &str| sent.iter().position(|l| l == needle);
    let pass = pos("PASS hunter2").expect("PASS must be sent");
    let nick = sent
        .iter()
        .position(|l| l.starts_with("NICK "))
        .expect("NICK must be sent");
    let user = sent
        .iter()
        .position(|l| l.starts_with("USER "))
        .expect("USER must be sent");
    assert!(
        pass < nick && pass < user,
        "PASS must precede NICK/USER: {sent:?}"
    );
    assert!(
        sent.iter().any(|l| l.starts_with("QUIT")),
        "expected a QUIT after 464, got {sent:?}"
    );
}

/// A registered session whose server stops answering PINGs (half-open link)
/// must be detected by the keepalive instead of looking connected forever.
#[tokio::test(start_paused = true)]
async fn half_open_link_is_detected_by_the_keepalive() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_deaf_after_registration(stream, lines).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (_ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let handle = tokio::spawn(run_session(base_config(port, None), etx, crx));

    // Pump the paused clock: registration takes a few ticks of virtual time,
    // then the unanswered keepalive periods roll by (60 s each) and the
    // session must give up on its own — no real 180 s wait.
    let events = pump_paused_clock(
        &mut erx,
        (KEEPALIVE_INTERVAL.as_secs() as usize + 1) * 4 * 1000,
        |evs| {
            evs.iter()
                .any(|e| matches!(e, IrcEvent::Disconnected { .. }))
        },
    )
    .await;
    tokio::time::resume();
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Registered { .. })),
        "never registered: {events:?}"
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IrcEvent::Disconnected { reason } if reason.contains("ping timeout"))),
        "expected a ping-timeout disconnect, got {events:?}"
    );
    let joined = tokio::time::timeout(Duration::from_secs(5), handle).await;
    assert!(
        joined.is_ok(),
        "session did not stop after the keepalive timeout"
    );
    joined.unwrap().expect("session task must not panic");

    let sent = wait_until(&lines, Duration::from_secs(5), |seen| {
        seen.iter().any(|l| l.starts_with("QUIT :Ping timeout"))
    })
    .await;
    assert!(
        sent.iter().any(|l| l.starts_with("PING :kirc")),
        "the keepalive PING must reach the wire: {sent:?}"
    );
    assert!(
        sent.iter().any(|l| l.starts_with("QUIT :Ping timeout")),
        "expected a QUIT on the keepalive timeout: {sent:?}"
    );
}

/// One overlong line must not derail the read loop: the session keeps
/// processing the lines that follow it.
#[tokio::test]
async fn overlong_line_does_not_stall_the_session() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Lines = Arc::new(Mutex::new(Vec::new()));
    {
        let lines = lines.clone();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server_overlong_line(stream, lines).await;
        });
    }

    let (etx, mut erx) = mpsc::channel::<IrcEvent>(64);
    let (ctx, crx) = mpsc::channel::<ClientCommand>(16);
    let handle = tokio::spawn(run_session(base_config(port, None), etx, crx));
    let events = collect_events(&mut erx, Duration::from_secs(10), |evs| {
        evs.iter().any(|e| {
            matches!(e, IrcEvent::Msg { ref nick, ref text, .. } if nick == "alice" && text == "still alive")
        })
    })
    .await;
    assert!(
        events.iter().any(|e| matches!(e, IrcEvent::Msg { nick, text, .. } if nick == "alice" && text == "still alive")),
        "traffic after the overlong line was lost: {events:?}"
    );
    ctx.send(ClientCommand::Quit).await.ok();
    let _ = tokio::time::timeout(Duration::from_secs(5), handle).await;

    let sent = wait_until(&lines, Duration::from_secs(5), |seen| {
        seen.iter().any(|l| l == "PONG :probe")
    })
    .await;
    assert!(
        sent.iter().any(|l| l == "PONG :probe"),
        "the PING after the overlong line was not answered: {sent:?}"
    );
}

