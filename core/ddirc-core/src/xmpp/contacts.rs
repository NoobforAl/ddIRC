//! The contact list: who we have, who can see whom, and who is there.
//!
//! In XMPP a one-to-one chat is not with "anyone"; it sits on top of a roster.
//! The server keeps the list, and presence - here, away, busy, gone - flows
//! between two people only after each has agreed to it. This holds what the
//! server has told us and turns it into the events the UI draws, and decides
//! nothing about what to say back: whether to let someone see us is the user's,
//! and nothing here ever answers a request on their behalf.
//!
//! Three rules, each a guard against a different party.
//!
//! **Presence is believed only from people we have.** A stranger can send
//! presence to anyone; letting it into the list would let them put themselves
//! on it, with whatever name and status they chose.
//!
//! **A roster push is believed only from our own server.** The caller checks
//! where it came from; this only applies it.
//!
//! **Everything is bounded.** A list, a set of requests, the resources one
//! person is signed in from and a status text each have a ceiling, because each
//! is a place the other end could make us hold memory it chose.

use std::collections::{HashMap, HashSet};

use tokio_xmpp::jid::{BareJid, Jid};
use tokio_xmpp::parsers::presence::{Presence, Show, Type as PresenceType};
use tokio_xmpp::parsers::roster::{self, Ask, Item};

use crate::api::events::IrcEvent;
use crate::api::types::{Availability, ContactView, Subscription};
use crate::xmpp::state::{clean_line, clean_name};

/// The most contacts held. A very large roster is a thousand people; past this
/// the rest are not shown rather than the list growing without end.
pub const MAX_CONTACTS: usize = 2_000;

/// The most people who may be waiting on an answer at once.
const MAX_REQUESTS: usize = 100;

/// The most places one person is tracked as being signed in from.
const MAX_RESOURCES: usize = 16;

/// The longest status text kept, in characters.
const MAX_STATUS: usize = 200;

/// What one place a person is signed in from has said.
#[derive(Debug, Clone)]
struct Seen {
    availability: Availability,
    status: String,
    priority: i8,
}

#[derive(Debug)]
struct Contact {
    name: Option<String>,
    subscription: Subscription,
    asked: bool,
    resources: HashMap<String, Seen>,
}

/// The roster and what is known of everyone on it.
#[derive(Debug, Default)]
pub struct Contacts {
    items: HashMap<BareJid, Contact>,
    /// People waiting for an answer, in the order they asked.
    requests: Vec<BareJid>,
}

