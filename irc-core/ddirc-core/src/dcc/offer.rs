//! Reading a `DCC SEND` offer off the wire.
//!
//! Everything in an offer is written by the other side. The filename, the
//! address, the port and the size are all attacker-controlled, and two of them
//! are dangerous in ways that are easy to miss:
//!
//! - **The filename** is used to name a file on disk. `../../.bashrc` and
//!   `C:\Windows\System32\drivers\etc\hosts` are both legal IRC strings, and a
//!   client that writes to the name it was given writes wherever it was told
//!   to. [`safe_filename`] reduces it to a bare name or refuses it.
//! - **The address** is somewhere this machine will be asked to connect. It is
//!   parsed into an [`IpAddr`] and nothing more; deciding whether to dial it is
//!   not this module's business, and loopback and private ranges are left for
//!   the caller to judge rather than quietly accepted here.
//!
//! Parsing is deliberately total: every malformed offer is [`None`], never a
//! panic and never a partial value.

use std::net::{IpAddr, Ipv4Addr};

/// A `DCC SEND` offer, as received.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DccOffer {
    /// The name to save it under, already reduced to something safe.
    ///
    /// Not what the sender wrote, if what they wrote could escape a directory
    /// — see [`safe_filename`]. The original is deliberately not kept: a field
    /// holding the raw name is a field some later caller will use.
    pub filename: String,

    /// Where to connect, for a normal offer.
    ///
    /// [`None`] for a reverse offer, where the *sender* connects to us and
    /// there is no address here to dial.
    pub addr: Option<IpAddr>,

    /// The port to connect to. [`None`] for a reverse offer.
    pub port: Option<u16>,

    /// How large the sender says the file is. Their claim, not a fact: the
    /// transfer has to hold the connection to it rather than trust it.
    pub size: Option<u64>,

    /// The token identifying a reverse offer, echoed back when accepting.
    ///
    /// Present exactly when this is a reverse offer, which is the case that
    /// works when the sender is behind NAT — or behind Tor, where they have no
    /// address to give out in the first place.
    pub token: Option<u64>,
}

impl DccOffer {
    /// Whether the sender is asking *us* to listen, rather than offering an
    /// address to dial.
    pub fn is_reverse(&self) -> bool {
        self.token.is_some()
    }
}

/// Parse the body of a CTCP message as a `DCC SEND` offer.
///
/// `body` is the CTCP payload with the `\x01` delimiters already removed —
/// `DCC SEND cat.jpg 3232235777 5001 12345`.
///
/// Returns [`None`] for anything that is not a well-formed `SEND`, including
/// other DCC commands: recognising one thing and ignoring the rest is what
/// keeps this from becoming a way to make the client do arbitrary work.
pub fn parse_send(body: &str) -> Option<DccOffer> {
    let rest = strip_keyword(body, "DCC")?;
    let rest = strip_keyword(rest, "SEND")?;

    let (name, rest) = take_filename(rest)?;
    let filename = safe_filename(name)?;

    let mut args = rest.split_whitespace();
    let addr = args.next()?;
    let port: u16 = args.next()?.parse().ok()?;
    // Size is optional in the wild. Old clients omit it, and an offer without
    // one is still an offer — it just cannot be shown with a total.
    let size = args.next().and_then(|s| s.parse::<u64>().ok());
    let token = args.next().and_then(|s| s.parse::<u64>().ok());

    // Port 0 is the marker for a reverse offer: there is nothing to dial, and
    // the token is what ties our listener back to this offer. A zero port with
    // no token is not a reverse offer, it is a broken one.
    if port == 0 {
        return Some(DccOffer {
            filename,
            addr: None,
            port: None,
            size,
            token: Some(token?),
        });
    }

    Some(DccOffer {
        filename,
        addr: Some(parse_addr(addr)?),
        port: Some(port),
        size,
        token: None,
    })
}

/// Case-insensitively strip a leading keyword and the space after it.
fn strip_keyword<'a>(s: &'a str, keyword: &str) -> Option<&'a str> {
    let s = s.trim_start();
    let (head, rest) = s.split_at_checked(keyword.len())?;
    if !head.eq_ignore_ascii_case(keyword) {
        return None;
    }
    // A keyword has to be followed by a space, or `DCCSEND` would parse.
    if !rest.starts_with(' ') {
        return None;
    }
    Some(rest.trim_start())
}

