//! The text box at the bottom of both screens.
//!
//! It used to be an outlined box with a title, which is the least inviting way
//! to ask someone to type: four lines of border around a blank row, and the
//! only hint that it takes input is that it is the thing at the bottom. A
//! messenger's composer does it the other way round, and this follows that —
//! one soft filled bar with rounded ends and no outline, the target on the
//! left like the attach button, a muted placeholder that says what typing here
//! will do, and a quiet hint on the right where the send button would be.
//!
//! The rounding is made of half blocks. The row above the text is `▄` and the
//! row below is `▀`, in the bar's colour on the terminal's own background, so
//! the fill appears to start and stop half a row beyond the text; the two end
//! caps are `▐` and `▌`. Block elements are in every terminal font that has any
//! box-drawing at all, and unlike a border they take no part of the row the text
//! is typed on.
//!
//! The colours are indexed rather than named, and the text colour is set rather
//! than inherited. The bar is dark in every theme, so text left to the
//! terminal's default would be black on dark grey in a light theme.

use ratatui::layout::{Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::widgets::{Block, Paragraph};
use ratatui::Frame;
use tui_input::Input;
use unicode_width::UnicodeWidthStr;

use crate::widgets::ACCENT;

const FILL: Color = Color::Indexed(236);
const TEXT: Color = Color::Indexed(253);
const MUTED: Color = Color::Indexed(245);

/// Less room than this for the text and the label and the hint go first: being
/// able to see what you type matters more than being told where it goes.
const MIN_TEXT: u16 = 8;

pub struct Composer<'a> {
    pub input: &'a Input,
    /// Where a line typed now goes: `#rust`, `bob`, `:`. Empty for nowhere.
    pub label: &'a str,
    /// Shown while the line is empty.
    pub placeholder: &'a str,
    /// Shown on the right while there is something to send.
    pub hint: &'a str,
}

/// Where each piece of the bar goes.
#[derive(Debug, PartialEq, Eq)]
pub struct Places {
    pub top: Rect,
    pub middle: Rect,
    pub bottom: Rect,
    pub label: Rect,
    pub text: Rect,
    pub hint: Rect,
}

/// Lay the bar out in `area`: a margin of one column each side, the three rows
/// of the pill when there are three to spare and only the text row when there
/// are not, and the text given whatever the label and hint leave.
pub fn places(area: Rect, label_width: u16, hint_width: u16) -> Places {
    let margin = u16::from(area.width >= 6);
    let bar = Rect {
        x: area.x + margin,
        width: area.width - 2 * margin,
        ..area
    };
    let row = |dy: u16| Rect {
        y: bar.y + dy,
        height: 1,
        ..bar
    };
    let none = Rect { height: 0, ..bar };
    let (top, middle, bottom) = if bar.height >= 3 {
        (row(0), row(1), row(2))
    } else {
        (none, row(0), none)
    };

    // The end caps take a column each; a space of padding sits inside them.
    let inner = Rect {
        x: middle.x + 1,
        width: middle.width.saturating_sub(2),
        ..middle
    };
    let room = |label: u16, hint: u16| {
        let taken = 2 + if label > 0 { label + 1 } else { 0 } + if hint > 0 { hint + 1 } else { 0 };
        inner.width.saturating_sub(taken)
    };
    let (mut label, mut hint) = (label_width, hint_width);
    if room(label, hint) < MIN_TEXT {
        hint = 0;
    }
    if room(label, hint) < MIN_TEXT {
        label = 0;
    }

    let label_x = inner.x + 1;
    let text_x = label_x + if label > 0 { label + 1 } else { 0 };
    let text_width = room(label, hint);
    Places {
        top,
        middle,
        bottom,
        label: Rect {
            x: label_x,
            width: label,
            ..inner
        },
        text: Rect {
            x: text_x,
            width: text_width,
            ..inner
        },
        hint: Rect {
            x: (inner.x + inner.width).saturating_sub(1 + hint),
            width: hint,
            ..inner
        },
    }
}

