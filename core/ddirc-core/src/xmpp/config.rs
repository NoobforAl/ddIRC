//! How to reach an XMPP account, and what makes a request to do so unacceptable.
//!
//! Separate from [`crate::api::types::ServerConfig`] rather than a variant of
//! it, because the two describe different things. An IRC network is a host and
//! a nick; an XMPP account is a JID, and the host is usually *derived* from it.
//! Forcing both into one struct would leave a field in each that means nothing
//! to the other.

use std::path::Path;

use tokio_xmpp::jid::BareJid;
use zeroize::Zeroizing;

use crate::api::types::{ConfigError, ProxyConfig};

/// The port XMPP servers conventionally offer TLS-from-the-first-byte on
/// (XEP-0368, `_xmpps-client._tcp`).
pub const DEFAULT_TLS_PORT: u16 = 5223;

/// The port XMPP servers conventionally start in *plaintext* on, and upgrade
/// with STARTTLS.
///
/// Refused up front for the reason IRC's plaintext ports are: connecting to it
/// with TLS fails with a handshake error that explains nothing.
const STARTTLS_PORT: u16 = 5222;

/// Why an [`XmppConfig`] was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum XmppConfigError {
    #[error("the account address must look like name@example.org: {0}")]
    InvalidJid(String),
    #[error("an XMPP account address needs a name before the @, as in name@example.org")]
    NoLocalPart,
    #[error("the password must not be empty")]
    EmptyPassword,
    #[error("the server name must not be empty when one is given")]
    EmptyHost,
    #[error("the server port must not be 0")]
    PortZero,
    #[error(
        "port 5222 is where XMPP servers start in plaintext and upgrade with \
         STARTTLS; ddIRC requires TLS from the first byte. Use 5223, or the \
         port your server offers direct TLS on."
    )]
    StartTlsPort,
    #[error("'{0}' is not a room address; it must look like room@conference.example.org")]
    InvalidRoom(String),
    /// A problem shared with IRC: a missing certificate, a bad proxy, an onion
    /// address with no proxy to resolve it.
    #[error(transparent)]
    Common(#[from] ConfigError),
}

/// An XMPP account and how to reach it.
///
/// TLS is not configurable: every connection is direct TLS, and there is no
/// field to change that.
#[derive(Clone)]
pub struct XmppConfig {
    /// The account, as `name@example.org`. No resource: the server assigns one,
    /// so the client does not volunteer a name for itself.
    pub jid: String,
    /// Held in [`Zeroizing`] so it is wiped when dropped.
    pub password: Zeroizing<String>,
    /// Where to dial, when that is not the JID's own domain. TLS is still
    /// verified against the domain in [`Self::jid`], never against this.
    pub host: Option<String>,
    pub port: Option<u16>,
    /// Rooms to join once online, as `room@conference.example.org`.
    pub rooms: Vec<String>,
    /// The nick to use in rooms. Defaults to the JID's local part.
    pub nickname: Option<String>,
    /// Path to a PEM certificate to trust *in addition to* the platform's roots.
    /// Same rules as [`crate::api::types::ServerConfig::extra_root_cert`]:
    /// added, never a replacement, and unreachable from Dart.
    pub extra_root_cert: Option<String>,
    /// Dial through this proxy instead of connecting directly. No fallback.
    pub proxy: Option<ProxyConfig>,
}

impl std::fmt::Debug for XmppConfig {
    /// By hand, because one of these fields is a password.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("XmppConfig")
            .field("jid", &self.jid)
            .field("password", &"<redacted>")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("rooms", &self.rooms)
            .field("nickname", &self.nickname)
            .field("extra_root_cert", &self.extra_root_cert)
            .field("proxy", &self.proxy)
            .finish()
    }
}

impl XmppConfig {
    /// The account, parsed.
    pub fn bare_jid(&self) -> Result<BareJid, XmppConfigError> {
        let jid: BareJid = self
            .jid
            .trim()
            .parse()
            .map_err(|e: tokio_xmpp::jid::Error| XmppConfigError::InvalidJid(e.to_string()))?;
        if jid.node().is_none() {
            return Err(XmppConfigError::NoLocalPart);
        }
        Ok(jid)
    }

    /// The name TLS is verified against: always the JID's domain.
    pub fn domain(&self) -> Result<String, XmppConfigError> {
        Ok(self.bare_jid()?.domain().as_str().to_owned())
    }

    /// The host to dial.
    pub fn dial_host(&self) -> Result<String, XmppConfigError> {
        match &self.host {
            Some(host) => Ok(host.trim().to_owned()),
            None => self.domain(),
        }
    }

    pub fn dial_port(&self) -> u16 {
        self.port.unwrap_or(DEFAULT_TLS_PORT)
    }

    /// The nick used in rooms.
    pub fn room_nick(&self) -> String {
        match &self.nickname {
            Some(nick) if !nick.trim().is_empty() => nick.trim().to_owned(),
            _ => self
                .bare_jid()
                .ok()
                .and_then(|jid| jid.node().map(|n| n.as_str().to_owned()))
                .unwrap_or_default(),
        }
    }

