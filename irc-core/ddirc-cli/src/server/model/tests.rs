use super::*;

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::NONE)
}

fn press(app: &mut App, c: char) -> Vec<AdminCommand> {
    app.key(key(KeyCode::Char(c)))
}

fn user(id: u64, nick: Option<&str>, channels: &[&str]) -> UserInfo {
    UserInfo {
        id,
        nick: nick.map(str::to_owned),
        user: nick.map(str::to_owned),
        realname: None,
        registered: nick.is_some(),
        channels: channels.iter().map(|c| (*c).to_owned()).collect(),
        connected_at: 100,
    }
}

fn channel(name: &str, members: &[(&str, bool)]) -> ChannelInfo {
    ChannelInfo {
        name: name.to_owned(),
        topic: None,
        topic_set_by: None,
        members: members
            .iter()
            .map(|(nick, op)| MemberInfo {
                nick: (*nick).to_owned(),
                op: *op,
            })
            .collect(),
    }
}

fn snapshot(users: Vec<UserInfo>, channels: Vec<ChannelInfo>) -> Snapshot {
    Snapshot {
        server_name: "ddirc.local".into(),
        network_name: "Local".into(),
        started_at: 0,
        connections_total: users.len() as u64,
        messages_total: 0,
        users,
        channels,
        banned: Vec::new(),
        motd: vec!["hello".into(), "world".into()],
    }
}

fn app() -> App {
    let info = Info {
        port: 6697,
        anchor: "ca.pem".into(),
        connect: "ddirc-cli client".into(),
    };
    App::new(
        info,
        snapshot(
            vec![
                user(1, Some("alice"), &["#room"]),
                user(2, Some("bob"), &["#room", "#other"]),
                user(3, None, &[]),
            ],
            vec![
                channel("#other", &[("bob", true)]),
                channel("#room", &[("alice", true), ("bob", false)]),
            ],
        ),
        1_000,
    )
}

fn nick(app: &App) -> Option<&str> {
    app.selected_user().and_then(|u| u.nick.as_deref())
}

fn event(kind: EventKind) -> ServerEvent {
    // Constructed by the server in real life; the fields are public for this.
    ServerEvent { at: 50, kind }
}

#[test]
fn the_first_row_starts_selected() {
    let app = app();
    assert_eq!(nick(&app), Some("alice"));
    assert_eq!(app.selected_channel().unwrap().name, "#other");
}

#[test]
fn a_selection_follows_the_person_when_the_list_shuffles() {
    let mut app = app();
    app.key(key(KeyCode::Down));
    assert_eq!(nick(&app), Some("bob"));

    // Somebody sorting before bob arrives: every row moves, and bob is still bob.
    let mut users = app.snapshot.users.clone();
    users.insert(0, user(9, Some("aaron"), &[]));
    app.set_snapshot(snapshot(users, app.snapshot.channels.clone()));
    assert_eq!(nick(&app), Some("bob"));
    assert_eq!(app.user_row(), Some(2));
}

#[test]
fn when_the_selected_person_leaves_the_next_row_takes_over() {
    let mut app = app();
    app.key(key(KeyCode::Down));
    assert_eq!(nick(&app), Some("bob"));

    let users: Vec<_> = app
        .snapshot
        .users
        .iter()
        .filter(|u| u.id != 2)
        .cloned()
        .collect();
    app.set_snapshot(snapshot(users, vec![]));
    // The unnamed connection that was beneath them, not a jump to the top.
    assert_eq!(app.selected_user().unwrap().id, 3);
    assert!(app.selected_channel().is_none());

    app.set_snapshot(snapshot(vec![], vec![]));
    assert!(app.selected_user().is_none());
    // Keys with nothing selected are harmless.
    assert!(press(&mut app, 'x').is_empty());
    assert!(app.confirm.is_none());
}

#[test]
fn removing_someone_asks_first_and_only_y_agrees() {
    let mut app = app();
    assert!(press(&mut app, 'x').is_empty());
    assert!(app.confirm.as_ref().unwrap().question.contains("alice"));

    // Enter is a reflex, not an answer.
    assert!(app.key(key(KeyCode::Enter)).is_empty());
    assert!(app.confirm.is_none(), "and it counts as no");

    press(&mut app, 'x');
    let sent = press(&mut app, 'y');
    assert_eq!(
        sent,
        vec![AdminCommand::Disconnect {
            nick: "alice".into(),
            reason: None
        }]
    );
    assert!(app.confirm.is_none());
}

