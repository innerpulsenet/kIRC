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
use kirc_core::{
    run_session, ClientCommand, ConnectionConfig, IrcEvent, SaslConfig, SaslMechanism,
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

    assert!(events.iter().any(|e| matches!(e, IrcEvent::Join { channel, nick, account: Some(a) } if channel == "#rust" && nick == "alice" && a == "account/alice")), "extended-join account missing");
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
