//! The XMPP connection actor.
//!
//! One tokio task owns the stream outright, exactly as on the IRC side:
//! commands arrive on a channel, events leave on another, and nothing outside
//! the task touches the connection. What the protocol *means* is in
//! [`crate::xmpp::session`], which has no I/O; this is the part that has it.
//!
//! # Why the library's own client is not used
//!
//! `tokio-xmpp` offers a `Client` that logs in and reconnects by itself. Its
//! reconnection is `loop { try to log in; on failure, sleep, double the sleep,
//! try again }`, with a comment in the source asking whether authentication
//! errors "should probably be fatal". Here they must be: a wrong password
//! retried every thirty seconds for ever is a locked account, and the person
//! is never told because the library only logs it. So the login, and the
//! decision about when to try again, are ours - the library supplies the stream
//! that survives a dropped connection with nothing lost (XEP-0198), and we tell
//! it how to make a new one.
//!
//! That policy is the IRC side's: a connection that has never worked is tried a
//! few times and then left alone, one that has is resumed with backoff, and a
//! refusal that waiting cannot cure stops and says so.

use std::borrow::Cow;
use std::collections::{BTreeSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use sasl::common::Credentials;
use tokio::sync::{mpsc, oneshot, Notify};
use tokio::time::sleep;
use tokio_xmpp::connect::ServerConnector;
use tokio_xmpp::jid::Jid;
use tokio_xmpp::parsers::ns;
use tokio_xmpp::stanzastream::{Connection, Event, StanzaStream, StreamEvent};
use tokio_xmpp::xmlstream::{StreamHeader, Timeouts};
use tokio_xmpp::{Error, Stanza};

use crate::api::events::IrcEvent;
use crate::api::types::ConnectionStatus;
use crate::conn::actor::{ClientCommand, ConnectionHandle};
use crate::conn::ratelimit::{ReceiveLimiter, SendLimiter};
use crate::conn::reconnect::Backoff;
use crate::xmpp::auth;
use crate::xmpp::config::XmppConfig;
use crate::xmpp::connector::DirectTlsConnector;
use crate::xmpp::diagnose::{self, Diagnosis};
use crate::xmpp::session::{Effects, Session};

/// How many events may queue up before we start dropping them.
const EVENT_QUEUE: usize = 1024;

/// How many stanzas the library may hold in each direction before it makes the
/// sender wait.
const STREAM_QUEUE: usize = 16;

/// How many times to try an account that has never once logged in.
///
/// The IRC side's reasoning applies unchanged: resuming a connection that was
/// working is the point of reconnecting, and retrying one that never worked is
/// a loop nobody asked for. See `MAX_ATTEMPTS_BEFORE_FIRST_SUCCESS` there.
const MAX_ATTEMPTS_BEFORE_FIRST_SUCCESS: u32 = 3;

/// How long a stream may be silent before the library asks the server whether
/// it is still there, and how long it waits for the answer.
///
/// Shorter than the library's five minutes each, which would let a connection
/// that died with the network look healthy for ten. A phone changes network
/// all the time; two minutes to notice is long enough.
const TIMEOUTS: Timeouts = Timeouts {
    read_timeout: Duration::from_secs(90),
    response_timeout: Duration::from_secs(30),
};

/// How often dropped incoming messages are reported, at most.
const DROP_REPORT_EVERY: Duration = Duration::from_secs(5);

/// Start a connection actor, returning a handle and the event stream.
///
/// The same shape as [`crate::conn::actor::spawn`]. The actor runs until the
/// connection is explicitly closed or the event receiver is dropped.
pub fn spawn(config: XmppConfig) -> (ConnectionHandle, mpsc::Receiver<IrcEvent>) {
    let (command_tx, command_rx) = mpsc::channel(64);
    let (event_tx, event_rx) = mpsc::channel(EVENT_QUEUE);

    tokio::spawn(async move {
        Actor::new(config, event_tx).run(command_rx).await;
    });

    (ConnectionHandle::new(command_tx), event_rx)
}

/// What the login task tells the actor, since it cannot emit events itself.
#[derive(Debug)]
enum Report {
    Attempt(u32),
    Failed {
        diagnosis: Diagnosis,
        /// When the next attempt is, and which one it will be. `None` means
        /// there will not be one.
        retry: Option<(Duration, u32)>,
    },
}

/// State the login task and the actor both need.
struct Shared {
    /// Whether this connection has ever logged in. Set once, never cleared: an
    /// account that worked this morning is worth resuming this afternoon.
    ever_online: AtomicBool,
    backoff: Mutex<Backoff>,
    /// Wakes a login task that is waiting out its backoff.
    retry_now: Notify,
}

/// Why a login attempt did not produce a stream.
pub(crate) enum LoginError {
    Xmpp(Error),
    NoMechanism(BTreeSet<String>),
}

impl From<Error> for LoginError {
    fn from(error: Error) -> Self {
        Self::Xmpp(error)
    }
}

/// Connect, secure, and authenticate. The resource is not bound: the stream
/// does that.
///
/// What `tokio-xmpp` does internally, except that the mechanisms offered to
/// the library are the ones [`auth::acceptable`] allows, and a server offering
/// none is an error that says what it offered.
pub(crate) async fn login(
    connector: &DirectTlsConnector,
    jid: &Jid,
    password: &str,
) -> Result<
    (
        tokio_xmpp::parsers::stream_features::StreamFeatures,
        tokio_xmpp::stanzastream::XmppStream,
    ),
    LoginError,
> {
    let (pending, binding) = connector.connect(jid, ns::JABBER_CLIENT, TIMEOUTS).await?;
    let (features, stream) = pending.recv_features().await.map_err(Error::from)?;

    let mechanisms = auth::acceptable(&features.sasl_mechanisms);
    if mechanisms.is_empty() {
        return Err(LoginError::NoMechanism(features.sasl_mechanisms));
    }
    let username = jid
        .node()
        .map(|n| n.as_str().to_owned())
        .unwrap_or_default();
    let credentials = Credentials::default()
        .with_username(username)
        .with_password(password)
        .with_channel_binding(binding);
    let stream = tokio_xmpp::client_login(stream, mechanisms, credentials).await?;
    let stream = stream
        .send_header(StreamHeader {
            to: Some(Cow::Borrowed(jid.domain().as_str())),
            from: None,
            id: None,
        })
        .await
        .map_err(Error::Io)?;
    let (features, stream) = stream.recv_features().await.map_err(Error::from)?;
    Ok((features, stream.box_stream()))
}

/// Log in, and keep trying until it works or it should stop.
///
/// Run by the stream whenever it needs a connection: once at the start, and
/// again each time one is lost. It either hands over a connection, or - when
/// trying again cannot help - reports why and waits to be told to stop. It does
/// not drop the channel it was given, because the stream treats that as a
/// crash.
async fn keep_trying(
    connector: DirectTlsConnector,
    jid: Jid,
    password: String,
    server: String,
    shared: Arc<Shared>,
    reports: mpsc::UnboundedSender<Report>,
    mut slot: oneshot::Sender<Connection>,
) {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let _ = reports.send(Report::Attempt(attempt));
        let outcome = tokio::select! {
            outcome = login(&connector, &jid, &password) => outcome,
            // The stream was closed while we were connecting.
            () = slot.closed() => return,
        };
        let error = match outcome {
            Ok((features, stream)) => {
                // If nobody is listening any more there is nothing to do with it.
                let _ = slot.send(Connection {
                    stream,
                    features,
                    identity: jid,
                });
                return;
            }
            Err(error) => error,
        };

        let diagnosis = match &error {
            LoginError::Xmpp(e) => diagnose::explain(e, &server),
            LoginError::NoMechanism(offered) => diagnose::no_acceptable_mechanism(offered),
        };
        let gave_up = !diagnosis.fatal
            && !shared.ever_online.load(Ordering::Relaxed)
            && attempt >= MAX_ATTEMPTS_BEFORE_FIRST_SUCCESS;
        if diagnosis.fatal || gave_up {
            let diagnosis = if gave_up {
                Diagnosis {
                    message: format!("{} Gave up after {attempt} attempts.", diagnosis.message),
                    fatal: true,
                }
            } else {
                diagnosis
            };
            let _ = reports.send(Report::Failed {
                diagnosis,
                retry: None,
            });
            // Parked until the actor closes the stream, which drops the other
            // end of the slot.
            slot.closed().await;
            return;
        }

        let delay = shared
            .backoff
            .lock()
            .map(|mut backoff| backoff.next_delay())
            .unwrap_or(Duration::from_secs(30));
        let _ = reports.send(Report::Failed {
            diagnosis,
            retry: Some((delay, attempt + 1)),
        });
        tokio::select! {
            () = sleep(delay) => {}
            () = shared.retry_now.notified() => {}
            () = slot.closed() => return,
        }
    }
}

