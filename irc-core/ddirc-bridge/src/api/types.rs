//! Data transfer objects for the Dart boundary.
//!
//! These deliberately mirror `ddirc_core`'s types rather than re-exporting
//! them. The core stays free of any Flutter or `flutter_rust_bridge` awareness,
//! nothing from the `irc` crate can leak into Dart, and the shapes here can be
//! tuned for Dart ergonomics without disturbing the core.

use ddirc_core::api::{events, types};
use ddirc_core::dcc;
use ddirc_core::media;
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
    /// Where this member belongs in the list, as an opaque string to compare.
    ///
    /// Carried so the UI can place one arriving nick without owning a second
    /// copy of the ordering rule. Never displayed; its contents are not a
    /// promise, only that comparing two of them gives the core's own order.
    pub sort_key: String,
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
    /// The whole roster, for the two moments that need one: the end of a
    /// `NAMES` burst, and our own join.
    MemberList {
        channel: String,
        members: Vec<MemberView>,
    },
    /// One person arrived, left, was renamed, was opped, or went away.
    ///
    /// Applied to the roster the UI already holds: find the row filed under
    /// `previous`, and put `member` where it now belongs — or remove it, when
    /// `member` is null because they are gone.
    MemberChanged {
        channel: String,
        previous: String,
        member: Option<MemberView>,
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
    /// Someone offered to send a file, over DCC.
    ///
    /// Reported, never answered — nothing has been sent back and no
    /// connection has been made. Accepting means dialling an address a
    /// stranger chose, or listening for them, and that is the user's call.
    FileOffered {
        /// Names the offer for as long as it is worth answering. Passed back
        /// to accept or decline it, so the UI refers to an offer the core
        /// parsed rather than handing an address back across this boundary.
        id: u64,
        /// Where it arrived: a channel, or the sender's nick for a direct
        /// message.
        channel: String,
        from: String,
        offer: DccOffer,
    },
    /// Bytes are about to move: an offer was accepted, in one direction or the
    /// other. Carries everything a progress row needs, so nothing after it has
    /// to repeat itself.
    FileTransferStarted {
        id: u64,
        channel: String,
        filename: String,
        /// True when the file is arriving, false when it is leaving.
        incoming: bool,
        total: Option<u64>,
    },
    /// How far it has got. Dropped rather than queued when the UI is behind.
    FileTransferProgress {
        id: u64,
        transferred: u64,
    },
    /// It finished, one way or the other. `error` is `None` on success, and
    /// `path` is where an arriving file was saved.
    FileTransferEnded {
        id: u64,
        channel: String,
        filename: String,
        path: Option<String>,
        error: Option<String>,
    },
    Error {
        message: String,
        fatal: bool,
    },
}

/// A file someone has offered to send.
///
/// The filename has already been reduced to something safe to create — no
/// directory separators, no `..`, no control characters — so it cannot name a
/// path outside wherever the app decides to put it. Everything else here is
/// the sender's claim and nothing more: `size` in particular is a number they
/// wrote, not a fact about a file.
#[derive(Debug, Clone)]
pub struct DccOffer {
    /// Safe to use as a name. Not necessarily what the sender typed.
    pub filename: String,

    /// Where to connect, as text. Absent for a reverse offer, where the
    /// sender is asking us to listen instead because they have no address to
    /// give out — behind NAT, or behind Tor.
    pub host: Option<String>,

    /// The port to connect to. Absent for a reverse offer.
    pub port: Option<u16>,

    /// How large the sender says it is.
    pub size: Option<u64>,

    /// Identifies a reverse offer when accepting it. Present exactly when
    /// this is one.
    pub token: Option<u64>,
}

