//! What XMPP means, as a pure state machine.
//!
//! Stanzas in, [`Effects`] out: the events to show, and the stanzas to send. No
//! socket, no clock, no task. That is the same split the IRC side makes between
//! its actor and the lines it is fed, and for the same reason - everything that
//! can go wrong in the protocol can be tested by writing down the XML that
//! arrived and asserting on what came out, and nothing needs a server.
//!
//! The mapping onto what the app understands is the part worth reading first:
//! a room is a channel, an occupant is a member, a one-to-one chat is a direct
//! message, a room's subject is its topic. See [`crate::xmpp`].
//!
//! Three rules run through all of it.
//!
//! **Nothing is answered that was not asked.** No version, no local time, no
//! last-activity, no feature list, no delivery or read receipts, no typing
//! notifications. A request for one gets `service-unavailable`, because an IQ
//! must be answered and that is the answer that says nothing. Only a ping, which
//! reveals nothing, is answered in kind. This is the CTCP decision again.
//!
//! **Only the right party may say a thing.** A carbon copy is believed only
//! when it comes from our own account, a message ID only from the room that
//! assigned it, a reply only to a request we sent.
//!
//! **Text from the network is cleaned before it is shown.** Names lose layout
//! characters, bodies lose control characters, both are bounded.

use std::collections::HashMap;

use tokio_xmpp::jid::{BareJid, FullJid, Jid};
use tokio_xmpp::minidom::Element;
use tokio_xmpp::parsers::carbons;
use tokio_xmpp::parsers::delay::Delay;
use tokio_xmpp::parsers::iq::Iq;
use tokio_xmpp::parsers::mam;
use tokio_xmpp::parsers::message::{Id, Lang, Message, MessageType};
use tokio_xmpp::parsers::message_correct::Replace;
use tokio_xmpp::parsers::muc::muc::History;
use tokio_xmpp::parsers::muc::user::{Affiliation, MucUser, Role, Status};
use tokio_xmpp::parsers::muc::Muc;
use tokio_xmpp::parsers::presence::{Presence, Show, Type as PresenceType};
use tokio_xmpp::parsers::roster::Roster;
use tokio_xmpp::parsers::rsm::SetQuery;
use tokio_xmpp::parsers::stanza_error::{DefinedCondition, ErrorType, StanzaError};
use tokio_xmpp::parsers::stanza_id::StanzaId;
use tokio_xmpp::Stanza;

use crate::api::events::IrcEvent;
use crate::api::types::{AuthOutcome, ChatMessage, Target};
use crate::conn::actor::ClientCommand;
use crate::state::{limits, truncate};
use crate::text::{format, reply};
use crate::xmpp::config::XmppConfig;
use crate::xmpp::state::{clean_name, mentions, Occupant, Room};

/// The longest message body shown or sent, in characters.
///
/// Servers cap a stanza, and a longer body is split rather than refused when
/// sending. On receiving, the excess is dropped: nobody reads past this, and a
/// body of megabytes is a way to make a client slow.
const MAX_BODY_CHARS: usize = 4_000;

/// How many messages one request to a room's archive asks for.
const CATCH_UP_PAGE: usize = 100;

/// How many a catch-up fetches in all before it stops, however much is left.
///
/// A phone off for a week would otherwise pull a week of a busy room on
/// reconnecting, which is slow, which costs data, and which nobody reads. What
/// was missed beyond this is still in the archive; it is the *replay* that is
/// bounded.
const CATCH_UP_TOTAL: usize = 500;

/// How many requests a catch-up makes in all.
///
/// A bound of its own, not a consequence of [`CATCH_UP_TOTAL`]: the archive
/// decides whether there is another page, and one that returns empty pages, or
/// the same cursor again, never advances a count of messages. It is exactly
/// enough requests to fetch the total at the page size, and one more for the
/// page that says it is finished.
const CATCH_UP_PAGES: usize = CATCH_UP_TOTAL / CATCH_UP_PAGE + 1;

/// The longest id from a room's archive that is kept, as for a live message.
///
/// The id is stored - as the place to catch up from and in the window of ids
/// recently shown - and handed to the app, so one of unbounded length is memory
/// the other end chooses to have us spend.
const MAX_ARCHIVE_ID: usize = 200;

/// How many times a room refusing our nick as taken is answered by trying
/// another before giving up.
const MAX_NICK_ATTEMPTS: u32 = 3;

/// What a step produced.
#[derive(Debug, Default)]
pub struct Effects {
    /// For the UI, in order.
    pub events: Vec<IrcEvent>,
    /// For the server, in order.
    pub send: Vec<Stanza>,
}

impl Effects {
    fn event(&mut self, event: IrcEvent) {
        self.events.push(event);
    }

    fn send(&mut self, stanza: impl Into<Stanza>) {
        self.send.push(stanza.into());
    }

    fn error(&mut self, message: impl Into<String>) {
        self.event(IrcEvent::Error {
            message: message.into(),
            fatal: false,
        });
    }
}

