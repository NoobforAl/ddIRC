//! What the full-screen client knows, and how it reacts to a key or an event.
//!
//! Nothing in here draws or reads a terminal. A key goes in and a list of
//! commands for the core comes out; an [`IrcEvent`] goes in and the
//! conversations change. That is the whole interface, which is what lets the
//! behaviour be tested without a screen — and keeps `ui.rs` down to deciding
//! where things go.

use std::collections::VecDeque;

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{
    ChannelListing, ChatMessage, ConnectionStatus, MemberView, Target, WhoisInfo,
};
use ddirc_core::conn::actor::ClientCommand;
use ddirc_core::text::format::{SpanStyle, TextSpan};
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use tui_input::backend::crossterm::EventHandler;
use tui_input::Input;

use super::commands::{command_for, command_for_with, Action};

/// Lines kept per conversation. A busy channel for an evening, not forever.
pub const MAX_LINES: usize = 2000;

/// How far PageUp moves, in lines. The model does not know how tall the screen
/// is, and "about a screenful" is close enough for a key that repeats.
const PAGE: usize = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferKind {
    /// The connection itself: status, errors, what the server says to nobody.
    Server,
    Channel,
    Direct,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    Chat,
    Action,
    Notice,
    Join,
    Part,
    Info,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub kind: LineKind,
    /// We said it.
    pub own: bool,
    /// It names us.
    pub mention: bool,
    /// The speaker, for the kinds that have one.
    pub who: String,
    /// Their channel privilege, e.g. `@`.
    pub prefix: String,
    pub body: Vec<TextSpan>,
}

impl Line {
    pub fn system(kind: LineKind, text: impl Into<String>) -> Self {
        Self {
            kind,
            own: false,
            mention: false,
            who: String::new(),
            prefix: String::new(),
            body: vec![TextSpan {
                text: text.into(),
                style: SpanStyle::default(),
            }],
        }
    }

    fn from_message(message: &ChatMessage) -> Self {
        let kind = if message.is_action {
            LineKind::Action
        } else if message.is_notice {
            LineKind::Notice
        } else {
            LineKind::Chat
        };
        Self {
            kind,
            own: message.is_self,
            mention: message.is_mention,
            who: message.sender.clone(),
            prefix: message.sender_prefix.clone().unwrap_or_default(),
            body: message.spans.clone(),
        }
    }

    /// The words, with no styling.
    #[cfg(test)]
    pub fn text(&self) -> String {
        self.body.iter().map(|s| s.text.as_str()).collect()
    }
}

#[derive(Debug)]
pub struct Buffer {
    pub name: String,
    pub kind: BufferKind,
    pub lines: VecDeque<Line>,
    pub unread: usize,
    /// Something unread was addressed to us.
    pub mentioned: bool,
    pub members: Vec<MemberView>,
    pub topic: Option<String>,
    /// Lines hidden below the view. Zero is pinned to the newest.
    pub scroll: usize,
}

impl Buffer {
    fn new(name: impl Into<String>, kind: BufferKind) -> Self {
        Self {
            name: name.into(),
            kind,
            lines: VecDeque::new(),
            unread: 0,
            mentioned: false,
            members: Vec::new(),
            topic: None,
            scroll: 0,
        }
    }

    fn push(&mut self, line: Line) {
        self.lines.push_back(line);
        // A reader who has scrolled up is reading something. New lines arrive
        // beneath them without moving it.
        if self.scroll > 0 {
            self.scroll += 1;
        }
        while self.lines.len() > MAX_LINES {
            self.lines.pop_front();
            self.scroll = self.scroll.saturating_sub(1);
        }
        self.scroll = self.scroll.min(self.lines.len().saturating_sub(1));
    }
}

/// Something on top of the conversation, until dismissed.
#[derive(Debug)]
pub enum Popup {
    Help,
    Channels {
        items: Vec<ChannelListing>,
        selected: usize,
        done: bool,
        truncated: bool,
    },
    Whois(Box<WhoisInfo>),
}

/// A Tab in progress: which word, and which of its completions is showing.
#[derive(Debug)]
struct Completion {
    start: usize,
    matches: Vec<String>,
    index: usize,
    /// What is in the input at `start` right now, so the next Tab can replace
    /// exactly it — and can tell, by it no longer being there, that the line
    /// was changed some other way and this completion is over.
    shown: Vec<char>,
}

