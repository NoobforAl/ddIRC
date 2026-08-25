//! The real client, against the real server, over real TLS.
//!
//! These are the tests that prove the decision in `lib.rs` actually works: that
//! a server issuing itself a certificate is reachable from a client which
//! verifies certificates and has no bypass.
//!
//! Unlike `ddirc-core/tests/dev_server.rs`, none of these are `#[ignore]`d.
//! There is nothing to install and nothing to start — the server is the crate
//! under test, and it binds an ephemeral loopback port. That is the whole point
//! of it existing, and it means the client's connection path is now exercised
//! by `cargo test` on a machine with no Docker and no network.

use std::path::PathBuf;
use std::time::Duration;

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::ServerConfig;
use ddirc_core::conn::actor::{self, ClientCommand, ConnectionHandle};
use ddirc_server::{Config, LocalServer};
use tokio::sync::mpsc::Receiver;

const TIMEOUT: Duration = Duration::from_secs(20);

/// A directory that cleans itself up, so no test leaves a CA behind.
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let mut p = std::env::temp_dir();
        p.push(format!("ddirc-server-test-{tag}"));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

async fn start(tag: &str) -> (LocalServer, TempDir) {
    let dir = TempDir::new(tag);
    let server = LocalServer::start(Config::new(&dir.0))
        .await
        .expect("the local server should bind a loopback port");
    (server, dir)
}

/// A client configuration pointed at `server`, trusting what it issued itself.
fn config(server: &LocalServer, nick: &str, trust: bool) -> ServerConfig {
    ServerConfig {
        host: "127.0.0.1".to_owned(),
        port: server.port(),
        nickname: nick.to_owned(),
        extra_root_cert: trust.then(|| server.anchor_path().to_string_lossy().into_owned()),
        ..Default::default()
    }
}

async fn wait_for<T>(
    rx: &mut Receiver<IrcEvent>,
    mut want: impl FnMut(&IrcEvent) -> Option<T>,
) -> T {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    let mut seen = Vec::new();
    loop {
        let event = match tokio::time::timeout_at(deadline, rx.recv()).await {
            Ok(Some(event)) => event,
            Ok(None) => panic!("event stream closed early; saw: {seen:#?}"),
            Err(_) => panic!("timed out after {TIMEOUT:?}; saw: {seen:#?}"),
        };
        if let Some(value) = want(&event) {
            return value;
        }
        seen.push(event);
    }
}

async fn connect(server: &LocalServer, nick: &str) -> (ConnectionHandle, Receiver<IrcEvent>) {
    let (handle, mut rx) = actor::spawn(config(server, nick, true));
    let got = wait_for(&mut rx, |event| match event {
        IrcEvent::Registered { nick, .. } => Some(nick.clone()),
        _ => None,
    })
    .await;
    assert_eq!(got, nick, "the server assigned a different nick");
    (handle, rx)
}

async fn join(handle: &ConnectionHandle, rx: &mut Receiver<IrcEvent>, channel: &str) {
    handle
        .send(ClientCommand::Join {
            channel: channel.to_owned(),
            key: None,
        })
        .await
        .expect("actor stopped");
    wait_for(rx, |event| match event {
        IrcEvent::Joined {
            channel: c,
            is_self: true,
            ..
        } if c == channel => Some(()),
        _ => None,
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_client_registers_against_the_server_it_ships_with() {
    let (server, _dir) = start("register").await;
    let (handle, mut rx) = connect(&server, "alice").await;

    // ISUPPORT arrives after the welcome, which is why the core reports the
    // network separately — and it is what the rail labels the connection.
    let network = wait_for(&mut rx, |event| match event {
        IrcEvent::NetworkNamed { network } => Some(network.clone()),
        _ => None,
    })
    .await;
    assert_eq!(network, "Local");

    let _ = handle
        .send(ClientCommand::Disconnect { reason: None })
        .await;
    server.stop().await;
}

/// The one that guards the others.
///
/// The certificate the server issues itself must be the *only* reason it is
/// reachable. If this ever registers, verification has been weakened somewhere
/// and every other test in this file is proving nothing — which is the same
/// guarantee `dev_server.rs` holds for the dev server, and it matters more
/// here, because this certificate is one the app generated rather than one a
/// developer went and fetched.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn without_the_anchor_the_same_connection_is_refused() {
    let (server, _dir) = start("untrusted").await;
    let (_handle, mut rx) = actor::spawn(config(&server, "mallory", false));

    // A refused certificate is not a fatal error to the core — it is a failed
    // attempt, and the connection goes into backoff like any other. So the
    // refusal arrives as the detail on a reconnecting status, which is also
    // where the user reads it.
    let message = wait_for(&mut rx, |event| match event {
        IrcEvent::Error { message, .. } => Some(message.clone()),
        IrcEvent::Status {
            detail: Some(detail),
            ..
        } => Some(detail.clone()),
        IrcEvent::Registered { .. } => {
            panic!("registered without trusting the anchor: verification is not being enforced")
        }
        _ => None,
    })
    .await;

    let lower = message.to_lowercase();
    assert!(
        lower.contains("does not trust") || lower.contains("certificate"),
        "the refusal should name the certificate, said: {message}"
    );
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_clients_can_hold_a_conversation() {
    let (server, _dir) = start("conversation").await;
    let (alice, mut alice_rx) = connect(&server, "alice").await;
    let (bob, mut bob_rx) = connect(&server, "bob").await;

    join(&alice, &mut alice_rx, "#room").await;
    join(&bob, &mut bob_rx, "#room").await;

    // alice sees bob arrive, which is the server's broadcast rather than
    // anything either client worked out for itself.
    wait_for(&mut alice_rx, |event| match event {
        IrcEvent::Joined {
            nick,
            is_self: false,
            ..
        } if nick == "bob" => Some(()),
        _ => None,
    })
    .await;

    alice
        .send(ClientCommand::SendMessage {
            target: "#room".to_owned(),
            text: "hello from the other side".to_owned(),
        })
        .await
        .expect("actor stopped");

    let (sender, text) = wait_for(&mut bob_rx, |event| match event {
        IrcEvent::Message(message) => Some((
            message.sender.clone(),
            // Reassembled from the spans the core split it into, which is the
            // form the UI renders rather than the raw line.
            message
                .spans
                .iter()
                .map(|s| s.text.as_str())
                .collect::<String>(),
        )),
        _ => None,
    })
    .await;
    assert_eq!(sender, "alice");
    assert_eq!(text, "hello from the other side");

    let _ = alice.send(ClientCommand::Disconnect { reason: None }).await;
    let _ = bob.send(ClientCommand::Disconnect { reason: None }).await;
    server.stop().await;
}

/// The anchor has to outlive a restart, or the app would have to be told to
/// trust a new certificate every time it launched.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restarted_server_is_still_trusted() {
    let dir = TempDir::new("restart");
    let first = LocalServer::start(Config::new(&dir.0)).await.unwrap();
    let port = first.port();
    let (handle, _rx) = connect(&first, "alice").await;
    let _ = handle
        .send(ClientCommand::Disconnect { reason: None })
        .await;
    first.stop().await;

    // The same port on purpose: the client's saved profile keeps one, and a
    // server that moved every launch would be a profile that stopped working.
    let mut config = Config::new(&dir.0);
    config.port = port;
    let second = LocalServer::start(config).await.unwrap();
    let (handle, _rx) = connect(&second, "alice").await;
    let _ = handle
        .send(ClientCommand::Disconnect { reason: None })
        .await;
    second.stop().await;
}
