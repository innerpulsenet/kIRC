//! IRCv3 capability negotiation helpers.

use std::collections::BTreeSet;

/// Capabilities requested by default (beyond any user additions).
///
/// `sasl` is only actually requested when a [`crate::SaslConfig`] is present.
pub const DEFAULT_CAPS: &[&str] = &[
    "server-time",
    "message-tags",
    "account-tag",
    "extended-join",
    "batch",
    "echo-message",
    "chathistory",
    "sasl",
];

/// A parsed `CAP` message (`LS`, `ACK`, `NAK`, `NEW`, `DEL`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapLine {
    /// Subcommand, upper-cased (`LS`, `ACK`, ...).
    pub subcommand: String,
    /// Whether this line is a `CAP LS *` continuation.
    pub multiline: bool,
    /// Capability tokens advertised/acknowledged/denied on this line.
    pub caps: Vec<String>,
}

/// Parse the parameter list of a `CAP` command.
///
/// Handles both short (`CAP LS <caps>`) and target-prefixed
/// (`CAP * LS <caps>`) forms, including the `*` multi-line continuation marker.
pub fn parse_cap(params: &[String]) -> Option<CapLine> {
    if params.len() < 2 {
        return None;
    }
    // Normally params[0] is the target (our nick or `*`) and params[1] the
    // subcommand. Be defensive and also accept the target-less short form.
    const SUBCOMMANDS: &[&str] = &["LS", "ACK", "NAK", "NEW", "DEL", "LIST"];
    let start = if SUBCOMMANDS.contains(&params[0].to_ascii_uppercase().as_str()) {
        0
    } else {
        1
    };
    let subcommand = params[start].to_ascii_uppercase();
    let rest = &params[start + 1..];
    let (multiline, cap_text) = match rest.first() {
        Some(marker) if marker == "*" => (true, rest.get(1).cloned().unwrap_or_default()),
        Some(text) => (false, text.clone()),
        None => (false, String::new()),
    };
    let caps = cap_text.split_whitespace().map(|s| s.to_string()).collect();
    Some(CapLine {
        subcommand,
        multiline,
        caps,
    })
}

/// Tracks the capability set advertised by the server and what we requested.
#[derive(Debug, Clone, Default)]
pub struct CapState {
    /// Capabilities advertised via `CAP LS`.
    pub available: BTreeSet<String>,
    /// Capabilities we asked for via `CAP REQ`.
    pub requested: BTreeSet<String>,
    /// Capabilities the server acknowledged via `CAP ACK`.
    pub acked: BTreeSet<String>,
    /// True once a non-multiline `CAP LS` has been fully received.
    pub ls_complete: bool,
    /// Raw advertised tokens for the `sasl` capability (e.g.
    /// `sasl=PLAIN,EXTERNAL`), kept verbatim so SASL auto-selection can see
    /// which mechanisms the server offers. `available` only keeps the bare
    /// name, so this separate list is needed.
    pub raw_sasl_values: Vec<String>,
}

impl CapState {
    /// Record capability tokens advertised by an `LS` line.
    ///
    /// Server advertisements carry values (`sasl=PLAIN,EXTERNAL`); only the
    /// bare capability name is retained so lookups work.
    pub fn add_available(&mut self, caps: &[String]) {
        for c in caps {
            if normalize_cap(c).eq_ignore_ascii_case("sasl") {
                self.raw_sasl_values.push(c.clone());
            }
            self.available.insert(normalize_cap(c));
        }
    }

    /// Record capability tokens acknowledged by an `ACK` line.
    pub fn add_acked(&mut self, caps: &[String]) {
        for c in caps {
            self.acked.insert(normalize_cap(c));
        }
    }

    /// Forget capabilities the server removed with `CAP DEL`.
    ///
    /// Names are folded exactly like in [`CapState::add_available`], so a
    /// case-different `DEL` still clears the entry (a stale `available` entry
    /// would make the next re-negotiation request a capability the server no
    /// longer offers, which it can then NAK — or silently ignore).
    pub fn remove_available(&mut self, caps: &[String]) {
        for c in caps {
            self.available.remove(&normalize_cap(c));
        }
    }

