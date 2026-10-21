//! Parsing and neutralisation of IRC (mIRC) in-band formatting codes.
//!
//! Everything a server sends is untrusted. Rather than handing raw bytes to the
//! UI and hoping it renders them safely, we parse the formatting codes here and
//! emit structured [`TextSpan`]s whose `text` is guaranteed free of C0 control
//! characters. A malicious message therefore cannot inject line breaks, reorder
//! the layout, or forge the styling we reserve for system messages.

use std::iter::Peekable;
use std::str::Chars;

/// Styling flags carried by a run of text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SpanStyle {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub monospace: bool,
    /// mIRC "reverse video". Renderers may ignore it; we preserve the intent.
    pub inverse: bool,
    /// mIRC colour index, if a colour was in effect.
    pub fg: Option<u8>,
    pub bg: Option<u8>,
}

/// A run of text sharing one style.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextSpan {
    pub text: String,
    pub style: SpanStyle,
}

// mIRC / IRCv3 formatting control characters.
const BOLD: char = '\u{02}';
const COLOR: char = '\u{03}';
const HEX_COLOR: char = '\u{04}';
const RESET: char = '\u{0F}';
const MONOSPACE: char = '\u{11}';
const INVERSE: char = '\u{16}';
const ITALIC: char = '\u{1D}';
const STRIKETHROUGH: char = '\u{1E}';
const UNDERLINE: char = '\u{1F}';

/// True for characters that must never reach the UI as literal text.
///
/// Covers the whole C0 range plus DEL. Note that tab is included: it can be
/// used to fake the indentation that distinguishes our system messages.
fn is_forbidden(c: char) -> bool {
    (c as u32) < 0x20 || c == '\u{7F}'
}

/// Parse `input` into styled spans, discarding formatting codes and stripping
/// any control character that survives.
///
/// Adjacent runs sharing a style are merged and empty runs are dropped, so the
/// output carries no zero-width noise for the UI to lay out.
pub fn parse(input: &str) -> Vec<TextSpan> {
    let mut spans: Vec<TextSpan> = Vec::new();
    let mut style = SpanStyle::default();
    let mut buf = String::new();
    let mut chars = input.chars().peekable();

    while let Some(c) = chars.next() {
        match c {
            // Every formatting code closes the current run before it takes
            // effect, so the run keeps the style it was written under.
            BOLD | ITALIC | UNDERLINE | STRIKETHROUGH | MONOSPACE | INVERSE | RESET | COLOR
            | HEX_COLOR => {
                flush(&mut spans, &mut buf, style);
                match c {
                    BOLD => style.bold = !style.bold,
                    ITALIC => style.italic = !style.italic,
                    UNDERLINE => style.underline = !style.underline,
                    STRIKETHROUGH => style.strikethrough = !style.strikethrough,
                    MONOSPACE => style.monospace = !style.monospace,
                    INVERSE => style.inverse = !style.inverse,
                    RESET => style = SpanStyle::default(),
                    COLOR => {
                        // A bare \x03 clears colour but leaves the rest alone.
                        let (fg, bg) = take_color(&mut chars);
                        style.fg = fg;
                        style.bg = bg;
                    }
                    // \x04RRGGBB[,RRGGBB]. We do not model 24-bit colour, so
                    // the payload is consumed rather than leaked as text.
                    _ => {
                        take_hex_color(&mut chars);
                        style.fg = None;
                        style.bg = None;
                    }
                }
            }
            c if is_forbidden(c) => {}
            c => buf.push(c),
        }
    }
    flush(&mut spans, &mut buf, style);
    spans
}

/// Close the pending run, merging into the previous span if styles match.
fn flush(spans: &mut Vec<TextSpan>, buf: &mut String, style: SpanStyle) {
    if buf.is_empty() {
        return;
    }
    let text = std::mem::take(buf);
    match spans.last_mut() {
        Some(last) if last.style == style => last.text.push_str(&text),
        _ => spans.push(TextSpan { text, style }),
    }
}

/// Consume an optional `NN[,NN]` colour payload following `\x03`.
///
/// Returns `(None, None)` for a bare `\x03`. A comma is only a separator when
/// digits follow it, so `\x0304,hello` keeps ",hello" as literal text.
fn take_color(chars: &mut Peekable<Chars<'_>>) -> (Option<u8>, Option<u8>) {
    let Some(fg) = take_digits(chars) else {
        return (None, None);
    };

    if chars.peek() == Some(&',') {
        // Look past the comma without committing. Cloning a Chars is cheap (it
        // is a slice cursor) and lets us rewind when no digits follow.
        let mut lookahead = chars.clone();
        lookahead.next();
        if let Some(bg) = take_digits(&mut lookahead) {
            *chars = lookahead;
            return (Some(fg), Some(bg));
        }
    }
    (Some(fg), None)
}

