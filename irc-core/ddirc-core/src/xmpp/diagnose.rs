//! Turning a failed connection into something a person can act on, and into a
//! decision about whether to try again.
//!
//! The XMPP counterpart of [`crate::conn::diagnose`]. What the library reports
//! is a Rust enum, and its `Display` says what happened in the library's terms:
//! "authentication error: failure from the server: NotAuthorized". The person
//! at the other end wants to be told their password is wrong.
//!
//! The second job matters more. Retrying is right for a network that dropped
//! and wrong for a password that is incorrect: the first is cured by waiting,
//! and the second is made worse by it - servers lock accounts and ban addresses
//! after repeated failures. So every failure is sorted into one of those two.

use std::collections::BTreeSet;

use tokio_xmpp::error::{AuthError, ProtocolError};
use tokio_xmpp::parsers::sasl::DefinedCondition as Sasl;
use tokio_xmpp::Error;

/// What to do about a failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnosis {
    /// What to tell the user.
    pub message: String,
    /// True when retrying cannot help, or would do harm. The connection stops
    /// and waits to be asked.
    pub fatal: bool,
}

impl Diagnosis {
    fn fatal(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            fatal: true,
        }
    }

    fn transient(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            fatal: false,
        }
    }
}

/// Explain `error`, which came from connecting to `server`.
pub fn explain(error: &Error, server: &str) -> Diagnosis {
    match error {
        Error::Auth(auth) => explain_auth(auth),
        Error::Io(io) => explain_io(io, server),
        Error::Disconnected => Diagnosis::transient("The server closed the connection."),
        Error::StreamError(e) => Diagnosis::transient(format!("The server ended the stream: {e}")),
        Error::Protocol(ProtocolError::NoTls) => Diagnosis::fatal(
            "The server does not offer an encrypted connection, and ddIRC will not \
             connect without one.",
        ),
        Error::Protocol(e) => {
            Diagnosis::transient(format!("The server sent something unexpected: {e}"))
        }
        Error::JidParse(e) => Diagnosis::fatal(format!("The account address is not valid: {e}")),
        other => Diagnosis::transient(format!("Could not connect: {other}")),
    }
}

fn explain_auth(error: &AuthError) -> Diagnosis {
    match error {
        AuthError::Fail(condition) => match condition {
            Sasl::NotAuthorized => Diagnosis::fatal(
                "The server refused the login. The account name or the password is wrong.",
            ),
            Sasl::AccountDisabled => Diagnosis::fatal("This account has been disabled."),
            Sasl::CredentialsExpired => {
                Diagnosis::fatal("The password for this account has expired and must be changed.")
            }
            Sasl::EncryptionRequired => Diagnosis::fatal(
                "The server will not log in over this connection because it is not encrypted enough.",
            ),
            Sasl::MechanismTooWeak => Diagnosis::fatal(
                "The server considers every login method this client offers too weak.",
            ),
            // The server's own way of saying "not now". Waiting is the cure.
            Sasl::TemporaryAuthFailure => {
                Diagnosis::transient("The server could not log you in just now.")
            }
            other => Diagnosis::fatal(format!("The server refused the login ({other:?}).")),
        },
        AuthError::NoMechanism => Diagnosis::fatal(
            "The server offers no login method this client is willing to use.",
        ),
        AuthError::Sasl(e) => Diagnosis::fatal(format!("The login could not be completed: {e}")),
        AuthError::ComponentFail => Diagnosis::fatal("The server refused the login."),
    }
}

fn explain_io(error: &std::io::Error, server: &str) -> Diagnosis {
    // The proxy is a separate failure from the server, and the two need
    // different advice. It arrives wrapped, so look inside.
    if let Some(socks) = error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<tokio_socks::Error>())
    {
        return explain_proxy(socks, server);
    }
    // A certificate the client will not accept is not a network problem and
    // will not go away by asking again.
    if let Some(tls) = error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<tokio_xmpp::rustls::Error>())
    {
        return explain_tls(tls, server);
    }
    match error.kind() {
        std::io::ErrorKind::TimedOut => {
            Diagnosis::transient(format!("Connecting to {server} took too long."))
        }
        std::io::ErrorKind::ConnectionRefused => Diagnosis::transient(format!(
            "{server} refused the connection. The server may be down, or this may not be \
             the port it offers encrypted connections on."
        )),
        std::io::ErrorKind::NotFound => Diagnosis::transient(format!(
            "Could not find {server}. Check the spelling, and your connection."
        )),
        _ => Diagnosis::transient(format!("The connection to {server} failed: {error}")),
    }
}