/// Draw the bar and, if `cursor` says so, put the terminal's cursor in it.
///
/// `cursor` is false while something is on top of the bar: the cursor belongs
/// to whatever has the keys, and one blinking under a popup says the wrong thing.
pub fn render(frame: &mut Frame, area: Rect, composer: &Composer, cursor: bool) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let chip = if composer.label.is_empty() {
        String::new()
    } else {
        format!("{} ›", composer.label)
    };
    let has_text = !composer.input.value().is_empty();
    let hint = if has_text { composer.hint } else { "" };
    let at = places(area, chip.width() as u16, hint.width() as u16);

    let edge = Style::new().fg(FILL);
    let across = |glyph: &str, r: Rect| {
        // Without the corners, so the ends of the bar are rounded off.
        glyph.repeat(r.width.saturating_sub(2) as usize)
    };
    if at.top.height > 0 {
        let r = Rect {
            x: at.top.x + 1,
            width: at.top.width.saturating_sub(2),
            ..at.top
        };
        frame.render_widget(Paragraph::new(across("▄", at.top)).style(edge), r);
        let r = Rect {
            x: at.bottom.x + 1,
            width: at.bottom.width.saturating_sub(2),
            ..at.bottom
        };
        frame.render_widget(Paragraph::new(across("▀", at.bottom)).style(edge), r);
    }

    // The fill, then the caps over its two end columns.
    frame.render_widget(
        Block::new().style(Style::new().bg(FILL).fg(TEXT)),
        Rect {
            x: at.middle.x + 1,
            width: at.middle.width.saturating_sub(2),
            ..at.middle
        },
    );
    if at.middle.width >= 2 {
        let left = Rect {
            width: 1,
            ..at.middle
        };
        let right = Rect {
            x: at.middle.x + at.middle.width - 1,
            width: 1,
            ..at.middle
        };
        frame.render_widget(Paragraph::new("▐").style(edge), left);
        frame.render_widget(Paragraph::new("▌").style(edge), right);
    }

    if at.label.width > 0 {
        frame.render_widget(
            Paragraph::new(chip).style(
                Style::new()
                    .fg(ACCENT)
                    .bg(FILL)
                    .add_modifier(Modifier::BOLD),
            ),
            at.label,
        );
    }
    if at.hint.width > 0 {
        frame.render_widget(
            Paragraph::new(hint).style(Style::new().fg(MUTED).bg(FILL)),
            at.hint,
        );
    }

    if at.text.width == 0 {
        return;
    }
    if has_text {
        let scroll = composer.input.visual_scroll(at.text.width as usize);
        frame.render_widget(
            Paragraph::new(composer.input.value())
                .scroll((0, scroll as u16))
                .style(Style::new().fg(TEXT).bg(FILL)),
            at.text,
        );
        if cursor {
            let column = composer.input.visual_cursor().saturating_sub(scroll) as u16;
            frame.set_cursor_position(Position::new(
                (at.text.x + column).min(at.text.x + at.text.width - 1),
                at.text.y,
            ));
        }
    } else {
        frame.render_widget(
            Paragraph::new(composer.placeholder).style(
                Style::new()
                    .fg(MUTED)
                    .bg(FILL)
                    .add_modifier(Modifier::ITALIC),
            ),
            at.text,
        );
        // The cursor sits at the start of the placeholder, as it does in a
        // messenger: the hint is something to type over, not something to skip.
        if cursor {
            frame.set_cursor_position(Position::new(at.text.x, at.text.y));
        }
    }
}

#[cfg(test)]
mod tests {
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    use super::*;

    fn draw(input: &Input, width: u16, height: u16) -> (String, Option<Position>) {
        let composer = Composer {
            input,
            label: "#rust",
            placeholder: "Write a message…",
            hint: "↵ send",
        };
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal
            .draw(|frame| render(frame, frame.area(), &composer, true))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let mut out = String::new();
        for y in 0..buffer.area.height {
            for x in 0..buffer.area.width {
                out.push_str(buffer[(x, y)].symbol());
            }
            out.push('\n');
        }
        let cursor = terminal.get_cursor_position().ok();
        (out, cursor)
    }

    #[test]
    fn the_bar_has_no_outline_and_rounded_ends() {
        let (screen, _) = draw(&Input::default(), 40, 3);
        let rows: Vec<&str> = screen.lines().collect();

        assert!(rows[0].contains('▄') && rows[2].contains('▀'), "{screen}");
        assert!(
            rows[1].starts_with(" ▐") && rows[1].trim_end().ends_with('▌'),
            "{screen}"
        );
        // The corners of the top and bottom rows are left empty: that is the rounding.
        assert!(
            rows[0].starts_with("  ") && rows[2].starts_with("  "),
            "{screen}"
        );
        // Nothing of a box: no line-drawing characters anywhere.
        assert!(!screen.contains(['│', '─', '┌', '└', '┐', '┘']), "{screen}");
    }