pub struct App {
    pub buffers: Vec<Buffer>,
    pub current: usize,
    pub nick: String,
    pub network: Option<String>,
    pub status: ConnectionStatus,
    pub status_detail: Option<String>,
    pub input: Input,
    pub popup: Option<Popup>,
    pub quit: bool,
    /// Whether a `/list` is in flight and its answer is wanted on screen.
    awaiting_list: bool,
    history: Vec<String>,
    history_at: Option<usize>,
    draft: String,
    completion: Option<Completion>,
    /// Whether this is an XMPP account. Changes how a typed name is read: see
    /// [`App::is_room`].
    xmpp: bool,
}

/// ASCII case-insensitive, which is what IRC names are compared with here.
fn same(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

impl App {
    pub fn new(nick: impl Into<String>, host: impl Into<String>) -> Self {
        Self {
            buffers: vec![Buffer::new(host, BufferKind::Server)],
            current: 0,
            nick: nick.into(),
            network: None,
            status: ConnectionStatus::Connecting,
            status_detail: None,
            input: Input::default(),
            popup: None,
            quit: false,
            awaiting_list: false,
            history: Vec::new(),
            history_at: None,
            draft: String::new(),
            completion: None,
            xmpp: false,
        }
    }

    /// For an XMPP account, whose names are read differently: see
    /// [`App::is_room`].
    #[must_use]
    pub fn for_xmpp(mut self) -> Self {
        self.xmpp = true;
        self
    }

    /// Whether `name` is a room rather than a person, for an XMPP account.
    ///
    /// Both are addresses - `lobby@conference.example.org`, `alice@example.org` -
    /// so nothing in the name says which, and the answer is what has been
    /// opened: a channel buffer is a room, a conversation is a person. A name
    /// with no buffer yet is read as a room if it is written like an address,
    /// because the words that ask - `/part room@x`, `/kick room@x bob` - put
    /// the room first, and a nick inside a room is not an address.
    pub fn is_room(&self, name: &str) -> bool {
        match self
            .buffers
            .iter()
            .find(|b| b.kind != BufferKind::Server && same(&b.name, name))
        {
            Some(buffer) => buffer.kind == BufferKind::Channel,
            None => name.contains('@') && !name.contains('/'),
        }
    }

    pub fn buffer(&self) -> &Buffer {
        &self.buffers[self.current]
    }

    fn buffer_mut(&mut self) -> &mut Buffer {
        &mut self.buffers[self.current]
    }

    /// The conversation a typed line goes to. The server buffer is nobody.
    pub fn target(&self) -> Option<&str> {
        let buffer = self.buffer();
        (buffer.kind != BufferKind::Server).then_some(buffer.name.as_str())
    }

    fn find(&self, name: &str) -> Option<usize> {
        self.buffers
            .iter()
            .position(|b| b.kind != BufferKind::Server && same(&b.name, name))
    }

    fn ensure(&mut self, name: &str, kind: BufferKind) -> usize {
        if let Some(index) = self.find(name) {
            return index;
        }
        self.buffers.push(Buffer::new(name, kind));
        self.buffers.len() - 1
    }

    pub fn switch(&mut self, index: usize) {
        if index < self.buffers.len() {
            self.current = index;
            let buffer = self.buffer_mut();
            buffer.unread = 0;
            buffer.mentioned = false;
        }
    }

    fn step(&mut self, forward: bool) {
        let n = self.buffers.len();
        let next = if forward {
            (self.current + 1) % n
        } else {
            (self.current + n - 1) % n
        };
        self.switch(next);
    }

    fn remove(&mut self, index: usize) {
        if index == 0 || index >= self.buffers.len() {
            return;
        }
        self.buffers.remove(index);
        if self.current == index {
            self.current = 0;
        } else if self.current > index {
            self.current -= 1;
        }
    }

    fn server_line(&mut self, kind: LineKind, text: impl Into<String>) {
        self.buffers[0].push(Line::system(kind, text));
    }

    /// A line in a named conversation if we have it, otherwise on the server's.
    fn line_in(&mut self, name: &str, line: Line) {
        let index = self.find(name).unwrap_or(0);
        self.buffers[index].push(line);
    }

    // ------------------------------------------------------------------ events

    pub fn apply(&mut self, event: IrcEvent) {
        match event {
            IrcEvent::Message(message) => self.on_message(&message),

            IrcEvent::Status { status, detail } => {
                let text = match &status {
                    ConnectionStatus::Disconnected => "disconnected".to_owned(),
                    ConnectionStatus::Connecting => "connecting".to_owned(),
                    ConnectionStatus::Registering => "registering".to_owned(),
                    ConnectionStatus::Connected => "connected".to_owned(),
                    ConnectionStatus::Reconnecting {
                        retry_in_secs,
                        attempt,
                    } => format!("reconnecting in {retry_in_secs}s (attempt {attempt})"),
                };
                let full = match detail.as_deref() {
                    Some(d) if !d.is_empty() => format!("{text}: {d}"),
                    _ => text,
                };
                self.status = status;
                self.status_detail = detail;
                self.server_line(LineKind::Info, full);
            }

            IrcEvent::Registered { nick, network, .. } => {
                self.nick = nick.clone();
                if network.is_some() {
                    self.network = network;
                }
                self.server_line(LineKind::Info, format!("registered as {nick}"));
            }
            IrcEvent::NetworkNamed { network } => {
                self.server_line(LineKind::Info, format!("network: {network}"));
                self.network = Some(network);
            }

            IrcEvent::Joined {
                channel,
                nick,
                is_self,
            } => {
                let index = self.ensure(&channel, BufferKind::Channel);
                if is_self {
                    self.switch(index);
                }
                self.buffers[index].push(Line::system(
                    LineKind::Join,
                    if is_self {
                        format!("you joined {channel}")
                    } else {
                        format!("{nick} joined")
                    },
                ));
            }
            IrcEvent::Parted {
                channel,
                nick,
                is_self,
                reason,
            } => {
                let why = reason
                    .as_deref()
                    .map(|r| format!(" ({r})"))
                    .unwrap_or_default();
                if is_self {
                    // The room is gone from the list, so where the reason —
                    // "kicked by ...", most of all — is read is the server's.
                    if let Some(index) = self.find(&channel) {
                        self.remove(index);
                    }
                    self.server_line(LineKind::Part, format!("you left {channel}{why}"));
                } else {
                    self.line_in(
                        &channel,
                        Line::system(LineKind::Part, format!("{nick} left{why}")),
                    );
                }
            }
            IrcEvent::Quit {
                channel,
                nick,
                reason,
            } => {
                let why = reason
                    .as_deref()
                    .map(|r| format!(" ({r})"))
                    .unwrap_or_default();
                self.line_in(
                    &channel,
                    Line::system(LineKind::Part, format!("{nick} quit{why}")),
                );
            }
            IrcEvent::NickChanged {
                channel,
                old,
                new,
                is_self,
            } => {
                if is_self {
                    self.nick = new.clone();
                }
                self.line_in(
                    &channel,
                    Line::system(LineKind::Info, format!("{old} is now {new}")),
                );
            }
            IrcEvent::TopicChanged {
                channel,
                topic,
                set_by,
            } => {
                if let Some(index) = self.find(&channel) {
                    self.buffers[index].topic = (!topic.is_empty()).then(|| topic.clone());
                }
                let text = match set_by {
                    Some(who) => format!("{who} set the topic: {topic}"),
                    None => format!("topic: {topic}"),
                };
                self.line_in(&channel, Line::system(LineKind::Info, text));
            }
            IrcEvent::MemberList { channel, members } => {
                if let Some(index) = self.find(&channel) {
                    let buffer = &mut self.buffers[index];
                    buffer.members = members;
                    buffer.members.sort_by(|a, b| a.sort_key.cmp(&b.sort_key));
                }
            }
            IrcEvent::MemberChanged {
                channel,
                previous,
                member,
            } => {
                if let Some(index) = self.find(&channel) {
                    let members = &mut self.buffers[index].members;
                    members.retain(|m| !same(&m.nick, &previous));
                    if let Some(member) = member {
                        let at = members.partition_point(|m| m.sort_key < member.sort_key);
                        members.insert(at, member);
                    }
                }
            }
            IrcEvent::ModeChanged {
                channel,
                by,
                affected,
            } => {
                let by = by.unwrap_or_else(|| "the server".to_owned());
                self.line_in(
                    &channel,
                    Line::system(
                        LineKind::Info,
                        format!("{by} changed privileges for {}", affected.join(", ")),
                    ),
                );
            }
            IrcEvent::MessagesDropped { channel, count } => {
                let line = Line::system(
                    LineKind::Error,
                    format!("{count} message(s) dropped by flood protection"),
                );
                match channel {
                    Some(channel) => self.line_in(&channel, line),
                    None => self.buffers[0].push(line),
                }
            }

            IrcEvent::FileOffered {
                channel,
                from,
                offer,
                ..
            } => {
                // Reported and nothing more, as everywhere else in this tree:
                // taking a file means dialling an address a stranger chose.
                let size = offer
                    .size
                    .map(|b| format!(", {b} bytes"))
                    .unwrap_or_default();
                self.line_in(
                    &channel,
                    Line::system(
                        LineKind::Info,
                        format!(
                            "{from} offered \"{}\"{size} (not accepted here)",
                            offer.filename
                        ),
                    ),
                );
            }
            IrcEvent::FileTransferStarted {
                filename, incoming, ..
            } => {
                let verb = if incoming { "receiving" } else { "sending" };
                self.server_line(LineKind::Info, format!("{verb} \"{filename}\""));
            }
            IrcEvent::FileTransferProgress { .. } => {}
            IrcEvent::FileTransferEnded {
                filename,
                path,
                error,
                ..
            } => {
                let text = match (error, path) {
                    (Some(e), _) => format!("\"{filename}\" failed: {e}"),
                    (None, Some(p)) => format!("\"{filename}\" saved to {p}"),
                    (None, None) => format!("\"{filename}\" sent"),
                };
                self.server_line(LineKind::Info, text);
            }

            IrcEvent::ChannelList {
                channels,
                done,
                truncated,
            } => {
                if self.awaiting_list {
                    let selected = match &self.popup {
                        Some(Popup::Channels { selected, .. }) => {
                            (*selected).min(channels.len().saturating_sub(1))
                        }
                        _ => 0,
                    };
                    self.popup = Some(Popup::Channels {
                        items: channels,
                        selected,
                        done,
                        truncated,
                    });
                    if done {
                        self.awaiting_list = false;
                    }
                }
            }
            IrcEvent::Whois(whois) => self.popup = Some(Popup::Whois(whois)),

            IrcEvent::Error { message, fatal } => {
                let text = if fatal {
                    format!("fatal: {message}")
                } else {
                    message
                };
                // Where the person is looking: a refusal to a command they just
                // typed belongs under it, not in a buffer they are not in.
                self.buffer_mut().push(Line::system(LineKind::Error, text));
            }
        }
    }

    fn on_message(&mut self, message: &ChatMessage) {
        // A server talking to us — a notice from `irc.example.net` — is not a
        // person to open a conversation with.
        let from_server = message.is_notice && message.sender.contains('.');
        let (index, kind) = match &message.target {
            Target::Channel(name) => (self.ensure(name, BufferKind::Channel), BufferKind::Channel),
            Target::Direct(_) if from_server => (0, BufferKind::Server),
            Target::Direct(nick) => (self.ensure(nick, BufferKind::Direct), BufferKind::Direct),
        };
        let here = index == self.current;
        let buffer = &mut self.buffers[index];
        buffer.push(Line::from_message(message));
        if !here && !message.is_self {
            buffer.unread += 1;
            if message.is_mention || kind == BufferKind::Direct {
                buffer.mentioned = true;
            }
        }
    }

    // -------------------------------------------------------------------- keys

    /// Handle a key. Returns what to send to the core, in order.
    pub fn key(&mut self, key: KeyEvent) -> Vec<ClientCommand> {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        // A chord is a command whatever the layout, so Ctrl-C is Ctrl-C on the
        // key where it is on a US keyboard. A plain key goes through as typed:
        // that is somebody writing in their own language. (The popups below
        // take no text, so for them every key is a command.)
        let key = if ctrl || alt || self.popup.is_some() {
            crate::keymap::shortcut(key)
        } else {
            key
        };

        if ctrl && matches!(key.code, KeyCode::Char('c' | 'q')) {
            self.quit = true;
            return vec![ClientCommand::Disconnect { reason: None }];
        }
        if self.popup.is_some() {
            return self.popup_key(key);
        }
        if key.code == KeyCode::F(1) {
            self.popup = Some(Popup::Help);
            return Vec::new();
        }

        if key.code != KeyCode::Tab {
            self.completion = None;
        }
        match key.code {
            KeyCode::Enter => return self.submit(),
            KeyCode::Esc => self.input.reset(),
            KeyCode::Tab => self.complete(),
            KeyCode::PageUp => self.scroll(PAGE as isize),
            KeyCode::PageDown => self.scroll(-(PAGE as isize)),
            KeyCode::Up => self.history_step(true),
            KeyCode::Down => self.history_step(false),
            KeyCode::Char('n') if ctrl => self.step(true),
            KeyCode::Char('p') if ctrl => self.step(false),
            KeyCode::Right if alt => self.step(true),
            KeyCode::Left if alt => self.step(false),
            KeyCode::Char(c @ '1'..='9') if alt => self.switch(c as usize - '1' as usize),
            _ => {
                self.input.handle_event(&Event::Key(key));
            }
        }
        Vec::new()
    }

    fn popup_key(&mut self, key: KeyEvent) -> Vec<ClientCommand> {
        let Some(popup) = self.popup.as_mut() else {
            return Vec::new();
        };
        match popup {
            Popup::Channels {
                items, selected, ..
            } => match key.code {
                KeyCode::Up => *selected = selected.saturating_sub(1),
                KeyCode::Down => *selected = (*selected + 1).min(items.len().saturating_sub(1)),
                KeyCode::PageUp => *selected = selected.saturating_sub(PAGE),
                KeyCode::PageDown => {
                    *selected = (*selected + PAGE).min(items.len().saturating_sub(1))
                }
                KeyCode::Home => *selected = 0,
                KeyCode::End => *selected = items.len().saturating_sub(1),
                KeyCode::Enter => {
                    let join = items.get(*selected).map(|c| ClientCommand::Join {
                        channel: c.name.clone(),
                        key: None,
                    });
                    self.popup = None;
                    self.awaiting_list = false;
                    return join.into_iter().collect();
                }
                KeyCode::Esc | KeyCode::Char('q') => {
                    self.popup = None;
                    self.awaiting_list = false;
                }
                _ => {}
            },
            Popup::Help | Popup::Whois(_) => {
                if matches!(
                    key.code,
                    KeyCode::Esc | KeyCode::Enter | KeyCode::Char('q') | KeyCode::F(1)
                ) {
                    self.popup = None;
                }
            }
        }
        Vec::new()
    }

    /// Turn the input line into commands, and the screen's own actions.
    pub fn submit(&mut self) -> Vec<ClientCommand> {
        let line = self.input.value_and_reset();
        self.history_at = None;
        if line.trim().is_empty() {
            return Vec::new();
        }
        if self.history.last() != Some(&line) {
            self.history.push(line.clone());
        }

        let target = self.target().map(str::to_owned);
        let action = if self.xmpp {
            command_for_with(&line, target.as_deref(), &|name| self.is_room(name), false)
        } else {
            command_for(&line, target.as_deref())
        };
        match action {
            None => {
                if target.is_none() {
                    self.buffer_mut().push(Line::system(
                        LineKind::Error,
                        "no conversation here: /join #channel, or /help",
                    ));
                }
                Vec::new()
            }
            Some(Action::Send(command)) => {
                match &command {
                    ClientCommand::Disconnect { .. } => self.quit = true,
                    ClientCommand::ListChannels => {
                        self.awaiting_list = true;
                        self.popup = Some(Popup::Channels {
                            items: Vec::new(),
                            selected: 0,
                            done: false,
                            truncated: false,
                        });
                    }
                    _ => {}
                }
                vec![command]
            }
            Some(Action::Notice(text)) => {
                self.buffer_mut().push(Line::system(LineKind::Error, text));
                Vec::new()
            }
            Some(Action::Query(nick)) => {
                let index = self.ensure(&nick, BufferKind::Direct);
                self.switch(index);
                Vec::new()
            }
            Some(Action::Close) => {
                let (kind, name) = {
                    let b = self.buffer();
                    (b.kind, b.name.clone())
                };
                match kind {
                    BufferKind::Server => {
                        self.buffer_mut().push(Line::system(
                            LineKind::Error,
                            "the server window cannot be closed; /quit leaves",
                        ));
                        Vec::new()
                    }
                    // Parting closes the window when the server confirms it, so
                    // the room is not forgotten before it has actually let go.
                    BufferKind::Channel => vec![ClientCommand::Part {
                        channel: name,
                        reason: None,
                    }],
                    BufferKind::Direct => {
                        let at = self.current;
                        self.remove(at);
                        Vec::new()
                    }
                }
            }
            Some(Action::Clear) => {
                let buffer = self.buffer_mut();
                buffer.lines.clear();
                buffer.scroll = 0;
                Vec::new()
            }
            Some(Action::Help) => {
                self.popup = Some(Popup::Help);
                Vec::new()
            }
        }
    }

    fn scroll(&mut self, by: isize) {
        let buffer = self.buffer_mut();
        let max = buffer.lines.len().saturating_sub(1);
        buffer.scroll = if by >= 0 {
            (buffer.scroll + by as usize).min(max)
        } else {
            buffer.scroll.saturating_sub(by.unsigned_abs())
        };
    }

    fn history_step(&mut self, back: bool) {
        if self.history.is_empty() {
            return;
        }
        let next = match (self.history_at, back) {
            (None, true) => {
                self.draft = self.input.value().to_owned();
                Some(self.history.len() - 1)
            }
            (None, false) => return,
            (Some(i), true) => Some(i.saturating_sub(1)),
            (Some(i), false) if i + 1 < self.history.len() => Some(i + 1),
            (Some(_), false) => None,
        };
        self.history_at = next;
        let text = match next {
            Some(i) => self.history[i].clone(),
            None => std::mem::take(&mut self.draft),
        };
        self.input = Input::new(text);
    }

    /// Complete the word before the cursor to a nick from this conversation.
    /// Again, and it moves on to the next candidate.
    fn complete(&mut self) {
        let value: Vec<char> = self.input.value().chars().collect();
        let cursor = self.input.cursor().min(value.len());

        if let Some(c) = &self.completion {
            let end = c.start + c.shown.len();
            if value.get(c.start..end) != Some(c.shown.as_slice()) {
                self.completion = None;
            }
        }

        if self.completion.is_none() {
            let start = value[..cursor]
                .iter()
                .rposition(|c| c.is_whitespace())
                .map_or(0, |i| i + 1);
            let word: String = value[start..cursor].iter().collect();
            if word.is_empty() {
                return;
            }
            let lower = word.to_ascii_lowercase();
            let mut matches: Vec<String> = self
                .buffer()
                .members
                .iter()
                .filter(|m| m.nick.to_ascii_lowercase().starts_with(&lower))
                .map(|m| m.nick.clone())
                .collect();
            matches.sort_by_key(|n| n.to_ascii_lowercase());
            if matches.is_empty() {
                return;
            }
            self.completion = Some(Completion {
                start,
                matches,
                index: 0,
                shown: value[start..cursor].to_vec(),
            });
        } else if let Some(c) = &mut self.completion {
            c.index = (c.index + 1) % c.matches.len();
        }

        let Some(c) = &mut self.completion else {
            return;
        };
        // At the start of a line a nick is an address, "bob: "; mid-sentence
        // it is a word, and wants only a space after it.
        let suffix = if c.start == 0 { ": " } else { " " };
        let replacement: Vec<char> = format!("{}{suffix}", c.matches[c.index]).chars().collect();
        let mut out: Vec<char> = value[..c.start].to_vec();
        out.extend(&replacement);
        out.extend(&value[c.start + c.shown.len()..]);
        let end = c.start + replacement.len();
        c.shown = replacement;
        self.input = Input::new(out.into_iter().collect()).with_cursor(end);
    }
}

#[cfg(test)]
mod tests;
