//! IRCv3 line parser.
//!
//! Handles the full client-relevant grammar:
//!
//! ```text
//! [ '@' tags SP ] [ ':' prefix SP ] command [ SP params ] [ SP ':' trailing ]
//! ```
//!
//! Tag values are unescaped per the IRCv3 `message-tags` specification
//! (`\:` -> `;`, `\s` -> space, `\\` -> `\`, `\r` -> CR, `\n` -> LF).

use std::collections::BTreeMap;

use thiserror::Error;

/// Hard sanity limit for a single IRC line (daemons cap at 512 for send, but
/// servers may deliver tag-heavy lines up to ~8191; anything beyond this is
/// treated as a protocol violation rather than being parsed).
pub const MAX_LINE_LEN: usize = 8192;

/// Errors produced while parsing an IRC line.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ParseError {
    /// The line was empty (or only contained a CR/LF terminator).
    #[error("empty message line")]
    Empty,
    /// The line exceeded [`MAX_LINE_LEN`].
    #[error("message line exceeds {MAX_LINE_LEN} bytes (got {0} bytes)")]
    TooLong(usize),
    /// The line was structurally invalid.
    #[error("malformed message: {0}")]
    Malformed(String),
}

/// The source of a message: `nick!ident@host`, a bare `nick`, or a
/// `server.name`. All components are optional because servers omit theirs.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Prefix {
    /// Nickname, when the source is a user.
    pub nick: Option<String>,
    /// Ident (username), when present.
    pub ident: Option<String>,
    /// Hostname or server name.
    pub host: Option<String>,
    /// The prefix exactly as it appeared on the wire (without the leading `:`).
    pub raw: String,
}

impl Prefix {
    /// Best-effort display name: nick, else host/server name, else raw.
    pub fn name(&self) -> &str {
        self.nick
            .as_deref()
            .or(self.host.as_deref())
            .unwrap_or(self.raw.as_str())
    }
}

/// A fully parsed IRC message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IrcMessage {
    /// IRCv3 message tags, with values already unescaped. A tag present without
    /// `=` (e.g. `@draft/foo`) maps to `None`; a tag with `=` maps to `Some`.
    pub tags: BTreeMap<String, Option<String>>,
    /// Parsed message source, if the line had one.
    pub prefix: Option<Prefix>,
    /// Command, upper-cased (`PRIVMSG`, `001`, `CAP`, ...).
    pub command: String,
    /// Command parameters; a trailing parameter keeps its embedded spaces.
    pub params: Vec<String>,
}

impl IrcMessage {
    /// Convenience accessor for a tag value.
    pub fn tag(&self, key: &str) -> Option<&str> {
        self.tags.get(key).and_then(|v| v.as_deref())
    }

    /// The nick of the sender, if the prefix carried one.
    pub fn nick(&self) -> Option<&str> {
        self.prefix.as_ref().and_then(|p| p.nick.as_deref())
    }

    /// The trailing / final parameter, if any.
    pub fn last_param(&self) -> Option<&str> {
        self.params.last().map(|s| s.as_str())
    }
}

/// Parse a single IRC protocol line (CR/LF optional) into an [`IrcMessage`].
pub fn parse_message(line: &str) -> Result<IrcMessage, ParseError> {
    let line = line.trim_end_matches(['\r', '\n']);
    if line.is_empty() {
        return Err(ParseError::Empty);
    }
    if line.len() > MAX_LINE_LEN {
        return Err(ParseError::TooLong(line.len()));
    }

    let mut rest = line;

    // --- tags -------------------------------------------------------------
    let mut tags = BTreeMap::new();
    if let Some(stripped) = rest.strip_prefix('@') {
        let (tag_str, remainder) = match stripped.find(' ') {
            Some(i) => (&stripped[..i], &stripped[i + 1..]),
            None => return Err(ParseError::Malformed("tags without a command".into())),
        };
        tags = parse_tags(tag_str);
        rest = remainder;
    }

    // --- prefix -----------------------------------------------------------
    let mut prefix = None;
    if let Some(stripped) = rest.strip_prefix(':') {
        let (pfx, remainder) = match stripped.find(' ') {
            Some(i) => (&stripped[..i], &stripped[i + 1..]),
            None => return Err(ParseError::Malformed("prefix without a command".into())),
        };
        prefix = Some(parse_prefix(pfx));
        rest = remainder;
    }

    // --- command ----------------------------------------------------------
    rest = rest.trim_start_matches(' ');
    if rest.is_empty() {
        return Err(ParseError::Malformed("missing command".into()));
    }
    let cmd_end = rest.find(' ').unwrap_or(rest.len());
    let command = rest[..cmd_end].to_ascii_uppercase();
    if command.is_empty() {
        return Err(ParseError::Malformed("missing command".into()));
    }

    // --- params -----------------------------------------------------------
    let mut params = Vec::new();
    let mut pr = &rest[cmd_end..];
    loop {
        pr = pr.trim_start_matches(' ');
        if pr.is_empty() {
            break;
        }
        if let Some(trailing) = pr.strip_prefix(':') {
            params.push(trailing.to_string());
            break;
        }
        let end = pr.find(' ').unwrap_or(pr.len());
        params.push(pr[..end].to_string());
        pr = &pr[end..];
    }

    Ok(IrcMessage {
        tags,
        prefix,
        command,
        params,
    })
}