    /// Validate the configuration.
    ///
    /// Called before every connection attempt, so a bad one surfaces as a clear
    /// error rather than a failed handshake some seconds later.
    pub fn validate(&self) -> Result<(), XmppConfigError> {
        self.bare_jid()?;
        if self.password.is_empty() {
            return Err(XmppConfigError::EmptyPassword);
        }
        if let Some(host) = &self.host {
            if host.trim().is_empty() {
                return Err(XmppConfigError::EmptyHost);
            }
        }
        match self.port {
            Some(0) => return Err(XmppConfigError::PortZero),
            Some(STARTTLS_PORT) => return Err(XmppConfigError::StartTlsPort),
            _ => {}
        }
        for room in &self.rooms {
            let jid: Result<BareJid, _> = room.trim().parse();
            match jid {
                Ok(jid) if jid.node().is_some() => {}
                _ => return Err(XmppConfigError::InvalidRoom(room.clone())),
            }
        }
        if let Some(path) = &self.extra_root_cert {
            if !Path::new(path).is_file() {
                return Err(ConfigError::MissingRootCert(path.clone()).into());
            }
        }
        let host = self.dial_host()?;
        if let Some(proxy) = &self.proxy {
            proxy.validate()?;
        } else if host
            .trim_end_matches('.')
            .to_ascii_lowercase()
            .ends_with(".onion")
        {
            // Same reasoning as the IRC side: an onion name is not in DNS and
            // never will be, so the failure it prevents is a lookup error that
            // names the wrong problem.
            return Err(ConfigError::OnionWithoutProxy(host).into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> XmppConfig {
        XmppConfig {
            jid: "alice@example.org".to_owned(),
            password: Zeroizing::new("hunter2".to_owned()),
            host: None,
            port: None,
            rooms: Vec::new(),
            nickname: None,
            extra_root_cert: None,
            proxy: None,
        }
    }

    #[test]
    fn a_plain_account_is_accepted() {
        config()
            .validate()
            .expect("a bare JID and a password are enough");
    }

    #[test]
    fn the_host_defaults_to_the_domain_and_the_port_to_direct_tls() {
        let c = config();
        assert_eq!(c.dial_host().unwrap(), "example.org");
        assert_eq!(c.dial_port(), 5223);
    }

    #[test]
    fn tls_is_verified_against_the_domain_even_when_dialling_elsewhere() {
        let c = XmppConfig {
            host: Some("xmpp.hosting.example".to_owned()),
            ..config()
        };
        assert_eq!(c.dial_host().unwrap(), "xmpp.hosting.example");
        assert_eq!(c.domain().unwrap(), "example.org");
    }

    #[test]
    fn an_address_without_a_name_is_refused() {
        let c = XmppConfig {
            jid: "example.org".to_owned(),
            ..config()
        };
        assert_eq!(c.validate(), Err(XmppConfigError::NoLocalPart));
    }

    #[test]
    fn garbage_is_not_an_address() {
        let c = XmppConfig {
            jid: "not an address@".to_owned(),
            ..config()
        };
        assert!(matches!(c.validate(), Err(XmppConfigError::InvalidJid(_))));
    }

    #[test]
    fn an_empty_password_is_refused() {
        let c = XmppConfig {
            password: Zeroizing::new(String::new()),
            ..config()
        };
        assert_eq!(c.validate(), Err(XmppConfigError::EmptyPassword));
    }

    #[test]
    fn the_starttls_port_is_refused_with_an_explanation() {
        let c = XmppConfig {
            port: Some(5222),
            ..config()
        };
        let error = c.validate().unwrap_err();
        assert_eq!(error, XmppConfigError::StartTlsPort);
        assert!(error.to_string().contains("5223"));
    }

    #[test]
    fn port_zero_is_refused() {
        let c = XmppConfig {
            port: Some(0),
            ..config()
        };
        assert_eq!(c.validate(), Err(XmppConfigError::PortZero));
    }

    #[test]
    fn a_blank_server_override_is_refused_rather_than_ignored() {
        let c = XmppConfig {
            host: Some("  ".to_owned()),
            ..config()
        };
        assert_eq!(c.validate(), Err(XmppConfigError::EmptyHost));
    }

    #[test]
    fn rooms_must_be_addresses() {
        let c = XmppConfig {
            rooms: vec![
                "lobby@conference.example.org".to_owned(),
                "#lobby".to_owned(),
            ],
            ..config()
        };
        assert_eq!(
            c.validate(),
            Err(XmppConfigError::InvalidRoom("#lobby".to_owned()))
        );
    }

    #[test]
    fn a_missing_certificate_is_named() {
        let c = XmppConfig {
            extra_root_cert: Some("/nonexistent/ca.pem".to_owned()),
            ..config()
        };
        assert!(matches!(
            c.validate(),
            Err(XmppConfigError::Common(ConfigError::MissingRootCert(_)))
        ));
    }

    #[test]
    fn an_onion_server_needs_a_proxy() {
        let c = XmppConfig {
            host: Some("exampleonionaddress.onion".to_owned()),
            ..config()
        };
        assert!(matches!(
            c.validate(),
            Err(XmppConfigError::Common(ConfigError::OnionWithoutProxy(_)))
        ));
        let with_proxy = XmppConfig {
            proxy: Some(ProxyConfig {
                host: "127.0.0.1".to_owned(),
                port: ProxyConfig::TOR_SOCKS_PORT,
                ..Default::default()
            }),
            ..c
        };
        with_proxy.validate().expect("a proxy can resolve it");
    }

    #[test]
    fn the_room_nick_defaults_to_the_local_part() {
        assert_eq!(config().room_nick(), "alice");
        let c = XmppConfig {
            nickname: Some("  ally ".to_owned()),
            ..config()
        };
        assert_eq!(c.room_nick(), "ally");
    }

    #[test]
    fn debug_never_prints_the_password() {
        let shown = format!("{:?}", config());
        assert!(!shown.contains("hunter2"));
        assert!(shown.contains("<redacted>"));
    }
}
