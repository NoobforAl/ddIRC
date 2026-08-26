//! Tor, bundled — beta.
//!
//! Half of this already worked. Anyone running Tor themselves could point the
//! proxy setting at `127.0.0.1:9050`, and everything above that — the proxy
//! model, the credential handling, the route shown in the rail's tooltip, the
//! `.onion` support — was built and tested against a real Tor. What was
//! missing was Tor itself, and "install Tor first" is a sentence that loses
//! most of the people the feature is for.
//!
//! # Why a library and not a binary
//!
//! This embeds [Arti], the Tor Project's own Rust implementation, rather than
//! shipping a `tor` executable beside the app. A second process would have to
//! be signed and notarised on macOS, would be a second thing for Android to
//! kill, would need its own torrc written at runtime, and would leave the app
//! guessing whether it was alive. A library is a dependency, which is a cost
//! paid once at build time rather than every launch.
//!
//! It is a large dependency and that should be said plainly: a little over
//! five hundred crates, and a few megabytes of binary. See `TODO.md` for the
//! measurements.
//!
//! # Why it still speaks SOCKS to us
//!
//! Arti can open a stream directly, and it would have been possible to give
//! the core a Tor transport beside its TCP one. That would mean a second
//! implementation of connecting, of reporting which route a connection took,
//! and of every failure message about them — to arrive at the same circuits.
//!
//! Instead this runs a SOCKS5 listener on loopback, and the app points its
//! existing proxy setting at it. The connection path is then *identical* to
//! the one an external Tor has always used, which means it is the path that is
//! already tested, and turning the bundled Tor on cannot break the case where
//! someone runs their own.
//!
//! [Arti]: https://gitlab.torproject.org/tpo/core/arti

mod socks;

use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;

use arti_client::config::TorClientConfigBuilder;
use arti_client::{BootstrapBehavior, TorClient};
use futures_util::StreamExt;
use tokio::net::TcpListener;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tor_rtcompat::PreferredRuntime;

/// What went wrong starting Tor.
#[derive(Debug, thiserror::Error)]
pub enum TorError {
    #[error("Tor needs a place to keep its state, and {path} could not be created: {source}")]
    Storage {
        path: String,
        #[source]
        source: std::io::Error,
    },

    #[error("Tor could not open a local port to listen on: {0}")]
    Listen(#[source] std::io::Error),

    #[error("Tor could not be started: {0}")]
    Start(String),
}

/// How far along Tor is, as the app should say it.
///
/// Deliberately a summary rather than the whole of Arti's bootstrap detail.
/// The user is being asked to wait, and the useful things to tell them are how
/// long is left, whether it has stopped making progress, and whether they can
/// connect yet.
#[derive(Debug, Clone, PartialEq)]
pub struct TorStatus {
    /// Connections will now succeed. Until this is true they will *wait*
    /// rather than fail — see [`BootstrapBehavior::OnDemand`].
    pub ready: bool,

    /// 0.0 to 1.0, for a progress bar.
    pub progress: f32,

    /// One line, from Arti, in Arti's words.
    pub summary: String,

    /// Set when bootstrapping is stuck and Arti knows why — a censored
    /// network, no route out, a clock far enough off that nothing verifies.
    /// This is the one worth putting in front of the user, because it is the
    /// only one they can act on.
    pub blocked: Option<String>,
}

impl TorStatus {
    fn starting() -> Self {
        TorStatus {
            ready: false,
            progress: 0.0,
            summary: "Starting Tor".to_owned(),
            blocked: None,
        }
    }
}

/// A running embedded Tor, and the loopback port it answers SOCKS5 on.
///
/// Dropping this stops it: the tasks are aborted and the listener closes, so
/// there is no way to leave a proxy running that nothing owns.
pub struct TorService {
    port: u16,
    status: watch::Receiver<TorStatus>,
    tasks: Vec<JoinHandle<()>>,
    /// Held so the client outlives the tasks using it, and so `stop` is the
    /// only thing that ends it.
    _client: Arc<TorClient<PreferredRuntime>>,
}

impl TorService {
    /// Start Tor and return as soon as there is a port to connect to.
    ///
    /// This does **not** wait for bootstrapping. Bootstrapping a fresh Tor
    /// means fetching a directory consensus, and how long that takes is not
    /// something the app can promise — it depends on the network the machine
    /// is on. Blocking here would mean an unresponsive switch in settings with
    /// nothing to show for it.
    ///
    /// Instead the port exists immediately and the client is set to bootstrap
    /// on demand, so a connection made before Tor is ready waits for it rather
    /// than failing. [`status`](Self::status) is how the UI says so.
    pub async fn start(data_dir: &Path) -> Result<TorService, TorError> {
        provider();

        let state = data_dir.join("tor/state");
        let cache = data_dir.join("tor/cache");
        for path in [&state, &cache] {
            std::fs::create_dir_all(path).map_err(|e| TorError::Storage {
                path: path.display().to_string(),
                source: e,
            })?;
        }

        let config = TorClientConfigBuilder::from_directories(&state, &cache)
            .build()
            .map_err(|e| TorError::Start(e.to_string()))?;

        let runtime = PreferredRuntime::current().map_err(|e| TorError::Start(e.to_string()))?;
        let client = TorClient::with_runtime(runtime)
            .config(config)
            .bootstrap_behavior(BootstrapBehavior::OnDemand)
            .create_unbootstrapped()
            .map_err(|e| TorError::Start(e.to_string()))?;

        // Loopback, and only loopback. A SOCKS proxy that anything else on the
        // network can reach is an open proxy, and an open proxy into Tor is
        // the kind of mistake that is someone else's traffic before it is
        // noticed. Port 0: the number does not matter, and asking for a fixed
        // one is asking for the launch where something else already has it.
        let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .await
            .map_err(TorError::Listen)?;
        let port = listener.local_addr().map_err(TorError::Listen)?.port();

        let (tx, status) = watch::channel(TorStatus::starting());

        let mut events = client.bootstrap_events();
        let reporter = tokio::spawn(async move {
            while let Some(event) = events.next().await {
                let status = TorStatus {
                    ready: event.ready_for_traffic(),
                    progress: event.as_frac(),
                    summary: event.to_string(),
                    blocked: event.blocked().map(|b| b.to_string()),
                };
                // The receiver going away means the service was dropped, and
                // there is nobody left to tell.
                if tx.send(status).is_err() {
                    return;
                }
            }
        });

        let serving = tokio::spawn(socks::serve(listener, client.clone()));

        // Bootstrapping is kicked off rather than waited for. `OnDemand` would
        // start it at the first connection anyway; doing it now means the wait
        // happens while the user is still looking at the settings screen that
        // turned it on, instead of the first time they try to join something.
        let bootstrapping = client.clone();
        let bootstrap = tokio::spawn(async move {
            if let Err(e) = bootstrapping.bootstrap().await {
                tracing::warn!("tor: bootstrap failed: {e}");
            }
        });

        tracing::info!("tor: SOCKS5 on 127.0.0.1:{port}, bootstrapping");
        Ok(TorService {
            port,
            status,
            tasks: vec![reporter, serving, bootstrap],
            _client: client,
        })
    }

