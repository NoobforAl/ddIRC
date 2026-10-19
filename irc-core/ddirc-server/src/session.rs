//! One accepted connection: TLS, framing, and the two tasks around it.
//!
//! Each connection gets a reader and a writer, and neither of them knows
//! anything about the server. The reader turns bytes into [`Message`]s and
//! hands them to the one task that owns the state; the writer takes
//! [`Message`]s from a queue and puts them back on the wire. All the protocol
//! lives in [`crate::state`], and none of it is reachable from here — which is
//! what lets it be tested without a socket.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use bytes::BytesMut;
use futures_util::{SinkExt, StreamExt};
use irc_proto::error::ProtocolError;
use irc_proto::{Command, IrcCodec, Message, Response};
use tokio::net::TcpStream;
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};
use tokio::sync::{oneshot, Notify};
use tokio::time::{timeout, timeout_at, Duration, Instant};
use tokio_rustls::TlsAcceptor;
use tokio_util::codec::{Decoder, Encoder, Framed};

use crate::state::ClientId;

/// [`IrcCodec`], with a bound on how much may sit unread without a line ending
/// in it.
///
/// The framing underneath keeps whatever it is given until it finds a newline,
/// so a client that sends bytes and never a `\n` makes the server hold memory
/// with no upper bound. On loopback that is hygiene rather than a threat — the
/// only thing that can reach this port is already running as this user — but a
/// leak with no ceiling is worth closing wherever it is found.
///
/// Reported as an I/O error rather than a parse error, which is the difference
/// that matters downstream: a line this crate cannot parse leaves the
/// connection usable, and this does not.
struct Bounded(IrcCodec);

impl Decoder for Bounded {
    type Item = Message;
    type Error = ProtocolError;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Message>, Self::Error> {
        if src.len() > MAX_PENDING && !src.contains(&b'\n') {
            return Err(ProtocolError::Io(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "line too long",
            )));
        }
        self.0.decode(src)
    }
}

impl Encoder<Message> for Bounded {
    type Error = ProtocolError;

    fn encode(&mut self, item: Message, dst: &mut BytesMut) -> Result<(), Self::Error> {
        self.0.encode(item, dst)
    }
}

/// What the reader tells the state task about.
pub enum Event {
    Connected {
        id: ClientId,
        tx: UnboundedSender<Message>,
    },
    Line {
        id: ClientId,
        message: Box<Message>,
    },
    Disconnected {
        id: ClientId,
        reason: String,
    },
    /// A registered connection has said nothing for a while, and the server
    /// should ask whether anyone is there.
    ///
    /// Sent to the state task rather than acted on here because the queue the
    /// `PING` goes down is owned by the state task: this task holding a sender
    /// of its own would keep the queue open after the state dropped the client,
    /// and a closed queue is how a connection learns it has been removed.
    Quiet {
        id: ClientId,
    },
}

/// How long a connection may be silent, and then unanswering, before it is
/// taken to be gone.
///
/// Without this a client that vanishes — an app killed, a phone that left the
/// Wi-Fi — is never noticed: the server only ever listens, and a socket nobody
/// closed looks exactly like a quiet one. The connection stays, and so does the
/// nickname it held, which is how a person who reconnects a minute later is told
/// that their own name is in use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Keepalive {
    /// Silence before the server sends a `PING`.
    pub after: Duration,
    /// Silence after the `PING` before the connection is dropped.
    pub timeout: Duration,
}

impl Default for Keepalive {
    fn default() -> Self {
        Self {
            after: Duration::from_secs(90),
            timeout: Duration::from_secs(45),
        }
    }
}

/// What to do when the wait for the next line runs out.
#[derive(Debug, PartialEq, Eq)]
enum Lapse {
    Ping,
    Drop,
}

/// Where a registered connection stands on being heard from.
///
/// A state machine on its own so the timing can be tested without a socket:
/// silent, then asked, then dropped — and *any* line, not only a `PONG`, puts it
/// back at the start. A client in the middle of a long burst has plainly not
/// gone anywhere, whether or not it answered.
#[derive(Debug)]
struct Idle {
    keepalive: Keepalive,
    probing: bool,
    deadline: Instant,
}

impl Idle {
    fn new(keepalive: Keepalive, now: Instant) -> Self {
        Self {
            keepalive,
            probing: false,
            deadline: now + keepalive.after,
        }
    }

    fn heard(&mut self, now: Instant) {
        *self = Self::new(self.keepalive, now);
    }

    fn lapsed(&mut self, now: Instant) -> Lapse {
        if self.probing {
            Lapse::Drop
        } else {
            self.probing = true;
            self.deadline = now + self.keepalive.timeout;
            Lapse::Ping
        }
    }
}

