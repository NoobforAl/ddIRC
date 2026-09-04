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

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use irc::client::data::ProxyType;
use irc::client::prelude::Config as IrcConfig;
use irc::client::Client;
use irc::proto::{ChannelMode, Command as Irc, Message, Mode, Response};
use tokio::sync::mpsc;
use tokio::time::sleep;
use zeroize::Zeroizing;

use crate::api::events::IrcEvent;
use crate::api::types::{
    AuthOutcome, ChannelListing, ChatMessage, ConfigError, ConnectionStatus, MemberView,
    ServerConfig, Target,
};
use crate::conn::diagnose;
use crate::conn::ratelimit::{ReceiveLimiter, SendLimiter};
use crate::conn::reconnect::Backoff;
use crate::conn::sasl::{Credentials, NotAttempted, SaslNegotiator, SaslOutcome};
use crate::dcc::transfer::{self, Progress, TransferError, TransferEvent};
use crate::dcc::DccOffer;
use crate::state::{limits, truncate, Session};
use crate::text::format;

/// How many channels a `LIST` keeps, and they are the busiest ones.
///
/// A directory is for choosing from, and nobody chooses from fifty thousand.
/// The cap is also what makes the answer bounded in memory on a network whose
/// full list is measured in megabytes.
pub const MAX_LIST_KEPT: usize = 100;

/// How many `LIST` replies the core will read before deciding the answer is
/// unreasonable and reporting what it has.
///
/// Not a limit anyone should reach: it exists so that a server which answers
/// `LIST` with an endless stream cannot hold a connection reading it for ever.
const MAX_LIST_REPLIES: u32 = 60_000;

/// How often a `LIST` still in progress reports what it has so far.
///
/// Often enough that a browser fills in while the answer is still arriving,
/// rarely enough that the interim reports are not themselves the flood.
const LIST_PROGRESS_EVERY: u32 = 2_000;

/// How many events may queue up before we start dropping them. Generous enough
/// to absorb a netsplit burst; bounded so a stalled UI cannot exhaust memory.
const EVENT_QUEUE: usize = 1024;

/// Cap on a single outgoing message, below the 512-byte IRC line limit with
/// room for the command envelope the server adds.
const MAX_MESSAGE_CHARS: usize = 400;

/// How long capability negotiation may take before it is abandoned.
///
/// Matched to the grace the local server gives a client to register
/// (`REGISTRATION_GRACE`), because it is the same question asked from the other
/// end of the socket. Generous by design: it exists to catch a server that has
/// stopped answering, not to hurry a slow one.
const CAP_NEGOTIATION_TIMEOUT: Duration = Duration::from_secs(30);

/// How many times to try a connection that has never once worked.
///
/// Automatic reconnection earns its place for a connection that *was* working:
/// a tunnel, a handoff between Wi-Fi and cellular, a server bouncing. Resuming
/// those without being asked is the whole point.
///
/// A connection that has never registered is a different thing. A wrong
/// address, a firewall, a proxy that cannot reach the host — retrying those
/// every five minutes for ever is not persistence, it is a loop nobody asked
/// for that goes on producing "reconnecting" while the reason it failed sits
/// unread. So the first connection gets a few attempts, which covers a laptop
/// whose network is not up yet at launch, and then stops and waits to be
/// asked.
///
/// Three, with the default backoff, is roughly fourteen seconds of trying.
const MAX_ATTEMPTS_BEFORE_FIRST_SUCCESS: u32 = 3;

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
    /// Ask the server what channels it has.
    ///
    /// One request at a time: a second while one is in flight is ignored
    /// rather than queued, because the answer is the same answer and asking
    /// twice would double a burst that is already the largest thing this
    /// connection ever receives.
    ListChannels,

    /// Stop waiting out the backoff and attempt the next connection now.
    ///
    /// Only meaningful while reconnecting; ignored at any other time, which is
    /// what makes it safe to fire from a button the user may hit just as the
    /// connection comes back on its own.
    ///
    /// Deliberately *not* a reset of the backoff. The delay measures how
    /// unhealthy the server has been, and an impatient click does not make it
    /// healthier — skipping the remaining wait is what was asked for, and
    /// pretending the earlier failures never happened is not. When the attempt
    /// does succeed the backoff resets on registration anyway, so nothing is
    /// lost by keeping it.
    Reconnect,
    /// Disconnect and stop reconnecting.
    Disconnect {
        reason: Option<String>,
    },

    /// Offer a file to someone, over DCC.
    ///
    /// The path is read by the core, not the UI: a file streamed from disk is
    /// never held whole in memory and never crosses the FFI boundary.
    SendFile {
        target: String,
        path: String,
    },

    /// Take up an offer that arrived, saving it into `directory`.
    ///
    /// Refers to the offer by the id it was announced with rather than by its
    /// contents, so the UI never hands back an address a stranger chose — the
    /// core answers only offers it parsed itself.
    AcceptFile {
        id: u64,
        directory: String,
    },

    /// Stop a transfer, or decline an offer that has not started.
    CancelTransfer {
        id: u64,
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
    /// Whether this connection has ever completed registration.
    ///
    /// The difference between "reconnect me automatically" and "tell me it did
    /// not work". Set once and never cleared: a network that worked this
    /// morning is one worth resuming this afternoon, however long it has been
    /// down in between.
    ever_registered: bool,
    /// Offers and transfers, by the id they were announced with.
    transfers: Transfers,
    /// The `LIST` currently being answered, if any.
    ///
    /// `Some` from the moment the request goes out until the server says it
    /// has finished, and it is what makes the reply burst distinguishable from
    /// a flood: nothing else on this connection is both enormous and asked
    /// for.
    listing: Option<Listing>,
}

/// A `LIST` in progress: the best of what has arrived, and how much has.
#[derive(Default)]
struct Listing {
    /// Kept sorted-and-truncated lazily rather than on every reply — see
    /// [`Listing::push`].
    kept: Vec<ChannelListing>,
    /// Replies seen, including the ones thrown away. Drives both the progress
    /// reports and the hard stop.
    seen: u32,
    /// True once anything has been discarded, so the UI can say so.
    truncated: bool,
    /// [`Self::seen`] at the last progress report.
    reported_at: u32,
}

impl Listing {
    /// Take one reply, keeping the busiest [`MAX_LIST_KEPT`] of everything
    /// seen so far.
    ///
    /// Sorted only when the buffer has grown to twice the cap rather than on
    /// every reply: the answer arrives at thousands of lines a second, and
    /// sorting a hundred entries per line would be the expensive part of
    /// reading it. Amortised, this is one comparison-sort per cap-worth of
    /// replies.
    fn push(&mut self, entry: ChannelListing) {
        self.seen = self.seen.saturating_add(1);
        self.kept.push(entry);
        if self.kept.len() >= MAX_LIST_KEPT * 2 {
            self.compact();
        }
    }

