//! The connection actor.
//!
//! One tokio task owns the `irc::Client` outright. Commands arrive on a channel
//! and events leave on another, so nothing outside this task ever touches the
//! client. That sidesteps the thread-safety questions entirely: there is no
//! shared mutable connection state to synchronise.
//!
//! The task also owns registration, because the `irc` crate's `identify()`
//! sends `CAP END` before `NICK`/`USER` and so closes capability negotiation
//! before SASL could run. See [`crate::conn::sasl`].

use std::collections::VecDeque;
use std::time::Instant;

use futures_util::StreamExt;
use irc::client::prelude::Config as IrcConfig;
use irc::client::Client;
use irc::proto::{ChannelMode, Command as Irc, Message, Mode, Response};
use tokio::sync::mpsc;
use tokio::time::sleep;
use zeroize::Zeroizing;

use crate::api::events::IrcEvent;
use crate::api::types::{
    AuthOutcome, ChatMessage, ConfigError, ConnectionStatus, MemberView, ServerConfig, Target,
};
use crate::conn::ratelimit::{ReceiveLimiter, SendLimiter};
use crate::conn::reconnect::Backoff;
use crate::conn::sasl::{Credentials, NotAttempted, SaslNegotiator, SaslOutcome};
use crate::state::{limits, truncate, Session};
use crate::text::format;

/// How many events may queue up before we start dropping them. Generous enough
/// to absorb a netsplit burst; bounded so a stalled UI cannot exhaust memory.
const EVENT_QUEUE: usize = 1024;

/// Cap on a single outgoing message, below the 512-byte IRC line limit with
/// room for the command envelope the server adds.
const MAX_MESSAGE_CHARS: usize = 400;

/// Requests from the UI into the actor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientCommand {
    Join {
        channel: String,
        key: Option<String>,
    },
    Part {
        channel: String,
        reason: Option<String>,
    },
    SendMessage {
        target: String,
        text: String,
    },
    SendAction {
        target: String,
        text: String,
    },
    SetNick(String),
    /// Set a channel topic, or clear it with an empty string.
    SetTopic {
        channel: String,
        topic: String,
    },
    /// Disconnect and stop reconnecting.
    Disconnect {
        reason: Option<String>,
    },
}

/// Errors that end a connection attempt.
#[derive(Debug, thiserror::Error)]
pub enum ConnectionError {
    #[error("invalid configuration: {0}")]
    Config(#[from] ConfigError),
    #[error("connection failed: {0}")]
    Irc(#[from] irc::error::Error),
    #[error("the client was shut down")]
    Shutdown,
    #[error("the connection is busy; try again")]
    Busy,
}

/// Why the inner connection loop returned.
enum Disposition {
    /// The user asked to disconnect; do not reconnect.
    UserQuit,
    /// The connection dropped; reconnect after backoff.
    Lost(String),
}

/// A handle for driving a connection from outside the actor.
#[derive(Debug, Clone)]
pub struct ConnectionHandle {
    commands: mpsc::Sender<ClientCommand>,
}

impl ConnectionHandle {
    /// Queue a command, waiting if the queue is momentarily full.
    ///
    /// Fails only once the actor has stopped.
    pub async fn send(&self, command: ClientCommand) -> Result<(), ConnectionError> {
        self.commands
            .send(command)
            .await
            .map_err(|_| ConnectionError::Shutdown)
    }

    /// Queue a command without waiting.
    ///
    /// For callers outside an async context — notably the FFI layer, where
    /// blocking would tie up a worker thread for as long as the actor is busy.
    /// A full queue is reported rather than hidden, since it means the actor is
    /// badly backed up and the command genuinely did not happen.
    pub fn try_send(&self, command: ClientCommand) -> Result<(), ConnectionError> {
        self.commands
            .try_send(command)
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => ConnectionError::Busy,
                mpsc::error::TrySendError::Closed(_) => ConnectionError::Shutdown,
            })
    }

    /// True once the actor has stopped and no further commands will be acted on.
    pub fn is_closed(&self) -> bool {
        self.commands.is_closed()
    }
}

/// Start a connection actor, returning a handle and the event stream.
///
/// The actor runs until the connection is explicitly closed or the event
/// receiver is dropped.
pub fn spawn(config: ServerConfig) -> (ConnectionHandle, mpsc::Receiver<IrcEvent>) {
    let (command_tx, command_rx) = mpsc::channel(64);
    let (event_tx, event_rx) = mpsc::channel(EVENT_QUEUE);

    tokio::spawn(async move {
        Actor::new(config, event_tx).run(command_rx).await;
    });

    (
        ConnectionHandle {
            commands: command_tx,
        },
        event_rx,
    )
}

struct Actor {
    config: ServerConfig,
    events: mpsc::Sender<IrcEvent>,
    session: Session,
    recv_limiter: ReceiveLimiter,
    /// Events dropped because the UI was not keeping up.
    dropped_events: u64,
}

impl Actor {
    fn new(config: ServerConfig, events: mpsc::Sender<IrcEvent>) -> Self {
        let session = Session::new(config.nickname.clone());
        Self {
            config,
            events,
            session,
            recv_limiter: ReceiveLimiter::new(Instant::now()),
            dropped_events: 0,
        }
    }

    /// Emit an event, dropping it if the UI has fallen behind.
    ///
    /// Dropping rather than awaiting matters: blocking here would stop us
    /// reading the socket, and the server would eventually ping-timeout us.
    fn emit(&mut self, event: IrcEvent) {
        if self.events.try_send(event).is_err() {
            self.dropped_events = self.dropped_events.saturating_add(1);
        }
    }

