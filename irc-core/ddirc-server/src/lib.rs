//! A small IRC server that runs inside ddIRC.
//!
//! # What it is for
//!
//! Somewhere to talk that does not need a daemon installed, an account made, or
//! a network's permission: a scratch network for trying things out, a place to
//! develop against without `dev/`'s Docker, and a target that is there when
//! nothing else is.
//!
//! # Loopback only, and that is a decision rather than a first step
//!
//! It binds `127.0.0.1` and `::1`, and nothing else. The open question in the
//! roadmap was whether it should listen further than that, and the answer is
//! no, for a reason that outlives the first version:
//!
//! Reaching this server from *another machine* means that machine's client has
//! to be given a trust anchor, because the certificate here is issued locally
//! and no public authority will ever vouch for it. Handing someone a
//! certificate to install is precisely the control this codebase has refused to
//! build — `extra_root_cert` is deliberately absent from the FFI type so that
//! nothing a user can be talked into typing becomes a trusted root. A local
//! server is not a good enough reason to open that door, and opening it for
//! this would open it for everything.
//!
//! The other half of the answer is duller and just as real: a server anyone
//! else can reach needs a routable address, a way through NAT, and a port
//! nobody else has taken. An app cannot arrange those, and pretending otherwise
//! produces a feature that works on the developer's machine.
//!
//! There is a real answer for *reachable from elsewhere*, and it is not a
//! bigger listener: publish it as an onion service, where the address is the
//! key, NAT stops mattering, and Tor authenticates which service answered. That
//! depends on shipping Tor, which is its own roadmap item — so the order the
//! two want doing in is Tor first, this second.
//!
//! # TLS, because the client will not accept anything else
//!
//! `ddirc-core` sets `use_tls` unconditionally and has no bypass, so a
//! plaintext local server would be unreachable from the app it lives in. It
//! therefore speaks real TLS with a certificate the client really verifies.
//! [`identity`] holds the whole argument for why generating one is safe here
//! when trusting a supplied one would not be.

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};

use tokio::net::TcpListener;
use tokio::sync::mpsc::unbounded_channel;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

pub mod identity;
mod session;
pub mod state;

use session::Event;
use state::{ClientId, Network, DEFAULT_NETWORK_NAME, DEFAULT_SERVER_NAME};

#[derive(Debug, thiserror::Error)]
pub enum ServerError {
    #[error("the local server could not listen on port {port}: {source}")]
    Listen {
        port: u16,
        #[source]
        source: std::io::Error,
    },
    #[error(transparent)]
    Identity(#[from] identity::IdentityError),
    #[error("the local server's certificate was refused by TLS: {0}")]
    Tls(#[from] rustls::Error),
}

/// How to start the server.
#[derive(Debug, Clone)]
pub struct Config {
    /// `0` asks the operating system for a free one, which is the sensible
    /// default: nothing else needs to know the number in advance, and a fixed
    /// port is a port something else can already be holding.
    pub port: u16,
    /// What the server calls itself in its own messages.
    pub server_name: String,
    /// What it calls the network, which is what the client's rail labels it.
    pub network_name: String,
    /// Where the CA lives. The app's own private data directory.
    pub data_dir: PathBuf,
}

impl Config {
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        Self {
            port: 0,
            server_name: DEFAULT_SERVER_NAME.to_owned(),
            network_name: DEFAULT_NETWORK_NAME.to_owned(),
            data_dir: data_dir.into(),
        }
    }
}

/// A running server. Dropping it stops it.
pub struct LocalServer {
    port: u16,
    anchor_path: PathBuf,
    shutdown: Option<oneshot::Sender<()>>,
    tasks: Vec<JoinHandle<()>>,
}

impl LocalServer {
    /// Bind, and start accepting.
    ///
    /// Returns once the listener is up, so a caller that connects immediately
    /// afterwards will not race the bind. Everything after that happens on its
    /// own tasks.
    pub async fn start(config: Config) -> Result<Self, ServerError> {
        let identity = identity::load_or_create(&config.data_dir)?;
        let anchor_path = identity.anchor_path.clone();
        let acceptor = session::acceptor(identity.chain, identity.key)?;

        let v4 = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, config.port)))
            .await
            .map_err(|source| ServerError::Listen {
                port: config.port,
                source,
            })?;
        let port = v4.local_addr().map(|a| a.port()).unwrap_or(config.port);

        // The same port on IPv6, so that `localhost` works whichever way it
        // resolves. Not fatal if it fails: a machine with IPv6 turned off is
        // an ordinary machine, and `127.0.0.1` still reaches the server.
        let v6 = match TcpListener::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, port))).await {
            Ok(listener) => Some(listener),
            Err(e) => {
                tracing::debug!("local server: no IPv6 loopback listener ({e})");
                None
            }
        };

        let (events_tx, mut events_rx) = unbounded_channel::<Event>();
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel::<()>();

        let mut network = Network::new(config.server_name, config.network_name);
        let state = tokio::spawn(async move {
            while let Some(event) = events_rx.recv().await {
                match event {
                    Event::Connected { id, tx } => network.connect(id, tx),
                    Event::Line { id, message } => network.handle(id, *message),
                    Event::Disconnected { id, reason } => network.disconnect(id, &reason),
                }
            }
        });

        let accept = tokio::spawn(async move {
            let mut next: ClientId = 1;
            loop {
                let accepted = tokio::select! {
                    // Biased so shutdown wins a tie. Otherwise a server being
                    // stopped under load can keep accepting indefinitely.
                    biased;
                    _ = &mut shutdown_rx => break,
                    result = v4.accept() => result,
                    result = accept_from(v6.as_ref()) => result,
                };

                match accepted {
                    Ok((socket, _)) => {
                        let id = next;
                        next += 1;
                        tokio::spawn(session::serve(
                            id,
                            socket,
                            acceptor.clone(),
                            events_tx.clone(),
                        ));
                    }
                    // One connection failing to arrive says nothing about the
                    // next one; the listener is still bound and still ours.
                    Err(e) => tracing::debug!("local server: accept failed: {e}"),
                }
            }
        });

        tracing::info!("local server listening on 127.0.0.1:{port}");
        Ok(Self {
            port,
            anchor_path,
            shutdown: Some(shutdown_tx),
            tasks: vec![accept, state],
        })
    }

    /// The port it actually bound, which is what the app has to connect to.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The certificate the client must trust to reach it.
    ///
    /// This is what the app puts in `extra_root_cert` for this one connection,
    /// and it is a certificate the app issued to itself — see [`identity`].
    pub fn anchor_path(&self) -> &Path {
        &self.anchor_path
    }

    /// Stop accepting, and wait until it has.
    pub async fn stop(mut self) {
        self.signal();
        for task in std::mem::take(&mut self.tasks) {
            let _ = task.await;
        }
    }

    fn signal(&mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
    }
}

impl Drop for LocalServer {
    /// Stops the listener even when nobody called [`LocalServer::stop`].
    ///
    /// A server that outlived its handle would keep a port bound with no way
    /// left to reach it, which is the sort of thing that only shows up as the
    /// next start failing.
    fn drop(&mut self) {
        self.signal();
        for task in &self.tasks {
            task.abort();
        }
    }
}

/// `accept` on a listener that may not exist.
///
/// A never-resolving future stands in for the missing IPv6 listener so the
/// `select!` above can be written once rather than twice.
async fn accept_from(
    listener: Option<&TcpListener>,
) -> std::io::Result<(tokio::net::TcpStream, SocketAddr)> {
    match listener {
        Some(listener) => listener.accept().await,
        None => std::future::pending().await,
    }
}