/// Why the reader woke: a line (or the end of the stream), or its deadline.
enum Wake<T> {
    Line(T),
    Deadline,
}

/// How long a connection may sit without finishing registration.
///
/// A socket that opens and then says nothing costs a task and a buffer for as
/// long as it is left alone. On loopback this is not a threat so much as
/// hygiene, but the alternative is a leak with no upper bound.
const REGISTRATION_GRACE: Duration = Duration::from_secs(30);

/// How long the TLS handshake itself may take.
const HANDSHAKE_GRACE: Duration = Duration::from_secs(10);

/// The most that may sit in the read buffer without a complete line in it.
///
/// IRC lines are 512 bytes; the framing underneath will buffer whatever it is
/// given until it finds a newline, which without a bound is a way to make the
/// server hold an arbitrary amount of memory by never sending one.
const MAX_PENDING: usize = 8 * 1024;

/// Serve one accepted socket until it closes.
///
/// Returns nothing and reports nothing: every outcome that matters reaches the
/// state task as an [`Event`], including the disconnection, so there is no
/// second path by which a connection can end.
pub async fn serve(
    id: ClientId,
    socket: TcpStream,
    acceptor: TlsAcceptor,
    events: UnboundedSender<Event>,
    keepalive: Keepalive,
) {
    // Nagle off: IRC is small messages that matter immediately, and coalescing
    // them buys nothing but latency on a line the user is watching.
    let _ = socket.set_nodelay(true);

    let stream = match timeout(HANDSHAKE_GRACE, acceptor.accept(socket)).await {
        Ok(Ok(stream)) => stream,
        // A failed handshake is not worth an event: nothing upstream has been
        // told this connection exists, so there is nothing to unwind.
        Ok(Err(e)) => {
            tracing::debug!("local server: TLS handshake failed: {e}");
            return;
        }
        Err(_) => {
            tracing::debug!("local server: TLS handshake timed out");
            return;
        }
    };

    let codec = match IrcCodec::new("utf-8") {
        Ok(codec) => codec,
        Err(e) => {
            tracing::error!("local server: could not build the IRC codec: {e}");
            return;
        }
    };
    let framed = Framed::new(stream, Bounded(codec));
    let (mut sink, mut lines) = framed.split();

    let (tx, mut outbox) = unbounded_channel::<Message>();
    if events.send(Event::Connected { id, tx }).is_err() {
        return;
    }

    // Whether registration actually completed, which only the state task
    // knows — and which it says out loud, to this connection, exactly once:
    // `RPL_WELCOME` is sent at the end of registration and at no other time.
    // So the writer reads the answer off the wire it is already writing,
    // rather than a second channel existing to carry one bit backwards.
    let registered = Arc::new(AtomicBool::new(false));

    // The writer owns the sending half for the rest of the connection. It ends
    // when the queue closes, which happens when the state task drops the
    // client — so a disconnect tears down both directions from one place.
    let welcomed = registered.clone();
    // Wakes the reader when the welcome goes out. Without it the reader only
    // learns that registration finished when the client next says something or
    // the registration grace runs out, so a client that registers and then goes
    // quiet would not have its silence counted for the first thirty seconds of
    // it — which is the very client the keepalive is for.
    let welcome = Arc::new(Notify::new());
    let welcome_sent = welcome.clone();
    // Told when the writer is finished, for whatever reason. The reader would
    // otherwise sit on a socket the server has already decided to close — an
    // operator removing someone drops their queue, which ends the writer, and
    // only the peer hanging up would end the reader. Some clients never do.
    let (writer_done_tx, mut writer_done) = oneshot::channel::<()>();
    let writer = tokio::spawn(async move {
        while let Some(message) = outbox.recv().await {
            if matches!(message.command, Command::Response(Response::RPL_WELCOME, _)) {
                welcomed.store(true, Ordering::Release);
                welcome_sent.notify_one();
            }
            if sink.send(message).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
        let _ = writer_done_tx.send(());
    });

    let mut registered_by = Some(Instant::now() + REGISTRATION_GRACE);
    let mut idle = Idle::new(keepalive, Instant::now());
    let reason = loop {
        // The deadline is dropped when the client is *registered*, not when it
        // first says something. Dropping it on the first line was the same
        // guard in name only: `NICK bob` and then silence held a task, a
        // buffer and a claimed nickname for as long as the server ran.
        if registered_by.is_some() && registered.load(Ordering::Acquire) {
            registered_by = None;
            // The silence is counted from the moment they were welcomed, not
            // from when the socket opened.
            idle.heard(Instant::now());
        }

        let wake = tokio::select! {
            // First, so a connection the server has closed stops being read
            // even when the peer is still talking.
            biased;
            _ = &mut writer_done => break "Closed by the server".to_owned(),
            // Registration has just finished; go round again so the deadline
            // being waited on becomes the keepalive's rather than the grace's.
            _ = welcome.notified(), if registered_by.is_some() => continue,
            wake = async {
                // Registering, the deadline is the registration grace; after
                // that it is the keepalive. Never none: a connection with no
                // deadline at all is the one that never goes away.
                let deadline = registered_by.unwrap_or(idle.deadline);
                match timeout_at(deadline, lines.next()).await {
                    Ok(next) => Wake::Line(next),
                    Err(_) => Wake::Deadline,
                }
            } => wake,
        };
        let next = match wake {
            Wake::Line(next) => next,
            // Registration may have completed while this was waiting; the
            // welcome is written by the other task, so the flag is worth one
            // more look before anyone is disconnected over a deadline they had
            // already met.
            Wake::Deadline if registered_by.is_some() && registered.load(Ordering::Acquire) => {
                registered_by = None;
                idle.heard(Instant::now());
                continue;
            }
            Wake::Deadline if registered_by.is_some() => break "Registration timeout".to_owned(),
            Wake::Deadline => match idle.lapsed(Instant::now()) {
                Lapse::Ping => {
                    if events.send(Event::Quiet { id }).is_err() {
                        break "Server shutting down".to_owned();
                    }
                    continue;
                }
                Lapse::Drop => {
                    let silent = (keepalive.after + keepalive.timeout).as_secs();
                    break format!("Ping timeout: {silent} seconds");
                }
            },
        };

        match next {
            Some(Ok(message)) => {
                idle.heard(Instant::now());
                if events
                    .send(Event::Line {
                        id,
                        message: Box::new(message),
                    })
                    .is_err()
                {
                    break "Server shutting down".to_owned();
                }
            }
            // A line this crate cannot parse is not worth ending a connection
            // over: the client is talking, it just said something unknown, and
            // dropping it would turn one bad line into a lost session. An I/O
            // error is the other kind — the socket or the framing is finished,
            // and reading on would spin.
            Some(Err(ProtocolError::InvalidMessage { string, .. })) => {
                // Still somebody there, whatever they said.
                idle.heard(Instant::now());
                tracing::debug!("local server: unparseable line from {id}: {string:?}");
            }
            Some(Err(e)) => break format!("{e}"),
            None => break "Connection closed".to_owned(),
        }
    };

    let _ = events.send(Event::Disconnected { id, reason });
    // Dropping the reader closes the socket, which ends the writer even if the
    // state task never gets to drop the queue.
    drop(lines);
    let _ = writer.await;
}

/// Build the TLS acceptor the listener hands every connection.
///
/// The provider is named rather than inferred, and the name has to be the one
/// the rest of the tree uses: rustls 0.23 will not choose between `ring` and
/// `aws-lc-rs` when both features are on, and its way of saying so is a panic
/// at the first handshake rather than an error at build time. Because Cargo
/// unifies features, asking for the other one here would turn both on for the
/// client as well, and the first thing to break would be connecting to
/// anything at all.
pub fn acceptor(
    chain: Vec<rustls::pki_types::CertificateDer<'static>>,
    key: rustls::pki_types::PrivateKeyDer<'static>,
) -> Result<TlsAcceptor, rustls::Error> {
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .with_no_client_auth()
    .with_single_cert(chain, key)?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const K: Keepalive = Keepalive {
        after: Duration::from_secs(90),
        timeout: Duration::from_secs(45),
    };

    #[test]
    fn silence_is_asked_about_and_then_acted_on() {
        let t0 = Instant::now();
        let mut idle = Idle::new(K, t0);
        assert_eq!(idle.deadline, t0 + Duration::from_secs(90));

        let t1 = t0 + Duration::from_secs(90);
        assert_eq!(idle.lapsed(t1), Lapse::Ping);
        // The second wait is the shorter one, from the moment of asking.
        assert_eq!(idle.deadline, t1 + Duration::from_secs(45));

        assert_eq!(idle.lapsed(t1 + Duration::from_secs(45)), Lapse::Drop);
    }

    #[test]
    fn any_line_starts_the_count_again_not_only_an_answer() {
        let t0 = Instant::now();
        let mut idle = Idle::new(K, t0);
        let t1 = t0 + Duration::from_secs(90);
        assert_eq!(idle.lapsed(t1), Lapse::Ping);

        // They said *something* while being asked: they are there.
        let t2 = t1 + Duration::from_secs(10);
        idle.heard(t2);
        assert_eq!(idle.deadline, t2 + Duration::from_secs(90));
        // And being asked again is the first question, not a second chance.
        assert_eq!(idle.lapsed(idle.deadline), Lapse::Ping);
    }
}