#[test]
fn the_question_names_the_person_chosen_when_it_was_asked() {
    let mut app = app();
    press(&mut app, 'b');
    // The list changes while the question is up.
    let mut users = app.snapshot.users.clone();
    users.remove(0);
    app.set_snapshot(snapshot(users, vec![]));

    let sent = press(&mut app, 'y');
    assert_eq!(
        sent,
        vec![AdminCommand::Ban {
            nick: "alice".into(),
            reason: None
        }],
        "alice was asked about, so alice it is"
    );
}

#[test]
fn a_connection_with_no_nick_cannot_be_acted_on() {
    let mut app = app();
    app.key(key(KeyCode::End));
    assert_eq!(app.selected_user().unwrap().id, 3);

    assert!(press(&mut app, 'x').is_empty());
    assert!(app.confirm.is_none());
    assert!(app
        .flash
        .as_ref()
        .unwrap()
        .text
        .contains("not chosen a nick"));
}

#[test]
fn kick_opens_the_command_line_ready_to_finish() {
    let mut app = app();
    app.key(key(KeyCode::Down));
    assert!(press(&mut app, 'k').is_empty());
    assert_eq!(app.bar.as_ref().unwrap().value(), "kick #room bob ");

    for c in "spam".chars() {
        press(&mut app, c);
    }
    let sent = app.key(key(KeyCode::Enter));
    assert_eq!(
        sent,
        vec![AdminCommand::Kick {
            channel: "#room".into(),
            nick: "bob".into(),
            reason: Some("spam".into())
        }]
    );
    assert!(app.bar.is_none());
}

#[test]
fn a_mistyped_command_is_kept_for_fixing() {
    let mut app = app();
    press(&mut app, ':');
    for c in "frob".chars() {
        press(&mut app, c);
    }
    assert!(app.key(key(KeyCode::Enter)).is_empty());
    assert_eq!(app.bar.as_ref().unwrap().value(), "frob");
    assert!(!app.flash.as_ref().unwrap().ok);

    app.key(key(KeyCode::Esc));
    assert!(app.bar.is_none());
}

#[test]
fn keys_typed_into_the_command_line_are_not_shortcuts() {
    let mut app = app();
    press(&mut app, ':');
    // `q` would otherwise ask to stop the server.
    press(&mut app, 'q');
    press(&mut app, 'x');
    assert_eq!(app.bar.as_ref().unwrap().value(), "qx");
    assert!(app.confirm.is_none());
}

#[test]
fn the_channels_tab_acts_on_members_once_focus_is_there() {
    let mut app = app();
    press(&mut app, '2');
    app.key(key(KeyCode::Down));
    assert_eq!(app.selected_channel().unwrap().name, "#room");
    assert_eq!(app.focus, Focus::Channels);

    // In the channel list the person-keys have no one to act on.
    assert!(press(&mut app, 'x').is_empty());
    assert!(app.confirm.is_none());

    app.key(key(KeyCode::Right));
    assert_eq!(app.focus, Focus::Members);
    assert_eq!(app.selected_member().unwrap().nick, "alice");
    app.key(key(KeyCode::Down));
    assert_eq!(app.selected_member().unwrap().nick, "bob");

    // bob is not an operator, so `o` makes him one; and the reverse.
    assert_eq!(
        press(&mut app, 'o'),
        vec![AdminCommand::Op {
            channel: "#room".into(),
            nick: "bob".into()
        }]
    );
    app.key(key(KeyCode::Up));
    assert_eq!(
        press(&mut app, 'o'),
        vec![AdminCommand::Deop {
            channel: "#room".into(),
            nick: "alice".into()
        }]
    );

    press(&mut app, 'k');
    assert_eq!(app.bar.as_ref().unwrap().value(), "kick #room alice ");
    app.key(key(KeyCode::Esc));

    // Esc steps back out to the channel list before it does anything else.
    app.key(key(KeyCode::Esc));
    assert_eq!(app.focus, Focus::Channels);
}

#[test]
fn channel_keys_set_topics_say_things_and_close_after_asking() {
    let mut app = app();
    press(&mut app, '2');
    app.key(key(KeyCode::Down));

    press(&mut app, 't');
    assert_eq!(app.bar.as_ref().unwrap().value(), "topic #room ");
    app.key(key(KeyCode::Esc));

    press(&mut app, 'n');
    assert_eq!(app.bar.as_ref().unwrap().value(), "say #room ");
    app.key(key(KeyCode::Esc));

    press(&mut app, 'c');
    assert!(app.confirm.as_ref().unwrap().question.contains("#room"));
    assert_eq!(
        press(&mut app, 'y'),
        vec![AdminCommand::CloseChannel {
            channel: "#room".into(),
            reason: None
        }]
    );
}

