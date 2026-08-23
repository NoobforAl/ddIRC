//! A terminal harness that exercises `ddirc-core` without Flutter.
//!
//! This is the Phase 1 acceptance gate: if the core cannot connect, negotiate
//! SASL, join, and carry a conversation here, no amount of UI will help. It
//! also stays useful afterwards — running it alongside the app against the same
//! channel isolates core bugs from UI bugs.
//!
//! Passwords are read from the environment rather than argv, because command
//! lines are visible to other processes and land in shell history.

use std::process::ExitCode;

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{AuthOutcome, ChatMessage, ConnectionStatus, ServerConfig, Target};
use ddirc_core::conn::actor::{self, ClientCommand};
use ddirc_core::text::format::TextSpan;
use tokio::io::{AsyncBufReadExt, BufReader};
use zeroize::Zeroizing;

const USAGE: &str = "\
ddirc-cli — test harness for ddirc-core

USAGE:
    ddirc-cli --nick <NICK> [OPTIONS]

OPTIONS:
    --server <HOST>        Server hostname [default: irc.libera.chat]
    --port <PORT>          TLS port [default: 6697]
    --nick <NICK>          Nickname (required)
    --channel <CHANNEL>    Channel to join; repeatable
    --sasl-account <NAME>  SASL account name

ENVIRONMENT:
    DDIRC_SASL_PASSWORD      SASL password (with --sasl-account)
    DDIRC_NICKSERV_PASSWORD  NickServ password, used only if SASL is unavailable
    DDIRC_SERVER_PASSWORD    Server-level PASS

COMMANDS (once connected):
    /join #channel     /part [reason]     /nick <new>
    /me <action>       /msg <target> <text>
    /quit              Anything else is sent to the current channel
";

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ddirc_core=info,ddirc_cli=info".into()),
        )
        .with_target(false)
        .init();

    let config = match parse_args() {
        Ok(Some(config)) => config,
        Ok(None) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(message) => {
            eprintln!("error: {message}\n\n{USAGE}");
            return ExitCode::FAILURE;
        }
    };

    if let Err(error) = config.validate() {
        eprintln!("error: {error}");
        return ExitCode::FAILURE;
    }

    println!(
        "connecting to {}:{} as {} (TLS)",
        config.host, config.port, config.nickname
    );

    // Track a default target so plain lines can be sent without a command.
    let mut current = config.channels.first().cloned();
    let (handle, mut events) = actor::spawn(config);
    let mut stdin = BufReader::new(tokio::io::stdin()).lines();

    loop {
        tokio::select! {
            event = events.recv() => {
                let Some(event) = event else {
                    println!("-- core stopped --");
                    return ExitCode::SUCCESS;
                };
                // Adopt the first channel we actually join as the default.
                if let IrcEvent::Joined { channel, is_self: true, .. } = &event {
                    current.get_or_insert_with(|| channel.clone());
                }
                render(&event);
            }

            line = stdin.next_line() => {
                let line = match line {
                    Ok(Some(line)) => line,
                    // EOF (Ctrl-D) or a closed stdin means we are done.
                    Ok(None) | Err(_) => {
                        let _ = handle.send(ClientCommand::Disconnect {
                            reason: Some("ddirc-cli".to_owned()),
                        }).await;
                        return ExitCode::SUCCESS;
                    }
                };

                match command_for(&line, current.as_deref()) {
                    Some(Action::Send(command)) => {
                        if let ClientCommand::Join { channel, .. } = &command {
                            current = Some(channel.clone());
                        }
                        let quitting = matches!(command, ClientCommand::Disconnect { .. });
                        if handle.send(command).await.is_err() {
                            println!("-- not connected --");
                        }
                        if quitting {
                            return ExitCode::SUCCESS;
                        }
                    }
                    Some(Action::Notice(text)) => println!("-- {text} --"),
                    None => {}
                }
            }
        }
    }
}

enum Action {
    Send(ClientCommand),
    Notice(String),
}

/// Translate a typed line into an action.
fn command_for(line: &str, current: Option<&str>) -> Option<Action> {
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

    let action = match command.to_ascii_lowercase().as_str() {
        "join" if !argument.is_empty() => Action::Send(ClientCommand::Join {
            channel: argument.to_owned(),
            key: None,
        }),
        "part" => match current {
            Some(channel) => Action::Send(ClientCommand::Part {
                channel: channel.to_owned(),
                reason: (!argument.is_empty()).then(|| argument.to_owned()),
            }),
            None => Action::Notice("no current channel".to_owned()),
        },
        "nick" if !argument.is_empty() => Action::Send(ClientCommand::SetNick(argument.to_owned())),
        "me" if !argument.is_empty() => match current {
            Some(target) => Action::Send(ClientCommand::SendAction {
                target: target.to_owned(),
                text: argument.to_owned(),
            }),
            None => Action::Notice("no current channel".to_owned()),
        },
        "msg" => match argument.split_once(' ') {
            Some((target, text)) => Action::Send(ClientCommand::SendMessage {
                target: target.to_owned(),
                text: text.to_owned(),
            }),
            None => Action::Notice("usage: /msg <target> <text>".to_owned()),
        },
        "quit" => Action::Send(ClientCommand::Disconnect {
            reason: (!argument.is_empty()).then(|| argument.to_owned()),
        }),
        other => Action::Notice(format!("unknown command: /{other}")),
    };
    Some(action)
}

/// Flatten sanitised spans back to plain text for the terminal.
fn plain(spans: &[TextSpan]) -> String {
    spans.iter().map(|s| s.text.as_str()).collect()
}