    fn status(&mut self, status: ConnectionStatus, detail: Option<String>) {
        self.emit(IrcEvent::Status { status, detail });
    }

    /// Reconnect loop. Returns when the user disconnects or the config is
    /// invalid, which is not worth retrying.
    async fn run(&mut self, mut commands: mpsc::Receiver<ClientCommand>) {
        let mut backoff = Backoff::default();

        loop {
            if let Err(error) = self.config.validate() {
                self.emit(IrcEvent::Error {
                    message: error.to_string(),
                    fatal: true,
                });
                self.status(ConnectionStatus::Disconnected, Some(error.to_string()));
                return;
            }

            self.status(ConnectionStatus::Connecting, None);

            let disposition = match self.connect_once(&mut commands, &mut backoff).await {
                Ok(disposition) => disposition,
                Err(error) => Disposition::Lost(error.to_string()),
            };

            let reason = match disposition {
                Disposition::UserQuit => {
                    self.status(ConnectionStatus::Disconnected, None);
                    return;
                }
                Disposition::Lost(reason) => reason,
            };

            // The session is per-connection; membership does not survive a drop.
            self.session = Session::new(self.config.nickname.clone());

            let delay = backoff.next_delay();
            self.status(
                ConnectionStatus::Reconnecting {
                    // Rounded up: truncating showed "reconnecting in 0s" for
                    // any sub-second wait, which reads as a broken countdown.
                    retry_in_secs: delay.as_secs_f64().ceil() as u64,
                    attempt: backoff.attempt(),
                },
                Some(reason),
            );

            // Stay responsive to a disconnect request while waiting.
            tokio::select! {
                () = sleep(delay) => {}
                command = commands.recv() => {
                    match command {
                        Some(ClientCommand::Disconnect { .. }) | None => {
                            self.status(ConnectionStatus::Disconnected, None);
                            return;
                        }
                        // Commands issued while offline have nowhere to go.
                        Some(_) => {}
                    }
                }
            }
        }
    }

    /// One connection attempt, from TCP to disconnect.
    async fn connect_once(
        &mut self,
        commands: &mut mpsc::Receiver<ClientCommand>,
        backoff: &mut Backoff,
    ) -> Result<Disposition, ConnectionError> {
        let mut client = Client::from_config(self.irc_config()).await?;
        let mut stream = client.stream()?;
        let sender = client.sender();

        self.status(ConnectionStatus::Registering, None);

        let mut sasl = SaslNegotiator::new(self.sasl_credentials());
        let mut auth = AuthOutcome::Anonymous;
        let mut registered = false;

        // The registration burst is not rate limited: servers expect it
        // immediately, and throttling it looks like a stalled client.
        sender.send(sasl.start())?;
        if let Some(password) = &self.config.server_password {
            sender.send(Irc::PASS(password.as_str().to_owned()))?;
        }
        sender.send(Irc::NICK(self.config.nickname.clone()))?;
        sender.send(Irc::USER(
            self.config.username().to_owned(),
            "0".to_owned(),
            self.config.realname().to_owned(),
        ))?;

        let mut outgoing: VecDeque<Irc> = VecDeque::new();
        let mut send_limiter = SendLimiter::new(Instant::now());

        loop {
            // Arm a timer only when something is waiting to go out, so a quiet
            // client never wakes up needlessly.
            let flush_in = (!outgoing.is_empty()).then(|| send_limiter.wait_time(Instant::now()));

            tokio::select! {
                biased;

                // Flush one queued command when the rate limiter allows.
                () = async {
                    match flush_in {
                        Some(delay) => sleep(delay).await,
                        // Never completes; keeps this branch inert.
                        None => std::future::pending().await,
                    }
                } => {
                    if send_limiter.acquire(Instant::now()).is_zero() {
                        if let Some(command) = outgoing.pop_front() {
                            sender.send(command)?;
                        }
                    }
                }

                command = commands.recv() => {
                    let Some(command) = command else {
                        // The handle was dropped; shut down cleanly.
                        let _ = sender.send(Irc::QUIT(None));
                        return Ok(Disposition::UserQuit);
                    };
                    if let ClientCommand::Disconnect { reason } = command {
                        let _ = sender.send(Irc::QUIT(Some(
                            reason.unwrap_or_else(|| "ddIRC".to_owned()),
                        )));
                        return Ok(Disposition::UserQuit);
                    }
                    self.queue(&mut outgoing, command);
                }

                message = stream.next() => {
                    let Some(message) = message else {
                        return Ok(Disposition::Lost("connection closed by server".to_owned()));
                    };
                    let message = message?;

                    // SASL runs before anything else and is never rate limited.
                    if !sasl.is_finished() {
                        let step = sasl.advance(&message);
                        for command in step.send {
                            sender.send(command)?;
                        }
                        if let Some(outcome) = step.outcome {
                            auth = self.auth_outcome(outcome);
                        }
                    }

                    if !self.recv_limiter.admit(Instant::now()) {
                        continue;
                    }

                    self.handle(&message, &mut registered, &auth, backoff, &mut outgoing);
                }
            }

            // Report anything flood protection or a slow UI discarded.
            self.report_drops();
        }
    }

