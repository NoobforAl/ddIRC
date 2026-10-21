//! What the XMPP session costs in time and memory, under load nobody should see.
//!
//! `#[ignore]`d, so `cargo test` stays hermetic and quick. Run it with:
//!
//! ```text
//! cargo test -p ddirc-core --test xmpp_perf --release -- --ignored --nocapture --test-threads=1
//! ```
//!
//! A counting allocator, not a profiler: every allocation in this process goes
//! through it, so "how many allocations per message", "how much is still held
//! afterwards" and "the high-water mark" are exact rather than sampled. The
//! stanzas are built *before* the clock starts and handed to the session by
//! value, as the actor does, so what is timed is the session and nothing else.
//!
//! What the two kinds of assertion are for:
//!
//! - **Retained memory does not grow with the number of messages.** The session
//!   holds a bounded amount of anything the network can make it hold - the
//!   index, the recent-id window, the contact list - and this is the test that
//!   says so with a hundred thousand messages rather than with a unit test's
//!   three. A leak shows here as a ratio, which is robust to the machine.
//! - **A generous ceiling on time per stanza.** Not a target. It is there so an
//!   accidental O(n) in the hot path - which is how a list that was bounded at
//!   two thousand became 2,000 comparisons per message - fails loudly instead
//!   of showing up as a phone that is warm.
//!
//! The numbers it prints are the point; read them before and after a change.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::time::{Duration, Instant};

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::ChatMessage;
use ddirc_core::conn::actor::ClientCommand;
use ddirc_core::xmpp::config::XmppConfig;
use ddirc_core::xmpp::session::Session;
use tokio_xmpp::jid::FullJid;
use tokio_xmpp::minidom::Element;
use tokio_xmpp::parsers::iq::Iq;
use tokio_xmpp::parsers::message::Message;
use tokio_xmpp::parsers::presence::Presence;
use tokio_xmpp::Stanza;
use zeroize::Zeroizing;

// ---- the counting allocator -------------------------------------------------

struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
static ALLOCS: AtomicUsize = AtomicUsize::new(0);
static BYTES: AtomicUsize = AtomicUsize::new(0);

fn note_alloc(size: usize) {
    ALLOCS.fetch_add(1, Relaxed);
    BYTES.fetch_add(size, Relaxed);
    let live = LIVE.fetch_add(size, Relaxed) + size;
    PEAK.fetch_max(live, Relaxed);
}

