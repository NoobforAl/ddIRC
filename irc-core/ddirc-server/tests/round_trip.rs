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
use ddirc_core::api::types::{ConnectionStatus, ServerConfig};
use ddirc_core::conn::actor::{self, ClientCommand, ConnectionHandle};
use ddirc_server::{AdminCommand, Config, EventKind, LocalServer};
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

/// What someone types on the way out has to be what the room reads.
///
/// Two things had to be true for this: the client has to let the `QUIT` leave
/// before it drops the connection, and the server has to take it as the end of
/// the link rather than waiting for the socket to say so.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn what_someone_says_on_the_way_out_is_what_the_room_reads() {
    let (server, _dir) = start("quit").await;
    let (alice, mut alice_rx) = connect(&server, "alice").await;
    let (bob, mut bob_rx) = connect(&server, "bob").await;
    join(&alice, &mut alice_rx, "#room").await;
    join(&bob, &mut bob_rx, "#room").await;

    bob.send(ClientCommand::Disconnect {
        reason: Some("gone fishing".to_owned()),
    })
    .await
    .expect("actor stopped");

    let reason = wait_for(&mut alice_rx, |event| match event {
        IrcEvent::Quit { nick, reason, .. } if nick == "bob" => Some(reason.clone()),
        _ => None,
    })
    .await;
    assert_eq!(reason.as_deref(), Some("gone fishing"));

    let _ = alice.send(ClientCommand::Disconnect { reason: None }).await;
    server.stop().await;
}

/// The operator's hand on a live server: what a kick looks like to the person
/// kicked, and that closing a connection really closes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_operator_can_remove_people_from_a_running_server() {
    let (server, _dir) = start("operator").await;
    let admin = server.handle();
    let (alice, mut alice_rx) = connect(&server, "alice").await;
    let (bob, mut bob_rx) = connect(&server, "bob").await;
    join(&alice, &mut alice_rx, "#room").await;
    join(&bob, &mut bob_rx, "#room").await;

    let snapshot = admin.snapshot().await.expect("the server is running");
    let nicks: Vec<_> = snapshot
        .users
        .iter()
        .filter_map(|u| u.nick.as_deref())
        .collect();
    assert_eq!(nicks, vec!["alice", "bob"]);
    assert_eq!(snapshot.channels[0].name, "#room");

    // Words the operator typed have to be shown, not mistaken for the server
    // chatter a client discards.
    admin
        .execute(AdminCommand::Notice {
            target: "#room".to_owned(),
            text: "heads up".to_owned(),
        })
        .await
        .expect("#room exists");
    let (sender, text) = wait_for(&mut bob_rx, |event| match event {
        IrcEvent::Message(m) if m.is_notice => Some((
            m.sender.clone(),
            m.spans.iter().map(|s| s.text.as_str()).collect::<String>(),
        )),
        _ => None,
    })
    .await;
    assert_eq!(
        (sender.as_str(), text.as_str()),
        ("ddirc.local", "heads up")
    );

    // To the person removed, it arrives as their own departure with the
    // reason attached — which is how the core reports a kick.
    admin
        .execute(AdminCommand::Kick {
            channel: "#room".to_owned(),
            nick: "bob".to_owned(),
            reason: Some("house rules".to_owned()),
        })
        .await
        .expect("bob is in #room");
    let reason = wait_for(&mut bob_rx, |event| match event {
        IrcEvent::Parted {
            is_self: true,
            reason,
            ..
        } => Some(reason.clone()),
        _ => None,
    })
    .await;
    assert_eq!(reason.as_deref(), Some("kicked by the server: house rules"));

    // A refusal comes back as words, not as silence.
    let refusal = admin
        .execute(AdminCommand::Kick {
            channel: "#room".to_owned(),
            nick: "bob".to_owned(),
            reason: None,
        })
        .await;
    assert_eq!(refusal, Err("bob is not in #room".to_owned()));

    // Closing the connection has to close it for real. The client sees its
    // link go, and starts trying to get it back.
    admin
        .execute(AdminCommand::Disconnect {
            nick: "alice".to_owned(),
            reason: Some("maintenance".to_owned()),
        })
        .await
        .expect("alice is connected");
    wait_for(&mut alice_rx, |event| match event {
        IrcEvent::Status {
            status: ConnectionStatus::Reconnecting { .. } | ConnectionStatus::Disconnected,
            ..
        } => Some(()),
        _ => None,
    })
    .await;

    let _ = alice.send(ClientCommand::Disconnect { reason: None }).await;
    let _ = bob.send(ClientCommand::Disconnect { reason: None }).await;
    server.stop().await;

    // And a handle that outlives its server says so rather than hanging.
    assert_eq!(admin.snapshot().await, None);
    assert!(admin
        .execute(AdminCommand::Wall {
            text: "anyone?".to_owned()
        })
        .await
        .is_err());
}

/// A server with a keepalive short enough to watch.
async fn start_with_keepalive(tag: &str) -> (LocalServer, TempDir) {
    let dir = TempDir::new(tag);
    let mut config = Config::new(&dir.0);
    config.ping_after = Duration::from_millis(150);
    config.ping_timeout = Duration::from_millis(500);
    let server = LocalServer::start(config)
        .await
        .expect("the local server should bind a loopback port");
    (server, dir)
}