    /// Translate the SASL result into the outcome the UI shows, sending the
    /// NickServ fallback when SASL did not authenticate us.
    fn auth_outcome(&self, outcome: SaslOutcome) -> AuthOutcome {
        match outcome {
            SaslOutcome::Authenticated => AuthOutcome::Sasl,
            SaslOutcome::NotAttempted {
                reason: NotAttempted::NoCredentials,
            } => {
                if self.config.nickserv_password.is_some() {
                    AuthOutcome::NickServFallback {
                        reason: "no SASL credentials configured".to_owned(),
                    }
                } else {
                    AuthOutcome::Anonymous
                }
            }
            SaslOutcome::NotAttempted {
                reason: NotAttempted::Unsupported,
            } => AuthOutcome::NickServFallback {
                reason: "server does not offer SASL".to_owned(),
            },
            SaslOutcome::Rejected { reason } => AuthOutcome::NickServFallback { reason },
        }
    }

    fn sasl_credentials(&self) -> Option<Credentials> {
        let account = self.config.sasl_account.as_ref()?;
        let password = self.config.sasl_password.as_ref()?;
        Some(Credentials {
            account: account.clone(),
            password: password.clone(),
        })
    }

    /// Build the crate's config.
    ///
    /// TLS is always on and `dangerously_accept_invalid_certs` is never set, so
    /// there is no path through this code that skips certificate verification.
    /// `cert_path` only ever *adds* a root to the platform's trust store, and
    /// is unset outside tests.
    /// `channels` and `nick_password` are deliberately left unset: the crate
    /// would act on them at end-of-MOTD, and we want to control both ordering
    /// and rate limiting ourselves.
    fn irc_config(&self) -> IrcConfig {
        IrcConfig {
            server: Some(self.config.host.clone()),
            port: Some(self.config.port),
            use_tls: Some(true),
            nickname: Some(self.config.nickname.clone()),
            alt_nicks: self.config.alt_nicks.clone(),
            username: Some(self.config.username().to_owned()),
            realname: Some(self.config.realname().to_owned()),
            ping_time: Some(60),
            ping_timeout: Some(20),
            cert_path: self.config.extra_root_cert.clone(),
            ..IrcConfig::default()
        }
    }

    /// Convert a UI command into protocol commands on the outgoing queue.
    fn queue(&mut self, outgoing: &mut VecDeque<Irc>, command: ClientCommand) {
        match command {
            ClientCommand::Join { channel, key } => {
                let command = match key {
                    Some(key) => Irc::JOIN(channel, Some(key), None),
                    None => Irc::JOIN(channel, None, None),
                };
                outgoing.push_back(command);
            }
            ClientCommand::Part { channel, reason } => {
                outgoing.push_back(Irc::PART(channel, reason));
            }
            ClientCommand::SendMessage { target, text } => {
                for line in sanitize_outgoing(&text) {
                    self.echo(&target, &line, false);
                    outgoing.push_back(Irc::PRIVMSG(target.clone(), line));
                }
            }
            ClientCommand::SendAction { target, text } => {
                for line in sanitize_outgoing(&text) {
                    self.echo(&target, &line, true);
                    outgoing.push_back(Irc::PRIVMSG(
                        target.clone(),
                        format!("\u{01}ACTION {line}\u{01}"),
                    ));
                }
            }
            ClientCommand::SetNick(nick) => outgoing.push_back(Irc::NICK(nick)),
            ClientCommand::SetTopic { channel, topic } => {
                // A topic is one protocol line, so newlines are collapsed
                // rather than split the way a message would be — sending the
                // tail as a second TOPIC would silently overwrite the first.
                let flattened: String = topic
                    .chars()
                    .map(|c| if c.is_control() { ' ' } else { c })
                    .collect();
                let bounded = truncate(flattened.trim(), limits::MAX_TOPIC);
                outgoing.push_back(Irc::TOPIC(channel, Some(bounded)));
            }
            // Handled before reaching the queue.
            ClientCommand::Disconnect { .. } => {}
        }
    }

    /// Emit one of our own messages back to the UI.
    ///
    /// IRC does not echo a client's own `PRIVMSG` back to it, so without this a
    /// user types a message and sees nothing — the conversation would show only
    /// the other side. (The IRCv3 `echo-message` capability would have the
    /// server do this, but it is far from universal, so we echo locally and do
    /// not request it. If it is ever requested, this must go, or every sent
    /// message will appear twice.)
    ///
    /// Echoed at queue time rather than after the rate limiter releases it, so
    /// the message appears immediately rather than up to a couple of seconds
    /// later.
    fn echo(&mut self, target: &str, line: &str, is_action: bool) {
        let nick = self.session.nick().to_owned();
        let sender_prefix = self
            .session
            .channel(target)
            .and_then(|c| c.member(&self.session.isupport.casemapping.normalize(&nick)))
            .and_then(|m| m.display_prefix(&self.session.isupport.prefixes))
            .map(|p| p.to_string());

        // A target we hold state for is a channel; anything else is a direct
        // message to that nick.
        let target = if self.session.channel(target).is_some() {
            Target::Channel(target.to_owned())
        } else {
            Target::Direct(target.to_owned())
        };

        self.emit(IrcEvent::Message(Box::new(ChatMessage {
            target,
            sender: nick,
            sender_prefix,
            spans: format::parse(line),
            is_self: true,
            // Quoting your own nick is not a mention of yourself.
            is_mention: false,
            is_action,
            is_notice: false,
        })));
    }

    fn report_drops(&mut self) {
        let flooded = self.recv_limiter.take_dropped();
        let backpressured = std::mem::take(&mut self.dropped_events);
        let total = flooded + backpressured;
        if total > 0 {
            // Sent directly: routing it through `emit` risks dropping the very
            // notice that explains the drops.
            let _ = self.events.try_send(IrcEvent::MessagesDropped {
                channel: None,
                count: total,
            });
        }
    }

