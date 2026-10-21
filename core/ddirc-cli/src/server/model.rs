//! What the server manager knows, and how it reacts to a key.
//!
//! The same split as the client's: a key goes in and a list of commands for the
//! server comes out, with nothing here touching a terminal.
//!
//! # A selection is a person, not a row
//!
//! The lists are live. Someone joins, and every row below them moves down one;
//! someone leaves, and every row below them moves up. A selection kept as an
//! index would slide onto a different person between the keypress that chose
//! them and the one that acts — and the actions here are *kick* and *ban*. So
//! the selection is the thing itself — a connection id, a channel name, a nick —
//! and the index is worked out from it each time it is needed.

use std::collections::VecDeque;

use ddirc_server::{
    AdminCommand, ChannelInfo, EventKind, MemberInfo, ServerEvent, Snapshot, UserInfo,
};
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use tui_input::backend::crossterm::EventHandler;
use tui_input::Input;

use super::commands::{self, Parsed};

pub const MAX_LOG: usize = 2000;
const PAGE: usize = 10;
/// How many ticks a result stays on the status line. A tick is a quarter of a
/// second, so about five seconds: long enough to read, short enough not to be
/// mistaken for the current state of anything.
const FLASH_TICKS: u8 = 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Users,
    Channels,
    Log,
}

impl Tab {
    pub const ALL: [Tab; 3] = [Tab::Users, Tab::Channels, Tab::Log];

    fn step(self, forward: bool) -> Tab {
        let i = Tab::ALL.iter().position(|t| *t == self).unwrap_or(0);
        let n = Tab::ALL.len();
        Tab::ALL[if forward {
            (i + 1) % n
        } else {
            (i + n - 1) % n
        }]
    }
}

/// Which half of the channels tab has the keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Channels,
    Members,
}

/// How a log line should look, which is to say how much it matters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Presence,
    Chat,
    Moderation,
    Good,
    Bad,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogLine {
    pub at: u64,
    pub text: String,
    pub tone: Tone,
}

/// Facts about this run that do not change.
#[derive(Debug, Clone)]
pub struct Info {
    pub port: u16,
    /// Where the certificate a client must trust is.
    pub anchor: String,
    /// A command that connects to this server.
    pub connect: String,
}

