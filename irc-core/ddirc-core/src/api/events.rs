//! Events emitted by the core, consumed by the UI.
//!
//! One flat enum rather than a callback per event type: it maps directly onto a
//! Dart `Stream`, keeps ordering guarantees obvious, and means adding an event
//! later does not change the API surface.

use crate::api::types::{AuthOutcome, ChatMessage, ConnectionStatus, MemberView};
use crate::dcc::DccOffer;

/// Something that happened on a connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IrcEvent {
    /// The connection lifecycle moved on. Drives the status dot, and carries
    /// reconnect countdowns so the UI can show them inline rather than in a
    /// blocking dialog.
    Status {
        status: ConnectionStatus,
        detail: Option<String>,
    },

    /// Registration completed. `nick` is what the server actually gave us,
    /// which may differ from what we asked for.
    Registered {
        nick: String,
        network: Option<String>,
        auth: AuthOutcome,
    },

    /// The server named its network in `ISUPPORT`.
    ///
    /// Separate from [`IrcEvent::Registered`] because `RPL_ISUPPORT` arrives
    /// *after* the welcome numeric — reporting the name at registration would
    /// always report nothing.
    NetworkNamed { network: String },

    /// A chat message, already sanitised.
    Message(Box<ChatMessage>),

    /// Someone joined a channel.
    Joined {
        channel: String,
        nick: String,
        is_self: bool,
    },

    /// Someone left a channel.
    Parted {
        channel: String,
        nick: String,
        is_self: bool,
        reason: Option<String>,
    },

    /// Someone quit the network. Emitted once per shared channel so each
    /// conversation can show it in place.
    Quit {
        channel: String,
        nick: String,
        reason: Option<String>,
    },

    /// Someone changed nick. Emitted once per shared channel.
    NickChanged {
        channel: String,
        old: String,
        new: String,
        is_self: bool,
    },

    /// A channel topic was set or changed. `set_by` is absent for the topic
    /// delivered on join.
    TopicChanged {
        channel: String,
        topic: String,
        set_by: Option<String>,
    },

    /// The whole roster, for the moments that genuinely need one: the end of a
    /// `NAMES` burst, and our own join.
    ///
    /// Everything after that is a [`Self::MemberChanged`]. Sending the roster
    /// on every arrival and departure would be one event carrying 883 members,
    /// serialised across the FFI and re-sorted, because somebody joined.
    MemberList {
        channel: String,
        members: Vec<MemberView>,
    },

    /// One person in a channel arrived, left, was renamed, changed privilege,
    /// or went away — applied to the roster the UI already holds.
    ///
    /// Deliberately shaped as a replacement rather than four kinds of event,
    /// because the UI's work is the same in every case: find the row filed
    /// under `previous`, and put `member` where it now belongs. A rename is
    /// then not a special case, and neither is an op, both of which move
    /// someone in the ordering.
    MemberChanged {
        channel: String,
        /// The nick the roster currently files them under — the row to replace
        /// or remove, spelled as the UI was given it. For an arrival there is
        /// no such row and this is the new nick.
        previous: String,
        /// What they are now, or [`None`] if they are gone.
        member: Option<MemberView>,
    },

    /// Someone's channel privileges changed.
    ModeChanged {
        channel: String,
        by: Option<String>,
        affected: Vec<String>,
    },

    /// Incoming messages were dropped by flood protection. Surfaced honestly so
    /// a quiet gap in a conversation is never mistaken for silence.
    MessagesDropped { channel: Option<String>, count: u64 },

    /// Someone offered to send a file, over DCC.
    ///
    /// Reported, never answered. Accepting means opening a connection to an
    /// address a stranger chose, or opening a listener for them — either way a
    /// decision the user makes, not one the client makes on their behalf.
    ///
    /// The offer has already been through [`crate::dcc::offer::parse_send`],
    /// so the filename is safe to create and the address is an `IpAddr` rather
    /// than a string. Everything else about it is still the sender's claim.
    FileOffered {
        /// Names this offer for as long as it is worth answering. Passed back
        /// to accept it, so the UI never has to hand the core an address a
        /// stranger chose — it refers to the offer the core already parsed.
        id: u64,
        /// The conversation it arrived in, so it can be shown in place. A
        /// channel name, or the sender's nick for a direct message.
        channel: String,
        /// Who offered it.
        from: String,
        offer: Box<DccOffer>,
    },

    /// Bytes are about to move, in either direction.
    ///
    /// The point at which a transfer becomes real: for an incoming one the
    /// connection is up, and for an outgoing one somebody accepted. Carries
    /// what the UI needs to draw a row, so nothing after this has to repeat it.
    FileTransferStarted {
        id: u64,
        /// Where to show it — the conversation the offer belongs to.
        channel: String,
        filename: String,
        /// True when the file is arriving, false when it is leaving.
        incoming: bool,
        /// What the sender claims, which for an outgoing transfer is a fact.
        total: Option<u64>,
    },

    /// How far a transfer has got. Dropped rather than queued when the UI is
    /// behind, so a progress number can never stall the transfer it describes.
    FileTransferProgress { id: u64, transferred: u64 },

    /// A transfer finished, one way or the other.
    ///
    /// One event for both outcomes because the UI does the same thing with
    /// them — replaces the progress row with a result — and two events would
    /// mean two ways to forget to remove it.
    FileTransferEnded {
        id: u64,
        channel: String,
        filename: String,
        /// Where it was saved, for an incoming transfer that succeeded.
        path: Option<String>,
        /// Why it stopped, when it did not succeed. `None` is success.
        error: Option<String>,
    },

    /// A server error or a protocol-level problem worth showing the user.
    Error { message: String, fatal: bool },
}

