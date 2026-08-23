//! Session state: channels, members, privileges and topics.
//!
//! Everything here is driven by untrusted server input, so the structures are
//! bounded. A server that invents ten thousand channel members, or a topic the
//! size of a novel, must cost us a predictable amount of memory rather than
//! whatever it feels like spending.
//!
//! Names are stored under a [`CaseMapping`]-normalised key but displayed with
//! the casing the server used, so `Alice` and `alice` are one member without
//! the UI losing the nick's real spelling.

pub mod isupport;

use std::collections::{BTreeSet, HashMap};

pub use isupport::{CaseMapping, ChanModes, ISupport, Prefixes};

/// Upper bounds on anything a server can inflate. Exceeding one is not an error
/// worth dropping the connection over; we simply refuse to grow further.
pub mod limits {
    /// Channels we will track at once.
    pub const MAX_CHANNELS: usize = 512;
    /// Members tracked per channel. Large channels exist; runaway ones do not.
    pub const MAX_MEMBERS: usize = 20_000;
    /// Characters retained from a topic.
    pub const MAX_TOPIC: usize = 1_000;
    /// Characters retained from a nick.
    pub const MAX_NICK: usize = 64;
    /// Characters retained from a channel name.
    pub const MAX_CHANNEL_NAME: usize = 200;
}

/// Truncate on a character boundary, so a bounded string never splits UTF-8.
pub(crate) fn truncate(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

/// One occupant of a channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    /// Display nick, in the casing the server last used.
    pub nick: String,
    /// Prefix characters currently held, e.g. `@` and `+`.
    pub prefixes: BTreeSet<char>,
    pub away: bool,
}

impl Member {
    fn new(nick: &str) -> Self {
        Self {
            nick: truncate(nick, limits::MAX_NICK),
            prefixes: BTreeSet::new(),
            away: false,
        }
    }

    /// The single prefix the UI should render, highest privilege first.
    pub fn display_prefix(&self, prefixes: &Prefixes) -> Option<char> {
        prefixes.highest(self.prefixes.iter())
    }
}

/// A joined channel.
#[derive(Debug, Clone, Default)]
pub struct Channel {
    /// Display name, in the casing the server used.
    pub name: String,
    pub topic: Option<String>,
    /// Members keyed by normalised nick.
    members: HashMap<String, Member>,
    /// True while a `NAMES` burst is being received, so the first reply after
    /// a re-`NAMES` replaces the roster rather than merging into a stale one.
    names_in_progress: bool,
}

impl Channel {
    fn new(name: &str) -> Self {
        Self {
            name: truncate(name, limits::MAX_CHANNEL_NAME),
            topic: None,
            members: HashMap::new(),
            names_in_progress: false,
        }
    }

    pub fn member_count(&self) -> usize {
        self.members.len()
    }

    pub fn member(&self, normalized_nick: &str) -> Option<&Member> {
        self.members.get(normalized_nick)
    }

    pub fn members(&self) -> impl Iterator<Item = &Member> {
        self.members.values()
    }

    /// Members sorted for display: by privilege, then case-insensitively by nick.
    pub fn sorted_members(&self, prefixes: &Prefixes) -> Vec<&Member> {
        let mut members: Vec<&Member> = self.members.values().collect();
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
}

/// Everything we know about the current server session.
#[derive(Debug, Clone)]
pub struct Session {
    nick: String,
    pub isupport: ISupport,
    /// Channels keyed by normalised name.
    channels: HashMap<String, Channel>,
}

impl Session {
    pub fn new(nick: impl Into<String>) -> Self {
        Self {
            nick: truncate(&nick.into(), limits::MAX_NICK),
            isupport: ISupport::default(),
            channels: HashMap::new(),
        }
    }

    pub fn nick(&self) -> &str {
        &self.nick
    }

    pub fn set_nick(&mut self, nick: &str) {
        self.nick = truncate(nick, limits::MAX_NICK);
    }

    fn normalize(&self, name: &str) -> String {
        self.isupport.casemapping.normalize(name)
    }

    /// True if `nick` is us.
    pub fn is_self(&self, nick: &str) -> bool {
        self.isupport.casemapping.eq(nick, &self.nick)
    }

    pub fn channel(&self, name: &str) -> Option<&Channel> {
        self.channels.get(&self.normalize(name))
    }

    pub fn channels(&self) -> impl Iterator<Item = &Channel> {
        self.channels.values()
    }