    /// Dispatch one incoming message.
    fn handle(
        &mut self,
        message: &Message,
        registered: &mut bool,
        auth: &AuthOutcome,
        backoff: &mut Backoff,
        outgoing: &mut VecDeque<Irc>,
    ) {
        let source = message.source_nickname().map(str::to_owned);

        match &message.command {
            Irc::Response(Response::RPL_WELCOME, args) => {
                *registered = true;
                // Only reset backoff once registration succeeds. Resetting when
                // the socket opens would hot-loop against a server that accepts
                // then immediately drops us.
                backoff.reset();

                if let Some(nick) = args.first() {
                    self.session.set_nick(nick);
                }
                self.on_registered(auth, outgoing);
            }
            Irc::Response(Response::RPL_ISUPPORT, args) => {
                let before = self.session.isupport.network.clone();
                self.session.on_isupport(args);
                let after = self.session.isupport.network.clone();
                // Only on a change: ISUPPORT is sent over several lines, and
                // repeating the same name once per line is noise.
                if after != before {
                    if let Some(network) = after {
                        self.emit(IrcEvent::NetworkNamed { network });
                    }
                }
            }

            // 353: <nick> <symbol> <channel> :<names>
            Irc::Response(Response::RPL_NAMREPLY, args) => {
                if let (Some(channel), Some(names)) = (args.get(2), args.get(3)) {
                    self.session.on_names_reply(channel, names);
                }
            }
            // 366: <nick> <channel> :End of /NAMES list
            Irc::Response(Response::RPL_ENDOFNAMES, args) => {
                if let Some(channel) = args.get(1) {
                    self.session.on_end_of_names(channel);
                    self.emit_member_list(channel);
                }
            }
            // 332: <nick> <channel> :<topic>
            Irc::Response(Response::RPL_TOPIC, args) => {
                if let (Some(channel), Some(topic)) = (args.get(1), args.get(2)) {
                    self.session.on_topic(channel, topic);
                    let (channel, topic) = (channel.clone(), format::strip(topic));
                    self.emit(IrcEvent::TopicChanged {
                        channel,
                        topic,
                        set_by: None,
                    });
                }
            }
            Irc::Response(response, args) if is_error_numeric(*response) => {
                let message = args
                    .last()
                    .cloned()
                    .unwrap_or_else(|| format!("{response:?}"));
                self.emit(IrcEvent::Error {
                    message: format::strip(&message),
                    fatal: false,
                });
            }

            Irc::TOPIC(channel, Some(topic)) => {
                self.session.on_topic(channel, topic);
                self.emit(IrcEvent::TopicChanged {
                    channel: channel.clone(),
                    topic: format::strip(topic),
                    set_by: source,
                });
            }
            Irc::JOIN(channel, _, _) => {
                let Some(nick) = source else { return };
                if self.session.on_join(channel, &nick) {
                    let is_self = self.session.is_self(&nick);
                    self.emit(IrcEvent::Joined {
                        channel: channel.clone(),
                        nick,
                        is_self,
                    });
                    if is_self {
                        self.emit_member_list(channel);
                    }
                }
            }
            Irc::PART(channel, reason) => {
                let Some(nick) = source else { return };
                let is_self = self.session.is_self(&nick);
                if self.session.on_part(channel, &nick) {
                    self.emit(IrcEvent::Parted {
                        channel: channel.clone(),
                        nick,
                        is_self,
                        reason: reason.as_deref().map(format::strip),
                    });
                }
            }
            Irc::QUIT(reason) => {
                let Some(nick) = source else { return };
                let reason = reason.as_deref().map(format::strip);
                for channel in self.session.on_quit(&nick) {
                    self.emit(IrcEvent::Quit {
                        channel,
                        nick: nick.clone(),
                        reason: reason.clone(),
                    });
                }
            }
            Irc::NICK(new) => {
                let Some(old) = source else { return };
                let is_self = self.session.is_self(&old);
                for channel in self.session.on_nick_change(&old, new) {
                    self.emit(IrcEvent::NickChanged {
                        channel,
                        old: old.clone(),
                        new: new.clone(),
                        is_self,
                    });
                }
            }
            Irc::ChannelMODE(channel, modes) => self.on_mode(channel, modes, source),

            Irc::PRIVMSG(target, text) => self.on_chat(target, text, source, false),
            Irc::NOTICE(target, text) => self.on_chat(target, text, source, true),

            _ => {}
        }
    }

    /// Finish registration: authenticate via NickServ if SASL did not, then
    /// join the configured channels.
    fn on_registered(&mut self, auth: &AuthOutcome, outgoing: &mut VecDeque<Irc>) {
        if matches!(auth, AuthOutcome::NickServFallback { .. }) {
            if let Some(password) = &self.config.nickserv_password {
                // Sent as a normal message so it is rate limited like any other.
                let line = Zeroizing::new(format!("IDENTIFY {}", password.as_str()));
                outgoing.push_back(Irc::PRIVMSG(
                    "NickServ".to_owned(),
                    line.as_str().to_owned(),
                ));
            }
        }

        for channel in &self.config.channels {
            outgoing.push_back(Irc::JOIN(channel.clone(), None, None));
        }

        self.emit(IrcEvent::Registered {
            nick: self.session.nick().to_owned(),
            network: self.session.isupport.network.clone(),
            auth: auth.clone(),
        });
        self.status(ConnectionStatus::Connected, None);
    }