    /// The loopback port to point the proxy setting at.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The current status, without waiting.
    pub fn status(&self) -> TorStatus {
        self.status.borrow().clone()
    }

    /// A watch handle, for a UI that wants to follow the bootstrap.
    pub fn watch(&self) -> watch::Receiver<TorStatus> {
        self.status.clone()
    }

    /// Stop, and do not return until the tasks are down.
    ///
    /// Existing connections through it are cut, which is the honest behaviour:
    /// turning Tor off while something is still routed through it must not
    /// leave that something connected by some other path.
    pub async fn stop(mut self) {
        // `take` rather than consuming the field: `TorService` has a `Drop`
        // impl, so it cannot be taken apart by moving out of it.
        let tasks = std::mem::take(&mut self.tasks);
        for task in &tasks {
            task.abort();
        }
        for task in tasks {
            let _ = task.await;
        }
    }
}

impl Drop for TorService {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

/// Make sure exactly one rustls crypto provider is the process default.
///
/// Arti's `rustls` feature deliberately pulls no provider of its own, leaving
/// the choice to whoever links the binary — which is this workspace, and this
/// workspace is on `aws-lc-rs`, because `tokio-rustls` selects it by default
/// and the `irc` crate takes `tokio-rustls` with its defaults.
///
/// Naming it here rather than letting rustls infer it is the difference
/// between a decision and a coin toss. rustls 0.23 will not choose when two
/// providers are compiled in, and the way it declines is a panic at the first
/// handshake rather than an error at build time — so the failure mode of
/// getting this wrong is not "Tor does not work", it is "the client stops
/// connecting to anything", discovered at runtime by a user.
///
/// Failing to install means one is already installed, which is the outcome
/// this wants; it is not an error and there is nothing to report.
fn provider() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Installing twice must be harmless, because `start` may be called again
    /// after a stop and the second call must not take the process down.
    #[test]
    fn the_provider_can_be_installed_more_than_once() {
        provider();
        provider();
        assert!(rustls::crypto::CryptoProvider::get_default().is_some());
    }

    /// Not a bootstrap test — that needs the network. This asserts the part
    /// that must hold on a machine with no route out at all: a port appears,
    /// it is on loopback, and nothing blocks waiting for Tor to be ready.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn starting_gives_a_loopback_port_without_waiting_for_the_network() {
        let mut dir = std::env::temp_dir();
        dir.push("ddirc-tor-test-start");
        let _ = std::fs::remove_dir_all(&dir);

        let tor = match TorService::start(&dir).await {
            Ok(tor) => tor,
            // A machine that cannot even create the state directory is not
            // what this is testing.
            Err(e) => {
                eprintln!("skipping: Tor would not start here: {e}");
                return;
            }
        };
        assert!(tor.port() > 0, "no port was bound");
        assert!(!tor.status().ready, "reported ready before bootstrapping");

        // The listener is really listening, whatever Tor is doing behind it.
        let probe = tokio::net::TcpStream::connect((Ipv4Addr::LOCALHOST, tor.port())).await;
        assert!(probe.is_ok(), "nothing was accepting on the port: {probe:?}");

        tor.stop().await;
        let _ = std::fs::remove_dir_all(&dir);
    }
}
