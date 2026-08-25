//! Owned, plain types that cross the API boundary.
//!
//! Nothing from the `irc` crate is re-exported here. Keeping the surface to
//! types we define means the UI can never reach a raw socket, a session handle,
//! or protocol internals, and it leaves us free to change or vendor the
//! underlying crate without touching Dart.

use std::path::Path;

use zeroize::Zeroizing;

use crate::text::format::TextSpan;

/// Ports that are conventionally plaintext IRC. Connecting with TLS to one of
/// these fails with a confusing handshake error, so we reject them up front
/// with an explanation instead.
const PLAINTEXT_PORTS: &[u16] = &[
    6660, 6661, 6662, 6663, 6664, 6665, 6666, 6667, 6668, 6669, 194,
];

/// Why a [`ServerConfig`] was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConfigError {
    #[error("server host must not be empty")]
    EmptyHost,
    #[error("nickname must not be empty")]
    EmptyNickname,
    #[error("nickname must not contain spaces or control characters")]
    InvalidNickname,
    #[error(
        "port {0} is a plaintext IRC port; ddIRC requires TLS. Use 6697 (the \
         standard TLS port) or another port your network serves TLS on."
    )]
    PlaintextPort(u16),
    #[error("SASL requires both an account and a password")]
    IncompleteSaslCredentials,
    #[error("certificate to trust not found: {0}")]
    MissingRootCert(String),
    #[error(
        "'{0}' is an onion address, and onion addresses only exist inside \
         Tor. Set this network's proxy to a Tor SOCKS5 listener - usually \
         127.0.0.1:9050 - because without one there is nothing here that can \
         find it."
    )]
    OnionWithoutProxy(String),
    #[error("proxy host must not be empty")]
    EmptyProxyHost,
    #[error("proxy port must not be 0")]
    ProxyPortZero,
    #[error("a SOCKS5 proxy needs both a username and a password, or neither")]
    IncompleteProxyCredentials,
    #[error(
        "proxy {0} must be between 1 and 255 bytes; SOCKS5 length-prefixes it \
         with a single byte (RFC 1929)"
    )]
    ProxyCredentialLength(&'static str),
}

/// A SOCKS5 proxy to dial through.
///
/// SOCKS5 and nothing else. It is what the transport underneath supports, and
/// it is also the right first choice: unlike an HTTP proxy it carries arbitrary
/// TCP, and it resolves the destination name at the far end, so a proxy meant
/// to hide where you are is not undone by a DNS lookup that announces it. Tor's
/// local listener speaks exactly this.
///
/// The proxy carries the connection; it does not terminate it. TLS is
/// negotiated end to end with the IRC server *through* the tunnel and verified
/// against the server's own name, so a proxy operator sees a stream of
/// ciphertext to a host they were told about, and nothing else.
///
/// There is no fallback. If a proxy is configured and cannot be reached, the
/// connection fails. Quietly dialling direct instead would defeat the one thing
/// a proxy is for, at exactly the moment it mattered most.
#[derive(Clone, Default)]
pub struct ProxyConfig {
    pub host: String,
    pub port: u16,
    /// SOCKS5 username/password auth (RFC 1929). Both or neither.
    ///
    /// Worth knowing before typing one in: RFC 1929 sends both in the clear to
    /// the proxy, before any TLS exists. It authenticates you *to the proxy*
    /// and protects nothing else. Tor accepts any pair here and uses it to put
    /// the connection on a circuit of its own rather than to check anything.
    pub username: Option<String>,
    pub password: Option<Zeroizing<String>>,
}

impl ProxyConfig {
    /// The port Tor's SOCKS listener uses by default.
    ///
    /// Offered as the form's starting value rather than 1080, SOCKS5's own
    /// conventional port: someone reaching for a proxy in an IRC client is
    /// usually reaching for Tor, and anyone with a different proxy already
    /// knows its port.
    pub const TOR_SOCKS_PORT: u16 = 9050;

