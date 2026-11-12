//! What this client knows about the rooms it is in.
//!
//! The XMPP counterpart of [`crate::state`], and kept apart from it because
//! that one is built around IRC's vocabulary: prefix modes, case mapping
//! negotiated per network, `NAMES`. A room here is a bare JID, an occupant is a
//! nick in it, and standing is two independent things - *affiliation*, which
//! the room remembers, and *role*, which lasts as long as the visit.

use std::collections::{BTreeMap, HashSet, VecDeque};

use tokio_xmpp::jid::BareJid;
use tokio_xmpp::parsers::muc::user::{Affiliation, Role};

use crate::api::types::MemberView;
use crate::state::limits;

/// Characters that change how text is laid out rather than what it says.
///
/// A nick is chosen by whoever joins, can be any Unicode, and is shown next to
/// everyone else's. Left in, a right-to-left override can make one occupant's
/// name read as another's, or reorder the text after it.
fn is_layout_control(c: char) -> bool {
    matches!(c,
        '\u{200e}' | '\u{200f}'
        | '\u{202a}'..='\u{202e}'
        | '\u{2066}'..='\u{2069}')
}

/// A name from the network, made safe to show: control and layout characters
/// removed, and bounded.
pub fn clean_name(name: &str) -> String {
    name.chars()
        .filter(|c| !c.is_control() && !is_layout_control(*c))
        .take(limits::MAX_NICK)
        .collect()
}

/// A line of free text from the network - a status, a reason - made safe to
/// show on one line: control characters become spaces, layout characters go,
/// and it is cut at `max` characters.
///
/// [`clean_name`] with the bound of a sentence rather than of a nickname.
pub fn clean_line(text: &str, max: usize) -> String {
    text.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .filter(|c| !is_layout_control(*c))
        .take(max)
        .collect::<String>()
        .trim()
        .to_owned()
}

/// True if `text` mentions `nick` as a whole word, ignoring case.
///
/// Substring matching would make the nick "sam" light up on "same".
pub fn mentions(nick: &str, text: &str) -> bool {
    fn is_word_char(c: char) -> bool {
        // No '.': it ends sentences, and "thanks sam." is a mention.
        c.is_alphanumeric() || "_-".contains(c)
    }
    let needle: String = nick.chars().flat_map(char::to_lowercase).collect();
    if needle.is_empty() {
        return false;
    }
    let haystack: String = text.chars().flat_map(char::to_lowercase).collect();
    haystack.match_indices(&needle).any(|(index, matched)| {
        let before = haystack[..index].chars().next_back();
        let after = haystack[index + matched.len()..].chars().next();
        !before.is_some_and(is_word_char) && !after.is_some_and(is_word_char)
    })
}

/// One person in a room.
#[derive(Debug, Clone, PartialEq)]
pub struct Occupant {
    pub nick: String,
    pub affiliation: Affiliation,
    pub role: Role,
    pub away: bool,
}

impl Occupant {
    /// The single mark shown beside the name, for the highest standing held.
    ///
    /// Chosen to read the way the same marks do on IRC, so a room looks the
    /// same in either: `~` owner, `&` admin, `@` moderator, `+` member. A
    /// plain participant has none, because nearly everyone is one and a mark on
    /// all of them would say nothing.
    pub fn prefix(&self) -> Option<char> {
        match (&self.affiliation, &self.role) {
            (Affiliation::Owner, _) => Some('~'),
            (Affiliation::Admin, _) => Some('&'),
            (_, Role::Moderator) => Some('@'),
            (Affiliation::Member, _) => Some('+'),
            _ => None,
        }
    }

    fn rank(&self) -> usize {
        match self.prefix() {
            Some('~') => 0,
            Some('&') => 1,
            Some('@') => 2,
            Some('+') => 3,
            _ => 0xffff,
        }
    }

