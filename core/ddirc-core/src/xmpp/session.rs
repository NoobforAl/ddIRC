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
use tokio_xmpp::parsers::data_forms::{DataForm, DataFormType, Field};
use tokio_xmpp::parsers::delay::Delay;
use tokio_xmpp::parsers::disco::{
    DiscoInfoQuery, DiscoInfoResult, DiscoItemsQuery, DiscoItemsResult,
};
use tokio_xmpp::parsers::http_upload::{SlotRequest, SlotResult};
use tokio_xmpp::parsers::iq::Iq;
use tokio_xmpp::parsers::mam;
use tokio_xmpp::parsers::message::{Id, Lang, Message, MessageType};
use tokio_xmpp::parsers::message_correct::Replace;
use tokio_xmpp::parsers::muc::muc::History;
use tokio_xmpp::parsers::muc::user::{Affiliation, MucUser, Role, Status};
use tokio_xmpp::parsers::muc::Muc;
use tokio_xmpp::parsers::ns;
use tokio_xmpp::parsers::oob::Oob;
use tokio_xmpp::parsers::presence::{Presence, Show, Type as PresenceType};
use tokio_xmpp::parsers::roster::{Ask, Item, Roster, Subscription as RosterSubscription};
use tokio_xmpp::parsers::rsm::SetQuery;
use tokio_xmpp::parsers::stanza_error::{DefinedCondition, ErrorType, StanzaError};
use tokio_xmpp::parsers::stanza_id::StanzaId;
use tokio_xmpp::Stanza;

use crate::api::events::IrcEvent;
use crate::api::types::{AuthOutcome, Availability, ChatMessage, Target};
use crate::conn::actor::ClientCommand;
use crate::state::{limits, truncate};
use crate::text::{format, reply};
use crate::xmpp::config::XmppConfig;
use crate::xmpp::contacts::Contacts;
use crate::xmpp::edits::{self, Entry, MessageIndex};
use crate::xmpp::state::{clean_line, clean_name, mentions, Occupant, Room};
use crate::xmpp::upload::{self, Slot, UploadService};

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
    /// Files the server has agreed to take, for the connection to upload. The
    /// session decides *that* and *where*; moving the bytes is not its job.
    pub uploads: Vec<UploadJob>,
}

/// A slot granted, and what to upload to it.
#[derive(Debug)]
pub struct UploadJob {
    /// Names the upload, as the UI was told when it began.
    pub ticket: u64,
    pub slot: Slot,
    pub content_type: &'static str,
}

/// How a file being shared stands.
#[derive(Debug)]
struct Ticket {
    /// The conversation it is for, spelled as the UI knows it.
    target: String,
    filename: String,
    /// Where it can be fetched from, once the server has granted a slot. Its
    /// presence is also how "waiting for a slot" is told from "uploading".
    get: Option<String>,
}

/// How many files may be on their way at once.
const MAX_UPLOADS: usize = 4;

