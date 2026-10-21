//! The server manager's command line.
//!
//! Every key in the manager ends up here or at the same [`AdminCommand`]s: a
//! shortcut like `k` does not kick anyone, it opens this line with `kick
//! #room bob ` already typed, so what is about to happen is on screen, and
//! editable, before Enter makes it so.

use ddirc_server::AdminCommand;

/// What a typed line means.
#[derive(Debug, PartialEq, Eq)]
pub enum Parsed {
    Run(AdminCommand),
    Help,
}

pub const HELP: &[(&str, &str)] = &[
    (
        "kick <#chan> <nick> [reason]",
        "remove someone from a channel",
    ),
    ("kill <nick> [reason]", "disconnect someone from the server"),
    ("ban <nick> [reason]", "disconnect them and refuse the name"),
    ("unban <nick>", "allow the name again"),
    (
        "topic <#chan> [text]",
        "set a topic; leave the text off to clear it",
    ),
    ("close <#chan> [reason]", "remove everyone and the channel"),
    ("op <#chan> <nick>", "make someone a channel operator"),
    ("deop <#chan> <nick>", "take operator status away"),
    ("say <nick|#chan> <text>", "a notice from the server itself"),
    ("wall <text>", "a notice to everyone connected"),
    (
        "motd [line | line …]",
        "set the message of the day; none restores it",
    ),
    ("help", "this list"),
];

fn channel(name: &str) -> String {
    if name.starts_with('#') {
        name.to_owned()
    } else {
        format!("#{name}")
    }
}

/// The first word, and the rest with its leading space gone.
fn word(text: &str) -> (&str, &str) {
    let text = text.trim_start();
    match text.split_once(char::is_whitespace) {
        Some((first, rest)) => (first, rest.trim()),
        None => (text, ""),
    }
}

fn reason(text: &str) -> Option<String> {
    (!text.is_empty()).then(|| text.to_owned())
}

/// Parse one line. A leading `:` or `/` is allowed and ignored, because
/// somebody will type one.
pub fn parse(line: &str) -> Result<Parsed, String> {
    let line = line.trim().trim_start_matches([':', '/']);
    let (verb, rest) = word(line);
    let need = |what: &str, value: &str| -> Result<String, String> {
        if value.is_empty() {
            Err(format!("{verb} needs {what}"))
        } else {
            Ok(value.to_owned())
        }
    };

    let command = match verb.to_ascii_lowercase().as_str() {
        "" => return Err("type a command; help lists them".to_owned()),
        "help" | "?" => return Ok(Parsed::Help),

        "kick" => {
            let (chan, rest) = word(rest);
            let (nick, why) = word(rest);
            AdminCommand::Kick {
                channel: channel(&need("a channel", chan)?),
                nick: need("a nick", nick)?,
                reason: reason(why),
            }
        }
        "kill" | "disconnect" => {
            let (nick, why) = word(rest);
            AdminCommand::Disconnect {
                nick: need("a nick", nick)?,
                reason: reason(why),
            }
        }
        "ban" => {
            let (nick, why) = word(rest);
            AdminCommand::Ban {
                nick: need("a nick", nick)?,
                reason: reason(why),
            }
        }
        "unban" => AdminCommand::Unban {
            nick: need("a nick", word(rest).0)?,
        },
        "topic" => {
            let (chan, text) = word(rest);
            AdminCommand::SetTopic {
                channel: channel(&need("a channel", chan)?),
                topic: text.to_owned(),
            }
        }
        "close" => {
            let (chan, why) = word(rest);
            AdminCommand::CloseChannel {
                channel: channel(&need("a channel", chan)?),
                reason: reason(why),
            }
        }
        "op" | "deop" => {
            let (chan, rest) = word(rest);
            let (nick, _) = word(rest);
            let channel = channel(&need("a channel", chan)?);
            let nick = need("a nick", nick)?;
            if verb.eq_ignore_ascii_case("op") {
                AdminCommand::Op { channel, nick }
            } else {
                AdminCommand::Deop { channel, nick }
            }
        }
        "say" | "msg" | "notice" => {
            let (target, text) = word(rest);
            AdminCommand::Notice {
                target: need("a nick or channel", target)?,
                text: need("something to say", text)?,
            }
        }
        "wall" => AdminCommand::Wall {
            text: need("something to say", rest)?,
        },
        "motd" => AdminCommand::SetMotd {
            lines: rest
                .split('|')
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(str::to_owned)
                .collect(),
        },
        other => return Err(format!("unknown command: {other} (help lists them)")),
    };
    Ok(Parsed::Run(command))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(line: &str) -> AdminCommand {
        match parse(line) {
            Ok(Parsed::Run(command)) => command,
            other => panic!("{line:?} parsed as {other:?}"),
        }
    }

    #[test]
    fn kick_takes_a_channel_a_nick_and_the_rest_as_the_reason() {
        assert_eq!(
            run("kick #room bob being rude"),
            AdminCommand::Kick {
                channel: "#room".into(),
                nick: "bob".into(),
                reason: Some("being rude".into())
            }
        );
        assert_eq!(
            run("kick room bob"),
            AdminCommand::Kick {
                channel: "#room".into(),
                nick: "bob".into(),
                reason: None
            },
            "the sigil is optional"
        );
    }

    #[test]
    fn a_leading_colon_or_slash_is_forgiven() {
        assert!(matches!(run(":wall hello"), AdminCommand::Wall { .. }));
        assert!(matches!(run("/WALL hello"), AdminCommand::Wall { .. }));
    }

    #[test]
    fn the_rest_of_the_line_is_kept_whole() {
        assert_eq!(
            run("say #room   two  spaces inside"),
            AdminCommand::Notice {
                target: "#room".into(),
                text: "two  spaces inside".into()
            }
        );
        assert_eq!(
            run("topic #room"),
            AdminCommand::SetTopic {
                channel: "#room".into(),
                topic: String::new()
            },
            "no text clears the topic"
        );
    }

    #[test]
    fn the_motd_is_lines_separated_by_bars() {
        assert_eq!(
            run("motd welcome | be nice |  "),
            AdminCommand::SetMotd {
                lines: vec!["welcome".into(), "be nice".into()]
            }
        );
        assert_eq!(run("motd"), AdminCommand::SetMotd { lines: vec![] });
    }

    #[test]
    fn op_and_deop_are_the_same_shape() {
        assert_eq!(
            run("op #r amy"),
            AdminCommand::Op {
                channel: "#r".into(),
                nick: "amy".into()
            }
        );
        assert!(matches!(run("deop #r amy"), AdminCommand::Deop { .. }));
    }

    #[test]
    fn what_is_missing_is_named() {
        assert_eq!(parse("kick"), Err("kick needs a channel".into()));
        assert_eq!(parse("kick #room"), Err("kick needs a nick".into()));
        assert_eq!(parse("say bob"), Err("say needs something to say".into()));
        assert_eq!(parse("kill"), Err("kill needs a nick".into()));
        assert!(parse("").is_err());
        assert!(parse("frobnicate").unwrap_err().contains("unknown command"));
        assert_eq!(parse("help"), Ok(Parsed::Help));
    }
}
