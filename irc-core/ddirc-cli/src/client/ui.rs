//! Where things go on the screen.
//!
//! Reads the [`App`] and draws it; changes nothing but the cursor. Text is laid
//! out here rather than handed to a wrapping widget because the conversation is
//! anchored to its *bottom* — the newest line is always visible, and scrolling
//! moves back from it — and working out how many rows a line takes is the only
//! way to know which lines fit.

use ddirc_core::api::types::ConnectionStatus;
use ddirc_core::text::format::SpanStyle;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line as Row, Span, Text};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph};
use ratatui::Frame;
use unicode_width::UnicodeWidthChar;

use super::model::{App, Buffer, BufferKind, Line, LineKind, Popup};
use crate::composer::{self, Composer};
use crate::widgets::{self, bold, clip, dim, help_lines};

/// Narrower than this and the side panels are left out; the conversation
/// matters more than the list of who else is there.
const MEMBERS_MIN_WIDTH: u16 = 72;
const WINDOWS_MIN_WIDTH: u16 = 46;
const WINDOWS_WIDTH: u16 = 22;
const MEMBERS_WIDTH: u16 = 20;

pub fn draw(frame: &mut Frame, app: &App) {
    let [main, input, status] = Layout::vertical([
        Constraint::Min(3),
        Constraint::Length(3),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    let buffer = app.buffer();
    let windows = main.width >= WINDOWS_MIN_WIDTH;
    let members = main.width >= MEMBERS_MIN_WIDTH && buffer.kind == BufferKind::Channel;

    let mut widths = Vec::new();
    if windows {
        widths.push(Constraint::Length(WINDOWS_WIDTH));
    }
    widths.push(Constraint::Min(10));
    if members {
        widths.push(Constraint::Length(MEMBERS_WIDTH));
    }
    let columns = Layout::horizontal(widths).split(main);
    let mut next = columns.iter().copied();
    if windows {
        draw_windows(frame, next.next().unwrap_or_default(), app);
    }
    draw_conversation(frame, next.next().unwrap_or_default(), buffer);
    if members {
        draw_members(frame, next.next().unwrap_or_default(), buffer);
    }

    draw_input(frame, input, app);
    draw_status(frame, status, app);

    match &app.popup {
        Some(Popup::Help) => draw_help(frame),
        Some(Popup::Channels {
            items,
            selected,
            done,
            truncated,
        }) => draw_channels(frame, items, *selected, *done, *truncated),
        Some(Popup::Whois(whois)) => draw_whois(frame, whois),
        None => {}
    }
}

// ------------------------------------------------------------------- windows

fn draw_windows(frame: &mut Frame, area: Rect, app: &App) {
    let items: Vec<ListItem> = app
        .buffers
        .iter()
        .enumerate()
        .map(|(i, b)| {
            let mut spans = vec![Span::styled(format!("{:>2} ", i + 1), dim())];
            let name = clip(&b.name, area.width.saturating_sub(10) as usize);
            let style = if b.mentioned {
                Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD)
            } else if b.unread > 0 {
                bold()
            } else if b.kind == BufferKind::Server {
                dim()
            } else {
                Style::new()
            };
            spans.push(Span::styled(name, style));
            if b.unread > 0 {
                spans.push(Span::styled(format!(" {}", b.unread), style));
            }
            ListItem::new(Row::from(spans))
        })
        .collect();

    let list = List::new(items)
        .block(Block::new().borders(Borders::RIGHT).border_style(dim()))
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    let mut state = ListState::default().with_selected(Some(app.current));
    frame.render_stateful_widget(list, area, &mut state);
}

// ------------------------------------------------------------------ members

fn draw_members(frame: &mut Frame, area: Rect, buffer: &Buffer) {
    let items: Vec<ListItem> = buffer
        .members
        .iter()
        .map(|m| {
            let prefix = m.prefix.as_deref().unwrap_or(" ");
            let style = if m.away {
                dim()
            } else if m.prefix.is_some() {
                Style::new().fg(Color::Green)
            } else {
                Style::new()
            };
            ListItem::new(Row::from(vec![
                Span::styled(prefix.to_owned(), Style::new().fg(Color::Green)),
                Span::styled(clip(&m.nick, area.width.saturating_sub(4) as usize), style),
            ]))
        })
        .collect();
    let block = Block::new()
        .borders(Borders::LEFT)
        .border_style(dim())
        .title(Row::styled(format!(" {} ", buffer.members.len()), dim()));
    frame.render_widget(List::new(items).block(block), area);
}

// ------------------------------------------------------------- conversation

fn draw_conversation(frame: &mut Frame, area: Rect, buffer: &Buffer) {
    let title = match (&buffer.kind, &buffer.topic) {
        (_, Some(topic)) => Row::from(vec![
            Span::styled(format!(" {} ", buffer.name), bold()),
            Span::styled(
                clip(
                    topic,
                    area.width.saturating_sub(buffer.name.len() as u16 + 6) as usize,
                ),
                dim(),
            ),
        ]),
        _ => Row::styled(format!(" {} ", buffer.name), bold()),
    };
    let mut block = Block::new().borders(Borders::BOTTOM).border_style(dim());
    // Over the border rather than inside it, so the conversation gets every row.
    let [header, body] = Layout::vertical([Constraint::Length(1), Constraint::Min(1)]).areas(area);
    frame.render_widget(Paragraph::new(title), header);
    if buffer.scroll > 0 {
        block = block.title_bottom(
            Row::styled(
                format!(" ↓ {} newer ", buffer.scroll),
                Style::new().fg(Color::Yellow),
            )
            .right_aligned(),
        );
    }
    let inner = block.inner(body);
    frame.render_widget(block, body);

    let rows = visible_rows(buffer, inner.width as usize, inner.height as usize);
    frame.render_widget(Paragraph::new(rows), inner);
}

/// The rows to show: the newest that fit, below any lines scrolled off.
fn visible_rows(buffer: &Buffer, width: usize, height: usize) -> Vec<Row<'static>> {
    let width = width.max(1);
    let end = buffer.lines.len().saturating_sub(buffer.scroll);
    let mut rows: Vec<Row<'static>> = Vec::new();
    // From the bottom up, stopping as soon as the screen is full: a long
    // scrollback is never laid out to show the last forty rows of it.
    for line in buffer.lines.iter().take(end).rev() {
        let mut laid = layout(line, width);
        laid.reverse();
        rows.extend(laid);
        if rows.len() >= height {
            break;
        }
    }
    rows.truncate(height);
    rows.reverse();
    rows
}

