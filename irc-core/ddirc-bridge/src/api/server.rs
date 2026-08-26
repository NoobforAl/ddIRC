//! Starting and stopping the IRC server that lives inside the app.
//!
//! One at a time, and owned here, for the same reason as the bundled Tor: Dart
//! gets a port number, not a handle. A second server would mean a second
//! certificate authority, a second port, and two answers to "is it running".
//!
//! # The trust anchor never crosses this boundary
//!
//! The server issues its own certificate, so the client has to be told to trust
//! it — and the field that does that, `extra_root_cert`, is deliberately absent
//! from the FFI's `ServerConfig`. Nothing a user can be talked into typing
//! becomes a trusted root, and that stays true here.
//!
//! So the anchor is filled in on this side, by [`anchor_for`], and only for a
//! connection whose host and port are the loopback address this process just
//! bound. It is the same arrangement `dev_root_cert` already uses for the dev
//! server, narrowed further: that one takes a path from the environment in
//! debug builds, this one takes a path the app itself wrote a moment ago.

use std::sync::{Mutex, OnceLock};

use ddirc_server::{Config, LocalServer};

use crate::api::client::runtime;

/// A running local server, as the settings screen sees it.
pub struct LocalServerInfo {
    /// The loopback port it bound. `0` was asked for, so this is whatever the
    /// operating system had free.
    pub port: u16,

    /// What it calls itself, which is what appears in its own messages.
    pub server_name: String,

    /// What it calls the network, which is what labels it in the rail.
    pub network_name: String,
}

/// The server, and the anchor path that goes with it.
///
/// Kept together because they are only ever useful together: a port with no
/// anchor is a port the client will refuse to talk to.
struct Running {
    server: LocalServer,
    anchor: String,
    server_name: String,
    network_name: String,
}

fn running() -> &'static Mutex<Option<Running>> {
    static RUNNING: OnceLock<Mutex<Option<Running>>> = OnceLock::new();
    RUNNING.get_or_init(|| Mutex::new(None))
}

/// The certificate to trust for this connection, if it is the local server.
///
/// Matched on host *and* port rather than host alone. Loopback is not one
/// service — the bundled Tor is on it too, and so is anything else the user
/// happens to run — and an anchor handed to whatever answers on `127.0.0.1`
/// would be a wider grant than the one being made here.
pub(crate) fn anchor_for(host: &str, port: u16) -> Option<String> {
    let guard = running().lock().unwrap_or_else(|e| e.into_inner());
    let running = guard.as_ref()?;
    let loopback = matches!(host, "127.0.0.1" | "::1" | "localhost");
    (loopback && port == running.server.port()).then(|| running.anchor.clone())
}

/// Start it, and return where it is.
///
/// Starting one that is already running returns the one already there rather
/// than an error, so a settings screen rebuilt at the wrong moment cannot end
/// up with two.
///
/// `data_dir` must be the app's own private storage: the certificate authority
/// is written there and has to survive a restart, because the client's trust
/// anchor cannot be re-issued under it without every saved profile pointed at
/// the server breaking.
pub fn local_server_start(data_dir: String) -> Result<LocalServerInfo, String> {
    let mut guard = running().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(already) = guard.as_ref() {
        return Ok(LocalServerInfo {
            port: already.server.port(),
            server_name: already.server_name.clone(),
            network_name: already.network_name.clone(),
        });
    }

    let config = Config::new(data_dir);
    let server_name = config.server_name.clone();
    let network_name = config.network_name.clone();

    let server = runtime()
        .block_on(LocalServer::start(config))
        .map_err(|e| e.to_string())?;

    let info = LocalServerInfo {
        port: server.port(),
        server_name: server_name.clone(),
        network_name: network_name.clone(),
    };
    *guard = Some(Running {
        anchor: server.anchor_path().display().to_string(),
        server,
        server_name,
        network_name,
    });
    Ok(info)
}

/// Stop it. Idempotent, so a switch turned off twice is not an error.
///
/// Anyone connected is disconnected, which is the honest reading of switching
/// off a server: there is nothing left to be connected to.
pub fn local_server_stop() {
    let taken = running().lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(running) = taken {
        runtime().block_on(running.server.stop());
    }
}

/// Where it is, or null if it is not running.
///
/// For a screen coming back rather than one that just pressed the switch — the
/// answer has to survive the widget being rebuilt.
pub fn local_server_info() -> Option<LocalServerInfo> {
    let guard = running().lock().unwrap_or_else(|e| e.into_inner());
    guard.as_ref().map(|r| LocalServerInfo {
        port: r.server.port(),
        server_name: r.server_name.clone(),
        network_name: r.network_name.clone(),
    })
}
