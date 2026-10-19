//! A typed line, turned into something to do.
//!
//! Shared by the plain-lines client and the full-screen one, so the two accept
//! the same commands and refuse the same typos. The few things only a screen can
//! do — open a conversation, close one, clear it — come back as their own
//! [`Action`]s, and the plain client says so rather than pretending.

use ddirc_core::conn::actor::ClientCommand;

pub enum Action {
    Send(ClientCommand),
    Notice(String),
    /// Open (and switch to) a private conversation.
    Query(String),
    /// Close the current conversation, leaving it first if it is a channel.
    Close,
    /// Empty the current conversation's scrollback.
    Clear,
    Help,
}

/// What the commands are, for `/help`.
pub const HELP: &[(&str, &str)] = &[
    ("/join <#channel> [key]", "join a channel"),
    (
        "/part [#channel] [reason]",
        "leave a channel (this one by default)",
    ),
    (
        "/msg <target> <text>",
        "send a message to a nick or channel",
    ),
    ("/query <nick>", "open a private conversation"),
    ("/me <action>", "say something in the third person"),
    ("/nick <new>", "change your nickname"),
    ("/topic <text>", "set the channel's topic"),
    (
        "/kick <nick> [reason]",
        "remove someone (channel operators)",
    ),
    ("/whois <nick>", "who is this?"),
    ("/list", "browse the server's channels"),
    ("/close", "close this conversation"),
    ("/clear", "empty this conversation's scrollback"),
    ("/quit [reason]", "disconnect and exit"),
];

/// Whether `name` is spelled like a channel.
fn is_channel(name: &str) -> bool {
    name.starts_with(['#', '&', '+', '!'])
}

/// `rust` is plainly meant as `#rust`, and nobody types the sigil twice.
fn channel(name: &str) -> String {
    if is_channel(name) {
        name.to_owned()
    } else {
        format!("#{name}")
    }
}