type Cell = (char, Style);

/// One line as the rows it takes at this width.
pub fn layout(line: &Line, width: usize) -> Vec<Row<'static>> {
    let (head, indent) = head(line);
    let mut cells: Vec<Cell> = Vec::new();
    for (c, style) in head {
        cells.push((c, style));
    }
    let body_style = match line.kind {
        LineKind::Error => Style::new().fg(Color::Red),
        LineKind::Info | LineKind::Join | LineKind::Part => dim(),
        _ if line.mention => Style::new().fg(Color::Yellow),
        _ => Style::new(),
    };
    for span in &line.body {
        let style = span_style(&span.style, body_style);
        cells.extend(span.text.chars().map(|c| (c, style)));
    }
    wrap(&cells, width, indent)
        .into_iter()
        .map(|row| Row::from(merge(row)))
        .collect()
}

/// The part of a line before its words — and how far to hang what follows.
fn head(line: &Line) -> (Vec<Cell>, usize) {
    let styled =
        |text: String, style: Style| -> Vec<Cell> { text.chars().map(|c| (c, style)).collect() };
    let nick_style = Style::new()
        .fg(nick_color(&line.who))
        .add_modifier(if line.own {
            Modifier::BOLD
        } else {
            Modifier::empty()
        });
    match line.kind {
        LineKind::Chat => {
            let mut cells = styled("<".into(), dim());
            cells.extend(styled(line.prefix.clone(), Style::new().fg(Color::Green)));
            cells.extend(styled(line.who.clone(), nick_style));
            cells.extend(styled("> ".into(), dim()));
            (cells, 2)
        }
        LineKind::Action => {
            let mut cells = styled("* ".into(), Style::new().fg(Color::Magenta));
            cells.extend(styled(line.who.clone(), nick_style));
            cells.extend(styled(" ".into(), Style::new()));
            (cells, 2)
        }
        LineKind::Notice => {
            let mut cells = styled("-".into(), dim());
            cells.extend(styled(line.who.clone(), nick_style));
            cells.extend(styled("- ".into(), dim()));
            (cells, 2)
        }
        LineKind::Join => (styled("→ ".into(), Style::new().fg(Color::Green)), 2),
        LineKind::Part => (styled("← ".into(), Style::new().fg(Color::Red)), 2),
        LineKind::Info => (styled("· ".into(), dim()), 2),
        LineKind::Error => (styled("! ".into(), Style::new().fg(Color::Red)), 2),
    }
}

