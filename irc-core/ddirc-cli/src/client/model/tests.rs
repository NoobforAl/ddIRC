use super::*;

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::NONE)
}

fn ctrl(c: char) -> KeyEvent {
    KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
}

fn alt(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::ALT)
}

fn spans(text: &str) -> Vec<TextSpan> {
    vec![TextSpan {
        text: text.to_owned(),
        style: SpanStyle::default(),
    }]
}

fn message(target: Target, sender: &str, text: &str) -> ChatMessage {
    ChatMessage {
        target,
        sender: sender.to_owned(),
        sender_prefix: None,
        spans: spans(text),
        is_self: false,
        is_mention: false,
        is_action: false,
        is_notice: false,
        msgid: None,
        server_time_ms: None,
        reply_to: None,
    }
}

fn chat(channel: &str, sender: &str, text: &str) -> IrcEvent {
    IrcEvent::Message(Box::new(message(
        Target::Channel(channel.to_owned()),
        sender,
        text,
    )))
}

fn member(nick: &str, prefix: Option<&str>) -> MemberView {
    MemberView {
        nick: nick.to_owned(),
        prefix: prefix.map(str::to_owned),
        away: false,
        // Operators first, then by name: the shape the core's own key has.
        sort_key: format!(
            "{}{}",
            if prefix.is_some() { "0" } else { "1" },
            nick.to_lowercase()
        ),
    }
}

fn joined(channel: &str, nick: &str, is_self: bool) -> IrcEvent {
    IrcEvent::Joined {
        channel: channel.to_owned(),
        nick: nick.to_owned(),
        is_self,
    }
}

fn app() -> App {
    App::new("me", "irc.test")
}

fn type_line(app: &mut App, text: &str) -> Vec<ClientCommand> {
    app.input = Input::new(text.to_owned());
    app.key(key(KeyCode::Enter))
}

fn last(app: &App) -> String {
    app.buffer()
        .lines
        .back()
        .map(Line::text)
        .unwrap_or_default()
}

#[test]
fn joining_a_channel_opens_it_and_moves_you_there() {
    let mut app = app();
    app.apply(joined("#rust", "me", true));

    assert_eq!(app.buffers.len(), 2);
    assert_eq!(app.buffer().name, "#rust");
    assert_eq!(app.target(), Some("#rust"));
    assert_eq!(last(&app), "you joined #rust");

    // Somebody else arriving is a line, not a move.
    app.apply(joined("#rust", "bob", false));
    assert_eq!(app.current, 1);
    assert_eq!(last(&app), "bob joined");
}

#[test]
fn the_server_buffer_is_nobody_to_talk_to() {
    let mut app = app();
    assert_eq!(app.target(), None);

    assert!(type_line(&mut app, "hello?").is_empty());
    assert!(last(&app).contains("no conversation here"));
}

#[test]
fn messages_elsewhere_count_until_you_look_and_mentions_stand_out() {
    let mut app = app();
    app.apply(joined("#a", "me", true));
    app.apply(joined("#b", "me", true));
    assert_eq!(app.buffer().name, "#b");

    app.apply(chat("#a", "bob", "one"));
    app.apply(chat("#a", "bob", "two"));
    assert_eq!(app.buffers[1].unread, 2);
    assert!(!app.buffers[1].mentioned);

    let mut ping = message(Target::Channel("#a".to_owned()), "bob", "me: ping");
    ping.is_mention = true;
    app.apply(IrcEvent::Message(Box::new(ping)));
    assert!(app.buffers[1].mentioned);

    // What is on screen is already read, and what you said yourself is too.
    app.apply(chat("#b", "bob", "here"));
    assert_eq!(app.buffers[2].unread, 0);

    app.switch(1);
    assert_eq!(app.buffers[1].unread, 0);
    assert!(!app.buffers[1].mentioned);
}

#[test]
fn a_private_message_opens_a_conversation_and_is_always_worth_noticing() {
    let mut app = app();
    app.apply(IrcEvent::Message(Box::new(message(
        Target::Direct("bob".to_owned()),
        "bob",
        "psst",
    ))));
    assert_eq!(app.buffers[1].kind, BufferKind::Direct);
    assert_eq!(app.buffers[1].name, "bob");
    assert!(app.buffers[1].mentioned);
}

