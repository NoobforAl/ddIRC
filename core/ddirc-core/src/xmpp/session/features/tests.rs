use super::*;

use crate::api::types::Subscription as Sub;
use crate::xmpp::session::tests::{
    bound, feed, in_room, item, messages, muc_presence, sent_kinds, session, stanza, text, MUC,
};

// ---- helpers ------------------------------------------------------------

/// The id of the first stanza of this kind that was sent to `to`.
fn id_of(fx: &Effects, to: &str) -> String {
    fx.send
        .iter()
        .find_map(|s| match s {
            Stanza::Iq(
                Iq::Get {
                    id, to: Some(t), ..
                }
                | Iq::Set {
                    id, to: Some(t), ..
                },
            ) if t.to_string() == to => Some(id.clone()),
            _ => None,
        })
        .unwrap_or_else(|| panic!("no request was sent to {to}: {fx:?}"))
}

/// The id of the roster request: the one iq with no `to`.
fn roster_id(fx: &Effects) -> String {
    fx.send
        .iter()
        .find_map(|s| match s {
            Stanza::Iq(Iq::Get { id, payload, .. }) if payload.is("query", NS_ROSTER) => {
                Some(id.clone())
            }
            _ => None,
        })
        .expect("a roster request was sent")
}

fn contacts_of(fx: &Effects) -> Vec<&crate::api::types::ContactView> {
    fx.events
        .iter()
        .filter_map(|e| match e {
            IrcEvent::Contact(c) => Some(c.as_ref()),
            _ => None,
        })
        .collect()
}

/// Online, with a roster of `bob` (both ways) and `carol` (we see her).
fn with_contacts() -> Session {
    let mut s = session();
    let fx = s.on_online(&bound());
    let id = roster_id(&fx);
    feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' id='{id}'>\
             <query xmlns='jabber:iq:roster'>\
             <item jid='bob@example.net' name='Bob' subscription='both'/>\
             <item jid='carol@example.net' subscription='to'/>\
             </query></iq>"
        ),
    );
    s
}

/// Online, and the server has said it takes uploads, of at most `max` bytes.
fn with_upload(max: u64) -> Session {
    with_upload_in(max, true)
}

/// As [`with_upload`], and the room is entered only if `joined`.
fn with_upload_in(max: u64, joined: bool) -> Session {
    let mut s = in_room();
    let fx = s.on_online(&bound());
    let items = id_of(&fx, "example.org");
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='example.org' id='{items}'>\
             <query xmlns='http://jabber.org/protocol/disco#items'>\
             <item jid='upload.example.org'/></query></iq>"
        ),
    );
    let info = id_of(&fx, "upload.example.org");
    feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='upload.example.org' id='{info}'>\
             <query xmlns='http://jabber.org/protocol/disco#info'>\
             <identity category='store' type='file'/>\
             <feature var='urn:xmpp:http:upload:0'/>\
             <x xmlns='jabber:x:data' type='result'>\
             <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field>\
             <field var='max-file-size'><value>{max}</value></field></x></query></iq>"
        ),
    );
    // A fresh login forgets the rooms' state; this is the room again.
    if joined {
        feed(
            &mut s,
            &muc_presence("alice", None, &item("none", "participant"), &[110]),
        );
    }
    s
}

fn slot_reply(from: &str, id: &str, put: &str, get: &str) -> String {
    format!(
        "<iq xmlns='jabber:client' type='result' from='{from}' id='{id}'>\
         <slot xmlns='urn:xmpp:http:upload:0'>\
         <put url='{put}'><header name='Authorization'>Bearer t</header></put>\
         <get url='{get}'/></slot></iq>"
    )
}

fn errors(fx: &Effects) -> Vec<&str> {
    fx.events
        .iter()
        .filter_map(|e| match e {
            IrcEvent::Error { message, .. } => Some(message.as_str()),
            _ => None,
        })
        .collect()
}

// ---- the contact list -----------------------------------------------------

#[test]
fn the_roster_the_server_sends_becomes_contacts() {
    let mut s = session();
    let fx = s.on_online(&bound());
    let id = roster_id(&fx);
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' id='{id}'>\
             <query xmlns='jabber:iq:roster'>\
             <item jid='bob@example.net' name='Bob' subscription='both'/>\
             <item jid='carol@example.net' subscription='to' ask='subscribe'/>\
             </query></iq>"
        ),
    );
    let seen = contacts_of(&fx);
    assert_eq!(seen.len(), 2);
    let bob = seen.iter().find(|c| c.jid == "bob@example.net").unwrap();
    assert_eq!(bob.name.as_deref(), Some("Bob"));
    assert_eq!(bob.subscription, Sub::Both);
    let carol = seen.iter().find(|c| c.jid == "carol@example.net").unwrap();
    assert_eq!(carol.subscription, Sub::To);
    assert!(carol.asked);
}

#[test]
fn a_roster_from_someone_who_was_not_asked_is_ignored() {
    let mut s = session();
    let fx = s.on_online(&bound());
    let id = roster_id(&fx);
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='mallory@evil.example' id='{id}'>\
             <query xmlns='jabber:iq:roster'>\
             <item jid='friend@example.net' name='Your Bank' subscription='both'/></query></iq>"
        ),
    );
    assert!(fx.events.is_empty());
}

#[test]
fn a_push_from_our_server_is_applied_and_answered() {
    let mut s = with_contacts();
    let fx = feed(
        &mut s,
        "<iq xmlns='jabber:client' type='set' id='push1'>\
         <query xmlns='jabber:iq:roster'>\
         <item jid='dave@example.net' subscription='from'/></query></iq>",
    );
    assert_eq!(contacts_of(&fx)[0].jid, "dave@example.net");
    assert_eq!(sent_kinds(&fx), ["iq-result"], "a push has to be answered");
}

#[test]
fn a_push_from_anyone_else_is_refused_and_changes_nothing() {
    let mut s = with_contacts();
    for from in [
        "mallory@evil.example",
        "bob@example.net",
        "alice@example.org/other",
    ] {
        let fx = feed(
            &mut s,
            &format!(
                "<iq xmlns='jabber:client' type='set' from='{from}' id='push2'>\
                 <query xmlns='jabber:iq:roster'>\
                 <item jid='mallory@evil.example' name='Trusted' subscription='both'/>\
                 </query></iq>"
            ),
        );
        assert!(contacts_of(&fx).is_empty(), "{from} wrote to the list");
        assert_eq!(sent_kinds(&fx), ["iq-error"], "{from}");
    }
}

