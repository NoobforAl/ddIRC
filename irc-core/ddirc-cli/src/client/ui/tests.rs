use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{ChannelListing, ChatMessage, MemberView, Target};
use ddirc_core::text::format::{SpanStyle, TextSpan};
use ratatui::backend::TestBackend;
use ratatui::Terminal;

use super::*;

fn text_line(who: &str, text: &str) -> Line {
    Line {
        kind: LineKind::Chat,
        own: false,
        mention: false,
        who: who.to_owned(),
        prefix: String::new(),
        body: vec![TextSpan {
            text: text.to_owned(),
            style: SpanStyle::default(),
        }],
    }
}

fn row_text(row: &Row) -> String {
    row.spans.iter().map(|s| s.content.as_ref()).collect()
}

fn rows(line: &Line, width: usize) -> Vec<String> {
    layout(line, width).iter().map(row_text).collect()
}

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

fn message(channel: &str, sender: &str, text: &str) -> IrcEvent {
    IrcEvent::Message(Box::new(ChatMessage {
        target: Target::Channel(channel.to_owned()),
        sender: sender.to_owned(),
        sender_prefix: None,
        spans: vec![TextSpan {
            text: text.to_owned(),
            style: SpanStyle::default(),
        }],
        is_self: false,
        is_mention: false,
        is_action: false,
        is_notice: false,
        msgid: None,
        server_time_ms: None,
        reply_to: None,
    }))
}

fn app_in_a_channel() -> App {
    let mut app = App::new("me", "irc.test");
    app.apply(IrcEvent::Joined {
        channel: "#rust".to_owned(),
        nick: "me".to_owned(),
        is_self: true,
    });
    app.apply(IrcEvent::MemberList {
        channel: "#rust".to_owned(),
        members: vec![
            MemberView {
                nick: "amy".to_owned(),
                prefix: Some("@".to_owned()),
                away: false,
                sort_key: "0amy".to_owned(),
            },
            MemberView {
                nick: "bob".to_owned(),
                prefix: None,
                away: false,
                sort_key: "1bob".to_owned(),
            },
        ],
    });
    app.apply(IrcEvent::TopicChanged {
        channel: "#rust".to_owned(),
        topic: "all about rust".to_owned(),
        set_by: None,
    });
    app.apply(message("#rust", "bob", "hello there"));
    app
}

#[test]
fn a_short_line_is_one_row_with_its_speaker() {
    assert_eq!(rows(&text_line("bob", "hi"), 40), vec!["<bob> hi"]);
}

#[test]
fn a_long_line_breaks_at_spaces_and_hangs_under_itself() {
    let line = text_line("bob", "the quick brown fox jumps over");
    let wrapped = rows(&line, 16);
    assert_eq!(
        wrapped,
        vec!["<bob> the quick", "  brown fox", "  jumps over"]
    );
    assert!(wrapped.iter().all(|r| r.chars().count() <= 16));
}

#[test]
fn a_word_longer_than_the_screen_is_broken_rather_than_lost() {
    let line = text_line("b", "abcdefghijklmnopqrstuvwxyz");
    let wrapped = rows(&line, 10);
    assert!(wrapped.len() > 2);
    let joined: String = wrapped
        .iter()
        .map(|r| r.trim())
        .collect::<Vec<_>>()
        .join("");
    assert!(
        joined.replace(['<', '>', ' '], "").ends_with("xyz"),
        "{wrapped:?}"
    );
}

#[test]
fn an_absurdly_narrow_screen_still_terminates() {
    for width in 1..4 {
        let wrapped = rows(&text_line("bob", "some words"), width);
        assert!(!wrapped.is_empty());
    }
}

#[test]
fn wide_characters_are_measured_in_columns() {
    let line = text_line("a", "日本語日本語日本語");
    for row in rows(&line, 12) {
        assert!(
            unicode_width::UnicodeWidthStr::width(row.as_str()) <= 12,
            "{row:?}"
        );
    }
}

#[test]
fn the_conversation_shows_who_said_what_beside_the_windows_and_the_roster() {
    let app = app_in_a_channel();
    let screen = render(&app, 100, 20);

    assert!(screen.contains("<bob> hello there"), "{screen}");
    // The window list, with the channel highlighted among them.
    assert!(screen.contains("irc.test"), "{screen}");
    assert!(screen.contains("#rust"), "{screen}");
    // The header carries the topic; the roster, the people.
    assert!(screen.contains("all about rust"), "{screen}");
    assert!(screen.contains("@amy"), "{screen}");
    assert!(screen.contains("bob"), "{screen}");
    // The input bar says where a line typed now would go, and invites one.
    assert!(screen.contains("#rust ›"), "{screen}");
    assert!(screen.contains("Write a message…"), "{screen}");
}

#[test]
fn a_narrow_terminal_gives_the_room_to_the_conversation() {
    let app = app_in_a_channel();
    let screen = render(&app, 40, 14);
    assert!(screen.contains("<bob> hello there"), "{screen}");
    assert!(
        !screen.contains("@amy"),
        "no roster at this width\n{screen}"
    );
}

#[test]
fn scrolling_back_says_how_much_is_below() {
    let mut app = app_in_a_channel();
    for i in 0..40 {
        app.apply(message("#rust", "bob", &format!("line {i}")));
    }
    app.key(ratatui::crossterm::event::KeyEvent::new(
        ratatui::crossterm::event::KeyCode::PageUp,
        ratatui::crossterm::event::KeyModifiers::NONE,
    ));
    let screen = render(&app, 100, 20);
    assert!(screen.contains("newer"), "{screen}");
    assert!(!screen.contains("line 39"), "{screen}");
}

#[test]
fn the_newest_line_is_always_on_screen_when_pinned() {
    let mut app = app_in_a_channel();
    for i in 0..100 {
        app.apply(message("#rust", "bob", &format!("line {i}")));
    }
    let screen = render(&app, 100, 12);
    assert!(screen.contains("line 99"), "{screen}");
    assert!(!screen.contains("line 10 "), "{screen}");
}

#[test]
fn popups_draw_over_the_conversation() {
    let mut app = app_in_a_channel();
    app.key(ratatui::crossterm::event::KeyEvent::new(
        ratatui::crossterm::event::KeyCode::F(1),
        ratatui::crossterm::event::KeyModifiers::NONE,
    ));
    let screen = render(&app, 100, 40);
    assert!(screen.contains("Commands"), "{screen}");
    assert!(screen.contains("/join"), "{screen}");

    app.popup = Some(Popup::Channels {
        items: vec![ChannelListing {
            name: "#elsewhere".to_owned(),
            users: 42,
            topic: "somewhere else".to_owned(),
        }],
        selected: 0,
        done: true,
        truncated: false,
    });
    let screen = render(&app, 100, 30);
    assert!(screen.contains("#elsewhere"), "{screen}");
    assert!(screen.contains("somewhere else"), "{screen}");
}

#[test]
fn a_tiny_terminal_does_not_panic() {
    let app = app_in_a_channel();
    for (w, h) in [(1, 1), (10, 3), (20, 5), (30, 8)] {
        let _ = render(&app, w, h);
    }
}

#[test]
fn colours_are_stable_per_nick_and_ignore_case() {
    assert_eq!(nick_color("Alice"), nick_color("alice"));
}