#[test]
fn a_notice_from_a_server_stays_on_the_server_window() {
    let mut app = app();
    let mut notice = message(
        Target::Direct("irc.test".to_owned()),
        "irc.test",
        "restarting",
    );
    notice.is_notice = true;
    app.apply(IrcEvent::Message(Box::new(notice)));

    assert_eq!(app.buffers.len(), 1, "no conversation with a machine");
    assert_eq!(app.buffers[0].lines.back().unwrap().text(), "restarting");
}

#[test]
fn being_kicked_closes_the_room_and_keeps_the_reason_where_it_can_be_read() {
    let mut app = app();
    app.apply(joined("#room", "me", true));
    assert_eq!(app.buffer().name, "#room");

    app.apply(IrcEvent::Parted {
        channel: "#room".to_owned(),
        nick: "me".to_owned(),
        is_self: true,
        reason: Some("kicked by alice: too loud".to_owned()),
    });

    assert_eq!(app.buffers.len(), 1);
    assert_eq!(app.current, 0, "back to the server window");
    assert_eq!(last(&app), "you left #room (kicked by alice: too loud)");
}

#[test]
fn removing_a_window_does_not_move_you_to_a_different_one() {
    let mut app = app();
    app.apply(joined("#a", "me", true));
    app.apply(joined("#b", "me", true));
    app.apply(joined("#c", "me", true));
    app.switch(3);

    app.apply(IrcEvent::Parted {
        channel: "#a".to_owned(),
        nick: "me".to_owned(),
        is_self: true,
        reason: None,
    });
    assert_eq!(app.buffer().name, "#c");
}

#[test]
fn the_roster_stays_in_order_as_people_come_and_go() {
    let mut app = app();
    app.apply(joined("#r", "me", true));
    app.apply(IrcEvent::MemberList {
        channel: "#r".to_owned(),
        members: vec![
            member("zed", None),
            member("amy", Some("@")),
            member("bob", None),
        ],
    });
    let names = |app: &App| -> Vec<String> {
        app.buffer()
            .members
            .iter()
            .map(|m| m.nick.clone())
            .collect()
    };
    assert_eq!(names(&app), vec!["amy", "bob", "zed"]);

    // Arrives in the middle.
    app.apply(IrcEvent::MemberChanged {
        channel: "#r".to_owned(),
        previous: "cat".to_owned(),
        member: Some(member("cat", None)),
    });
    assert_eq!(names(&app), vec!["amy", "bob", "cat", "zed"]);

    // Renamed: the row it was filed under goes, wherever the new one lands.
    app.apply(IrcEvent::MemberChanged {
        channel: "#r".to_owned(),
        previous: "BOB".to_owned(),
        member: Some(member("yan", None)),
    });
    assert_eq!(names(&app), vec!["amy", "cat", "yan", "zed"]);

    app.apply(IrcEvent::MemberChanged {
        channel: "#r".to_owned(),
        previous: "amy".to_owned(),
        member: None,
    });
    assert_eq!(names(&app), vec!["cat", "yan", "zed"]);
}

#[test]
fn typing_sends_to_the_conversation_you_are_in() {
    let mut app = app();
    app.apply(joined("#rust", "me", true));

    let sent = type_line(&mut app, "hello there");
    assert_eq!(
        sent,
        vec![ClientCommand::SendMessage {
            target: "#rust".to_owned(),
            text: "hello there".to_owned()
        }]
    );
    assert_eq!(app.input.value(), "", "the line is spent");
}

#[test]
fn query_opens_a_window_and_close_shuts_a_private_one_but_parts_a_channel() {
    let mut app = app();
    assert!(type_line(&mut app, "/query bob").is_empty());
    assert_eq!(app.buffer().name, "bob");
    assert_eq!(app.buffer().kind, BufferKind::Direct);

    assert!(type_line(&mut app, "/close").is_empty());
    assert_eq!(app.buffers.len(), 1);

    app.apply(joined("#rust", "me", true));
    let sent = type_line(&mut app, "/close");
    assert_eq!(
        sent,
        vec![ClientCommand::Part {
            channel: "#rust".to_owned(),
            reason: None
        }]
    );
    assert_eq!(
        app.buffers.len(),
        2,
        "closed when the server confirms, not before"
    );

    app.switch(0);
    type_line(&mut app, "/close");
    assert!(last(&app).contains("cannot be closed"));
}

