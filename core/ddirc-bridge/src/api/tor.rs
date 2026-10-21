//! Turning the bundled Tor on and off, and saying how far along it is.
//!
//! One at a time, and owned here: Dart gets a port number, not a handle. There
//! is exactly one embedded Tor per process because there is exactly one reason
//! to have it — a second would mean a second directory cache, a second set of
//! guards, and two answers to "is Tor on".
//!
//! What Dart does with the port is point the existing proxy setting at it. See
//! `ddirc-tor` for why bundling Tor deliberately did not add a new way for a
//! connection to leave the app.

use std::sync::{Mutex, OnceLock};

use ddirc_tor::TorService;

use crate::api::client::runtime;
use crate::frb_generated::StreamSink;

/// How far along Tor is, for the settings screen.
pub struct TorStatus {
    /// Connections through the proxy will now succeed. Before this they
    /// *wait*, rather than failing — so a network dialled early connects late
    /// rather than erroring.
    pub ready: bool,

    /// 0.0 to 1.0.
    pub progress: f32,

    /// One line, in Arti's words.
    pub summary: String,

    /// Why it is stuck, when Arti knows — a censored network, no route out, a
    /// clock too far off for anything to verify. The only part of this the
    /// user can act on, so it is the part shown in full.
    pub blocked: Option<String>,
}

impl From<ddirc_tor::TorStatus> for TorStatus {
    fn from(s: ddirc_tor::TorStatus) -> Self {
        TorStatus {
            ready: s.ready,
            progress: s.progress,
            summary: s.summary,
            blocked: s.blocked,
        }
    }
}

fn service() -> &'static Mutex<Option<TorService>> {
    static SERVICE: OnceLock<Mutex<Option<TorService>>> = OnceLock::new();
    SERVICE.get_or_init(|| Mutex::new(None))
}

/// Start the bundled Tor and return the loopback port it answers SOCKS5 on.
///
/// Returns as soon as there is a port, which is well before Tor can carry
/// anything: bootstrapping needs a directory consensus off the network, and
/// how long that takes depends on the network. Follow [`tor_status_stream`]
/// for the rest.
///
/// Starting when it is already running returns the port it is already on
/// rather than an error, so a settings screen rebuilt at the wrong moment
/// cannot end up with two.
///
/// `data_dir` is where Tor keeps its state and its directory cache. It must be
/// the app's own private storage: the cache is not secret, but the guard list
/// is a record of how this machine reaches the network.
pub fn tor_start(data_dir: String) -> Result<u16, String> {
    let mut guard = service().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(running) = guard.as_ref() {
        return Ok(running.port());
    }
    let started = runtime()
        .block_on(TorService::start(std::path::Path::new(&data_dir)))
        .map_err(|e| e.to_string())?;
    let port = started.port();
    *guard = Some(started);
    Ok(port)
}

/// Stop it. Idempotent, so a switch turned off twice is not an error.
///
/// Connections currently routed through it are cut. That is deliberate: after
/// turning Tor off, nothing should still be connected by way of it, and
/// nothing should quietly fall back to a direct route it was never given
/// permission to take.
pub fn tor_stop() {
    let taken = service().lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(service) = taken {
        runtime().block_on(service.stop());
    }
}

/// The port Tor is on, or null if it is not running.
///
/// For a UI coming back to a screen rather than one that just pressed the
/// switch — the answer has to survive the widget being rebuilt.
pub fn tor_port() -> Option<u16> {
    service()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|s| s.port())
}

/// Follow the bootstrap. In Dart this is a `Stream`.
///
/// The current status is delivered first, so a screen that subscribes late
/// still knows where things stand rather than waiting for the next change.
/// The stream ends when Tor stops.
pub fn tor_status_stream(sink: StreamSink<TorStatus>) -> Result<(), String> {
    let mut watch = {
        let guard = service().lock().unwrap_or_else(|e| e.into_inner());
        let service = guard.as_ref().ok_or("Tor is not running")?;
        service.watch()
    };

    runtime().spawn(async move {
        // `borrow_and_update` rather than `borrow`, so the first `changed`
        // reports the next change rather than immediately returning the value
        // that was just sent.
        let current = watch.borrow_and_update().clone();
        if sink.add(TorStatus::from(current)).is_err() {
            return;
        }
        while watch.changed().await.is_ok() {
            let status = watch.borrow_and_update().clone();
            if sink.add(TorStatus::from(status)).is_err() {
                return;
            }
        }
    });
    Ok(())
}
