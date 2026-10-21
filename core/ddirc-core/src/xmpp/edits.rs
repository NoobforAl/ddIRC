//! Correcting and taking back messages.
//!
//! IRC has nothing like this: what was said was said. XMPP lets the author of
//! a message replace its text (XEP-0308) or retract it (XEP-0424), and a client
//! that does not honour them leaves a conversation reading as though the
//! correction were a second, confusing message, and a retracted one still
//! there to be read.
//!
//! The two refer to the original differently, and the difference is the whole
//! difficulty. A correction names the id the *sender* put on the original. A
//! retraction names the id the *room* assigned to it, in a room, and the
//! sender's id in a one-to-one chat. The UI knows a message by one id only, so
//! the index here remembers both, and which author wrote it.
//!
//! The author is the point. Anyone may send a stanza that says "replace message
//! X", and one that is believed from anyone is a way to rewrite what other
//! people said. A correction or a retraction is applied only when it comes from
//! whoever wrote the original, as this index recorded when it was shown.

use std::collections::VecDeque;

use tokio_xmpp::jid::Jid;
use tokio_xmpp::minidom::Element;
use tokio_xmpp::parsers::message::{Id, Lang, Message};
use tokio_xmpp::parsers::message_correct::Replace;
use tokio_xmpp::parsers::stanza_id::OriginId;

use crate::state::truncate;
use crate::xmpp::session::xml_escape;

/// How many messages are remembered well enough to be corrected or retracted.
///
/// Far more than anyone corrects, and bounded because the index is filled by
/// whatever the network says. A message older than this scrolled out of the
/// index long before anyone would edit it; one that did is simply not editable.
pub const MAX_INDEXED: usize = 2_000;

/// The longest id kept, as everywhere else an id from the network is held.
const MAX_ID: usize = 200;

pub const NS_RETRACT: &str = "urn:xmpp:message-retract:1";
const NS_FALLBACK: &str = "urn:xmpp:fallback:0";
const NS_HINTS: &str = "urn:xmpp:hints";

/// What is known about a message that was shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The conversation it was shown in, spelled as the UI was told.
    pub conversation: String,
    /// Who wrote it: a nickname in a room, an address in a chat.
    pub author: String,
    /// The id the UI was given for it.
    pub msgid: String,
    /// The id its sender put on it, which a correction refers to.
    pub origin: Option<String>,
    /// We wrote it, so we may correct or retract it.
    pub mine: bool,
}

/// The recent messages, newest last.
#[derive(Debug, Default)]
pub struct MessageIndex {
    entries: VecDeque<Entry>,
}

impl MessageIndex {
    /// Remember a message that was shown.
    pub fn record(&mut self, entry: Entry) {
        // The same id from the same author. A different author's message under
        // an id we already hold is a different message, and dropping it would
        // let anyone who guesses our next id keep our message out of the index
        // by saying something under it first.
        if self.entries.iter().any(|e| {
            e.conversation == entry.conversation
                && e.msgid == entry.msgid
                && e.author == entry.author
        }) {
            return;
        }
        if self.entries.len() >= MAX_INDEXED {
            self.entries.pop_front();
        }
        self.entries.push_back(entry);
    }

    /// Whether a message was already shown in this conversation. How a replayed
    /// message is told from one that is new, whatever id the archive gave it.
    pub fn contains(&self, conversation: &str, msgid: &str) -> bool {
        self.entries
            .iter()
            .any(|e| e.conversation == conversation && e.msgid == msgid)
    }

    /// The message a correction from `author` refers to, if there is one by
    /// them. A match by anyone else is no match: it is somebody else's message
    /// and theirs to change.
    pub fn for_correction(&self, conversation: &str, origin: &str, author: &str) -> Option<&Entry> {
        self.entries.iter().rev().find(|e| {
            e.conversation == conversation
                && e.author == author
                && e.origin.as_deref() == Some(origin)
        })
    }

    /// The message a retraction from `author` refers to, if there is one by
    /// them. Either id is accepted: a room is meant to be named by its own id
    /// and clients differ.
    pub fn for_retraction(&self, conversation: &str, id: &str, author: &str) -> Option<&Entry> {
        self.entries.iter().rev().find(|e| {
            e.conversation == conversation
                && e.author == author
                && (e.msgid == id || e.origin.as_deref() == Some(id))
        })
    }

