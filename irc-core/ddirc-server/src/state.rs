//! Everything the server knows, and every reply it makes.
//!
//! One owner, no locks. Each connection has a reader task that turns bytes into
//! [`Message`]s and a writer task that turns [`Message`]s back into bytes; in
//! between, every event in the whole server is handled here, one at a time, by
//! a single task holding the only copy of this struct.
//!
//! That arrangement is worth the small awkwardness of the channel plumbing. A
//! server is almost entirely cross-client operations — a JOIN touches everyone
//! already in the channel, a nick change touches everyone who shares one — and
//! doing that under per-client locks is how deadlocks and half-applied state
//! get in. Here there is no interleaving to reason about: a message is handled
//! completely, or it has not started.
//!
//! It also makes the protocol testable without a socket. The tests at the
//! bottom drive this struct directly and read what came back out of the
//! per-client queues, so the behaviour is checked without TLS, ports, or
//! timing anywhere near it.

use std::collections::{HashMap, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

use irc_proto::{CapSubCommand, Command, Message, Prefix, Response};
use tokio::sync::mpsc::UnboundedSender;

/// Identifies one connection, for as long as it lasts.
pub type ClientId = u64;

/// What the server calls itself when it has no better name.
pub const DEFAULT_SERVER_NAME: &str = "ddirc.local";
/// What it calls the network.
pub const DEFAULT_NETWORK_NAME: &str = "Local";

/// The host part of every prefix.
///
/// Always literally true here, and deliberately so: this server only ever
/// accepts loopback connections, so there is no other host a client could be
/// on, and nothing is revealed by saying it.
const HOST: &str = "localhost";

/// Limits, advertised in `ISUPPORT` so the client can hold itself to them
/// rather than discovering them by being cut off.
const NICK_LEN: usize = 30;
const CHANNEL_LEN: usize = 50;
const TOPIC_LEN: usize = 390;

/// One connected client.
struct Client {
    tx: UnboundedSender<Message>,
    nick: Option<String>,
    user: Option<String>,
    real: Option<String>,
    registered: bool,
    /// Set by `CAP LS`. Registration then waits for `CAP END` rather than
    /// completing the moment NICK and USER have both arrived — otherwise a
    /// client that is still negotiating gets a welcome mid-conversation.
    negotiating: bool,
    /// What they said on the way out, kept until the socket actually closes.
    ///
    /// A `QUIT` is a statement, not a disconnection: the connection ends a
    /// moment later when the client hangs up, and it is the session task
    /// watching the socket that reports that. Without somewhere to put the
    /// reason in between, everyone in the channel is told "Connection closed"
    /// however deliberately the person left.
    quit_reason: Option<String>,
    /// Normalised names of the channels this client is in, so a disconnect does
    /// not have to search every channel on the server.
    channels: HashSet<String>,
}

impl Client {
    fn nick(&self) -> &str {
        self.nick.as_deref().unwrap_or("*")
    }

    /// The `nick!user@host` this client's own messages are attributed to.
    fn prefix(&self) -> Prefix {
        Prefix::Nickname(
            self.nick().to_owned(),
            self.user.clone().unwrap_or_else(|| self.nick().to_owned()),
            HOST.to_owned(),
        )
    }
}

struct Topic {
    text: String,
    set_by: String,
    at: u64,
}

struct Channel {
    /// As it was first typed. Lookups are normalised, but what is shown back
    /// should be what someone wrote.
    name: String,
    topic: Option<Topic>,
    members: HashSet<ClientId>,
    /// Whoever created the channel. Real servers do this, and it is what makes
    /// the `PREFIX=(o)@` this server advertises mean something.
    operators: HashSet<ClientId>,
}

/// The whole server.
pub struct Network {
    server_name: String,
    network_name: String,
    version: String,
    clients: HashMap<ClientId, Client>,
    /// Normalised nick to the client holding it. Kept beside `clients` so
    /// "is this nick taken" is a lookup rather than a scan, and so the two
    /// cannot disagree — every write goes through [`Self::claim_nick`].
    nicks: HashMap<String, ClientId>,
    channels: HashMap<String, Channel>,
}

/// Fold case the way `CASEMAPPING=ascii` says to.
///
/// Plain ASCII rather than RFC 1459's, which also folds `[]\` onto `{}|`. The
/// client understands both — see `state/isupport.rs` — so this is a free
/// choice, and the surprising one is the one where `[a]` and `{a}` are the same
/// channel.
fn fold(name: &str) -> String {
    name.to_ascii_lowercase()
}

/// Cut a string down to `max` bytes, on a character boundary.
///
/// `String::truncate` is the obvious call and is the wrong one: it **panics**
/// when the index falls inside a multi-byte character. Everything bounded here
/// arrived on the wire, so a topic or a quit message with an `é` straddling
/// the limit would panic the one task that owns all the server's state — and
/// that task dying leaves a listener still accepting connections that will
/// never be answered.
fn truncate(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut end = max;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Whether `name` is a channel rather than a nick.
fn is_channel(name: &str) -> bool {
    name.starts_with('#')
}

/// Nicks that would break the protocol if they were allowed through.
///
/// Refused here rather than sanitised, because a client that asked for a name
/// and silently got a different one has no way to know which one it has.
fn valid_nick(nick: &str) -> bool {
    !nick.is_empty()
        && nick.len() <= NICK_LEN
        && !nick.starts_with('#')
        && !nick.starts_with(':')
        && !nick.contains(' ')
        && !nick.contains(',')
        && !nick.contains('!')
        && !nick.contains('@')
        && nick.chars().all(|c| !c.is_control())
}

fn valid_channel(name: &str) -> bool {
    is_channel(name)
        && name.len() <= CHANNEL_LEN
        && name.len() > 1
        && !name.contains(' ')
        && !name.contains(',')
        && name.chars().all(|c| !c.is_control())
}

impl Network {
    pub fn new(server_name: impl Into<String>, network_name: impl Into<String>) -> Self {
        Self {
            server_name: server_name.into(),
            network_name: network_name.into(),
            version: format!("ddirc-server-{}", env!("CARGO_PKG_VERSION")),
            clients: HashMap::new(),
            nicks: HashMap::new(),
            channels: HashMap::new(),
        }
    }

    /// How many clients are connected, registered or not.
    pub fn client_count(&self) -> usize {
        self.clients.len()
    }

    /// A connection has been accepted. Nothing is known about it yet.
    pub fn connect(&mut self, id: ClientId, tx: UnboundedSender<Message>) {
        self.clients.insert(
            id,
            Client {
                tx,
                nick: None,
                user: None,
                real: None,
                registered: false,
                negotiating: false,
                quit_reason: None,
                channels: HashSet::new(),
            },
        );
    }

    /// A connection has gone, for any reason — QUIT, a dropped socket, or the
    /// server shutting down. Everyone who shared a channel is told once.
    ///
    /// `reason` is what the session task saw happen to the socket, which is a
    /// worse answer than what the client *said* if it said anything. Someone
    /// who typed `/quit heading out` should not appear to have dropped off.
    pub fn disconnect(&mut self, id: ClientId, reason: &str) {
        let Some(client) = self.clients.remove(&id) else {
            return;
        };
        if let Some(nick) = &client.nick {
            self.nicks.remove(&fold(nick));
        }

        let said = client.quit_reason.clone();
        let quit = Message {
            tags: None,
            prefix: Some(client.prefix()),
            command: Command::QUIT(Some(said.unwrap_or_else(|| reason.to_owned()))),
        };

        // Once, not once per shared channel: someone who shares three channels
        // with the departing client should see one QUIT, which is also what
        // every other server does.
        let mut told: HashSet<ClientId> = HashSet::new();
        for name in &client.channels {
            let Some(channel) = self.channels.get_mut(name) else {
                continue;
            };
            channel.members.remove(&id);
            channel.operators.remove(&id);
            for &member in &channel.members {
                if told.insert(member) {
                    if let Some(c) = self.clients.get(&member) {
                        let _ = c.tx.send(quit.clone());
                    }
                }
            }
        }
        self.channels.retain(|_, c| !c.members.is_empty());
    }

    /// Handle one message from one client.
    pub fn handle(&mut self, id: ClientId, message: Message) {
        if !self.clients.contains_key(&id) {
            return;
        }

        match message.command {
            Command::CAP(_, sub, arg, suffix) => self.on_cap(id, sub, arg.or(suffix)),
            Command::NICK(nick) => self.on_nick(id, &nick),
            Command::USER(user, _, real) => self.on_user(id, user, real),
            // Accepted and ignored. This server has no password; refusing the
            // command outright would fail a client that sends one harmlessly.
            Command::PASS(_) => {}
            Command::PING(token, _) => self.on_ping(id, token),
            Command::PONG(..) => {}
            Command::QUIT(reason) => {
                // The session task sees the socket close and calls `disconnect`
                // itself, so the connection is not ended here — only what to
                // say about it is recorded. Bounded like a topic, because it is
                // a string from the wire that is about to be sent to everyone
                // else on the server.
                if let Some(client) = self.clients.get_mut(&id) {
                    client.quit_reason =
                        Some(reason.map_or_else(|| "Quit".to_owned(), |r| truncate(&r, TOPIC_LEN)));
                }
            }
            command => {
                if !self.is_registered(id) {
                    self.numeric(
                        id,
                        Response::ERR_NOTREGISTERED,
                        &["You have not registered"],
                    );
                    return;
                }
                self.registered_command(id, command);
            }
        }
    }

    fn registered_command(&mut self, id: ClientId, command: Command) {
        match command {
            Command::JOIN(targets, _, _) => {
                for target in targets.split(',') {
                    self.on_join(id, target.trim());
                }
            }
            Command::PART(targets, reason) => {
                for target in targets.split(',') {
                    self.on_part(id, target.trim(), reason.as_deref());
                }
            }
            Command::PRIVMSG(target, text) => self.on_message(id, &target, &text, false),
            Command::NOTICE(target, text) => self.on_message(id, &target, &text, true),
            Command::TOPIC(channel, topic) => self.on_topic(id, &channel, topic),
            Command::NAMES(Some(channels), _) => {
                for name in channels.split(',') {
                    self.send_names(id, name.trim());
                }
            }
            Command::MOTD(_) => self.send_motd(id),
            // Answered rather than left to time out. No modes are settable on
            // this server, so a query is the only form that can be honoured,
            // and 324 with an empty mode string is the true answer.
            Command::ChannelMODE(channel, modes) if modes.is_empty() => {
                let nick = self.nick_of(id);
                self.raw(id, "324", &[&nick, &channel, "+"]);
            }
            Command::UserMODE(..) | Command::ChannelMODE(..) => {}
            other => {
                let name = String::from(&other);
                let verb = name.split(' ').next().unwrap_or("").to_owned();
                self.numeric_args(
                    id,
                    Response::ERR_UNKNOWNCOMMAND,
                    &[&verb, "Unknown command"],
                );
            }
        }
    }

    // ------------------------------------------------------------ registration

    fn on_cap(&mut self, id: ClientId, sub: CapSubCommand, _arg: Option<String>) {
        match sub {
            CapSubCommand::LS | CapSubCommand::LIST => {
                if let Some(client) = self.clients.get_mut(&id) {
                    client.negotiating = true;
                }
                let nick = self.nick_of(id);
                // An empty list, said out loud. This server implements no
                // IRCv3 capabilities; advertising one it does not have is how
                // a client ends up waiting for a reply that never comes.
                self.raw(id, "CAP", &[&nick, "LS", ""]);
            }
            CapSubCommand::REQ => {
                let nick = self.nick_of(id);
                // Nothing was offered, so nothing can be granted. NAK rather
                // than silence, so a client waiting on an answer gets one.
                self.raw(id, "CAP", &[&nick, "NAK", ""]);
            }
            CapSubCommand::END => {
                if let Some(client) = self.clients.get_mut(&id) {
                    client.negotiating = false;
                }
                self.try_register(id);
            }
            _ => {}
        }
    }

    fn on_nick(&mut self, id: ClientId, nick: &str) {
        let nick = nick.trim();
        if nick.is_empty() {
            self.numeric(id, Response::ERR_NONICKNAMEGIVEN, &["No nickname given"]);
            return;
        }
        if !valid_nick(nick) {
            self.numeric_args(
                id,
                Response::ERR_ERRONEOUSNICKNAME,
                &[nick, "Erroneous nickname"],
            );
            return;
        }
        let key = fold(nick);
        if let Some(&holder) = self.nicks.get(&key) {
            if holder != id {
                self.numeric_args(
                    id,
                    Response::ERR_NICKNAMEINUSE,
                    &[nick, "Nickname is already in use"],
                );
                return;
            }
        }

        let was = self.clients.get(&id).and_then(|c| c.nick.clone());
        let registered = self.is_registered(id);
        self.claim_nick(id, nick);

        match (registered, was) {
            // A rename mid-session. Everyone who can see this client has to be
            // told, or their member lists silently go stale.
            (true, Some(old)) if old != nick => {
                let change = Message {
                    tags: None,
                    prefix: Some(Prefix::Nickname(
                        old,
                        self.clients
                            .get(&id)
                            .and_then(|c| c.user.clone())
                            .unwrap_or_else(|| nick.to_owned()),
                        HOST.to_owned(),
                    )),
                    command: Command::NICK(nick.to_owned()),
                };
                self.tell_peers(id, change, true);
            }
            (false, _) => self.try_register(id),
            _ => {}
        }
    }

    fn on_user(&mut self, id: ClientId, user: String, real: String) {
        if self.is_registered(id) {
            self.numeric(
                id,
                Response::ERR_ALREADYREGISTRED,
                &["You may not reregister"],
            );
            return;
        }
        if let Some(client) = self.clients.get_mut(&id) {
            client.user = Some(user);
            client.real = Some(real);
        }
        self.try_register(id);
    }

    fn try_register(&mut self, id: ClientId) {
        let ready = self.clients.get(&id).is_some_and(|c| {
            !c.registered && !c.negotiating && c.nick.is_some() && c.user.is_some()
        });
        if !ready {
            return;
        }
        if let Some(client) = self.clients.get_mut(&id) {
            client.registered = true;
        }
        self.send_welcome(id);
    }

    fn send_welcome(&mut self, id: ClientId) {
        let nick = self.nick_of(id);
        let (server, network, version) = (
            self.server_name.clone(),
            self.network_name.clone(),
            self.version.clone(),
        );

        self.numeric(
            id,
            Response::RPL_WELCOME,
            &[&format!("Welcome to the {network} Network, {nick}")],
        );
        self.numeric(
            id,
            Response::RPL_YOURHOST,
            &[&format!("Your host is {server}, running version {version}")],
        );
        self.numeric(
            id,
            Response::RPL_CREATED,
            &["This server was created when you started it"],
        );
        // 004 takes bare parameters rather than a sentence: server, version,
        // the user modes it supports, then the channel modes. Both are empty
        // here, and saying so is more use than omitting the line.
        self.numeric_args(id, Response::RPL_MYINFO, &[&server, &version, "", ""]);

        // Everything the client's `state/isupport.rs` can act on, and nothing
        // it would have to guess at. NETWORK is what the rail labels the
        // connection; PREFIX is what makes the `@` in NAMES mean something.
        let tokens = format!(
            "NETWORK={network} CASEMAPPING=ascii CHANTYPES=# PREFIX=(o)@ CHANMODES=,,, \
             NICKLEN={NICK_LEN} CHANNELLEN={CHANNEL_LEN} TOPICLEN={TOPIC_LEN}"
        );
        let mut args: Vec<&str> = vec![&nick];
        args.extend(tokens.split(' ').filter(|t| !t.is_empty()));
        args.push("are supported by this server");
        self.send(
            id,
            Message {
                tags: None,
                prefix: Some(Prefix::ServerName(server)),
                command: Command::Response(
                    Response::RPL_ISUPPORT,
                    args.iter().map(|s| (*s).to_owned()).collect(),
                ),
            },
        );

        self.send_motd(id);
    }

    fn send_motd(&mut self, id: ClientId) {
        let server = self.server_name.clone();
        self.numeric(
            id,
            Response::RPL_MOTDSTART,
            &[&format!("- {server} Message of the Day -")],
        );
        // The beta label belongs here as well as in the settings switch that
        // turned this on. A MOTD is the one thing every client shows on
        // arrival, and it is read by whoever connected — who may not be the
        // person who started the server.
        for line in [
            "- This network runs inside ddIRC, on this machine only.",
            "- It is a beta feature: expect gaps, and do not rely on it.",
            "- Nothing here is reachable from any other machine.",
        ] {
            self.numeric(id, Response::RPL_MOTD, &[line]);
        }
        self.numeric(id, Response::RPL_ENDOFMOTD, &["End of /MOTD command"]);
    }

    // ---------------------------------------------------------------- channels

    fn on_join(&mut self, id: ClientId, name: &str) {
        if !valid_channel(name) {
            self.numeric_args(id, Response::ERR_NOSUCHCHANNEL, &[name, "No such channel"]);
            return;
        }
        let key = fold(name);
        if self
            .channels
            .get(&key)
            .is_some_and(|c| c.members.contains(&id))
        {
            return;
        }

        let fresh = !self.channels.contains_key(&key);
        let channel = self.channels.entry(key.clone()).or_insert_with(|| Channel {
            name: name.to_owned(),
            topic: None,
            members: HashSet::new(),
            operators: HashSet::new(),
        });
        channel.members.insert(id);
        if fresh {
            channel.operators.insert(id);
        }
        let shown = channel.name.clone();

        if let Some(client) = self.clients.get_mut(&id) {
            client.channels.insert(key.clone());
        }

        let join = Message {
            tags: None,
            prefix: Some(self.prefix_of(id)),
            command: Command::JOIN(shown.clone(), None, None),
        };
        // The joiner is told first, and told the same message everyone else
        // gets. A client that sees the room before its own JOIN has to guess
        // whether it is in.
        self.send(id, join.clone());
        self.broadcast(&key, join, Some(id));

        self.send_topic(id, &key, false);
        self.send_names(id, &shown);
    }

    fn on_part(&mut self, id: ClientId, name: &str, reason: Option<&str>) {
        let key = fold(name);
        let present = self
            .channels
            .get(&key)
            .is_some_and(|c| c.members.contains(&id));
        if !present {
            self.numeric_args(
                id,
                Response::ERR_NOTONCHANNEL,
                &[name, "You're not on that channel"],
            );
            return;
        }
        let shown = self.channels[&key].name.clone();
        let part = Message {
            tags: None,
            prefix: Some(self.prefix_of(id)),
            command: Command::PART(shown, reason.map(str::to_owned)),
        };
        // Sent while still a member, so the leaver sees their own PART too —
        // that is the acknowledgement the command has taken effect.
        self.broadcast(&key, part.clone(), None);

        if let Some(channel) = self.channels.get_mut(&key) {
            channel.members.remove(&id);
            channel.operators.remove(&id);
            if channel.members.is_empty() {
                self.channels.remove(&key);
            }
        }
        if let Some(client) = self.clients.get_mut(&id) {
            client.channels.remove(&key);
        }
    }

    fn on_topic(&mut self, id: ClientId, name: &str, topic: Option<String>) {
        let key = fold(name);
        if !self.channels.contains_key(&key) {
            self.numeric_args(id, Response::ERR_NOSUCHCHANNEL, &[name, "No such channel"]);
            return;
        }
        let Some(text) = topic else {
            self.send_topic(id, &key, true);
            return;
        };
        if !self.channels[&key].members.contains(&id) {
            self.numeric_args(
                id,
                Response::ERR_NOTONCHANNEL,
                &[name, "You're not on that channel"],
            );
            return;
        }

        let setter = self.nick_of(id);
        let text = truncate(&text, TOPIC_LEN);
        let shown = self.channels[&key].name.clone();
        if let Some(channel) = self.channels.get_mut(&key) {
            channel.topic = if text.is_empty() {
                None
            } else {
                Some(Topic {
                    text: text.clone(),
                    set_by: setter,
                    at: now(),
                })
            };
        }
        let change = Message {
            tags: None,
            prefix: Some(self.prefix_of(id)),
            command: Command::TOPIC(shown, Some(text)),
        };
        self.broadcast(&key, change, None);
    }

    /// The topic as a reply. `explicit` is a `TOPIC` query, which says "no
    /// topic" out loud; a join stays quiet about an empty one, as servers do.
    fn send_topic(&mut self, id: ClientId, key: &str, explicit: bool) {
        let Some(channel) = self.channels.get(key) else {
            return;
        };
        let name = channel.name.clone();
        match &channel.topic {
            Some(topic) => {
                let (text, set_by, at) = (topic.text.clone(), topic.set_by.clone(), topic.at);
                self.numeric_args(id, Response::RPL_TOPIC, &[&name, &text]);
                self.numeric_args(
                    id,
                    Response::RPL_TOPICWHOTIME,
                    &[&name, &set_by, &at.to_string()],
                );
            }
            None if explicit => {
                self.numeric_args(id, Response::RPL_NOTOPIC, &[&name, "No topic is set"]);
            }
            None => {}
        }
    }

    fn send_names(&mut self, id: ClientId, name: &str) {
        let key = fold(name);
        let (shown, names) = match self.channels.get(&key) {
            Some(channel) => {
                let mut names: Vec<String> = channel
                    .members
                    .iter()
                    .filter_map(|m| {
                        let nick = self.clients.get(m)?.nick.clone()?;
                        Some(if channel.operators.contains(m) {
                            format!("@{nick}")
                        } else {
                            nick
                        })
                    })
                    .collect();
                // Sorted so the list is stable between calls. A member list
                // that reorders itself on every NAMES looks like churn.
                names.sort();
                (channel.name.clone(), names)
            }
            None => (name.to_owned(), Vec::new()),
        };

        if !names.is_empty() {
            // "=" is the public-channel marker. This server has no secret or
            // private channels, so it is always this one.
            self.numeric_args(id, Response::RPL_NAMREPLY, &["=", &shown, &names.join(" ")]);
        }
        self.numeric_args(
            id,
            Response::RPL_ENDOFNAMES,
            &[&shown, "End of /NAMES list"],
        );
    }

    // ---------------------------------------------------------------- messages

    fn on_message(&mut self, id: ClientId, target: &str, text: &str, notice: bool) {
        if target.is_empty() {
            if !notice {
                self.numeric(id, Response::ERR_NORECIPIENT, &["No recipient given"]);
            }
            return;
        }
        if text.is_empty() {
            if !notice {
                self.numeric(id, Response::ERR_NOTEXTTOSEND, &["No text to send"]);
            }
            return;
        }

        let command = if notice {
            Command::NOTICE(target.to_owned(), text.to_owned())
        } else {
            Command::PRIVMSG(target.to_owned(), text.to_owned())
        };
        let message = Message {
            tags: None,
            prefix: Some(self.prefix_of(id)),
            command,
        };

        if is_channel(target) {
            let key = fold(target);
            let member = self
                .channels
                .get(&key)
                .is_some_and(|c| c.members.contains(&id));
            if !member {
                // A NOTICE must never draw an automatic reply — that is what
                // distinguishes it from PRIVMSG, and two servers bouncing
                // errors at each other is the failure it exists to prevent.
                if !notice {
                    self.numeric_args(
                        id,
                        Response::ERR_CANNOTSENDTOCHAN,
                        &[target, "Cannot send to channel"],
                    );
                }
                return;
            }
            // Not echoed to the sender: the client shows its own message when
            // it sends it, and a server that echoed would show it twice.
            self.broadcast(&key, message, Some(id));
            return;
        }

        match self.nicks.get(&fold(target)).copied() {
            Some(to) => self.send(to, message),
            None if !notice => {
                self.numeric_args(
                    id,
                    Response::ERR_NOSUCHNICK,
                    &[target, "No such nick/channel"],
                );
            }
            None => {}
        }
    }

    fn on_ping(&mut self, id: ClientId, token: String) {
        let server = self.server_name.clone();
        self.send(
            id,
            Message {
                tags: None,
                prefix: Some(Prefix::ServerName(server.clone())),
                command: Command::PONG(server, Some(token)),
            },
        );
    }

    // ----------------------------------------------------------------- sending

    fn is_registered(&self, id: ClientId) -> bool {
        self.clients.get(&id).is_some_and(|c| c.registered)
    }

    fn nick_of(&self, id: ClientId) -> String {
        self.clients
            .get(&id)
            .map(|c| c.nick().to_owned())
            .unwrap_or_else(|| "*".to_owned())
    }

    fn prefix_of(&self, id: ClientId) -> Prefix {
        self.clients
            .get(&id)
            .map(Client::prefix)
            .unwrap_or_else(|| Prefix::ServerName(self.server_name.clone()))
    }

    /// Move a nick to `id`, releasing whatever it held before.
    ///
    /// The only writer of `nicks`, so the index and the clients cannot drift.
    fn claim_nick(&mut self, id: ClientId, nick: &str) {
        if let Some(previous) = self.clients.get(&id).and_then(|c| c.nick.clone()) {
            self.nicks.remove(&fold(&previous));
        }
        self.nicks.insert(fold(nick), id);
        if let Some(client) = self.clients.get_mut(&id) {
            client.nick = Some(nick.to_owned());
        }
    }

    fn send(&self, id: ClientId, message: Message) {
        if let Some(client) = self.clients.get(&id) {
            // A failed send means the writer task is gone, which means the
            // socket is gone. The disconnect is already on its way here as its
            // own event, so there is nothing useful to do about it now.
            let _ = client.tx.send(message);
        }
    }

    fn broadcast(&self, key: &str, message: Message, except: Option<ClientId>) {
        let Some(channel) = self.channels.get(key) else {
            return;
        };
        for &member in &channel.members {
            if Some(member) != except {
                self.send(member, message.clone());
            }
        }
    }

    /// Everyone sharing a channel with `id`, each told once.
    fn tell_peers(&self, id: ClientId, message: Message, include_self: bool) {
        let Some(client) = self.clients.get(&id) else {
            return;
        };
        let mut told: HashSet<ClientId> = HashSet::new();
        if include_self {
            told.insert(id);
            self.send(id, message.clone());
        }
        for name in &client.channels {
            let Some(channel) = self.channels.get(name) else {
                continue;
            };
            for &member in &channel.members {
                if told.insert(member) {
                    self.send(member, message.clone());
                }
            }
        }
    }

    /// A numeric whose only parameter is the trailing text.
    fn numeric(&self, id: ClientId, response: Response, args: &[&str]) {
        self.numeric_args(id, response, args);
    }

    /// A numeric addressed to `id`.
    ///
    /// The recipient's own nick is always the first parameter — that is what
    /// makes a numeric addressable — so it is added here rather than at each of
    /// the several dozen call sites that would otherwise have to remember.
    fn numeric_args(&self, id: ClientId, response: Response, args: &[&str]) {
        let mut all = vec![self.nick_of(id)];
        all.extend(args.iter().map(|s| (*s).to_owned()));
        self.send(
            id,
            Message {
                tags: None,
                prefix: Some(Prefix::ServerName(self.server_name.clone())),
                command: Command::Response(response, all),
            },
        );
    }

    /// A command `irc-proto` has no variant for.
    fn raw(&self, id: ClientId, command: &str, args: &[&str]) {
        self.send(
            id,
            Message {
                tags: None,
                prefix: Some(Prefix::ServerName(self.server_name.clone())),
                command: Command::Raw(
                    command.to_owned(),
                    args.iter().map(|s| (*s).to_owned()).collect(),
                ),
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver};

    /// A network with `n` connected-but-unregistered clients.
    fn network(n: u64) -> (Network, Vec<UnboundedReceiver<Message>>) {
        let mut net = Network::new(DEFAULT_SERVER_NAME, DEFAULT_NETWORK_NAME);
        let mut rxs = Vec::new();
        for id in 0..n {
            let (tx, rx) = unbounded_channel();
            net.connect(id, tx);
            rxs.push(rx);
        }
        (net, rxs)
    }

    fn register(net: &mut Network, id: ClientId, nick: &str) {
        net.handle(id, Message::new(None, "NICK", vec![nick]).unwrap());
        net.handle(
            id,
            Message::new(None, "USER", vec![nick, "0", "*", "Real Name"]).unwrap(),
        );
    }

    /// Everything queued for a client, as wire lines.
    fn drain(rx: &mut UnboundedReceiver<Message>) -> Vec<String> {
        let mut out = Vec::new();
        while let Ok(m) = rx.try_recv() {
            out.push(m.to_string().trim_end().to_owned());
        }
        out
    }

    fn has(lines: &[String], needle: &str) -> bool {
        lines.iter().any(|l| l.contains(needle))
    }

    #[test]
    fn registration_produces_the_numerics_the_client_waits_for() {
        let (mut net, mut rxs) = network(1);
        register(&mut net, 0, "alice");
        let lines = drain(&mut rxs[0]);

        // 001 is what the client treats as "connected"; 005 is what it parses
        // its casemapping and prefixes out of.
        assert!(has(&lines, " 001 alice "), "{lines:?}");
        assert!(has(&lines, " 005 alice "), "{lines:?}");
        assert!(has(&lines, "NETWORK=Local"), "{lines:?}");
        assert!(has(&lines, "PREFIX=(o)@"), "{lines:?}");
        assert!(has(&lines, " 376 alice "), "{lines:?}");
    }

    #[test]
    fn cap_negotiation_holds_the_welcome_until_cap_end() {
        let (mut net, mut rxs) = network(1);
        net.handle(0, Message::new(None, "CAP", vec!["LS", "302"]).unwrap());
        register(&mut net, 0, "alice");

        let mid = drain(&mut rxs[0]);
        assert!(has(&mid, "CAP"), "{mid:?}");
        // Still negotiating: a welcome here would arrive mid-conversation.
        assert!(!has(&mid, " 001 "), "{mid:?}");

        net.handle(0, Message::new(None, "CAP", vec!["END"]).unwrap());
        assert!(has(&drain(&mut rxs[0]), " 001 alice "));
    }

    #[test]
    fn a_taken_nick_is_refused_and_the_holder_keeps_it() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        drain(&mut rxs[0]);

        net.handle(1, Message::new(None, "NICK", vec!["ALICE"]).unwrap());
        // Case-folded: ALICE and alice are the same nick under CASEMAPPING.
        assert!(has(&drain(&mut rxs[1]), " 433 "), "expected nick-in-use");
        assert_eq!(net.nick_of(0), "alice");
    }

    #[test]
    fn commands_before_registration_are_refused() {
        let (mut net, mut rxs) = network(1);
        net.handle(0, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        assert!(has(&drain(&mut rxs[0]), " 451 "), "expected not-registered");
    }

    #[test]
    fn joining_tells_the_room_and_the_joiner() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        net.handle(0, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        drain(&mut rxs[0]);
        drain(&mut rxs[1]);

        net.handle(1, Message::new(None, "JOIN", vec!["#room"]).unwrap());

        let alice = drain(&mut rxs[0]);
        assert!(has(&alice, "bob!bob@localhost JOIN #room"), "{alice:?}");

        let bob = drain(&mut rxs[1]);
        // Its own JOIN first, then the room — otherwise a client has to guess
        // whether it is in.
        assert!(has(&bob, "bob!bob@localhost JOIN #room"), "{bob:?}");
        assert!(has(&bob, " 353 "), "{bob:?}");
        assert!(has(&bob, " 366 "), "{bob:?}");
        // alice created the channel, so she carries the operator prefix.
        assert!(has(&bob, "@alice"), "{bob:?}");
    }

    #[test]
    fn a_channel_message_reaches_everyone_but_the_sender() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        net.handle(0, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        net.handle(1, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        drain(&mut rxs[0]);
        drain(&mut rxs[1]);

        net.handle(
            0,
            Message::new(None, "PRIVMSG", vec!["#room", "hello everyone"]).unwrap(),
        );

        assert!(has(&drain(&mut rxs[1]), "PRIVMSG #room :hello everyone"));
        // Not echoed: the client already shows what it sent, and a second copy
        // would show it twice.
        assert!(!has(&drain(&mut rxs[0]), "PRIVMSG #room"));
    }

    #[test]
    fn a_message_to_a_channel_you_are_not_in_is_refused() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        net.handle(0, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        drain(&mut rxs[1]);

        net.handle(
            1,
            Message::new(None, "PRIVMSG", vec!["#room", "hi"]).unwrap(),
        );
        assert!(has(&drain(&mut rxs[1]), " 404 "), "expected cannot-send");
    }

    #[test]
    fn a_private_message_reaches_the_named_client_only() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        drain(&mut rxs[0]);
        drain(&mut rxs[1]);

        // Addressed as "BOB" and delivered to bob: nicks are matched under the
        // casemapping, and the target is echoed as it was typed, which is what
        // every other server does.
        net.handle(
            0,
            Message::new(None, "PRIVMSG", vec!["BOB", "psst"]).unwrap(),
        );
        let bob = drain(&mut rxs[1]);
        assert!(has(&bob, "alice!alice@localhost PRIVMSG BOB"), "{bob:?}");
        assert!(has(&bob, "psst"), "{bob:?}");

        net.handle(
            0,
            Message::new(None, "PRIVMSG", vec!["nobody", "?"]).unwrap(),
        );
        assert!(has(&drain(&mut rxs[0]), " 401 "), "expected no-such-nick");
    }

    #[test]
    fn a_notice_never_draws_an_error_back() {
        let (mut net, mut rxs) = network(1);
        register(&mut net, 0, "alice");
        drain(&mut rxs[0]);

        net.handle(
            0,
            Message::new(None, "NOTICE", vec!["ghost", "hi"]).unwrap(),
        );
        net.handle(
            0,
            Message::new(None, "NOTICE", vec!["#nowhere", "hi"]).unwrap(),
        );
        // Two servers bouncing errors off each other is exactly what the rule
        // against auto-replying to NOTICE exists to prevent.
        assert!(drain(&mut rxs[0]).is_empty());
    }

    #[test]
    fn the_topic_is_kept_and_shown_to_whoever_joins_next() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        net.handle(0, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        net.handle(
            0,
            Message::new(None, "TOPIC", vec!["#room", "the day's business"]).unwrap(),
        );
        drain(&mut rxs[1]);

        net.handle(1, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        let bob = drain(&mut rxs[1]);
        assert!(has(&bob, " 332 "), "{bob:?}");
        assert!(has(&bob, "the day's business"), "{bob:?}");
        assert!(has(&bob, " 333 "), "expected who-and-when");
    }

    #[test]
    fn quitting_tells_each_witness_once() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        for room in ["#one", "#two"] {
            net.handle(0, Message::new(None, "JOIN", vec![room]).unwrap());
            net.handle(1, Message::new(None, "JOIN", vec![room]).unwrap());
        }
        drain(&mut rxs[1]);

        net.disconnect(0, "Client quit");

        let bob = drain(&mut rxs[1]);
        // Two shared channels, one QUIT. Anything else is a client showing the
        // same departure twice.
        assert_eq!(
            bob.iter().filter(|l| l.contains(" QUIT ")).count(),
            1,
            "{bob:?}"
        );
        // The nick is free again the moment its holder is gone.
        assert!(!net.nicks.contains_key("alice"));
    }

    #[test]
    fn what_someone_said_on_the_way_out_is_what_the_channel_is_told() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        net.handle(0, Message::new(None, "JOIN", vec!["#one"]).unwrap());
        net.handle(1, Message::new(None, "JOIN", vec!["#one"]).unwrap());
        drain(&mut rxs[1]);

        net.handle(0, Message::new(None, "QUIT", vec!["heading out"]).unwrap());
        // The socket closes a moment later, and the session task reports what
        // it saw — which is not what alice said.
        net.disconnect(0, "Connection closed");

        let bob = drain(&mut rxs[1]);
        assert!(has(&bob, "QUIT :heading out"), "{bob:?}");
        assert!(!has(&bob, "Connection closed"), "{bob:?}");
    }

    #[test]
    fn a_dropped_socket_still_says_something() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        net.handle(0, Message::new(None, "JOIN", vec!["#one"]).unwrap());
        net.handle(1, Message::new(None, "JOIN", vec!["#one"]).unwrap());
        drain(&mut rxs[1]);

        // No QUIT at all: the connection simply went away.
        net.disconnect(0, "Connection closed");
        assert!(has(&drain(&mut rxs[1]), "QUIT :Connection closed"));
    }

    #[test]
    fn a_quit_message_from_the_wire_cannot_panic_or_run_long() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        net.handle(0, Message::new(None, "JOIN", vec!["#one"]).unwrap());
        net.handle(1, Message::new(None, "JOIN", vec!["#one"]).unwrap());
        drain(&mut rxs[1]);

        // Multi-byte, and long enough that the cut lands inside a character.
        // `String::truncate` would panic here, and the state task taking a
        // panic is every client on the server losing theirs.
        let said = "é".repeat(TOPIC_LEN);
        net.handle(0, Message::new(None, "QUIT", vec![said.as_str()]).unwrap());
        net.disconnect(0, "Connection closed");

        let bob = drain(&mut rxs[1]);
        // Cut to the limit, and cut between characters: half an `é` is not a
        // string this could have sent at all.
        let quit = bob.iter().find(|l| l.contains("QUIT")).expect("a quit");
        assert_eq!(quit.matches('é').count(), TOPIC_LEN / 'é'.len_utf8());
        assert!(!quit.contains('\u{fffd}'), "{quit}");
    }

    #[test]
    fn a_topic_that_straddles_the_limit_is_cut_on_a_character() {
        let (mut net, mut rxs) = network(1);
        register(&mut net, 0, "alice");
        net.handle(0, Message::new(None, "JOIN", vec!["#one"]).unwrap());
        drain(&mut rxs[0]);

        net.handle(
            0,
            Message::new(None, "TOPIC", vec!["#one", &"é".repeat(TOPIC_LEN)]).unwrap(),
        );
        let lines = drain(&mut rxs[0]);
        let topic = lines.iter().find(|l| l.contains("TOPIC")).expect("a topic");
        assert_eq!(topic.matches('é').count(), TOPIC_LEN / 'é'.len_utf8());
    }

    #[test]
    fn an_empty_channel_is_forgotten() {
        let (mut net, _rxs) = network(1);
        register(&mut net, 0, "alice");
        net.handle(0, Message::new(None, "JOIN", vec!["#room"]).unwrap());
        assert!(net.channels.contains_key("#room"));

        net.handle(0, Message::new(None, "PART", vec!["#room"]).unwrap());
        // Otherwise every channel ever named lives until the process does, and
        // its topic and operator survive to surprise whoever joins next.
        assert!(!net.channels.contains_key("#room"));
    }

    #[test]
    fn a_rename_reaches_everyone_who_can_see_it_once() {
        let (mut net, mut rxs) = network(2);
        register(&mut net, 0, "alice");
        register(&mut net, 1, "bob");
        for room in ["#one", "#two"] {
            net.handle(0, Message::new(None, "JOIN", vec![room]).unwrap());
            net.handle(1, Message::new(None, "JOIN", vec![room]).unwrap());
        }
        drain(&mut rxs[0]);
        drain(&mut rxs[1]);

        net.handle(0, Message::new(None, "NICK", vec!["alicia"]).unwrap());

        let bob = drain(&mut rxs[1]);
        assert_eq!(
            bob.iter().filter(|l| l.contains("NICK")).count(),
            1,
            "{bob:?}"
        );
        assert!(has(&bob, "alice!alice@localhost NICK alicia"), "{bob:?}");
        // The renamer is told too, or its own name silently goes stale.
        assert!(has(&drain(&mut rxs[0]), "NICK alicia"));
        assert!(net.nicks.contains_key("alicia"));
        assert!(!net.nicks.contains_key("alice"));
    }

    #[test]
    fn ping_is_answered_with_the_token_it_was_given() {
        let (mut net, mut rxs) = network(1);
        register(&mut net, 0, "alice");
        drain(&mut rxs[0]);

        net.handle(0, Message::new(None, "PING", vec!["abc123"]).unwrap());
        assert!(has(&drain(&mut rxs[0]), "PONG"), "a ping must be answered");
    }

    #[test]
    fn a_nick_that_would_break_the_protocol_is_refused() {
        let (mut net, mut rxs) = network(1);
        for bad in ["#room", "two words", "with,comma", "a!b"] {
            net.handle(0, Message::new(None, "NICK", vec![bad]).unwrap());
        }
        let lines = drain(&mut rxs[0]);
        assert_eq!(
            lines.iter().filter(|l| l.contains(" 432 ")).count(),
            4,
            "{lines:?}"
        );
    }
}
