//! The Dart-facing client API.
//!
//! This is the entire surface Flutter can reach. It is deliberately small:
//! connect, subscribe, a handful of commands, disconnect. No socket, session
//! handle, or protocol internal is reachable from Dart.
//!
//! Connections are addressed by an opaque `id` rather than by passing a Rust
//! object across the boundary, which keeps ownership unambiguous — the Rust
//! side owns every connection, and Dart holds only a number.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use ddirc_core::api::events::IrcEvent as CoreEvent;
use ddirc_core::conn::actor::{self, ClientCommand, ConnectionHandle};
use flutter_rust_bridge::frb;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::mpsc;

use crate::api::types::{IrcEvent, ServerConfig};
use crate::frb_generated::StreamSink;

/// The runtime the connection actors live on.
///
/// Owned here rather than by the core so the core stays usable from any host —
/// the CLI harness supplies its own runtime via `#[tokio::main]`.
fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("ddirc-net")
            .enable_all()
            .build()
            .expect("failed to start the ddIRC network runtime")
    })
}

struct Connection {
    handle: ConnectionHandle,
    /// Taken by the first `event_stream` subscriber.
    ///
    /// Events produced between `connect` and the subscription are buffered by
    /// the channel, so none are lost to the gap.
    events: Option<mpsc::Receiver<CoreEvent>>,
}

fn connections() -> &'static Mutex<HashMap<u64, Connection>> {
    static CONNECTIONS: OnceLock<Mutex<HashMap<u64, Connection>>> = OnceLock::new();
    CONNECTIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Run `f` against a live connection.
///
/// A poisoned lock is recovered from rather than propagated: a panic in one
/// connection must not make every other connection permanently unusable.
fn with_connection<T>(
    id: u64,
    f: impl FnOnce(&mut Connection) -> Result<T, String>,
) -> Result<T, String> {
    let mut guard = connections().lock().unwrap_or_else(|e| e.into_inner());
    let connection = guard.get_mut(&id).ok_or("no such connection")?;
    f(connection)
}

/// An extra trust root for talking to the dev server, in debug builds only.
///
/// The dev server in `dev/` is real ergo with a real, self-signed certificate,
/// and nothing on the machine trusts it. Until now the only way to reach it
/// from the app was to launch the whole thing with `SSL_CERT_FILE` set, which
/// is awkward enough that it mostly did not happen.
///
/// This *adds* a root; it does not skip verification. That distinction is the
/// entire point. A bypass would mean the debug build no longer exercises the
/// code path the release build takes, so a certificate bug would survive every
/// day of local testing and surface only in production — and a bypass is one
/// stray `cfg` from being the thing that ships. Adding a root leaves the
/// handshake, the chain building and the hostname check all running exactly as
/// they do in release; the dev server is trusted because its certificate now
/// genuinely verifies, not because nothing was checked.
///
/// Three things must be true for it to apply: a debug build (this function
/// does not exist otherwise — it is `cfg`'d out, not merely unreachable),
/// `DDIRC_DEV_CA` set on purpose, and the file present. A path that is set but
/// missing is left in place so `validate` refuses it by name, because a typo
/// that silently reverted to the platform roots would look exactly like the
/// dev server being broken.
#[cfg(debug_assertions)]
fn dev_root_cert() -> Option<String> {
    let path = std::env::var("DDIRC_DEV_CA")
        .ok()
        .filter(|p| !p.is_empty())?;
    // On stderr rather than swallowed: weakened trust, however narrowly,
    // should never be something you have to go looking for.
    eprintln!("ddIRC [debug]: trusting extra root certificate from {path}");
    Some(path)
}