    /// Apply an `RPL_ISUPPORT` line.
    ///
    /// A `CASEMAPPING` change would invalidate every existing key, so any
    /// tracked state is re-keyed under the new mapping.
    pub fn on_isupport(&mut self, tokens: &[String]) {
        let before = self.isupport.casemapping;
        self.isupport.apply(tokens);
        if self.isupport.casemapping != before {
            self.rekey();
        }
    }

    /// Rebuild every map key after a casemapping change.
    fn rekey(&mut self) {
        let mapping = self.isupport.casemapping;
        self.channels = std::mem::take(&mut self.channels)
            .into_values()
            .map(|mut channel| {
                channel.members = std::mem::take(&mut channel.members)
                    .into_values()
                    .map(|m| (mapping.normalize(&m.nick), m))
                    .collect();
                (mapping.normalize(&channel.name), channel)
            })
            .collect();
    }

    /// Record that `nick` joined `channel`, creating the channel if we joined.
    ///
    /// Returns false if a bound was hit and the entry was not recorded.
    pub fn on_join(&mut self, channel: &str, nick: &str) -> bool {
        let key = self.normalize(channel);
        let is_self = self.is_self(nick);

        if !self.channels.contains_key(&key) {
            // Only create a channel for our own join; a JOIN for a channel we
            // are not in is a server error or an attempt to grow our state.
            if !is_self || self.channels.len() >= limits::MAX_CHANNELS {
                return false;
            }
            self.channels.insert(key.clone(), Channel::new(channel));
        }

        let member_key = self.normalize(nick);
        let Some(chan) = self.channels.get_mut(&key) else {
            return false;
        };
        if chan.members.len() >= limits::MAX_MEMBERS && !chan.members.contains_key(&member_key) {
            return false;
        }
        chan.members.insert(member_key, Member::new(nick));
        true
    }

    /// Record that `nick` left `channel`. Returns true if anything changed.
    ///
    /// Our own part removes the channel entirely.
    pub fn on_part(&mut self, channel: &str, nick: &str) -> bool {
        let key = self.normalize(channel);
        if self.is_self(nick) {
            return self.channels.remove(&key).is_some();
        }
        let member_key = self.normalize(nick);
        self.channels
            .get_mut(&key)
            .is_some_and(|c| c.members.remove(&member_key).is_some())
    }

    /// Record that `nick` quit the network.
    ///
    /// Returns the display names of the channels they were in, so the caller
    /// can emit one system message per affected channel.
    pub fn on_quit(&mut self, nick: &str) -> Vec<String> {
        if self.is_self(nick) {
            let names = self.channels.values().map(|c| c.name.clone()).collect();
            self.channels.clear();
            return names;
        }

        let member_key = self.normalize(nick);
        self.channels
            .values_mut()
            .filter(|c| c.members.contains_key(&member_key))
            .map(|c| {
                c.members.remove(&member_key);
                c.name.clone()
            })
            .collect()
    }

    /// Record a nick change, preserving privileges. Returns affected channels.
    pub fn on_nick_change(&mut self, old: &str, new: &str) -> Vec<String> {
        if self.is_self(old) {
            self.set_nick(new);
        }

        let old_key = self.normalize(old);
        let new_key = self.normalize(new);
        let new_display = truncate(new, limits::MAX_NICK);

        self.channels
            .values_mut()
            .filter_map(|channel| {
                let mut member = channel.members.remove(&old_key)?;
                member.nick = new_display.clone();
                channel.members.insert(new_key.clone(), member);
                Some(channel.name.clone())
            })
            .collect()
    }

    /// Apply one `RPL_NAMREPLY` line.
    ///
    /// The first line of a burst clears the previous roster, so a re-issued
    /// `NAMES` replaces rather than merges.
    pub fn on_names_reply(&mut self, channel: &str, names: &str) {
        let key = self.normalize(channel);
        let mapping = self.isupport.casemapping;
        let prefixes = self.isupport.prefixes.clone();

        if !self.channels.contains_key(&key) {
            if self.channels.len() >= limits::MAX_CHANNELS {
                return;
            }
            self.channels.insert(key.clone(), Channel::new(channel));
        }
        let Some(chan) = self.channels.get_mut(&key) else {
            return;
        };

        if !chan.names_in_progress {
            chan.names_in_progress = true;
            chan.members.clear();
        }

        for entry in names.split_whitespace() {
            if chan.members.len() >= limits::MAX_MEMBERS {
                break;
            }
            let (found, nick) = prefixes.split_prefixes(entry);
            if nick.is_empty() {
                continue;
            }
            let member = chan
                .members
                .entry(mapping.normalize(nick))
                .or_insert_with(|| Member::new(nick));
            member.prefixes.extend(found);
        }
    }

