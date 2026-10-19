//! Where things go on the manager's screen.
//!
//! Reads the [`App`]; changes nothing but the cursor. The activity log is on
//! screen under every tab but its own, because the thing an operator watches a
//! server for is what is happening, and a tab for it alone would be a tab they
//! have to leave the thing they are doing to look at.

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{Block, Cell, List, ListItem, Paragraph, Row, Table, TableState, Tabs};
use ratatui::Frame;

use super::commands::HELP;
use super::model::{App, Focus, LogLine, Tab, Tone};
use crate::composer::{self, Composer};
use crate::widgets::{self, age, bold, clip, clock, dim, help_lines, ACCENT};

/// Below this the activity pane is dropped; the lists matter more.
const LOG_MIN_HEIGHT: u16 = 26;
const LOG_ROWS: u16 = 8;

pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let log_rows = if app.tab != Tab::Log && area.height >= LOG_MIN_HEIGHT {
        LOG_ROWS
    } else {
        0
    };
    let bar_rows = if app.bar.is_some() { 3 } else { 1 };
    let [header, tabs, body, log, bar, hints] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Length(1),
        Constraint::Min(4),
        Constraint::Length(log_rows),
        Constraint::Length(bar_rows),
        Constraint::Length(1),
    ])
    .areas(area);

    draw_header(frame, header, app);
    draw_tabs(frame, tabs, app);
    match app.tab {
        Tab::Users => draw_users(frame, body, app),
        Tab::Channels => draw_channels(frame, body, app),
        Tab::Log => draw_log(frame, body, app, " Log "),
    }
    if log_rows > 0 {
        draw_log(frame, log, app, " Activity ");
    }
    draw_bar(frame, bar, app);
    draw_hints(frame, hints, app);

    if let Some(confirm) = &app.confirm {
        let body = Text::from(vec![
            Line::raw(confirm.question.clone()),
            Line::raw(""),
            Line::from(vec![
                Span::styled(
                    "y",
                    Style::new().fg(Color::Red).add_modifier(Modifier::BOLD),
                ),
                Span::raw(" yes     "),
                Span::styled("n", bold()),
                Span::raw(" no"),
            ]),
        ]);
        widgets::popup(frame, "Are you sure?", body);
    } else if app.help {
        draw_help(frame, app);
    }
}

fn draw_header(frame: &mut Frame, area: Rect, app: &App) {
    let s = &app.snapshot;
    let online = s.users.iter().filter(|u| u.registered).count();
    let summary = Line::from(vec![
        Span::styled(" ddirc server ", Style::new().fg(Color::Black).bg(ACCENT)),
        Span::raw(format!(
            " {} ({}) · 127.0.0.1:{} · up {} · {} online · {} channels · {} messages",
            s.network_name,
            s.server_name,
            app.info.port,
            age(app.now.saturating_sub(s.started_at)),
            online,
            s.channels.len(),
            s.messages_total,
        )),
    ]);
    let connect = Line::styled(
        clip(
            &format!(" connect: {}", app.info.connect),
            area.width as usize,
        ),
        dim(),
    );
    frame.render_widget(Paragraph::new(vec![summary, connect]), area);
}

fn draw_tabs(frame: &mut Frame, area: Rect, app: &App) {
    let online = app.snapshot.users.iter().filter(|u| u.registered).count();
    let titles = [
        format!("1 Users ({online})"),
        format!("2 Channels ({})", app.snapshot.channels.len()),
        "3 Log".to_owned(),
    ];
    let selected = Tab::ALL.iter().position(|t| *t == app.tab).unwrap_or(0);
    frame.render_widget(
        Tabs::new(titles)
            .select(selected)
            .highlight_style(
                Style::new()
                    .fg(ACCENT)
                    .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
            )
            .style(dim())
            .divider("│"),
        area,
    );
}

fn pane(title: String, active: bool) -> Block<'static> {
    Block::bordered()
        .title(Line::styled(title, if active { bold() } else { dim() }))
        .border_style(if active {
            Style::new().fg(ACCENT)
        } else {
            dim()
        })
}

// -------------------------------------------------------------------- users