    /// Where this occupant sorts, in the same format the IRC side uses: a
    /// fixed-width rank, a separator below every printable character, then the
    /// folded name. The UI compares these as strings and never needs to know
    /// which protocol made one.
    pub fn sort_key(&self) -> String {
        let mut key = format!("{:04x}\u{1}", self.rank());
        key.extend(self.nick.chars().flat_map(char::to_lowercase));
        key
    }

    pub fn view(&self) -> MemberView {
        MemberView {
            nick: self.nick.clone(),
            prefix: self.prefix().map(|p| p.to_string()),
            away: self.away,
            sort_key: self.sort_key(),
        }
    }
}

/// A room we have joined, or are joining.
#[derive(Debug, Clone)]
pub struct Room {
    pub jid: BareJid,
    /// The nick we are using, which the room may have changed from the one asked
    /// for.
    pub nick: String,
    /// True once the room has sent our own presence back: the end of the
    /// occupant list it sends first, and the point at which we are in.
    pub joined: bool,
    /// True once we asked to leave. The room confirms with our own presence,
    /// and until then a second `Parted` must not be reported.
    pub leaving: bool,
    /// How many times the nick was refused as taken.
    pub nick_attempts: u32,
    pub topic: Option<String>,
    /// Nick changes announced but not yet completed, as `new -> old`.
    ///
    /// A room reports a rename as two presences: the old nick going away with
    /// the new one named in it, and then the new nick arriving. Neither is a
    /// departure or an arrival, but they cannot be told from one without
    /// remembering the first when the second comes.
    pub renaming: BTreeMap<String, String>,
    /// The id the room's archive gave the last message we showed from it. What
    /// a catch-up after a reconnect asks "everything after" of. Only ever an id
    /// the room itself assigned: a client's own id means nothing to an archive,
    /// and asking for "after" one is an error.
    pub last_id: Option<String>,
    /// The ids of the messages most recently shown, so one that arrives twice -
    /// live, and again from the archive - is shown once.
    recent: VecDeque<String>,
    /// The same ids, for asking whether one is there.
    recent_set: HashSet<String>,
    occupants: BTreeMap<String, Occupant>,
}

/// How many ids a room remembers. Far more than a catch-up fetches, so a
/// message cannot be live and in the archive page and slip between the two.
const RECENT_IDS: usize = 512;

/// The most people a room remembers besides us: the same bound as an IRC
/// channel's members. A room service, or a crowd of made-up occupants, decides how
/// many presences arrive, and each would otherwise be kept for as long as the
/// connection lasts.
pub const MAX_OCCUPANTS: usize = 20_000;

/// How many announced renames wait for their second half. It normally arrives at
/// once, so this only fills if somebody announces renames and never finishes them.
pub const MAX_RENAMES: usize = 64;

impl Room {
    pub fn new(jid: BareJid, nick: String) -> Self {
        Self {
            jid,
            nick,
            joined: false,
            leaving: false,
            nick_attempts: 0,
            topic: None,
            renaming: BTreeMap::new(),
            last_id: None,
            recent: VecDeque::new(),
            recent_set: HashSet::new(),
            occupants: BTreeMap::new(),
        }
    }

    /// The name the UI files this room under.
    pub fn name(&self) -> String {
        self.jid.to_string()
    }

    pub fn is_self(&self, nick: &str) -> bool {
        nick == self.nick
    }

    /// Note that a message with this id is being shown. False if it already
    /// was, in which case it should not be shown again.
    pub fn remember(&mut self, id: &str) -> bool {
        // Looked up in a set, not walked: this runs once for every message in a
        // busy room, and a scan of 512 ids for each is most of what the rest of
        // handling it costs.
        if self.recent_set.contains(id) {
            return false;
        }
        if self.recent.len() >= RECENT_IDS {
            if let Some(old) = self.recent.pop_front() {
                self.recent_set.remove(&old);
            }
        }
        self.recent.push_back(id.to_owned());
        self.recent_set.insert(id.to_owned());
        true
    }

    pub fn occupant(&self, nick: &str) -> Option<&Occupant> {
        self.occupants.get(nick)
    }