/// Take the filename, which may be quoted because it may contain spaces.
///
/// Returns the raw name and whatever follows it. The name is not yet safe —
/// [`safe_filename`] is a separate step so that the two jobs, finding where
/// the name ends and deciding whether it may be used, cannot be confused for
/// each other.
fn take_filename(s: &str) -> Option<(&str, &str)> {
    if let Some(rest) = s.strip_prefix('"') {
        let end = rest.find('"')?;
        Some((&rest[..end], &rest[end + 1..]))
    } else {
        let end = s.find(' ')?;
        Some((&s[..end], &s[end..]))
    }
}

/// Reduce an offered filename to something safe to create.
///
/// The rules, and why each one is here:
///
/// - **Every path separator ends the name.** Only the last component is kept,
///   so `../../.bashrc` becomes `.bashrc` and `C:\Windows\...\hosts` becomes
///   `hosts`. Both `/` and `\` count, whatever this platform thinks, because
///   the name was written somewhere else.
/// - **`.` and `..` are refused**, since neither is a file to write.
/// - **Control characters are refused**, including NUL. A name is going to a
///   filesystem API and possibly through a shell in someone's file manager.
/// - **Empty is refused**, which also covers a name that was nothing but
///   separators.
/// - **Long is refused.** 255 bytes is the common limit for a single component
///   and a longer one fails at the filesystem anyway, later and less clearly.
///
/// Deliberately *not* done: rewriting Windows-reserved names (`CON`, `NUL`,
/// `COM1`), stripping trailing dots and spaces, or making the result unique.
/// Those matter at the point of creating the file, where the directory is
/// known and a collision can be answered by picking another name — doing it
/// here would give a false sense that the string is now safe for anything.
pub fn safe_filename(name: &str) -> Option<String> {
    let bare = name.rsplit(['/', '\\']).next().unwrap_or(name);

    if bare.is_empty() || bare == "." || bare == ".." {
        return None;
    }
    if bare.len() > 255 {
        return None;
    }
    if bare.chars().any(|c| c.is_control()) {
        return None;
    }
    Some(bare.to_owned())
}