fn draw_users(frame: &mut Frame, area: Rect, app: &App) {
    let online = app.snapshot.users.iter().filter(|u| u.registered).count();
    let mut title = format!(" Users ({online}) ");
    if !app.snapshot.banned.is_empty() {
        title = format!("{title}· banned: {} ", app.snapshot.banned.join(", "));
    }
    let block = pane(title, true);

    if app.snapshot.users.is_empty() {
        let text = Text::from(vec![
            Line::raw(""),
            Line::styled("  Nobody is connected yet.", dim()),
            Line::styled(
                clip(
                    &format!("  Try: {}", app.info.connect),
                    area.width as usize - 2,
                ),
                dim(),
            ),
        ]);
        frame.render_widget(Paragraph::new(text).block(block), area);
        return;
    }

    let rows = app.snapshot.users.iter().map(|u| {
        let nick = match (&u.nick, u.registered) {
            (Some(nick), true) => Cell::from(nick.clone()),
            (Some(nick), false) => Cell::from(format!("{nick} …")).style(dim()),
            (None, _) => Cell::from("(connecting)").style(dim()),
        };
        Row::new([
            nick,
            Cell::from(u.user.clone().unwrap_or_default()),
            Cell::from(u.channels.join(" ")),
            Cell::from(age(app.now.saturating_sub(u.connected_at))),
        ])
    });
    let table = Table::new(
        rows,
        [
            Constraint::Length(20),
            Constraint::Length(14),
            Constraint::Min(10),
            Constraint::Length(10),
        ],
    )
    .header(Row::new(["Nick", "User", "Channels", "Connected"]).style(bold()))
    .row_highlight_style(Style::new().add_modifier(Modifier::REVERSED))
    .highlight_symbol("▶ ")
    .block(block);
    let mut state = TableState::default().with_selected(app.user_row());
    frame.render_stateful_widget(table, area, &mut state);
}

// ----------------------------------------------------------------- channels

fn draw_channels(frame: &mut Frame, area: Rect, app: &App) {
    let [left, right] =
        Layout::horizontal([Constraint::Percentage(55), Constraint::Min(20)]).areas(area);
    let list_active = app.focus == Focus::Channels;

    let block = pane(
        format!(" Channels ({}) ", app.snapshot.channels.len()),
        list_active,
    );
    if app.snapshot.channels.is_empty() {
        frame.render_widget(
            Paragraph::new(Text::from(vec![
                Line::raw(""),
                Line::styled(
                    "  No channels yet. One appears when someone joins it.",
                    dim(),
                ),
            ]))
            .block(block),
            left,
        );
    } else {
        let rows = app.snapshot.channels.iter().map(|c| {
            Row::new([
                Cell::from(c.name.clone()),
                Cell::from(c.members.len().to_string()),
                Cell::from(c.topic.clone().unwrap_or_default()).style(dim()),
            ])
        });
        let table = Table::new(
            rows,
            [
                Constraint::Length(20),
                Constraint::Length(6),
                Constraint::Min(10),
            ],
        )
        .header(Row::new(["Channel", "Users", "Topic"]).style(bold()))
        .row_highlight_style(if list_active {
            Style::new().add_modifier(Modifier::REVERSED)
        } else {
            Style::new().add_modifier(Modifier::BOLD)
        })
        .highlight_symbol(if list_active { "▶ " } else { "  " })
        .block(block);
        let mut state = TableState::default().with_selected(app.channel_row());
        frame.render_stateful_widget(table, left, &mut state);
    }

    let (title, items): (String, Vec<ListItem>) = match app.selected_channel() {
        Some(channel) => (
            format!(" {} — {} ", channel.name, channel.members.len()),
            channel
                .members
                .iter()
                .map(|m| {
                    ListItem::new(Line::from(vec![
                        Span::styled(if m.op { "@" } else { " " }, Style::new().fg(Color::Green)),
                        Span::raw(m.nick.clone()),
                    ]))
                })
                .collect(),
        ),
        None => (" Members ".to_owned(), Vec::new()),
    };
    let list = List::new(items)
        .block(pane(title, !list_active))
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED))
        .highlight_symbol("▶");
    let mut state = ratatui::widgets::ListState::default().with_selected(if list_active {
        None
    } else {
        app.member_row()
    });
    frame.render_stateful_widget(list, right, &mut state);
}

// ---------------------------------------------------------------------- log

fn tone_style(tone: Tone) -> Style {
    match tone {
        Tone::Presence => dim(),
        Tone::Chat => Style::new(),
        Tone::Moderation => Style::new().fg(Color::Yellow),
        Tone::Good => Style::new().fg(Color::Green),
        Tone::Bad => Style::new().fg(Color::Red),
    }
}