    fn validate(&self) -> Result<(), ConfigError> {
        if self.host.trim().is_empty() {
            return Err(ConfigError::EmptyProxyHost);
        }
        if self.port == 0 {
            return Err(ConfigError::ProxyPortZero);
        }
        // Half a credential authenticates nobody, and the transport underneath
        // reacts to a lone username by refusing with a message about byte
        // lengths, which explains nothing to whoever left a field blank.
        if self.username.is_some() != self.password.is_some() {
            return Err(ConfigError::IncompleteProxyCredentials);
        }
        // SOCKS5 length-prefixes each with one byte, so 255 is a hard ceiling
        // and 0 is not a value. Caught here because the alternative is a
        // handshake that fails for a reason the user never sees.
        if let Some(username) = &self.username {
            if username.is_empty() || username.len() > 255 {
                return Err(ConfigError::ProxyCredentialLength("username"));
            }
        }
        if let Some(password) = &self.password {
            if password.is_empty() || password.len() > 255 {
                return Err(ConfigError::ProxyCredentialLength("password"));
            }
        }
        Ok(())
    }
}

impl std::fmt::Debug for ProxyConfig {
    /// Redacted, so a stray `{:?}` cannot put the password in a log.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProxyConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("username", &self.username)
            .field("password", &self.password.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

/// How to reach a server. TLS is not configurable: every connection uses it.
#[derive(Clone, Default)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub nickname: String,
    /// Nicks to try if the primary is taken.
    pub alt_nicks: Vec<String>,
    /// Defaults to the nickname.
    pub username: Option<String>,
    /// Defaults to the nickname.
    pub realname: Option<String>,
    /// Channels to join once registered.
    pub channels: Vec<String>,

    /// SASL account name. Requires `sasl_password`.
    pub sasl_account: Option<String>,
    /// Secrets are held in [`Zeroizing`] so they are wiped when dropped rather
    /// than left in freed heap memory.
    pub sasl_password: Option<Zeroizing<String>>,
    /// Used only if SASL was not attempted or was refused.
    pub nickserv_password: Option<Zeroizing<String>>,
    /// Server-level `PASS`, for private servers.
    pub server_password: Option<Zeroizing<String>>,

    /// Path to a PEM certificate to trust in addition to the platform's roots.
    ///
    /// *Added* to the trust store, never a replacement for it, and unrelated to
    /// the `irc` crate's `dangerously_accept_invalid_certs`, which this crate
    /// never sets — a server presenting an otherwise untrusted certificate is
    /// still refused. It exists so tests can reach the self-signed dev server
    /// in `dev/` without a verification-skipping path existing in the client.
    ///
    /// Unreachable from Dart: the FFI layer's own `ServerConfig` has no such
    /// field, so nothing the app can configure ever sets this.
    pub extra_root_cert: Option<String>,

    /// Dial through this proxy instead of connecting directly.
    ///
    /// Already resolved by the caller: the app settles its global setting
    /// against any per-server override before it gets here, so the core is
    /// handed one answer rather than a policy to interpret.
    pub proxy: Option<ProxyConfig>,
}

impl std::fmt::Debug for ServerConfig {
    /// Written out by hand rather than derived, because three of these fields
    /// are passwords and the derived version prints them. `Zeroizing` wipes a
    /// secret when it drops; it does nothing about one already formatted into
    /// a log line.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        fn shown(secret: &Option<Zeroizing<String>>) -> Option<&str> {
            secret.as_ref().map(|_| "<redacted>")
        }
        f.debug_struct("ServerConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("nickname", &self.nickname)
            .field("alt_nicks", &self.alt_nicks)
            .field("username", &self.username)
            .field("realname", &self.realname)
            .field("channels", &self.channels)
            .field("sasl_account", &self.sasl_account)
            .field("sasl_password", &shown(&self.sasl_password))
            .field("nickserv_password", &shown(&self.nickserv_password))
            .field("server_password", &shown(&self.server_password))
            .field("extra_root_cert", &self.extra_root_cert)
            .field("proxy", &self.proxy)
            .finish()
    }
}

impl ServerConfig {
    /// The standard port for IRC over TLS.
    pub const DEFAULT_TLS_PORT: u16 = 6697;