#[test]
fn a_push_removing_someone_removes_them() {
    let mut s = with_contacts();
    let fx = feed(
        &mut s,
        "<iq xmlns='jabber:client' type='set' id='p3'>\
         <query xmlns='jabber:iq:roster'>\
         <item jid='bob@example.net' subscription='remove'/></query></iq>",
    );
    assert!(matches!(
        fx.events.as_slice(),
        [IrcEvent::ContactRemoved { jid }] if jid == "bob@example.net"
    ));
}

#[test]
fn a_contact_coming_online_is_reported_and_a_stranger_is_not() {
    let mut s = with_contacts();
    let fx = feed(
        &mut s,
        "<presence xmlns='jabber:client' from='bob@example.net/phone'>\
         <show>away</show><status>at lunch</status></presence>",
    );
    let bob = contacts_of(&fx)[0];
    assert_eq!(bob.availability, crate::api::types::Availability::Away);
    assert_eq!(bob.status, "at lunch");

    let fx = feed(
        &mut s,
        "<presence xmlns='jabber:client' from='mallory@evil.example/x'><status>hi</status></presence>",
    );
    assert!(fx.events.is_empty());
}

#[test]
fn a_new_login_marks_everyone_offline_until_they_are_heard_from_again() {
    let mut s = with_contacts();
    feed(
        &mut s,
        "<presence xmlns='jabber:client' from='bob@example.net/phone'/>",
    );
    let fx = s.on_online(&bound());
    let bob = contacts_of(&fx)[0];
    assert_eq!(bob.availability, crate::api::types::Availability::Offline);
}

#[test]
fn someone_asking_to_see_us_is_reported_once_and_never_answered_for_us() {
    let mut s = session();
    s.on_online(&bound());
    let ask = "<presence xmlns='jabber:client' type='subscribe' from='dave@example.net'/>";
    let fx = feed(&mut s, ask);
    assert!(matches!(
        fx.events.as_slice(),
        [IrcEvent::SubscriptionRequest { jid }] if jid == "dave@example.net"
    ));
    assert!(fx.send.is_empty());
    // Asking again is not a second request.
    assert!(feed(&mut s, ask).events.is_empty());
}

#[test]
fn accepting_a_request_lets_them_see_us() {
    let mut s = session();
    s.on_online(&bound());
    feed(
        &mut s,
        "<presence xmlns='jabber:client' type='subscribe' from='dave@example.net'/>",
    );
    let fx = s.on_command(ClientCommand::AnswerSubscription {
        jid: "dave@example.net".to_owned(),
        accept: true,
    });
    let [Stanza::Presence(p)] = fx.send.as_slice() else {
        panic!("one presence: {fx:?}");
    };
    assert_eq!(p.type_, PresenceType::Subscribed);
    assert_eq!(p.to.as_ref().unwrap().to_string(), "dave@example.net");
}

#[test]
fn declining_a_request_says_no() {
    let mut s = session();
    s.on_online(&bound());
    feed(
        &mut s,
        "<presence xmlns='jabber:client' type='subscribe' from='dave@example.net'/>",
    );
    let fx = s.on_command(ClientCommand::AnswerSubscription {
        jid: "dave@example.net".to_owned(),
        accept: false,
    });
    let [Stanza::Presence(p)] = fx.send.as_slice() else {
        panic!("one presence: {fx:?}");
    };
    assert_eq!(p.type_, PresenceType::Unsubscribed);
}

#[test]
fn nobody_is_let_in_who_did_not_ask() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::AnswerSubscription {
        jid: "dave@example.net".to_owned(),
        accept: true,
    });
    assert!(fx.send.is_empty(), "no unasked grant of presence");
    assert_eq!(errors(&fx).len(), 1);
}

#[test]
fn a_request_is_answered_once() {
    let mut s = session();
    s.on_online(&bound());
    feed(
        &mut s,
        "<presence xmlns='jabber:client' type='subscribe' from='dave@example.net'/>",
    );
    let answer = ClientCommand::AnswerSubscription {
        jid: "dave@example.net".to_owned(),
        accept: true,
    };
    assert_eq!(s.on_command(answer.clone()).send.len(), 1);
    assert!(s.on_command(answer).send.is_empty());
}

#[test]
fn adding_a_contact_puts_them_on_the_list_and_asks_to_see_them() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::AddContact {
        jid: "erin@example.net/laptop".to_owned(),
        name: Some("Erin".to_owned()),
    });
    assert_eq!(sent_kinds(&fx), ["iq-set", "presence"]);
    let Stanza::Iq(Iq::Set { payload, .. }) = &fx.send[0] else {
        panic!("a roster set");
    };
    let roster = Roster::try_from(payload.clone()).unwrap();
    assert_eq!(roster.items[0].jid.to_string(), "erin@example.net");
    assert_eq!(roster.items[0].name.as_deref(), Some("Erin"));
    let Stanza::Presence(p) = &fx.send[1] else {
        panic!("a subscription");
    };
    assert_eq!(p.type_, PresenceType::Subscribe);
    assert_eq!(p.to.as_ref().unwrap().to_string(), "erin@example.net");
}

#[test]
fn some_things_are_not_contacts() {
    let mut s = in_room();
    for jid in [
        "alice@example.org",
        MUC,
        "example.net",
        "not an address",
        "",
    ] {
        let fx = s.on_command(ClientCommand::AddContact {
            jid: jid.to_owned(),
            name: None,
        });
        assert!(fx.send.is_empty(), "{jid:?} was added");
        assert_eq!(errors(&fx).len(), 1, "{jid:?}");
    }
}

#[test]
fn removing_a_contact_asks_the_server_to_remove_them() {
    let mut s = with_contacts();
    let fx = s.on_command(ClientCommand::RemoveContact {
        jid: "bob@example.net".to_owned(),
    });
    let Stanza::Iq(Iq::Set { payload, .. }) = &fx.send[0] else {
        panic!("a roster set");
    };
    let roster = Roster::try_from(payload.clone()).unwrap();
    assert_eq!(roster.items[0].subscription, RosterSubscription::Remove);
}

#[test]
fn a_refused_change_to_the_list_is_said() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::AddContact {
        jid: "erin@example.net".to_owned(),
        name: None,
    });
    let Stanza::Iq(Iq::Set { id, .. }) = &fx.send[0] else {
        panic!();
    };
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='error' id='{id}'>\
             <error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
             </error></iq>"
        ),
    );
    assert_eq!(errors(&fx).len(), 1);
}

// ---- how we are -------------------------------------------------------------