/// A request we sent and are waiting on the answer to.
#[derive(Debug)]
enum Pending {
    Roster,
    Carbons,
    Kick {
        room: BareJid,
    },
    /// A request to a room's archive for what was said while we were away. The
    /// id of this request is also the `queryid` its results carry, which is how
    /// a result is known to answer it.
    CatchUp {
        room: BareJid,
        /// Archived messages received so far, across every page.
        fetched: usize,
        /// Requests made so far, this one included.
        pages: usize,
        /// What this request asked for everything after. A page that ends where
        /// it began has moved nowhere.
        after: String,
        /// `fetched` when this request was sent, so the page can be told to
        /// have been empty.
        fetched_at_start: usize,
    },
}

/// One account's conversation with its server.
#[derive(Debug)]
pub struct Session {
    account: BareJid,
    default_nick: String,
    rooms: HashMap<BareJid, Room>,
    pending: HashMap<String, Pending>,
    /// Makes ids that cannot collide with another client's on the same account.
    id_prefix: String,
    counter: u64,
}

impl Session {
    pub fn new(config: &XmppConfig) -> Option<Self> {
        let account = config.bare_jid().ok()?;
        let default_nick = clean_name(&config.room_nick());
        let mut session = Self {
            account,
            default_nick,
            rooms: HashMap::new(),
            pending: HashMap::new(),
            id_prefix: format!("ddirc{:016x}", rand::random::<u64>()),
            counter: 0,
        };
        for room in &config.rooms {
            if let Ok(jid) = room.trim().parse::<BareJid>() {
                let nick = session.default_nick.clone();
                session.rooms.insert(jid.clone(), Room::new(jid, nick));
            }
        }
        Some(session)
    }

    pub fn account(&self) -> &BareJid {
        &self.account
    }

    fn next_id(&mut self) -> String {
        self.counter += 1;
        format!("{}-{}", self.id_prefix, self.counter)
    }

    /// The connection is up, and the server has bound us a resource.
    ///
    /// Called for a fresh login and never for a resumed stream: a resumed one
    /// has lost nothing and needs nothing redone.
    pub fn on_online(&mut self, bound: &FullJid) -> Effects {
        let mut fx = Effects::default();
        let _ = bound;
        self.pending.clear();
        fx.event(IrcEvent::Registered {
            nick: self.account.to_string(),
            network: Some(self.account.domain().to_string()),
            auth: AuthOutcome::Sasl,
        });

        // Carbons, so what is said from another device appears here too.
        let id = self.next_id();
        self.pending.insert(id.clone(), Pending::Carbons);
        fx.send(Iq::from_set(id, carbons::Enable));

        // The roster has to be asked for before presence, or the server does
        // not treat the session as one that wants contacts' presence.
        let id = self.next_id();
        self.pending.insert(id.clone(), Pending::Roster);
        fx.send(Iq::from_get(
            id,
            Roster {
                ver: None,
                items: Vec::new(),
            },
        ));

        // Plain presence: no capabilities hash, no client name, no status text.
        // A server needs to be told we are here and nothing else.
        fx.send(Presence::available());

        // A fresh login has lost every room. Ask for each again.
        let jids: Vec<BareJid> = self.rooms.keys().cloned().collect();
        for jid in jids {
            if let Some(room) = self.rooms.get_mut(&jid) {
                room.joined = false;
                room.leaving = false;
                room.clear_occupants();
                room.renaming.clear();
            }
            self.send_join(&jid, None, &mut fx);
        }
        fx
    }

    // ---- commands -----------------------------------------------------

    pub fn on_command(&mut self, command: ClientCommand) -> Effects {
        let mut fx = Effects::default();
        match command {
            ClientCommand::Join { channel, key } => self.join(&channel, key, &mut fx),
            ClientCommand::Part { channel, .. } => self.part(&channel, &mut fx),
            ClientCommand::Kick {
                channel,
                nick,
                reason,
            } => self.kick(&channel, &nick, reason.as_deref(), &mut fx),
            ClientCommand::SendMessage { target, text } => self.say(&target, &text, false, &mut fx),
            ClientCommand::SendAction { target, text } => self.say(&target, &text, true, &mut fx),
            ClientCommand::SendReply {
                target,
                text,
                reply,
            } => {
                let quoted =
                    reply::format_reply(&reply.nick, &reply::excerpt(&reply.excerpt), &text);
                self.say(&target, &quoted, false, &mut fx);
            }
            ClientCommand::SetNick(nick) => self.set_nick(&nick, &mut fx),
            ClientCommand::SetTopic { channel, topic } => self.set_topic(&channel, &topic, &mut fx),
            ClientCommand::ListChannels
            | ClientCommand::Whois { .. }
            | ClientCommand::SendFile { .. }
            | ClientCommand::AcceptFile { .. }
            | ClientCommand::CancelTransfer { .. } => {
                fx.error("That is not available over XMPP yet.");
            }
            // The connection's own business, handled where the connection is.
            ClientCommand::Reconnect | ClientCommand::Disconnect { .. } => {}
        }
        fx
    }

    fn room_jid(channel: &str) -> Option<BareJid> {
        let jid: BareJid = channel.trim().parse().ok()?;
        jid.node().is_some().then_some(jid)
    }