    /// Whether the server advertised (and can therefore be asked for) `cap`.
    pub fn supports(&self, cap: &str) -> bool {
        self.available.contains(cap)
    }

    /// Whether `cap` was requested and acknowledged.
    pub fn has(&self, cap: &str) -> bool {
        self.acked.contains(cap)
    }

    /// Values the server advertised for the `sasl` capability
    /// (`sasl=PLAIN,EXTERNAL` → `["PLAIN", "EXTERNAL"]`), upper-cased for
    /// comparison. Empty when not advertised or advertised bare.
    pub fn sasl_mechanisms_offered(&self) -> Vec<String> {
        self.raw_sasl_values
            .iter()
            .flat_map(|token| {
                token
                    .split('=')
                    .nth(1)
                    .unwrap_or_default()
                    .split(',')
                    .map(str::trim)
                    .filter(|m| !m.is_empty())
                    .map(|m| m.to_ascii_uppercase())
                    .collect::<Vec<_>>()
            })
            .collect()
    }
}

/// Strip the optional `=value` suffix from a capability token and fold it to
/// lower case. Capability names are case-insensitive on the wire (IRCv3
/// `CAP`), and every lookup in this module is written against the lower-case
/// spelling, so a server advertising `SASL` must still satisfy `supports("sasl")`.
fn normalize_cap(cap: &str) -> String {
    cap.split('=').next().unwrap_or(cap).to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_single_line_ls() {
        let cl = parse_cap(&v(&["*", "LS", "server-time message-tags sasl=PLAIN"])).unwrap();
        assert_eq!(cl.subcommand, "LS");
        assert!(!cl.multiline);
        assert!(cl.caps.contains(&"sasl=PLAIN".to_string()));
    }

    #[test]
    fn parses_multiline_ls_continuation() {
        let cl = parse_cap(&v(&["*", "LS", "*", "batch chathistory"])).unwrap();
        assert!(cl.multiline);
        assert_eq!(cl.caps, v(&["batch", "chathistory"]));
    }

    #[test]
    fn parses_ack_and_nak() {
        let ack = parse_cap(&v(&["mynick", "ACK", "server-time sasl"])).unwrap();
        assert_eq!(ack.subcommand, "ACK");
        assert_eq!(ack.caps, v(&["server-time", "sasl"]));
        let nak = parse_cap(&v(&["mynick", "NAK", "sasl"])).unwrap();
        assert_eq!(nak.subcommand, "NAK");
    }

    #[test]
    fn default_caps_include_required_set() {
        for required in [
            "server-time",
            "message-tags",
            "account-tag",
            "extended-join",
            "batch",
            "echo-message",
            "chathistory",
            "sasl",
        ] {
            assert!(DEFAULT_CAPS.contains(&required), "missing {required}");
        }
    }

    #[test]
    fn cap_state_tracks_available_and_acked() {
        let mut st = CapState::default();
        st.add_available(&v(&["server-time", "sasl"]));
        st.add_acked(&v(&["server-time"]));
        assert!(st.supports("sasl"));
        assert!(st.has("server-time"));
        assert!(!st.has("sasl"));
    }

    #[test]
    fn capability_names_are_case_insensitive() {
        // IRCv3 capability names are case-insensitive; a server that shouts
        // must still satisfy the lower-case lookups.
        let mut st = CapState::default();
        st.add_available(&v(&["SASL=PLAIN", "Server-Time"]));
        assert!(st.supports("sasl"));
        assert!(st.supports("server-time"));
        assert_eq!(st.sasl_mechanisms_offered(), v(&["PLAIN"]));
        st.add_acked(&v(&["Server-Time"]));
        assert!(st.has("server-time"));
        // DEL folds the same way.
        st.remove_available(&v(&["SERVER-TIME"]));
        assert!(!st.supports("server-time"));
        assert!(st.supports("sasl"));
    }

    #[test]
    fn short_form_without_target() {
        let cl = parse_cap(&v(&["LS", "sasl"])).unwrap();
        assert_eq!(cl.subcommand, "LS");
        assert_eq!(cl.caps, v(&["sasl"]));
    }
}