    /// Apply a channel mode change.
    ///
    /// The crate's own `takes_arg` is a hardcoded table that is wrong for `-l`
    /// (it claims a parameter that is not sent), which would shift every later
    /// argument and attribute privileges to the wrong member. So we keep only
    /// the order of modes and arguments — which the crate does preserve — and
    /// re-align them against the server's advertised `CHANMODES`.
    fn on_mode(&mut self, channel: &str, modes: &[Mode<ChannelMode>], source: Option<String>) {
        let mut mode_string = String::new();
        let mut params: Vec<String> = Vec::new();
        let mut current_sign = None;

        for mode in modes {
            let (sign, inner, arg) = match mode {
                Mode::Plus(inner, arg) => ('+', inner, arg),
                Mode::Minus(inner, arg) => ('-', inner, arg),
                Mode::NoPrefix(inner) => ('+', inner, &None),
            };
            if current_sign != Some(sign) {
                mode_string.push(sign);
                current_sign = Some(sign);
            }
            mode_string.push_str(&inner.to_string());
            if let Some(arg) = arg {
                params.push(arg.clone());
            }
        }

        let affected = self.session.on_mode(channel, &mode_string, &params);
        if !affected.is_empty() {
            self.emit(IrcEvent::ModeChanged {
                channel: channel.to_owned(),
                by: source,
                affected,
            });
            self.emit_member_list(channel);
        }
    }

    /// Handle a PRIVMSG or NOTICE.
    fn on_chat(&mut self, target: &str, text: &str, source: Option<String>, is_notice: bool) {
        let Some(sender) = source else { return };

        // CTCP ACTION is "\x01ACTION <text>\x01"; other CTCP requests are not
        // chat and are deliberately ignored rather than answered, so the client
        // cannot be used to leak version or timezone information.
        let trimmed = text.trim_matches('\u{01}');
        let (body, is_action) = match trimmed.strip_prefix("ACTION ") {
            Some(rest) => (rest, true),
            None if text.starts_with('\u{01}') => return,
            None => (text, false),
        };

        let is_self = self.session.is_self(&sender);
        // A message addressed to us directly belongs to a conversation with the
        // sender, not with ourselves.
        let target = if self.session.is_self(target) {
            Target::Direct(sender.clone())
        } else {
            Target::Channel(target.to_owned())
        };

        let sender_prefix = self
            .session
            .channel(target.name())
            .and_then(|c| c.member(&self.session.isupport.casemapping.normalize(&sender)))
            .and_then(|m| m.display_prefix(&self.session.isupport.prefixes))
            .map(|p| p.to_string());

        let message = ChatMessage {
            // Own messages never count as mentions of ourselves.
            is_mention: !is_self && self.session.is_mention(body),
            target,
            sender,
            sender_prefix,
            spans: format::parse(body),
            is_self,
            is_action,
            is_notice,
        };
        self.emit(IrcEvent::Message(Box::new(message)));
    }

    fn emit_member_list(&mut self, channel: &str) {
        let Some(chan) = self.session.channel(channel) else {
            return;
        };
        let prefixes = &self.session.isupport.prefixes;
        let members: Vec<MemberView> = chan
            .sorted_members(prefixes)
            .into_iter()
            .map(|m| MemberView {
                nick: m.nick.clone(),
                prefix: m.display_prefix(prefixes).map(|p| p.to_string()),
                away: m.away,
            })
            .collect();

        let channel = chan.name.clone();
        self.emit(IrcEvent::MemberList { channel, members });
    }
}

/// Split and bound an outgoing message.
///
/// Newlines are the important part: without splitting them, a message
/// containing CRLF would inject arbitrary commands into our own session.
fn sanitize_outgoing(text: &str) -> Vec<String> {
    text.lines()
        .flat_map(|line| {
            // Strip control characters a user could not have meant to send,
            // but keep formatting codes so deliberate styling still works.
            let cleaned: String = line
                .chars()
                .filter(|c| !matches!(*c, '\r' | '\n' | '\0'))
                .collect();

            cleaned
                .chars()
                .collect::<Vec<_>>()
                .chunks(MAX_MESSAGE_CHARS)
                .map(|chunk| chunk.iter().collect::<String>())
                .collect::<Vec<_>>()
        })
        .filter(|line| !line.trim().is_empty())
        .collect()
}