    fn join(&mut self, channel: &str, password: Option<String>, fx: &mut Effects) {
        let Some(jid) = Self::room_jid(channel) else {
            fx.error(format!(
                "'{}' is not a room address; it looks like room@conference.example.org.",
                clean_name(channel)
            ));
            return;
        };
        if self.rooms.get(&jid).is_some_and(|r| r.joined && !r.leaving) {
            return;
        }
        let nick = self.default_nick.clone();
        self.rooms.insert(jid.clone(), Room::new(jid.clone(), nick));
        self.send_join(&jid, password, fx);
    }

    fn send_join(&mut self, jid: &BareJid, password: Option<String>, fx: &mut Effects) {
        let Some(room) = self.rooms.get(jid) else {
            return;
        };
        let Ok(occupant) = jid.with_resource_str(&room.nick) else {
            fx.error(format!(
                "'{}' cannot be used as a nickname in a room.",
                room.nick
            ));
            self.rooms.remove(jid);
            return;
        };
        let mut muc = Muc::new();
        if let Some(password) = password.filter(|p| !p.is_empty()) {
            muc = muc.with_password(password);
        }
        // No history from the room itself. It would arrive as a burst on every
        // join, indistinguishable from live talk apart from a timestamp, and
        // what the user missed is the archive's job, not the room's.
        muc = muc.with_history(History::new().with_maxstanzas(0));
        fx.send(
            Presence::available()
                .with_to(Jid::from(occupant))
                .with_payload(muc),
        );
    }

    fn part(&mut self, channel: &str, fx: &mut Effects) {
        let Some(jid) = Self::room_jid(channel) else {
            return;
        };
        let Some(room) = self.rooms.get_mut(&jid) else {
            return;
        };
        if !room.joined {
            // Never confirmed, so there will be no presence to wait for.
            let name = room.name();
            let nick = room.nick.clone();
            self.rooms.remove(&jid);
            fx.event(IrcEvent::Parted {
                channel: name,
                nick,
                is_self: true,
                reason: None,
            });
            return;
        }
        room.leaving = true;
        if let Ok(occupant) = jid.with_resource_str(&room.nick) {
            fx.send(Presence::unavailable().with_to(Jid::from(occupant)));
        }
    }

    fn kick(&mut self, channel: &str, nick: &str, reason: Option<&str>, fx: &mut Effects) {
        let Some(jid) = Self::room_jid(channel) else {
            return;
        };
        let id = self.next_id();
        let reason = reason
            .map(clean_text)
            .filter(|r| !r.is_empty())
            .map(|r| format!("<reason>{}</reason>", xml_escape(&r)))
            .unwrap_or_default();
        // Written out rather than built, because the builder wants a validated
        // attribute name for every attribute and these three are constants. The
        // nick is escaped: it is the one part of this that someone else chose.
        let Ok(query) = format!(
            "<query xmlns='{NS_MUC_ADMIN}'><item nick='{}' role='none'>{reason}</item></query>",
            xml_escape(nick.trim())
        )
        .parse::<Element>() else {
            fx.error("That nickname cannot be sent.");
            return;
        };
        self.pending
            .insert(id.clone(), Pending::Kick { room: jid.clone() });
        fx.send(Iq::Set {
            from: None,
            to: Some(Jid::from(jid)),
            id,
            payload: query,
        });
    }

    fn set_nick(&mut self, nick: &str, fx: &mut Effects) {
        let nick = clean_name(nick.trim());
        if nick.is_empty() {
            fx.error("A nickname cannot be empty.");
            return;
        }
        self.default_nick = nick.clone();
        let joined: Vec<BareJid> = self
            .rooms
            .values()
            .filter(|r| r.joined)
            .map(|r| r.jid.clone())
            .collect();
        for jid in joined {
            match jid.with_resource_str(&nick) {
                Ok(occupant) => fx.send(Presence::available().with_to(Jid::from(occupant))),
                Err(_) => fx.error(format!("'{nick}' cannot be used as a nickname in a room.")),
            }
        }
    }

    fn set_topic(&mut self, channel: &str, topic: &str, fx: &mut Effects) {
        let Some(jid) = Self::room_jid(channel) else {
            return;
        };
        let flattened: String = topic
            .chars()
            .map(|c| if c.is_control() { ' ' } else { c })
            .collect();
        let mut message = Message::groupchat(Some(Jid::from(jid)));
        message.id = Some(Id(self.next_id()));
        message
            .subjects
            .insert(Lang::new(), truncate(flattened.trim(), limits::MAX_TOPIC));
        fx.send(message);
    }

