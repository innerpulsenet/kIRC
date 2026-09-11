//! SASL authentication: PLAIN, SCRAM-SHA-256 (full RFC 5802 client) and EXTERNAL.
//!
//! The session drives this state machine. After the server selects the
//! mechanism it replies with `AUTHENTICATE +`; [`SaslClient::initial`] then
//! produces the first payload and each subsequent server `AUTHENTICATE <data>`
//! is fed to [`SaslClient::feed`].

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use thiserror::Error;

type HmacSha256 = Hmac<Sha256>;

/// Supported SASL mechanisms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SaslMechanism {
    /// `PLAIN` — `authzid NUL authcid NUL passwd`, base64 encoded.
    Plain,
    /// `SCRAM-SHA-256` — full RFC 5802 / RFC 7677 client.
    ScramSha256,
    /// `EXTERNAL` — TLS client certificate; no payload.
    External,
}

/// SASL credentials + mechanism selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaslConfig {
    /// Mechanism to negotiate.
    pub mechanism: SaslMechanism,
    /// Account name.
    pub username: String,
    /// Password (ignored for `EXTERNAL`).
    pub password: String,
}

/// Errors raised during a SASL exchange.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SaslError {
    /// A base64 payload from the server could not be decoded.
    #[error("invalid base64 in SASL payload: {0}")]
    Base64(String),
    /// The server sent something that violates the selected mechanism.
    #[error("SASL protocol error: {0}")]
    Protocol(String),
    /// The server's SCRAM server-signature did not match our computation.
    #[error("SASL server signature verification failed")]
    SignatureMismatch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScramStep {
    Initial,
    AwaitServerFirst,
    AwaitServerFinal,
    Done,
}

/// Client-side SASL state machine.
#[derive(Debug, Clone)]
pub struct SaslClient {
    mechanism: SaslMechanism,
    username: String,
    password: String,
    nonce: String,
    step: ScramStep,
    client_first_bare: String,
    server_first: String,
    client_final_without_proof: String,
    expected_server_signature: Option<Vec<u8>>,
}

impl SaslClient {
    /// Create a client with a cryptographically random SCRAM nonce.
    pub fn new(config: &SaslConfig) -> Self {
        Self::with_nonce(config, random_nonce())
    }

    /// Create a client with an explicit nonce (used by tests / vectors).
    pub fn with_nonce(config: &SaslConfig, nonce: String) -> Self {
        SaslClient {
            mechanism: config.mechanism,
            username: config.username.clone(),
            password: config.password.clone(),
            nonce,
            step: ScramStep::Initial,
            client_first_bare: String::new(),
            server_first: String::new(),
            client_final_without_proof: String::new(),
            expected_server_signature: None,
        }
    }