#[test]
fn saying_we_are_away_is_told_to_everyone_and_to_each_room() {
    let mut s = in_room();
    let fx = s.on_command(ClientCommand::SetAvailability {
        availability: crate::api::types::Availability::Away,
        status: Some("back at 3".to_owned()),
    });
    assert_eq!(sent_kinds(&fx), ["presence", "presence"]);
    let Stanza::Presence(everyone) = &fx.send[0] else {
        panic!();
    };
    assert!(everyone.to.is_none());
    assert_eq!(everyone.show, Some(Show::Away));
    assert_eq!(everyone.statuses.values().next().unwrap(), "back at 3");
    let Stanza::Presence(room) = &fx.send[1] else {
        panic!();
    };
    assert_eq!(
        room.to.as_ref().unwrap().to_string(),
        format!("{MUC}/alice")
    );
    assert_eq!(room.show, Some(Show::Away));
}

#[test]
fn a_status_is_cleaned_before_it_is_sent() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::SetAvailability {
        availability: crate::api::types::Availability::Dnd,
        status: Some(format!("a\u{0007}b\u{202e}{}", "x".repeat(500))),
    });
    let Stanza::Presence(p) = &fx.send[0] else {
        panic!();
    };
    let status = p.statuses.values().next().unwrap();
    assert!(!status.contains('\u{0007}') && !status.contains('\u{202e}'));
    assert!(status.chars().count() <= STATUS_CHARS);
}

#[test]
fn how_we_are_is_said_again_on_the_next_login() {
    let mut s = session();
    s.on_online(&bound());
    s.on_command(ClientCommand::SetAvailability {
        availability: crate::api::types::Availability::ExtendedAway,
        status: None,
    });
    let fx = s.on_online(&bound());
    let announce = fx
        .send
        .iter()
        .find_map(|s| match s {
            Stanza::Presence(p) if p.to.is_none() => Some(p),
            _ => None,
        })
        .unwrap();
    assert_eq!(announce.show, Some(Show::Xa));
}

#[test]
fn available_with_no_status_is_plain_presence_again() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::SetAvailability {
        availability: crate::api::types::Availability::Available,
        status: None,
    });
    let Stanza::Presence(p) = &fx.send[0] else {
        panic!();
    };
    assert!(p.show.is_none() && p.statuses.is_empty() && p.payloads.is_empty());
}

// ---- correcting and taking back (a one-to-one chat) -------------------------

const CHAT_IN: &str =
    "<message xmlns='jabber:client' type='chat' from='carol@example.net/phone' id='c1'>\
                       <body>teh plan</body></message>";

#[test]
fn our_own_message_can_be_corrected() {
    let mut s = session();
    s.on_online(&bound());
    let sent = s.on_command(ClientCommand::SendMessage {
        target: "carol@example.net".to_owned(),
        text: "teh plan".to_owned(),
    });
    let mine = messages(&sent)[0]
        .msgid
        .clone()
        .expect("our echo has an id");
    let Stanza::Message(original) = &sent.send[0] else {
        panic!();
    };
    let original_id = original.id.clone().unwrap().0;
    assert_eq!(original_id, mine, "the UI knows it by the id it carries");

    let fx = s.on_command(ClientCommand::EditMessage {
        target: "carol@example.net".to_owned(),
        msgid: mine.clone(),
        text: "the plan".to_owned(),
    });
    let Stanza::Message(correction) = &fx.send[0] else {
        panic!("a message: {fx:?}");
    };
    let mut correction = correction.clone();
    let replace = correction.extract_valid_payload::<Replace>().unwrap();
    assert_eq!(replace.id.0, original_id);
    assert_eq!(
        correction.get_best_body_cloned(vec![""]).unwrap().1,
        "the plan"
    );
    // Not echoed twice: shown once, as an edit of what is already there.
    assert!(messages(&fx).is_empty());
    let [IrcEvent::MessageEdited { msgid, message, .. }] = fx.events.as_slice() else {
        panic!("{:?}", fx.events);
    };
    assert_eq!(msgid, &mine);
    assert_eq!(text(message), "the plan");
}

#[test]
fn what_we_did_not_write_cannot_be_edited_or_deleted() {
    let mut s = session();
    s.on_online(&bound());
    feed(&mut s, CHAT_IN);
    let edit = s.on_command(ClientCommand::EditMessage {
        target: "carol@example.net".to_owned(),
        msgid: "c1".to_owned(),
        text: "words in their mouth".to_owned(),
    });
    assert!(edit.send.is_empty());
    assert_eq!(errors(&edit).len(), 1);
    let retract = s.on_command(ClientCommand::RetractMessage {
        target: "carol@example.net".to_owned(),
        msgid: "c1".to_owned(),
    });
    assert!(retract.send.is_empty());
    assert_eq!(errors(&retract).len(), 1);
}

#[test]
fn an_edit_to_nothing_or_to_too_much_is_refused() {
    let mut s = session();
    s.on_online(&bound());
    let sent = s.on_command(ClientCommand::SendMessage {
        target: "carol@example.net".to_owned(),
        text: "hello".to_owned(),
    });
    let id = messages(&sent)[0].msgid.clone().unwrap();
    for text in ["", "   ", &"x".repeat(MAX_BODY_CHARS + 1)] {
        let fx = s.on_command(ClientCommand::EditMessage {
            target: "carol@example.net".to_owned(),
            msgid: id.clone(),
            text: text.to_owned(),
        });
        assert!(fx.send.is_empty(), "{:?}", text.len());
        assert_eq!(errors(&fx).len(), 1);
    }
}

#[test]
fn taking_a_message_back_says_so_and_removes_it_here() {
    let mut s = session();
    s.on_online(&bound());
    let sent = s.on_command(ClientCommand::SendMessage {
        target: "carol@example.net".to_owned(),
        text: "wrong chat".to_owned(),
    });
    let id = messages(&sent)[0].msgid.clone().unwrap();
    let fx = s.on_command(ClientCommand::RetractMessage {
        target: "carol@example.net".to_owned(),
        msgid: id.clone(),
    });
    let Stanza::Message(m) = &fx.send[0] else {
        panic!();
    };
    assert_eq!(edits::retraction(m).as_deref(), Some(id.as_str()));
    assert!(matches!(
        fx.events.as_slice(),
        [IrcEvent::MessageRetracted { msgid, .. }] if msgid == &id
    ));
    // And it cannot be taken back twice.
    let again = s.on_command(ClientCommand::RetractMessage {
        target: "carol@example.net".to_owned(),
        msgid: id,
    });
    assert!(again.send.is_empty());
}

