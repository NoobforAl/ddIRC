//! The terminal, for the two full-screen interfaces.
//!
//! Setup and teardown live in one guard so that leaving by any route — a quit
//! key, an error, a panic — gives the shell back usable. A terminal left in raw
//! mode on the alternate screen is the failure people remember a program by.

use std::io::{self, IsTerminal};
use std::time::Duration;

use ratatui::crossterm::event::{self, Event, KeyEvent, KeyEventKind};
use ratatui::DefaultTerminal;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver};

/// Whether there is a person at both ends: something to read keys from and
/// something to draw on. Redirected output, a pipe, or a cron job is not.
pub fn interactive() -> bool {
    io::stdin().is_terminal() && io::stdout().is_terminal()
}

/// Raw mode and the alternate screen, for as long as this is alive.
pub struct Screen {
    pub terminal: DefaultTerminal,
}

impl Screen {
    /// Also installs a panic hook that restores the terminal before the panic
    /// message is printed — otherwise the message is written onto a screen the
    /// shell is about to clear.
    pub fn enter() -> io::Result<Self> {
        Ok(Self {
            terminal: ratatui::try_init()?,
        })
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        ratatui::restore();
    }
}

/// Keys and resizes, read on a thread of their own.
///
/// Reading the terminal blocks, and doing it on the async runtime would hold a
/// worker for as long as the user does not type. The thread wakes a few times a
/// second to notice that nobody is listening any more, so it does not outlive
/// the screen it was reading for.
pub fn events() -> UnboundedReceiver<Event> {
    let (tx, rx) = unbounded_channel();
    std::thread::spawn(move || loop {
        match event::poll(Duration::from_millis(250)) {
            Ok(true) => match event::read() {
                Ok(event) => {
                    if tx.send(event).is_err() {
                        return;
                    }
                }
                Err(_) => return,
            },
            Ok(false) => {
                if tx.is_closed() {
                    return;
                }
            }
            Err(_) => return,
        }
    });
    rx
}

/// The key, if this event is one being pressed.
///
/// Windows reports a release as well as a press for every key, so handling
/// every key event types each character twice there.
pub fn pressed(event: &Event) -> Option<KeyEvent> {
    match event {
        Event::Key(key) if key.kind != KeyEventKind::Release => Some(*key),
        _ => None,
    }
}