/// Whether a message's source nick matches `nick` (case-insensitive, exact).
///
/// Exact matching matters: a source nick that merely *contains* the configured
/// nickname (`kircuserx`) must not be treated as us.
pub fn prefix_matches(message: &IrcMessage, nick: &str) -> bool {
    message
        .nick()
        .map(|n| n.eq_ignore_ascii_case(nick))
        .unwrap_or(false)
}

/// Parse the `@`-prefixed tag section (without the leading `@`).
fn parse_tags(section: &str) -> BTreeMap<String, Option<String>> {
    let mut tags = BTreeMap::new();
    for pair in section.split(';') {
        if pair.is_empty() {
            continue;
        }
        match pair.split_once('=') {
            Some((key, value)) if !key.is_empty() => {
                tags.insert(key.to_string(), Some(unescape_tag_value(value)));
            }
            Some(_) => {}
            None => {
                tags.insert(pair.to_string(), None);
            }
        }
    }
    tags
}

/// Unescape an IRCv3 tag value.
pub fn unescape_tag_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some(':') => out.push(';'),
                Some('s') => out.push(' '),
                Some('\\') => out.push('\\'),
                Some('r') => out.push('\r'),
                Some('n') => out.push('\n'),
                // Unknown escape: the backslash is dropped and the literal kept.
                Some(other) => out.push(other),
                // Dangling backslash at end of value: dropped.
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Escape a value for use in the IRCv3 tag section.
pub fn escape_tag_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            ';' => out.push_str("\\:"),
            ' ' => out.push_str("\\s"),
            '\\' => out.push_str("\\\\"),
            '\r' => out.push_str("\\r"),
            '\n' => out.push_str("\\n"),
            other => out.push(other),
        }
    }
    out
}