/// Being quiet is not being gone. A client that answers the server's `PING`
/// has to survive any number of keepalive rounds and still be able to talk.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_client_that_answers_is_never_dropped_for_being_quiet() {
    let (server, _dir) = start_with_keepalive("keepalive-alive").await;
    let (alice, mut alice_rx) = connect(&server, "alice").await;
    let (bob, mut bob_rx) = connect(&server, "bob").await;
    join(&alice, &mut alice_rx, "#room").await;
    join(&bob, &mut bob_rx, "#room").await;

    // Five or six rounds of ask-and-answer, with nobody saying a word.
    tokio::time::sleep(Duration::from_millis(1800)).await;

    alice
        .send(ClientCommand::SendMessage {
            target: "#room".to_owned(),
            text: "still here".to_owned(),
        })
        .await
        .expect("actor stopped");
    let text = wait_for(&mut bob_rx, |event| match event {
        IrcEvent::Message(m) => Some(m.spans.iter().map(|s| s.text.as_str()).collect::<String>()),
        _ => None,
    })
    .await;
    assert_eq!(text, "still here");

    let snapshot = server.handle().snapshot().await.expect("running");
    assert_eq!(snapshot.users.len(), 2, "nobody was dropped");

    let _ = alice.send(ClientCommand::Disconnect { reason: None }).await;
    let _ = bob.send(ClientCommand::Disconnect { reason: None }).await;
    server.stop().await;
}

/// The reverse, and the reason the keepalive exists: a connection that registers
/// and then says nothing at all — an app killed mid-session, a phone that left
/// the network — is asked, and then dropped, and its name is free again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_client_that_goes_silent_is_asked_then_dropped_and_its_nick_freed() {
    use std::sync::Arc;

    use rustls::pki_types::pem::PemObject;
    use rustls::pki_types::{CertificateDer, ServerName};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let (server, _dir) = start_with_keepalive("keepalive-silent").await;
    let handle = server.handle();
    let mut events = handle.subscribe();

    // A bare TLS connection, trusting what the server issued, that speaks the
    // registration and then never reads or writes again.
    let mut roots = rustls::RootCertStore::empty();
    let pem = std::fs::read(server.anchor_path()).expect("the anchor is on disk");
    for cert in CertificateDer::pem_slice_iter(&pem) {
        roots
            .add(cert.expect("a certificate"))
            .expect("a usable anchor");
    }
    let tls_config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("protocol versions")
    .with_root_certificates(roots)
    .with_no_client_auth();
    let tcp = tokio::net::TcpStream::connect(("127.0.0.1", server.port()))
        .await
        .expect("connect");
    let mut ghost = tokio_rustls::TlsConnector::from(Arc::new(tls_config))
        .connect(ServerName::try_from("127.0.0.1").unwrap(), tcp)
        .await
        .expect("handshake");
    ghost
        .write_all(b"NICK ghost\r\nUSER ghost 0 * :Ghost\r\n")
        .await
        .expect("register");

    // Read until welcomed, then say nothing and answer nothing.
    let mut heard = String::new();
    let mut buf = [0u8; 4096];
    while !heard.contains(" 001 ghost ") {
        let n = tokio::time::timeout(TIMEOUT, ghost.read(&mut buf))
            .await
            .expect("welcomed in time")
            .expect("read");
        assert!(n > 0, "closed before the welcome");
        heard.push_str(&String::from_utf8_lossy(&buf[..n]));
    }

    // Everything the server sends from here, until it hangs up. It must have
    // asked, and then it must have closed the connection.
    let mut after = String::new();
    loop {
        match tokio::time::timeout(TIMEOUT, ghost.read(&mut buf)).await {
            Ok(Ok(0)) | Ok(Err(_)) => break,
            Ok(Ok(n)) => after.push_str(&String::from_utf8_lossy(&buf[..n])),
            Err(_) => panic!("the server never hung up; heard: {after:?}"),
        }
    }
    assert!(
        after.contains("PING ddirc.local"),
        "it asked first: {after:?}"
    );

    // The operator's view says why.
    let reason = wait_for_event(&mut events, |kind| match kind {
        EventKind::Quit { nick, reason } if nick == "ghost" => Some(reason.clone()),
        _ => None,
    })
    .await;
    assert!(reason.starts_with("Ping timeout"), "{reason}");
    let snapshot = handle.snapshot().await.expect("running");
    assert!(snapshot.users.is_empty(), "{:?}", snapshot.users);

    // And the name is free: somebody else can be ghost now.
    let (again, _rx) = connect(&server, "ghost").await;
    let _ = again.send(ClientCommand::Disconnect { reason: None }).await;
    server.stop().await;
}

async fn wait_for_event<T>(
    events: &mut tokio::sync::broadcast::Receiver<ddirc_server::ServerEvent>,
    mut want: impl FnMut(&EventKind) -> Option<T>,
) -> T {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    loop {
        match tokio::time::timeout_at(deadline, events.recv()).await {
            Ok(Ok(event)) => {
                if let Some(value) = want(&event.kind) {
                    return value;
                }
            }
            Ok(Err(e)) => panic!("event stream ended: {e}"),
            Err(_) => panic!("timed out waiting for a server event"),
        }
    }
}
