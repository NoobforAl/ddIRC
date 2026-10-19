//! Shortcuts that work on any keyboard layout.
//!
//! A terminal reports the *character* a key produced, not which key it was. On a
//! Persian layout the key that is `c` on a US keyboard produces `ز`, so Ctrl-C
//! arrives as Ctrl-ز and nothing that matches on `'c'` fires — the program
//! cannot be quit from the keyboard it is being used on. The same goes for every
//! one-letter shortcut in the server manager.
//!
//! The fix is to put the key back where it was. Each table below lists, for one
//! layout, the character on each of the 26 Latin letter keys, in the order of
//! [`QWERTY`]; a character found in a table stands for the Latin letter at the
//! same position. That is a statement about where the key is, which is what a
//! shortcut means: Ctrl-C is the key to the right of X, whatever is printed on it.
//!
//! It is applied only where a key is a command and never where it is text. In
//! the input line a Persian letter is a Persian letter; in a chord (Ctrl or Alt
//! held) or in a screen with no input to type into, it is a shortcut. Getting
//! that line wrong in either direction is worse than not doing this at all: one
//! way shortcuts stay dead, the other way nobody can type in their own language.
//!
//! Layouts covered are the common non-Latin ones. A key a layout puts something
//! on that is not a single letter (Arabic's `لا`, Greek's `;`) is left out
//! (`\0`), because mapping punctuation would break the punctuation.

use ratatui::crossterm::event::{KeyCode, KeyEvent};

/// The Latin letter keys, in the order each table below lists them.
const QWERTY: &str = "qwertyuiopasdfghjklzxcvbnm";

const LAYOUTS: &[&str] = &[
    // Persian (ISIRI 9147)
    "ضصثقفغعهخحشسیبلاتنمظطزرذدپ",
    // Arabic (101)
    "ضصثقفغعهخحشسيبلاتنمئءؤر\0ىة",
    // Russian (ЙЦУКЕН)
    "йцукенгшщзфывапролдячсмить",
    // Greek
    "\0ςερτυθιοπασδφγηξκλζχψωβνμ",
    // Hebrew
    "\0\0קראטוןםפשדגכעיחלךזסבהנמצ",
];

/// The Latin letter on the key that produces `c` on some known layout.
///
/// Upper case stays upper case, so Shift on a layout that has capitals (Russian,
/// Greek) still reaches `M`. Returns `None` for anything not in a table,
/// including every ASCII character.
pub fn latin(c: char) -> Option<char> {
    if c.is_ascii() {
        return None;
    }
    let lower = c.to_lowercase().next()?;
    let letters: Vec<char> = QWERTY.chars().collect();
    for layout in LAYOUTS {
        if let Some(at) = layout.chars().position(|k| k == lower && k != '\0') {
            let letter = letters[at];
            return Some(if c == lower {
                letter
            } else {
                letter.to_ascii_uppercase()
            });
        }
    }
    None
}

/// `key`, with its character put back on the Latin key it was typed on.
pub fn shortcut(key: KeyEvent) -> KeyEvent {
    match key.code {
        KeyCode::Char(c) => match latin(c) {
            Some(letter) => KeyEvent {
                code: KeyCode::Char(letter),
                ..key
            },
            None => key,
        },
        _ => key,
    }
}

#[cfg(test)]
mod tests {
    use ratatui::crossterm::event::KeyModifiers;

    use super::*;

    #[test]
    fn every_table_has_a_character_for_each_of_the_26_keys() {
        for layout in LAYOUTS {
            assert_eq!(layout.chars().count(), 26, "{layout}");
        }
    }

    #[test]
    fn no_character_is_two_different_letters() {
        // Several layouts share characters (Persian and Arabic both put `ش` on
        // A), which is fine; one character meaning two keys is not.
        let letters: Vec<char> = QWERTY.chars().collect();
        let mut seen: std::collections::HashMap<char, char> = std::collections::HashMap::new();
        for layout in LAYOUTS {
            for (at, c) in layout.chars().enumerate() {
                if c == '\0' {
                    continue;
                }
                if let Some(previous) = seen.insert(c, letters[at]) {
                    assert_eq!(previous, letters[at], "{c} is on two keys");
                }
            }
        }
    }

    #[test]
    fn the_key_that_broke_ctrl_c_is_put_back() {
        // Observed: Ctrl-C on a Persian layout arrives as Ctrl-ز.
        assert_eq!(latin('ز'), Some('c'));
        let key = KeyEvent::new(KeyCode::Char('ز'), KeyModifiers::CONTROL);
        let fixed = shortcut(key);
        assert_eq!(fixed.code, KeyCode::Char('c'));
        assert_eq!(
            fixed.modifiers,
            KeyModifiers::CONTROL,
            "the modifiers ride along"
        );
    }

    #[test]
    fn the_other_layouts_land_on_the_same_keys() {
        assert_eq!(latin('с'), Some('c')); // Russian
        assert_eq!(latin('ψ'), Some('c')); // Greek
        assert_eq!(latin('ב'), Some('c')); // Hebrew
        assert_eq!(latin('ؤ'), Some('c')); // Arabic
        assert_eq!(latin('ط'), Some('x')); // Persian
        assert_eq!(latin('د'), Some('n'));
    }

    #[test]
    fn capitals_stay_capitals() {
        assert_eq!(latin('Ь'), Some('M'));
        assert_eq!(latin('ь'), Some('m'));
    }

    #[test]
    fn latin_letters_and_punctuation_are_never_touched() {
        for c in "abcxyzABC:/?;'1 ".chars() {
            assert_eq!(latin(c), None, "{c:?}");
        }
        let key = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(shortcut(key), key);
        let key = KeyEvent::new(KeyCode::F(1), KeyModifiers::NONE);
        assert_eq!(shortcut(key), key);
    }

    #[test]
    fn a_character_no_table_knows_is_left_alone() {
        assert_eq!(latin('日'), None);
        assert_eq!(latin('é'), None);
    }
}
