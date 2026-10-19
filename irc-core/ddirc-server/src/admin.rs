//! The operator's side of the server: what can be done to it, and what it says.
//!
//! The protocol half of this crate answers *clients*. This is the other
//! direction — a person at the machine running the server, who wants to see who
//! is connected, remove someone, close a room, or just watch. It is a separate
//! surface rather than a pile of extra IRC commands for one reason: nothing
//! here is reachable from the network. A client cannot kick itself into being
//! an operator of the server, because there is no wire command for any of this.
//!
//! Three things cross the boundary, and all three are plain data:
//!
//! * [`AdminCommand`] goes in, and is applied by the single task that owns the
//!   state — so an admin action is one more event in the same queue as every
//!   client's, handled completely or not started, like the rest.
//! * [`Snapshot`] comes out on request, as a copy. A UI that held a reference
//!   would need a lock; a UI that holds a copy needs nothing.
//! * [`ServerEvent`]s are broadcast as things happen. A subscriber that falls
//!   behind loses the oldest, which is the right failure for a log view and
//!   means a slow terminal can never slow the server.

use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::{broadcast, mpsc::UnboundedSender, oneshot};

use crate::state::ClientId;

/// Something the operator asks of the server.
///
/// Channels and nicks are matched the way the protocol matches them — ASCII
/// case-insensitively — so `kick #Room BOB` finds `#room` and `bob`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdminCommand {
    /// Remove one person from one channel. They stay on the server.
    Kick {
        channel: String,
        nick: String,
        reason: Option<String>,
    },
    /// Remove one person from the server altogether.
    Disconnect {
        nick: String,
        reason: Option<String>,
    },
    /// Disconnect a nick and refuse it from now on. Names, not addresses: every
    /// client here is on loopback, so an address would ban everybody.
    Ban {
        nick: String,
        reason: Option<String>,
    },
    Unban {
        nick: String,
    },
    /// Set a channel's topic, or clear it with an empty string.
    SetTopic {
        channel: String,
        topic: String,
    },
    /// Empty a channel and remove it.
    CloseChannel {
        channel: String,
        reason: Option<String>,
    },
    /// Give or take channel operator status.
    Op {
        channel: String,
        nick: String,
    },
    Deop {
        channel: String,
        nick: String,
    },
    /// A `NOTICE` from the server itself, to a nick or a channel.
    Notice {
        target: String,
        text: String,
    },
    /// A `NOTICE` from the server to everyone registered.
    Wall {
        text: String,
    },
    /// Replace the message of the day. An empty list restores the default.
    SetMotd {
        lines: Vec<String>,
    },
}

/// What happened, as the operator sees it.
///
/// Message *bodies* are carried for channels and deliberately not for direct
/// messages: a channel is a room the operator is, in effect, hosting, while a
/// private message is between two people who did not address it to the person
/// running the server. The fact that it happened is still reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EventKind {
    /// A connection was accepted. Nothing is known about it yet.
    Connected {
        id: ClientId,
    },
    /// A connection ended before it registered.
    Dropped {
        id: ClientId,
        reason: String,
    },
    Registered {
        id: ClientId,
        nick: String,
    },
    NickChanged {
        old: String,
        new: String,
    },
    Joined {
        nick: String,
        channel: String,
    },
    Parted {
        nick: String,
        channel: String,
        reason: Option<String>,
    },
    Kicked {
        nick: String,
        channel: String,
        by: String,
        reason: Option<String>,
    },
    Quit {
        nick: String,
        reason: String,
    },
    Mode {
        channel: String,
        by: String,
        nick: String,
        op: bool,
    },
    Topic {
        channel: String,
        by: String,
        topic: String,
    },
    Message {
        from: String,
        target: String,
        /// `None` for a direct message — see the type's own note.
        text: Option<String>,
        notice: bool,
    },
    /// The outcome of an [`AdminCommand`], in words.
    Admin {
        ok: bool,
        text: String,
    },
}

/// One thing that happened, and when.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerEvent {
    /// Seconds since the Unix epoch.
    pub at: u64,
    pub kind: EventKind,
}

impl ServerEvent {
    pub(crate) fn new(kind: EventKind) -> Self {
        Self { at: now(), kind }
    }