/// How one run of the connection ended.
enum Ended {
    /// The user asked to disconnect, or the UI went away.
    Quit,
    /// It stopped for a reason retrying will not change. Waits to be asked.
    Stopped,
}

struct Actor {
    config: XmppConfig,
    events: mpsc::Sender<IrcEvent>,
    recv_limiter: ReceiveLimiter,
    send_limiter: SendLimiter,
    /// Events dropped because the UI was not keeping up.
    dropped_events: u64,
    last_drop_report: Instant,
}

impl Actor {
    fn new(config: XmppConfig, events: mpsc::Sender<IrcEvent>) -> Self {
        let now = Instant::now();
        Self {
            config,
            events,
            recv_limiter: ReceiveLimiter::new(now),
            send_limiter: SendLimiter::new(now),
            dropped_events: 0,
            last_drop_report: now,
        }
    }

    /// Hand an event to the UI. False once nobody is listening.
    fn emit(&mut self, event: IrcEvent) -> bool {
        match self.events.try_send(event) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.dropped_events += 1;
                true
            }
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        }
    }

    fn status(&mut self, status: ConnectionStatus, detail: Option<String>) -> bool {
        self.emit(IrcEvent::Status { status, detail })
    }

    fn fatal(&mut self, message: String) {
        self.emit(IrcEvent::Error {
            message: message.clone(),
            fatal: true,
        });
        self.status(ConnectionStatus::Disconnected, Some(message));
    }

    async fn run(mut self, mut commands: mpsc::Receiver<ClientCommand>) {
        if let Err(error) = self.config.validate() {
            self.fatal(error.to_string());
            return;
        }
        loop {
            match self.connect_once(&mut commands).await {
                Ended::Quit => return,
                Ended::Stopped => {
                    // Wait to be asked, as the IRC side does after a refusal.
                    loop {
                        match commands.recv().await {
                            Some(ClientCommand::Reconnect) => break,
                            Some(ClientCommand::Disconnect { .. }) | None => return,
                            Some(_) => {
                                if !self.emit(IrcEvent::Error {
                                    message: "Not connected.".to_owned(),
                                    fatal: false,
                                }) {
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One connection, from the first attempt until it ends for good.
    async fn connect_once(&mut self, commands: &mut mpsc::Receiver<ClientCommand>) -> Ended {
        if !self.status(ConnectionStatus::Connecting, None) {
            return Ended::Quit;
        }
        let connector = match DirectTlsConnector::new(&self.config) {
            Ok(connector) => connector,
            Err(error) => {
                self.fatal(error.to_string());
                return Ended::Stopped;
            }
        };
        let Some(mut session) = Session::new(&self.config) else {
            self.fatal("The account address is not valid.".to_owned());
            return Ended::Stopped;
        };
        let Ok(jid) = self.config.bare_jid().map(Jid::from) else {
            self.fatal("The account address is not valid.".to_owned());
            return Ended::Stopped;
        };
        let server = self.config.dial_host().unwrap_or_default();

        let shared = Arc::new(Shared {
            ever_online: AtomicBool::new(false),
            backoff: Mutex::new(Backoff::default()),
            retry_now: Notify::new(),
        });
        let (report_tx, mut reports) = mpsc::unbounded_channel();

        let password = self.config.password.to_string();
        let mut stream = {
            let shared = shared.clone();
            StanzaStream::new(
                Box::new(move |_, slot| {
                    tokio::spawn(keep_trying(
                        connector.clone(),
                        jid.clone(),
                        password.clone(),
                        server.clone(),
                        shared.clone(),
                        report_tx.clone(),
                        slot,
                    ));
                }),
                STREAM_QUEUE,
            )
        };

        // Messages waiting for the send limiter. Everything else goes straight
        // out: a presence or a query is not what a server's flood protection is
        // about, and holding one back behind a paragraph of chat would stall
        // joining a room.
        let mut paced: VecDeque<Stanza> = VecDeque::new();

        let ended = loop {
            if self.events.is_closed() {
                break Ended::Quit;
            }
            self.report_drops();
            let wait = (!paced.is_empty()).then(|| self.send_limiter.wait_time(Instant::now()));

            tokio::select! {
                command = commands.recv() => {
                    let Some(command) = command else { break Ended::Quit };
                    match command {
                        ClientCommand::Disconnect { .. } => {
                            self.status(ConnectionStatus::Disconnected, None);
                            break Ended::Quit;
                        }
                        ClientCommand::Reconnect => shared.retry_now.notify_one(),
                        other => {
                            let fx = session.on_command(other);
                            self.apply(fx, &stream, &mut paced).await;
                        }
                    }
                }
                event = stream.next() => {
                    let Some(event) = event else {
                        self.status(ConnectionStatus::Disconnected, None);
                        break Ended::Stopped;
                    };
                    match event {
                        Event::Stream(StreamEvent::Reset { bound_jid, .. }) => {
                            shared.ever_online.store(true, Ordering::Relaxed);
                            if let Ok(mut backoff) = shared.backoff.lock() {
                                backoff.reset();
                            }
                            self.status(ConnectionStatus::Connected, None);
                            if let Ok(bound) = bound_jid.try_into_full() {
                                let fx = session.on_online(&bound);
                                self.apply(fx, &stream, &mut paced).await;
                            }
                        }
                        Event::Stream(StreamEvent::Suspended) => {
                            self.status(
                                ConnectionStatus::Reconnecting { retry_in_secs: 0, attempt: 1 },
                                Some("The connection was lost; resuming.".to_owned()),
                            );
                        }
                        Event::Stream(StreamEvent::Resumed) => {
                            self.status(ConnectionStatus::Connected, None);
                        }
                        Event::Stanza(stanza) => {
                            // Only chat counts against the flood limit; a burst
                            // of presence at the start of a busy room is not a
                            // flood and the roster depends on all of it.
                            if matches!(stanza, Stanza::Message(_))
                                && !self.recv_limiter.admit(Instant::now())
                            {
                                continue;
                            }
                            let fx = session.on_stanza(stanza);
                            self.apply(fx, &stream, &mut paced).await;
                        }
                    }
                }
                report = reports.recv() => {
                    let Some(report) = report else { continue };
                    if let Some(ended) = self.on_report(report) {
                        break ended;
                    }
                }
                () = sleep(wait.unwrap_or_default()), if wait.is_some() => {
                    self.release(&stream, &mut paced).await;
                }
            }
        };

        // Closing says goodbye properly and cancels any reconnection still
        // pending, which is also what wakes a parked login task.
        if matches!(ended, Ended::Quit) {
            stream.close().await;
        } else {
            tokio::time::timeout(Duration::from_secs(5), stream.close())
                .await
                .ok();
        }
        ended
    }

    /// Act on something the login task reported. `Some` ends the connection.
    fn on_report(&mut self, report: Report) -> Option<Ended> {
        match report {
            Report::Attempt(1) => None,
            Report::Attempt(_) => {
                self.status(ConnectionStatus::Connecting, None);
                None
            }
            Report::Failed { diagnosis, retry } => {
                self.emit(IrcEvent::Error {
                    message: diagnosis.message.clone(),
                    fatal: diagnosis.fatal,
                });
                match retry {
                    Some((delay, attempt)) if !diagnosis.fatal => {
                        self.status(
                            ConnectionStatus::Reconnecting {
                                retry_in_secs: delay.as_secs().max(1),
                                attempt,
                            },
                            Some(diagnosis.message),
                        );
                        None
                    }
                    _ => {
                        self.status(ConnectionStatus::Disconnected, Some(diagnosis.message));
                        Some(Ended::Stopped)
                    }
                }
            }
        }
    }

    /// Carry out what the session decided.
    async fn apply(&mut self, fx: Effects, stream: &StanzaStream, paced: &mut VecDeque<Stanza>) {
        for event in fx.events {
            self.emit(event);
        }
        for stanza in fx.send {
            if matches!(stanza, Stanza::Message(_)) {
                paced.push_back(stanza);
            } else {
                stream.send(Box::new(stanza)).await;
            }
        }
        self.release(stream, paced).await;
    }

    /// Send as many waiting messages as the limiter allows.
    async fn release(&mut self, stream: &StanzaStream, paced: &mut VecDeque<Stanza>) {
        while !paced.is_empty() {
            if !self.send_limiter.acquire(Instant::now()).is_zero() {
                return;
            }
            if let Some(stanza) = paced.pop_front() {
                stream.send(Box::new(stanza)).await;
            }
        }
    }

    fn report_drops(&mut self) {
        if self.last_drop_report.elapsed() < DROP_REPORT_EVERY {
            return;
        }
        let total = self.recv_limiter.take_dropped() + std::mem::take(&mut self.dropped_events);
        self.last_drop_report = Instant::now();
        if total > 0 {
            self.emit(IrcEvent::MessagesDropped {
                channel: None,
                count: total,
            });
        }
    }
}
