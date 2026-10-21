//! End to end against a real XMPP server.
//!
//! `make dev-xmpp` starts ejabberd on 127.0.0.1:5223 with `alice@localhost` and
//! `bob@localhost` registered; `make test-integration-xmpp` runs these.
//!
//! They are the counterpart of `dev_server.rs`, and the reason they exist is
//! the one `xmpp_round_trip.rs` cannot answer: that test talks to a server this
//! crate's author scripted, so it proves the code does what its author
//! expected. This talks to one somebody else wrote. Every assumption about how
//! a room announces its occupants, which id a message carries, or what a
//! carbon looks like is checked here against software that does not share them.
//!
//! All `#[ignore]`d so `cargo test` stays hermetic. They must run one at a time
//! (`--test-threads=1`, which the make target passes): two tests sharing
//! `alice@localhost` would be one account in two places, and a carbon from the
//! other test's session would look like a bug in this one.

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{ConnectionStatus, Target};
use ddirc_core::conn::actor::{ClientCommand, ConnectionHandle};
use ddirc_core::xmpp::actor;
use ddirc_core::xmpp::config::XmppConfig;
use tokio::sync::mpsc::Receiver;
use zeroize::Zeroizing;

const TIMEOUT: Duration = Duration::from_secs(30);

/// Print what `tokio-xmpp` logs, when `DDIRC_XMPP_LOG` is set. Off by default:
/// it is the library describing itself, which is only wanted when a test fails
/// and the reason is inside it.
struct StderrLog;

impl log::Log for StderrLog {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.target().starts_with("tokio_xmpp")
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            eprintln!("[{}] {}", record.level(), record.args());
        }
    }

    fn flush(&self) {}
}

fn trace_library() {
    if std::env::var_os("DDIRC_XMPP_LOG").is_some() {
        let _ = log::set_logger(&StderrLog);
        log::set_max_level(log::LevelFilter::Debug);
    }
}

/// The certificate `dev/xmpp/gen-certs.sh` made, which the client is told to
/// trust in addition to the usual roots.
fn dev_cert() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../dev/xmpp/certs/localhost.crt");
    assert!(
        path.is_file(),
        "no dev certificate at {}; run `make dev-xmpp`",
        path.display()
    );
    path.canonicalize().unwrap().to_string_lossy().into_owned()
}

/// A room name no earlier run used, so a test never meets another's leftovers
/// (the server keeps rooms and their history).
fn unique_room(tag: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("{tag}-{nanos}@conference.localhost")
}

fn account(user: &str, password: &str, rooms: &[&str]) -> XmppConfig {
    XmppConfig {
        jid: format!("{user}@localhost"),
        password: Zeroizing::new(password.to_owned()),
        host: Some("127.0.0.1".to_owned()),
        port: None,
        rooms: rooms.iter().map(|r| (*r).to_owned()).collect(),
        nickname: None,
        extra_root_cert: Some(dev_cert()),
        proxy: None,
    }
}

struct Client {
    handle: ConnectionHandle,
    events: Receiver<IrcEvent>,
    /// What this client has seen, so a test can look back without having
    /// consumed it on the way to something else.
    seen: Vec<IrcEvent>,
}

impl Client {
    fn start(config: XmppConfig) -> Self {
        let (handle, events) = actor::spawn(config);
        Self {
            handle,
            events,
            seen: Vec::new(),
        }
    }

    /// Wait for an event `pick` accepts. Everything before it is kept in
    /// [`Client::seen`].
    async fn wait<T>(&mut self, what: &str, mut pick: impl FnMut(&IrcEvent) -> Option<T>) -> T {
        let deadline = tokio::time::Instant::now() + TIMEOUT;
        loop {
            match tokio::time::timeout_at(deadline, self.events.recv()).await {
                Ok(Some(event)) => {
                    let found = pick(&event);
                    self.seen.push(event);
                    if let Some(found) = found {
                        return found;
                    }
                }
                Ok(None) => panic!(
                    "the actor stopped while waiting for {what}; saw {:#?}",
                    self.seen
                ),
                Err(_) => panic!("timed out waiting for {what}; saw {:#?}", self.seen),
            }
        }
    }

    async fn send(&self, command: ClientCommand) {
        self.handle
            .send(command)
            .await
            .expect("the actor is running");
    }