    /// Send text to a room or a person.
    fn say(&mut self, target: &str, text: &str, action: bool, fx: &mut Effects) {
        let Ok(to) = target.trim().parse::<Jid>() else {
            fx.error(format!("'{}' is not an address.", clean_name(target)));
            return;
        };
        let room = to.to_bare();
        // Who this is for is decided by the address alone, and the three cases
        // must not be confused. A room's own address, with no resource, is the
        // room: everyone in it hears. The same address *with* a resource is one
        // person in it, and what is said is private. Anything else is a person.
        // Treating the second as the first would send a private reply to the
        // whole room.
        let known_room = self.rooms.get(&room);
        let in_room = known_room.is_some() && to.resource().is_none();
        if known_room.is_some_and(|r| !r.joined) {
            fx.error(format!("You are not in {room} yet."));
            return;
        }
        // A private message to someone in a room is filed under their address in
        // it, as one received from them is; anyone else under their account.
        let conversation = if known_room.is_some() {
            to.to_string()
        } else {
            room.to_string()
        };
        for part in sanitize_outgoing(text) {
            let body = if action {
                format!("/me {part}")
            } else {
                part.clone()
            };
            let mut message = if in_room {
                Message::groupchat(Some(Jid::from(room.clone())))
            } else {
                Message::chat(Some(to.clone()))
            };
            message.id = Some(Id(self.next_id()));
            message.bodies.insert(Lang::new(), body);
            fx.send(message);

            // A room reflects what is said in it, and that reflection is what
            // is shown; echoing here as well would show everything twice. A
            // person does not reflect, so the line is shown now - the same
            // choice, and for the same reason, as on IRC.
            if !in_room {
                let (reply_to, shown) = if action {
                    (None, part.as_str())
                } else {
                    split_reply(&part)
                };
                fx.event(IrcEvent::Message(Box::new(ChatMessage {
                    target: Target::Direct(conversation.clone()),
                    sender: self.account.to_string(),
                    sender_prefix: None,
                    spans: format::parse(shown),
                    is_self: true,
                    is_mention: false,
                    is_action: action,
                    is_notice: false,
                    msgid: None,
                    server_time_ms: None,
                    reply_to,
                })));
            }
        }
    }

    // ---- stanzas ------------------------------------------------------

    pub fn on_stanza(&mut self, stanza: Stanza) -> Effects {
        let mut fx = Effects::default();
        match stanza {
            Stanza::Message(message) => self.on_message(message, &mut fx),
            Stanza::Presence(presence) => self.on_presence(presence, &mut fx),
            Stanza::Iq(iq) => self.on_iq(iq, &mut fx),
        }
        fx
    }

    fn on_iq(&mut self, iq: Iq, fx: &mut Effects) {
        match iq {
            Iq::Get {
                from, id, payload, ..
            }
            | Iq::Set {
                from, id, payload, ..
            } => {
                // Every request has to be answered. A ping, which says nothing
                // about us, is answered; everything else is declined in the
                // way that says nothing either.
                let reply = if payload.is("ping", NS_PING) {
                    Iq::empty_result(from.clone().unwrap_or_else(|| self.server()), id)
                } else {
                    let error = StanzaError::new(
                        ErrorType::Cancel,
                        DefinedCondition::ServiceUnavailable,
                        "en",
                        "",
                    );
                    let mut reply = Iq::from_error(id, error);
                    *reply.to_mut() = from;
                    reply
                };
                fx.send(reply);
            }
            Iq::Result {
                from, id, payload, ..
            } => {
                if !self.came_from_expected(&id, from.as_ref()) {
                    return;
                }
                if let Some(Pending::CatchUp {
                    room,
                    fetched,
                    pages,
                    after,
                    fetched_at_start,
                }) = self.pending.remove(&id)
                {
                    // The end of a page. Another only if the archive says there
                    // is one *and* every limit we hold agrees. The archive's
                    // word is the least of them: it is the one party that could
                    // say "more" for ever.
                    let fin = payload.and_then(|p| mam::Fin::try_from(p).ok());
                    let more =
                        fin.filter(|f| !f.complete)
                            .and_then(|f| f.set.last)
                            .filter(|last| {
                                // Nothing came in this page, or the cursor has not
                                // moved: the archive is not getting anywhere.
                                fetched > fetched_at_start
                                    && *last != after
                                    && fetched < CATCH_UP_TOTAL
                                    && pages < CATCH_UP_PAGES
                            });
                    if let Some(last) = more {
                        self.send_catch_up(&room, last, fetched, pages, fx);
                    }
                }
            }
            Iq::Error {
                from, id, error, ..
            } => {
                if !self.came_from_expected(&id, from.as_ref()) {
                    return;
                }
                match self.pending.remove(&id) {
                    Some(Pending::Kick { room }) => fx.error(format!(
                        "Could not remove them from {room}: {}.",
                        describe(&error.defined_condition)
                    )),
                    // Carbons, the roster and an archive are conveniences. A
                    // server that lacks them is still a server worth using.
                    Some(Pending::Carbons)
                    | Some(Pending::Roster)
                    | Some(Pending::CatchUp { .. })
                    | None => {}
                }
            }
        }
    }

    fn server(&self) -> Jid {
        Jid::from(BareJid::from_parts(None, self.account.domain()))
    }