/// Open a connection and return its id.
///
/// The configuration is validated up front, so a bad host, a plaintext port, or
/// half-supplied SASL credentials fail here with a clear message rather than as
/// an opaque error later.
pub fn connect(config: ServerConfig) -> Result<u64, String> {
    #[allow(unused_mut)]
    let mut config: ddirc_core::api::types::ServerConfig = config.into();
    #[cfg(debug_assertions)]
    {
        config.extra_root_cert = dev_root_cert();
    }
    config.validate().map_err(|e| e.to_string())?;

    // `actor::spawn` calls `tokio::spawn`, which needs a runtime in scope.
    let guard = runtime().enter();
    let (handle, events) = actor::spawn(config);
    drop(guard);

    static NEXT_ID: AtomicU64 = AtomicU64::new(1);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);

    connections()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            id,
            Connection {
                handle,
                events: Some(events),
            },
        );
    Ok(id)
}

/// Subscribe to a connection's events. In Dart this returns a `Stream`.
///
/// Only one subscription per connection is possible; the UI should fan out from
/// the single stream rather than subscribing twice.
pub fn event_stream(id: u64, sink: StreamSink<IrcEvent>) -> Result<(), String> {
    let mut events = with_connection(id, |connection| {
        connection
            .events
            .take()
            .ok_or_else(|| "already subscribed".to_owned())
    })?;

    // The sink may be held indefinitely and written from a spawned task, which
    // is exactly the shape the actor produces.
    runtime().spawn(async move {
        while let Some(event) = events.recv().await {
            // A closed sink means Dart dropped the subscription; stop quietly.
            if sink.add(IrcEvent::from(event)).is_err() {
                break;
            }
        }
    });
    Ok(())
}

/// Queue a command for a connection.
///
/// Non-blocking: blocking here would tie up an FFI worker thread for as long as
/// the actor is busy. A full queue means the actor is badly backed up, which is
/// reported rather than hidden — the command genuinely did not happen.
fn send(id: u64, command: ClientCommand) -> Result<(), String> {
    with_connection(id, |connection| {
        connection
            .handle
            .try_send(command)
            .map_err(|e| e.to_string())
    })
}

pub fn join(id: u64, channel: String, key: Option<String>) -> Result<(), String> {
    send(
        id,
        ClientCommand::Join {
            channel,
            key: key.filter(|k| !k.is_empty()),
        },
    )
}

pub fn part(id: u64, channel: String, reason: Option<String>) -> Result<(), String> {
    send(id, ClientCommand::Part { channel, reason })
}

pub fn send_message(id: u64, target: String, text: String) -> Result<(), String> {
    send(id, ClientCommand::SendMessage { target, text })
}

pub fn send_action(id: u64, target: String, text: String) -> Result<(), String> {
    send(id, ClientCommand::SendAction { target, text })
}

pub fn set_nick(id: u64, nick: String) -> Result<(), String> {
    send(id, ClientCommand::SetNick(nick))
}

/// Set a channel topic. An empty string clears it.
pub fn set_topic(id: u64, channel: String, topic: String) -> Result<(), String> {
    send(id, ClientCommand::SetTopic { channel, topic })
}

/// Stop waiting out the reconnect backoff and try again now.
///
/// Does nothing unless the connection is actually waiting, so it is safe to
/// call from a button the user may press at the moment the connection returns
/// on its own. The connection, its id and its scrollback all survive — this
/// wakes the existing actor rather than replacing it.
pub fn reconnect(id: u64) -> Result<(), String> {
    send(id, ClientCommand::Reconnect)
}

/// Disconnect and release the connection.
///
/// Idempotent: disconnecting an unknown or already-closed connection succeeds,
/// so the UI does not have to track whether teardown already happened.
pub fn disconnect(id: u64, reason: Option<String>) -> Result<(), String> {
    let connection = connections()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id);

    let Some(connection) = connection else {
        return Ok(());
    };
    // Best effort: the connection is already removed from the registry, so even
    // if the actor is gone the caller is correctly left with nothing to close.
    let _ = connection
        .handle
        .try_send(ClientCommand::Disconnect { reason });
    Ok(())
}

/// The default port for IRC over TLS, so Dart does not hardcode it.
#[frb(sync)]
pub fn default_tls_port() -> u16 {
    ddirc_core::api::types::ServerConfig::DEFAULT_TLS_PORT
}
