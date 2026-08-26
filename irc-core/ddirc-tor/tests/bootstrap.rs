//! The two things about bundled Tor that only the real network can answer.
//!
//! Both are `#[ignore]`d, for the same reason `dev_server.rs` is: they need
//! something this machine does not supply, and a suite that fails on an
//! aeroplane is a suite people learn to ignore. Run them deliberately:
//!
//! ```text
//! cargo test -p ddirc-tor -- --ignored --nocapture
//! ```
//!
//! `--nocapture` matters. The interesting output of the first one is the
//! bootstrap commentary and the time it took, and that is the number the
//! decision to ship this rests on.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{ProxyConfig, ServerConfig};
use ddirc_core::conn::actor::{self, ClientCommand};
use ddirc_tor::TorService;

/// Long, because the honest answer to "how long does Tor take to start" is
/// "it depends on the network you are on", and a test that gives up early
/// would report a censored network as a broken client.
const BOOTSTRAP_LIMIT: Duration = Duration::from_secs(600);

/// A directory that cleans itself up.
struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let mut p = std::env::temp_dir();
        p.push(format!("ddirc-tor-test-{tag}"));
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

/// Turn on Arti's own logging, if the caller asked for it.
///
/// Installed rather than assumed: without a subscriber, `RUST_LOG` sets
/// nothing and a bootstrap that stalls says nothing about why. That silence is
/// not evidence of anything, which is the trap worth avoiding when the whole
/// point of these tests is to find out what is happening.
fn logging() {
    let filter = std::env::var("RUST_LOG").unwrap_or_else(|_| "warn".to_owned());
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_test_writer()
        .try_init();
}

/// Wait for Tor to be ready, printing what it is doing on the way.
///
/// Returns how long it took, which is the point of running this.
async fn bootstrap(tor: &TorService) -> Duration {
    let started = Instant::now();
    let mut watch = tor.watch();
    let deadline = tokio::time::Instant::now() + BOOTSTRAP_LIMIT;
    let mut last = String::new();

    loop {
        let status = tor.status();
        if status.summary != last {
            println!(
                "[{:>6.1}s] {}",
                started.elapsed().as_secs_f32(),
                status.summary
            );
            last = status.summary.clone();
        }
        if let Some(blocked) = &status.blocked {
            println!("  ...blocked: {blocked}");
        }
        if status.ready {
            return started.elapsed();
        }
        if tokio::time::timeout_at(deadline, watch.changed())
            .await
            .is_err()
        {
            panic!(
                "Tor did not bootstrap within {BOOTSTRAP_LIMIT:?}. Last said: {}",
                status.summary
            );
        }
    }
}

/// Does the bundled Tor actually start, and how long does it take?
///
/// This is the question the research left open, and the one that decides
/// whether shipping this is reasonable. A client that reconnects at launch
/// and then waits minutes before it can is a different feature from one that
/// waits seconds.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs the real Tor network"]
async fn tor_bootstraps_and_says_how_long_it_took() {
    logging();
    let dir = TempDir::new("bootstrap");
    let tor = TorService::start(&dir.0)
        .await
        .expect("Tor would not start");
    println!("SOCKS5 on 127.0.0.1:{}", tor.port());

    let took = bootstrap(&tor).await;
    println!("bootstrapped in {:.1}s", took.as_secs_f32());
    assert!(tor.status().ready);

    tor.stop().await;
}

/// Public channels to sit in, once registration has gone through.
///
/// Two, on purpose. One channel proves the join path works; a second proves
/// the connection carries more than the first thing it was asked for, which is
/// the failure mode a stream-isolated SOCKS proxy could plausibly have.
const CHANNELS: [&str; 2] = ["#oftc", "#debian"];

