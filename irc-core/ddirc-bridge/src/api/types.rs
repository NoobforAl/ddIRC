//! Data transfer objects for the Dart boundary.
//!
//! These deliberately mirror `ddirc_core`'s types rather than re-exporting
//! them. The core stays free of any Flutter or `flutter_rust_bridge` awareness,
//! nothing from the `irc` crate can leak into Dart, and the shapes here can be
//! tuned for Dart ergonomics without disturbing the core.

use ddirc_core::api::{events, types};
use ddirc_core::text::format;

/// Styling for a run of message text.
#[derive(Debug, Clone)]
pub struct SpanStyle {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub monospace: bool,
    pub inverse: bool,
    /// mIRC colour index, if any.
    pub fg: Option<u8>,
    pub bg: Option<u8>,
}

/// A run of message text sharing one style.
///
/// The text is guaranteed free of control characters: the core strips them
/// before this type is ever built.
#[derive(Debug, Clone)]
pub struct TextSpan {
    pub text: String,
    pub style: SpanStyle,
}

/// Connection lifecycle, for the status dot.
#[derive(Debug, Clone)]
pub enum ConnectionStatus {
    Disconnected,
    Connecting,
    Registering,
    Connected,
    Reconnecting { retry_in_secs: u64, attempt: u32 },
}

/// How authentication resolved.
#[derive(Debug, Clone)]
pub enum AuthOutcome {
    /// Authenticated before joining anything.
    Sasl,
    /// Weaker: authenticated after connecting, so we were briefly present
    /// unauthenticated. Worth surfacing to the user.
    NickServFallback {
        reason: String,
    },
    Anonymous,
}

/// A channel member.
#[derive(Debug, Clone)]
pub struct MemberView {
    pub nick: String,
    /// Highest-privilege prefix, e.g. `@` or `+`.
    pub prefix: Option<String>,
    pub away: bool,
}

/// Where a message was addressed.
#[derive(Debug, Clone)]
pub enum Target {
    Channel { name: String },
    Direct { nick: String },
}

/// A chat message, already sanitised.
#[derive(Debug, Clone)]
pub struct ChatMessage {
    pub target: Target,
    pub sender: String,
    pub sender_prefix: Option<String>,
    pub spans: Vec<TextSpan>,
    /// True if we sent it, so the UI can align it opposite.
    pub is_self: bool,
    /// True if our nick was mentioned, for the highlight tint.
    pub is_mention: bool,
    pub is_action: bool,
    pub is_notice: bool,
}

/// Something that happened on a connection.
#[derive(Debug, Clone)]
pub enum IrcEvent {
    Status {
        status: ConnectionStatus,
        detail: Option<String>,
    },
    Registered {
        nick: String,
        network: Option<String>,
        auth: AuthOutcome,
    },
    NetworkNamed {
        network: String,
    },
    Message {
        message: ChatMessage,
    },
    Joined {
        channel: String,
        nick: String,
        is_self: bool,
    },
    Parted {
        channel: String,
        nick: String,
        is_self: bool,
        reason: Option<String>,
    },
    Quit {
        channel: String,
        nick: String,
        reason: Option<String>,
    },
    NickChanged {
        channel: String,
        old: String,
        new: String,
        is_self: bool,
    },
    TopicChanged {
        channel: String,
        topic: String,
        set_by: Option<String>,
    },
    MemberList {
        channel: String,
        members: Vec<MemberView>,
    },
    ModeChanged {
        channel: String,
        by: Option<String>,
        affected: Vec<String>,
    },
    /// Messages discarded by flood protection or UI backpressure. Surfaced so a
    /// gap in a conversation is never silently mistaken for silence.
    MessagesDropped {
        channel: Option<String>,
        count: u64,
    },
    Error {
        message: String,
        fatal: bool,
    },
}

/// How to reach a server.
///
/// TLS is not configurable — every connection uses it. Passwords arrive as
/// plain strings from Dart and are moved into zeroizing storage on the Rust
/// side immediately.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub nickname: String,
    pub alt_nicks: Vec<String>,
    pub username: Option<String>,
    pub realname: Option<String>,
    pub channels: Vec<String>,
    pub sasl_account: Option<String>,
    pub sasl_password: Option<String>,
    pub nickserv_password: Option<String>,
    pub server_password: Option<String>,
}

// ---------------------------------------------------------------------------
// Conversions from the core's types.
// ---------------------------------------------------------------------------

impl From<format::SpanStyle> for SpanStyle {
    fn from(style: format::SpanStyle) -> Self {
        Self {
            bold: style.bold,
            italic: style.italic,
            underline: style.underline,
            strikethrough: style.strikethrough,
            monospace: style.monospace,
            inverse: style.inverse,
            fg: style.fg,
            bg: style.bg,
        }
    }
}