    /// One of our own messages, by the id the UI knows it by.
    pub fn ours(&self, conversation: &str, msgid: &str) -> Option<&Entry> {
        self.entries
            .iter()
            .rev()
            .find(|e| e.mine && e.conversation == conversation && e.msgid == msgid)
    }

    /// Forget everything one author said in a conversation.
    ///
    /// For when they leave a room. A room names people by nickname, and a
    /// nickname is free the moment its holder goes: whoever takes it next must
    /// not be able to change what the last holder said.
    pub fn forget_author(&mut self, conversation: &str, author: &str) {
        self.entries
            .retain(|e| !(e.conversation == conversation && e.author == author));
    }

    /// Forget a whole conversation, for when we leave it.
    pub fn forget_conversation(&mut self, conversation: &str) {
        self.entries.retain(|e| e.conversation != conversation);
    }

    /// Forget every conversation whose name begins with `prefix`: the private
    /// chats inside a room, which are filed as `room/nick`.
    pub fn forget_conversation_prefix(&mut self, prefix: &str) {
        self.entries.retain(|e| !e.conversation.starts_with(prefix));
    }

    /// Carry an author's messages over to a new name, for a rename in a room.
    pub fn rename_author(&mut self, conversation: &str, old: &str, new: &str) {
        for e in &mut self.entries {
            if e.conversation == conversation && e.author == old {
                e.author = new.to_owned();
            }
        }
    }

    /// Forget a message, once it has been retracted.
    pub fn forget(&mut self, conversation: &str, msgid: &str) {
        self.entries
            .retain(|e| !(e.conversation == conversation && e.msgid == msgid));
    }
}

/// The id a sender put on a message: the stable `origin-id` when there is one,
/// and the `id` attribute otherwise.
pub fn origin_id(message: &mut Message) -> Option<String> {
    if let Some(origin) = message.extract_valid_payload::<OriginId>() {
        return Some(truncate(&origin.id, MAX_ID));
    }
    message.id.as_ref().map(|id| truncate(&id.0, MAX_ID))
}

/// The id a retraction names, if this message is one.
pub fn retraction(message: &Message) -> Option<String> {
    message
        .payloads
        .iter()
        .find(|p| p.is("retract", NS_RETRACT))
        .and_then(|p| p.attr("id"))
        .filter(|id| !id.is_empty())
        .map(|id| truncate(id, MAX_ID))
}

/// Put an id on an outgoing message, in both places a receiver may look.
///
/// `origin-id` (XEP-0359) is the one that survives a server or a room rewriting
/// the `id` attribute, which is the thing a later correction needs to find it by.
pub fn with_origin_id(mut message: Message, id: &str) -> Message {
    message.id = Some(Id(id.to_owned()));
    message.with_payload(OriginId { id: id.to_owned() })
}

/// A message that replaces the text of an earlier one of ours.
pub fn correction(to: Jid, group: bool, id: &str, replaces: &str, body: String) -> Message {
    let message = if group {
        Message::groupchat(Some(to))
    } else {
        Message::chat(Some(to))
    };
    let mut message = with_origin_id(message, id).with_payload(Replace {
        id: Id(replaces.to_owned()),
    });
    message.bodies.insert(Lang::new(), body);
    message
}