    /// An answer is only believed from where the question went.
    ///
    /// Without this, anyone who could guess an id - and ours are short - could
    /// answer for the server.
    fn came_from_expected(&self, id: &str, from: Option<&Jid>) -> bool {
        let Some(pending) = self.pending.get(id) else {
            return false;
        };
        let Some(from) = from else {
            // No `from` means our own server speaking for itself. That is who
            // answers about the roster and carbons, and it is not who answers
            // for a room.
            return matches!(pending, Pending::Roster | Pending::Carbons);
        };
        let bare = from.to_bare();
        match pending {
            // A room's answer is from the room itself - its address and no
            // resource. A resource is an *occupant*, anyone who joined, and
            // would otherwise be able to answer for the room by guessing an id.
            Pending::Kick { room } | Pending::CatchUp { room, .. } => {
                from.resource().is_none() && &bare == room
            }
            Pending::Roster | Pending::Carbons => {
                bare == self.account
                    || bare.domain() == self.account.domain() && bare.node().is_none()
            }
        }
    }

    fn on_presence(&mut self, presence: Presence, fx: &mut Effects) {
        let Some(from) = presence.from.clone() else {
            return;
        };
        let bare = from.to_bare();
        if self.rooms.contains_key(&bare) {
            self.on_room_presence(
                &bare,
                from.resource().map(|r| r.as_str().to_owned()),
                presence,
                fx,
            );
            return;
        }
        if presence.type_ == PresenceType::Subscribe {
            // Someone asks to see when we are online. Never answered on our
            // behalf: accepting tells them we exist and are reading, which is
            // the user's to give. Shown as a notice from them, so it arrives
            // as a request like a first message from a stranger does.
            let who = bare.to_string();
            fx.event(IrcEvent::Message(Box::new(ChatMessage {
                target: Target::Direct(who.clone()),
                sender: who.clone(),
                sender_prefix: None,
                spans: format::parse(&format!("{who} asked to see when you are online.")),
                is_self: false,
                is_mention: false,
                is_action: false,
                is_notice: true,
                msgid: None,
                server_time_ms: None,
                reply_to: None,
            })));
        }
        // Everyone else's availability has nowhere to be shown yet.
    }

    fn on_room_presence(
        &mut self,
        jid: &BareJid,
        nick: Option<String>,
        presence: Presence,
        fx: &mut Effects,
    ) {
        if presence.type_ == PresenceType::Error {
            self.on_room_error(jid, &presence, fx);
            return;
        }
        // Presence from the room itself, with no occupant, carries nothing here.
        let Some(raw_nick) = nick else {
            return;
        };
        let nick = clean_name(&raw_nick);
        let user = presence
            .payloads
            .iter()
            .find_map(|e| MucUser::try_from(e.clone()).ok());
        let statuses: Vec<Status> = user.as_ref().map(|u| u.status.clone()).unwrap_or_default();
        let item = user.as_ref().and_then(|u| u.items.first());

        let Some(room) = self.rooms.get_mut(jid) else {
            return;
        };
        let is_self = statuses.contains(&Status::SelfPresence) || room.is_self(&nick);
        let channel = room.name();

        if presence.type_ == PresenceType::Unavailable {
            // A rename is announced as the old nick going away.
            if statuses.contains(&Status::NewNick) {
                if let Some(new) = item.and_then(|i| i.nick.as_deref()).map(clean_name) {
                    room.remove(&nick);
                    room.renaming.insert(new, nick);
                }
                return;
            }
            let reason = item
                .and_then(|i| i.reason.as_ref())
                .map(|r| clean_text(&r.0))
                .filter(|r| !r.is_empty())
                .or_else(|| removal_reason(&statuses));
            room.remove(&nick);
            if is_self {
                self.rooms.remove(jid);
                fx.event(IrcEvent::Parted {
                    channel,
                    nick,
                    is_self: true,
                    reason,
                });
            } else {
                fx.event(IrcEvent::Parted {
                    channel: channel.clone(),
                    nick: nick.clone(),
                    is_self: false,
                    reason,
                });
                fx.event(IrcEvent::MemberChanged {
                    channel,
                    previous: nick,
                    member: None,
                });
            }
            return;
        }

        let occupant = Occupant {
            nick: nick.clone(),
            affiliation: item
                .map(|i| i.affiliation.clone())
                .unwrap_or(Affiliation::None),
            role: item.map(|i| i.role.clone()).unwrap_or(Role::None),
            away: matches!(presence.show, Some(Show::Away | Show::Xa | Show::Dnd)),
        };
        let view = occupant.view();
        let old_nick = room.renaming.remove(&nick);
        let before = room.upsert(occupant.clone());

        if let Some(old) = old_nick {
            if room.is_self(&old) {
                room.nick = nick.clone();
            }
            fx.event(IrcEvent::NickChanged {
                channel: channel.clone(),
                old: old.clone(),
                new: nick.clone(),
                is_self,
            });
            fx.event(IrcEvent::MemberChanged {
                channel,
                previous: old,
                member: Some(view),
            });
            return;
        }

        if !room.joined {
            // The room lists everyone who is already there first and ends with
            // us, so our own presence is the end of the list.
            if is_self {
                room.joined = true;
                room.nick = nick.clone();
                // A room we have shown messages from before, rejoined: whatever
                // was said while we were gone is in its archive.
                let resume_from = room.last_id.clone();
                fx.event(IrcEvent::Joined {
                    channel: channel.clone(),
                    nick,
                    is_self: true,
                });
                fx.event(IrcEvent::MemberList {
                    channel,
                    members: room.members(),
                });
                if let Some(after) = resume_from {
                    self.send_catch_up(jid, after, 0, 0, fx);
                }
            }
            return;
        }

        match before {
            None => {
                fx.event(IrcEvent::Joined {
                    channel: channel.clone(),
                    nick: nick.clone(),
                    is_self,
                });
                fx.event(IrcEvent::MemberChanged {
                    channel,
                    previous: nick,
                    member: Some(view),
                });
            }
            Some(previous) if previous != occupant => {
                fx.event(IrcEvent::MemberChanged {
                    channel,
                    previous: nick,
                    member: Some(view),
                });
            }
            Some(_) => {}
        }
    }