#[test]
fn changing_channel_resets_the_member_selection() {
    let mut app = app();
    press(&mut app, '2');
    app.key(key(KeyCode::Down));
    app.key(key(KeyCode::Right));
    app.key(key(KeyCode::Down));
    assert_eq!(app.selected_member().unwrap().nick, "bob");

    app.key(key(KeyCode::Left));
    app.key(key(KeyCode::Up));
    assert_eq!(app.selected_channel().unwrap().name, "#other");
    assert_eq!(
        app.selected_member().unwrap().nick,
        "bob",
        "that room's first"
    );
}

#[test]
fn stopping_the_server_is_a_question_too() {
    let mut app = app();
    press(&mut app, 'q');
    assert!(!app.quit);
    press(&mut app, 'n');
    assert!(!app.quit);

    press(&mut app, 'q');
    press(&mut app, 'y');
    assert!(app.quit);

    // Ctrl-C is the way out for someone who means it.
    let mut app = self::app();
    app.key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL));
    assert!(app.quit);
}

#[test]
fn tabs_switch_by_number_and_by_tab_key() {
    let mut app = app();
    assert_eq!(app.tab, Tab::Users);
    app.key(key(KeyCode::Tab));
    assert_eq!(app.tab, Tab::Channels);
    app.key(key(KeyCode::Tab));
    app.key(key(KeyCode::Tab));
    assert_eq!(app.tab, Tab::Users, "wraps");
    app.key(key(KeyCode::BackTab));
    assert_eq!(app.tab, Tab::Log);
    press(&mut app, '1');
    assert_eq!(app.tab, Tab::Users);
}

#[test]
fn events_fill_the_log_and_results_are_flashed() {
    let mut app = app();
    app.apply_event(&event(EventKind::Joined {
        nick: "bob".into(),
        channel: "#room".into(),
    }));
    app.apply_event(&event(EventKind::Admin {
        ok: false,
        text: "no such nick: carol".into(),
    }));

    assert_eq!(app.log.len(), 2);
    assert_eq!(app.log[0].text, "bob joined #room");
    assert_eq!(app.log[0].tone, Tone::Presence);
    assert_eq!(app.log[1].tone, Tone::Bad);
    let flash = app.flash.clone().unwrap();
    assert_eq!(flash.text, "no such nick: carol");
    assert!(!flash.ok);

    // And it fades.
    for _ in 0..FLASH_TICKS {
        app.tick(1_001);
    }
    assert!(app.flash.is_none());
}

#[test]
fn the_log_scrolls_back_and_holds_still_while_new_lines_arrive() {
    let mut app = app();
    press(&mut app, '3');
    for i in 0..30 {
        app.apply_event(&event(EventKind::Connected { id: i }));
    }
    assert_eq!(app.log_scroll, 0);

    app.key(key(KeyCode::PageUp));
    assert_eq!(app.log_scroll, PAGE);
    app.apply_event(&event(EventKind::Connected { id: 99 }));
    assert_eq!(app.log_scroll, PAGE + 1);

    app.key(key(KeyCode::End));
    assert_eq!(app.log_scroll, 0);
}

#[test]
fn the_log_is_bounded() {
    let mut app = app();
    for i in 0..(MAX_LOG as u64 + 10) {
        app.apply_event(&event(EventKind::Connected { id: i }));
    }
    assert_eq!(app.log.len(), MAX_LOG);
}

#[test]
fn the_motd_shortcut_starts_from_the_current_one() {
    let mut app = app();
    press(&mut app, 'M');
    assert_eq!(app.bar.as_ref().unwrap().value(), "motd hello | world");
    let sent = app.key(key(KeyCode::Enter));
    assert_eq!(
        sent,
        vec![AdminCommand::SetMotd {
            lines: vec!["hello".into(), "world".into()]
        }]
    );
}

#[test]
fn the_manager_answers_to_its_letters_on_any_layout_but_the_bar_takes_text() {
    // `ط` is the key `x` is on a US keyboard, on a Persian layout.
    let mut app = app();
    assert!(press(&mut app, 'ط').is_empty());
    assert!(app.confirm.is_some(), "x asked to disconnect");
    // `ن` is `k`... answering the question: `ی` is not y, `غ` is.
    press(&mut app, 'غ');
    assert!(app.confirm.is_none());

    // In the command bar a plain key is text, in any language.
    let mut app = self::app();
    press(&mut app, ':');
    for c in "سلام".chars() {
        press(&mut app, c);
    }
    assert_eq!(app.bar.as_ref().unwrap().value(), "سلام");

    // A chord is still a command while the bar is open: Ctrl-C stops everything.
    app.key(KeyEvent::new(KeyCode::Char('ز'), KeyModifiers::CONTROL));
    assert!(app.quit);
}

#[test]
fn f2_opens_the_command_line_for_a_layout_with_no_colon_where_it_expects_one() {
    let mut app = app();
    app.key(key(KeyCode::F(2)));
    assert!(app.bar.is_some());
}