    /// Validate the configuration.
    ///
    /// Called before every connection attempt, so an invalid config surfaces as
    /// a clear error rather than a TLS handshake failure ten seconds later.
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.host.trim().is_empty() {
            return Err(ConfigError::EmptyHost);
        }
        if self.nickname.trim().is_empty() {
            return Err(ConfigError::EmptyNickname);
        }
        // A nick containing a space or control character would let a crafted
        // config inject a second command into the registration burst.
        if self
            .nickname
            .chars()
            .any(|c| c.is_whitespace() || (c as u32) < 0x20)
        {
            return Err(ConfigError::InvalidNickname);
        }
        if PLAINTEXT_PORTS.contains(&self.port) {
            return Err(ConfigError::PlaintextPort(self.port));
        }
        if self.sasl_account.is_some() != self.sasl_password.is_some() {
            return Err(ConfigError::IncompleteSaslCredentials);
        }
        // The `irc` crate ignores an unreadable certificate path silently, so
        // catching it here is the difference between a clear error and a
        // handshake that fails ten seconds later for no stated reason.
        if let Some(path) = &self.extra_root_cert {
            if !Path::new(path).is_file() {
                return Err(ConfigError::MissingRootCert(path.clone()));
            }
        }
        if let Some(proxy) = &self.proxy {
            proxy.validate()?;
        } else if self.is_onion() {
            // Caught here for the same reason a plaintext port is: the failure
            // it prevents is a name-resolution error that names DNS, which is
            // true and useless. An onion address is not in DNS and never will
            // be — it is resolved by Tor, at the far end of a SOCKS5 tunnel.
            //
            // Only the *absence* of a proxy is checked. Whether the proxy on
            // the other end is really Tor is not knowable from here, and
            // guessing would refuse working configurations.
            return Err(ConfigError::OnionWithoutProxy(self.host.clone()));
        }
        Ok(())
    }

    /// Whether this is a Tor onion address.
    ///
    /// Nothing else about the connection changes if it is: the SOCKS5 tunnel
    /// carries the name to Tor, which resolves it, and TLS is then negotiated
    /// and *verified* against that name exactly as for any other host. An
    /// onion service that wants to be reachable from here needs a certificate
    /// issued for its own `.onion` name — which is permitted, and is the only
    /// arrangement that does not require weakening the client.
    pub fn is_onion(&self) -> bool {
        self.host
            .trim()
            .trim_end_matches('.')
            .to_ascii_lowercase()
            .ends_with(".onion")
    }

    pub fn username(&self) -> &str {
        self.username.as_deref().unwrap_or(&self.nickname)
    }

    pub fn realname(&self) -> &str {
        self.realname.as_deref().unwrap_or(&self.nickname)
    }
}

/// Connection lifecycle, driving the status dot in the UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionStatus {
    Disconnected,
    Connecting,
    /// TCP and TLS are up; registration is in progress.
    Registering,
    Connected,
    /// Waiting out backoff before the next attempt.
    Reconnecting {
        /// Seconds until the next attempt, for a countdown.
        retry_in_secs: u64,
        attempt: u32,
    },
}

/// How authentication resolved, so the UI can warn when it silently degraded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthOutcome {
    /// SASL succeeded; we were logged in before joining anything.
    Sasl,
    /// SASL was unavailable or refused, so NickServ was used instead. This is
    /// weaker: we are briefly present unauthenticated.
    NickServFallback { reason: String },
    /// No credentials were configured.
    Anonymous,
}

/// A channel member as the UI needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemberView {
    pub nick: String,
    /// Highest-privilege prefix, e.g. `@` or `+`.
    pub prefix: Option<String>,
    pub away: bool,
}

/// Where a message was addressed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Channel(String),
    /// A private message; the string is the other party's nick.
    Direct(String),
}

impl Target {
    pub fn name(&self) -> &str {
        match self {
            Self::Channel(name) | Self::Direct(name) => name,
        }
    }
}