/// The whole path, end to end: the app's own client, through the app's own
/// Tor, to a real IRC network over real TLS, into real public channels.
///
/// Nothing here is a stub. `ProxyConfig` is the same type the Dart side fills
/// in, pointed at the port this crate bound, and the connection is the one
/// `connect` makes in production. If this joins and sees a member list,
/// bundled Tor works for what people actually do with the app.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs the real Tor network and a real IRC server"]
async fn the_client_registers_through_the_bundled_tor() {
    logging();
    let dir = TempDir::new("register");
    let tor = TorService::start(&dir.0)
        .await
        .expect("Tor would not start");
    let took = bootstrap(&tor).await;
    println!("bootstrapped in {:.1}s, dialling", took.as_secs_f32());

    // OFTC rather than Libera: Libera blocks Tor exits outright unless you
    // arrive over its onion service, which is a different thing to be testing.
    // OFTC accepts Tor connections and is one of the networks the picker
    // already ships.
    let config = ServerConfig {
        host: "irc.oftc.net".to_owned(),
        port: 6697,
        nickname: format!("ddirctor{}", std::process::id() % 10_000),
        proxy: Some(ProxyConfig {
            host: "127.0.0.1".to_owned(),
            port: tor.port(),
            username: None,
            password: None,
        }),
        ..Default::default()
    };

    let (handle, mut rx) = actor::spawn(config);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(180);
    let mut seen = Vec::new();
    loop {
        let event = match tokio::time::timeout_at(deadline, rx.recv()).await {
            Ok(Some(event)) => event,
            Ok(None) => panic!("the event stream closed early; saw: {seen:#?}"),
            Err(_) => panic!("never registered; saw: {seen:#?}"),
        };
        if let IrcEvent::Registered { nick, .. } = &event {
            println!("registered as {nick} through Tor");
            break;
        }
        println!("  {event:?}");
        seen.push(event);
    }

    for channel in CHANNELS {
        handle
            .send(ClientCommand::Join {
                channel: channel.to_owned(),
                key: None,
            })
            .await
            .expect("the client stopped accepting commands");
    }

    // Waiting for the member list rather than for the join: the join is our
    // own message coming back, and proves only that the server heard us. The
    // roster is the server volunteering data, which is the direction that
    // matters — it is the one a half-open proxied connection would never
    // produce.
    //
    // Kept rather than taken once, because the roster arrives twice: the core
    // emits one the moment we join, holding only ourselves, and the real one
    // on `RPL_ENDOFNAMES` once the server has finished listing. Reading the
    // first would report "1 person" in a channel of hundreds and prove far
    // less than it appeared to.
    let mut joined: Vec<String> = Vec::new();
    let mut rosters: HashMap<String, usize> = HashMap::new();
    let mut heard = 0_u32;

    // One loop, so the roster keeps being updated while we listen. Ends when
    // both channels have answered *and* the listening window is up.
    let joins_by = tokio::time::Instant::now() + Duration::from_secs(120);
    let listen_until = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let settled = rosters.len() == CHANNELS.len();
        let deadline = if settled { listen_until } else { joins_by };
        let event = match tokio::time::timeout_at(deadline, rx.recv()).await {
            Ok(Some(event)) => event,
            Ok(None) => panic!("the event stream closed while joining"),
            // Out of time is the end of the listening window once the joins
            // are in, and a failure before that.
            Err(_) if settled => break,
            Err(_) => panic!("joined {joined:?}, but only got rosters for {rosters:?}"),
        };
        match event {
            IrcEvent::Joined {
                channel,
                is_self: true,
                ..
            } => {
                println!("joined {channel}");
                joined.push(channel);
            }
            IrcEvent::MemberList { channel, members } => {
                assert!(
                    !members.is_empty(),
                    "{channel} came back with an empty roster, which cannot be right"
                );
                rosters.insert(channel, members.len());
            }
            IrcEvent::TopicChanged { channel, topic, .. } => {
                println!("{channel} topic: {topic}");
            }
            IrcEvent::Message(message) => {
                heard += 1;
                let text: String = message.spans.iter().map(|s| s.text.as_str()).collect();
                println!("  <{}> {text}", message.sender);
            }
            IrcEvent::Error { message, fatal } => {
                assert!(!fatal, "the server hung up on us: {message}");
                println!("  server said: {message}");
            }
            _ => {}
        }
    }

    for channel in CHANNELS {
        // Matched without regard to case, because the name that comes back is
        // the server's: ask OFTC for `#debian` and it answers about `#Debian`.
        // Channel names are case-insensitive and the core keeps the casing the
        // server used, which is right — so it is the lookup that has to bend.
        let (name, count) = rosters
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(channel))
            .map(|(name, count)| (name.as_str(), *count))
            .unwrap_or((channel, 0));
        println!("{name}: {count} people");
        // A public channel this size is never down to one person, and one
        // person is exactly what a roster read too early reports.
        assert!(count > 1, "{name} had only {count} in it");
    }
    println!("heard {heard} messages while listening");

    let _ = handle
        .send(ClientCommand::Disconnect {
            reason: Some("done".to_owned()),
        })
        .await;
    tor.stop().await;
}