    /// The wire name of the selected mechanism.
    pub fn mechanism_name(&self) -> &'static str {
        match self.mechanism {
            SaslMechanism::Plain => "PLAIN",
            SaslMechanism::ScramSha256 => "SCRAM-SHA-256",
            SaslMechanism::External => "EXTERNAL",
        }
    }

    /// Whether the exchange has finished sending (waiting for the numeric).
    pub fn is_complete(&self) -> bool {
        self.step == ScramStep::Done
    }

    /// The first `AUTHENTICATE` payload, sent in response to `AUTHENTICATE +`.
    ///
    /// For `EXTERNAL` this is `+` (empty response).
    pub fn initial(&mut self) -> String {
        match self.mechanism {
            SaslMechanism::Plain => {
                // authzid is empty: the authcid is used as the authorization id.
                let payload = format!("\0{}\0{}", self.username, self.password);
                B64.encode(payload.as_bytes())
            }
            SaslMechanism::External => "+".to_string(),
            SaslMechanism::ScramSha256 => {
                self.client_first_bare =
                    format!("n={},r={}", sasl_name(&self.username), self.nonce);
                self.step = ScramStep::AwaitServerFirst;
                let message = format!("n,,{}", self.client_first_bare);
                B64.encode(message.as_bytes())
            }
        }
    }

    /// Feed a server `AUTHENTICATE <arg>` payload.
    ///
    /// Returns `Some(next_payload)` when the client must send another
    /// `AUTHENTICATE`, or `None` when it is done sending and simply awaits the
    /// success numeric.
    pub fn feed(&mut self, server_arg: &str) -> Result<Option<String>, SaslError> {
        match self.mechanism {
            SaslMechanism::Plain | SaslMechanism::External => {
                self.step = ScramStep::Done;
                Ok(None)
            }
            SaslMechanism::ScramSha256 => self.feed_scram(server_arg),
        }
    }

    fn feed_scram(&mut self, server_arg: &str) -> Result<Option<String>, SaslError> {
        match self.step {
            ScramStep::AwaitServerFirst => {
                let decoded = B64
                    .decode(server_arg.as_bytes())
                    .map_err(|e| SaslError::Base64(e.to_string()))?;
                let server_first = String::from_utf8(decoded)
                    .map_err(|e| SaslError::Protocol(format!("non-UTF8 server-first: {e}")))?;
                self.server_first = server_first.clone();

                let attrs = parse_scram_attrs(&server_first);
                let combined_nonce = attrs
                    .get("r")
                    .ok_or_else(|| SaslError::Protocol("server-first missing 'r'".into()))?
                    .clone();
                let salt_b64 = attrs
                    .get("s")
                    .ok_or_else(|| SaslError::Protocol("server-first missing 's'".into()))?
                    .clone();
                let iterations: u32 = attrs
                    .get("i")
                    .ok_or_else(|| SaslError::Protocol("server-first missing 'i'".into()))?
                    .parse()
                    .map_err(|_| SaslError::Protocol("server-first 'i' is not a number".into()))?;
                if !combined_nonce.starts_with(&self.nonce)
                    || combined_nonce.len() <= self.nonce.len()
                {
                    return Err(SaslError::Protocol(
                        "server nonce does not extend the client nonce".into(),
                    ));
                }
                let salt = B64
                    .decode(salt_b64.as_bytes())
                    .map_err(|e| SaslError::Base64(e.to_string()))?;

                let salted_password = hi(self.password.as_bytes(), &salt, iterations);
                let client_key = hmac_sha256(&salted_password, b"Client Key");
                let stored_key = sha256(&client_key);

                self.client_final_without_proof =
                    format!("c={},r={}", B64.encode(b"n,,"), combined_nonce);
                let auth_message = format!(
                    "{},{},{}",
                    self.client_first_bare, self.server_first, self.client_final_without_proof
                );
                let client_signature = hmac_sha256(&stored_key, auth_message.as_bytes());
                let mut proof = client_key;
                for (p, s) in proof.iter_mut().zip(client_signature.iter()) {
                    *p ^= *s;
                }

                let server_key = hmac_sha256(&salted_password, b"Server Key");
                let server_signature = hmac_sha256(&server_key, auth_message.as_bytes());
                self.expected_server_signature = Some(server_signature.to_vec());
                self.step = ScramStep::AwaitServerFinal;

                let final_message = format!(
                    "{},p={}",
                    self.client_final_without_proof,
                    B64.encode(proof)
                );
                Ok(Some(B64.encode(final_message.as_bytes())))
            }
            ScramStep::AwaitServerFinal => {
                let decoded = B64
                    .decode(server_arg.as_bytes())
                    .map_err(|e| SaslError::Base64(e.to_string()))?;
                let server_final = String::from_utf8(decoded)
                    .map_err(|e| SaslError::Protocol(format!("non-UTF8 server-final: {e}")))?;
                let attrs = parse_scram_attrs(&server_final);
                if let Some(err) = attrs.get("e") {
                    return Err(SaslError::Protocol(format!("server rejected proof: {err}")));
                }
                let v = attrs
                    .get("v")
                    .ok_or_else(|| SaslError::Protocol("server-final missing 'v'".into()))?;
                let signature = B64
                    .decode(v.as_bytes())
                    .map_err(|e| SaslError::Base64(e.to_string()))?;
                match self.expected_server_signature.as_ref() {
                    Some(expected) if constant_time_eq(expected, &signature) => {}
                    Some(_) => return Err(SaslError::SignatureMismatch),
                    None => {
                        return Err(SaslError::Protocol(
                            "no expected server signature recorded".into(),
                        ))
                    }
                }
                self.step = ScramStep::Done;
                Ok(None)
            }
            _ => Err(SaslError::Protocol(
                "unexpected SASL step: no server-first received yet".into(),
            )),
        }
    }
}

/// Parse SCRAM attribute lists (`r=...,s=...,i=...`) into a map.
fn parse_scram_attrs(s: &str) -> Vec<(String, String)> {
    let mut attrs = Vec::new();
    for part in s.split(',') {
        if let Some((k, v)) = part.split_once('=') {
            attrs.push((k.to_string(), v.to_string()));
        }
    }
    attrs
}

