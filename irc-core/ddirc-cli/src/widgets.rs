//! Small pieces both interfaces draw with.

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::Frame;
use tui_popup::Popup;
use unicode_width::UnicodeWidthStr;

/// The one accent colour, so the two interfaces look like one program.
pub const ACCENT: Color = Color::Cyan;

pub fn dim() -> Style {
    Style::new().fg(Color::DarkGray)
}

pub fn bold() -> Style {
    Style::new().add_modifier(Modifier::BOLD)
}

/// A centred box sized to its contents, over whatever is underneath.
pub fn popup(frame: &mut Frame, title: &str, body: Text<'static>) {
    let widget = Popup::new(body)
        .title(format!(" {title} "))
        .border_style(Style::new().fg(ACCENT));
    frame.render_widget(widget, frame.area());
}

/// A two-column help table: keys in the accent colour, then what they do.
pub fn help_lines(rows: &[(&str, &str)]) -> Vec<Line<'static>> {
    let width = rows.iter().map(|(k, _)| k.width()).max().unwrap_or(0);
    rows.iter()
        .map(|(keys, what)| {
            Line::from(vec![
                Span::styled(format!("{keys:<width$}  "), Style::new().fg(ACCENT)),
                Span::raw((*what).to_owned()),
            ])
        })
        .collect()
}

/// Cut `text` to at most `max` columns, ending in `…` if anything was lost.
pub fn clip(text: &str, max: usize) -> String {
    if text.width() <= max {
        return text.to_owned();
    }
    let mut out = String::new();
    let mut used = 0;
    for c in text.chars() {
        let w = unicode_width::UnicodeWidthChar::width(c).unwrap_or(0);
        if used + w + 1 > max {
            break;
        }
        out.push(c);
        used += w;
    }
    out.push('…');
    out
}

/// `HH:MM:SS` in UTC. UTC on purpose: it needs no timezone database, and a log
/// that two people read in different places agrees with itself.
pub fn clock(epoch_secs: u64) -> String {
    let day = epoch_secs % 86_400;
    format!("{:02}:{:02}:{:02}", day / 3600, (day / 60) % 60, day % 60)
}

/// `3d 04h`, `2h 05m`, `4m 09s`, `12s`: the two largest units that apply.
pub fn age(secs: u64) -> String {
    let (d, h, m, s) = (
        secs / 86_400,
        (secs / 3600) % 24,
        (secs / 60) % 60,
        secs % 60,
    );
    if d > 0 {
        format!("{d}d {h:02}h")
    } else if h > 0 {
        format!("{h}h {m:02}m")
    } else if m > 0 {
        format!("{m}m {s:02}s")
    } else {
        format!("{s}s")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_are_read_off_the_clock() {
        assert_eq!(clock(0), "00:00:00");
        assert_eq!(clock(3_661), "01:01:01");
        // A whole number of days later is the same time of day.
        assert_eq!(clock(86_400 * 20_000 + 45_296), "12:34:56");
    }

    #[test]
    fn ages_show_the_two_biggest_units() {
        assert_eq!(age(7), "7s");
        assert_eq!(age(249), "4m 09s");
        assert_eq!(age(7_500), "2h 05m");
        assert_eq!(age(3 * 86_400 + 4 * 3_600 + 59), "3d 04h");
    }

    #[test]
    fn clipping_counts_columns_not_bytes() {
        assert_eq!(clip("short", 10), "short");
        assert_eq!(clip("a long sentence", 6), "a lon…");
        // Wide characters take two columns each.
        assert_eq!(clip("日本語のテキスト", 7), "日本語…");
    }
}