    async fn say(&self, target: &str, text: &str) {
        self.send(ClientCommand::SendMessage {
            target: target.to_owned(),
            text: text.to_owned(),
        })
        .await;
    }

    /// Wait until we are in `room`, and return who is there.
    async fn joined(&mut self, room: &str) -> Vec<(String, Option<String>)> {
        let room = room.to_owned();
        self.wait("our own join", |e| {
            matches!(e, IrcEvent::Joined { channel, is_self: true, .. } if *channel == room)
                .then_some(())
        })
        .await;
        self.wait("the member list", |e| match e {
            IrcEvent::MemberList { channel, members } if *channel == room => Some(
                members
                    .iter()
                    .map(|m| (m.nick.clone(), m.prefix.clone()))
                    .collect(),
            ),
            _ => None,
        })
        .await
    }

    /// Wait for a message in `target` whose text contains `needle`.
    async fn message(
        &mut self,
        target: Target,
        needle: &str,
    ) -> ddirc_core::api::types::ChatMessage {
        let needle = needle.to_owned();
        self.wait(&format!("a message containing {needle:?}"), |e| match e {
            IrcEvent::Message(m)
                if m.target == target
                    && ddirc_core::text::format::strip(&ddirc_core::text::format::encode(
                        &m.spans,
                    ))
                    .contains(&needle) =>
            {
                Some((**m).clone())
            }
            _ => None,
        })
        .await
    }