/// Small helper to look up the first value for a SCRAM attribute key.
trait ScramLookup {
    fn get(&self, key: &str) -> Option<&String>;
}
impl ScramLookup for Vec<(String, String)> {
    fn get(&self, key: &str) -> Option<&String> {
        self.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
}

/// SCRAM `saslname`: escape `=` and `,` as required by RFC 5802.
fn sasl_name(name: &str) -> String {
    name.replace('=', "=3D").replace(',', "=2C")
}

/// HMAC-SHA-256. Any key length is legal, so this never fails.
fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC-SHA256 accepts keys of any length");
    mac.update(data);
    let out = mac.finalize().into_bytes();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

/// SHA-256.
fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

/// PBKDF2-HMAC-SHA-256 with a single block (`Hi` from RFC 5802).
fn hi(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut salt_block = Vec::with_capacity(salt.len() + 4);
    salt_block.extend_from_slice(salt);
    salt_block.extend_from_slice(&1u32.to_be_bytes());

    let mut u = hmac_sha256(password, &salt_block);
    let mut result = u;
    let rounds = if iterations == 0 { 1 } else { iterations };
    for _ in 1..rounds {
        u = hmac_sha256(password, &u);
        for (r, x) in result.iter_mut().zip(u.iter()) {
            *r ^= *x;
        }
    }
    result
}

/// Length-checked, branch-free-ish comparison (not a security boundary here,
/// but avoids any early-exit on the signature bytes).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// A random, printable, comma-free SCRAM client nonce.
fn random_nonce() -> String {
    use rand::Rng;
    const CHARSET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    (0..32)
        .map(|_| CHARSET[rng.gen_range(0..CHARSET.len())] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain_cfg() -> SaslConfig {
        SaslConfig {
            mechanism: SaslMechanism::Plain,
            username: "user".to_string(),
            password: "hunter2".to_string(),
        }
    }

    #[test]
    fn plain_encoding_is_nul_user_nul_pass() {
        let mut client = SaslClient::new(&plain_cfg());
        let payload = client.initial();
        let decoded = B64.decode(payload.as_bytes()).unwrap();
        assert_eq!(decoded, b"\0user\0hunter2");
        assert_eq!(client.mechanism_name(), "PLAIN");
        // PLAIN has nothing further to send.
        assert_eq!(client.feed("+").unwrap(), None);
        assert!(client.is_complete());
    }

    #[test]
    fn plain_empty_password() {
        let cfg = SaslConfig {
            mechanism: SaslMechanism::Plain,
            username: "u".to_string(),
            password: String::new(),
        };
        let mut client = SaslClient::new(&cfg);
        let decoded = B64.decode(client.initial().as_bytes()).unwrap();
        assert_eq!(decoded, b"\0u\0");
    }

    #[test]
    fn external_initial_is_plus() {
        let cfg = SaslConfig {
            mechanism: SaslMechanism::External,
            username: String::new(),
            password: String::new(),
        };
        let mut client = SaslClient::new(&cfg);
        assert_eq!(client.mechanism_name(), "EXTERNAL");
        assert_eq!(client.initial(), "+");
        assert_eq!(client.feed("+").unwrap(), None);
    }

    #[test]
    fn scram_client_first_construction() {
        let cfg = SaslConfig {
            mechanism: SaslMechanism::ScramSha256,
            username: "user".to_string(),
            password: "pencil".to_string(),
        };
        let mut client = SaslClient::with_nonce(&cfg, "fixednonce123".to_string());
        assert_eq!(client.mechanism_name(), "SCRAM-SHA-256");
        let first = B64.decode(client.initial().as_bytes()).unwrap();
        assert_eq!(first, b"n,,n=user,r=fixednonce123");

        // saslname escaping of '=' and ','
        let cfg2 = SaslConfig {
            mechanism: SaslMechanism::ScramSha256,
            username: "a=b,c".to_string(),
            password: "p".to_string(),
        };
        let mut c2 = SaslClient::with_nonce(&cfg2, "nonce".to_string());
        let first2 = B64.decode(c2.initial().as_bytes()).unwrap();
        assert_eq!(first2, b"n,,n=a=3Db=2Cc,r=nonce");
    }

    /// Fixed SCRAM-SHA-256 vector. The expected `p=` proof and `v=` server
    /// signature are recomputed independently in-test from sha2 + hmac.
    #[test]
    fn scram_proof_math_matches_independent_computation() {
        let username = "user";
        let password = "pencil";
        let client_nonce = "rOprNGfwEbeRWgbNEkqO";
        let server_nonce = "%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
        let combined_nonce = format!("{client_nonce}{server_nonce}");
        let salt_b64: &str = "W22ZaJ0SNY7soEsUEjb6gQ==";
        let salt = B64.decode(salt_b64).unwrap();
        let iterations: u32 = 4096;

        let server_first = format!("r={combined_nonce},s={salt_b64},i={iterations}");

        let mut client = SaslClient::with_nonce(
            &SaslConfig {
                mechanism: SaslMechanism::ScramSha256,
                username: username.to_string(),
                password: password.to_string(),
            },
            client_nonce.to_string(),
        );
        let _ = client.initial();
        let out = client.feed(&B64.encode(server_first.as_bytes())).unwrap();
        let client_final_b64 = out.expect("client-final expected");
        let client_final =
            String::from_utf8(B64.decode(client_final_b64.as_bytes()).unwrap()).unwrap();

        let client_final_without_proof = format!("c={},r={combined_nonce}", B64.encode(b"n,,"));
        assert!(client_final.starts_with(&client_final_without_proof));
        let proof_b64 = client_final.split(",p=").nth(1).expect("proof present");

        // ----- independent recomputation with sha2 + hmac -----
        type H = Hmac<Sha256>;
        fn hmac(key: &[u8], data: &[u8]) -> Vec<u8> {
            let mut m = H::new_from_slice(key).unwrap();
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
        let salted = pbkdf2(password.as_bytes(), &salt, iterations);
        let client_key = hmac(&salted, b"Client Key");
        let stored_key = Sha256::digest(&client_key).to_vec();
        let auth_message =
            format!("n={username},r={client_nonce},{server_first},{client_final_without_proof}");
        let client_signature = hmac(&stored_key, auth_message.as_bytes());
        let expected_proof: Vec<u8> = client_key
            .iter()
            .zip(client_signature.iter())
            .map(|(a, b)| a ^ b)
            .collect();
        assert_eq!(B64.encode(&expected_proof), proof_b64);

        // Server signature verification path.
        let server_key = hmac(&salted, b"Server Key");
        let server_signature = hmac(&server_key, auth_message.as_bytes());
        let server_final = format!("v={}", B64.encode(&server_signature));
        assert_eq!(
            client.feed(&B64.encode(server_final.as_bytes())).unwrap(),
            None
        );
        assert!(client.is_complete());

        // A corrupted server signature must be rejected.
        let mut client2 = SaslClient::with_nonce(
            &SaslConfig {
                mechanism: SaslMechanism::ScramSha256,
                username: username.to_string(),
                password: password.to_string(),
            },
            client_nonce.to_string(),
        );
        let _ = client2.initial();
        let _ = client2.feed(&B64.encode(server_first.as_bytes())).unwrap();
        let bad = B64.encode(vec![0u8; 32]);
        let err = client2
            .feed(&B64.encode(format!("v={bad}").as_bytes()))
            .unwrap_err();
        assert_eq!(err, SaslError::SignatureMismatch);
    }

    #[test]
    fn scram_rejects_nonce_that_does_not_extend_client_nonce() {
        let mut client = SaslClient::with_nonce(
            &SaslConfig {
                mechanism: SaslMechanism::ScramSha256,
                username: "u".to_string(),
                password: "p".to_string(),
            },
            "abc".to_string(),
        );
        let _ = client.initial();
        let bad = B64.encode(b"r=xyz,s=c2FsdA==,i=4096");
        assert!(client.feed(&bad).is_err());
    }

    #[test]
    fn scram_reports_server_error_attribute() {
        let mut client = SaslClient::with_nonce(
            &SaslConfig {
                mechanism: SaslMechanism::ScramSha256,
                username: "u".to_string(),
                password: "p".to_string(),
            },
            "abc".to_string(),
        );
        let _ = client.initial();
        let _ = client
            .feed(&B64.encode(b"r=abcdefgh,s=c2FsdA==,i=4096"))
            .unwrap();
        let err = client.feed(&B64.encode(b"e=invalid-proof")).unwrap_err();
        assert!(matches!(err, SaslError::Protocol(_)));
    }

    #[test]
    fn scrm_lookup_helper() {
        let attrs: Vec<(String, String)> = vec![("r".into(), "1".into()), ("i".into(), "2".into())];
        assert_eq!(attrs.get("r"), Some(&"1".to_string()));
        assert_eq!(attrs.get("nope"), None);
    }
}