impl IrcEvent {
    /// The channel this event belongs to, if any, for routing to a conversation.
    pub fn channel(&self) -> Option<&str> {
        match self {
            Self::Joined { channel, .. }
            | Self::Parted { channel, .. }
            | Self::Quit { channel, .. }
            | Self::NickChanged { channel, .. }
            | Self::TopicChanged { channel, .. }
            | Self::MemberList { channel, .. }
            | Self::MemberChanged { channel, .. }
            | Self::ModeChanged { channel, .. } => Some(channel),
            Self::Message(message) => Some(message.target.name()),
            Self::FileOffered { channel, .. }
            | Self::FileTransferStarted { channel, .. }
            | Self::FileTransferEnded { channel, .. } => Some(channel),
            // Progress carries no channel of its own: it is only ever read
            // against a transfer the UI already placed when it started, and
            // repeating the name on every chunk would be a name to keep in
            // step for no gain.
            Self::FileTransferProgress { .. } => None,
            Self::MessagesDropped { channel, .. } => channel.as_deref(),
            Self::Status { .. }
            | Self::Registered { .. }
            | Self::NetworkNamed { .. }
            | Self::Error { .. } => None,
        }
    }

    /// True for events the UI renders as small, muted, centred system lines
    /// rather than as messages.
    pub fn is_system(&self) -> bool {
        matches!(
            self,
            Self::Joined { .. }
                | Self::Parted { .. }
                | Self::Quit { .. }
                | Self::NickChanged { .. }
                | Self::TopicChanged { .. }
                | Self::ModeChanged { .. }
                | Self::MessagesDropped { .. }
                | Self::Status { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::types::Target;

    fn message() -> IrcEvent {
        IrcEvent::Message(Box::new(ChatMessage {
            target: Target::Channel("#test".to_owned()),
            sender: "alice".to_owned(),
            sender_prefix: Some("@".to_owned()),
            spans: Vec::new(),
            is_self: false,
            is_mention: false,
            is_action: false,
            is_notice: false,
        }))
    }

    #[test]
    fn channel_routing_covers_message_and_system_events() {
        assert_eq!(message().channel(), Some("#test"));
        assert_eq!(
            IrcEvent::Joined {
                channel: "#test".to_owned(),
                nick: "bob".to_owned(),
                is_self: false
            }
            .channel(),
            Some("#test")
        );
    }

    #[test]
    fn connection_events_are_not_channel_scoped() {
        let status = IrcEvent::Status {
            status: ConnectionStatus::Connecting,
            detail: None,
        };
        assert_eq!(status.channel(), None);
        assert_eq!(
            IrcEvent::Error {
                message: "x".to_owned(),
                fatal: false
            }
            .channel(),
            None
        );
    }

    #[test]
    fn messages_are_not_system_lines() {
        assert!(!message().is_system(), "real messages are not subordinate");
        assert!(IrcEvent::Joined {
            channel: "#t".to_owned(),
            nick: "b".to_owned(),
            is_self: false
        }
        .is_system());
    }
}