    fn compact(&mut self) {
        // Descending by population, then by name so that two equally busy
        // channels do not swap places between one report and the next.
        self.kept
            .sort_by(|a, b| b.users.cmp(&a.users).then_with(|| a.name.cmp(&b.name)));
        if self.kept.len() > MAX_LIST_KEPT {
            self.kept.truncate(MAX_LIST_KEPT);
            self.truncated = true;
        }
    }

    /// What to send the UI now.
    fn snapshot(&mut self) -> Vec<ChannelListing> {
        self.compact();
        self.kept.clone()
    }
}

/// Offers waiting for an answer, and transfers already running.
///
/// Kept on the actor rather than inside the transfer module because the ids
/// are the vocabulary the UI speaks: an offer is announced with one, accepted
/// by one, and cancelled by one. The transfers themselves run as their own
/// tasks and are only reachable from here through their cancel channel.
#[derive(Default)]
struct Transfers {
    next_id: u64,
    /// Announced, not yet answered. Holds the offer so accepting never has to
    /// take one back from the UI.
    offers: HashMap<u64, PendingOffer>,
    /// Running, and how to stop each one.
    running: HashMap<u64, mpsc::Sender<()>>,
}

struct PendingOffer {
    channel: String,
    offer: DccOffer,
}

impl Transfers {
    fn next(&mut self) -> u64 {
        self.next_id = self.next_id.wrapping_add(1);
        self.next_id
    }
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
            ever_registered: false,
            transfers: Transfers::default(),
            listing: None,
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