// SAFETY: forwards every call to `System` unchanged, and only counts.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        note_alloc(layout.size());
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Relaxed);
        System.dealloc(ptr, layout)
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        note_alloc(layout.size());
        System.alloc_zeroed(layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        LIVE.fetch_sub(layout.size(), Relaxed);
        note_alloc(new_size);
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

/// What one workload cost.
#[derive(Debug, Clone, Copy)]
struct Cost {
    stanzas: usize,
    elapsed: Duration,
    allocs: usize,
    bytes: usize,
    /// Still held when it finished, over what was held before it began.
    retained: isize,
    /// The highest the heap went above where it began.
    peak: usize,
}

impl Cost {
    fn per_stanza_ns(&self) -> f64 {
        self.elapsed.as_nanos() as f64 / self.stanzas.max(1) as f64
    }
    fn report(&self, label: &str) {
        println!(
            "{label:<34} {:>8} stanzas {:>9.0} ns each {:>6.1} allocs {:>8.0} B alloc'd each | \
             retained {:>9} B | peak +{:>9} B",
            self.stanzas,
            self.per_stanza_ns(),
            self.allocs as f64 / self.stanzas.max(1) as f64,
            self.bytes as f64 / self.stanzas.max(1) as f64,
            self.retained,
            self.peak
        );
    }
}

/// Run `batches` of stanzas through `feed`, timing and counting only the feeding.
///
/// Each batch is built outside the clock by `build`, so parsing XML is not
/// charged to the session. The batch is small so that the stanzas waiting to be
/// fed do not themselves dominate the high-water mark.
fn measure(
    total: usize,
    batch: usize,
    mut build: impl FnMut(usize) -> Stanza,
    mut feed: impl FnMut(Stanza),
) -> Cost {
    let live0 = LIVE.load(Relaxed) as isize;
    let mut elapsed = Duration::ZERO;
    let mut allocs = 0;
    let mut bytes = 0;
    let mut peak = 0usize;
    let mut done = 0;
    while done < total {
        let n = batch.min(total - done);
        let stanzas: Vec<Stanza> = (done..done + n).map(&mut build).collect();
        let (a0, b0) = (ALLOCS.load(Relaxed), BYTES.load(Relaxed));
        let base = LIVE.load(Relaxed);
        PEAK.store(base, Relaxed);
        let t = Instant::now();
        for stanza in stanzas {
            feed(stanza);
        }
        elapsed += t.elapsed();
        allocs += ALLOCS.load(Relaxed) - a0;
        bytes += BYTES.load(Relaxed) - b0;
        peak = peak.max(PEAK.load(Relaxed).saturating_sub(base));
        done += n;
    }
    Cost {
        stanzas: total,
        elapsed,
        allocs,
        bytes,
        retained: LIVE.load(Relaxed) as isize - live0,
        peak,
    }
}

// ---- stanza builders ---------------------------------------------------------

const ROOM: &str = "lobby@conference.example.org";

fn config() -> XmppConfig {
    XmppConfig {
        jid: "alice@example.org".to_owned(),
        password: Zeroizing::new("hunter2".to_owned()),
        host: None,
        port: None,
        rooms: vec![ROOM.to_owned()],
        nickname: Some("alice".to_owned()),
        extra_root_cert: None,
        proxy: None,
    }
}

fn stanza(xml: &str) -> Stanza {
    let element: Element = xml.parse().expect("well-formed test XML");
    match element.name() {
        "message" => Stanza::Message(Message::try_from(element).expect("a message")),
        "presence" => Stanza::Presence(Presence::try_from(element).expect("a presence")),
        "iq" => Stanza::Iq(Iq::try_from(element).expect("an iq")),
        other => panic!("not a stanza: {other}"),
    }
}

/// A session that is online, with the room joined and `occupants` people in it.
fn session_in_room(occupants: usize) -> Session {
    let mut s = Session::new(&config()).expect("valid config");
    let bound: FullJid = "alice@example.org/ddirc".parse().unwrap();
    drop(s.on_online(&bound));
    for n in 0..occupants {
        drop(s.on_stanza(stanza(&format!(
            "<presence xmlns='jabber:client' from='{ROOM}/user{n}'>\
             <x xmlns='http://jabber.org/protocol/muc#user'>\
             <item affiliation='none' role='participant'/></x></presence>"
        ))));
    }
    drop(s.on_stanza(stanza(&format!(
        "<presence xmlns='jabber:client' from='{ROOM}/alice'>\
         <x xmlns='http://jabber.org/protocol/muc#user'>\
         <item affiliation='none' role='participant'/><status code='110'/></x></presence>"
    ))));
    s
}

fn room_message(n: usize, occupants: usize) -> Stanza {
    stanza(&format!(
        "<message xmlns='jabber:client' type='groupchat' from='{ROOM}/user{}' id='m{n}'>\
         <body>message number {n}: a line of the sort people write in a room, about eighty characters</body>\
         <stanza-id xmlns='urn:xmpp:sid:0' by='{ROOM}' id='S{n}'/></message>",
        n % occupants
    ))
}

fn drain(effects: ddirc_core::xmpp::session::Effects) -> usize {
    effects.events.len() + effects.send.len()
}

// ---- workloads ---------------------------------------------------------------

#[test]
#[ignore = "a measurement; see the module docs"]
fn a_busy_room_costs_bounded_memory_and_little_time() {
    println!();
    let occupants = 50;
    let mut results = Vec::new();
    for total in [20_000usize, 100_000] {
        let mut s = session_in_room(occupants);
        // Warm up, so one-time growth (the maps reaching their size) is not
        // charged to the steady state being measured.
        let _ = measure(
            5_000,
            500,
            |n| room_message(n, occupants),
            |st| {
                drain(s.on_stanza(st));
            },
        );
        let cost = measure(
            total,
            500,
            |n| room_message(n + 5_000, occupants),
            |st| {
                drain(s.on_stanza(st));
            },
        );
        cost.report(&format!("room, {total} messages"));
        results.push(cost);
    }
    // Memory the session keeps must not follow the number of messages.
    let (small, large) = (results[0], results[1]);
    assert!(
        large.retained <= small.retained.max(0) * 2 + 256 * 1024,
        "retained memory grew with the traffic: {} B after 20k, {} B after 100k",
        small.retained,
        large.retained
    );
    assert!(
        large.per_stanza_ns() < 200_000.0,
        "a room message costs {} ns: something in the hot path is no longer constant",
        large.per_stanza_ns()
    );
}

#[test]
#[ignore = "a measurement; see the module docs"]
fn private_chats_cost_bounded_memory_and_little_time() {
    println!();
    let mut s = session_in_room(1);
    let chat = |n: usize| {
        stanza(&format!(
            "<message xmlns='jabber:client' type='chat' from='friend{}@example.net/phone' id='c{n}'>\
             <body>hello {n}, how are you getting on with the thing</body>\
             <stanza-id xmlns='urn:xmpp:sid:0' by='alice@example.org' id='A{n}'/></message>",
            n % 40
        ))
    };
    let _ = measure(5_000, 500, chat, |st| {
        drain(s.on_stanza(st));
    });
    let a = measure(
        20_000,
        500,
        |n| chat(n + 5_000),
        |st| {
            drain(s.on_stanza(st));
        },
    );
    a.report("chats, 20000 messages");
    let b = measure(
        100_000,
        500,
        |n| chat(n + 25_000),
        |st| {
            drain(s.on_stanza(st));
        },
    );
    b.report("chats, 100000 messages");
    assert!(
        b.retained <= a.retained.max(0) * 2 + 256 * 1024,
        "retained memory grew with the traffic: {} B, then {} B",
        a.retained,
        b.retained
    );
    assert!(
        b.per_stanza_ns() < 200_000.0,
        "{} ns per chat",
        b.per_stanza_ns()
    );
}

#[test]
#[ignore = "a measurement; see the module docs"]
fn a_large_roster_with_presence_churn_is_cheap() {
    println!();
    let contacts = 2_000;
    let mut s = Session::new(&config()).unwrap();
    let bound: FullJid = "alice@example.org/ddirc".parse().unwrap();
    let fx = s.on_online(&bound);
    let roster_id = fx
        .send
        .iter()
        .find_map(|st| match st {
            Stanza::Iq(Iq::Get { id, payload, .. }) if payload.is("query", "jabber:iq:roster") => {
                Some(id.clone())
            }
            _ => None,
        })
        .expect("a roster request");
    let items: String = (0..contacts)
        .map(|n| format!("<item jid='user{n}@example.net' name='User {n}' subscription='both'/>"))
        .collect();
    let roster = stanza(&format!(
        "<iq xmlns='jabber:client' type='result' id='{roster_id}'>\
         <query xmlns='jabber:iq:roster'>{items}</query></iq>"
    ));
    let t = Instant::now();
    let a0 = ALLOCS.load(Relaxed);
    let live0 = LIVE.load(Relaxed) as isize;
    let fx = s.on_stanza(roster);
    println!(
        "roster of {contacts}: {:?}, {} events, {} allocs, retained {} B",
        t.elapsed(),
        fx.events.len(),
        ALLOCS.load(Relaxed) - a0,
        LIVE.load(Relaxed) as isize - live0
    );
    drop(fx);

    // Everyone's presence flips between here, away and gone, over and over.
    let shows = [
        "",
        "<show>away</show>",
        "<show>dnd</show>",
        "<show>xa</show>",
    ];
    let presence = |n: usize| {
        let who = n % contacts;
        let kind = if n % 7 == 6 {
            " type='unavailable'"
        } else {
            ""
        };
        stanza(&format!(
            "<presence xmlns='jabber:client' from='user{who}@example.net/phone'{kind}>{}\
             <status>doing thing {n}</status></presence>",
            shows[n % shows.len()]
        ))
    };
    let _ = measure(10_000, 500, presence, |st| {
        drain(s.on_stanza(st));
    });
    let a = measure(
        50_000,
        500,
        |n| presence(n + 10_000),
        |st| {
            drain(s.on_stanza(st));
        },
    );
    a.report("presence churn, 50000");
    let b = measure(
        200_000,
        500,
        |n| presence(n + 60_000),
        |st| {
            drain(s.on_stanza(st));
        },
    );
    b.report("presence churn, 200000");
    assert!(
        b.retained <= a.retained.max(0) * 2 + 512 * 1024,
        "retained memory grew with the churn: {} B, then {} B",
        a.retained,
        b.retained
    );
    assert!(
        b.per_stanza_ns() < 200_000.0,
        "{} ns per presence",
        b.per_stanza_ns()
    );
}

#[test]
#[ignore = "a measurement; see the module docs"]
fn corrections_and_retractions_of_recent_messages_are_cheap() {
    println!();
    let occupants = 50;
    let mut s = session_in_room(occupants);
    let _ = measure(
        3_000,
        500,
        |n| room_message(n, occupants),
        |st| {
            drain(s.on_stanza(st));
        },
    );
    // Correct a message from the last thousand by the person who wrote it.
    let correction = |n: usize| {
        let target = 2_000 + (n * 7) % 900;
        let who = target % occupants;
        stanza(&format!(
            "<message xmlns='jabber:client' type='groupchat' from='{ROOM}/user{who}' id='c{n}'>\
             <body>corrected {n}</body>\
             <replace xmlns='urn:xmpp:message-correct:0' id='m{target}'/>\
             <stanza-id xmlns='urn:xmpp:sid:0' by='{ROOM}' id='SC{n}'/></message>"
        ))
    };
    let a = measure(20_000, 500, correction, |st| {
        drain(s.on_stanza(st));
    });
    a.report("corrections, 20000");
    assert!(
        a.per_stanza_ns() < 200_000.0,
        "{} ns per correction",
        a.per_stanza_ns()
    );
}

#[test]
#[ignore = "a measurement; see the module docs"]
fn the_events_a_room_message_makes_are_small() {
    // Not the session's memory but what it hands on: every event crosses to
    // the UI, and a message that is a few kilobytes of events is a few
    // kilobytes of garbage per line.
    println!();
    let mut s = session_in_room(10);
    let st = room_message(1, 10);
    let fx = s.on_stanza(st);
    let message: Vec<&ChatMessage> = fx
        .events
        .iter()
        .filter_map(|e| match e {
            IrcEvent::Message(m) => Some(m.as_ref()),
            _ => None,
        })
        .collect();
    println!(
        "one room message -> {} events, {} message(s), {} span(s) in the first",
        fx.events.len(),
        message.len(),
        message.first().map_or(0, |m| m.spans.len())
    );
    // And a command's cost: sending.
    let a0 = ALLOCS.load(Relaxed);
    let b0 = BYTES.load(Relaxed);
    let fx = s.on_command(ClientCommand::SendMessage {
        target: ROOM.to_owned(),
        text: "hello".to_owned(),
    });
    println!(
        "one message sent -> {} stanza(s), {} allocs, {} B",
        fx.send.len(),
        ALLOCS.load(Relaxed) - a0,
        BYTES.load(Relaxed) - b0
    );
}