impl Contacts {
    pub fn contains(&self, jid: &BareJid) -> bool {
        self.items.contains_key(jid)
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Whether the roster already holds as many as it will.
    pub fn is_full(&self) -> bool {
        self.items.len() >= MAX_CONTACTS
    }

    /// One contact as the UI draws them, if we have them.
    pub fn view(&self, jid: &BareJid) -> Option<ContactView> {
        self.items.get(jid).map(|c| Self::render(jid, c))
    }

    fn render(jid: &BareJid, contact: &Contact) -> ContactView {
        // Of the places they are signed in from, the one with the highest
        // priority speaks for them, and among equals the most available. A
        // phone and a laptop are one person, and "away" on the one they are not
        // using should not hide "here" on the one they are.
        let best = contact
            .resources
            .values()
            .max_by_key(|seen| (seen.priority, rank(seen.availability)));
        ContactView {
            jid: jid.to_string(),
            name: contact.name.clone(),
            subscription: contact.subscription,
            asked: contact.asked,
            availability: best.map_or(Availability::Offline, |s| s.availability),
            status: best.map(|s| s.status.clone()).unwrap_or_default(),
        }
    }

    /// Apply the server's roster.
    ///
    /// `full` is true for the answer to asking for the whole list, which is
    /// the entire truth: anyone it does not mention is gone. A push carries
    /// only what changed. Returns the events for the UI, in order.
    pub fn apply_roster(&mut self, items: Vec<Item>, own: &BareJid, full: bool) -> Vec<IrcEvent> {
        let mut events = Vec::new();
        let mut mentioned: HashSet<BareJid> = HashSet::new();
        for item in items {
            if item.jid == *own {
                // Ourselves is not a contact, however the server lists us.
                continue;
            }
            mentioned.insert(item.jid.clone());
            if item.subscription == roster::Subscription::Remove {
                if self.items.remove(&item.jid).is_some() {
                    events.push(IrcEvent::ContactRemoved {
                        jid: item.jid.to_string(),
                    });
                }
                continue;
            }
            if !self.items.contains_key(&item.jid) && self.is_full() {
                continue;
            }
            let name = item
                .name
                .as_deref()
                .map(clean_name)
                .filter(|n| !n.is_empty());
            let subscription = match item.subscription {
                roster::Subscription::To => Subscription::To,
                roster::Subscription::From => Subscription::From,
                roster::Subscription::Both => Subscription::Both,
                roster::Subscription::None | roster::Subscription::Remove => Subscription::None,
            };
            let asked = item.ask == Ask::Subscribe;
            let contact = self
                .items
                .entry(item.jid.clone())
                .or_insert_with(|| Contact {
                    name: None,
                    subscription: Subscription::None,
                    asked: false,
                    resources: HashMap::new(),
                });
            contact.name = name;
            contact.subscription = subscription;
            contact.asked = asked;
            // Someone who asked to see us and is now on the list by their own
            // doing, or ours, is answered by the list: the request is moot once
            // they can see us.
            if matches!(subscription, Subscription::From | Subscription::Both) {
                self.requests.retain(|r| r != &item.jid);
            }
            if let Some(view) = self.view(&item.jid) {
                events.push(IrcEvent::Contact(Box::new(view)));
            }
        }
        if full {
            let gone: Vec<BareJid> = self
                .items
                .keys()
                .filter(|jid| !mentioned.contains(*jid))
                .cloned()
                .collect();
            for jid in gone {
                self.items.remove(&jid);
                events.push(IrcEvent::ContactRemoved {
                    jid: jid.to_string(),
                });
            }
        }
        events
    }

    /// Apply a contact's presence.
    ///
    /// Anyone who is not on the list is ignored. Returns an event only when
    /// what the UI shows would change.
    pub fn apply_presence(&mut self, from: &Jid, presence: &Presence) -> Option<IrcEvent> {
        let bare = from.to_bare();
        let resource = from.resource().map(|r| r.as_str().to_owned())?;
        let before = self.view(&bare)?;
        let contact = self.items.get_mut(&bare)?;
        match presence.type_ {
            PresenceType::Unavailable => {
                contact.resources.remove(&resource);
            }
            PresenceType::None => {
                if !contact.resources.contains_key(&resource)
                    && contact.resources.len() >= MAX_RESOURCES
                {
                    return None;
                }
                let availability = match presence.show {
                    Some(Show::Away) => Availability::Away,
                    Some(Show::Dnd) => Availability::Dnd,
                    Some(Show::Xa) => Availability::ExtendedAway,
                    Some(Show::Chat) | None => Availability::Available,
                };
                let status = presence
                    .statuses
                    .values()
                    .next()
                    .map(|s| clean_line(s, MAX_STATUS))
                    .unwrap_or_default();
                contact.resources.insert(
                    resource,
                    Seen {
                        availability,
                        status,
                        priority: presence.priority.0,
                    },
                );
            }
            // Requests, answers and errors are not availability.
            _ => return None,
        }
        let after = Self::render(&bare, self.items.get(&bare)?);
        (after != before).then(|| IrcEvent::Contact(Box::new(after)))
    }

    /// Forget who is signed in. A new login starts from nothing, and the server
    /// sends everyone's presence again; the ones that do not come back are
    /// offline. Returns the events for those that were not.
    pub fn forget_presence(&mut self) -> Vec<IrcEvent> {
        let mut events = Vec::new();
        for (jid, contact) in &mut self.items {
            if !contact.resources.is_empty() {
                contact.resources.clear();
                events.push(IrcEvent::Contact(Box::new(Self::render(jid, contact))));
            }
        }
        events
    }

    /// Note that someone asked to see us. False if there was no room, or they
    /// already had.
    pub fn add_request(&mut self, jid: BareJid) -> bool {
        if self.requests.contains(&jid) || self.requests.len() >= MAX_REQUESTS {
            return false;
        }
        self.requests.push(jid);
        true
    }

    /// Whether this person is waiting on us. Taken off the list as a side
    /// effect, so one request is answered once.
    pub fn take_request(&mut self, jid: &BareJid) -> bool {
        let before = self.requests.len();
        self.requests.retain(|r| r != jid);
        self.requests.len() != before
    }

    /// Forget everyone who was waiting, and say who that was.
    pub fn clear_requests(&mut self) -> Vec<BareJid> {
        std::mem::take(&mut self.requests)
    }

    /// Everyone waiting on an answer, oldest first.
    pub fn requests(&self) -> &[BareJid] {
        &self.requests
    }
}

/// How available a state is, for choosing between a person's devices.
fn rank(availability: Availability) -> u8 {
    match availability {
        Availability::Available => 4,
        Availability::Away => 3,
        Availability::ExtendedAway => 2,
        Availability::Dnd => 1,
        Availability::Offline => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jid(s: &str) -> BareJid {
        s.parse().unwrap()
    }

    fn item(j: &str, subscription: roster::Subscription) -> Item {
        Item {
            jid: jid(j),
            name: None,
            subscription,
            ask: Ask::None,
            groups: Vec::new(),
            approved: None,
        }
    }

    fn here(contacts: &mut Contacts, from: &str, show: Option<Show>, priority: i8) {
        let mut presence = Presence::available().with_priority(priority);
        presence.show = show;
        contacts.apply_presence(&from.parse().unwrap(), &presence);
    }

    #[test]
    fn a_stranger_cannot_put_themselves_on_the_list() {
        let mut c = Contacts::default();
        let event = c.apply_presence(
            &"mallory@evil.example/x".parse().unwrap(),
            &Presence::available(),
        );
        assert!(event.is_none());
        assert!(c.is_empty());
    }

    #[test]
    fn the_roster_is_the_whole_truth_when_it_is_the_whole_list() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![
                item("a@example.org", roster::Subscription::Both),
                item("b@example.org", roster::Subscription::Both),
            ],
            &own,
            true,
        );
        let events = c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        assert!(matches!(
            events.as_slice(),
            [IrcEvent::Contact(_), IrcEvent::ContactRemoved { jid }] if jid == "b@example.org"
        ));
        assert!(!c.contains(&jid("b@example.org")));
    }