#[test]
fn a_correction_from_the_author_replaces_the_message() {
    let mut s = session();
    s.on_online(&bound());
    feed(&mut s, CHAT_IN);
    let fx = feed(
        &mut s,
        "<message xmlns='jabber:client' type='chat' from='carol@example.net/laptop' id='c2'>\
         <body>the plan</body><replace xmlns='urn:xmpp:message-correct:0' id='c1'/></message>",
    );
    assert!(messages(&fx).is_empty(), "not a new line");
    let [IrcEvent::MessageEdited {
        msgid,
        sender,
        message,
        ..
    }] = fx.events.as_slice()
    else {
        panic!("{:?}", fx.events);
    };
    assert_eq!(msgid, "c1");
    assert_eq!(sender, "carol@example.net");
    assert_eq!(text(message), "the plan");
}

#[test]
fn a_correction_from_someone_else_is_only_a_message() {
    let mut s = session();
    s.on_online(&bound());
    feed(&mut s, CHAT_IN);
    // Mallory names Carol's message. It is a message from Mallory, and says so.
    let fx = feed(
        &mut s,
        "<message xmlns='jabber:client' type='chat' from='mallory@evil.example/x' id='m1'>\
         <body>I love you</body><replace xmlns='urn:xmpp:message-correct:0' id='c1'/></message>",
    );
    assert!(!fx
        .events
        .iter()
        .any(|e| matches!(e, IrcEvent::MessageEdited { .. })));
    let shown = messages(&fx);
    assert_eq!(shown.len(), 1);
    assert_eq!(shown[0].sender, "mallory@evil.example");
    assert!(text(shown[0]).starts_with("(edited)"));
}

#[test]
fn a_correction_of_something_we_never_showed_is_a_message_that_says_it_is_one() {
    let mut s = session();
    s.on_online(&bound());
    let fx = feed(
        &mut s,
        "<message xmlns='jabber:client' type='chat' from='carol@example.net/laptop' id='c9'>\
         <body>the plan</body><replace xmlns='urn:xmpp:message-correct:0' id='nope'/></message>",
    );
    assert!(text(messages(&fx)[0]).starts_with("(edited)"));
}

#[test]
fn a_retraction_from_the_author_removes_the_message_and_is_not_itself_shown() {
    let mut s = session();
    s.on_online(&bound());
    feed(&mut s, CHAT_IN);
    let fx = feed(
        &mut s,
        "<message xmlns='jabber:client' type='chat' from='carol@example.net/phone' id='c3'>\
         <retract xmlns='urn:xmpp:message-retract:1' id='c1'/>\
         <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:message-retract:1'/>\
         <body>/me retracted a previous message, but your client does not support that.</body>\
         </message>",
    );
    assert!(messages(&fx).is_empty(), "the fallback is not a message");
    assert!(matches!(
        fx.events.as_slice(),
        [IrcEvent::MessageRetracted { msgid, .. }] if msgid == "c1"
    ));
}

#[test]
fn a_retraction_from_someone_else_does_nothing_and_shows_nothing() {
    let mut s = session();
    s.on_online(&bound());
    feed(&mut s, CHAT_IN);
    let fx = feed(
        &mut s,
        "<message xmlns='jabber:client' type='chat' from='mallory@evil.example/x' id='m2'>\
         <retract xmlns='urn:xmpp:message-retract:1' id='c1'/><body>retracted</body></message>",
    );
    assert!(fx.events.is_empty());
}

// ---- correcting and taking back (a room) --------------------------------------

fn room_says(nick: &str, id: &str, stanza_id: &str, extra: &str, body: &str) -> String {
    format!(
        "<message xmlns='jabber:client' type='groupchat' from='{MUC}/{nick}' id='{id}'>\
         <body>{body}</body>{extra}\
         <stanza-id xmlns='urn:xmpp:sid:0' by='{MUC}' id='{stanza_id}'/></message>"
    )
}

#[test]
fn in_a_room_a_correction_finds_the_message_by_the_senders_id_and_names_it_by_the_rooms() {
    let mut s = in_room();
    feed(&mut s, &room_says("bob", "bobs-1", "S1", "", "teh plan"));
    let fx = feed(
        &mut s,
        &room_says(
            "bob",
            "bobs-2",
            "S2",
            "<replace xmlns='urn:xmpp:message-correct:0' id='bobs-1'/>",
            "the plan",
        ),
    );
    assert!(messages(&fx).is_empty());
    let [IrcEvent::MessageEdited { msgid, message, .. }] = fx.events.as_slice() else {
        panic!("{:?}", fx.events);
    };
    assert_eq!(msgid, "S1", "the id the UI was given");
    assert_eq!(text(message), "the plan");
}

#[test]
fn in_a_room_another_occupant_cannot_correct_someone_elses_message() {
    let mut s = in_room();
    feed(&mut s, &room_says("bob", "bobs-1", "S1", "", "I agree"));
    feed(
        &mut s,
        &muc_presence("mallory", None, &item("none", "participant"), &[]),
    );
    let fx = feed(
        &mut s,
        &room_says(
            "mallory",
            "m-1",
            "S2",
            "<replace xmlns='urn:xmpp:message-correct:0' id='bobs-1'/>",
            "I disagree",
        ),
    );
    assert!(!fx
        .events
        .iter()
        .any(|e| matches!(e, IrcEvent::MessageEdited { .. })));
    assert_eq!(messages(&fx)[0].sender, "mallory");
}

#[test]
fn in_a_room_a_retraction_names_the_rooms_id_and_only_the_author_may() {
    let mut s = in_room();
    feed(&mut s, &room_says("bob", "bobs-1", "S1", "", "oops"));
    feed(
        &mut s,
        &muc_presence("mallory", None, &item("none", "participant"), &[]),
    );
    let forged = feed(
        &mut s,
        &room_says(
            "mallory",
            "m-1",
            "S2",
            "<retract xmlns='urn:xmpp:message-retract:1' id='S1'/>",
            "retracted",
        ),
    );
    assert!(forged.events.is_empty());

    let real = feed(
        &mut s,
        &room_says(
            "bob",
            "bobs-2",
            "S3",
            "<retract xmlns='urn:xmpp:message-retract:1' id='S1'/>",
            "retracted",
        ),
    );
    assert!(messages(&real).is_empty());
    assert!(matches!(
        real.events.as_slice(),
        [IrcEvent::MessageRetracted { msgid, sender, .. }] if msgid == "S1" && sender == "bob"
    ));
}