/// Consume one or two ASCII digits, returning the value they encode.
fn take_digits(chars: &mut Peekable<Chars<'_>>) -> Option<u8> {
    let mut value: u16 = 0;
    let mut seen = 0;
    while seen < 2 {
        match chars.peek() {
            Some(c) if c.is_ascii_digit() => {
                value = value * 10 + (*c as u16 - u16::from(b'0'));
                chars.next();
                seen += 1;
            }
            _ => break,
        }
    }
    (seen > 0).then(|| value.min(u16::from(u8::MAX)) as u8)
}

/// Consume an optional `RRGGBB[,RRGGBB]` payload following `\x04`.
fn take_hex_color(chars: &mut Peekable<Chars<'_>>) {
    fn take_six(chars: &mut Peekable<Chars<'_>>) -> bool {
        let mut lookahead = chars.clone();
        for _ in 0..6 {
            match lookahead.next() {
                Some(c) if c.is_ascii_hexdigit() => {}
                _ => return false,
            }
        }
        *chars = lookahead;
        true
    }

    if take_six(chars) && chars.peek() == Some(&',') {
        let mut lookahead = chars.clone();
        lookahead.next();
        if take_six(&mut lookahead) {
            *chars = lookahead;
        }
    }
}

/// Flatten `input` to plain text with all formatting and control codes removed.
///
/// Used for mention matching and notification previews, where styling is noise.
pub fn strip(input: &str) -> String {
    parse(input).into_iter().map(|s| s.text).collect()
}

/// Write spans back out as mIRC codes, so [`parse`] recovers them exactly.
///
/// The inverse of [`parse`], and it exists for one reason: the message store
/// keeps a line as a single string, and a store that kept the flattened text
/// would quietly turn every saved message plain. Encoding back into the same
/// codes the message arrived in means the database holds one `TEXT` column and
/// history reloads through the parser that every other message goes through —
/// no second representation to keep in step, and no serialisation format to
/// version.
///
/// Each span opens with a reset and states its style in full rather than
/// emitting the difference from the previous one. Absolute is not merely
/// simpler here, it is safer: a diff that is wrong produces a line that is
/// subtly mis-styled from that point on, and nothing about the output would
/// say so.
pub fn encode(spans: &[TextSpan]) -> String {
    let mut out = String::new();
    for span in spans {
        // Nothing before this span can leak into it.
        out.push(RESET);
        if span.style.bold {
            out.push(BOLD);
        }
        if span.style.italic {
            out.push(ITALIC);
        }
        if span.style.underline {
            out.push(UNDERLINE);
        }
        if span.style.strikethrough {
            out.push(STRIKETHROUGH);
        }
        if span.style.monospace {
            out.push(MONOSPACE);
        }
        if span.style.inverse {
            out.push(INVERSE);
        }
        if let Some(fg) = span.style.fg {
            out.push(COLOR);
            // Always two digits. A one-digit colour would swallow a leading
            // digit of the text as the second, which is the classic mIRC
            // encoding bug and produces a different colour *and* a missing
            // character.
            out.push_str(&format!("{:02}", fg));
            if let Some(bg) = span.style.bg {
                out.push(',');
                out.push_str(&format!("{:02}", bg));
            }
            // A colour with no background, followed by text that opens with a
            // comma and a digit, would have that comma read as the separator
            // and the digits eaten as a background. Two bold toggles cancel
            // out, change no style, produce no span of their own — and end the
            // colour payload so the comma stays literal.
            if span.style.bg.is_none() && opens_like_a_background(&span.text) {
                out.push(BOLD);
                out.push(BOLD);
            }
        }
        out.push_str(&span.text);
    }
    out
}