/// A chat message, already sanitised into styled spans.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub target: Target,
    pub sender: String,
    /// The sender's channel privilege prefix at the time of sending.
    pub sender_prefix: Option<String>,
    /// Sanitised content. Never contains control characters.
    pub spans: Vec<TextSpan>,
    /// True if we sent it, so the UI can align it opposite.
    pub is_self: bool,
    /// True if our nick was mentioned, for the highlight tint.
    pub is_mention: bool,
    /// A CTCP ACTION (`/me`), rendered in the third person.
    pub is_action: bool,
    /// A NOTICE rather than a PRIVMSG.
    pub is_notice: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> ServerConfig {
        ServerConfig {
            host: "irc.libera.chat".to_owned(),
            port: ServerConfig::DEFAULT_TLS_PORT,
            nickname: "ddirc".to_owned(),
            ..Default::default()
        }
    }

    #[test]
    fn valid_config_passes() {
        assert_eq!(config().validate(), Ok(()));
    }

    #[test]
    fn plaintext_ports_are_rejected() {
        for port in [6667, 6665, 194] {
            let c = ServerConfig { port, ..config() };
            assert_eq!(
                c.validate(),
                Err(ConfigError::PlaintextPort(port)),
                "port {port} should be refused"
            );
        }
    }

    #[test]
    fn tls_ports_are_accepted() {
        // TLS is not limited to 6697; unusual ports must still work.
        for port in [6697, 7000, 9999] {
            let c = ServerConfig { port, ..config() };
            assert_eq!(c.validate(), Ok(()), "port {port} should be allowed");
        }
    }

    #[test]
    fn empty_host_and_nick_are_rejected() {
        let c = ServerConfig {
            host: "  ".to_owned(),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::EmptyHost));

        let c = ServerConfig {
            nickname: String::new(),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::EmptyNickname));
    }

    #[test]
    fn nick_with_control_characters_is_rejected() {
        // Would otherwise inject a second command into registration.
        let c = ServerConfig {
            nickname: "evil\r\nJOIN #x".to_owned(),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::InvalidNickname));

        let c = ServerConfig {
            nickname: "two words".to_owned(),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::InvalidNickname));
    }

    #[test]
    fn partial_sasl_credentials_are_rejected() {
        let c = ServerConfig {
            sasl_account: Some("me".to_owned()),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::IncompleteSaslCredentials));

        let c = ServerConfig {
            sasl_password: Some(Zeroizing::new("pw".to_owned())),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::IncompleteSaslCredentials));

        let c = ServerConfig {
            sasl_account: Some("me".to_owned()),
            sasl_password: Some(Zeroizing::new("pw".to_owned())),
            ..config()
        };
        assert_eq!(c.validate(), Ok(()));
    }

    fn proxy() -> ProxyConfig {
        ProxyConfig {
            host: "127.0.0.1".to_owned(),
            port: ProxyConfig::TOR_SOCKS_PORT,
            ..Default::default()
        }
    }

    #[test]
    fn an_onion_address_without_a_proxy_is_refused() {
        // Without this the user gets a DNS failure, which is accurate and
        // explains nothing: an onion address is not in DNS and cannot be.
        let c = ServerConfig {
            host: "w5tmaxmtwiud3gsdb2bxelqepos7ymwvndquzfnjjh3zavhfbok2yfqd.onion".to_owned(),
            ..config()
        };
        assert_eq!(
            c.validate(),
            Err(ConfigError::OnionWithoutProxy(c.host.clone()))
        );

        // With one, it is an ordinary host as far as this layer is concerned.
        let c = ServerConfig {
            proxy: Some(proxy()),
            ..c
        };
        assert_eq!(c.validate(), Ok(()));
    }

    #[test]
    fn onion_addresses_are_recognised_however_they_are_written() {
        for host in [
            "abc.onion",
            "ABC.ONION",
            // A fully-qualified name with the root dot still names the same
            // service, and browsers accept it; refusing it here would be a
            // puzzle rather than a safeguard.
            "abc.onion.",
        ] {
            let c = ServerConfig {
                host: host.to_owned(),
                ..config()
            };
            assert!(c.is_onion(), "{host} should be an onion address");
        }

        for host in ["irc.libera.chat", "onion.example.org", "notanonion"] {
            let c = ServerConfig {
                host: host.to_owned(),
                ..config()
            };
            assert!(!c.is_onion(), "{host} should not be an onion address");
        }
    }

    #[test]
    fn no_proxy_is_the_default() {
        assert!(config().proxy.is_none());
    }

    #[test]
    fn a_plain_proxy_passes() {
        let c = ServerConfig {
            proxy: Some(proxy()),
            ..config()
        };
        assert_eq!(c.validate(), Ok(()));
    }

    #[test]
    fn a_proxy_without_a_host_or_port_is_rejected() {
        let c = ServerConfig {
            proxy: Some(ProxyConfig {
                host: "   ".to_owned(),
                ..proxy()
            }),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::EmptyProxyHost));

        let c = ServerConfig {
            proxy: Some(ProxyConfig { port: 0, ..proxy() }),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::ProxyPortZero));
    }

    #[test]
    fn half_a_proxy_credential_is_rejected() {
        // The transport underneath answers a lone username with "username
        // length should between 1 to 255", which names the wrong problem.
        let c = ServerConfig {
            proxy: Some(ProxyConfig {
                username: Some("me".to_owned()),
                ..proxy()
            }),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::IncompleteProxyCredentials));

        let c = ServerConfig {
            proxy: Some(ProxyConfig {
                password: Some(Zeroizing::new("pw".to_owned())),
                ..proxy()
            }),
            ..config()
        };
        assert_eq!(c.validate(), Err(ConfigError::IncompleteProxyCredentials));

        let c = ServerConfig {
            proxy: Some(ProxyConfig {
                username: Some("me".to_owned()),
                password: Some(Zeroizing::new("pw".to_owned())),
                ..proxy()
            }),
            ..config()
        };
        assert_eq!(c.validate(), Ok(()));
    }

    #[test]
    fn proxy_credentials_longer_than_socks5_allows_are_rejected() {
        // One length byte each, so 255 is the ceiling and 256 is not a
        // borderline case the server might tolerate — it cannot be expressed.
        let c = ServerConfig {
            proxy: Some(ProxyConfig {
                username: Some("u".repeat(256)),
                password: Some(Zeroizing::new("pw".to_owned())),
                ..proxy()
            }),
            ..config()
        };
        assert_eq!(
            c.validate(),
            Err(ConfigError::ProxyCredentialLength("username"))
        );

        let c = ServerConfig {
            proxy: Some(ProxyConfig {
                username: Some("me".to_owned()),
                password: Some(Zeroizing::new("p".repeat(256))),
                ..proxy()
            }),
            ..config()
        };
        assert_eq!(
            c.validate(),
            Err(ConfigError::ProxyCredentialLength("password"))
        );

        // 255 exactly is legal, and a boundary worth pinning in both places.
        let c = ServerConfig {
            proxy: Some(ProxyConfig {
                username: Some("u".repeat(255)),
                password: Some(Zeroizing::new("p".repeat(255))),
                ..proxy()
            }),
            ..config()
        };
        assert_eq!(c.validate(), Ok(()));
    }

    #[test]
    fn no_debug_output_contains_a_secret() {
        // The derived Debug printed all four. Nothing formats a ServerConfig
        // today, but a debug log is one `{:?}` away from existing.
        let c = ServerConfig {
            sasl_account: Some("me".to_owned()),
            sasl_password: Some(Zeroizing::new("sasl-hunter2".to_owned())),
            nickserv_password: Some(Zeroizing::new("ns-hunter2".to_owned())),
            server_password: Some(Zeroizing::new("srv-hunter2".to_owned())),
            proxy: Some(ProxyConfig {
                username: Some("proxy-user".to_owned()),
                password: Some(Zeroizing::new("proxy-hunter2".to_owned())),
                ..proxy()
            }),
            ..config()
        };
        let rendered = format!("{c:?}");
        for secret in ["sasl-hunter2", "ns-hunter2", "srv-hunter2", "proxy-hunter2"] {
            assert!(!rendered.contains(secret), "{secret} leaked: {rendered}");
        }
        // The things that are not secrets must survive, or this is useless
        // for the debugging it exists for.
        assert!(rendered.contains("irc.libera.chat"));
        assert!(rendered.contains("proxy-user"));
        assert!(rendered.contains("127.0.0.1"));
    }

    #[test]
    fn username_and_realname_default_to_nickname() {
        let c = config();
        assert_eq!(c.username(), "ddirc");
        assert_eq!(c.realname(), "ddirc");

        let c = ServerConfig {
            username: Some("u".to_owned()),
            ..config()
        };
        assert_eq!(c.username(), "u");
        assert_eq!(c.realname(), "ddirc");
    }
}