/// Translate a typed line into an action. `current` is the conversation the
/// line was typed in, if there is one.
pub fn command_for(line: &str, current: Option<&str>) -> Option<Action> {
    let line = line.trim_end_matches(['\r', '\n']);
    if line.trim().is_empty() {
        return None;
    }

    let Some(rest) = line.strip_prefix('/') else {
        let target = current?;
        return Some(Action::Send(ClientCommand::SendMessage {
            target: target.to_owned(),
            text: line.to_owned(),
        }));
    };

    let (command, argument) = match rest.split_once(' ') {
        Some((command, argument)) => (command, argument.trim()),
        None => (rest, ""),
    };
    let current_channel = current.filter(|c| is_channel(c));
    let reason = |s: &str| (!s.is_empty()).then(|| s.to_owned());

    let action = match command.to_ascii_lowercase().as_str() {
        "join" | "j" if !argument.is_empty() => {
            let (name, key) = match argument.split_once(' ') {
                Some((name, key)) => (name, reason(key.trim())),
                None => (argument, None),
            };
            Action::Send(ClientCommand::Join {
                channel: channel(name),
                key,
            })
        }
        "part" | "leave" => {
            // `/part #other bye`, or `/part bye` for the one we are in.
            let (named, why) = match argument.split_once(' ') {
                Some((first, why)) if is_channel(first) => (Some(first), why.trim()),
                None if is_channel(argument) => (Some(argument), ""),
                _ => (None, argument),
            };
            match named.or(current_channel) {
                Some(channel) => Action::Send(ClientCommand::Part {
                    channel: channel.to_owned(),
                    reason: reason(why),
                }),
                None => Action::Notice("not in a channel".to_owned()),
            }
        }
        "nick" if !argument.is_empty() => Action::Send(ClientCommand::SetNick(argument.to_owned())),
        "me" if !argument.is_empty() => match current {
            Some(target) => Action::Send(ClientCommand::SendAction {
                target: target.to_owned(),
                text: argument.to_owned(),
            }),
            None => Action::Notice("no current conversation".to_owned()),
        },
        "msg" | "m" => match argument.split_once(' ') {
            Some((target, text)) if !text.trim().is_empty() => {
                Action::Send(ClientCommand::SendMessage {
                    target: target.to_owned(),
                    text: text.trim().to_owned(),
                })
            }
            _ => Action::Notice("usage: /msg <target> <text>".to_owned()),
        },
        "query" | "q" if !argument.is_empty() => {
            Action::Query(argument.split(' ').next().unwrap_or(argument).to_owned())
        }
        "topic" => match (current_channel, argument.is_empty()) {
            (Some(channel), false) => Action::Send(ClientCommand::SetTopic {
                channel: channel.to_owned(),
                topic: argument.to_owned(),
            }),
            (Some(_), true) => Action::Notice("usage: /topic <text>".to_owned()),
            (None, _) => Action::Notice("not in a channel".to_owned()),
        },
        "kick" if !argument.is_empty() => {
            // `/kick bob spamming`, or `/kick #room bob spamming`.
            let (named, rest) = match argument.split_once(' ') {
                Some((first, rest)) if is_channel(first) => (Some(first), rest.trim()),
                _ => (None, argument),
            };
            let (nick, why) = match rest.split_once(' ') {
                Some((nick, why)) => (nick, why.trim()),
                None => (rest, ""),
            };
            match named.or(current_channel) {
                Some(channel) if !nick.is_empty() => Action::Send(ClientCommand::Kick {
                    channel: channel.to_owned(),
                    nick: nick.to_owned(),
                    reason: reason(why),
                }),
                Some(_) => Action::Notice("usage: /kick <nick> [reason]".to_owned()),
                None => Action::Notice("not in a channel".to_owned()),
            }
        }
        "list" => Action::Send(ClientCommand::ListChannels),
        "whois" if !argument.is_empty() => Action::Send(ClientCommand::Whois {
            nick: argument.to_owned(),
        }),
        "close" => Action::Close,
        "clear" => Action::Clear,
        "help" | "?" => Action::Help,
        "quit" | "exit" => Action::Send(ClientCommand::Disconnect {
            reason: reason(argument),
        }),
        other => Action::Notice(format!("unknown command: /{other}")),
    };
    Some(action)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_goes_to_the_current_channel() {
        let action = command_for("hello there", Some("#test"));
        assert!(matches!(
            action,
            Some(Action::Send(ClientCommand::SendMessage { ref target, ref text }))
                if target == "#test" && text == "hello there"
        ));
    }

    #[test]
    fn plain_text_without_a_channel_is_ignored() {
        assert!(command_for("hello", None).is_none());
    }

    #[test]
    fn blank_lines_are_ignored() {
        assert!(command_for("   ", Some("#test")).is_none());
        assert!(command_for("", Some("#test")).is_none());
    }

    #[test]
    fn join_and_part_are_parsed() {
        assert!(matches!(
            command_for("/join #rust", None),
            Some(Action::Send(ClientCommand::Join { ref channel, key: None })) if channel == "#rust"
        ));
        assert!(matches!(
            command_for("/part goodbye", Some("#test")),
            Some(Action::Send(ClientCommand::Part { ref channel, ref reason }))
                if channel == "#test" && reason.as_deref() == Some("goodbye")
        ));
    }

    #[test]
    fn a_channel_needs_no_sigil_and_may_have_a_key() {
        assert!(matches!(
            command_for("/join rust sesame", None),
            Some(Action::Send(ClientCommand::Join { ref channel, ref key }))
                if channel == "#rust" && key.as_deref() == Some("sesame")
        ));
    }

    #[test]
    fn part_can_name_another_channel() {
        assert!(matches!(
            command_for("/part #other so long", Some("#test")),
            Some(Action::Send(ClientCommand::Part { ref channel, ref reason }))
                if channel == "#other" && reason.as_deref() == Some("so long")
        ));
        // From a private conversation there is no "this channel" to leave.
        assert!(matches!(
            command_for("/part", Some("bob")),
            Some(Action::Notice(_))
        ));
    }

    #[test]
    fn msg_requires_a_target_and_body() {
        assert!(matches!(
            command_for("/msg alice hi there", None),
            Some(Action::Send(ClientCommand::SendMessage { ref target, ref text }))
                if target == "alice" && text == "hi there"
        ));
        assert!(matches!(
            command_for("/msg alice", None),
            Some(Action::Notice(_))
        ));
    }

    #[test]
    fn kick_defaults_to_this_channel_and_may_name_another() {
        assert!(matches!(
            command_for("/kick bob too loud", Some("#room")),
            Some(Action::Send(ClientCommand::Kick { ref channel, ref nick, ref reason }))
                if channel == "#room" && nick == "bob" && reason.as_deref() == Some("too loud")
        ));
        assert!(matches!(
            command_for("/kick #other bob", Some("#room")),
            Some(Action::Send(ClientCommand::Kick { ref channel, ref nick, reason: None }))
                if channel == "#other" && nick == "bob"
        ));
        assert!(matches!(
            command_for("/kick bob", Some("alice")),
            Some(Action::Notice(_))
        ));
    }

    #[test]
    fn topic_needs_a_channel_and_some_text() {
        assert!(matches!(
            command_for("/topic be nice", Some("#room")),
            Some(Action::Send(ClientCommand::SetTopic { ref channel, ref topic }))
                if channel == "#room" && topic == "be nice"
        ));
        assert!(matches!(
            command_for("/topic", Some("#room")),
            Some(Action::Notice(_))
        ));
        assert!(matches!(
            command_for("/topic hi", None),
            Some(Action::Notice(_))
        ));
    }

    #[test]
    fn screen_commands_are_their_own_actions() {
        assert!(
            matches!(command_for("/query bob", None), Some(Action::Query(ref n)) if n == "bob")
        );
        assert!(matches!(command_for("/close", None), Some(Action::Close)));
        assert!(matches!(command_for("/clear", None), Some(Action::Clear)));
        assert!(matches!(command_for("/help", None), Some(Action::Help)));
    }

    #[test]
    fn commands_are_case_insensitive() {
        assert!(matches!(
            command_for("/JOIN #rust", None),
            Some(Action::Send(ClientCommand::Join { .. }))
        ));
    }

    #[test]
    fn a_leading_slash_is_never_sent_as_chat() {
        // Otherwise a typo like /jion would be broadcast to the channel.
        assert!(matches!(
            command_for("/jion #rust", Some("#test")),
            Some(Action::Notice(_))
        ));
    }
}
