use ddirc_server::{
    AdminCommand, ChannelInfo, EventKind, MemberInfo, ServerEvent, Snapshot, UserInfo,
};
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::Terminal;

use super::super::model::Info;
use super::*;

fn render(app: &App, width: u16, height: u16) -> String {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
    terminal.draw(|frame| draw(frame, app)).unwrap();
    let buffer = terminal.backend().buffer();
    let mut out = String::new();
    for y in 0..buffer.area.height {
        for x in 0..buffer.area.width {
            out.push_str(buffer[(x, y)].symbol());
        }
        out.push('\n');
    }
    out
}

fn app() -> App {
    let user = |id, nick: Option<&str>, channels: &[&str]| UserInfo {
        id,
        nick: nick.map(str::to_owned),
        user: nick.map(str::to_owned),
        realname: None,
        registered: nick.is_some(),
        channels: channels.iter().map(|c| (*c).to_owned()).collect(),
        connected_at: 940,
    };
    let snapshot = Snapshot {
        server_name: "ddirc.local".into(),
        network_name: "Local".into(),
        started_at: 0,
        connections_total: 3,
        messages_total: 7,
        users: vec![
            user(1, Some("alice"), &["#room"]),
            user(2, Some("bob"), &["#room"]),
            user(3, None, &[]),
        ],
        channels: vec![ChannelInfo {
            name: "#room".into(),
            topic: Some("be nice".into()),
            topic_set_by: Some("alice".into()),
            members: vec![
                MemberInfo {
                    nick: "alice".into(),
                    op: true,
                },
                MemberInfo {
                    nick: "bob".into(),
                    op: false,
                },
            ],
        }],
        banned: vec!["eve".into()],
        motd: vec![],
    };
    let info = Info {
        port: 6697,
        anchor: "/data/ca.pem".into(),
        connect: "ddirc-cli client --server 127.0.0.1 --port 6697".into(),
    };
    App::new(info, snapshot, 1_000)
}

fn press(app: &mut App, code: KeyCode) -> Vec<AdminCommand> {
    app.key(KeyEvent::new(code, KeyModifiers::NONE))
}

#[test]
fn the_header_says_what_this_is_and_how_to_reach_it() {
    let screen = render(&app(), 110, 30);
    assert!(screen.contains("ddirc server"), "{screen}");
    assert!(screen.contains("Local (ddirc.local)"), "{screen}");
    assert!(screen.contains("127.0.0.1:6697"), "{screen}");
    assert!(screen.contains("2 online"), "{screen}");
    assert!(screen.contains("up 16m 40s"), "{screen}");
    assert!(screen.contains("connect: ddirc-cli client"), "{screen}");
}

#[test]
fn the_users_tab_lists_everyone_including_the_unnamed() {
    let screen = render(&app(), 110, 30);
    assert!(screen.contains("alice"), "{screen}");
    assert!(screen.contains("bob"), "{screen}");
    assert!(screen.contains("(connecting)"), "{screen}");
    assert!(screen.contains("#room"), "{screen}");
    // How long they have been here: now (1000) minus connected_at (940).
    assert!(screen.contains("1m 00s"), "{screen}");
    // The names that cannot come back.
    assert!(screen.contains("banned: eve"), "{screen}");
}

#[test]
fn the_channels_tab_shows_rooms_and_the_people_in_the_chosen_one() {
    let mut app = app();
    press(&mut app, KeyCode::Char('2'));
    let screen = render(&app, 110, 30);
    assert!(screen.contains("be nice"), "{screen}");
    assert!(screen.contains("@alice"), "{screen}");
    assert!(screen.contains("#room — 2"), "{screen}");
}

#[test]
fn the_activity_log_is_on_every_tab_but_its_own() {
    let mut app = app();
    app.apply_event(&ServerEvent {
        at: 3_661,
        kind: EventKind::Joined {
            nick: "bob".into(),
            channel: "#room".into(),
        },
    });
    let screen = render(&app, 110, 40);
    assert!(screen.contains("Activity"), "{screen}");
    assert!(screen.contains("01:01:01  bob joined #room"), "{screen}");

    // Too short to spare the rows: the lists win.
    let screen = render(&app, 110, 20);
    assert!(!screen.contains("Activity"), "{screen}");

    press(&mut app, KeyCode::Char('3'));
    let screen = render(&app, 110, 40);
    assert!(screen.contains("bob joined #room"), "{screen}");
    assert!(!screen.contains("Activity"), "{screen}");
}

#[test]
fn the_command_line_and_the_questions_appear_when_asked_for() {
    let mut app = app();
    press(&mut app, KeyCode::Char('k'));
    let screen = render(&app, 110, 30);
    assert!(screen.contains("kick #room alice"), "{screen}");
    assert!(screen.contains("Esc cancel"), "{screen}");
    press(&mut app, KeyCode::Esc);

    press(&mut app, KeyCode::Char('x'));
    let screen = render(&app, 110, 30);
    assert!(screen.contains("Are you sure?"), "{screen}");
    assert!(screen.contains("Disconnect alice"), "{screen}");
}

#[test]
fn a_result_is_shown_on_the_status_line() {
    let mut app = app();
    app.apply_event(&ServerEvent {
        at: 1,
        kind: EventKind::Admin {
            ok: false,
            text: "no such nick: carol".into(),
        },
    });
    let screen = render(&app, 110, 30);
    assert!(screen.contains("✗ no such nick: carol"), "{screen}");
}

#[test]
fn an_empty_server_says_how_to_connect() {
    let mut app = app();
    let mut snapshot = app.snapshot.clone();
    snapshot.users.clear();
    snapshot.channels.clear();
    app.set_snapshot(snapshot);

    let screen = render(&app, 110, 30);
    assert!(screen.contains("Nobody is connected yet"), "{screen}");
    press(&mut app, KeyCode::Char('2'));
    let screen = render(&app, 110, 30);
    assert!(screen.contains("No channels yet"), "{screen}");
}

#[test]
fn help_lists_the_commands_and_the_certificate() {
    let mut app = app();
    press(&mut app, KeyCode::Char('?'));
    let screen = render(&app, 120, 50);
    assert!(screen.contains("kick <#chan> <nick>"), "{screen}");
    assert!(
        screen.contains("certificate to trust: /data/ca.pem"),
        "{screen}"
    );
}

#[test]
fn a_tiny_terminal_does_not_panic() {
    let mut app = app();
    for (w, h) in [(1, 1), (10, 4), (30, 10), (60, 12)] {
        let _ = render(&app, w, h);
    }
    press(&mut app, KeyCode::Char('2'));
    press(&mut app, KeyCode::Char('3'));
    for (w, h) in [(1, 1), (10, 4), (30, 10)] {
        let _ = render(&app, w, h);
    }
}