/// Whether `text` starts with something [`take_color`] would mistake for the
/// background half of a colour code.
fn opens_like_a_background(text: &str) -> bool {
    let mut chars = text.chars();
    chars.next() == Some(',') && chars.next().is_some_and(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_is_untouched() {
        let spans = parse("hello world");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].text, "hello world");
        assert_eq!(spans[0].style, SpanStyle::default());
    }

    #[test]
    fn bold_toggles_on_and_off() {
        let spans = parse("a\u{02}b\u{02}c");
        assert_eq!(spans.len(), 3);
        assert!(!spans[0].style.bold);
        assert!(spans[1].style.bold);
        assert!(!spans[2].style.bold);
        assert_eq!(strip("a\u{02}b\u{02}c"), "abc");
    }

    #[test]
    fn every_attribute_toggles_independently() {
        let spans = parse("\u{1D}i\u{1F}u\u{1E}s\u{11}m\u{16}v");
        let last = spans.last().unwrap().style;
        assert!(last.italic && last.underline && last.strikethrough);
        assert!(last.monospace && last.inverse);
        assert!(!last.bold);
    }

    #[test]
    fn parses_foreground_and_background_color() {
        let spans = parse("\u{03}04,08warn");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].style.fg, Some(4));
        assert_eq!(spans[0].style.bg, Some(8));
        assert_eq!(spans[0].text, "warn");
    }

    #[test]
    fn single_digit_color_is_accepted() {
        let spans = parse("\u{03}4red");
        assert_eq!(spans[0].style.fg, Some(4));
        assert_eq!(spans[0].text, "red");
    }

    #[test]
    fn comma_without_digits_stays_literal() {
        // Regression: naive parsers eat the comma and the word after it.
        let spans = parse("\u{03}04,hello");
        assert_eq!(spans[0].style.fg, Some(4));
        assert_eq!(spans[0].style.bg, None);
        assert_eq!(spans[0].text, ",hello");
    }

    #[test]
    fn bare_color_code_resets_color_only() {
        let spans = parse("\u{02}\u{03}04a\u{03}b");
        let last = spans.last().unwrap();
        assert_eq!(last.text, "b");
        assert_eq!(last.style.fg, None, "bare \\x03 clears colour");
        assert!(last.style.bold, "but leaves bold intact");
    }

    #[test]
    fn reset_clears_every_attribute() {
        let spans = parse("\u{02}\u{1F}\u{03}04a\u{0F}b");
        let last = spans.last().unwrap();
        assert_eq!(last.style, SpanStyle::default());
        assert_eq!(last.text, "b");
    }

    #[test]
    fn truncated_color_code_at_end_of_input() {
        // Must not panic nor emit stray digits.
        assert_eq!(strip("text\u{03}"), "text");
        assert_eq!(strip("text\u{03}0"), "text");
        assert_eq!(strip("text\u{03}04,"), "text,");
    }

    #[test]
    fn control_characters_are_stripped() {
        // Newlines and tabs could be used to forge system-message layout.
        assert_eq!(strip("a\nb\rc\td\u{07}e\u{7F}f"), "abcdef");
    }

    #[test]
    fn hex_color_payload_is_consumed_not_leaked() {
        assert_eq!(strip("\u{04}FF0000red"), "red");
        assert_eq!(strip("\u{04}FF0000,00FF00red"), "red");
        // A malformed payload must not swallow real text.
        assert_eq!(strip("\u{04}ZZmsg"), "ZZmsg");
    }

    #[test]
    fn adjacent_same_style_runs_are_merged() {
        let spans = parse("\u{03}04a\u{03}04b");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].text, "ab");
    }

    #[test]
    fn three_digit_color_takes_only_two() {
        // "\x03123" is colour 12 followed by the literal "3".
        let spans = parse("\u{03}123");
        assert_eq!(spans[0].style.fg, Some(12));
        assert_eq!(spans[0].text, "3");
    }

    #[test]
    fn empty_input_yields_no_spans() {
        assert!(parse("").is_empty());
        assert!(
            parse("\u{02}\u{0F}").is_empty(),
            "codes alone produce nothing"
        );
    }

    #[test]
    fn unicode_is_preserved() {
        assert_eq!(strip("\u{02}héllo → 世界"), "héllo → 世界");
    }

    /// The property the message store depends on: whatever a message arrived
    /// as, saving and reloading it produces the same spans. Checked as a
    /// round-trip rather than against a fixed encoding, because it is the
    /// round-trip and not the byte sequence that anything relies on.
    #[track_caller]
    fn round_trips(input: &str) {
        let once = parse(input);
        let again = parse(&encode(&once));
        assert_eq!(once, again, "re-parsing {input:?} lost or changed styling");
    }

    #[test]
    fn encoding_round_trips_through_the_parser() {
        for input in [
            "plain text",
            "\u{02}bold\u{02} and not",
            "\u{1D}italic\u{1F}underlined\u{1E}struck\u{11}mono\u{16}inverse",
            "\u{03}04red\u{03}09,01 on green \u{0F}back to nothing",
            "\u{02}\u{1D}both at once\u{0F}",
            "héllo → 世界 \u{02}emoji 🎉\u{02}",
            "\u{03}12three digits: 3",
        ] {
            round_trips(input);
        }
    }

    #[test]
    fn a_colour_followed_by_a_comma_and_digits_survives() {
        // The encoding trap: "\x0304" then ",5" would be read back as
        // foreground 4 on background 5, with the ",5" gone from the text.
        round_trips("\u{03}04\u{02}\u{02},5 past midnight");

        let spans = parse(&encode(&[TextSpan {
            text: ",50 of them".to_owned(),
            style: SpanStyle {
                fg: Some(4),
                ..SpanStyle::default()
            },
        }]));
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].text, ",50 of them");
        assert_eq!(spans[0].style.fg, Some(4));
        assert_eq!(spans[0].style.bg, None);
    }

    #[test]
    fn encoding_nothing_produces_nothing() {
        assert!(parse(&encode(&[])).is_empty());
    }
}
