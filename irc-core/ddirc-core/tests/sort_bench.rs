//! What ordering a large channel's member list actually costs.
//!
//! `#[ignore]`d, so `cargo test` stays hermetic and quick. Run it with:
//!
//! ```text
//! cargo test -p ddirc-core --test sort_bench --release -- --ignored --nocapture
//! ```
//!
//! A stopwatch, not a statistical benchmark: one mean over many rounds, in
//! release, after a warm-up pass. That is enough to answer the question it
//! exists for — did this change help — and it exists because reading the code
//! gave the wrong answer twice.
//!
//! Both rejected versions are kept here rather than left in a commit message,
//! because the ranking between them is the whole lesson and it is not the one
//! you would guess:
//!
//! - **`sorted_original`** computed both halves of the sort key inside the
//!   comparator. Ranking walked the member's prefix list twice per comparison,
//!   and `to_lowercase()` allocated two `String`s per comparison.
//! - **`sorted_lazy`** hoisted the rank out, and replaced the two allocations
//!   with a lazy lowercase iterator comparison that allocates **nothing at
//!   all**. It is three times slower than what shipped.
//! - **What shipped** hoists the rank *and* the lowercased nick, paying one
//!   allocation per member so that the comparator is a single `memcmp`.
//!
//! The allocation-free version losing to the allocating one is the point.
//! `String` comparison is a `memcmp`; a `flat_map(char::to_lowercase)` compare
//! is a state machine stepped one character at a time, and a sort runs it
//! O(n log n) times. Minimising allocations was the wrong target; minimising
//! work inside the comparator was the right one.
//!
//! # The third wrong guess, which is this file earning its keep again
//!
//! What shipped is now one `String` per member — [`Member::sort_key`] — rather
//! than the `(rank, String)` pair it used to be, because the UI applies
//! arrivals and departures one at a time and needs the same ordering on the
//! far side of the FFI. Building that key costs something: **0.107ms became
//! 0.155ms** over 883 members, so about 7.8x became about 6.8x.
//!
//! Two things were measured on the way, and both were worth measuring:
//!
//! - `format!("{rank:04x}\u{1}{nick}")` is **0.271ms** — worse than the pair it
//!   replaced and barely better than doing nothing. The formatting machinery
//!   parses a spec and dispatches through a trait object, per member, per sort.
//!   Writing the four hex digits out by hand is most of the difference.
//! - Appending the nick with `push_str(&nick.to_lowercase())` is **0.186ms**,
//!   against **0.155ms** for folding it in with `flat_map(char::to_lowercase)`.
//!   Note that this is the *opposite* of the lesson above, and not a
//!   contradiction of it: there the iterator ran inside the comparator, O(n log
//!   n) times; here it runs once per member, where the second allocation and
//!   the copy out of it cost more than stepping it does.
//!
//! The 0.048ms given up buys a member list that is no longer wrong, and is
//! repaid immediately: this sort now runs when a channel is joined rather than
//! every time anybody in it is opped, and the roster it produces is no longer
//! serialised across the FFI on every arrival.

use std::cmp::Ordering;
use std::time::Instant;

use ddirc_core::state::{Member, Prefixes, Session};

/// A roster shaped like a large public channel: mixed case, a spread of nick
/// lengths, out of alphabetical order, and about one in forty holding a
/// privilege prefix.
fn channel_of(size: usize) -> Session {
    let mut session = Session::new("ddirc");
    session.on_isupport(&[
        "PREFIX=(qaohv)~&@%+".to_owned(),
        "CHANMODES=beI,k,l,imnpst".to_owned(),
    ]);
    session.on_join("#big", "ddirc");

    let mut names = String::new();
    for i in 0..size {
        // Deterministic, and deliberately not in sorted order, so the sort has
        // real work to do.
        let scrambled = (i * 7919) % size;
        if i % 41 == 0 {
            names.push('@');
        }
        match i % 4 {
            0 => names.push_str(&format!("User{scrambled}")),
            1 => names.push_str(&format!("nick_{scrambled}")),
            2 => names.push_str(&format!("SomebodyRatherLonger{scrambled}")),
            _ => names.push_str(&format!("a{scrambled}")),
        }
        names.push(' ');
    }

    session.on_names_reply("#big", names.trim_end());
    session.on_end_of_names("#big");
    session
}