    /// Close a `NAMES` burst.
    pub fn on_end_of_names(&mut self, channel: &str) {
        let key = self.normalize(channel);
        if let Some(chan) = self.channels.get_mut(&key) {
            chan.names_in_progress = false;
        }
    }

    /// Set a channel topic, bounding its length.
    pub fn on_topic(&mut self, channel: &str, topic: &str) {
        let key = self.normalize(channel);
        if let Some(chan) = self.channels.get_mut(&key) {
            chan.topic = Some(truncate(topic, limits::MAX_TOPIC));
        }
    }

    /// Apply a channel `MODE` change.
    ///
    /// `modes` is the mode string (`+o-v`) and `params` the arguments that
    /// follow. Parameter alignment is driven by `CHANMODES`/`PREFIX` from
    /// `ISUPPORT`, because consuming the wrong argument would attribute a
    /// privilege to the wrong member.
    ///
    /// Returns the display nicks whose privileges changed.
    pub fn on_mode(&mut self, channel: &str, modes: &str, params: &[String]) -> Vec<String> {
        let key = self.normalize(channel);
        let mapping = self.isupport.casemapping;
        let prefixes = self.isupport.prefixes.clone();
        let chanmodes = self.isupport.chanmodes.clone();

        let Some(chan) = self.channels.get_mut(&key) else {
            return Vec::new();
        };

        let mut changed = Vec::new();
        let mut params = params.iter();
        let mut adding = true;

        for mode in modes.chars() {
            match mode {
                '+' => adding = true,
                '-' => adding = false,
                _ => {
                    if prefixes.is_prefix_mode(mode) {
                        // Privilege modes always consume a nick.
                        let Some(target) = params.next() else { break };
                        let Some(prefix) = prefixes.prefix_for_mode(mode) else {
                            continue;
                        };
                        if let Some(member) = chan.members.get_mut(&mapping.normalize(target)) {
                            if adding {
                                member.prefixes.insert(prefix);
                            } else {
                                member.prefixes.remove(&prefix);
                            }
                            changed.push(member.nick.clone());
                        }
                    } else if chanmodes.takes_parameter(mode, adding) {
                        // Consume and ignore, to keep the rest aligned.
                        if params.next().is_none() {
                            break;
                        }
                    }
                }
            }
        }
        changed
    }

    /// Mark a member away or back across every channel they share with us.
    pub fn set_away(&mut self, nick: &str, away: bool) {
        let member_key = self.normalize(nick);
        for channel in self.channels.values_mut() {
            if let Some(member) = channel.members.get_mut(&member_key) {
                member.away = away;
            }
        }
    }