    /// Put a failed attempt into words, naming the server it was about.
    ///
    /// Never `error.to_string()`: for the commonest failures the `irc` crate's
    /// own message is "an io error occurred", which tells the user nothing and
    /// drops the cause on the floor. See [`diagnose`].
    fn describe(&self, error: &ConnectionError) -> String {
        match error {
            ConnectionError::Irc(irc) => diagnose::explain(irc, &self.config),
            other => diagnose::chain(other),
        }
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
                Err(error) => Disposition::Lost(self.describe(&error)),
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

            // Stop, rather than retry, when nothing has ever worked here and
            // the patience above is spent. The actor deliberately stays alive:
            // exiting would close the command channel and take the UI's own
            // "Try again" with it, which is the one thing the user is being
            // asked to do.
            if !self.ever_registered && backoff.attempt() >= MAX_ATTEMPTS_BEFORE_FIRST_SUCCESS {
                self.status(ConnectionStatus::Disconnected, Some(reason));
                loop {
                    match commands.recv().await {
                        Some(ClientCommand::Reconnect) => break,
                        Some(ClientCommand::Disconnect { .. }) | None => {
                            self.status(ConnectionStatus::Disconnected, None);
                            return;
                        }
                        // Anything else has nowhere to go while offline.
                        Some(_) => {}
                    }
                }
                // Asked for by hand, so the delays start over rather than
                // resuming at the five minutes the last attempt had reached.
                backoff.reset();
                continue;
            }

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

            // Stay responsive while waiting out the backoff. Exactly two
            // things end the wait early: giving up, and being told to hurry.
            //
            // The loop matters. Without it any other command — a message typed
            // while offline — fell out of the `select!` and dropped straight
            // into the next connection attempt, skipping the rest of the delay
            // that the backoff exists to impose.
            let wake = sleep(delay);
            tokio::pin!(wake);
            loop {
                tokio::select! {
                    () = &mut wake => break,
                    command = commands.recv() => match command {
                        Some(ClientCommand::Disconnect { .. }) | None => {
                            self.status(ConnectionStatus::Disconnected, None);
                            return;
                        }
                        Some(ClientCommand::Reconnect) => break,
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

        // Capability negotiation is the one exchange here where the server sets
        // the pace and nothing bounds it: `CAP LS 302` goes out unconditionally
        // and a server that simply never answers it holds the connection at
        // "Registering" for as long as it cares to. This is that bound, and it
        // is the same 30 seconds the local server grants a client of its own.
        let negotiation_deadline = sleep(CAP_NEGOTIATION_TIMEOUT);
        tokio::pin!(negotiation_deadline);

        loop {
            // Arm a timer only when something is waiting to go out, so a quiet
            // client never wakes up needlessly.
            let flush_in = (!outgoing.is_empty()).then(|| send_limiter.wait_time(Instant::now()));

            tokio::select! {
                biased;

                // Out of patience with negotiation. Close it and let
                // registration finish unauthenticated: the connection is not at
                // fault, the capability exchange is, and dropping the one over
                // the other would cost the user a working connection they could
                // have had. Disabled once negotiation ends, by whichever route,
                // so this fires at most once.
                () = &mut negotiation_deadline, if !sasl.is_finished() => {
                    let step = sasl.abandon();
                    for command in step.send {
                        sender.send(command)?;
                    }
                    if let Some(outcome) = step.outcome {
                        auth = self.auth_outcome(outcome);
                    }
                }

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
                    // The file commands are handled here rather than in
                    // `queue` because two of them are async — binding a port
                    // and asking the routing table for an address — and
                    // because only one of the three produces a protocol
                    // message at all.
                    match command {
                        ClientCommand::SendFile { target, path } => {
                            self.send_file(&mut outgoing, target, path).await;
                        }
                        ClientCommand::AcceptFile { id, directory } => {
                            self.accept_file(id, directory);
                        }
                        ClientCommand::CancelTransfer { id } => {
                            self.cancel_transfer(id);
                        }
                        other => self.queue(&mut outgoing, other),
                    }
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

                    // The answer to our own `LIST` is exempt from flood
                    // protection, and only while we are waiting for one.
                    //
                    // The limiter exists to bound what a server or another
                    // user can push at us unasked. A directory we requested is
                    // neither: it is one reply that happens to arrive as fifty
                    // thousand lines, and metering it would mean discarding
                    // most of the answer and then reporting the loss as a
                    // flood. What bounds it instead is `MAX_LIST_REPLIES`,
                    // after which the exemption ends with the request.
                    let asked_for = self.listing.is_some() && is_list_reply(&message);
                    if !asked_for && !self.recv_limiter.admit(Instant::now()) {
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
    ///
    /// The proxy, when there is one, wraps the socket *below* TLS: the crate
    /// opens the SOCKS5 tunnel first and then performs the handshake through
    /// it, against `server`. Verification and SNI are unchanged, so the proxy
    /// carries ciphertext it cannot read and cannot substitute itself for the
    /// server. And there is no direct-connection fallback anywhere on this
    /// path — a proxy that cannot be reached is a connection that fails.
    fn irc_config(&self) -> IrcConfig {
        let proxy = self.config.proxy.as_ref();
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
            proxy_type: Some(match proxy {
                Some(_) => ProxyType::Socks5,
                None => ProxyType::None,
            }),
            proxy_server: proxy.map(|p| p.host.clone()),
            proxy_port: proxy.map(|p| p.port),
            proxy_username: proxy.and_then(|p| p.username.clone()),
            // The crate's config field is a plain `String`, so this copy is not
            // zeroized on drop the way ours is. Unavoidable without vendoring
            // the crate, and the same is already true of the server password we
            // hand to `PASS`; noted rather than papered over.
            proxy_password: proxy.and_then(|p| p.password.as_ref().map(|s| s.to_string())),
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
            ClientCommand::ListChannels => {
                // Ignored while one is already running. See the variant.
                if self.listing.is_none() {
                    self.listing = Some(Listing::default());
                    outgoing.push_back(Irc::LIST(None, None));
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
            // Nothing to hurry: the connection this arrived on is up. The
            // button that sends this is only offered while reconnecting, so
            // getting here at all means it raced the connection coming back.
            ClientCommand::Reconnect => {}
            // Handled before reaching the queue.
            ClientCommand::Disconnect { .. } => {}
            // Also handled before reaching the queue: two of the three are
            // async, and only one of them produces a protocol message at all.
            // Listed rather than caught by a wildcard, so that a command added
            // later cannot be silently dropped here.
            ClientCommand::SendFile { .. }
            | ClientCommand::AcceptFile { .. }
            | ClientCommand::CancelTransfer { .. } => {}
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
            // 321: <nick> Channel :Users  Name — the header, which some
            // servers omit entirely. Starting the collection here as well as
            // on the request means a stray one cannot leave the accumulator
            // holding half of a previous answer.
            Irc::Response(Response::RPL_LISTSTART, _) => {
                if let Some(listing) = self.listing.as_mut() {
                    *listing = Listing::default();
                }
            }
            // 322: <nick> <channel> <#visible> :<topic>
            Irc::Response(Response::RPL_LIST, args) => self.on_list_reply(args),
            // 323: <nick> :End of /LIST
            Irc::Response(Response::RPL_LISTEND, _) => self.finish_listing(),
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
                        nick: nick.clone(),
                        is_self,
                    });
                    if is_self {
                        // Our own join is one of the two moments a whole
                        // roster is the right answer: there was nothing there
                        // before it, and `NAMES` is about to replace it anyway.
                        self.emit_member_list(channel);
                    } else {
                        self.emit_member_changed(channel, &nick, &nick);
                    }
                }
            }
            Irc::PART(channel, reason) => {
                let Some(nick) = source else { return };
                let is_self = self.session.is_self(&nick);
                // Taken before the removal, because afterwards there is
                // nothing left to ask how the roster spelled them.
                let filed_as = self
                    .session
                    .known_nick(&nick)
                    .unwrap_or_else(|| nick.clone());
                if self.session.on_part(channel, &nick) {
                    self.emit(IrcEvent::Parted {
                        channel: channel.clone(),
                        nick,
                        is_self,
                        reason: reason.as_deref().map(format::strip),
                    });
                    // Our own part closes the conversation, roster and all, so
                    // there is nobody left to tell about it.
                    if !is_self {
                        self.emit_member_changed(channel, &filed_as, &filed_as);
                    }
                }
            }
            Irc::QUIT(reason) => {
                let Some(nick) = source else { return };
                let reason = reason.as_deref().map(format::strip);
                let filed_as = self
                    .session
                    .known_nick(&nick)
                    .unwrap_or_else(|| nick.clone());
                for channel in self.session.on_quit(&nick) {
                    self.emit(IrcEvent::Quit {
                        channel: channel.clone(),
                        nick: nick.clone(),
                        reason: reason.clone(),
                    });
                    self.emit_member_changed(&channel, &filed_as, &filed_as);
                }
            }
            Irc::NICK(new) => {
                let Some(old) = source else { return };
                let is_self = self.session.is_self(&old);
                let filed_as = self.session.known_nick(&old).unwrap_or_else(|| old.clone());
                for channel in self.session.on_nick_change(&old, new) {
                    self.emit(IrcEvent::NickChanged {
                        channel: channel.clone(),
                        old: old.clone(),
                        new: new.clone(),
                        is_self,
                    });
                    // A rename moves them in the ordering as well as changing
                    // the label, which is why this is the same event an
                    // arrival uses rather than a rename of its own.
                    self.emit_member_changed(&channel, &filed_as, new);
                }
            }
            // Only sent by a server that offered `away-notify` and was taken
            // up on it — see `conn/sasl.rs`. Without the capability nobody is
            // ever told, which is why the away state used to be a field that
            // could not change.
            Irc::AWAY(message) => {
                let Some(nick) = source else { return };
                let away = message.is_some();
                let filed_as = self
                    .session
                    .known_nick(&nick)
                    .unwrap_or_else(|| nick.clone());
                for channel in self.session.set_away(&nick, away) {
                    self.emit_member_changed(&channel, &filed_as, &filed_as);
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

        // From here on, a lost connection is one worth resuming without
        // being asked. See `MAX_ATTEMPTS_BEFORE_FIRST_SUCCESS`.
        self.ever_registered = true;

        self.emit(IrcEvent::Registered {
            nick: self.session.nick().to_owned(),
            network: self.session.isupport.network.clone(),
            auth: auth.clone(),
        });
        self.status(ConnectionStatus::Connected, None);
    }

    /// One `RPL_LIST` line.
    ///
    /// Ignored outright when no `LIST` is in flight. A server is free to send
    /// these unprompted, and an unprompted directory is not something the user
    /// asked to see.
    fn on_list_reply(&mut self, args: &[String]) {
        let Some(listing) = self.listing.as_mut() else {
            return;
        };
        // Past the point where reading more could be doing anyone a favour.
        if listing.seen >= MAX_LIST_REPLIES {
            listing.truncated = true;
            self.finish_listing();
            return;
        }

        let Some(name) = args.get(1) else { return };
        // A channel with no reported population is not an error — some servers
        // hide the count on secret channels — and zero is the honest reading.
        let users = args.get(2).and_then(|u| u.parse::<u32>().ok()).unwrap_or(0);
        let topic = args.get(3).map(|t| format::strip(t)).unwrap_or_default();

        listing.push(ChannelListing {
            name: name.clone(),
            users,
            topic: truncate(topic.trim(), limits::MAX_TOPIC),
        });

        // Report as it goes, so a browser fills in while the rest is still
        // arriving rather than sitting empty for the length of the answer.
        if listing.seen - listing.reported_at >= LIST_PROGRESS_EVERY {
            listing.reported_at = listing.seen;
            let channels = listing.snapshot();
            let truncated = listing.truncated;
            self.emit(IrcEvent::ChannelList {
                channels,
                done: false,
                truncated,
            });
        }
    }

    /// The server has finished, or we have stopped listening.
    ///
    /// Emits even when nothing was collected: "this server has no channels to
    /// show" is an answer, and a browser left spinning for ever is not.
    fn finish_listing(&mut self) {
        let Some(mut listing) = self.listing.take() else {
            return;
        };
        let channels = listing.snapshot();
        self.emit(IrcEvent::ChannelList {
            channels,
            done: true,
            truncated: listing.truncated,
        });
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
                affected: affected.clone(),
            });
            // One event each rather than the whole roster. Being opped moves
            // someone to the top of the list, which is a move of one row —
            // and `affected` is already the nicks the roster spells them by,
            // since `on_mode` reads them off the members it changed.
            for nick in affected {
                self.emit_member_changed(channel, &nick, &nick);
            }
        }
    }

    /// Handle a CTCP request that is not ACTION.
    ///
    /// Exactly one is recognised — `DCC SEND` — and recognising it means
    /// emitting an event, not replying and not connecting. Everything else is
    /// dropped in silence, which is the existing policy and the reason this
    /// client cannot be made to report its version, its uptime or its
    /// timezone to anyone who asks.
    ///
    /// A NOTICE is never a request, so a `DCC` arriving in one is ignored:
    /// answering a NOTICE is how two clients get into a loop, and the reply to
    /// a CTCP request is itself a NOTICE.
    fn on_ctcp(&mut self, target: &str, body: &str, sender: &str, is_notice: bool) {
        if is_notice {
            return;
        }
        let Some(offer) = crate::dcc::offer::parse_send(body) else {
            return;
        };

        // Routed to where the offer arrived: a channel, or the conversation
        // with whoever sent it. An offer shown somewhere other than where it
        // was made would leave no way to tell who is asking.
        let channel = if self.session.is_self(target) {
            sender.to_owned()
        } else {
            target.to_owned()
        };

        // Remembered here so that accepting can name the offer rather than
        // describe it. The UI never gets to hand an address back to the core —
        // it answers an offer the core parsed, or it answers nothing.
        let id = self.transfers.next();
        self.transfers.offers.insert(
            id,
            PendingOffer {
                channel: channel.clone(),
                offer: offer.clone(),
            },
        );

        self.emit(IrcEvent::FileOffered {
            id,
            channel,
            from: sender.to_owned(),
            offer: Box::new(offer),
        });
    }

    /// Take up an offer that arrived.
    ///
    /// The transfer runs as its own task: a file takes minutes, and the IRC
    /// socket has to go on answering pings throughout.
    fn accept_file(&mut self, id: u64, directory: String) {
        let Some(pending) = self.transfers.offers.remove(&id) else {
            // Already answered, or left over from a previous connection.
            // Silence is right: nothing was promised and nothing is owed.
            return;
        };

        let (cancel_tx, mut cancel_rx) = mpsc::channel(1);
        self.transfers.running.insert(id, cancel_tx);

        let events = self.events.clone();
        let proxy = self.config.proxy.clone();
        let channel = pending.channel;
        let filename = pending.offer.filename.clone();
        let offer = pending.offer;

        tokio::spawn(async move {
            let started = IrcEvent::FileTransferStarted {
                id,
                channel: channel.clone(),
                filename: filename.clone(),
                incoming: true,
                total: offer.size,
            };
            if events.send(started).await.is_err() {
                return;
            }

            let (progress, forwarder) = forward_progress(events.clone(), id);
            let result = transfer::accept(
                &offer,
                std::path::Path::new(&directory),
                proxy.as_ref(),
                progress,
                &mut cancel_rx,
            )
            .await;
            forwarder.abort();

            let _ = events
                .send(ended(
                    id,
                    channel,
                    filename,
                    result.map(|path| Some(path.to_string_lossy().into_owned())),
                ))
                .await;
        });
    }

    /// Offer a file to someone, and serve it when they take it up.
    ///
    /// Async, and answered from the actor rather than from the spawned task,
    /// because the offer itself is an IRC message: it has to go out on the
    /// connection's own sender, in order, behind the same rate limiter as
    /// everything else. Only the serving is spawned.
    async fn send_file(&mut self, outgoing: &mut VecDeque<Irc>, target: String, path: String) {
        let id = self.transfers.next();
        let filename = PathBuf::from(&path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "file".to_owned());

        // The rule this whole module exists to keep. Behind a proxy a normal
        // offer would publish the address the proxy is there to hide, and the
        // honest alternative — a reverse offer, where they listen and we dial
        // out through the proxy — is not built yet. Refusing is the only
        // remaining answer that does not quietly undo the setting.
        if self.config.proxy.is_some() {
            self.emit(ended(
                id,
                target,
                filename,
                Err(TransferError::WouldDiscloseAddressBySending),
            ));
            return;
        }

        let prepared = async {
            let size = tokio::fs::metadata(&path).await?.len();
            if size > transfer::MAX_TRANSFER_BYTES {
                return Err(TransferError::TooLarge(
                    transfer::MAX_TRANSFER_BYTES / (1024 * 1024 * 1024),
                ));
            }
            let advertised = transfer::routable_address(&self.config.host)
                .await
                .ok_or(TransferError::NoRoutableAddress)?;
            let (listener, listening) = transfer::listen().await?;
            Ok::<_, TransferError>((size, advertised, listener, listening))
        }
        .await;

        let (size, advertised, listener, listening) = match prepared {
            Ok(parts) => parts,
            Err(e) => {
                self.emit(ended(id, target, filename, Err(e)));
                return;
            }
        };

        outgoing.push_back(Irc::PRIVMSG(
            target.clone(),
            format!(
                "\u{01}DCC SEND {} {} {} {}\u{01}",
                transfer::quote_filename(&filename),
                advertised,
                listening.port,
                size
            ),
        ));

        self.emit(IrcEvent::FileTransferStarted {
            id,
            channel: target.clone(),
            filename: filename.clone(),
            incoming: false,
            total: Some(size),
        });

        let (cancel_tx, mut cancel_rx) = mpsc::channel(1);
        self.transfers.running.insert(id, cancel_tx);
        let events = self.events.clone();

        tokio::spawn(async move {
            let (progress, forwarder) = forward_progress(events.clone(), id);
            let result = transfer::serve(
                listener,
                std::path::Path::new(&path),
                progress,
                &mut cancel_rx,
            )
            .await;
            forwarder.abort();

            let _ = events
                .send(ended(id, target, filename, result.map(|_| None)))
                .await;
        });
    }

    /// Stop a transfer, or turn down an offer that never started.
    fn cancel_transfer(&mut self, id: u64) {
        // An offer declined before it began needs no task stopped and no event
        // sent. Nothing was ever said to the other side, which is exactly what
        // "reported, never answered" buys: declining is silent.
        self.transfers.offers.remove(&id);
        if let Some(cancel) = self.transfers.running.remove(&id) {
            let _ = cancel.try_send(());
        }
    }

    /// Handle a PRIVMSG or NOTICE.
    fn on_chat(&mut self, target: &str, text: &str, source: Option<String>, is_notice: bool) {
        let Some(sender) = source else { return };

        // CTCP ACTION is "\x01ACTION <text>\x01"; other CTCP requests are not
        // chat and are deliberately ignored rather than answered, so the client
        // cannot be used to leak version or timezone information.
        //
        // DCC is the one exception, and it is not an exception to that rule:
        // an offer is reported, never answered. Nothing is sent back and no
        // connection is made — the user decides, because accepting means
        // dialling an address a stranger chose.
        let trimmed = text.trim_matches('\u{01}');
        let (body, is_action) = match trimmed.strip_prefix("ACTION ") {
            Some(rest) => (rest, true),
            None if text.starts_with('\u{01}') => {
                self.on_ctcp(target, trimmed, &sender, is_notice);
                return;
            }
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

    /// One member of one channel, as the UI holds them.
    ///
    /// `None` when they are not in that channel, which is the ordinary answer
    /// for someone who has just left and the reason a departure carries no
    /// member at all.
    fn member_view(&self, channel: &str, nick: &str) -> Option<MemberView> {
        let prefixes = &self.session.isupport.prefixes;
        let key = self.session.isupport.casemapping.normalize(nick);
        let member = self.session.channel(channel)?.member(&key)?;
        Some(MemberView {
            nick: member.nick.clone(),
            prefix: member.display_prefix(prefixes).map(|p| p.to_string()),
            away: member.away,
            sort_key: member.sort_key(prefixes),
        })
    }

    /// Tell the UI about one person, in one channel.
    ///
    /// `previous` is the nick the roster has them filed under and `nick` the
    /// one to look up now — the same string except in a rename, which is the
    /// whole reason the two are separate.
    fn emit_member_changed(&mut self, channel: &str, previous: &str, nick: &str) {
        let member = self.member_view(channel, nick);
        // A channel we are not in has no roster to correct, and a departure
        // from one is not news. `member_view` returning `None` is meaningful
        // for someone who left a channel we *are* in, so the two are told
        // apart here rather than by the absence of a member.
        if member.is_none() && self.session.channel(channel).is_none() {
            return;
        }
        self.emit(IrcEvent::MemberChanged {
            channel: channel.to_owned(),
            previous: previous.to_owned(),
            member,
        });
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
                sort_key: m.sort_key(prefixes),
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

/// True for the three numerics that make up the answer to a `LIST`.
///
/// Kept next to the flood limiter's only exemption, because that is the one
/// thing it decides: which lines are allowed to arrive faster than a person
/// could have caused them.
fn is_list_reply(message: &Message) -> bool {
    matches!(
        message.command,
        Irc::Response(
            Response::RPL_LISTSTART | Response::RPL_LIST | Response::RPL_LISTEND,
            _
        )
    )
}

/// True for numerics that represent an error worth surfacing.
fn is_error_numeric(response: Response) -> bool {
    let code = response as u16;
    (400..600).contains(&code)
}

/// Forward a transfer's own progress onto the connection's event stream.
///
/// Two channels rather than one because the transfer module knows nothing
/// about `IrcEvent` — it reports bytes, and this puts an id on them. The
/// returned handle is aborted when the transfer ends, which is what stops the
/// forwarder rather than leaving a task per transfer alive for ever.
fn forward_progress(
    events: mpsc::Sender<IrcEvent>,
    id: u64,
) -> (Progress, tokio::task::JoinHandle<()>) {
    let (tx, mut rx) = mpsc::channel(32);
    let handle = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            let mapped = match event {
                // The start is announced by the actor, which knows the
                // filename and the direction; the transfer's own `Started` is
                // the same news arriving later and carrying less of it.
                TransferEvent::Started { .. } => continue,
                TransferEvent::Progress { transferred } => {
                    IrcEvent::FileTransferProgress { id, transferred }
                }
            };
            // Dropped rather than awaited: a progress number nobody read is
            // worth nothing, and blocking here would stall the transfer it
            // describes.
            let _ = events.try_send(mapped);
        }
    });
    (Progress::new(tx), handle)
}

/// The one event both outcomes of a transfer produce.
fn ended(
    id: u64,
    channel: String,
    filename: String,
    result: Result<Option<String>, TransferError>,
) -> IrcEvent {
    match result {
        Ok(path) => IrcEvent::FileTransferEnded {
            id,
            channel,
            filename,
            path,
            error: None,
        },
        Err(e) => IrcEvent::FileTransferEnded {
            id,
            channel,
            filename,
            path: None,
            error: Some(e.to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

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
    // The reconnect command.
    //
    // These drive the real `run` loop against a closed loopback port, so the
    // first attempt is refused immediately and the actor lands in its backoff
    // wait — which is the state the whole feature is about. No DNS, no socket
    // that stays open, and nothing that depends on the network.
    // ---------------------------------------------------------------------

    /// A port with nothing on it, so connecting is refused rather than hanging.
    ///
    /// Bound and dropped rather than picked out of the air: a hardcoded port is
    /// a test that fails on whichever machine happens to be using it.
    fn closed_port() -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind a free port");
        let port = listener.local_addr().expect("read the bound port").port();
        drop(listener);
        port
    }

    fn failing_actor() -> (ConnectionHandle, mpsc::Receiver<IrcEvent>) {
        spawn(ServerConfig {
            host: "127.0.0.1".to_owned(),
            port: closed_port(),
            nickname: "ddirc".to_owned(),
            ..Default::default()
        })
    }

    /// Wait for the actor to reach its backoff wait, returning the delay it
    /// announced.
    async fn wait_for_backoff(rx: &mut mpsc::Receiver<IrcEvent>) -> u64 {
        loop {
            let event = tokio::time::timeout(Duration::from_secs(10), rx.recv())
                .await
                .expect("the actor should reach backoff")
                .expect("the actor should still be running");
            if let IrcEvent::Status {
                status: ConnectionStatus::Reconnecting { retry_in_secs, .. },
                ..
            } = event
            {
                return retry_in_secs;
            }
        }
    }

    /// Whether another connection attempt begins within `window`.
    async fn attempts_again(rx: &mut mpsc::Receiver<IrcEvent>, window: Duration) -> bool {
        let deadline = tokio::time::Instant::now() + window;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return false;
            }
            match tokio::time::timeout(remaining, rx.recv()).await {
                Err(_) => return false,
                Ok(None) => return false,
                Ok(Some(IrcEvent::Status {
                    status: ConnectionStatus::Connecting,
                    ..
                })) => return true,
                Ok(Some(_)) => {}
            }
        }
    }

    /// Wait until the actor stops trying, returning the reason it gave.
    ///
    /// Distinguished from the backoff wait by the status: `Reconnecting` means
    /// it intends to try again, `Disconnected` means it has stopped and is
    /// waiting to be asked.
    async fn wait_for_giving_up(rx: &mut mpsc::Receiver<IrcEvent>) -> String {
        loop {
            let event = tokio::time::timeout(Duration::from_secs(30), rx.recv())
                .await
                .expect("the actor should give up")
                .expect("the actor should still be running");
            if let IrcEvent::Status {
                status: ConnectionStatus::Disconnected,
                detail,
            } = event
            {
                return detail.unwrap_or_default();
            }
        }
    }

    /// A connection that has never worked stops asking, rather than retrying a
    /// wrong address every five minutes for the rest of the session.
    #[tokio::test]
    async fn a_connection_that_never_worked_gives_up_and_waits() {
        // Held, not dropped: releasing the handle closes the command channel,
        // which ends the actor and would make this pass for the wrong reason.
        let (_handle, mut rx) = failing_actor();

        let reason = wait_for_giving_up(&mut rx).await;
        assert!(
            !reason.is_empty(),
            "giving up should say why, or the user has nothing to act on"
        );

        // And it must stay silent afterwards. This is the actual complaint:
        // attempts continuing without anybody asking for them.
        assert!(
            !attempts_again(&mut rx, Duration::from_secs(2)).await,
            "it must not keep trying once it has given up"
        );
    }

    /// Giving up must not take the way back with it.
    ///
    /// The actor stays alive on purpose: returning would close the command
    /// channel, and the UI's "Try again" button sends a command down it. A
    /// version of this that exited would look correct and leave the user with
    /// a button that does nothing.
    #[tokio::test]
    async fn giving_up_still_answers_the_retry_button() {
        let (handle, mut rx) = failing_actor();
        wait_for_giving_up(&mut rx).await;

        handle
            .send(ClientCommand::Reconnect)
            .await
            .expect("the actor must still be listening after giving up");

        assert!(
            attempts_again(&mut rx, Duration::from_secs(2)).await,
            "asking by hand should start another attempt"
        );
    }

    /// And it is still possible to close a session that has given up.
    #[tokio::test]
    async fn a_session_that_gave_up_can_still_be_disconnected() {
        let (handle, mut rx) = failing_actor();
        wait_for_giving_up(&mut rx).await;

        handle
            .send(ClientCommand::Disconnect { reason: None })
            .await
            .expect("the actor must still be listening");

        // The actor ends, which closes the event stream.
        let closed = tokio::time::timeout(Duration::from_secs(5), async {
            while rx.recv().await.is_some() {}
        })
        .await;
        assert!(closed.is_ok(), "disconnect should end the actor");
    }

    #[tokio::test]
    async fn reconnect_cuts_the_wait_short() {
        let (handle, mut rx) = failing_actor();
        let delay = wait_for_backoff(&mut rx).await;
        assert!(delay >= 1, "the backoff should be at least a second");

        handle
            .send(ClientCommand::Reconnect)
            .await
            .expect("the actor should still be listening");

        // Far inside the announced delay: if this passes, the wait was woken
        // rather than merely having elapsed.
        assert!(
            attempts_again(&mut rx, Duration::from_millis(400)).await,
            "reconnect should start the next attempt immediately"
        );
    }

    #[tokio::test]
    async fn an_ordinary_command_does_not_cut_the_wait_short() {
        // The regression this pairs with: every command used to fall out of
        // the select and drop straight into the next attempt, so typing a
        // message while offline skipped the backoff entirely.
        let (handle, mut rx) = failing_actor();
        let delay = wait_for_backoff(&mut rx).await;
        assert!(delay >= 1);

        handle
            .send(ClientCommand::SendMessage {
                target: "#somewhere".to_owned(),
                text: "anyone there?".to_owned(),
            })
            .await
            .expect("the actor should still be listening");

        assert!(
            !attempts_again(&mut rx, Duration::from_millis(400)).await,
            "a message sent while offline must not trigger a reconnect"
        );
    }

    #[tokio::test]
    async fn disconnect_still_ends_the_wait() {
        // The loop added around the select must not trap the actor in it.
        let (handle, mut rx) = failing_actor();
        wait_for_backoff(&mut rx).await;

        handle
            .send(ClientCommand::Disconnect { reason: None })
            .await
            .expect("the actor should still be listening");

        let ended = tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(event) = rx.recv().await {
                if matches!(
                    event,
                    IrcEvent::Status {
                        status: ConnectionStatus::Disconnected,
                        ..
                    }
                ) {
                    return true;
                }
            }
            false
        })
        .await;
        assert_eq!(ended, Ok(true), "disconnect should stop the actor");
    }

    #[test]
    fn reconnect_puts_nothing_on_the_wire() {
        // It is an instruction to the actor, not a protocol command. Reaching
        // `queue` at all means it raced the connection coming back up.
        let (mut actor, _rx, mut outgoing) = actor(&[]);
        actor.queue(&mut outgoing, ClientCommand::Reconnect);
        assert!(outgoing.is_empty());
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

    /// Every `MemberChanged` in `events`, as (previous, the member or `None`).
    fn changes(events: &[IrcEvent]) -> Vec<(String, Option<MemberView>)> {
        events
            .iter()
            .filter_map(|e| match e {
                IrcEvent::MemberChanged {
                    previous, member, ..
                } => Some((previous.clone(), member.clone())),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn someone_arriving_is_one_member_rather_than_a_roster() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(&mut actor, &mut outgoing, ":dave!u@h JOIN #test");

        let events = drain(&mut rx);
        let changed = changes(&events);
        assert_eq!(changed.len(), 1, "{events:?}");
        let (previous, member) = &changed[0];
        assert_eq!(previous, "dave");
        let member = member.as_ref().expect("an arrival carries the member");
        assert_eq!(member.nick, "dave");
        assert!(!member.away);
        // The roster is 883 people in a real channel; it is not sent because
        // one of them arrived.
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, IrcEvent::MemberList { .. })),
            "{events:?}"
        );
    }

    #[test]
    fn leaving_removes_exactly_one_row_and_quitting_removes_it_everywhere() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        feed(&mut actor, &mut outgoing, ":ddirc!u@h JOIN #second");
        feed(&mut actor, &mut outgoing, ":alice!u@h JOIN #second");
        drain(&mut rx);

        feed(&mut actor, &mut outgoing, ":bob!u@h PART #test");
        let changed = changes(&drain(&mut rx));
        assert_eq!(changed, vec![("bob".to_owned(), None)]);

        // A quit is the same shape, once per channel they shared with us.
        feed(&mut actor, &mut outgoing, ":alice!u@h QUIT :Ping timeout");
        let changed = changes(&drain(&mut rx));
        assert_eq!(changed.len(), 2, "{changed:?}");
        assert!(changed
            .iter()
            .all(|(prev, m)| prev == "alice" && m.is_none()));
    }

    #[test]
    fn a_rename_names_the_row_it_replaces() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(&mut actor, &mut outgoing, ":alice!u@h NICK alicia");

        let changed = changes(&drain(&mut rx));
        assert_eq!(changed.len(), 1, "{changed:?}");
        let (previous, member) = &changed[0];
        // The old nick is what the UI has the row filed under; the new one is
        // what goes in its place, at whatever position it now sorts to.
        assert_eq!(previous, "alice");
        let member = member.as_ref().expect("a rename carries the member");
        assert_eq!(member.nick, "alicia");
        assert_eq!(member.prefix.as_deref(), Some("@"), "privileges follow");
    }

    #[test]
    fn a_departure_is_identified_by_the_spelling_the_roster_holds() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        // `NAMES` said `bob`; the PART prefix shouts it. Same person under
        // every casemapping, and the UI only knows the first spelling.
        feed(&mut actor, &mut outgoing, ":BOB!u@h PART #test");

        let changed = changes(&drain(&mut rx));
        assert_eq!(changed, vec![("bob".to_owned(), None)]);
    }