    #[test]
    fn an_empty_bar_says_what_typing_will_do_and_nothing_more() {
        let (screen, cursor) = draw(&Input::default(), 50, 3);
        assert!(screen.contains("#rust ›"), "{screen}");
        assert!(screen.contains("Write a message…"), "{screen}");
        assert!(!screen.contains("↵ send"), "nothing to send yet\n{screen}");
        // The cursor is at the start of the text area, on the middle row.
        let at = cursor.unwrap();
        assert_eq!(at.y, 1);
        let middle: Vec<char> = screen.lines().nth(1).unwrap().chars().collect();
        let placeholder_at = middle.iter().position(|c| *c == 'W').unwrap() as u16;
        assert_eq!(at.x, placeholder_at);
    }

    #[test]
    fn typing_replaces_the_placeholder_and_offers_to_send() {
        let (screen, cursor) = draw(&Input::new("hello".to_owned()), 50, 3);
        assert!(screen.contains("hello"), "{screen}");
        assert!(!screen.contains("Write a message"), "{screen}");
        assert!(screen.contains("↵ send"), "{screen}");
        let middle: Vec<char> = screen.lines().nth(1).unwrap().chars().collect();
        let start = middle.iter().position(|c| *c == 'h').unwrap() as u16;
        assert_eq!(cursor.unwrap().x, start + 5, "the cursor follows the text");
    }

    #[test]
    fn a_long_line_scrolls_so_the_cursor_stays_in_the_bar() {
        let long = "x".repeat(200);
        let (screen, cursor) = draw(&Input::new(long), 40, 3);
        let at = cursor.unwrap();
        assert!(at.x < 40 && at.y == 1, "{at:?}");
        assert!(screen.lines().nth(1).unwrap().contains("xxxx"));
    }

    #[test]
    fn the_label_and_hint_give_way_before_the_text_does() {
        let narrow = places(Rect::new(0, 0, 20, 3), 7, 6);
        assert_eq!(narrow.hint.width, 0, "the hint goes first");
        assert!(narrow.text.width >= MIN_TEXT);

        let tiny = places(Rect::new(0, 0, 14, 3), 7, 6);
        assert_eq!(tiny.label.width, 0, "then the label");
        assert!(tiny.text.width >= MIN_TEXT || tiny.text.width == 14 - 2 - 2 - 2);

        let roomy = places(Rect::new(0, 0, 80, 3), 7, 6);
        assert_eq!((roomy.label.width, roomy.hint.width), (7, 6));
        assert!(roomy.label.x < roomy.text.x && roomy.text.right() < roomy.hint.x);
    }

    #[test]
    fn with_less_than_three_rows_only_the_text_row_is_drawn() {
        let p = places(Rect::new(0, 0, 40, 1), 5, 0);
        assert_eq!(p.top.height, 0);
        assert_eq!(p.middle.height, 1);
        let (screen, _) = draw(&Input::default(), 40, 1);
        assert!(screen.contains("Write a message"), "{screen}");
    }

    #[test]
    fn no_size_panics() {
        for width in 0..30 {
            for height in 0..5 {
                let _ = draw(&Input::new("abc".to_owned()), width, height);
                let _ = draw(&Input::default(), width, height);
            }
        }
    }

    #[test]
    fn the_text_row_is_filled_edge_to_edge_and_the_rows_around_it_are_not() {
        let composer = Composer {
            input: &Input::default(),
            label: "#rust",
            placeholder: "Write a message…",
            hint: "",
        };
        let mut terminal = Terminal::new(TestBackend::new(40, 3)).unwrap();
        terminal
            .draw(|frame| render(frame, frame.area(), &composer, true))
            .unwrap();
        let buffer = terminal.backend().buffer();

        // Between the caps, every cell of the middle row has the bar's colour
        // behind it, text or not: that is what makes it read as one surface.
        for x in 2..38 {
            assert_eq!(buffer[(x, 1)].bg, FILL, "column {x}");
        }
        // The rows above and below draw the fill with the *foreground*, so the
        // terminal's own background shows through around the rounded ends.
        for x in 0..40 {
            assert_ne!(buffer[(x, 0)].bg, FILL, "top row, column {x}");
            assert_ne!(buffer[(x, 2)].bg, FILL, "bottom row, column {x}");
        }
        assert_eq!(buffer[(5, 0)].fg, FILL);
        // The text is readable on it whatever the terminal's theme.
        let w = (0..40).find(|&x| buffer[(x, 1)].symbol() == "W").unwrap();
        assert_eq!(buffer[(w, 1)].fg, MUTED);
    }
}