    fn on_room_error(&mut self, jid: &BareJid, presence: &Presence, fx: &mut Effects) {
        let condition = presence
            .payloads
            .iter()
            .find_map(|e| StanzaError::try_from(e.clone()).ok())
            .map(|e| e.defined_condition);
        let Some(room) = self.rooms.get_mut(jid) else {
            return;
        };
        if room.joined {
            return;
        }
        // Nick taken: try another, a few times, as IRC does with alternates.
        if matches!(condition, Some(DefinedCondition::Conflict))
            && room.nick_attempts < MAX_NICK_ATTEMPTS
        {
            room.nick_attempts += 1;
            room.nick = format!("{}_", room.nick);
            let jid = jid.clone();
            self.send_join(&jid, None, fx);
            return;
        }
        let name = room.name();
        self.rooms.remove(jid);
        fx.error(format!(
            "Could not join {name}: {}.",
            condition
                .as_ref()
                .map(describe)
                .unwrap_or_else(|| "the room refused".to_owned())
        ));
        fx.event(IrcEvent::Parted {
            channel: name,
            nick: self.default_nick.clone(),
            is_self: true,
            reason: None,
        });
    }

    fn on_message(&mut self, mut message: Message, fx: &mut Effects) {
        let Some(from) = message.from.clone() else {
            return;
        };
        if let Some(result) = message.extract_valid_payload::<mam::Result_>() {
            self.on_archived(&from, result, fx);
            return;
        }
        match message.type_ {
            MessageType::Groupchat => self.on_groupchat(&from, message, fx),
            MessageType::Error => {
                let who = from.to_bare().to_string();
                let reason = message
                    .extract_valid_payload::<StanzaError>()
                    .map(|e| describe(&e.defined_condition))
                    .unwrap_or_else(|| "it was not delivered".to_owned());
                fx.error(format!("Message to {who} failed: {reason}."));
            }
            MessageType::Chat | MessageType::Normal => self.on_chat(&from, &mut message, fx),
            // Announcements from the server. Nowhere to show them yet.
            MessageType::Headline => {}
        }
    }

    fn on_groupchat(&mut self, from: &Jid, mut message: Message, fx: &mut Effects) {
        let room_jid = from.to_bare();
        let time = message_time(&mut message);
        self.show_room_message(&room_jid, from, message, time, None, fx);
    }

    /// Show a message said in a room, live or replayed from its archive.
    ///
    /// `archived` is the archive's id for it when it was replayed. A replayed
    /// message differs from a live one in three ways: it carries the time it
    /// was said rather than the time it arrived, it never raises a mention (it
    /// is old news, and a notification for each of five hundred would be the
    /// opposite of help), and it does not touch the topic, which would be set
    /// back to whatever it was then.
    fn show_room_message(
        &mut self,
        room_jid: &BareJid,
        from: &Jid,
        mut message: Message,
        time: Option<i64>,
        archived: Option<String>,
        fx: &mut Effects,
    ) {
        let replayed = archived.is_some();
        let Some(room) = self.rooms.get_mut(room_jid) else {
            // From a room we are not in: not ours to show.
            return;
        };
        let channel = room.name();
        let sender = from.resource().map(|r| clean_name(r.as_str()));

        let body = message
            .get_best_body_cloned(vec![""])
            .map(|(_, body)| clean_text(&body));
        let Some(body) = body.filter(|b| !b.trim().is_empty()) else {
            // A subject with no body is the room's topic - unless it is old.
            if replayed {
                return;
            }
            if let Some((_, subject)) = message.get_best_subject_cloned(vec![""]) {
                let topic = truncate(&clean_text(&subject).replace('\n', " "), limits::MAX_TOPIC);
                // Nothing changed, nothing to say. A room with no topic still
                // sends an empty subject when someone joins, and reporting
                // that as the topic being cleared would be an event about
                // something that did not happen; the same goes for a room
                // repeating the topic we already hold. A topic that really is
                // cleared arrives when we hold one, and is reported.
                let held = room.topic.as_deref().unwrap_or("");
                if topic == held {
                    return;
                }
                room.topic = Some(topic.clone());
                let set_by = room.joined.then_some(sender).flatten();
                fx.event(IrcEvent::TopicChanged {
                    channel,
                    topic,
                    set_by,
                });
            }
            return;
        };

        // The id the room itself assigned, the only one that means anything
        // later; anyone can put any id on a stanza they send.
        let room_id = archived.or_else(|| {
            message
                .extract_valid_payload::<StanzaId>()
                .filter(|s| s.by.to_bare() == *room_jid)
                .map(|s| truncate(&s.id, 200))
        });
        if let Some(id) = &room_id {
            // Seen already - live, and again in the archive page - is shown
            // once. And this is now the place to catch up from.
            if !room.remember(id) {
                return;
            }
            room.last_id = Some(id.clone());
        }
        let msgid = room_id.or_else(|| message.id.as_ref().map(|id| truncate(&id.0, 200)));

        let correction = message.extract_valid_payload::<Replace>().is_some();
        let (is_action, text) = split_action(&body);
        let (reply_to, text) = if is_action {
            (None, text)
        } else {
            split_reply(text)
        };
        let text = if correction {
            format!("(edited) {text}")
        } else {
            text.to_owned()
        };

        let (nick, is_self, prefix, is_notice) = match sender {
            Some(nick) => {
                let is_self = room.is_self(&nick);
                let prefix = room
                    .occupant(&nick)
                    .and_then(Occupant::prefix)
                    .map(|p| p.to_string());
                (nick, is_self, prefix, false)
            }
            // From the room itself rather than from anyone in it.
            None => (room_jid.to_string(), false, None, true),
        };
        let is_mention = !replayed && !is_self && mentions(&room.nick, &text);

        fx.event(IrcEvent::Message(Box::new(ChatMessage {
            target: Target::Channel(channel),
            sender: nick,
            sender_prefix: prefix,
            spans: format::parse(&text),
            is_self,
            is_mention,
            is_action,
            is_notice,
            msgid,
            server_time_ms: time,
            reply_to,
        })));
    }