    #[test]
    fn a_push_changes_only_what_it_names() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![
                item("a@example.org", roster::Subscription::Both),
                item("b@example.org", roster::Subscription::Both),
            ],
            &own,
            true,
        );
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::To)],
            &own,
            false,
        );
        assert!(c.contains(&jid("b@example.org")));
        assert_eq!(
            c.view(&jid("a@example.org")).unwrap().subscription,
            Subscription::To
        );
    }

    #[test]
    fn removal_removes_and_says_so() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        let events = c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Remove)],
            &own,
            false,
        );
        assert!(matches!(
            events.as_slice(),
            [IrcEvent::ContactRemoved { .. }]
        ));
        assert!(c.is_empty());
    }

    #[test]
    fn ourselves_are_not_a_contact() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("me@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        assert!(c.is_empty());
    }

    #[test]
    fn the_roster_is_bounded() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        let items = (0..MAX_CONTACTS + 50)
            .map(|i| item(&format!("u{i}@example.org"), roster::Subscription::Both))
            .collect();
        c.apply_roster(items, &own, true);
        assert_eq!(c.len(), MAX_CONTACTS);
    }

    #[test]
    fn a_name_is_cleaned() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        let mut i = item("a@example.org", roster::Subscription::Both);
        i.name = Some("Al\u{202e}ice\u{0007}".to_owned());
        c.apply_roster(vec![i], &own, true);
        assert_eq!(
            c.view(&jid("a@example.org")).unwrap().name.as_deref(),
            Some("Alice")
        );
    }

    #[test]
    fn a_contact_is_offline_until_they_say_otherwise() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        assert_eq!(
            c.view(&jid("a@example.org")).unwrap().availability,
            Availability::Offline
        );
        here(&mut c, "a@example.org/phone", None, 0);
        assert_eq!(
            c.view(&jid("a@example.org")).unwrap().availability,
            Availability::Available
        );
    }

    #[test]
    fn two_devices_are_one_person() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        here(&mut c, "a@example.org/phone", Some(Show::Away), 0);
        here(&mut c, "a@example.org/laptop", None, 0);
        assert_eq!(
            c.view(&jid("a@example.org")).unwrap().availability,
            Availability::Available
        );
        // Priority outranks being more available.
        here(&mut c, "a@example.org/phone", Some(Show::Dnd), 10);
        assert_eq!(
            c.view(&jid("a@example.org")).unwrap().availability,
            Availability::Dnd
        );
    }

    #[test]
    fn going_offline_from_the_last_device_is_offline() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        here(&mut c, "a@example.org/phone", None, 0);
        let event = c.apply_presence(
            &"a@example.org/phone".parse().unwrap(),
            &Presence::unavailable(),
        );
        assert!(
            matches!(event, Some(IrcEvent::Contact(v)) if v.availability == Availability::Offline)
        );
    }

    #[test]
    fn a_change_that_shows_nothing_says_nothing() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        here(&mut c, "a@example.org/phone", None, 0);
        let again = c.apply_presence(
            &"a@example.org/phone".parse().unwrap(),
            &Presence::available(),
        );
        assert!(again.is_none());
    }

    #[test]
    fn a_status_is_cleaned_and_bounded() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        let mut presence = Presence::available();
        presence.set_status("", format!("\u{0007}lunch\u{202e}{}", "x".repeat(500)));
        c.apply_presence(&"a@example.org/p".parse().unwrap(), &presence);
        let status = c.view(&jid("a@example.org")).unwrap().status;
        assert!(status.starts_with("lunch"));
        assert!(!status.contains('\u{202e}'));
        assert!(status.chars().count() <= MAX_STATUS);
    }

    #[test]
    fn the_places_one_person_is_tracked_are_bounded() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        for i in 0..MAX_RESOURCES + 10 {
            here(&mut c, &format!("a@example.org/r{i}"), None, 0);
        }
        assert!(c.items[&jid("a@example.org")].resources.len() <= MAX_RESOURCES);
    }

    #[test]
    fn a_new_login_forgets_who_was_there() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::Both)],
            &own,
            true,
        );
        here(&mut c, "a@example.org/phone", None, 0);
        let events = c.forget_presence();
        assert_eq!(events.len(), 1);
        assert_eq!(
            c.view(&jid("a@example.org")).unwrap().availability,
            Availability::Offline
        );
    }

    #[test]
    fn requests_are_answered_once_and_bounded() {
        let mut c = Contacts::default();
        assert!(c.add_request(jid("a@example.org")));
        assert!(!c.add_request(jid("a@example.org")));
        assert!(c.take_request(&jid("a@example.org")));
        assert!(!c.take_request(&jid("a@example.org")));
        for i in 0..MAX_REQUESTS + 20 {
            c.add_request(jid(&format!("u{i}@example.org")));
        }
        assert_eq!(c.requests().len(), MAX_REQUESTS);
    }

    #[test]
    fn someone_who_can_now_see_us_is_no_longer_waiting() {
        let own = jid("me@example.org");
        let mut c = Contacts::default();
        c.add_request(jid("a@example.org"));
        c.apply_roster(
            vec![item("a@example.org", roster::Subscription::From)],
            &own,
            false,
        );
        assert!(c.requests().is_empty());
    }
}