    #[test]
    fn away_reaches_every_channel_shared_with_the_person_who_went_away() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        feed(&mut actor, &mut outgoing, ":ddirc!u@h JOIN #second");
        feed(&mut actor, &mut outgoing, ":alice!u@h JOIN #second");
        drain(&mut rx);

        feed(&mut actor, &mut outgoing, ":alice!u@h AWAY :making tea");
        let changed = changes(&drain(&mut rx));
        assert_eq!(changed.len(), 2, "{changed:?}");
        assert!(changed
            .iter()
            .all(|(prev, m)| prev == "alice" && m.as_ref().is_some_and(|m| m.away)));

        // Back again, and told once more. A repeat of a state already held is
        // not news and is not sent — servers re-announce on reconnects.
        feed(&mut actor, &mut outgoing, ":alice!u@h AWAY");
        let changed = changes(&drain(&mut rx));
        assert_eq!(changed.len(), 2, "{changed:?}");
        assert!(changed
            .iter()
            .all(|(_, m)| m.as_ref().is_some_and(|m| !m.away)));

        feed(&mut actor, &mut outgoing, ":alice!u@h AWAY");
        assert!(changes(&drain(&mut rx)).is_empty(), "nothing changed");
    }

    #[test]
    fn the_sort_key_orders_a_roster_the_way_the_core_does() {
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

        // The whole point of carrying the key: sorting by it alone reproduces
        // the order, so the UI can place one arrival without a second copy of
        // the rule that produced this list.
        let mut by_key = members.clone();
        by_key.sort_by(|a, b| a.sort_key.cmp(&b.sort_key));
        assert_eq!(by_key, members);
        assert!(members.iter().all(|m| !m.sort_key.is_empty()));
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
    fn a_dcc_offer_is_reported_and_never_answered() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h PRIVMSG #test :\u{01}DCC SEND cat.jpg 2130706433 5001 4096\u{01}",
        );

        let events = drain(&mut rx);
        let offered = events
            .iter()
            .find_map(|e| match e {
                IrcEvent::FileOffered {
                    channel,
                    from,
                    offer,
                    ..
                } => Some((channel, from, offer)),
                _ => None,
            })
            .expect("expected a FileOffered event");

        assert_eq!(offered.0, "#test");
        assert_eq!(offered.1, "alice");
        assert_eq!(offered.2.filename, "cat.jpg");
        assert_eq!(offered.2.port, Some(5001));

        // The whole point: nothing was sent back, and no connection was made.
        // An offer is reported so the user can decide, not acted on.
        assert!(outgoing.is_empty(), "no reply was queued");
        // And it is not chat, so it does not appear as something someone said.
        assert!(
            !events.iter().any(|e| matches!(e, IrcEvent::Message(_))),
            "a DCC offer is not a chat line"
        );
    }

    #[test]
    fn a_dcc_offer_in_a_direct_message_belongs_to_the_sender() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h PRIVMSG ddirc :\u{01}DCC SEND f 1 2 3\u{01}",
        );

        let channel = drain(&mut rx)
            .into_iter()
            .find_map(|e| match e {
                IrcEvent::FileOffered { channel, .. } => Some(channel),
                _ => None,
            })
            .expect("expected a FileOffered event");
        // Shown in the conversation with alice, not one named after us.
        assert_eq!(channel, "alice");
    }

    #[test]
    fn a_dcc_offer_in_a_notice_is_ignored() {
        // A NOTICE is never a request, and the reply to a CTCP request is
        // itself a NOTICE — answering one is how two clients start a loop.
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(
            &mut actor,
            &mut outgoing,
            ":alice!u@h NOTICE #test :\u{01}DCC SEND f 1 2 3\u{01}",
        );

        assert!(
            !drain(&mut rx)
                .iter()
                .any(|e| matches!(e, IrcEvent::FileOffered { .. })),
            "a DCC offer in a NOTICE is not an offer"
        );
    }

    #[test]
    fn a_dcc_offer_naming_a_path_is_dropped_rather_than_shown() {
        // `parse_send` refuses a filename that cannot be safely created, and
        // the actor does not paper over that with a blank one: an offer that
        // cannot be accepted is not shown as one that can.
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        joined_channel(&mut actor, &mut outgoing);
        drain(&mut rx);

        feed(
            &mut actor,
            &mut outgoing,
            ":mallory!u@h PRIVMSG #test :\u{01}DCC SEND \"..\" 1 2 3\u{01}",
        );

        assert!(
            !drain(&mut rx)
                .iter()
                .any(|e| matches!(e, IrcEvent::FileOffered { .. })),
            "an unusable filename is not an offer"
        );
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

    /// The `irc` crate must not be built with its `ctcp` feature.
    ///
    /// This is a test about a manifest, which is unusual, and the reason is
    /// that the behaviour it guards cannot be reached from here. With `ctcp`
    /// enabled the crate answers CTCP itself, inside
    /// `ClientStream::poll_next`, using its own `Sender` — so the reply never
    /// touches the actor, never appears in `outgoing`, and the test above
    /// passes while the client is answering `VERSION`, `FINGER` and `TIME` to
    /// anyone who asks. `TIME` is the bad one: it is `Local::now()` as RFC
    /// 2822, which gives away the machine's clock and its UTC offset.
    ///
    /// Catching that needs either a live socket or the manifest. The manifest
    /// is cheaper, is hermetic, and fails with the reason attached.
    #[test]
    fn the_irc_crate_is_not_built_with_its_ctcp_auto_responder() {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("ddirc-core sits inside the workspace")
            .join("Cargo.toml");
        let text = std::fs::read_to_string(&manifest).expect("workspace manifest is readable");

        let line = text
            .lines()
            .find(|l| l.starts_with("irc = "))
            .expect("the workspace still declares the irc dependency");

        assert!(
            !line.contains("\"ctcp\""),
            "the `ctcp` feature is enabled on the irc crate. It does not mean \
             'understand CTCP', it means 'reply to CTCP automatically', and it \
             would make this client disclose its real name, its version and its \
             local time and timezone on request. See the note above it in \
             {}.",
            manifest.display(),
        );
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

        // One member changed, so one member is sent — not the roster. Being
        // opped also moves bob up the ordering, which is why the same event
        // carries a sort key rather than a prefix alone.
        let bob = events
            .iter()
            .rev()
            .find_map(|e| match e {
                IrcEvent::MemberChanged {
                    member: Some(member),
                    ..
                } if member.nick == "bob" => Some(member.clone()),
                _ => None,
            })
            .expect("the opped member should be sent");
        assert_eq!(
            bob.prefix.as_deref(),
            Some("@"),
            "bob was opped, not the mask"
        );
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, IrcEvent::MemberList { .. })),
            "a privilege change is one row, not a whole roster: {events:?}"
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

    // -------------------------------------------------------------- the LIST
    //
    // The directory is the one reply on this connection that arrives faster
    // than a person could have caused it, so most of what is worth pinning
    // here is about *bounding* it: what is kept, what is thrown away, and the
    // fact that none of it happens unless somebody asked.

    /// Send the request the way the UI does, so the actor is in the state a
    /// real answer would arrive into.
    fn start_listing(actor: &mut Actor, outgoing: &mut VecDeque<Irc>) {
        actor.queue(outgoing, ClientCommand::ListChannels);
    }

    fn last_list(rx: &mut mpsc::Receiver<IrcEvent>) -> (Vec<ChannelListing>, bool, bool) {
        drain(rx)
            .into_iter()
            .filter_map(|event| match event {
                IrcEvent::ChannelList {
                    channels,
                    done,
                    truncated,
                } => Some((channels, done, truncated)),
                _ => None,
            })
            .next_back()
            .expect("a LIST should be answered")
    }

    #[test]
    fn asking_sends_one_list_and_ignores_a_second_ask() {
        let (mut actor, _rx, mut outgoing) = actor(&[]);
        start_listing(&mut actor, &mut outgoing);
        start_listing(&mut actor, &mut outgoing);

        // The answer to the second would be the answer to the first, and this
        // is the largest thing the connection ever receives.
        let asks = outgoing
            .iter()
            .filter(|c| matches!(c, Irc::LIST(..)))
            .count();
        assert_eq!(asks, 1, "a second ask while one is running is not sent");
    }

    #[test]
    fn a_directory_arrives_busiest_first() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        start_listing(&mut actor, &mut outgoing);

        feed(
            &mut actor,
            &mut outgoing,
            ":s 322 me #quiet 3 :a small room",
        );
        feed(
            &mut actor,
            &mut outgoing,
            ":s 322 me #busy 900 :the big one",
        );
        feed(&mut actor, &mut outgoing, ":s 322 me #middle 40 :");
        feed(&mut actor, &mut outgoing, ":s 323 me :End of /LIST");

        let (channels, done, truncated) = last_list(&mut rx);
        assert!(done, "the end of the list is the end of the list");
        assert!(!truncated, "three channels is not more than the cap");
        let names: Vec<&str> = channels.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["#busy", "#middle", "#quiet"]);
        assert_eq!(channels[0].users, 900);
        assert_eq!(channels[0].topic, "the big one");
    }

    /// The cap is what makes the answer bounded, and it has to keep the *best*
    /// of what it saw rather than the first that happened to arrive.
    #[test]
    fn a_long_directory_keeps_the_busiest_and_says_it_did() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        start_listing(&mut actor, &mut outgoing);

        // Populations ascending, so keeping the first N would be exactly wrong.
        for i in 0..(MAX_LIST_KEPT * 3) {
            feed(
                &mut actor,
                &mut outgoing,
                &format!(":s 322 me #c{i} {i} :room {i}"),
            );
        }
        feed(&mut actor, &mut outgoing, ":s 323 me :End of /LIST");

        let (channels, done, truncated) = last_list(&mut rx);
        assert!(done);
        assert!(truncated, "throwing some away has to be admitted");
        assert_eq!(channels.len(), MAX_LIST_KEPT);
        assert_eq!(
            channels[0].users as usize,
            MAX_LIST_KEPT * 3 - 1,
            "the busiest channel seen must survive the cap"
        );
    }

    /// A server that answers nothing at all still ends the wait.
    #[test]
    fn an_empty_directory_is_still_an_answer() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        start_listing(&mut actor, &mut outgoing);
        feed(&mut actor, &mut outgoing, ":s 323 me :End of /LIST");

        let (channels, done, _) = last_list(&mut rx);
        assert!(done, "a browser left spinning is worse than an empty one");
        assert!(channels.is_empty());
    }

    /// Nobody asked, so nobody is told.
    #[test]
    fn unprompted_list_replies_are_ignored() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        feed(
            &mut actor,
            &mut outgoing,
            ":s 322 me #whatever 5 :unasked for",
        );
        feed(&mut actor, &mut outgoing, ":s 323 me :End of /LIST");

        assert!(
            drain(&mut rx).is_empty(),
            "a directory nobody asked for is not news"
        );
    }

    /// The flood limiter's one exemption, and its exact shape: these three
    /// numerics, and only while a request is outstanding.
    #[test]
    fn only_list_replies_are_exempt_from_flood_protection() {
        let parse = |raw: &str| raw.parse::<Message>().expect("should parse");

        assert!(is_list_reply(&parse(":s 321 me Channel :Users  Name")));
        assert!(is_list_reply(&parse(":s 322 me #a 1 :t")));
        assert!(is_list_reply(&parse(":s 323 me :End of /LIST")));

        assert!(!is_list_reply(&parse(":a!u@h PRIVMSG #a :hello")));
        assert!(!is_list_reply(&parse(":s 353 me = #a :alice")));
    }

    /// The header restarts the collection, so a stray answer cannot leave the
    /// accumulator holding half of a previous one.
    #[test]
    fn the_list_header_starts_the_collection_over() {
        let (mut actor, mut rx, mut outgoing) = actor(&[]);
        start_listing(&mut actor, &mut outgoing);

        feed(&mut actor, &mut outgoing, ":s 322 me #stale 10 :left over");
        feed(&mut actor, &mut outgoing, ":s 321 me Channel :Users  Name");
        feed(
            &mut actor,
            &mut outgoing,
            ":s 322 me #fresh 5 :the real one",
        );
        feed(&mut actor, &mut outgoing, ":s 323 me :End of /LIST");

        let (channels, _, _) = last_list(&mut rx);
        let names: Vec<&str> = channels.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["#fresh"]);
    }
}
