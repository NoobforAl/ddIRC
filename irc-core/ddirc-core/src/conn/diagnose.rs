//! Turning connection failures into sentences a user can act on.
//!
//! The `irc` crate's own `Display` is not usable as a user-facing message. Its
//! most common variant reads, in full:
//!
//! ```text
//! an io error occurred
//! ```
//!
//! The `io::Error` is attached as a `#[source]` but never printed, so a typo in
//! a hostname, a firewall, a server that is down and a port that is wrong all
//! arrive looking identical — and none of them says what to do next. The TLS
//! variant is the same shape.
//!
//! So we do not print the error. We classify it, name the host and port that
//! failed, and say what would usually fix it. Where we cannot classify it we
//! fall back to walking the source chain, which at minimum recovers the detail
//! the crate dropped.

use std::io::ErrorKind;

use irc::error::Error as IrcError;

/// Describe a failed connection attempt.
///
/// `host` and `port` are the ones that were dialled, because "connection
/// refused" without them is barely more useful than "an io error occurred" —
/// the user may have several networks configured and no idea which one this is
/// about.
pub fn explain(error: &IrcError, host: &str, port: u16) -> String {
    match error {
        IrcError::Io(io) => explain_io(io, host, port),

        IrcError::Tls(_) => format!(
            "Could not agree a secure connection with {host}:{port}. \
             If this is a private or self-signed server, its certificate is \
             not trusted by this machine. Details: {}",
            chain(error)
        ),

        IrcError::InvalidDnsNameError(_) => format!(
            "'{host}' is not a valid hostname, so its certificate cannot be \
             checked. An IP address needs the certificate to list that address."
        ),

        IrcError::PingTimeout => format!(
            "{host} stopped responding. The connection was dropped after no \
             reply to a ping."
        ),

        IrcError::NoUsableNick => "Every nickname was already taken. Add \
             alternates in the network's settings, or pick another."
            .to_owned(),

        // Everything else is a protocol or internal fault the user cannot act
        // on, so the honest thing is the detail rather than a guess.
        other => chain(other),
    }
}

fn explain_io(io: &std::io::Error, host: &str, port: u16) -> String {
    match io.kind() {
        ErrorKind::ConnectionRefused => format!(
            "{host}:{port} refused the connection. The server may be down, or \
             the port may be wrong — IRC over TLS is usually 6697."
        ),

        ErrorKind::TimedOut => format!(
            "{host}:{port} did not answer in time. The address may be wrong, \
             or a firewall may be dropping the connection."
        ),

        ErrorKind::ConnectionReset | ErrorKind::ConnectionAborted => format!(
            "{host} closed the connection. Servers do this when they are full, \
             when the client is banned, or when a K-line is in force."
        ),

        ErrorKind::PermissionDenied => format!(
            "This machine refused to open a connection to {host}:{port}. A \
             firewall or a network policy is usually the reason."
        ),

        // Not a distinct ErrorKind on every platform, so this is matched on the
        // message rather than on the kind. It is worth the special case: a
        // mistyped hostname is the single most likely way to arrive here, and
        // the raw text ("failed to lookup address information") does not say so.
        _ if is_dns_failure(io) => format!(
            "Could not find '{host}'. Check the address for a typo, and check \
             that this machine has a working internet connection."
        ),

        // The fallback still beats the status quo, because it prints the
        // io::Error that the irc crate leaves out.
        _ => format!("Could not reach {host}:{port}: {io}"),
    }
}

/// Whether an I/O error is a name-resolution failure.
///
/// `ErrorKind` has no variant for this on stable, and the platforms disagree:
/// Windows reports `WSAHOST_NOT_FOUND` (11001), Unix returns `EAI_NONAME` from
/// `getaddrinfo` wrapped in an uncategorised error. Matching the text is
/// unlovely, but the alternative is telling the user their server refused a
/// connection when the name never resolved at all.
fn is_dns_failure(io: &std::io::Error) -> bool {
    if io.raw_os_error() == Some(11001) {
        return true;
    }
    let text = io.to_string().to_ascii_lowercase();
    text.contains("lookup address")
        || text.contains("name or service not known")
        || text.contains("nodename nor servname")
        || text.contains("no such host")
}

