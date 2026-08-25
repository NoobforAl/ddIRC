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
//! variant is the same shape, and so is the proxy one.
//!
//! So we do not print the error. We classify it, name the host and port that
//! failed, and say what would usually fix it. Where we cannot classify it we
//! fall back to walking the source chain, which at minimum recovers the detail
//! the crate dropped.
//!
//! A proxy changes what the same failure means, which is why every function
//! here is told whether one was in use. "Could not find 'irc.example.org'" is
//! wrong advice when the name was never ours to resolve, and "the server
//! refused the connection" is wrong when the refusal came from a SOCKS5 reply
//! about a machine we never spoke to.

use std::io::ErrorKind;

use irc::error::Error as IrcError;
use tokio_socks::Error as SocksError;

use crate::api::types::{ProxyConfig, ServerConfig};

/// Describe a failed connection attempt.
///
/// Takes the whole config rather than a host and port, because the proxy
/// setting changes the meaning of nearly every error below — and because
/// "connection refused" on its own is barely more useful than "an io error
/// occurred" to a user with several networks configured.
pub fn explain(error: &IrcError, config: &ServerConfig) -> String {
    let host = config.host.as_str();
    let port = config.port;
    let proxy = config.proxy.as_ref();

    match error {
        IrcError::Io(io) => explain_io(io, host, port, proxy),

        IrcError::Proxy(socks) => match proxy {
            Some(proxy) => explain_socks(socks, proxy, host, port),
            // Cannot happen: the transport only produces this variant when it
            // was asked for a proxy. Handled anyway, because a message that
            // says something true is better than a panic if it ever does.
            None => chain(error),
        },

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

/// How to name the proxy in a message: `host:port`, as it was typed.
fn label(proxy: &ProxyConfig) -> String {
    format!("{}:{}", proxy.host, proxy.port)
}

/// The line to add when a proxy is configured and Tor is the likely intent.
///
/// Only offered for the port Tor listens on, so it does not become noise for
/// someone running an ordinary SOCKS5 proxy who has never used Tor.
fn tor_hint(proxy: &ProxyConfig) -> &'static str {
    if proxy.port == ProxyConfig::TOR_SOCKS_PORT {
        " If this is Tor, check that it is running."
    } else {
        ""
    }
}

fn explain_io(io: &std::io::Error, host: &str, port: u16, proxy: Option<&ProxyConfig>) -> String {
    // With a proxy, the tunnel is already open by the time an I/O error can
    // mean anything: the proxy did the connecting, and reported its own result
    // as a SOCKS reply. So the advice below — wrong port, mistyped name, a
    // firewall between here and the server — is about a hop that never
    // happened, and saying it would send the user looking in the wrong place.
    if let Some(proxy) = proxy {
        return format!(
            "The connection to {host}:{port} through the proxy at {} failed \
             after the tunnel was open: {io}",
            label(proxy)
        );
    }

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

/// Describe a SOCKS5 failure.
///
/// The distinction that matters in almost every case is *which* hop broke: the
/// one to the proxy, or the one the proxy makes on our behalf. They are fixed
/// in completely different places, and the underlying messages ("Connection
/// refused", "General SOCKS server failure") do not say which is which.
fn explain_socks(error: &SocksError, proxy: &ProxyConfig, host: &str, port: u16) -> String {
    let at = label(proxy);
    match error {
        // Hop one. Nothing left this machine for the server.
        SocksError::ProxyServerUnreachable => format!(
            "Could not reach the proxy at {at}, so nothing was sent to {host}. \
             Check that the proxy is running and listening on that port.{}",
            tor_hint(proxy)
        ),

        // Answered, but not in SOCKS5. Pointing this at an HTTP proxy or an
        // ordinary web server is the commonest way to land here, and the raw
        // "Invalid response version" gives no hint of that.
        SocksError::InvalidResponseVersion | SocksError::UnknownAddressType => format!(
            "Whatever is listening at {at} did not answer as a SOCKS5 proxy. \
             An HTTP proxy or an ordinary web server on that port would look \
             exactly like this — ddIRC speaks SOCKS5 only."
        ),

        // Credentials. Three variants, one thing to go and fix.
        SocksError::PasswordAuthFailure(_)
        | SocksError::NoAcceptableAuthMethods
        | SocksError::UnknownAuthMethod
        | SocksError::AuthorizationRequired => format!(
            "The proxy at {at} refused the username and password. Check them \
             in the network's proxy settings — leave both blank if the proxy \
             does not ask for credentials."
        ),

        SocksError::InvalidAuthValues(detail) => format!(
            "The proxy credentials are not usable: {detail}. SOCKS5 allows \
             1 to 255 bytes for each."
        ),

        // Hop two. The proxy is fine; it could not get where it was sent.
        SocksError::ConnectionRefused => format!(
            "The proxy at {at} reached {host}:{port} and the connection was \
             refused. The server may be down, or the port may be wrong — IRC \
             over TLS is usually 6697."
        ),

        SocksError::HostUnreachable => format!(
            "The proxy at {at} could not reach {host}. If the address is right, \
             the problem is on the proxy's side of the network, not this one."
        ),

        SocksError::NetworkUnreachable => {
            format!("The proxy at {at} has no route to {host}:{port}.")
        }

        SocksError::ConnectionNotAllowedByRuleset => format!(
            "The proxy at {at} refused to connect to {host}:{port}. Its rules \
             do not permit that destination."
        ),

        SocksError::TtlExpired => format!("The proxy at {at} gave up on the way to {host}:{port}."),

        // Tor answers with this for a name it cannot resolve, among other
        // things, so it is worth naming both possibilities rather than one.
        SocksError::GeneralSocksServerFailure => format!(
            "The proxy at {at} could not connect to {host}:{port}, and did not \
             say why. A name it cannot resolve is the usual cause."
        ),

        SocksError::InvalidTargetAddress(detail) => {
            format!("'{host}' cannot be sent to a SOCKS5 proxy: {detail}.")
        }

        SocksError::CommandNotSupported | SocksError::AddressTypeNotSupported => {
            format!("The proxy at {at} does not support what ddIRC asked of it: {error}.")
        }

        // Whatever is left still names the proxy, which is the one thing the
        // underlying message never does.
        other => format!("The proxy at {at} failed: {other}"),
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

    fn config() -> ServerConfig {
        ServerConfig {
            host: "irc.example.org".to_owned(),
            port: 6697,
            nickname: "ddirc".to_owned(),
            ..Default::default()
        }
    }

    fn through(port: u16) -> ServerConfig {
        ServerConfig {
            proxy: Some(ProxyConfig {
                host: "127.0.0.1".to_owned(),
                port,
                ..Default::default()
            }),
            ..config()
        }
    }

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
            &config(),
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
            &ServerConfig {
                host: "irc.exmaple.org".to_owned(),
                ..config()
            },
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
            &config(),
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
            for config in [config(), through(9050)] {
                let message = explain(&io_error(kind, "detail"), &config);
                assert!(
                    !message.contains("an io error occurred"),
                    "{kind:?} leaked the crate's message: {message}"
                );
                assert!(!message.is_empty());
            }
        }
    }

    #[test]
    fn a_ping_timeout_explains_what_dropped_the_connection() {
        let message = explain(&IrcError::PingTimeout, &config());
        assert!(message.contains("stopped responding"));
    }

    #[test]
    fn taken_nicknames_point_at_the_setting_that_fixes_it() {
        let message = explain(&IrcError::NoUsableNick, &config());
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

    // -- proxy ---------------------------------------------------------------

    fn socks(error: SocksError, config: &ServerConfig) -> String {
        explain(&IrcError::Proxy(error), config)
    }

    #[test]
    fn an_unreachable_proxy_says_nothing_was_sent() {
        // The distinction the raw message misses entirely: this failure is
        // about the first hop, and the server was never involved.
        let message = socks(SocksError::ProxyServerUnreachable, &through(9050));
        assert!(message.contains("127.0.0.1:9050"), "{message}");
        assert!(message.contains("nothing was sent"), "{message}");
    }

    #[test]
    fn tor_is_only_mentioned_on_tors_port() {
        // Useful on 9050, noise on someone's corporate SOCKS5 proxy.
        let tor = socks(SocksError::ProxyServerUnreachable, &through(9050));
        assert!(tor.contains("Tor"), "{tor}");

        let other = socks(SocksError::ProxyServerUnreachable, &through(1080));
        assert!(!other.contains("Tor"), "{other}");
    }

    #[test]
    fn a_refusal_from_the_proxy_is_not_a_refusal_by_the_server() {
        // Both hops can produce "connection refused". They are fixed in
        // different places, so the message has to say which one it was.
        let direct = explain(
            &io_error(ErrorKind::ConnectionRefused, "refused"),
            &config(),
        );
        let proxied = socks(SocksError::ConnectionRefused, &through(1080));

        assert!(!direct.contains("proxy"), "{direct}");
        assert!(proxied.contains("The proxy at 127.0.0.1:1080"), "{proxied}");
        assert!(proxied.contains("irc.example.org:6697"), "{proxied}");
    }

    #[test]
    fn something_that_is_not_socks5_on_the_port_is_named_as_such() {
        let message = socks(SocksError::InvalidResponseVersion, &through(8080));
        assert!(
            message.contains("did not answer as a SOCKS5 proxy"),
            "{message}"
        );
        assert!(message.contains("HTTP proxy"), "{message}");
    }

    #[test]
    fn every_authentication_failure_points_at_the_credentials() {
        for error in [
            SocksError::PasswordAuthFailure(1),
            SocksError::NoAcceptableAuthMethods,
            SocksError::UnknownAuthMethod,
        ] {
            let message = socks(error, &through(1080));
            assert!(message.contains("username and password"), "{message}");
        }
    }

    #[test]
    fn a_proxied_dns_failure_does_not_blame_the_address() {
        // Under a proxy the name is resolved at the far end, so "check the
        // address for a typo" would send the user to the wrong place.
        let message = socks(SocksError::GeneralSocksServerFailure, &through(9050));
        assert!(!message.contains("typo"), "{message}");
        assert!(message.contains("resolve"), "{message}");
    }

    #[test]
    fn every_proxy_failure_names_the_proxy() {
        // The one thing tokio-socks never says, and the first thing a user
        // needs to know: which of the two machines this is about.
        for error in [
            SocksError::ProxyServerUnreachable,
            SocksError::ConnectionRefused,
            SocksError::HostUnreachable,
            SocksError::NetworkUnreachable,
            SocksError::ConnectionNotAllowedByRuleset,
            SocksError::TtlExpired,
            SocksError::GeneralSocksServerFailure,
            SocksError::CommandNotSupported,
            SocksError::UnknownError,
            SocksError::InvalidReservedByte,
        ] {
            let message = socks(error, &through(1080));
            assert!(
                message.contains("127.0.0.1:1080"),
                "the proxy went unnamed: {message}"
            );
            assert!(!message.contains("a proxy error occurred"), "{message}");
        }
    }

    #[test]
    fn an_io_failure_through_a_proxy_says_where_it_got_to() {
        // Distinguishes "the tunnel never opened" from "it opened and then
        // broke", which are different problems with different owners.
        let message = explain(&io_error(ErrorKind::BrokenPipe, "pipe"), &through(9050));
        assert!(message.contains("after the tunnel was open"), "{message}");
        assert!(message.contains("127.0.0.1:9050"), "{message}");
        assert!(!message.contains("typo"), "{message}");
    }
}