fn explain_tls(error: &tokio_xmpp::rustls::Error, server: &str) -> Diagnosis {
    use tokio_xmpp::rustls::{CertificateError, Error as Tls};
    match error {
        Tls::InvalidCertificate(CertificateError::NotValidForName)
        | Tls::InvalidCertificate(CertificateError::NotValidForNameContext { .. }) => {
            Diagnosis::fatal(format!(
                "The certificate {server} presented is for a different name than the account's \
                 domain. ddIRC will not connect to a server that cannot prove it is the right one."
            ))
        }
        Tls::InvalidCertificate(CertificateError::Expired)
        | Tls::InvalidCertificate(CertificateError::ExpiredContext { .. }) => Diagnosis::fatal(
            format!("The certificate {server} presented has expired. If this device's clock is wrong, fix that first."),
        ),
        Tls::InvalidCertificate(CertificateError::UnknownIssuer) => Diagnosis::fatal(format!(
            "The certificate {server} presented was not issued by an authority this device trusts."
        )),
        Tls::InvalidCertificate(e) => Diagnosis::fatal(format!(
            "The certificate {server} presented was refused ({e:?})."
        )),
        other => Diagnosis::transient(format!("The encrypted connection to {server} failed: {other}")),
    }
}

fn explain_proxy(error: &tokio_socks::Error, server: &str) -> Diagnosis {
    use tokio_socks::Error as Socks;
    match error {
        Socks::Io(_) => Diagnosis::transient(
            "Could not reach the proxy. Check that it is running and that its address is right.",
        ),
        Socks::HostUnreachable | Socks::NetworkUnreachable => {
            Diagnosis::transient(format!("The proxy could not reach {server}."))
        }
        Socks::ConnectionRefused => {
            Diagnosis::transient(format!("The proxy was refused by {server}."))
        }
        Socks::PasswordAuthFailure(_) | Socks::AuthorizationRequired => {
            Diagnosis::fatal("The proxy refused the username and password given for it.")
        }
        other => Diagnosis::transient(format!("The proxy could not carry the connection: {other}")),
    }
}

/// The error for a server that offered nothing this client will log in with.
pub fn no_acceptable_mechanism(advertised: &BTreeSet<String>) -> Diagnosis {
    Diagnosis::fatal(format!(
        "The server offers no login method this client is willing to use (it offered: {}).",
        crate::xmpp::auth::describe(advertised)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;

    fn auth(condition: Sasl) -> Error {
        Error::Auth(AuthError::Fail(condition))
    }

    #[test]
    fn a_wrong_password_is_fatal_and_says_so() {
        let d = explain(&auth(Sasl::NotAuthorized), "example.org");
        assert!(
            d.fatal,
            "retrying a wrong password is how accounts get locked"
        );
        assert!(d.message.contains("password"));
    }

    #[test]
    fn a_disabled_account_is_fatal() {
        assert!(explain(&auth(Sasl::AccountDisabled), "x").fatal);
        assert!(explain(&auth(Sasl::CredentialsExpired), "x").fatal);
    }

    #[test]
    fn a_temporary_failure_is_worth_another_go() {
        assert!(!explain(&auth(Sasl::TemporaryAuthFailure), "x").fatal);
    }

    #[test]
    fn no_login_method_in_common_is_fatal() {
        assert!(explain(&Error::Auth(AuthError::NoMechanism), "x").fatal);
        let offered: BTreeSet<String> = ["ANONYMOUS".to_owned()].into();
        let d = no_acceptable_mechanism(&offered);
        assert!(d.fatal);
        assert!(d.message.contains("ANONYMOUS"));
    }

    #[test]
    fn a_dropped_connection_is_transient() {
        assert!(!explain(&Error::Disconnected, "x").fatal);
        let reset = Error::Io(io::Error::from(io::ErrorKind::ConnectionReset));
        assert!(!explain(&reset, "x").fatal);
    }

    #[test]
    fn a_refused_connection_suggests_the_port() {
        let refused = Error::Io(io::Error::from(io::ErrorKind::ConnectionRefused));
        let d = explain(&refused, "example.org:5223");
        assert!(!d.fatal);
        assert!(d.message.contains("port"));
    }

    #[test]
    fn a_dead_proxy_is_named_as_the_proxy() {
        let wrapped = Error::Io(io::Error::other(tokio_socks::Error::Io(io::Error::from(
            io::ErrorKind::ConnectionRefused,
        ))));
        let d = explain(&wrapped, "example.org");
        assert!(!d.fatal);
        assert!(d.message.contains("proxy"));
    }

    #[test]
    fn a_proxy_that_rejects_our_credentials_is_fatal() {
        let wrapped = Error::Io(io::Error::other(tokio_socks::Error::PasswordAuthFailure(1)));
        assert!(explain(&wrapped, "example.org").fatal);
    }

    #[test]
    fn a_certificate_for_the_wrong_name_is_fatal_and_says_why() {
        use tokio_xmpp::rustls::{CertificateError, Error as Tls};
        let e = Error::Io(io::Error::other(Tls::InvalidCertificate(
            CertificateError::NotValidForName,
        )));
        let d = explain(&e, "example.org");
        assert!(d.fatal);
        assert!(d.message.contains("different name"));
    }

    #[test]
    fn an_unknown_issuer_and_an_expired_certificate_are_fatal() {
        use tokio_xmpp::rustls::{CertificateError, Error as Tls};
        for cert in [CertificateError::UnknownIssuer, CertificateError::Expired] {
            let e = Error::Io(io::Error::other(Tls::InvalidCertificate(cert)));
            assert!(explain(&e, "example.org").fatal);
        }
    }
}