fn log_row(line: &LogLine, width: usize) -> Line<'static> {
    // 8 for the clock and 2 for the gap.
    Line::from(vec![
        Span::styled(clock(line.at), dim()),
        Span::raw("  "),
        Span::styled(
            clip(&line.text, width.saturating_sub(10)),
            tone_style(line.tone),
        ),
    ])
}

fn draw_log(frame: &mut Frame, area: Rect, app: &App, title: &str) {
    let mut block = pane(title.to_owned(), app.tab == Tab::Log);
    if app.log_scroll > 0 {
        block = block.title_bottom(
            Line::styled(
                format!(" ↓ {} newer ", app.log_scroll),
                Style::new().fg(Color::Yellow),
            )
            .right_aligned(),
        );
    }
    let inner = block.inner(area);
    let end = app.log.len().saturating_sub(app.log_scroll);
    let start = end.saturating_sub(inner.height as usize);
    let rows: Vec<Line> = app
        .log
        .range(start..end)
        .map(|l| log_row(l, inner.width as usize))
        .collect();
    frame.render_widget(Paragraph::new(rows).block(block), area);
}

// ------------------------------------------------------------ bar and hints

fn draw_bar(frame: &mut Frame, area: Rect, app: &App) {
    if let Some(input) = &app.bar {
        let composer = Composer {
            input,
            label: ":",
            placeholder: "Type a command — help lists them",
            hint: "↵ run · Esc cancel",
        };
        // The hint is always useful here, not only once there is text: a
        // command line you cannot see how to leave is a trap.
        composer::render(frame, area, &composer, true);
        return;
    }

    let line = match &app.flash {
        Some(flash) => Line::from(vec![
            Span::styled(
                if flash.ok { " ✓ " } else { " ✗ " },
                Style::new().fg(if flash.ok { Color::Green } else { Color::Red }),
            ),
            Span::raw(clip(&flash.text, area.width.saturating_sub(4) as usize)),
        ]),
        None => Line::styled(" press : to type a command, ? for help", dim()),
    };
    frame.render_widget(Paragraph::new(line), area);
}

fn draw_hints(frame: &mut Frame, area: Rect, app: &App) {
    let hints = match (app.tab, app.focus) {
        _ if app.bar.is_some() => "Enter run · Esc cancel",
        (Tab::Users, _) => {
            "↑↓ select · k kick · x disconnect · b ban · m message · w wall · Tab next · q quit"
        }
        (Tab::Channels, Focus::Channels) => {
            "↑↓ select · → members · t topic · n say · c close · w wall · Tab next · q quit"
        }
        (Tab::Channels, Focus::Members) => {
            "↑↓ select · ← back · k kick · o op/deop · x disconnect · b ban · q quit"
        }
        (Tab::Log, _) => "↑↓ PgUp PgDn scroll · End latest · Tab next · q quit",
    };
    frame.render_widget(
        Paragraph::new(Line::styled(
            format!(" {}", clip(hints, area.width as usize - 1)),
            dim(),
        )),
        area,
    );
}

fn draw_help(frame: &mut Frame, app: &App) {
    let mut lines = vec![
        Line::styled("Commands (press : first)", bold()),
        Line::raw(""),
    ];
    lines.extend(help_lines(HELP));
    lines.push(Line::raw(""));
    lines.push(Line::styled("Keys", bold()));
    lines.push(Line::raw(""));
    lines.extend(help_lines(&[
        ("1 2 3 / Tab", "switch tab"),
        ("↑ ↓ PgUp PgDn", "move the selection"),
        (
            "k  x  b  m",
            "kick · disconnect · ban · message the selected person",
        ),
        ("o", "operator on/off for the selected member"),
        ("t  n  c", "topic · say · close the selected channel"),
        ("w  M  u", "wall · edit the message of the day · unban"),
        ("q / Ctrl-C", "stop the server (asks first / at once)"),
    ]));
    lines.push(Line::raw(""));
    lines.push(Line::styled("Connecting", bold()));
    lines.push(Line::raw(""));
    lines.push(Line::raw(format!("  {}", app.info.connect)));
    lines.push(Line::styled(
        format!("  certificate to trust: {}", app.info.anchor),
        dim(),
    ));
    widgets::popup(frame, "Help — Esc to close", Text::from(lines));
}

#[cfg(test)]
mod tests;