    pub fn upsert(&mut self, occupant: Occupant) -> Option<Occupant> {
        self.occupants.insert(occupant.nick.clone(), occupant)
    }

    /// How many people are here besides us. The bound is on these, so that we are
    /// never what a full room turns away - or what makes it turn someone else away.
    /// Counting ourselves would leave a room that let us in as its
    /// [`MAX_OCCUPANTS`] + 1st person unable to finish another occupant's rename,
    /// because removing the old nick would leave it exactly at the limit.
    fn others(&self) -> usize {
        self.occupants.len() - usize::from(self.occupants.contains_key(&self.nick))
    }

    /// Whether `nick` is where a rename we announced ends: our own, completing.
    /// Announcing one removes our entry, so this takes back the place it left.
    fn completes_our_rename(&self, nick: &str) -> bool {
        self.renaming.get(nick).is_some_and(|old| self.is_self(old))
    }

    /// Whether a presence from this nick can be kept. Someone already here always
    /// can, since it adds no one; a full room stops growing rather than leaving.
    ///
    /// `claims_self` is only what the presence says: the room marks it with status
    /// 110, and a room we do not trust can put that on any nick it likes. So a full
    /// room makes room for it only where a stranger cannot repeat it. The nick we
    /// hold is never turned away: it is one entry, and not counted against the
    /// bound. Completing a rename of our own is the same, and it moves the nick we
    /// hold, so a second pair has nothing left of ours to complete. And if we have
    /// not been let in yet, the presence is the end of the list the room sends
    /// first, and the first one marks us as joined - a second claim finds the way
    /// shut. That last is for a room that gave us a nick other than the one we
    /// asked for; without it, one that really is full could never let us in.
    ///
    /// It is not open to the second half of somebody else's rename. Completing one
    /// returns before the room is marked joined, so if it counted, a room could
    /// announce `missing -> fresh` and then `fresh` marked as ours, over and over,
    /// each pair adding someone and none closing the way in. A real rename needs
    /// no exception anyway: the old nick is removed when it is announced, which
    /// leaves the place the new one takes.
    pub fn admits(&self, nick: &str, claims_self: bool) -> bool {
        self.others() < MAX_OCCUPANTS
            || self.occupants.contains_key(nick)
            || self.is_self(nick)
            || self.completes_our_rename(nick)
            || (claims_self && !self.joined && !self.renaming.contains_key(nick))
    }

    /// Remember that `old` said it is becoming `new`, and return the nick the app
    /// has to be told is gone, if there is one.
    ///
    /// Two things make a pending rename disappear without ever completing: there
    /// are too many, so one is forgotten, or `new` is announced again by somebody
    /// else, which replaces whoever was going to be it. Either way the nick that
    /// had been going to become something was removed from [`Self::members`] when
    /// it was announced, and the app has had no word since, so it would show that
    /// row for as long as the room is open - and a room that does this with fresh
    /// nicks would make the app's list grow without a bound. The caller reports
    /// what comes back as having left.
    ///
    /// A map keyed by name cannot say which entry is oldest, so when it is full the
    /// first by name goes: every entry is equally an announcement nobody finished,
    /// and a rename that does complete does so at once.
    ///
    /// Nothing is returned for a nick that is not gone. One that is still going to
    /// be something - `old` itself, or any nick with another entry here, since the
    /// map is keyed by where a rename ends and one nick can be announcing two
    /// names - is pending, and reporting it gone would drop what it said before it
    /// could be carried to the name it takes. And anyone who has since arrived
    /// again has a row that is current, which a removal would hide.
    #[must_use = "the nick it returns has to be reported as gone"]
    pub fn note_rename(&mut self, new: String, old: String) -> Option<String> {
        let forgotten = if self.renaming.len() >= MAX_RENAMES && !self.renaming.contains_key(&new) {
            self.renaming.pop_first().map(|(_, source)| source)
        } else {
            None
        };
        let replaced = self.renaming.insert(new, old);
        forgotten.or(replaced).filter(|gone| {
            !self.occupants.contains_key(gone)
                && !self.renaming.values().any(|source| source == gone)
        })
    }