#[test]
fn quitting_says_goodbye_to_the_core() {
    let mut app = app();
    let sent = type_line(&mut app, "/quit later");
    assert!(app.quit);
    assert_eq!(
        sent,
        vec![ClientCommand::Disconnect {
            reason: Some("later".to_owned())
        }]
    );

    let mut app = self::app();
    assert_eq!(
        app.key(ctrl('c')),
        vec![ClientCommand::Disconnect { reason: None }]
    );
    assert!(app.quit);
}

#[test]
fn list_shows_what_arrives_and_enter_joins_the_highlighted_channel() {
    let mut app = app();
    assert_eq!(
        type_line(&mut app, "/list"),
        vec![ClientCommand::ListChannels]
    );
    assert!(matches!(app.popup, Some(Popup::Channels { .. })));

    let listing = |name: &str| ChannelListing {
        name: name.to_owned(),
        users: 3,
        topic: String::new(),
    };
    app.apply(IrcEvent::ChannelList {
        channels: vec![listing("#one"), listing("#two")],
        done: true,
        truncated: false,
    });

    app.key(key(KeyCode::Down));
    let sent = app.key(key(KeyCode::Enter));
    assert_eq!(
        sent,
        vec![ClientCommand::Join {
            channel: "#two".to_owned(),
            key: None
        }]
    );
    assert!(app.popup.is_none());
}

#[test]
fn a_list_nobody_asked_for_does_not_pop_up() {
    let mut app = app();
    app.apply(IrcEvent::ChannelList {
        channels: Vec::new(),
        done: true,
        truncated: false,
    });
    assert!(app.popup.is_none());

    // And closing it halfway stops the rest from reopening it.
    type_line(&mut app, "/list");
    app.key(key(KeyCode::Esc));
    app.apply(IrcEvent::ChannelList {
        channels: Vec::new(),
        done: false,
        truncated: false,
    });
    assert!(app.popup.is_none());
}

#[test]
fn up_and_down_walk_the_history_and_bring_the_draft_back() {
    let mut app = app();
    app.apply(joined("#r", "me", true));
    type_line(&mut app, "first");
    type_line(&mut app, "second");

    app.input = Input::new("half-typed".to_owned());
    app.key(key(KeyCode::Up));
    assert_eq!(app.input.value(), "second");
    app.key(key(KeyCode::Up));
    assert_eq!(app.input.value(), "first");
    app.key(key(KeyCode::Down));
    assert_eq!(app.input.value(), "second");
    app.key(key(KeyCode::Down));
    assert_eq!(app.input.value(), "half-typed");
}

#[test]
fn tab_completes_a_nick_and_tab_again_tries_the_next() {
    let mut app = app();
    app.apply(joined("#r", "me", true));
    app.apply(IrcEvent::MemberList {
        channel: "#r".to_owned(),
        members: vec![
            member("alice", None),
            member("Albert", None),
            member("bob", None),
        ],
    });

    app.input = Input::new("al".to_owned());
    app.key(key(KeyCode::Tab));
    // First word of the line: an address, so it gets the colon.
    assert_eq!(app.input.value(), "Albert: ");
    app.key(key(KeyCode::Tab));
    assert_eq!(app.input.value(), "alice: ");
    app.key(key(KeyCode::Tab));
    assert_eq!(app.input.value(), "Albert: ", "and round again");

    // Mid-sentence it is just a word. Any other key ends the completion in
    // progress, which is what typing the new line would have done.
    app.key(key(KeyCode::Esc));
    app.input = Input::new("hi bo".to_owned());
    app.key(key(KeyCode::Tab));
    assert_eq!(app.input.value(), "hi bob ");

    // No such nick: nothing happens.
    app.input = Input::new("zz".to_owned());
    app.key(key(KeyCode::Tab));
    assert_eq!(app.input.value(), "zz");
}

#[test]
fn scrolling_back_stays_put_while_new_lines_arrive() {
    let mut app = app();
    app.apply(joined("#r", "me", true));
    for i in 0..30 {
        app.apply(chat("#r", "bob", &format!("line {i}")));
    }
    assert_eq!(app.buffer().scroll, 0, "pinned to the newest");

    app.key(key(KeyCode::PageUp));
    assert_eq!(app.buffer().scroll, PAGE);
    app.apply(chat("#r", "bob", "new"));
    assert_eq!(
        app.buffer().scroll,
        PAGE + 1,
        "what you were reading has not moved"
    );

    app.key(key(KeyCode::PageDown));
    app.key(key(KeyCode::PageDown));
    assert_eq!(app.buffer().scroll, 0);
}