/// Break `cells` into rows no wider than `width` columns, at spaces where there
/// is one to break at. Rows after the first are indented.
fn wrap(cells: &[Cell], width: usize, indent: usize) -> Vec<Vec<Cell>> {
    let indent = indent.min(width.saturating_sub(1));
    let mut rows: Vec<Vec<Cell>> = Vec::new();
    let mut start = 0;
    while start < cells.len() {
        let room = if rows.is_empty() {
            width
        } else {
            width - indent
        };
        let (mut used, mut end, mut space) = (0, start, None);
        while end < cells.len() {
            let w = cells[end].0.width().unwrap_or(0);
            if used + w > room {
                break;
            }
            if cells[end].0 == ' ' {
                space = Some(end);
            }
            used += w;
            end += 1;
        }

        let mut row: Vec<Cell> = if rows.is_empty() {
            Vec::new()
        } else {
            vec![(' ', Style::new()); indent]
        };
        if end == cells.len() {
            row.extend_from_slice(&cells[start..end]);
            rows.push(row);
            break;
        }
        // Prefer a word boundary; failing that, break mid-word rather than
        // overflow; and always take at least one character so it terminates.
        let cut = match space {
            Some(at) if at > start => at,
            _ if end > start => end,
            _ => start + 1,
        };
        row.extend_from_slice(&cells[start..cut]);
        rows.push(row);
        start = cut;
        while cells.get(start).is_some_and(|(c, _)| *c == ' ') {
            start += 1;
        }
    }
    if rows.is_empty() {
        rows.push(Vec::new());
    }
    rows
}

/// Runs of cells with one style, as spans.
fn merge(row: Vec<Cell>) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut run = String::new();
    let mut run_style = Style::new();
    for (c, style) in row {
        if !run.is_empty() && style != run_style {
            spans.push(Span::styled(std::mem::take(&mut run), run_style));
        }
        run_style = style;
        run.push(c);
    }
    if !run.is_empty() {
        spans.push(Span::styled(run, run_style));
    }
    spans
}

fn span_style(style: &SpanStyle, base: Style) -> Style {
    let mut out = base;
    if style.bold {
        out = out.add_modifier(Modifier::BOLD);
    }
    if style.italic {
        out = out.add_modifier(Modifier::ITALIC);
    }
    if style.underline {
        out = out.add_modifier(Modifier::UNDERLINED);
    }
    if style.strikethrough {
        out = out.add_modifier(Modifier::CROSSED_OUT);
    }
    if style.inverse {
        out = out.add_modifier(Modifier::REVERSED);
    }
    if let Some(color) = style.fg.and_then(mirc_color) {
        out = out.fg(color);
    }
    if let Some(color) = style.bg.and_then(mirc_color) {
        out = out.bg(color);
    }
    out
}

/// mIRC's sixteen colours as the terminal's own, so a user's theme applies.
/// The rest of its 99 are not worth guessing at.
fn mirc_color(index: u8) -> Option<Color> {
    Some(match index {
        0 => Color::White,
        1 => Color::Black,
        2 => Color::Blue,
        3 => Color::Green,
        4 => Color::LightRed,
        5 => Color::Red,
        6 => Color::Magenta,
        7 => Color::Yellow,
        8 => Color::LightYellow,
        9 => Color::LightGreen,
        10 => Color::Cyan,
        11 => Color::LightCyan,
        12 => Color::LightBlue,
        13 => Color::LightMagenta,
        14 => Color::DarkGray,
        15 => Color::Gray,
        _ => return None,
    })
}

/// The same colour for the same person, every time, everywhere.
fn nick_color(nick: &str) -> Color {
    const PALETTE: [Color; 8] = [
        Color::Cyan,
        Color::Green,
        Color::Yellow,
        Color::Magenta,
        Color::LightBlue,
        Color::LightRed,
        Color::LightGreen,
        Color::LightCyan,
    ];
    let hash = nick.to_ascii_lowercase().bytes().fold(5381usize, |h, b| {
        h.wrapping_mul(33).wrapping_add(b as usize)
    });
    PALETTE[hash % PALETTE.len()]
}

// -------------------------------------------------------------- input, status

fn draw_input(frame: &mut Frame, area: Rect, app: &App) {
    // The window you are in is where a line goes, so it is the label; the
    // server window is nowhere, and its placeholder says how to get somewhere.
    let (label, placeholder) = match app.target() {
        Some(target) => (target, "Write a message…"),
        None => ("", "Nobody to talk to here yet — try /join #channel"),
    };
    let composer = Composer {
        input: &app.input,
        label,
        placeholder,
        hint: "↵ send",
    };
    // No cursor while something is on top: it belongs to whatever has the keys.
    composer::render(frame, area, &composer, app.popup.is_none());
}