    pub fn remove(&mut self, nick: &str) -> Option<Occupant> {
        self.occupants.remove(nick)
    }

    pub fn clear_occupants(&mut self) {
        self.occupants.clear();
    }

    /// Everyone, in the order the UI should show them.
    pub fn members(&self) -> Vec<MemberView> {
        let mut members: Vec<MemberView> = self.occupants.values().map(Occupant::view).collect();
        members.sort_by(|a, b| a.sort_key.cmp(&b.sort_key));
        members
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a_room() -> Room {
        Room::new(
            "room@conference.example.org".parse().unwrap(),
            "me".to_owned(),
        )
    }

    #[test]
    fn a_full_room_stops_growing_but_keeps_who_is_there() {
        let mut room = a_room();
        for i in 0..MAX_OCCUPANTS {
            room.upsert(occupant(
                &format!("n{i}"),
                Affiliation::None,
                Role::Participant,
            ));
        }

        assert!(!room.admits("someone new", false));
        assert!(room.admits("n7", false), "someone here can still change");

        room.remove("n7");
        assert!(
            room.admits("someone new", false),
            "and a place that opens is free"
        );
    }

    #[test]
    fn a_full_room_still_lets_us_in_once_and_only_once() {
        let mut room = a_room();
        for i in 0..MAX_OCCUPANTS {
            room.upsert(occupant(
                &format!("n{i}"),
                Affiliation::None,
                Role::Participant,
            ));
        }

        // We are the last of the list a room sends first, so a room with exactly
        // as many people as we keep must still be able to finish letting us in.
        assert!(room.admits("whoever the room calls us", true));
        // Said by anyone else it is a stranger's word, and the room is full.
        assert!(!room.admits("someone new", false));

        // The first such presence is what marks us joined, so the same claim from a
        // room that wants to grow ours without bound finds it shut.
        room.joined = true;
        assert!(!room.admits("made up 1", true));
        assert!(!room.admits("made up 2", true));
        room.joined = false;

        // Not joined, but the second half of a rename: that one returns before the
        // room is marked joined, so if it counted the way in would never close.
        let _ = room.note_rename("fresh".to_owned(), "missing".to_owned());
        assert!(!room.admits("fresh", true));
        room.joined = true;
        // The nick we hold is already counted, so it is never refused.
        assert!(room.admits("me", true));
        assert!(room.admits("me", false));
    }

    #[test]
    fn we_are_not_counted_against_the_bound_so_a_rename_at_the_limit_completes() {
        let mut room = a_room();
        for i in 0..MAX_OCCUPANTS {
            room.upsert(occupant(
                &format!("n{i}"),
                Affiliation::None,
                Role::Participant,
            ));
        }
        // A room as full as it can be of other people, and us as well.
        room.upsert(occupant("me", Affiliation::None, Role::Participant));
        room.joined = true;
        assert!(!room.admits("someone new", false));

        // Somebody renames: the old nick goes when it is announced, and the new
        // one must be let in. Counting us, the room would be at the limit exactly
        // and turn the new nick away, leaving the app with the old name for good.
        room.remove("n7");
        let _ = room.note_rename("n7 renamed".to_owned(), "n7".to_owned());
        assert!(room.admits("n7 renamed", false));
    }

    #[test]
    fn completing_our_own_rename_in_a_full_room_is_let_in_once() {
        let mut room = a_room();
        for i in 0..MAX_OCCUPANTS {
            room.upsert(occupant(
                &format!("n{i}"),
                Affiliation::None,
                Role::Participant,
            ));
        }
        room.joined = true;

        // We announced a rename, which took our entry out. Its second half is ours,
        // whether or not the room marks it so, and it moves the nick we hold.
        let _ = room.note_rename("ally".to_owned(), "me".to_owned());
        assert!(room.admits("ally", false));

        // Once it has, the nick we hold is `ally`, and another entry that names
        // `me` as its source completes nothing of ours.
        room.nick = "ally".to_owned();
        assert!(!room.admits("someone new", true));
        let _ = room.note_rename("made up".to_owned(), "me".to_owned());
        assert!(!room.admits("made up", true));
    }

    #[test]
    fn a_nick_pending_under_two_names_is_not_reported_gone_while_either_is() {
        let mut room = a_room();
        let _ = room.note_rename("bob".to_owned(), "x".to_owned());
        let _ = room.note_rename("carol".to_owned(), "x".to_owned());

        // `bob` is taken by somebody else, which replaces that entry. `x` is still
        // going to be `carol`, and reporting it gone would have its earlier
        // messages dropped before they could be carried over to that name.
        assert_eq!(room.note_rename("bob".to_owned(), "y".to_owned()), None);

        // Replace the other one as well, and now it really is gone.
        assert_eq!(
            room.note_rename("carol".to_owned(), "z".to_owned()),
            Some("x".to_owned())
        );
    }

    #[test]
    fn forgetting_one_of_two_entries_for_a_nick_does_not_report_it() {
        let mut room = a_room();
        // The first two by name share a source.
        let _ = room.note_rename("new000".to_owned(), "shared".to_owned());
        let _ = room.note_rename("new001".to_owned(), "shared".to_owned());
        for i in 2..MAX_RENAMES {
            let _ = room.note_rename(format!("new{i:03}"), format!("old{i:03}"));
        }

        // The first goes to make room, but `shared` is still pending under the
        // second.
        assert_eq!(
            room.note_rename("new999".to_owned(), "old999".to_owned()),
            None
        );
        assert!(!room.renaming.contains_key("new000"));
        assert!(room.renaming.contains_key("new001"));
    }

    #[test]
    fn renames_nobody_finishes_do_not_pile_up() {
        let mut room = a_room();
        for i in 0..(MAX_RENAMES * 3) {
            let _ = room.note_rename(format!("new{i:04}"), format!("old{i:04}"));
        }

        assert_eq!(room.renaming.len(), MAX_RENAMES);
    }

    #[test]
    fn a_rename_that_is_forgotten_is_handed_back_so_it_can_be_reported() {
        let mut room = a_room();
        for i in 0..MAX_RENAMES {
            assert_eq!(
                room.note_rename(format!("new{i:03}"), format!("old{i:03}")),
                None,
                "there is room for {MAX_RENAMES} of them"
            );
        }

        // One more, and the first by name makes way. Its old nick is what the app
        // is still showing.
        assert_eq!(
            room.note_rename("new999".to_owned(), "old999".to_owned()),
            Some("old000".to_owned())
        );
        assert_eq!(room.renaming.len(), MAX_RENAMES);
        assert!(!room.renaming.contains_key("new000"));
    }

    #[test]
    fn announcing_a_rename_again_replaces_its_entry_and_evicts_no_one_else() {
        let mut room = a_room();
        for i in 0..MAX_RENAMES {
            let _ = room.note_rename(format!("new{i:03}"), format!("old{i:03}"));
        }

        // The same new nick again: it replaces its own entry. Dropping the guard
        // that checks for that would evict the first one as well, and this is the
        // only place that would show.
        let gone = room.note_rename("new010".to_owned(), "someone else".to_owned());
        assert_eq!(room.renaming.len(), MAX_RENAMES);
        assert!(
            room.renaming.contains_key("new000"),
            "nothing was made to leave"
        );
        assert_eq!(room.renaming["new010"], "someone else");
        // Only the one it replaced is gone.
        assert_eq!(gone, Some("old010".to_owned()));
    }

    #[test]
    fn a_replaced_rename_is_handed_back_unless_it_is_still_pending_or_here() {
        let mut room = a_room();
        let _ = room.note_rename("new".to_owned(), "first".to_owned());

        // The same pair again changes nothing: that nick is still going to be it.
        assert_eq!(room.note_rename("new".to_owned(), "first".to_owned()), None);

        // Somebody else announcing the same destination replaces it, and whoever
        // was going to be it is what the app still shows.
        assert_eq!(
            room.note_rename("new".to_owned(), "second".to_owned()),
            Some("first".to_owned())
        );

        // But one that has since arrived again has a row that is current, and
        // reporting it gone would hide someone who is here.
        room.upsert(occupant("second", Affiliation::None, Role::Participant));
        assert_eq!(room.note_rename("new".to_owned(), "third".to_owned()), None);
    }

    #[test]
    fn a_nick_renamed_twice_is_not_reported_gone_while_one_is_pending() {
        let mut room = a_room();
        for i in 0..MAX_RENAMES {
            let _ = room.note_rename(format!("new{i:03}"), format!("old{i:03}"));
        }

        // The entry forgotten to make room belongs to the nick now announcing
        // another name, which is itself still pending under the new one.
        assert_eq!(
            room.note_rename("new999".to_owned(), "old000".to_owned()),
            None
        );
        assert!(!room.renaming.contains_key("new000"));
        assert_eq!(room.renaming["new999"], "old000");
    }

    fn occupant(nick: &str, affiliation: Affiliation, role: Role) -> Occupant {
        Occupant {
            nick: nick.to_owned(),
            affiliation,
            role,
            away: false,
        }
    }

    #[test]
    fn standing_maps_onto_the_marks_irc_users_know() {
        let p = |a, r| occupant("x", a, r).prefix();
        assert_eq!(p(Affiliation::Owner, Role::Moderator), Some('~'));
        assert_eq!(p(Affiliation::Admin, Role::Moderator), Some('&'));
        assert_eq!(p(Affiliation::None, Role::Moderator), Some('@'));
        assert_eq!(p(Affiliation::Member, Role::Participant), Some('+'));
        assert_eq!(p(Affiliation::None, Role::Participant), None);
        assert_eq!(p(Affiliation::None, Role::Visitor), None);
    }

    #[test]
    fn a_moderator_who_is_also_a_member_shows_as_the_moderator() {
        assert_eq!(
            occupant("x", Affiliation::Member, Role::Moderator).prefix(),
            Some('@')
        );
    }

    #[test]
    fn members_sort_by_standing_then_name_ignoring_case() {
        let mut room = Room::new("room@muc.example.org".parse().unwrap(), "me".to_owned());
        room.upsert(occupant("zed", Affiliation::None, Role::Participant));
        room.upsert(occupant("Amy", Affiliation::None, Role::Participant));
        room.upsert(occupant("mod", Affiliation::None, Role::Moderator));
        room.upsert(occupant("boss", Affiliation::Owner, Role::Moderator));
        let order: Vec<_> = room.members().into_iter().map(|m| m.nick).collect();
        assert_eq!(order, ["boss", "mod", "Amy", "zed"]);
    }

    #[test]
    fn the_sort_key_has_the_shape_the_irc_side_produces() {
        let key = occupant("Amy", Affiliation::None, Role::Moderator).sort_key();
        assert_eq!(key, "0002\u{1}amy");
    }

    #[test]
    fn names_lose_control_and_layout_characters() {
        assert_eq!(clean_name("al\u{202e}ice\u{0}"), "alice");
        assert_eq!(clean_name("a\nb"), "ab");
        assert_eq!(
            clean_name(&"x".repeat(500)).chars().count(),
            limits::MAX_NICK
        );
    }

    #[test]
    fn a_mention_is_a_whole_word() {
        assert!(mentions("sam", "hey Sam, look"));
        assert!(mentions("sam", "sam"));
        assert!(mentions("sam", "sam: hi"));
        assert!(mentions("sam", "thanks sam."));
        assert!(!mentions("sam", "the same thing"));
        assert!(!mentions("sam", "samples"));
        assert!(!mentions("", "anything"));
    }
}