/// Parse a message prefix (`nick!ident@host`, `nick`, `ident@host`, `server.name`).
pub fn parse_prefix(raw: &str) -> Prefix {
    if let Some((nick, remainder)) = raw.split_once('!') {
        let (ident, host) = match remainder.split_once('@') {
            Some((i, h)) => (Some(i.to_string()), Some(h.to_string())),
            None => (Some(remainder.to_string()), None),
        };
        return Prefix {
            nick: Some(nick.to_string()),
            ident,
            host,
            raw: raw.to_string(),
        };
    }

    if let Some((ident, host)) = raw.split_once('@') {
        return Prefix {
            nick: None,
            ident: Some(ident.to_string()),
            host: Some(host.to_string()),
            raw: raw.to_string(),
        };
    }

    // A bare token containing a dot is a server name; otherwise it is a nick.
    if raw.contains('.') {
        Prefix {
            nick: None,
            ident: None,
            host: Some(raw.to_string()),
            raw: raw.to_string(),
        }
    } else {
        Prefix {
            nick: Some(raw.to_string()),
            ident: None,
            host: None,
            raw: raw.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_privmsg() {
        let m = parse_message(":nick!user@host PRIVMSG #chan :hello world\r\n").unwrap();
        assert_eq!(m.command, "PRIVMSG");
        assert_eq!(
            m.params,
            vec!["#chan".to_string(), "hello world".to_string()]
        );
        assert!(m.tags.is_empty());
        let p = m.prefix.unwrap();
        assert_eq!(p.nick.as_deref(), Some("nick"));
        assert_eq!(p.ident.as_deref(), Some("user"));
        assert_eq!(p.host.as_deref(), Some("host"));
        assert_eq!(p.raw, "nick!user@host");
    }

    #[test]
    fn parses_tags_with_escaping() {
        let m = parse_message(
            "@time=2026-09-11T12:00:00.000Z;account=foo;draft/x;msgid=abc\\:def;text=a\\sb\\\\c \
             :nick!u@h PRIVMSG #chan :hi",
        )
        .unwrap();
        assert_eq!(m.tag("time"), Some("2026-09-11T12:00:00.000Z"));
        assert_eq!(m.tag("account"), Some("foo"));
        assert_eq!(m.tag("draft/x"), None); // valueless tag -> None
        assert!(m.tags.contains_key("draft/x"));
        assert_eq!(m.tag("msgid"), Some("abc;def"));
        assert_eq!(m.tag("text"), Some("a b\\c"));
        assert_eq!(m.params[0], "#chan");
        assert_eq!(m.params[1], "hi");
    }

    #[test]
    fn unescape_all_escapes() {
        assert_eq!(unescape_tag_value("a\\:b"), "a;b");
        assert_eq!(unescape_tag_value("a\\sb"), "a b");
        assert_eq!(unescape_tag_value("a\\\\b"), "a\\b");
        assert_eq!(unescape_tag_value("a\\rb"), "a\rb");
        assert_eq!(unescape_tag_value("a\\nb"), "a\nb");
        assert_eq!(unescape_tag_value("a\\zb"), "azb");
        assert_eq!(unescape_tag_value("trailing\\"), "trailing");
        assert_eq!(unescape_tag_value("plain"), "plain");
    }

    #[test]
    fn escape_round_trips() {
        let raw = "semi; space\\ slash\r\nend";
        assert_eq!(unescape_tag_value(&escape_tag_value(raw)), raw);
    }

    #[test]
    fn prefix_variants() {
        let full = parse_prefix("nick!ident@host.example");
        assert_eq!(full.nick.as_deref(), Some("nick"));
        assert_eq!(full.ident.as_deref(), Some("ident"));
        assert_eq!(full.host.as_deref(), Some("host.example"));

        let bare_nick = parse_prefix("justanick");
        assert_eq!(bare_nick.nick.as_deref(), Some("justanick"));
        assert_eq!(bare_nick.ident, None);
        assert_eq!(bare_nick.host, None);

        let server = parse_prefix("irc.ergo.chat");
        assert_eq!(server.nick, None);
        assert_eq!(server.host.as_deref(), Some("irc.ergo.chat"));

        let host_only = parse_prefix("ident@only.host");
        assert_eq!(host_only.nick, None);
        assert_eq!(host_only.ident.as_deref(), Some("ident"));
        assert_eq!(host_only.host.as_deref(), Some("only.host"));

        let partial = parse_prefix("nick!identonly");
        assert_eq!(partial.nick.as_deref(), Some("nick"));
        assert_eq!(partial.ident.as_deref(), Some("identonly"));
        assert_eq!(partial.host, None);
    }

    #[test]
    fn trailing_param_keeps_spaces_and_empty_trailing() {
        let m = parse_message(":s NOTICE me :  leading spaces  ").unwrap();
        assert_eq!(
            m.params,
            vec!["me".to_string(), "  leading spaces  ".to_string()]
        );

        let empty = parse_message(":s PRIVMSG #c :").unwrap();
        assert_eq!(empty.params, vec!["#c".to_string(), String::new()]);
    }

    #[test]
    fn empty_params_and_no_params() {
        let none = parse_message("PING").unwrap();
        assert!(none.params.is_empty());
        assert_eq!(none.command, "PING");

        let trailing_only = parse_message("ERROR :Closing Link").unwrap();
        assert_eq!(trailing_only.command, "ERROR");
        assert_eq!(trailing_only.params, vec!["Closing Link".to_string()]);

        let multi = parse_message(":s 372 me : - some motd").unwrap();
        assert_eq!(multi.command, "372");
        assert_eq!(multi.params.len(), 2);
        assert_eq!(multi.params[1], " - some motd");
    }

    #[test]
    fn command_is_uppercased() {
        assert_eq!(parse_message("privmsg #c :x").unwrap().command, "PRIVMSG");
        assert_eq!(parse_message("cap ls 302").unwrap().command, "CAP");
    }

    #[test]
    fn rejects_empty_and_oversized() {
        assert_eq!(parse_message(""), Err(ParseError::Empty));
        assert_eq!(parse_message("\r\n"), Err(ParseError::Empty));
        let big = "a".repeat(MAX_LINE_LEN + 1);
        assert!(matches!(parse_message(&big), Err(ParseError::TooLong(_))));
    }

    #[test]
    fn numeric_message() {
        let m = parse_message(":irc.example 001 mynick :Welcome to IRC").unwrap();
        assert_eq!(m.command, "001");
        assert_eq!(m.params[0], "mynick");
        assert_eq!(m.params[1], "Welcome to IRC");
        assert_eq!(m.prefix.unwrap().host.as_deref(), Some("irc.example"));
    }
}