/// A SOCKS5 proxy to dial through.
///
/// SOCKS5 only, which is what the transport supports and also what Tor's local
/// listener speaks. The tunnel carries the connection; TLS is still negotiated
/// end to end with the IRC server through it, so the proxy sees ciphertext to a
/// host it was told about and nothing more.
///
/// Dart resolves the app-wide setting against any per-server override before
/// building this, so `ServerConfig::proxy` is an answer rather than a policy.
#[derive(Debug, Clone)]
pub struct ProxyConfig {
    pub host: String,
    pub port: u16,
    /// SOCKS5 username/password auth (RFC 1929). Both or neither.
    ///
    /// Sent to the proxy in the clear, before any TLS exists — it proves who
    /// you are to the proxy and protects nothing else.
    pub username: Option<String>,
    pub password: Option<String>,
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
    /// Dial through this proxy rather than connecting directly. There is no
    /// fallback: if it is set and unreachable, the connection fails.
    pub proxy: Option<ProxyConfig>,
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
            sort_key: member.sort_key,
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
            events::IrcEvent::MemberChanged {
                channel,
                previous,
                member,
            } => Self::MemberChanged {
                channel,
                previous,
                member: member.map(Into::into),
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
            events::IrcEvent::FileOffered {
                id,
                channel,
                from,
                offer,
            } => Self::FileOffered {
                id,
                channel,
                from,
                offer: (*offer).into(),
            },
            events::IrcEvent::FileTransferStarted {
                id,
                channel,
                filename,
                incoming,
                total,
            } => Self::FileTransferStarted {
                id,
                channel,
                filename,
                incoming,
                total,
            },
            events::IrcEvent::FileTransferProgress { id, transferred } => {
                Self::FileTransferProgress { id, transferred }
            }
            events::IrcEvent::FileTransferEnded {
                id,
                channel,
                filename,
                path,
                error,
            } => Self::FileTransferEnded {
                id,
                channel,
                filename,
                path,
                error,
            },
            events::IrcEvent::Error { message, fatal } => Self::Error { message, fatal },
        }
    }
}

impl From<dcc::DccOffer> for DccOffer {
    fn from(offer: dcc::DccOffer) -> Self {
        Self {
            filename: offer.filename,
            // Rendered here rather than on the far side: Dart has no address
            // type, and formatting an `IpAddr` in two places is how the two
            // spellings of an IPv6 address drift apart.
            host: offer.addr.map(|a| a.to_string()),
            port: offer.port,
            size: offer.size,
            token: offer.token,
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
            // Not exposed to Dart on purpose: trusting an extra certificate is
            // a test-only affordance, and an app-settable one would be a way to
            // talk the client into trusting an attacker's certificate.
            extra_root_cert: None,
            proxy: config.proxy.map(Into::into),
        }
    }
}

impl From<ProxyConfig> for types::ProxyConfig {
    fn from(proxy: ProxyConfig) -> Self {
        Self {
            host: proxy.host,
            port: proxy.port,
            // Empty is the same as absent here. A blank field in the settings
            // form must not read as a one-character credential, which SOCKS5
            // would happily encode and the proxy would then reject.
            username: proxy.username.filter(|v| !v.is_empty()),
            password: proxy
                .password
                .filter(|v| !v.is_empty())
                .map(zeroize::Zeroizing::new),
        }
    }
}

// ---------------------------------------------------------------------------
// Removing metadata from an outgoing file.
// ---------------------------------------------------------------------------

/// One thing taken out of a file.
#[derive(Debug, Clone)]
pub struct RemovedItem {
    /// What it was: `"EXIF"`, `"XMP"`, `"comment"`, and so on.
    pub what: String,
    pub bytes: u64,
}

/// What happened when a file was cleaned.
///
/// Four outcomes rather than a `Result`, because the caller has a different
/// decision to make in each: only one of them produces new bytes, and only one
/// of them is a reason to stop.
#[derive(Debug, Clone)]
pub enum CleanOutcome {
    /// Metadata was found and removed. `bytes` is the file to send.
    Cleaned {
        bytes: Vec<u8>,
        /// `"JPEG"`, `"PNG"`, `"GIF"` or `"WebP"`.
        kind: String,
        removed: Vec<RemovedItem>,
    },
    /// A supported image that had nothing to remove — a screenshot, usually.
    ///
    /// Deliberately not `Cleaned` with an empty list: the honest thing to tell
    /// someone is "there was nothing in it", not "it has been cleaned", which
    /// sounds like work was done and invites trust in the wrong place. The
    /// original bytes are unchanged, so none are sent back across the bridge.
    AlreadyClean { kind: String },
    /// Not an image this can rewrite. Not an error: the caller may still want
    /// to send it, and now knows it was not cleaned.
    NotAnImage,
    /// A supported format that did not parse. Worth separating from
    /// `NotAnImage`, because this one probably means a damaged file.
    Malformed { detail: String },
}

