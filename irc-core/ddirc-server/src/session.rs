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
use tokio::time::{timeout, Duration};
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
    let writer = tokio::spawn(async move {
        while let Some(message) = outbox.recv().await {
            if matches!(message.command, Command::Response(Response::RPL_WELCOME, _)) {
                welcomed.store(true, Ordering::Release);
            }
            if sink.send(message).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });

    let mut registered_by = Some(tokio::time::Instant::now() + REGISTRATION_GRACE);
    let reason = loop {
        // The deadline is dropped when the client is *registered*, not when it
        // first says something. Dropping it on the first line was the same
        // guard in name only: `NICK bob` and then silence held a task, a
        // buffer and a claimed nickname for as long as the server ran.
        if registered_by.is_some() && registered.load(Ordering::Acquire) {
            registered_by = None;
        }

        let next = match registered_by {
            Some(deadline) => {
                match timeout(deadline - tokio::time::Instant::now(), lines.next()).await {
                    Ok(next) => next,
                    // Registration may have completed while this was waiting;
                    // the welcome is written by the other task, so the flag is
                    // worth one more look before anyone is disconnected over
                    // a deadline they had already met.
                    Err(_) if registered.load(Ordering::Acquire) => {
                        registered_by = None;
                        continue;
                    }
                    Err(_) => break "Registration timeout".to_owned(),
                }
            }
            None => lines.next().await,
        };

        match next {
            Some(Ok(message)) => {
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
