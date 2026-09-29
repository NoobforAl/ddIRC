//! Replies: the one pattern ddIRC writes and reads to say "this answers that".
//!
//! IRCv3 has a tag for it, `+draft/reply=<msgid>`, and it is sent whenever the
//! server allows client tags. But most networks do not, and most clients would
//! not show the tag anyway, so every reply also carries its meaning in the text,
//! where anyone can read it:
//!
//! ```text
//! alice: «the first forty characters of what al…» the reply itself
//! ```
//!
//! To another client that is an ordinary highlight of `alice` followed by a
//! quote, which is what a person replying by hand would have typed. To ddIRC it
//! is a reply, and the prefix is lifted off and drawn as a quote box instead.
//!
//! Both halves live here, so the format cannot drift from its parser.

/// The longest excerpt quoted from the original, in characters.
///
/// Enough to recognise a line, short enough to leave room for the answer in a
/// single IRC line.
pub const MAX_EXCERPT: usize = 40;

const OPEN: char = '«';
const CLOSE: char = '»';
const ELLIPSIS: char = '…';

/// The longest nick the parser will believe. Generous: servers advertise
/// `NICKLEN`, and the largest in common use is well under this.
const MAX_NICK: usize = 64;

/// What a message is replying to, as far as it can be known.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ReplyRef {
    /// The original's `msgid`, when the server tags messages. The only exact
    /// way back to it.
    pub msgid: Option<String>,
    /// Who wrote the original. Empty when a reply arrived by tag alone, with
    /// no text prefix to say.
    pub nick: String,
    /// The start of the original, plain text. Empty under the same condition.
    pub excerpt: String,
}

/// Shorten `text` to an excerpt: plain, one line, at most [`MAX_EXCERPT`]
/// characters, with an ellipsis when anything was cut.
///
/// The closing quote mark is replaced, because an excerpt that contained one
/// would end the quote early for every reader, ddIRC included.
pub fn excerpt(text: &str) -> String {
    let flat: String = text
        .chars()
        .map(|c| match c {
            CLOSE => '"',
            c if c.is_control() => ' ',
            c => c,
        })
        .collect();
    let flat = flat.split_whitespace().collect::<Vec<_>>().join(" ");

    let mut chars = flat.chars();
    let head: String = chars.by_ref().take(MAX_EXCERPT).collect();
    if chars.next().is_some() {
        format!("{}{ELLIPSIS}", head.trim_end())
    } else {
        head
    }
}

/// The text of a reply: the quoted prefix, then what the user wrote.
pub fn format_reply(nick: &str, excerpt: &str, body: &str) -> String {
    format!("{nick}: {OPEN}{excerpt}{CLOSE} {body}")
}

/// Split a message into what it replies to and what it says, if it is a reply.
///
/// Strict on purpose. This runs on every message from everyone, and a loose
/// match would turn ordinary text that happens to contain guillemets into a
/// quote box. So the prefix has to be exactly the shape [`format_reply`]
/// writes, at the very start of the line.
pub fn parse_reply(text: &str) -> Option<(ReplyRef, &str)> {
    let (nick, rest) = text.split_once(": ")?;
    if nick.is_empty() || nick.chars().count() > MAX_NICK || !nick.chars().all(is_nick_char) {
        return None;
    }
    let rest = rest.strip_prefix(OPEN)?;
    let (quoted, body) = rest.split_once(CLOSE)?;
    if quoted.chars().count() > MAX_EXCERPT + 1 || quoted.contains(OPEN) {
        return None;
    }
    let body = body.strip_prefix(' ').unwrap_or(body);
    Some((
        ReplyRef {
            msgid: None,
            nick: nick.to_owned(),
            excerpt: quoted.to_owned(),
        },
        body,
    ))
}

/// Characters a nick can be made of, per RFC 2812 plus what real networks
/// allow. Deliberately excludes whitespace, `:` and anything that starts a
/// channel name.
fn is_nick_char(c: char) -> bool {
    c.is_alphanumeric() || "-_[]\\`^{}|".contains(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_round_trips() {
        let text = format_reply("alice", &excerpt("the build is green again"), "nice!");
        assert_eq!(text, "alice: «the build is green again» nice!");
        let (reply, body) = parse_reply(&text).unwrap();
        assert_eq!(reply.nick, "alice");
        assert_eq!(reply.excerpt, "the build is green again");
        assert_eq!(reply.msgid, None);
        assert_eq!(body, "nice!");
    }

    #[test]
    fn long_originals_are_cut_with_an_ellipsis() {
        let long = "a".repeat(100);
        let cut = excerpt(&long);
        assert_eq!(cut.chars().count(), MAX_EXCERPT + 1);
        assert!(cut.ends_with('…'));
        let text = format_reply("bob", &cut, "ok");
        let (reply, body) = parse_reply(&text).unwrap();
        assert_eq!(reply.excerpt, cut);
        assert_eq!(body, "ok");
    }

    #[test]
    fn excerpts_are_one_plain_line_without_closing_quotes() {
        assert_eq!(excerpt("one\ntwo   three"), "one two three");
        assert_eq!(excerpt("a » b"), "a \" b");
    }

    #[test]
    fn a_quote_mark_in_the_original_cannot_end_the_quote_early() {
        let text = format_reply("carol", &excerpt("x » y"), "reply");
        let (reply, body) = parse_reply(&text).unwrap();
        assert_eq!(reply.excerpt, "x \" y");
        assert_eq!(body, "reply");
    }

    #[test]
    fn ordinary_messages_are_not_replies() {
        for text in [
            "alice: hello",
            "hello «world» there",
            "#chan: «x» y",
            "two words: «x» y",
            ": «x» y",
            "alice: «unterminated",
        ] {
            assert!(parse_reply(text).is_none(), "{text:?} is not a reply");
        }
    }

    #[test]
    fn an_empty_body_is_still_a_reply() {
        let (reply, body) = parse_reply("dave: «hi»").unwrap();
        assert_eq!(reply.nick, "dave");
        assert_eq!(body, "");
    }

    #[test]
    fn unicode_counts_characters_not_bytes() {
        let cut = excerpt(&"世".repeat(60));
        assert_eq!(cut.chars().count(), MAX_EXCERPT + 1);
        assert!(parse_reply(&format_reply("eve", &cut, "好")).is_some());
    }
}