/// True for numerics that represent an error worth surfacing.
fn is_error_numeric(response: Response) -> bool {
    let code = response as u16;
    (400..600).contains(&code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outgoing_messages_cannot_inject_commands() {
        // The classic injection: a newline followed by a command.
        let lines = sanitize_outgoing("hello\r\nQUIT :owned");
        assert_eq!(lines, vec!["hello", "QUIT :owned"]);
        // Both are sent as message *content*, never as raw protocol, because
        // each becomes the parameter of its own PRIVMSG.
        assert!(lines.iter().all(|l| !l.contains('\r') && !l.contains('\n')));
    }

    #[test]
    fn outgoing_messages_are_chunked_to_fit_a_line() {
        let lines = sanitize_outgoing(&"x".repeat(1000));
        assert_eq!(lines.len(), 3);
        assert!(lines.iter().all(|l| l.chars().count() <= MAX_MESSAGE_CHARS));
        assert_eq!(lines.concat().chars().count(), 1000, "no content lost");
    }

    #[test]
    fn blank_lines_are_dropped() {
        assert!(sanitize_outgoing("   \n\n  ").is_empty());
        assert_eq!(sanitize_outgoing("a\n\nb"), vec!["a", "b"]);
    }

    #[test]
    fn formatting_codes_survive_outgoing_sanitisation() {
        // Users may deliberately send bold; only control characters that would
        // break framing are removed.
        let lines = sanitize_outgoing("\u{02}bold\u{02}");
        assert_eq!(lines, vec!["\u{02}bold\u{02}"]);
    }

    #[test]
    fn multibyte_messages_split_on_character_boundaries() {
        let lines = sanitize_outgoing(&"世".repeat(500));
        assert!(lines.len() >= 2);
        // Reassembling must reproduce the original exactly.
        assert_eq!(lines.concat(), "世".repeat(500));
    }

    // ---------------------------------------------------------------------
    // Transcript tests.
    //
    // These drive the real dispatch path with scripted server output, so the
    // whole message-handling layer is covered without a socket. Live testing
    // proved the TLS and registration path, but cannot serve as a regression
    // asset: it needs unfiltered egress and a cooperative server.
    // ---------------------------------------------------------------------

    /// Build an actor with no connection, plus the receiving end of its events.
    fn actor(channels: &[&str]) -> (Actor, mpsc::Receiver<IrcEvent>, VecDeque<Irc>) {
        let (tx, rx) = mpsc::channel(256);
        let config = ServerConfig {
            host: "example.test".to_owned(),
            port: ServerConfig::DEFAULT_TLS_PORT,
            nickname: "ddirc".to_owned(),
            channels: channels.iter().map(|c| (*c).to_owned()).collect(),
            ..Default::default()
        };
        (Actor::new(config, tx), rx, VecDeque::new())
    }

    /// Feed one raw server line through the dispatcher.
    fn feed(actor: &mut Actor, outgoing: &mut VecDeque<Irc>, raw: &str) {
        let message: Message = raw.parse().expect("transcript line should parse");
        let mut registered = true;
        let mut backoff = Backoff::default();
        actor.handle(
            &message,
            &mut registered,
            &AuthOutcome::Anonymous,
            &mut backoff,
            outgoing,
        );
    }

    fn drain(rx: &mut mpsc::Receiver<IrcEvent>) -> Vec<IrcEvent> {
        let mut events = Vec::new();
        while let Ok(event) = rx.try_recv() {
            events.push(event);
        }
        events
    }

    /// Bring the actor to a joined, populated channel.
    fn joined_channel(actor: &mut Actor, outgoing: &mut VecDeque<Irc>) {
        feed(
            actor,
            outgoing,
            ":srv 005 ddirc PREFIX=(qaohv)~&@%+ CHANMODES=beI,k,l,imnpst :are supported",
        );
        feed(actor, outgoing, ":ddirc!u@h JOIN #test");
        feed(
            actor,
            outgoing,
            ":srv 353 ddirc = #test :@alice +bob ddirc carol",
        );
        feed(actor, outgoing, ":srv 366 ddirc #test :End of /NAMES list");
    }

    #[test]
    fn welcome_registers_and_queues_configured_joins() {
        let (mut actor, mut rx, mut outgoing) = actor(&["#rust", "#test"]);
        feed(
            &mut actor,
            &mut outgoing,
            ":srv 001 ddirc :Welcome to the network",
        );

        let events = drain(&mut rx);
        assert!(
            events
                .iter()
                .any(|e| matches!(e, IrcEvent::Registered { nick, .. } if nick == "ddirc")),
            "expected a Registered event, got {events:?}"
        );
        assert!(events.iter().any(|e| matches!(
            e,
            IrcEvent::Status {
                status: ConnectionStatus::Connected,
                ..
            }
        )));
        assert_eq!(
            outgoing,
            VecDeque::from(vec![
                Irc::JOIN("#rust".to_owned(), None, None),
                Irc::JOIN("#test".to_owned(), None, None),
            ])
        );
    }

    #[test]
    fn names_reply_produces_a_member_list_with_prefixes() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);

        let members = drain(&mut rx)
            .iter()
            .rev()
            .find_map(|e| match e {
                IrcEvent::MemberList { members, .. } => Some(members.clone()),
                _ => None,
            })
            .expect("expected a MemberList event");

        // Sorted by privilege, then name.
        let rendered: Vec<(String, Option<String>)> = members
            .iter()
            .map(|m| (m.nick.clone(), m.prefix.clone()))
            .collect();
        assert_eq!(
            rendered,
            vec![
                ("alice".to_owned(), Some("@".to_owned())),
                ("bob".to_owned(), Some("+".to_owned())),
                ("carol".to_owned(), None),
                ("ddirc".to_owned(), None),
            ]
        );
    }

    #[test]
    fn channel_message_is_sanitised_and_attributed() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        // Bold formatting plus an embedded control character.
        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h PRIVMSG #test :\u{02}hi\u{02} there\u{07}",
        );

        let message = drain(&mut rx)
            .into_iter()
            .find_map(|e| match e {
                IrcEvent::Message(m) => Some(*m),
                _ => None,
            })
            .expect("expected a Message event");

        assert_eq!(message.sender, "alice");
        assert_eq!(
            message.sender_prefix.as_deref(),
            Some("@"),
            "op prefix carried"
        );
        assert_eq!(message.target, Target::Channel("#test".to_owned()));
        assert!(!message.is_self && !message.is_action && !message.is_notice);

        let text: String = message.spans.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(text, "hi there", "control character stripped");
        assert!(
            message.spans.iter().any(|s| s.style.bold),
            "bold kept as style"
        );
    }

    #[test]
    fn mentions_are_flagged_but_never_for_our_own_messages() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h PRIVMSG #test :ddirc: ping",
        );
        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h PRIVMSG #test :ddircular saw",
        );
        feed(
            &mut actor,
            &mut outgoing,
            ":ddirc!u@h PRIVMSG #test :ddirc said ddirc",
        );

        let flags: Vec<bool> = drain(&mut rx)
            .iter()
            .filter_map(|e| match e {
                IrcEvent::Message(m) => Some(m.is_mention),
                _ => None,
            })
            .collect();
        assert_eq!(
            flags,
            vec![true, false, false],
            "word-boundary mention, substring, then self-message"
        );
    }

    #[test]
    fn private_message_is_attributed_to_the_sender_not_ourselves() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        feed(&mut actor, &mut outgoing, ":alice!u@h PRIVMSG ddirc :psst");

        let message = drain(&mut rx)
            .into_iter()
            .find_map(|e| match e {
                IrcEvent::Message(m) => Some(*m),
                _ => None,
            })
            .expect("expected a Message event");
        // The conversation is with alice, not with ourselves.
        assert_eq!(message.target, Target::Direct("alice".to_owned()));
    }

    #[test]
    fn ctcp_action_is_chat_but_other_ctcp_is_ignored() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h PRIVMSG #test :\u{01}ACTION waves\u{01}",
        );
        // A VERSION request must not be answered or shown; replying leaks
        // client and platform details to anyone who asks.
        feed(
            &mut actor,
            &mut outgoing,
            ":mallory!u@h PRIVMSG #test :\u{01}VERSION\u{01}",
        );

        let messages: Vec<ChatMessage> = drain(&mut rx)
            .into_iter()
            .filter_map(|e| match e {
                IrcEvent::Message(m) => Some(*m),
                _ => None,
            })
            .collect();

        assert_eq!(messages.len(), 1, "only the ACTION counts as chat");
        assert!(messages[0].is_action);
        let text: String = messages[0].spans.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(text, "waves");
        assert!(outgoing.is_empty(), "no CTCP reply was queued");
    }

    #[test]
    fn mode_change_aligns_parameters_against_server_chanmodes() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        // "-l+o bob": `-l` carries no parameter, so `bob` belongs to `+o`. The
        // crate's own mode table gets this wrong and would op the wrong user.
        feed(&mut actor, &mut outgoing, ":alice!u@h MODE #test -l+o bob");

        let events = drain(&mut rx);
        assert!(
            events.iter().any(|e| matches!(
                e,
                IrcEvent::ModeChanged { affected, .. } if affected == &vec!["bob".to_owned()]
            )),
            "expected bob to be the affected member, got {events:?}"
        );

        let members = events
            .iter()
            .rev()
            .find_map(|e| match e {
                IrcEvent::MemberList { members, .. } => Some(members.clone()),
                _ => None,
            })
            .expect("member list should be refreshed");
        let bob = members.iter().find(|m| m.nick == "bob").unwrap();
        assert_eq!(
            bob.prefix.as_deref(),
            Some("@"),
            "bob was opped, not the mask"
        );
    }

    #[test]
    fn quit_is_reported_once_per_shared_channel() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        feed(&mut actor, &mut outgoing, ":ddirc!u@h JOIN #second");
        feed(&mut actor, &mut outgoing, ":alice!u@h JOIN #second");
        drain(&mut rx);

        feed(&mut actor, &mut outgoing, ":alice!u@h QUIT :Ping timeout");

        let mut channels: Vec<String> = drain(&mut rx)
            .into_iter()
            .filter_map(|e| match e {
                IrcEvent::Quit {
                    channel, reason, ..
                } => {
                    assert_eq!(reason.as_deref(), Some("Ping timeout"));
                    Some(channel)
                }
                _ => None,
            })
            .collect();
        channels.sort();
        assert_eq!(channels, vec!["#second", "#test"]);
    }

    #[test]
    fn nick_change_is_reported_and_privileges_follow() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(&mut actor, &mut outgoing, ":alice!u@h NICK alice2");

        let events = drain(&mut rx);
        assert!(events.iter().any(|e| matches!(
            e,
            IrcEvent::NickChanged { old, new, is_self: false, .. }
                if old == "alice" && new == "alice2"
        )));
        let chan = actor.session.channel("#test").unwrap();
        assert!(chan.member("alice2").unwrap().prefixes.contains(&'@'));
    }

    #[test]
    fn topic_is_stripped_of_control_codes() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h TOPIC #test :\u{03}04red\u{0F} topic",
        );

        let topic = drain(&mut rx)
            .into_iter()
            .find_map(|e| match e {
                IrcEvent::TopicChanged { topic, set_by, .. } => {
                    assert_eq!(set_by.as_deref(), Some("alice"));
                    Some(topic)
                }
                _ => None,
            })
            .expect("expected a TopicChanged event");
        assert_eq!(topic, "red topic");
    }

    #[test]
    fn network_name_is_reported_when_isupport_arrives() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);

        // ISUPPORT arrives after the welcome numeric, so the name is not known
        // at registration — it has to be reported when it actually shows up.
        feed(
            &mut actor,
            &mut outgoing,
            ":srv 005 ddirc NETWORK=Snoonet :are supported",
        );
        let events = drain(&mut rx);
        assert!(
            events.iter().any(|e| matches!(
                e,
                IrcEvent::NetworkNamed { network } if network == "Snoonet"
            )),
            "got {events:?}"
        );

        // A second ISUPPORT line repeating the same name says nothing new.
        feed(
            &mut actor,
            &mut outgoing,
            ":srv 005 ddirc NETWORK=Snoonet CHANTYPES=# :are supported",
        );
        assert!(
            !drain(&mut rx)
                .iter()
                .any(|e| matches!(e, IrcEvent::NetworkNamed { .. })),
            "the same name must not be re-announced per ISUPPORT line"
        );
    }

    #[test]
    fn topic_is_flattened_to_a_single_protocol_line() {
        let (mut actor, _rx, mut outgoing) = actor(&[]);

        // A pasted multi-line topic must not become two TOPIC commands: the
        // second would silently overwrite the first, so the user would keep
        // only the tail of what they typed.
        actor.queue(
            &mut outgoing,
            ClientCommand::SetTopic {
                channel: "#test".to_owned(),
                topic: "  first line\r\nsecond line\u{0}  ".to_owned(),
            },
        );

        assert_eq!(
            outgoing.pop_front(),
            Some(Irc::TOPIC(
                "#test".to_owned(),
                Some("first line  second line".to_owned())
            ))
        );
        assert!(outgoing.is_empty());
    }

    #[test]
    fn topic_is_bounded_before_it_reaches_the_wire() {
        let (mut actor, _rx, mut outgoing) = actor(&[]);
        actor.queue(
            &mut outgoing,
            ClientCommand::SetTopic {
                channel: "#test".to_owned(),
                topic: "t".repeat(limits::MAX_TOPIC * 2),
            },
        );

        let Some(Irc::TOPIC(_, Some(topic))) = outgoing.pop_front() else {
            panic!("expected a TOPIC command");
        };
        assert_eq!(topic.chars().count(), limits::MAX_TOPIC);
    }

    #[test]
    fn error_numerics_surface_as_non_fatal_errors() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        feed(
            &mut actor,
            &mut outgoing,
            ":srv 433 * ddirc :Nickname is already in use",
        );

        let events = drain(&mut rx);
        assert!(
            events.iter().any(|e| matches!(
                e,
                IrcEvent::Error { message, fatal: false } if message.contains("already in use")
            )),
            "got {events:?}"
        );
    }

    #[test]
    fn sent_messages_are_echoed_back_to_the_ui() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        actor.queue(
            &mut outgoing,
            ClientCommand::SendMessage {
                target: "#test".to_owned(),
                text: "hello everyone".to_owned(),
            },
        );

        // IRC never sends our own PRIVMSG back, so without the local echo the
        // sender would see nothing at all.
        let message = drain(&mut rx)
            .into_iter()
            .find_map(|e| match e {
                IrcEvent::Message(m) => Some(*m),
                _ => None,
            })
            .expect("own message should be echoed");

        assert!(
            message.is_self,
            "must be flagged as ours so the UI aligns it"
        );
        assert!(
            !message.is_mention,
            "own nick in own message is not a mention"
        );
        assert_eq!(message.sender, "ddirc");
        assert_eq!(message.target, Target::Channel("#test".to_owned()));
        let text: String = message.spans.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(text, "hello everyone");

        // The message must still actually be sent, not merely echoed.
        assert_eq!(
            outgoing.pop_front(),
            Some(Irc::PRIVMSG(
                "#test".to_owned(),
                "hello everyone".to_owned()
            ))
        );
    }

    #[test]
    fn echoed_action_is_marked_and_sent_as_ctcp() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        actor.queue(
            &mut outgoing,
            ClientCommand::SendAction {
                target: "#test".to_owned(),
                text: "waves".to_owned(),
            },
        );

        let message = drain(&mut rx)
            .into_iter()
            .find_map(|e| match e {
                IrcEvent::Message(m) => Some(*m),
                _ => None,
            })
            .expect("own action should be echoed");
        assert!(message.is_action && message.is_self);
        // The echo carries the bare text; the CTCP wrapper is wire-only.
        let text: String = message.spans.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(text, "waves");

        assert_eq!(
            outgoing.pop_front(),
            Some(Irc::PRIVMSG(
                "#test".to_owned(),
                "\u{01}ACTION waves\u{01}".to_owned()
            ))
        );
    }

    #[test]
    fn echo_to_a_non_channel_target_is_a_direct_message() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        actor.queue(
            &mut outgoing,
            ClientCommand::SendMessage {
                target: "alice".to_owned(),
                text: "psst".to_owned(),
            },
        );

        let message = drain(&mut rx)
            .into_iter()
            .find_map(|e| match e {
                IrcEvent::Message(m) => Some(*m),
                _ => None,
            })
            .expect("own DM should be echoed");
        assert_eq!(message.target, Target::Direct("alice".to_owned()));
    }

    #[test]
    fn a_join_for_an_unknown_channel_does_not_create_state() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        // We never joined #elsewhere, so a JOIN there is server noise or an
        // attempt to grow our state; it must be ignored.
        feed(&mut actor, &mut outgoing, ":stranger!u@h JOIN #elsewhere");

        assert!(actor.session.channel("#elsewhere").is_none());
        assert!(drain(&mut rx).is_empty(), "no event for an unknown channel");
    }

    #[test]
    fn error_numerics_are_recognised() {
        assert!(is_error_numeric(Response::ERR_NOSUCHNICK));
        assert!(is_error_numeric(Response::ERR_NICKNAMEINUSE));
        assert!(!is_error_numeric(Response::RPL_WELCOME));
        assert!(!is_error_numeric(Response::RPL_TOPIC));
    }
}
