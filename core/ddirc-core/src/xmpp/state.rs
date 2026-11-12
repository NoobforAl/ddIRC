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

/// The most people a room remembers: the same bound as an IRC channel's members.
/// A room service, or a crowd of made-up occupants, decides how many presences
/// arrive, and each would otherwise be kept for as long as the connection lasts.
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

    /// Whether a presence from this nick can be kept. Someone already here always
    /// can, since it adds no one; a full room stops growing rather than leaving.
    ///
    /// `claims_self` is only what the presence says: the room marks it with status
    /// 110, and a room we do not trust can put that on any nick it likes. So a full
    /// room makes room for it in just two cases, both of which a stranger cannot
    /// repeat. It is the nick we hold, which is already counted and so adds no one.
    /// Or we have not been let in yet, in which case it is the end of the list the
    /// room sends first, and the first one marks us as joined - a second claim
    /// finds the room full again. Without the second case a room that really has
    /// [`MAX_OCCUPANTS`] people could never finish letting us in.
    ///
    /// A rename needs no exception: the old nick is removed when it is announced,
    /// which leaves the place the new one takes.
    pub fn admits(&self, nick: &str, claims_self: bool) -> bool {
        self.occupants.len() < MAX_OCCUPANTS
            || self.occupants.contains_key(nick)
            || self.is_self(nick)
            || (claims_self && !self.joined)
    }

    /// Remember that `old` said it is becoming `new`, and return whichever nick
    /// was forgotten to make room for it, if any.
    ///
    /// A map keyed by name cannot say which entry is oldest, so the first by name
    /// goes: every entry here is equally an announcement nobody finished, and a
    /// rename that does complete does so at once. Its only cost is that the one
    /// forgotten shows as a leave rather than a rename. The caller has to say so,
    /// because the app has had no word of that nick since it was announced, and
    /// would keep showing it for as long as the room is open.
    #[must_use = "the nick it returns has to be reported as gone"]
    pub fn note_rename(&mut self, new: String, old: String) -> Option<String> {
        let dropped = if self.renaming.len() >= MAX_RENAMES && !self.renaming.contains_key(&new) {
            self.renaming.pop_first().map(|(_, old)| old)
        } else {
            None
        };
        self.renaming.insert(new, old);
        dropped
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
        // The nick we hold is already counted, so it is never refused.
        assert!(room.admits("me", true));
        assert!(room.admits("me", false));
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
    fn announcing_a_rename_again_forgets_nobody() {
        let mut room = a_room();
        for i in 0..MAX_RENAMES {
            let _ = room.note_rename(format!("new{i:03}"), format!("old{i:03}"));
        }

        // The same new nick again: it replaces its own entry. Dropping the guard
        // that checks for that would evict the first one as well, and this is the
        // only place that would show.
        assert_eq!(
            room.note_rename("new010".to_owned(), "someone else".to_owned()),
            None
        );
        assert_eq!(room.renaming.len(), MAX_RENAMES);
        assert!(
            room.renaming.contains_key("new000"),
            "nothing was made to leave"
        );
        assert_eq!(room.renaming["new010"], "someone else");
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