impl From<format::TextSpan> for TextSpan {
    fn from(span: format::TextSpan) -> Self {
        Self {
            text: span.text,
            style: span.style.into(),
        }
    }
}

impl From<types::ConnectionStatus> for ConnectionStatus {
    fn from(status: types::ConnectionStatus) -> Self {
        match status {
            types::ConnectionStatus::Disconnected => Self::Disconnected,
            types::ConnectionStatus::Connecting => Self::Connecting,
            types::ConnectionStatus::Registering => Self::Registering,
            types::ConnectionStatus::Connected => Self::Connected,
            types::ConnectionStatus::Reconnecting {
                retry_in_secs,
                attempt,
            } => Self::Reconnecting {
                retry_in_secs,
                attempt,
            },
        }
    }
}

impl From<types::AuthOutcome> for AuthOutcome {
    fn from(auth: types::AuthOutcome) -> Self {
        match auth {
            types::AuthOutcome::Sasl => Self::Sasl,
            types::AuthOutcome::NickServFallback { reason } => Self::NickServFallback { reason },
            types::AuthOutcome::Anonymous => Self::Anonymous,
        }
    }
}

impl From<types::MemberView> for MemberView {
    fn from(member: types::MemberView) -> Self {
        Self {
            nick: member.nick,
            prefix: member.prefix,
            away: member.away,
        }
    }
}

impl From<types::Target> for Target {
    fn from(target: types::Target) -> Self {
        match target {
            types::Target::Channel(name) => Self::Channel { name },
            types::Target::Direct(nick) => Self::Direct { nick },
        }
    }
}

impl From<types::ChatMessage> for ChatMessage {
    fn from(message: types::ChatMessage) -> Self {
        Self {
            target: message.target.into(),
            sender: message.sender,
            sender_prefix: message.sender_prefix,
            spans: message.spans.into_iter().map(Into::into).collect(),
            is_self: message.is_self,
            is_mention: message.is_mention,
            is_action: message.is_action,
            is_notice: message.is_notice,
        }
    }
}

impl From<events::IrcEvent> for IrcEvent {
    fn from(event: events::IrcEvent) -> Self {
        match event {
            events::IrcEvent::Status { status, detail } => Self::Status {
                status: status.into(),
                detail,
            },
            events::IrcEvent::Registered {
                nick,
                network,
                auth,
            } => Self::Registered {
                nick,
                network,
                auth: auth.into(),
            },
            events::IrcEvent::NetworkNamed { network } => Self::NetworkNamed { network },
            events::IrcEvent::Message(message) => Self::Message {
                message: (*message).into(),
            },
            events::IrcEvent::Joined {
                channel,
                nick,
                is_self,
            } => Self::Joined {
                channel,
                nick,
                is_self,
            },
            events::IrcEvent::Parted {
                channel,
                nick,
                is_self,
                reason,
            } => Self::Parted {
                channel,
                nick,
                is_self,
                reason,
            },
            events::IrcEvent::Quit {
                channel,
                nick,
                reason,
            } => Self::Quit {
                channel,
                nick,
                reason,
            },
            events::IrcEvent::NickChanged {
                channel,
                old,
                new,
                is_self,
            } => Self::NickChanged {
                channel,
                old,
                new,
                is_self,
            },
            events::IrcEvent::TopicChanged {
                channel,
                topic,
                set_by,
            } => Self::TopicChanged {
                channel,
                topic,
                set_by,
            },
            events::IrcEvent::MemberList { channel, members } => Self::MemberList {
                channel,
                members: members.into_iter().map(Into::into).collect(),
            },
            events::IrcEvent::ModeChanged {
                channel,
                by,
                affected,
            } => Self::ModeChanged {
                channel,
                by,
                affected,
            },
            events::IrcEvent::MessagesDropped { channel, count } => {
                Self::MessagesDropped { channel, count }
            }
            events::IrcEvent::Error { message, fatal } => Self::Error { message, fatal },
        }
    }
}

impl From<ServerConfig> for types::ServerConfig {
    fn from(config: ServerConfig) -> Self {
        /// Move a Dart-supplied secret into zeroizing storage, dropping empties
        /// so a blank text field is not mistaken for a real password.
        fn secret(value: Option<String>) -> Option<zeroize::Zeroizing<String>> {
            value.filter(|v| !v.is_empty()).map(zeroize::Zeroizing::new)
        }

        Self {
            host: config.host,
            port: config.port,
            nickname: config.nickname,
            alt_nicks: config.alt_nicks,
            username: config.username.filter(|v| !v.is_empty()),
            realname: config.realname.filter(|v| !v.is_empty()),
            channels: config.channels,
            sasl_account: config.sasl_account.filter(|v| !v.is_empty()),
            sasl_password: secret(config.sasl_password),
            nickserv_password: secret(config.nickserv_password),
            server_password: secret(config.server_password),
        }
    }
}