/// Rejected #1: the version this crate shipped first. Everything in the
/// comparator.
fn sorted_original<'a>(
    members: impl Iterator<Item = &'a Member>,
    prefixes: &Prefixes,
) -> Vec<&'a Member> {
    let mut members: Vec<&Member> = members.collect();
    members.sort_by(|a, b| {
        let rank = |m: &Member| {
            m.display_prefix(prefixes)
                .and_then(|p| prefixes.rank(p))
                .unwrap_or(usize::MAX)
        };
        rank(a)
            .cmp(&rank(b))
            .then_with(|| a.nick.to_lowercase().cmp(&b.nick.to_lowercase()))
    });
    members
}

/// Rejected #2: rank hoisted, nicks compared through a lazy lowercase
/// iterator. Allocates nothing, and is the slowest thing here per unit of
/// cleverness.
fn sorted_lazy<'a>(
    members: impl Iterator<Item = &'a Member>,
    prefixes: &Prefixes,
) -> Vec<&'a Member> {
    fn nick_order(a: &str, b: &str) -> Ordering {
        a.chars()
            .flat_map(char::to_lowercase)
            .cmp(b.chars().flat_map(char::to_lowercase))
    }

    let mut ranked: Vec<(usize, &Member)> = members
        .map(|m| {
            let rank = m
                .display_prefix(prefixes)
                .and_then(|p| prefixes.rank(p))
                .unwrap_or(usize::MAX);
            (rank, m)
        })
        .collect();

    ranked.sort_by(|(a_rank, a), (b_rank, b)| {
        a_rank
            .cmp(b_rank)
            .then_with(|| nick_order(&a.nick, &b.nick))
    });
    ranked.into_iter().map(|(_, m)| m).collect()
}

fn mean_ms(rounds: u32, mut f: impl FnMut() -> usize) -> f64 {
    let _ = f(); // warm-up, so nobody pays for a cold allocator
    let start = Instant::now();
    let mut sink = 0usize;
    for _ in 0..rounds {
        sink = sink.wrapping_add(f());
    }
    assert!(sink > 0);
    start.elapsed().as_secs_f64() / rounds as f64 * 1000.0
}

fn nicks(members: Vec<&Member>) -> Vec<&str> {
    members.iter().map(|m| m.nick.as_str()).collect()
}

#[test]
#[ignore = "a stopwatch, not a check; run with --release --ignored --nocapture"]
fn ordering_a_large_roster() {
    println!("\n  size   original      lazy   shipped   speed-up");
    for size in [50usize, 481, 883, 2000] {
        let session = channel_of(size);
        let channel = session.channel("#big").expect("the channel");
        let prefixes = &session.isupport.prefixes;

        // All three must agree, or the timings compare different answers.
        let expected = nicks(sorted_original(channel.members(), prefixes));
        assert_eq!(expected, nicks(sorted_lazy(channel.members(), prefixes)));
        assert_eq!(expected, nicks(channel.sorted_members(prefixes)));

        let rounds = if size > 1000 { 500 } else { 2000 };
        let original = mean_ms(rounds, || {
            sorted_original(channel.members(), prefixes).len()
        });
        let lazy = mean_ms(rounds, || sorted_lazy(channel.members(), prefixes).len());
        let shipped = mean_ms(rounds, || channel.sorted_members(prefixes).len());

        println!(
            "{size:>6}   {original:>6.3}ms  {lazy:>6.3}ms  {shipped:>6.3}ms   \
             {:>5.1}x",
            original / shipped
        );
    }
    println!();
}

/// The ordering the benchmark above assumes, checked rather than assumed:
/// privilege first, then case-insensitively by nick.
#[test]
fn ordering_is_privilege_then_case_insensitive_nick() {
    let mut session = Session::new("ddirc");
    session.on_isupport(&["PREFIX=(qaohv)~&@%+".to_owned()]);
    session.on_join("#t", "ddirc");
    // Our own nick has to appear in the reply like anyone else's: a NAMES
    // burst replaces the roster, it does not merge into it.
    session.on_names_reply("#t", "zoe Adam @yuri +bella ddirc");
    session.on_end_of_names("#t");

    let channel = session.channel("#t").expect("the channel");
    assert_eq!(
        nicks(channel.sorted_members(&session.isupport.prefixes)),
        vec!["yuri", "bella", "Adam", "ddirc", "zoe"],
    );
}