fn draw_status(frame: &mut Frame, area: Rect, app: &App) {
    let (dot, label) = match &app.status {
        ConnectionStatus::Connected => (Color::Green, "connected".to_owned()),
        ConnectionStatus::Connecting => (Color::Yellow, "connecting…".to_owned()),
        ConnectionStatus::Registering => (Color::Yellow, "registering…".to_owned()),
        ConnectionStatus::Reconnecting {
            retry_in_secs,
            attempt,
        } => (
            Color::Yellow,
            format!("reconnecting in {retry_in_secs}s (attempt {attempt})"),
        ),
        ConnectionStatus::Disconnected => (Color::Red, "disconnected".to_owned()),
    };
    let network = app
        .network
        .as_deref()
        .unwrap_or(app.buffers[0].name.as_str());
    let left = Row::from(vec![
        Span::styled(" ● ", Style::new().fg(dot)),
        Span::raw(format!("{label} · {network} · {}", app.nick)),
    ]);
    let hints = "F1 help · Ctrl-N/P windows · PgUp/PgDn scroll · Ctrl-C quit ";
    let [l, r] = Layout::horizontal([
        Constraint::Min(10),
        Constraint::Length((hints.chars().count() as u16).min(area.width.saturating_sub(12))),
    ])
    .areas(area);
    frame.render_widget(Paragraph::new(left), l);
    frame.render_widget(
        Paragraph::new(Row::styled(clip(hints, r.width as usize), dim())).right_aligned(),
        r,
    );
}

// ------------------------------------------------------------------- popups

fn draw_help(frame: &mut Frame) {
    let mut lines = vec![Row::styled("Commands", bold()), Row::raw("")];
    lines.extend(help_lines(super::commands::HELP));
    lines.push(Row::raw(""));
    lines.push(Row::styled("Keys", bold()));
    lines.push(Row::raw(""));
    lines.extend(help_lines(&[
        ("Enter", "send"),
        ("Tab", "complete a nick (again for the next)"),
        ("Up / Down", "earlier lines you typed"),
        ("PgUp / PgDn", "scroll the conversation"),
        ("Ctrl-N / Ctrl-P", "next / previous window"),
        ("Alt-1 … Alt-9", "jump to a window"),
        ("Esc", "clear the line"),
        ("Ctrl-C", "quit"),
    ]));
    widgets::popup(frame, "Help — Esc to close", Text::from(lines));
}

fn draw_channels(
    frame: &mut Frame,
    items: &[ddirc_core::api::types::ChannelListing],
    selected: usize,
    done: bool,
    truncated: bool,
) {
    let area = frame.area();
    let height = (area.height.saturating_sub(6)).clamp(3, 22) as usize;
    let first = selected.saturating_sub(height.saturating_sub(1));
    let width = (area.width.saturating_sub(10)).clamp(30, 90) as usize;

    let mut lines: Vec<Row> = Vec::new();
    if items.is_empty() {
        lines.push(Row::styled(
            if done {
                "no channels"
            } else {
                "asking the server…"
            },
            dim(),
        ));
    }
    for (i, c) in items.iter().enumerate().skip(first).take(height) {
        let text = clip(
            &format!("{:>5}  {:<22} {}", c.users, c.name, c.topic),
            width,
        );
        let style = if i == selected {
            Style::new().add_modifier(Modifier::REVERSED)
        } else {
            Style::new()
        };
        lines.push(Row::styled(text, style));
    }
    lines.push(Row::raw(""));
    let note = match (done, truncated) {
        (false, _) => "still arriving · ",
        (true, true) => "the busiest of many · ",
        (true, false) => "",
    };
    lines.push(Row::styled(
        format!("{note}↑↓ choose · Enter join · Esc close"),
        dim(),
    ));
    widgets::popup(frame, "Channels", Text::from(lines));
}

fn draw_whois(frame: &mut Frame, whois: &ddirc_core::api::types::WhoisInfo) {
    let mut lines: Vec<Row> = Vec::new();
    if !whois.found {
        lines.push(Row::raw(format!("No such nick: {}", whois.nick)));
    } else {
        let field = |name: &str, value: String| {
            Row::from(vec![
                Span::styled(format!("{name:<10}"), dim()),
                Span::raw(value),
            ])
        };
        lines.push(field("nick", whois.nick.clone()));
        if let (Some(user), Some(host)) = (&whois.user, &whois.host) {
            lines.push(field("address", format!("{user}@{host}")));
        }
        if let Some(real) = &whois.realname {
            lines.push(field("name", real.clone()));
        }
        if let Some(server) = &whois.server {
            lines.push(field("server", server.clone()));
        }
        if let Some(account) = &whois.account {
            lines.push(field("account", account.clone()));
        }
        if !whois.channels.is_empty() {
            lines.push(field("channels", whois.channels.join(" ")));
        }
        if let Some(idle) = whois.idle_secs {
            lines.push(field("idle", widgets::age(idle)));
        }
        if let Some(away) = &whois.away {
            lines.push(field("away", away.clone()));
        }
        if whois.secure {
            lines.push(field("", "connected securely".to_owned()));
        }
    }
    widgets::popup(frame, "Whois — Esc to close", Text::from(lines));
}

#[cfg(test)]
mod tests;