/// Remove everything an image carries beyond the picture.
///
/// Rewrites the container; the image data is copied across untouched, so the
/// pixels are byte-identical and nothing is lost to a re-compress.
impl From<Result<media::Stripped, media::StripError>> for CleanOutcome {
    fn from(result: Result<media::Stripped, media::StripError>) -> Self {
        match result {
            Ok(stripped) if stripped.was_already_clean() => Self::AlreadyClean {
                kind: stripped.kind.as_str().to_owned(),
            },
            Ok(stripped) => Self::Cleaned {
                kind: stripped.kind.as_str().to_owned(),
                removed: stripped
                    .removed
                    .iter()
                    .map(|r| RemovedItem {
                        what: r.what.to_owned(),
                        bytes: r.bytes as u64,
                    })
                    .collect(),
                bytes: stripped.bytes,
            },
            Err(media::StripError::Unsupported | media::StripError::Empty) => Self::NotAnImage,
            Err(e) => Self::Malformed {
                detail: e.to_string(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A one-pixel PNG carrying a text chunk, built by hand.
    fn png(with_text: bool) -> Vec<u8> {
        fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
            let mut out = (data.len() as u32).to_be_bytes().to_vec();
            out.extend_from_slice(kind);
            out.extend_from_slice(data);
            out.extend_from_slice(&[0; 4]);
            out
        }
        let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
        out.extend_from_slice(&chunk(b"IHDR", &[0; 13]));
        if with_text {
            out.extend_from_slice(&chunk(b"tEXt", b"Software\0Private Editor"));
        }
        out.extend_from_slice(&chunk(b"IDAT", b"px"));
        out.extend_from_slice(&chunk(b"IEND", b""));
        out
    }

    #[test]
    fn a_file_with_metadata_comes_back_cleaned_and_says_what_went() {
        let outcome = CleanOutcome::from(media::strip(&png(true)));
        let CleanOutcome::Cleaned {
            bytes,
            kind,
            removed,
        } = outcome
        else {
            panic!("expected Cleaned, got {outcome:?}");
        };
        assert_eq!(kind, "PNG");
        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0].what, "text");
        assert!(removed[0].bytes > 0);
        assert!(!bytes.windows(7).any(|w| w == b"Private"));
    }

    #[test]
    fn a_file_with_nothing_in_it_is_not_reported_as_cleaned() {
        // "Cleaned, removed nothing" sounds like work was done. "There was
        // nothing in it" is what actually happened, and the two invite very
        // different amounts of trust.
        let outcome = CleanOutcome::from(media::strip(&png(false)));
        assert!(
            matches!(outcome, CleanOutcome::AlreadyClean { ref kind } if kind == "PNG"),
            "{outcome:?}"
        );
    }

    #[test]
    fn something_that_is_not_an_image_is_not_an_error() {
        // The caller may still want to send it. It just has to know that
        // nothing was removed from it.
        for not_an_image in [&b"%PDF-1.7"[..], &b""[..], &b"hello"[..]] {
            let outcome = CleanOutcome::from(media::strip(not_an_image));
            assert!(matches!(outcome, CleanOutcome::NotAnImage), "{outcome:?}");
        }
    }

    #[test]
    fn a_damaged_image_is_told_apart_from_a_non_image() {
        // This one probably means a truncated download rather than a file
        // picked by mistake, and the user can act on the difference.
        let truncated = &png(true)[..20];
        let outcome = CleanOutcome::from(media::strip(truncated));
        assert!(
            matches!(outcome, CleanOutcome::Malformed { .. }),
            "{outcome:?}"
        );
    }
}