#[test]
fn in_a_room_our_own_edit_is_shown_when_the_room_reflects_it() {
    let mut s = in_room();
    // Our message, as the room reflects it.
    let sent = s.on_command(ClientCommand::SendMessage {
        target: MUC.to_owned(),
        text: "teh plan".to_owned(),
    });
    let Stanza::Message(m) = &sent.send[0] else {
        panic!();
    };
    let our_id = m.id.clone().unwrap().0;
    feed(&mut s, &room_says("alice", &our_id, "S9", "", "teh plan"));

    let fx = s.on_command(ClientCommand::EditMessage {
        target: MUC.to_owned(),
        msgid: "S9".to_owned(),
        text: "the plan".to_owned(),
    });
    let Stanza::Message(correction) = &fx.send[0] else {
        panic!();
    };
    let mut correction = correction.clone();
    assert_eq!(
        correction.extract_valid_payload::<Replace>().unwrap().id.0,
        our_id
    );
    assert_eq!(correction.type_, MessageType::Groupchat);
    assert!(fx.events.is_empty(), "the room will reflect it");

    let reflected = feed(
        &mut s,
        &room_says(
            "alice",
            "x",
            "S10",
            &format!("<replace xmlns='urn:xmpp:message-correct:0' id='{our_id}'/>"),
            "the plan",
        ),
    );
    let [IrcEvent::MessageEdited { msgid, .. }] = reflected.events.as_slice() else {
        panic!("{:?}", reflected.events);
    };
    assert_eq!(msgid, "S9");
}

#[test]
fn in_a_room_taking_a_message_back_names_the_rooms_id() {
    let mut s = in_room();
    let sent = s.on_command(ClientCommand::SendMessage {
        target: MUC.to_owned(),
        text: "oops".to_owned(),
    });
    let Stanza::Message(m) = &sent.send[0] else {
        panic!();
    };
    feed(
        &mut s,
        &room_says("alice", &m.id.clone().unwrap().0, "S9", "", "oops"),
    );
    let fx = s.on_command(ClientCommand::RetractMessage {
        target: MUC.to_owned(),
        msgid: "S9".to_owned(),
    });
    let Stanza::Message(retraction) = &fx.send[0] else {
        panic!();
    };
    assert_eq!(edits::retraction(retraction).as_deref(), Some("S9"));
    assert_eq!(retraction.type_, MessageType::Groupchat);
    assert!(fx.events.is_empty(), "the room will reflect it");
}

#[test]
fn a_retraction_advances_the_place_to_catch_up_from() {
    let mut s = in_room();
    feed(&mut s, &room_says("bob", "b1", "S1", "", "hi"));
    feed(
        &mut s,
        &room_says(
            "bob",
            "b2",
            "S2",
            "<retract xmlns='urn:xmpp:message-retract:1' id='S1'/>",
            "x",
        ),
    );
    assert_eq!(
        s.rooms
            .get(&MUC.parse::<BareJid>().unwrap())
            .unwrap()
            .last_id
            .as_deref(),
        Some("S2")
    );
}

// ---- finding where files go ---------------------------------------------------------

#[test]
fn the_server_is_asked_what_it_has_and_its_components_what_they_are() {
    let mut s = session();
    let fx = s.on_online(&bound());
    let items = id_of(&fx, "example.org");
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='example.org' id='{items}'>\
             <query xmlns='http://jabber.org/protocol/disco#items'>\
             <item jid='upload.example.org'/><item jid='conference.example.org'/>\
             <item jid='pubsub.example.org' node='some-node'/></query></iq>"
        ),
    );
    // Two components are asked; a node of one is not a component.
    assert_eq!(sent_kinds(&fx), ["iq-get", "iq-get"]);
}

#[test]
fn an_upload_service_is_found_and_the_ui_is_told() {
    let s = with_upload(5_000_000);
    assert_eq!(s.upload_limit(), Some(5_000_000));
}

#[test]
fn the_ui_is_told_when_uploading_becomes_possible() {
    let mut s = session();
    let fx = s.on_online(&bound());
    let items = id_of(&fx, "example.org");
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='example.org' id='{items}'>\
             <query xmlns='http://jabber.org/protocol/disco#items'>\
             <item jid='upload.example.org'/></query></iq>"
        ),
    );
    let info = id_of(&fx, "upload.example.org");
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='upload.example.org' id='{info}'>\
             <query xmlns='http://jabber.org/protocol/disco#info'>\
             <feature var='urn:xmpp:http:upload:0'/></query></iq>"
        ),
    );
    assert!(matches!(
        fx.events.as_slice(),
        [IrcEvent::UploadAvailable { max_bytes: Some(m) }] if *m == upload::HARD_LIMIT
    ));
}

#[test]
fn an_answer_about_a_component_from_somewhere_else_is_ignored() {
    let mut s = session();
    let fx = s.on_online(&bound());
    let items = id_of(&fx, "example.org");
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='example.org' id='{items}'>\
             <query xmlns='http://jabber.org/protocol/disco#items'>\
             <item jid='upload.example.org'/></query></iq>"
        ),
    );
    let info = id_of(&fx, "upload.example.org");
    feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='evil.example.net' id='{info}'>\
             <query xmlns='http://jabber.org/protocol/disco#info'>\
             <feature var='urn:xmpp:http:upload:0'/></query></iq>"
        ),
    );
    assert_eq!(s.upload_limit(), None);
}

#[test]
fn a_list_of_components_from_somewhere_else_is_ignored() {
    let mut s = session();
    let fx = s.on_online(&bound());
    let items = id_of(&fx, "example.org");
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' from='mallory@example.org/x' id='{items}'>\
             <query xmlns='http://jabber.org/protocol/disco#items'>\
             <item jid='upload.evil.example'/></query></iq>"
        ),
    );
    assert!(fx.send.is_empty());
}

// ---- sharing a file ---------------------------------------------------------------

#[test]
fn nothing_is_sent_before_the_server_has_said_where() {
    let mut s = session();
    s.on_online(&bound());
    let (ticket, fx) = s.begin_upload("carol@example.net", "a.png", 100);
    assert!(ticket.is_none());
    assert!(fx.send.is_empty());
    assert_eq!(errors(&fx).len(), 1);
}