#[test]
fn scrollback_is_bounded() {
    let mut app = app();
    app.apply(joined("#r", "me", true));
    for i in 0..(MAX_LINES + 50) {
        app.apply(chat("#r", "bob", &format!("{i}")));
    }
    assert_eq!(app.buffer().lines.len(), MAX_LINES);
    assert_eq!(
        app.buffer().lines.back().unwrap().text(),
        (MAX_LINES + 49).to_string()
    );
}

#[test]
fn windows_can_be_cycled_and_jumped_to() {
    let mut app = app();
    app.apply(joined("#a", "me", true));
    app.apply(joined("#b", "me", true));
    assert_eq!(app.current, 2);

    app.key(ctrl('n'));
    assert_eq!(app.current, 0, "wraps to the server window");
    app.key(ctrl('p'));
    assert_eq!(app.current, 2);
    app.key(alt(KeyCode::Char('2')));
    assert_eq!(app.buffer().name, "#a");
    app.key(alt(KeyCode::Right));
    assert_eq!(app.buffer().name, "#b");
    // A number past the last window is not a window.
    app.key(alt(KeyCode::Char('9')));
    assert_eq!(app.buffer().name, "#b");
}

#[test]
fn a_refusal_appears_under_the_command_that_caused_it() {
    let mut app = app();
    app.apply(joined("#r", "me", true));
    app.apply(IrcEvent::Error {
        message: "You're not channel operator".to_owned(),
        fatal: false,
    });
    assert_eq!(last(&app), "You're not channel operator");
    assert_eq!(app.buffer().lines.back().unwrap().kind, LineKind::Error);
}

#[test]
fn the_topic_is_kept_for_the_header() {
    let mut app = app();
    app.apply(joined("#r", "me", true));
    app.apply(IrcEvent::TopicChanged {
        channel: "#R".to_owned(),
        topic: "be nice".to_owned(),
        set_by: None,
    });
    assert_eq!(app.buffer().topic.as_deref(), Some("be nice"));

    app.apply(IrcEvent::TopicChanged {
        channel: "#r".to_owned(),
        topic: String::new(),
        set_by: Some("alice".to_owned()),
    });
    assert_eq!(app.buffer().topic, None);
}

#[test]
fn escape_clears_the_line_and_f1_opens_help() {
    let mut app = app();
    app.input = Input::new("oops".to_owned());
    app.key(key(KeyCode::Esc));
    assert_eq!(app.input.value(), "");

    app.key(key(KeyCode::F(1)));
    assert!(matches!(app.popup, Some(Popup::Help)));
    // While it is up, keys go to it and not to the line underneath.
    app.key(key(KeyCode::Char('x')));
    assert_eq!(app.input.value(), "");
    app.key(key(KeyCode::Esc));
    assert!(app.popup.is_none());
}

#[test]
fn shortcuts_work_on_a_non_latin_layout_but_typing_stays_in_that_language() {
    // Observed on a Persian layout: Ctrl-C arrives as Ctrl-ز.
    let mut app = app();
    let sent = app.key(KeyEvent::new(KeyCode::Char('ز'), KeyModifiers::CONTROL));
    assert!(
        app.quit,
        "Ctrl-C has to quit whatever is printed on the key"
    );
    assert_eq!(sent, vec![ClientCommand::Disconnect { reason: None }]);

    // Ctrl-N (`د` on the same layout) still switches windows.
    let mut app = self::app();
    app.apply(joined("#a", "me", true));
    app.switch(0);
    app.key(KeyEvent::new(KeyCode::Char('د'), KeyModifiers::CONTROL));
    assert_eq!(app.buffer().name, "#a");

    // But a plain key is text, and nothing may turn it into Latin.
    let mut app = self::app();
    for c in "سلام دنیا".chars() {
        app.key(key(KeyCode::Char(c)));
    }
    assert_eq!(app.input.value(), "سلام دنیا");
    let mut app = self::app();
    for c in "привет".chars() {
        app.key(key(KeyCode::Char(c)));
    }
    assert_eq!(app.input.value(), "привет");

    // A popup takes no text, so there every key is a command: `ض` is `q`.
    app.key(key(KeyCode::F(1)));
    assert!(app.popup.is_some());
    app.key(key(KeyCode::Char('ض')));
    assert!(app.popup.is_none());
}