    /// One line of plain text, without a timestamp. What the headless log
    /// prints and what the log pane shows.
    pub fn describe(&self) -> String {
        fn why(reason: &Option<String>) -> String {
            match reason.as_deref() {
                Some(r) if !r.is_empty() => format!(" ({r})"),
                _ => String::new(),
            }
        }
        match &self.kind {
            EventKind::Connected { id } => format!("connection #{id} opened"),
            EventKind::Dropped { id, reason } => {
                format!("connection #{id} closed before registering ({reason})")
            }
            EventKind::Registered { id, nick } => format!("{nick} registered (connection #{id})"),
            EventKind::NickChanged { old, new } => format!("{old} is now {new}"),
            EventKind::Joined { nick, channel } => format!("{nick} joined {channel}"),
            EventKind::Parted {
                nick,
                channel,
                reason,
            } => format!("{nick} left {channel}{}", why(reason)),
            EventKind::Kicked {
                nick,
                channel,
                by,
                reason,
            } => format!("{by} kicked {nick} from {channel}{}", why(reason)),
            EventKind::Quit { nick, reason } => format!("{nick} quit ({reason})"),
            EventKind::Mode {
                channel,
                by,
                nick,
                op,
            } => format!(
                "{by} {} operator status {} {nick} in {channel}",
                if *op { "gave" } else { "took" },
                if *op { "to" } else { "from" },
            ),
            EventKind::Topic { channel, by, topic } if topic.is_empty() => {
                format!("{by} cleared the topic of {channel}")
            }
            EventKind::Topic { channel, by, topic } => {
                format!("{by} set the topic of {channel}: {topic}")
            }
            EventKind::Message {
                from,
                target,
                text: Some(text),
                notice,
            } => {
                if *notice {
                    format!("{target} -{from}- {text}")
                } else {
                    format!("{target} <{from}> {text}")
                }
            }
            EventKind::Message {
                from,
                target,
                text: None,
                ..
            } => format!("{from} sent a private message to {target}"),
            EventKind::Admin { ok: true, text } => format!("ok: {text}"),
            EventKind::Admin { ok: false, text } => format!("refused: {text}"),
        }
    }
}

/// A connection, as the operator sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserInfo {
    pub id: ClientId,
    /// `None` until it has chosen one.
    pub nick: Option<String>,
    pub user: Option<String>,
    pub realname: Option<String>,
    pub registered: bool,
    /// Channel names as they were first typed, sorted.
    pub channels: Vec<String>,
    /// Seconds since the Unix epoch.
    pub connected_at: u64,
}

/// One person in a channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemberInfo {
    pub nick: String,
    pub op: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelInfo {
    pub name: String,
    pub topic: Option<String>,
    pub topic_set_by: Option<String>,
    /// Operators first, then by nick.
    pub members: Vec<MemberInfo>,
}

/// A copy of everything worth showing, taken at one instant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub server_name: String,
    pub network_name: String,
    pub started_at: u64,
    /// Every connection accepted since the server started.
    pub connections_total: u64,
    /// Every `PRIVMSG` and `NOTICE` relayed.
    pub messages_total: u64,
    /// Registered users first, by nick; then connections still registering.
    pub users: Vec<UserInfo>,
    /// By name.
    pub channels: Vec<ChannelInfo>,
    /// Folded nicks, sorted.
    pub banned: Vec<String>,
    pub motd: Vec<String>,
}

/// What reaches the task that owns the state, besides client traffic.
pub(crate) enum Request {
    Command {
        command: AdminCommand,
        reply: Option<oneshot::Sender<Result<String, String>>>,
    },
    Snapshot(oneshot::Sender<Snapshot>),
}

/// A way to watch and steer a running server. Cheap to clone.
///
/// Stays valid after the server stops, and says so: every method then reports
/// that the server is gone rather than panicking or waiting forever.
#[derive(Clone)]
pub struct ServerHandle {
    requests: UnboundedSender<Request>,
    events: broadcast::Sender<ServerEvent>,
}

/// Room for a burst without a subscriber having to keep up with it. A log view
/// that is more than this far behind is not being read.
pub(crate) const EVENT_BACKLOG: usize = 1024;

impl ServerHandle {
    pub(crate) fn new(
        requests: UnboundedSender<Request>,
        events: broadcast::Sender<ServerEvent>,
    ) -> Self {
        Self { requests, events }
    }

    /// Apply a command and wait for the outcome. `Err` is a refusal, in words —
    /// no such nick, not on that channel — or that the server has stopped.
    pub async fn execute(&self, command: AdminCommand) -> Result<String, String> {
        let (reply, answer) = oneshot::channel();
        self.requests
            .send(Request::Command {
                command,
                reply: Some(reply),
            })
            .map_err(|_| STOPPED.to_owned())?;
        answer.await.unwrap_or_else(|_| Err(STOPPED.to_owned()))
    }

    /// Apply a command without waiting. The outcome still arrives as an
    /// [`EventKind::Admin`] for anyone subscribed, which is how a UI that only
    /// shows a log hears about it.
    pub fn send(&self, command: AdminCommand) -> bool {
        self.requests
            .send(Request::Command {
                command,
                reply: None,
            })
            .is_ok()
    }

    /// A copy of the current state, or `None` once the server has stopped.
    pub async fn snapshot(&self) -> Option<Snapshot> {
        let (reply, answer) = oneshot::channel();
        self.requests.send(Request::Snapshot(reply)).ok()?;
        answer.await.ok()
    }

    /// Everything that happens from now on.
    pub fn subscribe(&self) -> broadcast::Receiver<ServerEvent> {
        self.events.subscribe()
    }
}

const STOPPED: &str = "the server has stopped";

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