#[test]
fn a_slot_is_asked_for_with_the_name_and_size() {
    let mut s = with_upload(1_000_000);
    let (ticket, fx) = s.begin_upload("carol@example.net", "/home/me/holiday.JPG", 12345);
    let ticket = ticket.expect("a ticket");
    assert!(matches!(
        &fx.events[0],
        IrcEvent::FileTransferStarted { id, filename, incoming: false, total: Some(12345), .. }
            if *id == ticket && filename == "holiday.JPG"
    ));
    let Stanza::Iq(Iq::Get { payload, to, .. }) = &fx.send[0] else {
        panic!("{fx:?}");
    };
    assert_eq!(to.as_ref().unwrap().to_string(), "upload.example.org");
    let request = SlotRequest::try_from(payload.clone()).unwrap();
    assert_eq!(request.filename, "holiday.JPG", "a name, not a path");
    assert_eq!(request.size, 12345);
    assert_eq!(request.content_type.as_deref(), Some("image/jpeg"));
}

#[test]
fn a_file_that_is_empty_or_too_large_is_refused_before_asking() {
    let mut s = with_upload(1000);
    for size in [0, 1001] {
        let (ticket, fx) = s.begin_upload("carol@example.net", "a.bin", size);
        assert!(ticket.is_none(), "{size}");
        assert!(fx.send.is_empty());
        assert_eq!(errors(&fx).len(), 1);
    }
}

#[test]
fn a_room_we_are_not_in_cannot_be_sent_a_file() {
    let mut s = with_upload_in(1000, false);
    let (ticket, fx) = s.begin_upload(MUC, "a.bin", 10);
    assert!(ticket.is_none());
    assert!(fx.send.is_empty());
    // And once it is entered, the same room takes one.
    feed(
        &mut s,
        &muc_presence("alice", None, &item("none", "participant"), &[110]),
    );
    assert!(s.begin_upload(MUC, "a.bin", 10).0.is_some());
}

#[test]
fn only_so_many_files_are_in_flight_at_once() {
    let mut s = with_upload(1_000_000);
    for _ in 0..MAX_UPLOADS {
        assert!(s.begin_upload("carol@example.net", "a.bin", 10).0.is_some());
    }
    assert!(s.begin_upload("carol@example.net", "a.bin", 10).0.is_none());
}

#[test]
fn a_granted_slot_becomes_a_job_for_the_connection() {
    let mut s = with_upload(1_000_000);
    let (ticket, fx) = s.begin_upload("carol@example.net", "a.png", 10);
    let id = id_of(&fx, "upload.example.org");
    let fx = feed(
        &mut s,
        &slot_reply(
            "upload.example.org",
            &id,
            "https://upload.example.org/put/x/a.png",
            "https://upload.example.org/get/x/a.png",
        ),
    );
    let [job] = fx.uploads.as_slice() else {
        panic!("{fx:?}");
    };
    assert_eq!(Some(job.ticket), ticket);
    assert_eq!(job.slot.get, "https://upload.example.org/get/x/a.png");
    assert_eq!(job.content_type, "image/png");
    assert_eq!(
        job.slot.headers,
        vec![("Authorization".to_owned(), "Bearer t".to_owned())]
    );
}

#[test]
fn a_slot_that_is_not_safe_is_refused_and_nothing_is_uploaded() {
    for put in [
        "http://upload.example.org/put",
        "https://192.168.0.1/put",
        "https://user:pw@upload.example.org/put",
        "https://printer/put",
    ] {
        let mut s = with_upload(1_000_000);
        let (_, fx) = s.begin_upload("carol@example.net", "a.png", 10);
        let id = id_of(&fx, "upload.example.org");
        let fx = feed(
            &mut s,
            &slot_reply(
                "upload.example.org",
                &id,
                put,
                "https://upload.example.org/get",
            ),
        );
        assert!(fx.uploads.is_empty(), "{put}");
        assert!(
            matches!(
                fx.events.as_slice(),
                [IrcEvent::FileTransferEnded { error: Some(_), .. }]
            ),
            "{put}: {:?}",
            fx.events
        );
    }
}

#[test]
fn a_slot_from_anywhere_but_the_upload_service_is_ignored() {
    let mut s = with_upload(1_000_000);
    let (_, fx) = s.begin_upload("carol@example.net", "a.png", 10);
    let id = id_of(&fx, "upload.example.org");
    let fx = feed(
        &mut s,
        &slot_reply(
            "evil.example.net",
            &id,
            "https://evil.example.net/put",
            "https://evil.example.net/get",
        ),
    );
    assert!(fx.uploads.is_empty());
    assert!(fx.events.is_empty());
}

#[test]
fn a_refused_slot_ends_the_transfer_with_the_reason() {
    let mut s = with_upload(1_000_000);
    let (_, fx) = s.begin_upload("carol@example.net", "a.png", 10);
    let id = id_of(&fx, "upload.example.org");
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='error' from='upload.example.org' id='{id}'>\
             <error type='modify'><not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
             </error></iq>"
        ),
    );
    assert!(matches!(
        fx.events.as_slice(),
        [IrcEvent::FileTransferEnded { error: Some(_), .. }]
    ));
}

#[test]
fn a_finished_upload_sends_the_link_naming_it_as_the_subject() {
    let mut s = with_upload(1_000_000);
    let (ticket, fx) = s.begin_upload("carol@example.net", "a.png", 10);
    let id = id_of(&fx, "upload.example.org");
    feed(
        &mut s,
        &slot_reply(
            "upload.example.org",
            &id,
            "https://upload.example.org/put/x/a.png",
            "https://upload.example.org/get/x/a.png",
        ),
    );
    let fx = s.upload_finished(ticket.unwrap(), Ok(()));
    assert!(matches!(
        &fx.events[0],
        IrcEvent::FileTransferEnded { error: None, .. }
    ));
    let Stanza::Message(m) = &fx.send[0] else {
        panic!();
    };
    let mut m = m.clone();
    assert_eq!(
        m.get_best_body_cloned(vec![""]).unwrap().1,
        "https://upload.example.org/get/x/a.png"
    );
    let oob = m
        .extract_valid_payload::<Oob>()
        .expect("the link is the subject");
    assert_eq!(oob.url, "https://upload.example.org/get/x/a.png");
    // And it is shown to us, because a person does not reflect it.
    assert_eq!(messages(&fx).len(), 1);
}