    /// A message the archive sends in answer to a catch-up.
    ///
    /// Believed only if it answers a request we sent and comes from the place
    /// we sent it. Anyone can address a message to us that claims to be an
    /// archived one; without this, anyone could write into a room's history as
    /// we show it.
    fn on_archived(&mut self, from: &Jid, result: mam::Result_, fx: &mut Effects) {
        let Some(query) = result.queryid.as_ref().map(|q| q.0.clone()) else {
            return;
        };
        let room = match self.pending.get_mut(&query) {
            Some(Pending::CatchUp { room, fetched, .. }) if from.resource().is_none() => {
                if from.to_bare() != *room {
                    return;
                }
                *fetched += 1;
                room.clone()
            }
            _ => return,
        };
        let time = result.forwarded.delay.as_ref().map(delay_millis);
        let inner = result.forwarded.message;
        let Some(said_by) = inner.from.clone() else {
            return;
        };
        // Only what was said in the room: its own address is the only one an
        // occupant's is a resource of.
        if said_by.to_bare() != room || inner.type_ != MessageType::Groupchat {
            return;
        }
        let id = truncate(&result.id, MAX_ARCHIVE_ID);
        self.show_room_message(&room, &said_by, inner, time, Some(id), fx);
    }

    /// Ask a room's archive for what came after `after`.
    fn send_catch_up(
        &mut self,
        room: &BareJid,
        after: String,
        fetched: usize,
        pages: usize,
        fx: &mut Effects,
    ) {
        let id = self.next_id();
        self.pending.insert(
            id.clone(),
            Pending::CatchUp {
                room: room.clone(),
                fetched,
                pages: pages + 1,
                after: after.clone(),
                fetched_at_start: fetched,
            },
        );
        let query = mam::Query {
            queryid: Some(mam::QueryId(id.clone())),
            node: None,
            form: None,
            set: Some(SetQuery {
                max: Some(CATCH_UP_PAGE),
                after: Some(after),
                before: None,
                index: None,
            }),
            flip_page: false,
        };
        fx.send(Iq::from_set(id, query).with_to(Jid::from(room.clone())));
    }

    fn on_chat(&mut self, from: &Jid, message: &mut Message, fx: &mut Effects) {
        // A carbon is another device of ours speaking, or one of ours being
        // spoken to. It is believed only from our own account: anyone can
        // otherwise send a "carbon" claiming we said something, or that a
        // stranger's message came from someone we trust.
        if let Some(received) = message.extract_valid_payload::<carbons::Received>() {
            if from.to_bare() == self.account {
                let mut inner = received.forwarded.message;
                let time = received.forwarded.delay.as_ref().map(delay_millis);
                if let Some(other) = inner.from.clone() {
                    self.show_chat(&other, &mut inner, false, time, fx);
                }
            }
            return;
        }
        if let Some(sent) = message.extract_valid_payload::<carbons::Sent>() {
            if from.to_bare() == self.account {
                let mut inner = sent.forwarded.message;
                let time = sent.forwarded.delay.as_ref().map(delay_millis);
                if let Some(other) = inner.to.clone() {
                    self.show_chat(&other, &mut inner, true, time, fx);
                }
            }
            return;
        }
        let time = message_time(message);
        // A message from our own account that is not a carbon is not a thing
        // that happens, and showing it would put words in our own mouth.
        if from.to_bare() == self.account {
            return;
        }
        self.show_chat(from, message, false, time, fx);
    }