/// Parse a DCC address.
///
/// Three forms are in use. The first is the one the protocol actually
/// specifies and the one that looks least like an address: a 32-bit integer in
/// decimal, host byte order, so `127.0.0.1` is `2130706433`.
fn parse_addr(s: &str) -> Option<IpAddr> {
    // Tried first, because a bare integer is unambiguous and `parse::<IpAddr>`
    // would reject it.
    if let Ok(packed) = s.parse::<u32>() {
        return Some(IpAddr::V4(Ipv4Addr::from(packed)));
    }
    // Modern clients send literals, and IPv6 has no packed form at all.
    s.trim_matches(['[', ']']).parse::<IpAddr>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_offer_parses() {
        let offer = parse_send("DCC SEND cat.jpg 3232235777 5001 12345").unwrap();
        assert_eq!(offer.filename, "cat.jpg");
        assert_eq!(offer.addr, Some(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))));
        assert_eq!(offer.port, Some(5001));
        assert_eq!(offer.size, Some(12345));
        assert!(!offer.is_reverse());
    }

    #[test]
    fn the_packed_address_is_the_one_the_protocol_specifies() {
        // 2130706433 is 127.0.0.1, and looks like nothing at all until decoded.
        let offer = parse_send("DCC SEND f 2130706433 1 1").unwrap();
        assert_eq!(offer.addr, Some(IpAddr::V4(Ipv4Addr::LOCALHOST)));
    }

    #[test]
    fn literals_work_too_because_clients_send_them() {
        let v4 = parse_send("DCC SEND f 192.168.1.1 1 1").unwrap();
        assert_eq!(v4.addr, Some(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))));

        let v6 = parse_send("DCC SEND f [2001:db8::1] 1 1").unwrap();
        assert_eq!(v6.addr, Some("2001:db8::1".parse::<IpAddr>().unwrap()));
    }

    #[test]
    fn a_quoted_filename_may_contain_spaces() {
        let offer = parse_send("DCC SEND \"holiday photo.jpg\" 1 2 3").unwrap();
        assert_eq!(offer.filename, "holiday photo.jpg");
        assert_eq!(offer.port, Some(2));
    }

    #[test]
    fn a_zero_port_with_a_token_is_a_reverse_offer() {
        // The case that works when the sender has no address to give out —
        // behind NAT, or behind Tor.
        let offer = parse_send("DCC SEND f 0 0 4096 7788").unwrap();
        assert!(offer.is_reverse());
        assert_eq!(offer.token, Some(7788));
        assert_eq!(offer.addr, None);
        assert_eq!(offer.port, None);
        assert_eq!(offer.size, Some(4096));
    }

    #[test]
    fn a_zero_port_without_a_token_is_broken_rather_than_reverse() {
        assert!(parse_send("DCC SEND f 0 0 4096").is_none());
    }

    #[test]
    fn a_missing_size_is_still_an_offer() {
        // Old clients omit it. It costs a total in the UI, not the transfer.
        let offer = parse_send("DCC SEND f 1 2").unwrap();
        assert_eq!(offer.size, None);
        assert_eq!(offer.port, Some(2));
    }

    #[test]
    fn only_send_is_recognised() {
        for other in [
            "DCC CHAT chat 1 2",
            "DCC RESUME f 2 3",
            "DCC ACCEPT f 2 3",
            "DCC XMIT f 1 2",
        ] {
            assert!(parse_send(other).is_none(), "{other} should not parse");
        }
    }

    #[test]
    fn the_keyword_has_to_be_a_keyword() {
        assert!(parse_send("DCCSEND f 1 2 3").is_none());
        assert!(parse_send("SEND f 1 2 3").is_none());
        assert!(parse_send("NOTDCC SEND f 1 2 3").is_none());
        // Case is not significant, though, and clients vary.
        assert!(parse_send("dcc send f 1 2 3").is_some());
    }

    #[test]
    fn nothing_malformed_panics_or_half_parses() {
        for junk in [
            "",
            "DCC",
            "DCC ",
            "DCC SEND",
            "DCC SEND ",
            "DCC SEND f",
            "DCC SEND f 1",
            "DCC SEND f notanaddress 1 1",
            "DCC SEND f 1 notaport 1",
            "DCC SEND f 1 99999 1",
            "DCC SEND \"unterminated 1 2 3",
            "DCC SEND f 4294967296 1 1",
        ] {
            assert!(parse_send(junk).is_none(), "{junk:?} should not parse");
        }
    }

    #[test]
    fn a_filename_cannot_escape_the_directory_it_is_saved_in() {
        // The whole reason this module has a sanitiser. Both separators, on
        // every platform: the name was written somewhere else.
        assert_eq!(safe_filename("../../.bashrc").unwrap(), ".bashrc");
        assert_eq!(safe_filename("/etc/passwd").unwrap(), "passwd");
        assert_eq!(
            safe_filename(r"C:\Windows\System32\drivers\etc\hosts").unwrap(),
            "hosts"
        );
        assert_eq!(safe_filename("a/b/c/d.txt").unwrap(), "d.txt");
    }

    #[test]
    fn a_filename_that_is_not_a_file_is_refused() {
        for bad in ["", ".", "..", "/", "///", r"..\..", "a/..", "a/"] {
            assert!(safe_filename(bad).is_none(), "{bad:?} should be refused");
        }
    }

    #[test]
    fn control_characters_are_refused_rather_than_stripped() {
        // Stripping would silently turn two different offers into one name.
        assert!(safe_filename("evil\u{0}.txt").is_none());
        assert!(safe_filename("evil\n.txt").is_none());
        assert!(safe_filename("evil\r\n.txt").is_none());
        assert!(safe_filename("bell\u{7}").is_none());
    }

    #[test]
    fn an_absurdly_long_name_is_refused() {
        assert!(safe_filename(&"a".repeat(255)).is_some());
        assert!(safe_filename(&"a".repeat(256)).is_none());
    }

    #[test]
    fn a_dangerous_name_takes_the_whole_offer_down_with_it() {
        // Not "parsed with a blank name": an offer whose filename cannot be
        // used is not an offer that can be accepted.
        assert!(parse_send("DCC SEND \"../../.bashrc\" 1 2 3").is_some());
        assert!(parse_send("DCC SEND \"..\" 1 2 3").is_none());
        assert!(parse_send("DCC SEND \"\" 1 2 3").is_none());
    }
}