/// A message that takes back an earlier one of ours.
///
/// Carries a fallback body, so that the server archives it and a client that
/// has never heard of retraction says that one was attempted, rather than
/// nothing, and a store-hint, so that it is archived even so.
pub fn retract(to: Jid, group: bool, id: &str, retracts: &str) -> Message {
    let message = if group {
        Message::groupchat(Some(to))
    } else {
        Message::chat(Some(to))
    };
    let mut message = with_origin_id(message, id);
    // Written out rather than built, because the builder wants a validated
    // attribute name and these are constants; the id is the one part of it
    // someone else chose, and is escaped.
    let retraction = format!(
        "<retract xmlns='{NS_RETRACT}' id='{}'/>",
        xml_escape(retracts)
    );
    for xml in [
        retraction.as_str(),
        &format!("<fallback xmlns='{NS_FALLBACK}' for='{NS_RETRACT}'/>"),
        &format!("<store xmlns='{NS_HINTS}'/>"),
    ] {
        if let Ok(element) = xml.parse::<Element>() {
            message.payloads.push(element);
        }
    }
    message.bodies.insert(
        Lang::new(),
        "/me retracted a previous message, but your client does not support that.".to_owned(),
    );
    message
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(conversation: &str, author: &str, msgid: &str, origin: Option<&str>) -> Entry {
        Entry {
            conversation: conversation.to_owned(),
            author: author.to_owned(),
            msgid: msgid.to_owned(),
            origin: origin.map(str::to_owned),
            mine: false,
        }
    }

    #[test]
    fn a_correction_finds_the_message_by_the_senders_own_id() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "stanza-1", Some("bobs-id")));
        let found = index.for_correction("room", "bobs-id", "bob").unwrap();
        assert_eq!(found.msgid, "stanza-1");
    }

    #[test]
    fn nobody_else_can_correct_it() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "stanza-1", Some("bobs-id")));
        assert!(index.for_correction("room", "bobs-id", "mallory").is_none());
    }

    #[test]
    fn naming_a_message_of_bobs_in_a_message_of_mallorys_does_not_borrow_it() {
        // Mallory sends a message whose own id is the one Bob's carries. A
        // correction from either finds only their own.
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "stanza-1", Some("shared")));
        index.record(entry("room", "mallory", "stanza-2", Some("shared")));
        assert_eq!(
            index.for_correction("room", "shared", "bob").unwrap().msgid,
            "stanza-1"
        );
        assert_eq!(
            index
                .for_correction("room", "shared", "mallory")
                .unwrap()
                .msgid,
            "stanza-2"
        );
    }

    #[test]
    fn a_correction_in_another_conversation_finds_nothing() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "stanza-1", Some("bobs-id")));
        assert!(index.for_correction("other", "bobs-id", "bob").is_none());
    }

    #[test]
    fn a_retraction_may_name_either_id_but_only_from_the_author() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "stanza-1", Some("bobs-id")));
        assert!(index.for_retraction("room", "stanza-1", "bob").is_some());
        assert!(index.for_retraction("room", "bobs-id", "bob").is_some());
        assert!(index
            .for_retraction("room", "stanza-1", "mallory")
            .is_none());
    }

    #[test]
    fn only_our_own_messages_are_ours_to_change() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "stanza-1", None));
        let mut mine = entry("room", "alice", "stanza-2", Some("a"));
        mine.mine = true;
        index.record(mine);
        assert!(index.ours("room", "stanza-1").is_none());
        assert!(index.ours("room", "stanza-2").is_some());
    }

    #[test]
    fn the_index_is_bounded_and_forgets_the_oldest() {
        let mut index = MessageIndex::default();
        for i in 0..MAX_INDEXED + 10 {
            index.record(entry("room", "bob", &format!("s{i}"), None));
        }
        assert_eq!(index.entries.len(), MAX_INDEXED);
        assert!(index.for_retraction("room", "s0", "bob").is_none());
        assert!(index
            .for_retraction("room", &format!("s{}", MAX_INDEXED + 9), "bob")
            .is_some());
    }

    #[test]
    fn someone_else_claiming_our_id_does_not_keep_ours_out() {
        let mut index = MessageIndex::default();
        // Mallory says something first under the id our next message will use.
        index.record(entry("room", "mallory", "alice-7", Some("alice-7")));
        let mut ours = entry("room", "alice", "alice-7", Some("alice-7"));
        ours.mine = true;
        index.record(ours);
        assert!(index.ours("room", "alice-7").is_some());
        // And her entry is still hers alone.
        assert!(index.for_correction("room", "alice-7", "mallory").is_some());
    }

    #[test]
    fn a_nickname_taken_over_does_not_inherit_what_the_last_holder_said() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "s1", Some("b1")));
        index.record(entry("other", "bob", "s2", Some("b2")));
        index.forget_author("room", "bob");
        assert!(index.for_correction("room", "b1", "bob").is_none());
        assert!(index.for_correction("other", "b2", "bob").is_some());
    }

    #[test]
    fn a_rename_carries_the_messages_to_the_new_name_only() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "s1", Some("b1")));
        index.rename_author("room", "bob", "robert");
        assert!(index.for_correction("room", "b1", "bob").is_none());
        assert!(index.for_correction("room", "b1", "robert").is_some());
    }

    #[test]
    fn forgetting_by_prefix_takes_the_private_chats_of_a_room() {
        let mut index = MessageIndex::default();
        index.record(entry("room@c/bob", "room@c/bob", "s1", Some("b1")));
        index.record(entry("room@c", "bob", "s2", Some("b2")));
        index.record(entry("room2@c/bob", "room2@c/bob", "s3", Some("b3")));
        index.forget_conversation_prefix("room@c/");
        assert!(index
            .for_correction("room@c/bob", "b1", "room@c/bob")
            .is_none());
        assert!(index.for_correction("room@c", "b2", "bob").is_some());
        assert!(index
            .for_correction("room2@c/bob", "b3", "room2@c/bob")
            .is_some());
    }

    #[test]
    fn leaving_a_conversation_forgets_all_of_it() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "s1", Some("b1")));
        index.record(entry("other", "bob", "s2", Some("b2")));
        index.forget_conversation("room");
        assert!(index.for_correction("room", "b1", "bob").is_none());
        assert!(index.for_correction("other", "b2", "bob").is_some());
    }

    #[test]
    fn recording_the_same_message_twice_keeps_one() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "s1", Some("o")));
        index.record(entry("room", "bob", "s1", Some("o")));
        assert_eq!(index.entries.len(), 1);
    }

    #[test]
    fn a_retracted_message_is_forgotten() {
        let mut index = MessageIndex::default();
        index.record(entry("room", "bob", "s1", Some("o")));
        index.forget("room", "s1");
        assert!(index.for_retraction("room", "s1", "bob").is_none());
    }

    #[test]
    fn a_retraction_is_recognised_by_its_namespace() {
        let mut message = Message::chat(None);
        message.payloads.push(
            format!("<retract xmlns='{NS_RETRACT}' id='abc'/>")
                .parse()
                .unwrap(),
        );
        assert_eq!(retraction(&message).as_deref(), Some("abc"));

        // The same element name in another namespace is not one.
        let mut other = Message::chat(None);
        other.payloads.push(
            "<retract xmlns='urn:example:other' id='abc'/>"
                .parse()
                .unwrap(),
        );
        assert!(retraction(&other).is_none());
    }

    #[test]
    fn a_retraction_with_no_id_names_nothing() {
        let mut message = Message::chat(None);
        message.payloads.push(
            format!("<retract xmlns='{NS_RETRACT}' id=''/>")
                .parse()
                .unwrap(),
        );
        assert!(retraction(&message).is_none());
    }

    #[test]
    fn an_id_from_the_network_is_bounded() {
        let mut message = Message::chat(None);
        message.payloads.push(
            format!("<retract xmlns='{NS_RETRACT}' id='{}'/>", "x".repeat(5000))
                .parse()
                .unwrap(),
        );
        assert_eq!(retraction(&message).unwrap().chars().count(), MAX_ID);
    }

    #[test]
    fn the_origin_id_is_preferred_to_the_id_attribute() {
        let message = with_origin_id(Message::chat(None), "mine");
        let mut message = message;
        assert_eq!(origin_id(&mut message).as_deref(), Some("mine"));

        let mut bare = Message::chat(None);
        bare.id = Some(Id("plain".to_owned()));
        assert_eq!(origin_id(&mut bare).as_deref(), Some("plain"));
    }

    #[test]
    fn an_outgoing_correction_names_the_original_and_carries_the_new_text() {
        let to: Jid = "room@conf.example.org".parse().unwrap();
        let mut m = correction(to, true, "new-id", "old-id", "fixed".to_owned());
        let replace = m.extract_valid_payload::<Replace>().unwrap();
        assert_eq!(replace.id.0, "old-id");
        assert_eq!(
            m.bodies.get(&Lang::new()).map(String::as_str),
            Some("fixed")
        );
        assert_eq!(
            m.type_,
            tokio_xmpp::parsers::message::MessageType::Groupchat
        );
    }

    #[test]
    fn an_outgoing_retraction_says_what_it_is_for_clients_that_do_not_know() {
        let to: Jid = "bob@example.org".parse().unwrap();
        let m = retract(to, false, "new-id", "old-id");
        assert_eq!(retraction(&m).as_deref(), Some("old-id"));
        assert!(m.payloads.iter().any(|p| p.is("fallback", NS_FALLBACK)));
        assert!(m.payloads.iter().any(|p| p.is("store", NS_HINTS)));
        assert!(m
            .bodies
            .get(&Lang::new())
            .is_some_and(|b| b.contains("retracted")));
    }
}