fn render(event: &IrcEvent) {
    match event {
        IrcEvent::Message(message) => render_message(message),

        IrcEvent::Status { status, detail } => {
            let detail = detail.as_deref().unwrap_or("");
            let text = match status {
                ConnectionStatus::Disconnected => "disconnected".to_owned(),
                ConnectionStatus::Connecting => "connecting".to_owned(),
                ConnectionStatus::Registering => "registering".to_owned(),
                ConnectionStatus::Connected => "connected".to_owned(),
                ConnectionStatus::Reconnecting {
                    retry_in_secs,
                    attempt,
                } => {
                    format!("reconnecting in {retry_in_secs}s (attempt {attempt})")
                }
            };
            println!(
                "-- {text}{}{detail} --",
                if detail.is_empty() { "" } else { ": " }
            );
        }

        IrcEvent::Registered {
            nick,
            network,
            auth,
        } => {
            let network = network.as_deref().unwrap_or("server");
            let auth = match auth {
                AuthOutcome::Sasl => "SASL".to_owned(),
                AuthOutcome::NickServFallback { reason } => {
                    format!("NickServ fallback ({reason})")
                }
                AuthOutcome::Anonymous => "anonymous".to_owned(),
            };
            println!("-- registered on {network} as {nick} [auth: {auth}] --");
        }

        IrcEvent::NetworkNamed { network } => println!("-- network: {network} --"),

        IrcEvent::Joined { channel, nick, .. } => println!("-- {nick} joined {channel} --"),
        IrcEvent::Parted {
            channel,
            nick,
            reason,
            ..
        } => {
            println!("-- {nick} left {channel}{} --", suffix(reason.as_deref()));
        }
        IrcEvent::Quit {
            channel,
            nick,
            reason,
        } => {
            println!("-- {nick} quit [{channel}]{} --", suffix(reason.as_deref()));
        }
        IrcEvent::NickChanged {
            channel, old, new, ..
        } => {
            println!("-- {old} is now {new} [{channel}] --");
        }
        IrcEvent::TopicChanged {
            channel,
            topic,
            set_by,
        } => match set_by {
            Some(who) => println!("-- {who} set the topic of {channel}: {topic} --"),
            None => println!("-- topic for {channel}: {topic} --"),
        },
        IrcEvent::MemberList { channel, members } => {
            println!("-- {channel}: {} members --", members.len());
        }
        IrcEvent::ModeChanged {
            channel,
            by,
            affected,
        } => {
            let by = by.as_deref().unwrap_or("server");
            println!(
                "-- {by} changed modes in {channel} for {} --",
                affected.join(", ")
            );
        }
        IrcEvent::MessagesDropped { count, .. } => {
            println!("-- {count} message(s) dropped by flood protection --");
        }
        IrcEvent::Error { message, fatal } => {
            let label = if *fatal { "fatal" } else { "error" };
            eprintln!("-- {label}: {message} --");
        }
    }
}

fn render_message(message: &ChatMessage) {
    let body = plain(&message.spans);
    let scope = match &message.target {
        Target::Channel(name) => name.clone(),
        Target::Direct(nick) => format!("({nick})"),
    };
    let prefix = message.sender_prefix.as_deref().unwrap_or("");
    let mention = if message.is_mention { " *" } else { "" };

    if message.is_action {
        println!("{scope} * {prefix}{} {body}{mention}", message.sender);
    } else if message.is_notice {
        println!("{scope} -{prefix}{}- {body}{mention}", message.sender);
    } else {
        println!("{scope} <{prefix}{}> {body}{mention}", message.sender);
    }
}

fn suffix(reason: Option<&str>) -> String {
    reason.map_or_else(String::new, |r| format!(" ({r})"))
}

/// Parse argv. Returns `Ok(None)` when help was requested.
fn parse_args() -> Result<Option<ServerConfig>, String> {
    let mut config = ServerConfig {
        host: "irc.libera.chat".to_owned(),
        port: ServerConfig::DEFAULT_TLS_PORT,
        ..Default::default()
    };

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Ok(None),
            "--server" => config.host = value()?,
            "--port" => {
                let raw = value()?;
                config.port = raw.parse().map_err(|_| format!("invalid port: {raw}"))?;
            }
            "--nick" => config.nickname = value()?,
            "--channel" => config.channels.push(value()?),
            "--sasl-account" => config.sasl_account = Some(value()?),
            other => return Err(format!("unrecognised argument: {other}")),
        }
    }

    if config.nickname.is_empty() {
        return Err("--nick is required".to_owned());
    }

    // Secrets come from the environment, never argv.
    config.sasl_password = secret("DDIRC_SASL_PASSWORD");
    config.nickserv_password = secret("DDIRC_NICKSERV_PASSWORD");
    config.server_password = secret("DDIRC_SERVER_PASSWORD");

    if config.sasl_account.is_some() && config.sasl_password.is_none() {
        return Err("--sasl-account requires DDIRC_SASL_PASSWORD to be set".to_owned());
    }
    if config.sasl_password.is_some() && config.sasl_account.is_none() {
        return Err("DDIRC_SASL_PASSWORD requires --sasl-account".to_owned());
    }

    Ok(Some(config))
}

/// Read a secret from the environment and remove it from our own environment,
/// so it is not inherited by anything we might later spawn.
fn secret(name: &str) -> Option<Zeroizing<String>> {
    let value = std::env::var(name).ok()?;
    std::env::remove_var(name);
    (!value.is_empty()).then(|| Zeroizing::new(value))
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
            Some(Action::Send(ClientCommand::Join { ref channel, .. })) if channel == "#rust"
        ));
        assert!(matches!(
            command_for("/part goodbye", Some("#test")),
            Some(Action::Send(ClientCommand::Part { ref reason, .. }))
                if reason.as_deref() == Some("goodbye")
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