#[test]
fn a_failed_upload_ends_the_transfer_and_sends_nothing() {
    let mut s = with_upload(1_000_000);
    let (ticket, fx) = s.begin_upload("carol@example.net", "a.png", 10);
    let id = id_of(&fx, "upload.example.org");
    feed(
        &mut s,
        &slot_reply(
            "upload.example.org",
            &id,
            "https://upload.example.org/put",
            "https://upload.example.org/get",
        ),
    );
    let fx = s.upload_finished(ticket.unwrap(), Err("the server refused it".to_owned()));
    assert!(fx.send.is_empty());
    assert!(matches!(
        fx.events.as_slice(),
        [IrcEvent::FileTransferEnded { error: Some(e), .. }] if e == "the server refused it"
    ));
    // And a second report about the same upload is nothing.
    assert!(s.upload_finished(ticket.unwrap(), Ok(())).events.is_empty());
}

#[test]
fn a_connection_lost_while_waiting_for_a_slot_ends_that_upload() {
    let mut s = with_upload(1_000_000);
    s.begin_upload("carol@example.net", "a.png", 10);
    let fx = s.on_online(&bound());
    assert!(fx
        .events
        .iter()
        .any(|e| matches!(e, IrcEvent::FileTransferEnded { error: Some(_), .. })));
}

#[test]
fn a_connection_lost_during_the_upload_does_not_end_it() {
    let mut s = with_upload(1_000_000);
    let (_, fx) = s.begin_upload("carol@example.net", "a.png", 10);
    let id = id_of(&fx, "upload.example.org");
    feed(
        &mut s,
        &slot_reply(
            "upload.example.org",
            &id,
            "https://upload.example.org/put",
            "https://upload.example.org/get",
        ),
    );
    // The bytes are on their way over a connection of their own.
    let fx = s.on_online(&bound());
    assert!(!fx
        .events
        .iter()
        .any(|e| matches!(e, IrcEvent::FileTransferEnded { .. })));
}

#[test]
fn the_name_sent_is_only_a_name() {
    let mut s = with_upload(1_000_000);
    for given in [
        "C:\\Users\\me\\secret plans.pdf",
        "/etc/passwd",
        "../../x.png",
        "bell\u{0007}.png",
    ] {
        let (_, fx) = s.begin_upload("carol@example.net", given, 10);
        let Stanza::Iq(Iq::Get { payload, .. }) = &fx.send[0] else {
            panic!();
        };
        let name = SlotRequest::try_from(payload.clone()).unwrap().filename;
        assert!(!name.contains(['/', '\\']), "{given:?} -> {name:?}");
        assert!(!name.chars().any(char::is_control), "{given:?} -> {name:?}");
        // Free the slot for the next try.
        let ticket = match &fx.events[0] {
            IrcEvent::FileTransferStarted { id, .. } => *id,
            other => panic!("{other:?}"),
        };
        s.upload_finished(ticket, Err("done".to_owned()));
    }
}

// ---- catching up on one-to-one chats ----------------------------------------------

/// The id of the one archive query in `fx`, and the query itself.
fn archive_query(fx: &Effects) -> (String, mam::Query) {
    fx.send
        .iter()
        .find_map(|s| match s {
            Stanza::Iq(Iq::Set {
                id, payload, to, ..
            }) if payload.is("query", "urn:xmpp:mam:2") && to.is_none() => {
                Some((id.clone(), mam::Query::try_from(payload.clone()).unwrap()))
            }
            _ => None,
        })
        .expect("a query to our own archive")
}

fn archived_chat(
    qid: &str,
    id: &str,
    stamp: &str,
    from: &str,
    to: &str,
    mid: &str,
    body: &str,
) -> String {
    format!(
        "<message xmlns='jabber:client' from='alice@example.org' to='alice@example.org/ddirc'>\
         <result xmlns='urn:xmpp:mam:2' queryid='{qid}' id='{id}'>\
         <forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='{stamp}'/>\
         <message xmlns='jabber:client' from='{from}' to='{to}' type='chat' id='{mid}'>\
         <body>{body}</body></message></forwarded></result></message>"
    )
}

fn live_chat_with_archive_id(archive_id: &str, mid: &str, body: &str) -> String {
    format!(
        "<message xmlns='jabber:client' type='chat' from='carol@example.net/phone' id='{mid}'>\
         <body>{body}</body>\
         <stanza-id xmlns='urn:xmpp:sid:0' by='alice@example.org' id='{archive_id}'/></message>"
    )
}

#[test]
fn a_time_is_written_the_way_a_server_reads_it() {
    assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
    assert_eq!(iso8601(1_700_000_000_000), "2023-11-14T22:13:20Z");
    // A leap day, and the day after it.
    assert_eq!(iso8601(1_709_164_800_000), "2024-02-29T00:00:00Z");
    assert_eq!(iso8601(1_709_251_200_000), "2024-03-01T00:00:00Z");
    // The turn of a century that was a leap year, and of one that was not.
    assert_eq!(iso8601(951_782_400_000), "2000-02-29T00:00:00Z");
    assert_eq!(iso8601(4_107_542_400_000), "2100-03-01T00:00:00Z");
    // Before the epoch, and milliseconds do not round up.
    assert_eq!(iso8601(-1000), "1969-12-31T23:59:59Z");
    assert_eq!(iso8601(999), "1970-01-01T00:00:00Z");
}

#[test]
fn what_was_said_while_the_connection_was_down_is_asked_for_after_the_last_thing_seen() {
    let mut s = session();
    s.on_online(&bound());
    feed(&mut s, &live_chat_with_archive_id("A1", "c1", "first"));
    feed(&mut s, &live_chat_with_archive_id("A2", "c2", "second"));

    let fx = s.on_online(&bound());
    let (_, query) = archive_query(&fx);
    assert_eq!(query.set.unwrap().after.as_deref(), Some("A2"));
    assert!(query.form.is_none(), "an id, not a time");
}

#[test]
fn a_first_login_has_nowhere_to_catch_up_from_and_asks_nothing() {
    let mut s = session();
    let fx = s.on_online(&bound());
    assert!(!fx.send.iter().any(|s| matches!(s,
        Stanza::Iq(Iq::Set { payload, to: None, .. }) if payload.is("query", "urn:xmpp:mam:2"))));
}

#[test]
fn an_id_an_archive_other_than_ours_gave_is_not_a_place_to_catch_up_from() {
    let mut s = session();
    s.on_online(&bound());
    feed(
        &mut s,
        "<message xmlns='jabber:client' type='chat' from='mallory@evil.example/x' id='m1'>\
         <body>hi</body><stanza-id xmlns='urn:xmpp:sid:0' by='mallory@evil.example' id='FORGED'/>\
         </message>",
    );
    let fx = s.on_online(&bound());
    assert!(!fx.send.iter().any(|s| matches!(s,
        Stanza::Iq(Iq::Set { payload, to: None, .. }) if payload.is("query", "urn:xmpp:mam:2"))));
}