/// The error and every cause beneath it, joined.
///
/// Used wherever we cannot say anything better, so that a message which drops
/// its own cause — as the `irc` crate's does — still arrives with the detail
/// attached.
pub fn chain(error: &dyn std::error::Error) -> String {
    let mut parts = vec![error.to_string()];
    let mut source = error.source();
    while let Some(cause) = source {
        let text = cause.to_string();
        // Nested errors often restate their parent; repeating it adds nothing.
        if !parts.iter().any(|p| p == &text) {
            parts.push(text);
        }
        source = cause.source();
    }
    parts.join(": ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn io_error(kind: ErrorKind, message: &str) -> IrcError {
        IrcError::Io(io_of(kind, message))
    }

    /// `Error::new` with `ErrorKind::Other` is deprecated in favour of
    /// `Error::other`, so route both through one place rather than repeating
    /// the special case at every call site.
    fn io_of(kind: ErrorKind, message: &str) -> std::io::Error {
        if kind == ErrorKind::Other {
            std::io::Error::other(message)
        } else {
            std::io::Error::new(kind, message)
        }
    }

    #[test]
    fn a_refused_connection_names_the_host_and_the_usual_cause() {
        let message = explain(
            &io_error(ErrorKind::ConnectionRefused, "refused"),
            "irc.example.org",
            6697,
        );
        assert!(message.contains("irc.example.org:6697"));
        assert!(message.contains("refused the connection"));
    }

    #[test]
    fn a_name_that_does_not_resolve_says_so() {
        // The case the old message got most wrong: nothing was refused and
        // nothing timed out, the name simply does not exist.
        let message = explain(
            &io_error(ErrorKind::Other, "failed to lookup address information"),
            "irc.exmaple.org",
            6697,
        );
        assert!(message.contains("Could not find 'irc.exmaple.org'"));
        assert!(message.contains("typo"));
    }

    #[test]
    fn an_unclassified_io_error_still_carries_its_own_text() {
        // The whole point: the irc crate would have said only "an io error
        // occurred" and dropped this.
        let message = explain(
            &io_error(ErrorKind::BrokenPipe, "the pipe broke"),
            "irc.example.org",
            6697,
        );
        assert!(message.contains("the pipe broke"), "{message}");
    }

    #[test]
    fn nothing_reports_the_useless_default() {
        // A guard against regressing to the crate's own Display, whatever the
        // kind. If this fails, some path is printing the error directly again.
        for kind in [
            ErrorKind::ConnectionRefused,
            ErrorKind::TimedOut,
            ErrorKind::ConnectionReset,
            ErrorKind::PermissionDenied,
            ErrorKind::BrokenPipe,
            ErrorKind::Other,
        ] {
            let message = explain(&io_error(kind, "detail"), "host.test", 6697);
            assert!(
                !message.contains("an io error occurred"),
                "{kind:?} leaked the crate's message: {message}"
            );
            assert!(!message.is_empty());
        }
    }

    #[test]
    fn a_ping_timeout_explains_what_dropped_the_connection() {
        let message = explain(&IrcError::PingTimeout, "irc.example.org", 6697);
        assert!(message.contains("stopped responding"));
    }

    #[test]
    fn taken_nicknames_point_at_the_setting_that_fixes_it() {
        let message = explain(&IrcError::NoUsableNick, "irc.example.org", 6697);
        assert!(message.contains("alternates"));
    }

    #[test]
    fn the_chain_keeps_the_cause_the_top_level_omits() {
        let error = io_error(ErrorKind::ConnectionRefused, "connection refused");
        let text = chain(&error);
        assert!(text.starts_with("an io error occurred"));
        assert!(
            text.contains("connection refused"),
            "the source must survive: {text}"
        );
    }

    #[test]
    fn the_chain_does_not_repeat_itself() {
        // thiserror's `#[from]` often produces a parent whose Display is its
        // child's, and printing it twice reads like a stutter.
        let error = io_of(ErrorKind::Other, "the same text");
        assert_eq!(chain(&error), "the same text");
    }
}