/// What a confirmed question does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Confirmed {
    Admin(AdminCommand),
    Quit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Confirm {
    pub question: String,
    pub action: Confirmed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flash {
    pub text: String,
    pub ok: bool,
    ticks: u8,
}

pub struct App {
    pub info: Info,
    pub snapshot: Snapshot,
    /// Seconds since the epoch, as of the last tick. Ages are measured from it.
    pub now: u64,
    pub tab: Tab,
    pub focus: Focus,
    user: Option<u64>,
    channel: Option<String>,
    member: Option<String>,
    pub log: VecDeque<LogLine>,
    /// Lines hidden below the view. Zero is pinned to the newest.
    pub log_scroll: usize,
    /// The command line, while it is open.
    pub bar: Option<Input>,
    pub confirm: Option<Confirm>,
    pub help: bool,
    pub flash: Option<Flash>,
    pub quit: bool,
}

/// Keep `selection` if what it names is still in `items`; otherwise take the
/// item now where it was, or the last one, or nothing.
fn reselect<T, K: PartialEq>(
    items: &[T],
    key: impl Fn(&T) -> K,
    selection: &mut Option<K>,
    was_at: usize,
) {
    let present = selection
        .as_ref()
        .is_some_and(|k| items.iter().any(|i| &key(i) == k));
    if !present {
        *selection = items
            .get(was_at.min(items.len().saturating_sub(1)))
            .map(&key);
    }
}

/// Move a selection by `by` rows, stopping at the ends.
fn shift<T, K: PartialEq>(
    items: &[T],
    key: impl Fn(&T) -> K,
    selection: &mut Option<K>,
    by: isize,
) {
    if items.is_empty() {
        *selection = None;
        return;
    }
    let at = selection
        .as_ref()
        .and_then(|k| items.iter().position(|i| &key(i) == k))
        .unwrap_or(0);
    let to = (at as isize + by).clamp(0, items.len() as isize - 1) as usize;
    *selection = Some(key(&items[to]));
}

impl App {
    pub fn new(info: Info, snapshot: Snapshot, now: u64) -> Self {
        let mut app = Self {
            info,
            snapshot: empty(),
            now,
            tab: Tab::Users,
            focus: Focus::Channels,
            user: None,
            channel: None,
            member: None,
            log: VecDeque::new(),
            log_scroll: 0,
            bar: None,
            confirm: None,
            help: false,
            flash: None,
            quit: false,
        };
        app.set_snapshot(snapshot);
        app
    }

    // --------------------------------------------------------------- selection

    pub fn selected_user(&self) -> Option<&UserInfo> {
        let id = self.user?;
        self.snapshot.users.iter().find(|u| u.id == id)
    }

    pub fn selected_channel(&self) -> Option<&ChannelInfo> {
        let name = self.channel.as_deref()?;
        self.snapshot.channels.iter().find(|c| c.name == name)
    }

    pub fn selected_member(&self) -> Option<&MemberInfo> {
        let nick = self.member.as_deref()?;
        self.selected_channel()?
            .members
            .iter()
            .find(|m| m.nick == nick)
    }

    pub fn set_snapshot(&mut self, snapshot: Snapshot) {
        let user_at = self.index_of_user().unwrap_or(0);
        let channel_at = self.index_of_channel().unwrap_or(0);
        let member_at = self.index_of_member().unwrap_or(0);

        self.snapshot = snapshot;
        reselect(&self.snapshot.users, |u| u.id, &mut self.user, user_at);
        reselect(
            &self.snapshot.channels,
            |c| c.name.clone(),
            &mut self.channel,
            channel_at,
        );
        // Members are those of whichever channel is now selected, and a
        // different channel has different people.
        let members: &[MemberInfo] = self
            .channel
            .as_deref()
            .and_then(|n| self.snapshot.channels.iter().find(|c| c.name == n))
            .map_or(&[], |c| c.members.as_slice());
        reselect(members, |m| m.nick.clone(), &mut self.member, member_at);
    }

    fn index_of_user(&self) -> Option<usize> {
        let id = self.user?;
        self.snapshot.users.iter().position(|u| u.id == id)
    }

    fn index_of_channel(&self) -> Option<usize> {
        let name = self.channel.as_deref()?;
        self.snapshot.channels.iter().position(|c| c.name == name)
    }

    fn index_of_member(&self) -> Option<usize> {
        let nick = self.member.as_deref()?;
        self.selected_channel()?
            .members
            .iter()
            .position(|m| m.nick == nick)
    }

    /// The row to highlight in each list.
    pub fn user_row(&self) -> Option<usize> {
        self.index_of_user()
    }
    pub fn channel_row(&self) -> Option<usize> {
        self.index_of_channel()
    }
    pub fn member_row(&self) -> Option<usize> {
        self.index_of_member()
    }

    /// Select a different row, in whichever list has the keys.
    fn move_selection(&mut self, by: isize) {
        match (self.tab, self.focus) {
            (Tab::Users, _) => shift(&self.snapshot.users, |u| u.id, &mut self.user, by),
            (Tab::Channels, Focus::Channels) => {
                shift(
                    &self.snapshot.channels,
                    |c| c.name.clone(),
                    &mut self.channel,
                    by,
                );
                // A new channel starts with its first member selected, rather
                // than whoever happened to share a row number.
                self.member = self
                    .selected_channel()
                    .and_then(|c| c.members.first())
                    .map(|m| m.nick.clone());
            }
            (Tab::Channels, Focus::Members) => {
                let mut member = self.member.take();
                let members: &[MemberInfo] = self
                    .selected_channel()
                    .map_or(&[], |c| c.members.as_slice());
                shift(members, |m| m.nick.clone(), &mut member, by);
                self.member = member;
            }
            (Tab::Log, _) => {
                let max = self.log.len().saturating_sub(1);
                self.log_scroll = if by < 0 {
                    self.log_scroll.saturating_add(by.unsigned_abs()).min(max)
                } else {
                    self.log_scroll.saturating_sub(by as usize)
                };
            }
        }
    }

    // ------------------------------------------------------------------ events

    pub fn tick(&mut self, now: u64) {
        self.now = now;
        if let Some(flash) = &mut self.flash {
            flash.ticks = flash.ticks.saturating_sub(1);
            if flash.ticks == 0 {
                self.flash = None;
            }
        }
    }

    pub fn say(&mut self, text: impl Into<String>, ok: bool) {
        self.flash = Some(Flash {
            text: text.into(),
            ok,
            ticks: FLASH_TICKS,
        });
    }

    pub fn apply_event(&mut self, event: &ServerEvent) {
        let tone = match &event.kind {
            EventKind::Connected { .. }
            | EventKind::Dropped { .. }
            | EventKind::Registered { .. }
            | EventKind::NickChanged { .. }
            | EventKind::Joined { .. }
            | EventKind::Parted { .. }
            | EventKind::Quit { .. } => Tone::Presence,
            EventKind::Message { .. } => Tone::Chat,
            EventKind::Kicked { .. } | EventKind::Mode { .. } | EventKind::Topic { .. } => {
                Tone::Moderation
            }
            EventKind::Admin { ok: true, .. } => Tone::Good,
            EventKind::Admin { ok: false, .. } => Tone::Bad,
        };
        if let EventKind::Admin { ok, text } = &event.kind {
            self.say(text.clone(), *ok);
        }
        self.log.push_back(LogLine {
            at: event.at,
            text: event.describe(),
            tone,
        });
        if self.log_scroll > 0 {
            self.log_scroll += 1;
        }
        while self.log.len() > MAX_LOG {
            self.log.pop_front();
            self.log_scroll = self.log_scroll.saturating_sub(1);
        }
        self.log_scroll = self.log_scroll.min(self.log.len().saturating_sub(1));
    }

    /// The server's own count of events missed, for a subscriber that fell behind.
    pub fn note_skipped(&mut self, count: u64) {
        self.log.push_back(LogLine {
            at: self.now,
            text: format!("{count} events were missed while the screen was busy"),
            tone: Tone::Bad,
        });
    }

    // -------------------------------------------------------------------- keys

    /// Handle a key. Returns what to tell the server to do, in order.
    pub fn key(&mut self, key: KeyEvent) -> Vec<AdminCommand> {
        // Outside the command bar every key is a command, so a letter typed on
        // any layout means the Latin key it sits on. Inside it, only a chord
        // does; a plain key there is text, and the bar takes commands in
        // whatever language the person types them.
        let chord = key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT);
        let key = if chord || self.bar.is_none() {
            crate::keymap::shortcut(key)
        } else {
            key
        };
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && key.code == KeyCode::Char('c') {
            self.quit = true;
            return Vec::new();
        }
        if self.confirm.is_some() {
            return self.confirm_key(key);
        }
        if self.bar.is_some() {
            return self.bar_key(key);
        }
        if self.help {
            if matches!(
                key.code,
                KeyCode::Esc | KeyCode::Enter | KeyCode::Char('q' | '?') | KeyCode::F(1)
            ) {
                self.help = false;
            }
            return Vec::new();
        }
        self.normal_key(key)
    }

    fn confirm_key(&mut self, key: KeyEvent) -> Vec<AdminCommand> {
        match key.code {
            // Only `y`. Enter is what a hand does on its way to something else,
            // and the thing being confirmed is irreversible.
            KeyCode::Char('y' | 'Y') => {
                let Some(confirm) = self.confirm.take() else {
                    return Vec::new();
                };
                match confirm.action {
                    Confirmed::Admin(command) => return vec![command],
                    Confirmed::Quit => self.quit = true,
                }
            }
            KeyCode::Char('n' | 'N' | 'q') | KeyCode::Esc | KeyCode::Enter => self.confirm = None,
            _ => {}
        }
        Vec::new()
    }

    fn bar_key(&mut self, key: KeyEvent) -> Vec<AdminCommand> {
        match key.code {
            KeyCode::Esc => self.bar = None,
            KeyCode::Enter => {
                let line = self
                    .bar
                    .as_ref()
                    .map(|b| b.value().to_owned())
                    .unwrap_or_default();
                match commands::parse(&line) {
                    Ok(Parsed::Run(command)) => {
                        self.bar = None;
                        return vec![command];
                    }
                    Ok(Parsed::Help) => {
                        self.bar = None;
                        self.help = true;
                    }
                    // Left open, with what was typed, so a typo is one key to
                    // fix rather than a line to type again.
                    Err(message) => self.say(message, false),
                }
            }
            _ => {
                if let Some(bar) = &mut self.bar {
                    bar.handle_event(&Event::Key(key));
                }
            }
        }
        Vec::new()
    }

    fn open_bar(&mut self, text: impl Into<String>) {
        self.bar = Some(Input::new(text.into()));
    }

    fn ask(&mut self, question: String, action: Confirmed) {
        self.confirm = Some(Confirm { question, action });
    }

    fn normal_key(&mut self, key: KeyEvent) -> Vec<AdminCommand> {
        let in_members = self.tab == Tab::Channels && self.focus == Focus::Members;
        match key.code {
            // Back out of the member list first; Esc means "up one level" before
            // it means "dismiss the message".
            KeyCode::Left | KeyCode::Esc if in_members => self.focus = Focus::Channels,
            KeyCode::Right | KeyCode::Enter
                if self.tab == Tab::Channels && self.focus == Focus::Channels =>
            {
                self.focus = Focus::Members;
            }

            KeyCode::Char('q') => self.ask("Stop the server?".to_owned(), Confirmed::Quit),
            KeyCode::Char('?') | KeyCode::F(1) => self.help = true,
            // F2 as well: on a layout with no `:` or `/` where they are on a
            // US keyboard, the command line would otherwise have no way in.
            KeyCode::Char(':' | '/') | KeyCode::F(2) => self.open_bar(""),
            KeyCode::Char('w') => self.open_bar("wall "),
            KeyCode::Char('M') => {
                let motd = self.snapshot.motd.join(" | ");
                self.open_bar(format!("motd {motd}"));
            }
            KeyCode::Esc => self.flash = None,

            KeyCode::Tab => self.tab = self.tab.step(true),
            KeyCode::BackTab => self.tab = self.tab.step(false),
            KeyCode::Char('1') => self.tab = Tab::Users,
            KeyCode::Char('2') => self.tab = Tab::Channels,
            KeyCode::Char('3') => self.tab = Tab::Log,

            KeyCode::Up => self.move_selection(-1),
            KeyCode::Down => self.move_selection(1),
            KeyCode::PageUp => self.move_selection(-(PAGE as isize)),
            KeyCode::PageDown => self.move_selection(PAGE as isize),
            KeyCode::Home => self.move_selection(isize::MIN / 2),
            KeyCode::End => {
                if self.tab == Tab::Log {
                    self.log_scroll = 0;
                } else {
                    self.move_selection(isize::MAX / 2);
                }
            }

            KeyCode::Char(c) => return self.action_key(c),
            _ => {}
        }
        Vec::new()
    }

    /// The keys that do something to what is selected.
    fn action_key(&mut self, c: char) -> Vec<AdminCommand> {
        let target = self.target();
        match (c, target) {
            ('k', Some(Target { nick, channel })) => match channel {
                Some(channel) => self.open_bar(format!("kick {channel} {nick} ")),
                None => self.say(format!("{nick} is not in any channel"), false),
            },
            ('x', Some(Target { nick, .. })) => self.ask(
                format!("Disconnect {nick} from the server?"),
                Confirmed::Admin(AdminCommand::Disconnect { nick, reason: None }),
            ),
            ('b', Some(Target { nick, .. })) => self.ask(
                format!("Ban {nick}? They are disconnected and the name is refused."),
                Confirmed::Admin(AdminCommand::Ban { nick, reason: None }),
            ),
            ('m', Some(Target { nick, .. })) => self.open_bar(format!("say {nick} ")),
            (
                'o',
                Some(Target {
                    nick,
                    channel: Some(channel),
                }),
            ) if self.tab == Tab::Channels => {
                let is_op = self.selected_member().is_some_and(|m| m.op);
                return vec![if is_op {
                    AdminCommand::Deop { channel, nick }
                } else {
                    AdminCommand::Op { channel, nick }
                }];
            }

            ('t', _) if self.tab == Tab::Channels => {
                if let Some(c) = self.selected_channel() {
                    let text = format!("topic {} {}", c.name, c.topic.as_deref().unwrap_or(""));
                    self.open_bar(text);
                }
            }
            ('n', _) if self.tab == Tab::Channels => {
                if let Some(c) = self.selected_channel() {
                    let text = format!("say {} ", c.name);
                    self.open_bar(text);
                }
            }
            ('c', _) if self.tab == Tab::Channels => {
                if let Some(c) = self.selected_channel() {
                    let name = c.name.clone();
                    self.ask(
                        format!("Close {name}? Everyone in it is removed."),
                        Confirmed::Admin(AdminCommand::CloseChannel {
                            channel: name,
                            reason: None,
                        }),
                    );
                }
            }
            ('u', _) => {
                // Names under a ban are not in the lists, so there is nothing
                // to select; the command line is the way to lift one.
                let banned = self.snapshot.banned.first().cloned().unwrap_or_default();
                self.open_bar(format!("unban {banned}"));
            }
            _ => {}
        }
        Vec::new()
    }

    /// The person the keys act on: the highlighted user on the users tab, the
    /// highlighted member (once focus is in the member list) on the channels tab.
    fn target(&mut self) -> Option<Target> {
        match self.tab {
            Tab::Users => {
                let user = self.selected_user()?;
                let Some(nick) = user.nick.clone().filter(|_| user.registered) else {
                    let id = user.id;
                    self.say(format!("connection #{id} has not chosen a nick yet"), false);
                    return None;
                };
                Some(Target {
                    channel: user.channels.first().cloned(),
                    nick,
                })
            }
            Tab::Channels if self.focus == Focus::Members => {
                let channel = self.selected_channel()?.name.clone();
                let nick = self.selected_member()?.nick.clone();
                Some(Target {
                    nick,
                    channel: Some(channel),
                })
            }
            _ => None,
        }
    }
}

struct Target {
    nick: String,
    channel: Option<String>,
}

fn empty() -> Snapshot {
    Snapshot {
        server_name: String::new(),
        network_name: String::new(),
        started_at: 0,
        connections_total: 0,
        messages_total: 0,
        users: Vec::new(),
        channels: Vec::new(),
        banned: Vec::new(),
        motd: Vec::new(),
    }
}

#[cfg(test)]
mod tests;