/// How many components of the server are asked what they are.
const MAX_DISCO_ITEMS: usize = 16;

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
    /// What the server has besides itself, to find where files go.
    DiscoItems,
    DiscoInfo {
        jid: Jid,
    },
    /// A request for somewhere to upload a file to.
    Slot {
        ticket: u64,
    },
    /// Adding or removing a contact, kept to say so when the server refuses.
    RosterSet {
        jid: BareJid,
    },
    Kick {
        room: BareJid,
    },
    /// A request to a room's archive for what was said while we were away. The
    /// id of this request is also the `queryid` its results carry, which is how
    /// a result is known to answer it.
    CatchUp {
        /// The room whose archive this asks, or `None` for our own account's:
        /// the one-to-one chats.
        room: Option<BareJid>,
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
    contacts: Contacts,
    index: MessageIndex,
    /// Where files go, once the server has said.
    upload: Option<UploadService>,
    tickets: HashMap<u64, Ticket>,
    next_ticket: u64,
    /// How the user has said they are, and sent again on every login.
    own: Option<(Availability, String)>,
    /// The last id our own account's archive gave a one-to-one message, the
    /// place to catch up from after a dropped connection.
    chat_cursor: Option<String>,
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
            contacts: Contacts::default(),
            index: MessageIndex::default(),
            upload: None,
            tickets: HashMap::new(),
            next_ticket: 0,
            own: None,
            chat_cursor: None,
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

        // A new login starts from nothing about who is where, and from no
        // knowledge of where files go. Whatever was waiting on an answer to a
        // question asked on the last connection will not get one.
        for event in self.contacts.forget_presence() {
            fx.event(event);
        }
        // Whoever is still waiting will ask again: a server delivers the
        // subscriptions it holds when we log in. What it does not deliver was
        // withdrawn while we were away, and would otherwise wait for ever.
        for jid in self.contacts.clear_requests() {
            if !self.contacts.contains(&jid) {
                fx.event(IrcEvent::ContactRemoved {
                    jid: jid.to_string(),
                });
            }
        }
        self.upload = None;
        let waiting: Vec<u64> = self
            .tickets
            .iter()
            .filter(|(_, t)| t.get.is_none())
            .map(|(id, _)| *id)
            .collect();
        for ticket in waiting {
            self.fail_upload(
                ticket,
                "The connection was lost before the upload began.",
                &mut fx,
            );
        }

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

        // What the server asked of a new session: what else it offers, so that
        // somewhere to put a file can be found.
        let id = self.next_id();
        self.pending.insert(id.clone(), Pending::DiscoItems);
        fx.send(
            Iq::from_get(
                id,
                DiscoItemsQuery {
                    node: None,
                    rsm: None,
                },
            )
            .with_to(self.server()),
        );

        // Plain presence unless the user has said otherwise: no capabilities
        // hash, no client name. A server needs to be told we are here and
        // nothing else; a status is a thing the user wrote and chose to send.
        fx.send(self.own_presence());

        // What was said to us while we were away, if there is a place to start
        // from. A first login has none; the app supplies one then.
        if let Some(cursor) = self.chat_cursor.clone() {
            self.send_catch_up(None, CatchUpFrom::After(cursor), 0, 0, &mut fx);
        }

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
            ClientCommand::AddContact { jid, name } => {
                self.add_contact(&jid, name.as_deref(), &mut fx);
            }
            ClientCommand::RemoveContact { jid } => self.remove_contact(&jid, &mut fx),
            ClientCommand::AnswerSubscription { jid, accept } => {
                self.answer_subscription(&jid, accept, &mut fx);
            }
            ClientCommand::SetAvailability {
                availability,
                status,
            } => self.set_availability(availability, status.as_deref(), &mut fx),
            ClientCommand::CatchUpChats { since_ms } => {
                // Only when this connection has nothing better to go on: its own
                // cursor knows exactly where it left off, a clock does not.
                if self.chat_cursor.is_none() {
                    self.send_catch_up(None, CatchUpFrom::Since(since_ms), 0, 0, &mut fx);
                }
            }
            ClientCommand::EditMessage {
                target,
                msgid,
                text,
            } => self.edit(&target, &msgid, &text, &mut fx),
            ClientCommand::RetractMessage { target, msgid } => {
                self.retract(&target, &msgid, &mut fx);
            }
            ClientCommand::ListChannels
            | ClientCommand::Whois { .. }
            // Sending a file starts on the connection, which reads the file;
            // it reaches the session only by `begin_upload`.
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
        self.say_with(target, text, action, None, fx);
    }

    /// [`say`](Self::say), optionally naming the address a message is about
    /// (XEP-0066), which is how a shared file is told from a link.
    fn say_with(
        &mut self,
        target: &str,
        text: &str,
        action: bool,
        oob: Option<&str>,
        fx: &mut Effects,
    ) {
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
            let message = if in_room {
                Message::groupchat(Some(Jid::from(room.clone())))
            } else {
                Message::chat(Some(to.clone()))
            };
            // The id goes in both places a receiver may look, so that a later
            // correction or retraction can name this message.
            let id = self.next_id();
            let mut message = edits::with_origin_id(message, &id);
            message.bodies.insert(Lang::new(), body);
            if let Some(url) = oob {
                message = message.with_payload(Oob {
                    url: url.to_owned(),
                    desc: None,
                });
            }
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
                    msgid: Some(id.clone()),
                    server_time_ms: None,
                    reply_to,
                })));
                self.index.record(Entry {
                    conversation: conversation.clone(),
                    author: self.account.to_string(),
                    msgid: id.clone(),
                    origin: Some(id),
                    mine: true,
                });
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
            Iq::Set {
                from, id, payload, ..
            } if payload.is("query", NS_ROSTER) => self.on_roster_push(from, id, payload, fx),
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
                match self.pending.remove(&id) {
                    Some(Pending::CatchUp {
                        room,
                        fetched,
                        pages,
                        after,
                        fetched_at_start,
                    }) => {
                        // The end of a page. Another only if the archive says
                        // there is one *and* every limit we hold agrees. The
                        // archive's word is the least of them: it is the one
                        // party that could say "more" for ever.
                        let fin = payload.and_then(|p| mam::Fin::try_from(p).ok());
                        let more =
                            fin.filter(|f| !f.complete)
                                .and_then(|f| f.set.last)
                                .filter(|last| {
                                    // Nothing came in this page, or the cursor has
                                    // not moved: the archive is not getting anywhere.
                                    fetched > fetched_at_start
                                        && *last != after
                                        && fetched < CATCH_UP_TOTAL
                                        && pages < CATCH_UP_PAGES
                                });
                        if let Some(last) = more {
                            self.send_catch_up(room, CatchUpFrom::After(last), fetched, pages, fx);
                        }
                    }
                    Some(Pending::Roster) => {
                        if let Some(roster) = payload.and_then(|p| Roster::try_from(p).ok()) {
                            for event in
                                self.contacts
                                    .apply_roster(roster.items, &self.account, true)
                            {
                                fx.event(event);
                            }
                        }
                    }
                    Some(Pending::DiscoItems) => {
                        let items = payload.and_then(|p| DiscoItemsResult::try_from(p).ok());
                        for item in items
                            .into_iter()
                            .flat_map(|i| i.items)
                            .take(MAX_DISCO_ITEMS)
                        {
                            // A component, not a node of one: where files go is
                            // a service of its own.
                            if item.node.is_some() {
                                continue;
                            }
                            let id = self.next_id();
                            self.pending.insert(
                                id.clone(),
                                Pending::DiscoInfo {
                                    jid: item.jid.clone(),
                                },
                            );
                            fx.send(
                                Iq::from_get(id, DiscoInfoQuery { node: None }).with_to(item.jid),
                            );
                        }
                    }
                    Some(Pending::DiscoInfo { jid }) => {
                        let info = payload.and_then(|p| DiscoInfoResult::try_from(p).ok());
                        if self.upload.is_none() {
                            if let Some(service) =
                                info.and_then(|i| upload::service_from_info(&jid, &i))
                            {
                                fx.event(IrcEvent::UploadAvailable {
                                    max_bytes: Some(upload::limit(&service)),
                                });
                                self.upload = Some(service);
                            }
                        }
                    }
                    Some(Pending::Slot { ticket }) => self.on_slot(ticket, payload, fx),
                    Some(Pending::Carbons | Pending::Kick { .. } | Pending::RosterSet { .. })
                    | None => {}
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
                    Some(Pending::RosterSet { jid }) => fx.error(format!(
                        "Could not change {jid} on your contact list: {}.",
                        describe(&error.defined_condition)
                    )),
                    Some(Pending::Slot { ticket }) => {
                        let why = format!(
                            "The server would not take the file: {}.",
                            describe(&error.defined_condition)
                        );
                        self.fail_upload(ticket, &why, fx);
                    }
                    // Carbons, the roster, an archive and what else the server
                    // has are conveniences. A server that lacks them is still a
                    // server worth using.
                    Some(
                        Pending::Carbons
                        | Pending::Roster
                        | Pending::CatchUp { .. }
                        | Pending::DiscoItems
                        | Pending::DiscoInfo { .. },
                    )
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
            return matches!(
                pending,
                Pending::Roster
                    | Pending::Carbons
                    | Pending::DiscoItems
                    | Pending::RosterSet { .. }
                    | Pending::CatchUp { room: None, .. }
            );
        };
        let bare = from.to_bare();
        match pending {
            // A room's answer is from the room itself - its address and no
            // resource. A resource is an *occupant*, anyone who joined, and
            // would otherwise be able to answer for the room by guessing an id.
            Pending::Kick { room }
            | Pending::CatchUp {
                room: Some(room), ..
            } => from.resource().is_none() && &bare == room,
            // Our own archive answers as our own account.
            Pending::CatchUp { room: None, .. } => {
                from.resource().is_none() && bare == self.account
            }
            Pending::Roster | Pending::Carbons | Pending::RosterSet { .. } => {
                bare == self.account
                    || bare.domain() == self.account.domain() && bare.node().is_none()
            }
            // The server, and not a person or a room: the question went to its
            // own address, which has no part before the `@` and no resource.
            Pending::DiscoItems => {
                from.resource().is_none()
                    && bare.node().is_none()
                    && bare.domain() == self.account.domain()
            }
            // A component answers for itself, at the address it was asked at.
            Pending::DiscoInfo { jid } => from == jid,
            Pending::Slot { .. } => self
                .upload
                .as_ref()
                .is_some_and(|service| from == &service.jid),
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
        match presence.type_ {
            PresenceType::Subscribe => {
                // Someone asks to see when we are online. Never answered on our
                // behalf: accepting tells them we exist and are reading, which
                // is the user's to give. Reported, and the user answers it.
                //
                // From a person only: an address with no name before the `@` is
                // a server or a service, which can be neither accepted nor
                // declined here and would sit in the list for ever.
                if bare != self.account
                    && bare.node().is_some()
                    && self.contacts.add_request(bare.clone())
                {
                    fx.event(IrcEvent::SubscriptionRequest {
                        jid: bare.to_string(),
                    });
                }
            }
            // They changed their mind. Accepting now would pre-approve someone
            // who withdrew, so the request goes, and the UI is told by the one
            // event it already clears a waiting request on.
            PresenceType::Unsubscribe => {
                if self.contacts.take_request(&bare) && !self.contacts.contains(&bare) {
                    fx.event(IrcEvent::ContactRemoved {
                        jid: bare.to_string(),
                    });
                }
            }
            // Whether a contact is here. Only believed of someone on the list.
            PresenceType::None | PresenceType::Unavailable => {
                if let Some(event) = self.contacts.apply_presence(&from, &presence) {
                    fx.event(event);
                }
            }
            // The rest - that they agreed, or stopped - is carried by the
            // roster update the server sends with it.
            _ => {}
        }
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
            // A nickname is free the moment its holder goes, so what they said
            // is no longer anyone's to change but a message they can no longer
            // send - and ours, all of it, when we leave.
            if is_self {
                self.index.forget_conversation(&channel);
            } else {
                self.index.forget_author(&channel, &nick);
            }
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
            self.index.rename_author(&channel, &old, &nick);
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
                    self.send_catch_up(Some(jid.clone()), CatchUpFrom::After(after), 0, 0, fx);
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
        let origin = edits::origin_id(&mut message);

        // A retraction is never shown as a message. It is applied if it comes
        // from whoever wrote what it names, and otherwise it is nothing.
        if let Some(target_id) = edits::retraction(&message) {
            if let Some(author) = &sender {
                if let Some(entry) = self
                    .index
                    .for_retraction(&channel, &target_id, author)
                    .cloned()
                {
                    self.index.forget(&channel, &entry.msgid);
                    fx.event(IrcEvent::MessageRetracted {
                        target: Target::Channel(channel),
                        msgid: entry.msgid,
                        sender: author.clone(),
                    });
                }
            }
            return;
        }

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

        let msgid = room_id.or_else(|| origin.clone());

        let correction = message.extract_valid_payload::<Replace>();
        let (is_action, text) = split_action(&body);
        let (reply_to, text) = if is_action {
            (None, text)
        } else {
            split_reply(text)
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

        // A correction from the author of what it names replaces that message
        // in place. From anyone else, or naming something we never showed, it
        // is only a message, and says it is a correction.
        if let (Some(replace), false) = (&correction, is_notice) {
            if let Some(entry) = self
                .index
                .for_correction(&channel, &replace.id.0, &nick)
                .cloned()
            {
                let edited = ChatMessage {
                    target: Target::Channel(channel.clone()),
                    sender: nick.clone(),
                    sender_prefix: prefix,
                    spans: format::parse(text),
                    is_self,
                    is_mention: false,
                    is_action,
                    is_notice,
                    msgid: Some(entry.msgid.clone()),
                    server_time_ms: time,
                    reply_to,
                };
                fx.event(IrcEvent::MessageEdited {
                    target: Target::Channel(channel),
                    msgid: entry.msgid,
                    sender: nick,
                    message: Box::new(edited),
                });
                return;
            }
        }
        let text = if correction.is_some() {
            format!("(edited) {text}")
        } else {
            text.to_owned()
        };
        let is_mention = !replayed && !is_self && mentions(&room.nick, &text);

        if let (false, Some(id)) = (is_notice, &msgid) {
            self.index.record(Entry {
                conversation: channel.clone(),
                author: nick.clone(),
                msgid: id.clone(),
                origin,
                mine: is_self,
            });
        }
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
                // From the place it was asked of: the room, or our own account.
                let expected = room.clone().unwrap_or_else(|| self.account.clone());
                if from.to_bare() != expected {
                    return;
                }
                *fetched += 1;
                room.clone()
            }
            _ => return,
        };
        let time = result.forwarded.delay.as_ref().map(delay_millis);
        let inner = result.forwarded.message;
        let Some(room) = room else {
            self.on_archived_chat(inner, truncate(&result.id, MAX_ARCHIVE_ID), time, fx);
            return;
        };
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

    /// One message from our own account's archive: something said to us, or by
    /// us from another device, while this connection was not there.
    fn on_archived_chat(
        &mut self,
        mut inner: Message,
        id: String,
        time: Option<i64>,
        fx: &mut Effects,
    ) {
        // The place to carry on from, whatever becomes of the message.
        self.chat_cursor = Some(id);
        if inner.type_ != MessageType::Chat && inner.type_ != MessageType::Normal {
            return;
        }
        let (Some(from), Some(to)) = (inner.from.clone(), inner.to.clone()) else {
            return;
        };
        // Said by us, from another place, or said to us.
        let outgoing = from.to_bare() == self.account;
        let other = if outgoing { to } else { from };
        if other.to_bare() == self.account {
            return;
        }
        self.show_chat(&other, &mut inner, outgoing, time, true, fx);
    }

    /// Ask an archive for what came after a point: a room's, or - with no room -
    /// our own account's, which holds the one-to-one chats.
    fn send_catch_up(
        &mut self,
        room: Option<BareJid>,
        from: CatchUpFrom,
        fetched: usize,
        pages: usize,
        fx: &mut Effects,
    ) {
        let id = self.next_id();
        let (after, since) = match from {
            CatchUpFrom::After(after) => (Some(after), None),
            CatchUpFrom::Since(ms) => (None, Some(ms)),
        };
        self.pending.insert(
            id.clone(),
            Pending::CatchUp {
                room: room.clone(),
                fetched,
                pages: pages + 1,
                // Nothing to have failed to move past when starting from a time.
                after: after.clone().unwrap_or_default(),
                fetched_at_start: fetched,
            },
        );
        let form = since.map(|ms| {
            DataForm::new(
                DataFormType::Submit,
                ns::MAM,
                vec![Field::text_single("start", &iso8601(ms))],
            )
        });
        let query = mam::Query {
            queryid: Some(mam::QueryId(id.clone())),
            node: None,
            form,
            set: Some(SetQuery {
                max: Some(CATCH_UP_PAGE),
                after,
                before: None,
                index: None,
            }),
            flip_page: false,
        };
        let iq = Iq::from_set(id, query);
        fx.send(match room {
            Some(room) => iq.with_to(Jid::from(room)),
            None => iq,
        });
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
                    self.show_chat(&other, &mut inner, false, time, false, fx);
                }
            }
            return;
        }
        if let Some(sent) = message.extract_valid_payload::<carbons::Sent>() {
            if from.to_bare() == self.account {
                let mut inner = sent.forwarded.message;
                let time = sent.forwarded.delay.as_ref().map(delay_millis);
                if let Some(other) = inner.to.clone() {
                    self.show_chat(&other, &mut inner, true, time, false, fx);
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
        // Where our archive will have got to, so that a dropped connection can
        // ask for what came after.
        if let Some(stanza_id) = message.extract_valid_payload::<StanzaId>() {
            if stanza_id.by.to_bare() == self.account {
                self.chat_cursor = Some(truncate(&stanza_id.id, MAX_ARCHIVE_ID));
            }
        }
        self.show_chat(from, message, false, time, false, fx);
    }

    fn show_chat(
        &mut self,
        other: &Jid,
        message: &mut Message,
        outgoing: bool,
        time: Option<i64>,
        replayed: bool,
        fx: &mut Effects,
    ) {
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
        let author = if outgoing {
            self.account.to_string()
        } else {
            sender
        };
        // Who is *recorded* as having said it, which is not always what is shown.
        // In a room's private chat the shown name is a nickname, and a nickname
        // can be anything - including our own address - so it is filed under the
        // occupant's full address instead, which has a `/` in it that no account
        // address has. Without this, someone in a room calling themselves our
        // address could change the private messages we sent them.
        let key = if outgoing {
            self.account.to_string()
        } else if from_room {
            other.to_string()
        } else {
            author.clone()
        };
        let origin = edits::origin_id(message);

        // Said before, live, and now again from the archive: shown once.
        if replayed {
            if let Some(id) = message.id.as_ref().map(|id| truncate(&id.0, 200)) {
                if self.index.contains(&name, &id) {
                    return;
                }
            }
        }

        // A retraction is never shown as a message, and is applied only if it
        // comes from whoever wrote what it names.
        if let Some(target_id) = edits::retraction(message) {
            if let Some(entry) = self.index.for_retraction(&name, &target_id, &key).cloned() {
                self.index.forget(&name, &entry.msgid);
                fx.event(IrcEvent::MessageRetracted {
                    target: Target::Direct(name),
                    msgid: entry.msgid,
                    sender: author,
                });
            }
            return;
        }

        let Some((_, body)) = message.get_best_body_cloned(vec![""]) else {
            return;
        };
        let body = clean_text(&body);
        if body.trim().is_empty() {
            return;
        }
        let correction = message.extract_valid_payload::<Replace>();
        let (is_action, text) = split_action(&body);
        let (reply_to, text) = if is_action {
            (None, text)
        } else {
            split_reply(text)
        };
        let msgid = message.id.as_ref().map(|id| truncate(&id.0, 200));

        // As in a room: a correction by the author replaces the message, and
        // anything else is a message that says it was a correction.
        if let Some(replace) = &correction {
            if let Some(entry) = self
                .index
                .for_correction(&name, &replace.id.0, &key)
                .cloned()
            {
                let edited = ChatMessage {
                    target: Target::Direct(name.clone()),
                    sender: author.clone(),
                    sender_prefix: None,
                    spans: format::parse(text),
                    is_self: outgoing,
                    is_mention: false,
                    is_action,
                    is_notice: false,
                    msgid: Some(entry.msgid.clone()),
                    server_time_ms: time,
                    reply_to,
                };
                fx.event(IrcEvent::MessageEdited {
                    target: Target::Direct(name),
                    msgid: entry.msgid,
                    sender: author,
                    message: Box::new(edited),
                });
                return;
            }
        }
        let text = if correction.is_some() {
            format!("(edited) {text}")
        } else {
            text.to_owned()
        };
        if let Some(id) = &msgid {
            self.index.record(Entry {
                conversation: name.clone(),
                author: key,
                msgid: id.clone(),
                origin,
                mine: outgoing,
            });
        }
        fx.event(IrcEvent::Message(Box::new(ChatMessage {
            target: Target::Direct(name),
            sender: author,
            sender_prefix: None,
            spans: format::parse(&text),
            is_self: outgoing,
            is_mention: false,
            is_action,
            is_notice: false,
            msgid,
            server_time_ms: time,
            reply_to,
        })));
    }
}

/// Where an archive request starts from.
#[derive(Debug)]
enum CatchUpFrom {
    /// Everything after an id the archive gave.
    After(String),
    /// Everything since a time, in Unix milliseconds.
    Since(i64),
}

/// A Unix time in milliseconds as XEP-0082 text, in UTC.
///
/// By hand, because the one thing needed is a date a server will parse and
/// the alternative is a date library for a single format string. The civil-date
/// arithmetic is Howard Hinnant's `civil_from_days`.
fn iso8601(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let of_day = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        of_day / 3600,
        of_day % 3600 / 60,
        of_day % 60
    )
}

const NS_MUC_ADMIN: &str = "http://jabber.org/protocol/muc#admin";

const NS_ROSTER: &str = "jabber:iq:roster";

/// The longest status text sent, in characters.
const STATUS_CHARS: usize = 200;

const NS_PING: &str = "urn:xmpp:ping";

/// Escape text for use inside an XML attribute or element written by hand.
pub(crate) fn xml_escape(text: &str) -> String {
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

mod features;

#[cfg(test)]
mod tests;