#[test]
fn the_app_can_say_where_to_start_when_the_connection_has_no_idea() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::CatchUpChats {
        since_ms: 1_700_000_000_000,
    });
    let (_, query) = archive_query(&fx);
    let form = query.form.expect("a time filter");
    let start = form
        .fields
        .iter()
        .find(|f| f.var.as_deref() == Some("start"))
        .expect("a start");
    assert_eq!(start.values, ["2023-11-14T22:13:20Z"]);
    assert!(query.set.unwrap().after.is_none());
}

#[test]
fn the_connections_own_cursor_is_better_than_a_clock_and_wins() {
    let mut s = session();
    s.on_online(&bound());
    feed(&mut s, &live_chat_with_archive_id("A1", "c1", "first"));
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 1 });
    assert!(fx.send.is_empty());
}

#[test]
fn archived_chats_are_shown_with_the_time_they_were_said_and_in_order() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 0 });
    let (qid, _) = archive_query(&fx);

    let mut said = Vec::new();
    for (n, body) in ["one", "two"].iter().enumerate() {
        let fx = feed(
            &mut s,
            &archived_chat(
                &qid,
                &format!("A{n}"),
                "2024-05-01T10:00:00Z",
                "carol@example.net/phone",
                "alice@example.org",
                &format!("c{n}"),
                body,
            ),
        );
        said.extend(messages(&fx).into_iter().cloned());
    }
    assert_eq!(said.len(), 2);
    assert_eq!(text(&said[0]), "one");
    assert_eq!(said[0].server_time_ms, Some(1_714_557_600_000));
    assert!(!said[0].is_self);
    assert_eq!(
        said[0].target,
        Target::Direct("carol@example.net".to_owned())
    );
    assert!(!said[0].is_mention, "history is old news");
}

#[test]
fn something_we_said_from_another_device_is_shown_as_ours() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 0 });
    let (qid, _) = archive_query(&fx);
    let fx = feed(
        &mut s,
        &archived_chat(
            &qid,
            "A1",
            "2024-05-01T10:00:00Z",
            "alice@example.org/phone",
            "carol@example.net",
            "mine1",
            "sent from my phone",
        ),
    );
    let m = messages(&fx)[0];
    assert!(m.is_self);
    assert_eq!(m.target, Target::Direct("carol@example.net".to_owned()));
}

#[test]
fn what_was_already_shown_is_not_shown_again_from_the_archive() {
    let mut s = session();
    s.on_online(&bound());
    feed(
        &mut s,
        &live_chat_with_archive_id("A1", "c1", "already here"),
    );
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 0 });
    // The connection has a cursor now, so the app's request was not needed; ask
    // as the relogin does.
    assert!(fx.send.is_empty());
    let fx = s.on_online(&bound());
    let (qid, _) = archive_query(&fx);
    let fx = feed(
        &mut s,
        &archived_chat(
            &qid,
            "A1",
            "2024-05-01T10:00:00Z",
            "carol@example.net/phone",
            "alice@example.org",
            "c1",
            "already here",
        ),
    );
    assert!(messages(&fx).is_empty());
}

#[test]
fn an_archived_chat_from_someone_who_was_not_asked_is_ignored() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 0 });
    let (qid, _) = archive_query(&fx);
    // Not from our own account, though it carries the right query id.
    let forged = format!(
        "<message xmlns='jabber:client' from='mallory@evil.example' to='alice@example.org/ddirc'>\
         <result xmlns='urn:xmpp:mam:2' queryid='{qid}' id='X'>\
         <forwarded xmlns='urn:xmpp:forward:0'>\
         <message xmlns='jabber:client' from='bank@example.net' to='alice@example.org' type='chat'>\
         <body>send me your password</body></message></forwarded></result></message>"
    );
    assert!(feed(&mut s, &forged).events.is_empty());
    // Nor one with a query id we never used.
    let unasked = archived_chat(
        "not-ours",
        "A9",
        "2024-05-01T10:00:00Z",
        "carol@example.net/phone",
        "alice@example.org",
        "c9",
        "hi",
    );
    assert!(feed(&mut s, &unasked).events.is_empty());
}

#[test]
fn a_page_that_says_there_is_more_is_followed_by_the_next() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 0 });
    let (qid, _) = archive_query(&fx);
    feed(
        &mut s,
        &archived_chat(
            &qid,
            "A1",
            "2024-05-01T10:00:00Z",
            "carol@example.net/phone",
            "alice@example.org",
            "c1",
            "one",
        ),
    );
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' id='{qid}'>\
             <fin xmlns='urn:xmpp:mam:2'><set xmlns='http://jabber.org/protocol/rsm'>\
             <last>A1</last></set></fin></iq>"
        ),
    );
    let (_, next) = archive_query(&fx);
    assert_eq!(next.set.unwrap().after.as_deref(), Some("A1"));
}

#[test]
fn a_page_that_brought_nothing_ends_it() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 0 });
    let (qid, _) = archive_query(&fx);
    let fx = feed(
        &mut s,
        &format!(
            "<iq xmlns='jabber:client' type='result' id='{qid}'>\
             <fin xmlns='urn:xmpp:mam:2'><set xmlns='http://jabber.org/protocol/rsm'>\
             <last>A1</last></set></fin></iq>"
        ),
    );
    assert!(
        fx.send.is_empty(),
        "an archive that says 'more' and sends none is not to be believed"
    );
}

#[test]
fn a_group_message_in_our_archive_is_not_a_chat() {
    let mut s = session();
    s.on_online(&bound());
    let fx = s.on_command(ClientCommand::CatchUpChats { since_ms: 0 });
    let (qid, _) = archive_query(&fx);
    let m = format!(
        "<message xmlns='jabber:client' from='alice@example.org' to='alice@example.org/ddirc'>\
         <result xmlns='urn:xmpp:mam:2' queryid='{qid}' id='G1'>\
         <forwarded xmlns='urn:xmpp:forward:0'>\
         <message xmlns='jabber:client' from='room@conference.example.org/bob' \
         to='alice@example.org' type='groupchat'><body>room talk</body></message>\
         </forwarded></result></message>"
    );
    assert!(messages(&feed(&mut s, &m)).is_empty());
}

// Keep `stanza` used: the helpers above build XML and parse it through feed.
#[test]
fn the_test_helpers_agree_about_stanzas() {
    assert!(matches!(
        stanza("<presence xmlns='jabber:client'/>"),
        Stanza::Presence(_)
    ));
}