    fn show_chat(
        &mut self,
        other: &Jid,
        message: &mut Message,
        outgoing: bool,
        time: Option<i64>,
        fx: &mut Effects,
    ) {
        let Some((_, body)) = message.get_best_body_cloned(vec![""]) else {
            return;
        };
        let body = clean_text(&body);
        if body.trim().is_empty() {
            return;
        }
        let from_room = self.rooms.contains_key(&other.to_bare());
        // A private message from someone in a room is a conversation with that
        // occupant, not with the room, and is filed under their room address.
        let (name, sender) = if from_room {
            let nick = other
                .resource()
                .map(|r| clean_name(r.as_str()))
                .unwrap_or_default();
            (other.to_string(), nick)
        } else {
            let bare = other.to_bare().to_string();
            (bare.clone(), bare)
        };
        let correction = message.extract_valid_payload::<Replace>().is_some();
        let (is_action, text) = split_action(&body);
        let (reply_to, text) = if is_action {
            (None, text)
        } else {
            split_reply(text)
        };
        let text = if correction {
            format!("(edited) {text}")
        } else {
            text.to_owned()
        };
        fx.event(IrcEvent::Message(Box::new(ChatMessage {
            target: Target::Direct(name),
            sender: if outgoing {
                self.account.to_string()
            } else {
                sender
            },
            sender_prefix: None,
            spans: format::parse(&text),
            is_self: outgoing,
            is_mention: false,
            is_action,
            is_notice: false,
            msgid: message.id.as_ref().map(|id| truncate(&id.0, 200)),
            server_time_ms: time,
            reply_to,
        })));
    }
}

const NS_MUC_ADMIN: &str = "http://jabber.org/protocol/muc#admin";

const NS_PING: &str = "urn:xmpp:ping";

/// Escape text for use inside an XML attribute or element written by hand.
fn xml_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\'' => out.push_str("&apos;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

/// What the room says when it removes someone, from the codes it sends.
fn removal_reason(statuses: &[Status]) -> Option<String> {
    statuses.iter().find_map(|s| match s {
        Status::Banned => Some("banned".to_owned()),
        Status::Kicked => Some("removed from the room".to_owned()),
        Status::RemovalFromRoom => Some("removed: their standing changed".to_owned()),
        Status::ConfigMembersOnly => Some("the room became members-only".to_owned()),
        Status::ServiceShutdown => Some("the service is shutting down".to_owned()),
        _ => None,
    })
}

/// An error condition in words a person can act on.
fn describe(condition: &DefinedCondition) -> String {
    match condition {
        DefinedCondition::Conflict => "that nickname is already in use",
        DefinedCondition::Forbidden => "you are not allowed",
        DefinedCondition::NotAuthorized => "a password is required",
        DefinedCondition::RegistrationRequired => "the room is for members only",
        DefinedCondition::ItemNotFound => "there is no such room",
        DefinedCondition::NotAllowed => "that is not allowed",
        DefinedCondition::ServiceUnavailable => "the service is not available",
        DefinedCondition::RemoteServerNotFound => "the server could not be found",
        DefinedCondition::RemoteServerTimeout => "the server did not answer",
        DefinedCondition::ResourceConstraint => "the room is full",
        DefinedCondition::RecipientUnavailable => "the recipient is not available",
        _ => "the server refused",
    }
    .to_owned()
}

/// When a message says it was sent, in milliseconds since the Unix epoch.
fn message_time(message: &mut Message) -> Option<i64> {
    message
        .extract_valid_payload::<Delay>()
        .as_ref()
        .map(delay_millis)
}

fn delay_millis(delay: &Delay) -> i64 {
    delay.stamp.0.timestamp_millis()
}

/// Text from the network made safe to show: control characters removed, except
/// the newline, and bounded.
fn clean_text(text: &str) -> String {
    text.chars()
        .filter(|c| *c == '\n' || *c == '\t' || !c.is_control())
        .take(MAX_BODY_CHARS)
        .collect()
}

/// `/me` at the start of a body is an action (XEP-0245).
fn split_action(body: &str) -> (bool, &str) {
    match body.strip_prefix("/me ") {
        Some(rest) => (true, rest),
        None => (false, body),
    }
}

fn split_reply(text: &str) -> (Option<crate::text::reply::ReplyRef>, &str) {
    match reply::parse_reply(text) {
        Some((found, body)) => (Some(found), body),
        None => (None, text),
    }
}

/// Make text fit for sending, in pieces a server will take.
///
/// Unlike IRC, a newline does not need to split a message: a body is free text.
/// What does need to go is anything XML cannot carry. Control characters other
/// than tab and newline are not legal in an XML document at all, and a stanza
/// holding one is a stream error, which ends the connection.
fn sanitize_outgoing(text: &str) -> Vec<String> {
    let cleaned: String = text
        .replace("\r\n", "\n")
        .chars()
        .filter(|c| *c == '\n' || *c == '\t' || !c.is_control())
        .filter(|c| !matches!(*c, '\u{fffe}' | '\u{ffff}'))
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        return Vec::new();
    }
    cleaned
        .chars()
        .collect::<Vec<_>>()
        .chunks(MAX_BODY_CHARS)
        .map(|chunk| chunk.iter().collect::<String>())
        .collect()
}

#[cfg(test)]
mod tests;
