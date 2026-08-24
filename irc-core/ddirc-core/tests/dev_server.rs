//! End-to-end tests against the local dev server.
//!
//! Unlike the transcript tests, which feed scripted lines into the dispatch
//! path, these drive a real socket: real TLS with certificate verification,
//! real registration, real `ISUPPORT`, real server-side state. They are the
//! only tests that can catch a break between our protocol handling and a server
//! that disagrees with it.
//!
//! Every test is `#[ignore]`d, because `cargo test` has to stay hermetic — it
//! runs in CI and on machines with no Docker. Start the server first:
//!
//! ```text
//! make dev-server
//! make test-integration
//! ```
//!
//! The server's certificate is self-signed, so each config points
//! `extra_root_cert` at it. That *adds* a trusted root; it does not disable
//! verification, and the field is unreachable from the app.

use std::path::{Path, PathBuf};
use std::time::Duration;

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{AuthOutcome, ConnectionStatus, ServerConfig, Target};
use ddirc_core::conn::actor::{self, ClientCommand, ConnectionHandle};
use tokio::sync::mpsc::Receiver;

/// Generous: a failure here should read as "the server never said it", not as a
/// flake on a loaded machine.
const TIMEOUT: Duration = Duration::from_secs(20);

/// The certificate `make dev-server` generated.
fn cert() -> PathBuf {
    if let Ok(path) = std::env::var("DDIRC_DEV_CERT") {
        return PathBuf::from(path);
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../dev/ergo/fullchain.pem")
}

fn config(nick: &str) -> ServerConfig {
    let cert = cert();
    assert!(
        cert.is_file(),
        "no dev server certificate at {}; run `make dev-server` first",
        cert.display()
    );
    ServerConfig {
        host: "localhost".to_owned(),
        port: ServerConfig::DEFAULT_TLS_PORT,
        nickname: nick.to_owned(),
        extra_root_cert: Some(cert.to_string_lossy().into_owned()),
        ..Default::default()
    }
}

/// Pull events until `want` matches one, then return what it extracted.
///
/// A fatal error short-circuits with the server's own words, so a broken
/// assumption reports the reason rather than a bare timeout.
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
        if let IrcEvent::Error {
            message,
            fatal: true,
        } = &event
        {
            panic!("fatal error from the server: {message}");
        }
        seen.push(event);
    }
}

/// Connect and wait until registration completes.
async fn connect(nick: &str) -> (ConnectionHandle, Receiver<IrcEvent>) {
    let (handle, mut rx) = actor::spawn(config(nick));
    let registered = wait_for(&mut rx, |event| match event {
        IrcEvent::Registered { nick, auth, .. } => Some((nick.clone(), auth.clone())),
        _ => None,
    })
    .await;
    assert_eq!(registered.0, nick, "server assigned a different nick");
    assert_eq!(registered.1, AuthOutcome::Anonymous);
    (handle, rx)
}

/// Join and wait until the server confirms *we* are in.
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

async fn disconnect(handle: ConnectionHandle) {
    let _ = handle
        .send(ClientCommand::Disconnect {
            reason: Some("test over".to_owned()),
        })
        .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs the dev server: make dev-server"]
async fn connects_over_tls_and_registers() {
    let (handle, mut rx) = connect("ddirc_reg").await;

    // ISUPPORT lands after the welcome numeric, which is exactly why the core
    // reports the network separately instead of on Registered.
    let network = wait_for(&mut rx, |event| match event {
        IrcEvent::NetworkNamed { network } => Some(network.clone()),
        _ => None,
    })
    .await;
    assert_eq!(network, "ErgoTest");

    disconnect(handle).await;
}

/// The one that guards the others.
///
/// `extra_root_cert` must be the *only* reason the dev server is reachable. If
/// this ever passes registration, verification has been weakened somewhere and
/// every other test here is proving nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs the dev server: make dev-server"]
async fn refuses_the_self_signed_certificate_without_the_extra_root() {
    let config = ServerConfig {
        extra_root_cert: None,
        ..config("ddirc_untrusting")
    };
    let (handle, mut rx) = actor::spawn(config);

    wait_for(&mut rx, |event| match event {
        IrcEvent::Registered { .. } => {
            panic!(
                "registered against an untrusted certificate: verification is not being enforced"
            )
        }
        // The handshake failure surfaces as a lost connection heading into
        // backoff, or as a plain error, depending on where rustls gives up.
        IrcEvent::Status {
            status: ConnectionStatus::Reconnecting { .. },
            ..
        } => Some(()),
        IrcEvent::Error { .. } => Some(()),
        _ => None,
    })
    .await;

    disconnect(handle).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs the dev server: make dev-server"]
async fn joining_yields_a_member_list_containing_us() {
    let (handle, mut rx) = connect("ddirc_join").await;
    join(&handle, &mut rx, "#ddirc-join").await;

    let members = wait_for(&mut rx, |event| match event {
        IrcEvent::MemberList { channel, members } if channel == "#ddirc-join" => {
            Some(members.clone())
        }
        _ => None,
    })
    .await;
    assert!(
        members.iter().any(|m| m.nick == "ddirc_join"),
        "we are not in our own member list: {members:?}"
    );

    disconnect(handle).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs the dev server: make dev-server"]
async fn carries_a_message_between_two_clients() {
    const CHANNEL: &str = "#ddirc-talk";

    let (listener, mut listener_rx) = connect("ddirc_ears").await;
    join(&listener, &mut listener_rx, CHANNEL).await;

    let (speaker, mut speaker_rx) = connect("ddirc_mouth").await;
    join(&speaker, &mut speaker_rx, CHANNEL).await;

    // Wait until the listener has actually seen the speaker arrive; sending
    // before that would race the server's own join broadcast.
    wait_for(&mut listener_rx, |event| match event {
        IrcEvent::Joined { nick, .. } if nick == "ddirc_mouth" => Some(()),
        _ => None,
    })
    .await;

    speaker
        .send(ClientCommand::SendMessage {
            target: CHANNEL.to_owned(),
            text: "hello from the other side".to_owned(),
        })
        .await
        .expect("actor stopped");

    let message = wait_for(&mut listener_rx, |event| match event {
        IrcEvent::Message(message) if message.sender == "ddirc_mouth" => Some(message.clone()),
        _ => None,
    })
    .await;

    assert_eq!(message.target, Target::Channel(CHANNEL.to_owned()));
    assert!(!message.is_self);
    let text: String = message.spans.iter().map(|s| s.text.as_str()).collect();
    assert_eq!(text, "hello from the other side");

    disconnect(speaker).await;
    disconnect(listener).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs the dev server: make dev-server"]
async fn sets_a_topic_and_hears_it_back() {
    const CHANNEL: &str = "#ddirc-topic";

    let (handle, mut rx) = connect("ddirc_topic").await;
    join(&handle, &mut rx, CHANNEL).await;

    handle
        .send(ClientCommand::SetTopic {
            channel: CHANNEL.to_owned(),
            topic: "set by an integration test".to_owned(),
        })
        .await
        .expect("actor stopped");

    let topic = wait_for(&mut rx, |event| match event {
        IrcEvent::TopicChanged {
            channel,
            topic,
            set_by: Some(_),
        } if channel == CHANNEL => Some(topic.clone()),
        _ => None,
    })
    .await;
    assert_eq!(topic, "set by an integration test");

    disconnect(handle).await;
}
