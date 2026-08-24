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
}

/// How to reach a server. TLS is not configurable: every connection uses it.
#[derive(Debug, Clone, Default)]
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
        Ok(())
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