    async fn connected(&mut self) {
        self.wait("being connected", |e| {
            matches!(
                e,
                IrcEvent::Status {
                    status: ConnectionStatus::Connected,
                    ..
                }
            )
            .then_some(())
        })
        .await;
    }
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn logs_in_and_enters_a_room_it_creates() {
    let room = unique_room("enter");
    let mut alice = Client::start(account("alice", "hunter2", &[&room]));

    alice.connected().await;
    let registered = alice
        .wait("registration", |e| match e {
            IrcEvent::Registered { nick, network, .. } => Some((nick.clone(), network.clone())),
            _ => None,
        })
        .await;
    assert_eq!(registered.0, "alice@localhost");
    assert_eq!(registered.1.as_deref(), Some("localhost"));

    let members = alice.joined(&room).await;
    assert_eq!(members.len(), 1, "{members:?}");
    assert_eq!(members[0].0, "alice");
    // Whoever creates a room owns it, and the list says so the way IRC does.
    assert_eq!(members[0].1.as_deref(), Some("~"), "{members:?}");
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn two_people_talk_in_a_room() {
    let room = unique_room("talk");
    let mut alice = Client::start(account("alice", "hunter2", &[&room]));
    alice.joined(&room).await;

    let mut bob = Client::start(account("bob", "hunter2", &[&room]));
    let members = bob.joined(&room).await;
    let nicks: Vec<_> = members.iter().map(|(n, _)| n.as_str()).collect();
    assert!(
        nicks.contains(&"alice") && nicks.contains(&"bob"),
        "{members:?}"
    );

    // Alice sees bob arrive.
    alice
        .wait("bob arriving", |e| {
            matches!(e, IrcEvent::Joined { nick, is_self: false, .. } if nick == "bob")
                .then_some(())
        })
        .await;

    bob.say(&room, "hello from bob").await;
    let heard = alice
        .message(Target::Channel(room.clone()), "hello from bob")
        .await;
    assert_eq!(heard.sender, "bob");
    assert!(!heard.is_self);
    assert!(
        heard.msgid.is_some(),
        "the room assigns an id to what is said in it"
    );

    // And what bob said comes back to bob as his own, once - not twice.
    let echoed = bob
        .message(Target::Channel(room.clone()), "hello from bob")
        .await;
    assert!(echoed.is_self);
    assert_eq!(echoed.msgid, heard.msgid, "the same message, the same id");

    alice.say(&room, "hello bob, it's alice").await;
    let reply = bob
        .message(Target::Channel(room.clone()), "hello bob")
        .await;
    assert_eq!(reply.sender, "alice");
    assert_eq!(
        reply.sender_prefix.as_deref(),
        Some("~"),
        "the creator's standing travels with what they say"
    );

    let copies = bob
        .seen
        .iter()
        .filter(|e| matches!(e, IrcEvent::Message(m) if m.is_self))
        .count();
    assert_eq!(copies, 1, "bob's own message was shown {copies} times");
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn a_topic_is_set_and_heard() {
    let room = unique_room("topic");
    let mut alice = Client::start(account("alice", "hunter2", &[&room]));
    alice.joined(&room).await;
    let mut bob = Client::start(account("bob", "hunter2", &[&room]));
    bob.joined(&room).await;

    alice
        .send(ClientCommand::SetTopic {
            channel: room.clone(),
            topic: "release day".to_owned(),
        })
        .await;
    let topic = bob
        .wait("the topic", |e| match e {
            IrcEvent::TopicChanged { topic, set_by, .. } => Some((topic.clone(), set_by.clone())),
            _ => None,
        })
        .await;
    assert_eq!(topic.0, "release day");
    assert_eq!(topic.1.as_deref(), Some("alice"));
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn a_moderator_removes_someone_and_they_are_told() {
    let room = unique_room("kick");
    let mut alice = Client::start(account("alice", "hunter2", &[&room]));
    alice.joined(&room).await;
    let mut bob = Client::start(account("bob", "hunter2", &[&room]));
    bob.joined(&room).await;

    alice
        .send(ClientCommand::Kick {
            channel: room.clone(),
            nick: "bob".to_owned(),
            reason: Some("testing".to_owned()),
        })
        .await;

    let parted = bob
        .wait("being removed", |e| match e {
            IrcEvent::Parted {
                is_self: true,
                reason,
                ..
            } => Some(reason.clone()),
            _ => None,
        })
        .await;
    assert!(parted.is_some(), "the room said why");

    // And alice is told bob has gone.
    alice
        .wait("bob leaving", |e| {
            matches!(e, IrcEvent::Parted { nick, is_self: false, .. } if nick == "bob")
                .then_some(())
        })
        .await;
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn changing_nick_in_a_room_is_one_event_for_everyone() {
    let room = unique_room("nick");
    let mut alice = Client::start(account("alice", "hunter2", &[&room]));
    alice.joined(&room).await;
    let mut bob = Client::start(account("bob", "hunter2", &[&room]));
    bob.joined(&room).await;

    bob.send(ClientCommand::SetNick("robert".to_owned())).await;

    let seen_by_alice = alice
        .wait("bob's new name", |e| match e {
            IrcEvent::NickChanged { old, new, .. } => Some((old.clone(), new.clone())),
            _ => None,
        })
        .await;
    assert_eq!(seen_by_alice, ("bob".to_owned(), "robert".to_owned()));
    let seen_by_bob = bob
        .wait("our own new name", |e| match e {
            IrcEvent::NickChanged {
                is_self: true, new, ..
            } => Some(new.clone()),
            _ => None,
        })
        .await;
    assert_eq!(seen_by_bob, "robert");

    // And he speaks under it.
    bob.say(&room, "call me robert").await;
    let heard = alice
        .message(Target::Channel(room.clone()), "call me robert")
        .await;
    assert_eq!(heard.sender, "robert");
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn a_direct_message_arrives_and_another_device_hears_about_it() {
    let mut bob = Client::start(account("bob", "hunter2", &[]));
    bob.connected().await;
    bob.wait("registration", |e| {
        matches!(e, IrcEvent::Registered { .. }).then_some(())
    })
    .await;

    // Two sessions of the same account: the second is "another device".
    let mut alice = Client::start(account("alice", "hunter2", &[]));
    alice.connected().await;
    let mut phone = Client::start(account("alice", "hunter2", &[]));
    phone.connected().await;
    // Carbons are switched on after login; give both a moment to be.
    tokio::time::sleep(Duration::from_secs(2)).await;

    alice.say("bob@localhost", "psst, bob").await;

    // Bob hears it, from alice's address and not a full JID.
    let heard = bob
        .message(Target::Direct("alice@localhost".to_owned()), "psst, bob")
        .await;
    assert_eq!(heard.sender, "alice@localhost");
    assert!(!heard.is_self);

    // Alice's other device is told she said it: a carbon, and hers.
    let carbon = phone
        .message(Target::Direct("bob@localhost".to_owned()), "psst, bob")
        .await;
    assert!(carbon.is_self, "what our other device says is us speaking");

    // And bob's answer reaches both of alice's.
    bob.say("alice@localhost", "got it").await;
    alice
        .message(Target::Direct("bob@localhost".to_owned()), "got it")
        .await;
    phone
        .message(Target::Direct("bob@localhost".to_owned()), "got it")
        .await;
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn a_private_message_inside_a_room_stays_private() {
    let room = unique_room("pm");
    let mut alice = Client::start(account("alice", "hunter2", &[&room]));
    alice.joined(&room).await;
    let mut bob = Client::start(account("bob", "hunter2", &[&room]));
    bob.joined(&room).await;
    // Alice speaks to bob alone, by his address in the room.
    alice.say(&format!("{room}/bob"), "just between us").await;

    let heard = bob
        .message(Target::Direct(format!("{room}/alice")), "just between us")
        .await;
    assert_eq!(heard.sender, "alice");

    // It was not said to the room: bob's view of the room itself holds nothing
    // of it, and neither does alice's, apart from her own private line.
    for (who, client) in [("alice", &alice), ("bob", &bob)] {
        let in_room = client.seen.iter().any(|e| {
            matches!(e, IrcEvent::Message(m)
                if m.target == Target::Channel(room.clone())
                    && ddirc_core::text::format::strip(&ddirc_core::text::format::encode(&m.spans))
                        .contains("just between us"))
        });
        assert!(!in_room, "{who} saw a private message in the room");
    }
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn a_wrong_password_is_reported_and_not_retried() {
    let mut mallory = Client::start(account("alice", "not-the-password", &[]));
    let message = mallory
        .wait("the refusal", |e| match e {
            IrcEvent::Error {
                message,
                fatal: true,
            } => Some(message.clone()),
            _ => None,
        })
        .await;
    assert!(message.contains("password"), "{message}");

    // Past the first backoff: a client that were going to try again has.
    tokio::time::sleep(Duration::from_secs(4)).await;
    let retried = mallory.seen.iter().any(|e| {
        matches!(
            e,
            IrcEvent::Status {
                status: ConnectionStatus::Reconnecting { .. },
                ..
            }
        )
    });
    assert!(!retried, "{:#?}", mallory.seen);
}

#[tokio::test]
#[ignore = "needs `make dev-xmpp`"]
async fn the_connection_test_logs_in_and_says_who() {
    let report = ddirc_core::xmpp::probe::probe(account("alice", "hunter2", &[]))
        .await
        .expect("the right password logs in");
    assert_eq!(report.nickname, "alice@localhost");
    assert_eq!(report.server.as_deref(), Some("localhost"));

    let refused = ddirc_core::xmpp::probe::probe(account("alice", "wrong", &[]))
        .await
        .expect_err("a wrong password is an error");
    assert!(refused.contains("password"), "{refused}");
}

/// Restart the dev server under a live session: the one test that stops the
/// thing it is talking to, which is why it is last and why it needs the docker
/// command as well as the server.
#[tokio::test]
#[ignore = "needs `make dev-xmpp`, and restarts it"]
async fn recovers_and_rejoins_when_the_server_restarts() {
    trace_library();
    let room = unique_room("restart");
    let mut alice = Client::start(account("alice", "hunter2", &[&room]));
    alice.joined(&room).await;
    let before = alice.seen.len();

    let restarted = std::process::Command::new("docker")
        .args(["restart", "ddirc-dev-xmppd"])
        .output()
        .expect("the docker command runs");
    assert!(
        restarted.status.success(),
        "{}",
        String::from_utf8_lossy(&restarted.stderr)
    );

    // The connection is noticed as lost and is not given up on: it was working,
    // so it is the kind worth resuming. (The first attempts may fail while the
    // server is coming back; those are retried, not reported as fatal.)
    alice
        .wait("reconnecting", |e| {
            matches!(
                e,
                IrcEvent::Status {
                    status: ConnectionStatus::Reconnecting { .. },
                    ..
                }
            )
            .then_some(())
        })
        .await;

    // Then logged in again from scratch - the server forgot the session - and
    // back in the room, which it also forgot.
    alice
        .wait("registering again", |e| {
            matches!(e, IrcEvent::Registered { .. }).then_some(())
        })
        .await;
    let members = alice.joined(&room).await;
    assert_eq!(members[0].0, "alice", "{members:?}");

    let fatal = alice.seen[before..]
        .iter()
        .any(|e| matches!(e, IrcEvent::Error { fatal: true, .. }));
    assert!(!fatal, "{:#?}", &alice.seen[before..]);

    // And it works afterwards.
    alice.say(&room, "back again").await;
    alice
        .message(Target::Channel(room.clone()), "back again")
        .await;
}