    /// True if `text` mentions our nick as a whole word.
    ///
    /// Substring matching would make the nick "sam" light up on "same" and
    /// every "sample", so the match requires non-nick characters either side.
    pub fn is_mention(&self, text: &str) -> bool {
        let haystack = self.isupport.casemapping.normalize(text);
        let needle = self.isupport.casemapping.normalize(&self.nick);
        if needle.is_empty() {
            return false;
        }

        // Characters that can appear in a nick; a match bounded by any of them
        // is part of a longer word rather than a mention.
        fn is_nick_char(c: char) -> bool {
            c.is_alphanumeric() || "[]\\`_^{|}-".contains(c)
        }

        haystack.match_indices(&needle).any(|(index, matched)| {
            let before = haystack[..index].chars().next_back();
            let after = haystack[index + matched.len()..].chars().next();
            !before.is_some_and(is_nick_char) && !after.is_some_and(is_nick_char)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> Session {
        let mut s = Session::new("ddirc");
        s.on_isupport(&[
            "PREFIX=(qaohv)~&@%+".to_owned(),
            "CHANMODES=beI,k,l,imnpst".to_owned(),
        ]);
        s
    }

    fn joined() -> Session {
        let mut s = session();
        assert!(s.on_join("#test", "ddirc"));
        assert!(s.on_join("#test", "alice"));
        assert!(s.on_join("#test", "bob"));
        s
    }

    #[test]
    fn joining_creates_the_channel_only_for_us() {
        let mut s = session();
        // A JOIN for a channel we are not in must not create state.
        assert!(!s.on_join("#other", "stranger"));
        assert!(s.channel("#other").is_none());

        assert!(s.on_join("#test", "ddirc"));
        assert_eq!(s.channel("#test").unwrap().member_count(), 1);
    }

    #[test]
    fn channel_lookup_is_case_insensitive() {
        let s = joined();
        assert!(s.channel("#TEST").is_some());
        assert_eq!(
            s.channel("#TeSt").unwrap().name,
            "#test",
            "display casing preserved"
        );
    }

    #[test]
    fn our_own_part_removes_the_channel() {
        let mut s = joined();
        assert!(s.on_part("#test", "alice"));
        assert_eq!(s.channel("#test").unwrap().member_count(), 2);

        assert!(s.on_part("#test", "ddirc"));
        assert!(s.channel("#test").is_none());
    }

    #[test]
    fn quit_reports_every_affected_channel() {
        let mut s = joined();
        s.on_join("#second", "ddirc");
        s.on_join("#second", "alice");

        let mut affected = s.on_quit("alice");
        affected.sort();
        assert_eq!(affected, vec!["#second", "#test"]);
        assert!(s.channel("#test").unwrap().member("alice").is_none());
    }

    #[test]
    fn nick_change_preserves_privileges() {
        let mut s = joined();
        s.on_mode("#test", "+o", &["alice".to_owned()]);

        let affected = s.on_nick_change("alice", "alice2");
        assert_eq!(affected, vec!["#test"]);

        let chan = s.channel("#test").unwrap();
        assert!(chan.member("alice").is_none());
        let member = chan.member("alice2").unwrap();
        assert_eq!(member.nick, "alice2");
        assert!(member.prefixes.contains(&'@'), "op survived the rename");
    }

    #[test]
    fn our_own_nick_change_updates_the_session() {
        let mut s = joined();
        s.on_nick_change("ddirc", "ddirc_");
        assert_eq!(s.nick(), "ddirc_");
        assert!(s.is_self("DDIRC_"));
    }

    #[test]
    fn names_reply_parses_multi_prefix_entries() {
        let mut s = session();
        s.on_join("#test", "ddirc");
        s.on_names_reply("#test", "@+alice %bob carol ~dave");
        s.on_end_of_names("#test");

        let chan = s.channel("#test").unwrap();
        let prefixes = &s.isupport.prefixes;
        assert_eq!(
            chan.member("alice").unwrap().display_prefix(prefixes),
            Some('@')
        );
        assert_eq!(
            chan.member("bob").unwrap().display_prefix(prefixes),
            Some('%')
        );
        assert_eq!(chan.member("carol").unwrap().display_prefix(prefixes), None);
        assert_eq!(
            chan.member("dave").unwrap().display_prefix(prefixes),
            Some('~')
        );
    }

    #[test]
    fn repeated_names_burst_replaces_the_roster() {
        let mut s = session();
        s.on_join("#test", "ddirc");
        s.on_names_reply("#test", "alice bob");
        s.on_end_of_names("#test");
        assert_eq!(s.channel("#test").unwrap().member_count(), 2);

        // A fresh NAMES must not merge with the stale roster.
        s.on_names_reply("#test", "carol");
        s.on_end_of_names("#test");
        let chan = s.channel("#test").unwrap();
        assert_eq!(chan.member_count(), 1);
        assert!(chan.member("alice").is_none());
    }

    #[test]
    fn multi_line_names_burst_accumulates() {
        let mut s = session();
        s.on_join("#test", "ddirc");
        s.on_names_reply("#test", "alice bob");
        s.on_names_reply("#test", "carol");
        s.on_end_of_names("#test");
        assert_eq!(s.channel("#test").unwrap().member_count(), 3);
    }

    #[test]
    fn mode_parameters_align_using_chanmodes() {
        let mut s = joined();
        // `b` takes a mask, `o` takes a nick. Mis-alignment here would op the
        // ban mask instead of bob.
        let changed = s.on_mode(
            "#test",
            "+bo",
            &["*!*@spam.example".to_owned(), "bob".to_owned()],
        );

        assert_eq!(changed, vec!["bob"]);
        let chan = s.channel("#test").unwrap();
        assert!(chan.member("bob").unwrap().prefixes.contains(&'@'));
        assert!(chan.member("alice").unwrap().prefixes.is_empty());
    }

    #[test]
    fn mode_handles_mixed_add_and_remove() {
        let mut s = joined();
        s.on_mode("#test", "+o", &["alice".to_owned()]);
        s.on_mode("#test", "+v", &["bob".to_owned()]);

        s.on_mode("#test", "-o+v", &["alice".to_owned(), "alice".to_owned()]);
        let chan = s.channel("#test").unwrap();
        let alice = chan.member("alice").unwrap();
        assert!(!alice.prefixes.contains(&'@'), "op removed");
        assert!(alice.prefixes.contains(&'+'), "voice added");
    }

    #[test]
    fn mode_with_parameterless_modes_does_not_consume_arguments() {
        let mut s = joined();
        // `n` and `t` take no parameter; `o` must still find "bob".
        let changed = s.on_mode("#test", "+nto", &["bob".to_owned()]);
        assert_eq!(changed, vec!["bob"]);
    }

    #[test]
    fn mode_with_missing_parameters_does_not_panic() {
        let mut s = joined();
        // Truncated parameter list from a malicious or buggy server.
        let changed = s.on_mode("#test", "+ooo", &["alice".to_owned()]);
        assert_eq!(changed, vec!["alice"]);
    }

    #[test]
    fn limit_mode_only_consumes_a_parameter_when_set() {
        let mut s = joined();
        // "-l+o bob": `-l` takes no param, so `bob` belongs to `+o`.
        let changed = s.on_mode("#test", "-l+o", &["bob".to_owned()]);
        assert_eq!(changed, vec!["bob"]);
    }

    #[test]
    fn topic_is_bounded() {
        let mut s = joined();
        s.on_topic("#test", &"t".repeat(5_000));
        let topic = s.channel("#test").unwrap().topic.clone().unwrap();
        assert_eq!(topic.chars().count(), limits::MAX_TOPIC);
    }

    #[test]
    fn member_count_is_bounded() {
        let mut s = session();
        s.on_join("#test", "ddirc");
        let names: String = (0..limits::MAX_MEMBERS + 100)
            .map(|i| format!("nick{i} "))
            .collect();
        s.on_names_reply("#test", &names);
        assert_eq!(
            s.channel("#test").unwrap().member_count(),
            limits::MAX_MEMBERS
        );
    }

    #[test]
    fn channel_count_is_bounded() {
        let mut s = session();
        for i in 0..limits::MAX_CHANNELS + 10 {
            s.on_join(&format!("#chan{i}"), "ddirc");
        }
        assert_eq!(s.channels().count(), limits::MAX_CHANNELS);
    }

    #[test]
    fn mentions_require_a_word_boundary() {
        let mut s = Session::new("sam");
        s.on_isupport(&[]);

        assert!(s.is_mention("sam: hello"));
        assert!(s.is_mention("hey sam"));
        assert!(s.is_mention("SAM, look"));
        assert!(s.is_mention("(sam)"));

        assert!(!s.is_mention("same thing"), "substring is not a mention");
        assert!(!s.is_mention("sample text"));
        assert!(!s.is_mention("flotsam"));
    }

    #[test]
    fn mentions_respect_casemapping_for_bracket_nicks() {
        let mut s = Session::new("foo[bar]");
        s.on_isupport(&["CASEMAPPING=rfc1459".to_owned()]);
        // Under RFC 1459 folding these are the same nick.
        assert!(s.is_mention("hello foo{bar}"));
    }

    #[test]
    fn casemapping_change_rekeys_existing_state() {
        let mut s = Session::new("ddirc");
        s.on_isupport(&["CASEMAPPING=ascii".to_owned()]);
        s.on_join("#Chan[1]", "ddirc");
        s.on_join("#Chan[1]", "Al[ice]");

        // Switching mapping must not orphan the entries we already hold.
        s.on_isupport(&["CASEMAPPING=rfc1459".to_owned()]);
        let chan = s.channel("#chan{1}").expect("channel re-keyed");
        assert!(chan.member("al{ice}").is_some(), "member re-keyed");
    }

    #[test]
    fn members_sort_by_privilege_then_name() {
        let mut s = session();
        s.on_join("#test", "ddirc");
        // A real NAMES burst lists every member, ourselves included, and
        // replaces the roster wholesale.
        s.on_names_reply("#test", "zoe @adam +yuri bella ddirc");
        s.on_end_of_names("#test");

        let chan = s.channel("#test").unwrap();
        let order: Vec<&str> = chan
            .sorted_members(&s.isupport.prefixes)
            .iter()
            .map(|m| m.nick.as_str())
            .collect();
        assert_eq!(order, vec!["adam", "yuri", "bella", "ddirc", "zoe"]);
    }

    #[test]
    fn away_status_applies_across_shared_channels() {
        let mut s = joined();
        s.on_join("#second", "ddirc");
        s.on_join("#second", "alice");

        s.set_away("alice", true);
        assert!(s.channel("#test").unwrap().member("alice").unwrap().away);
        assert!(s.channel("#second").unwrap().member("alice").unwrap().away);
    }

    #[test]
    fn nicks_are_length_bounded() {
        let mut s = session();
        s.on_join("#test", "ddirc");
        let long = "n".repeat(500);
        s.on_join("#test", &long);

        let chan = s.channel("#test").unwrap();
        let member = chan.members().find(|m| m.nick.starts_with('n')).unwrap();
        assert_eq!(member.nick.chars().count(), limits::MAX_NICK);
    }
}
