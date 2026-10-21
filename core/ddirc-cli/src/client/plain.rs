//! The client as lines on stdout, for pipes, logs and scripts.
//!
//! This is the original harness: it is the Phase 1 acceptance gate for
//! `ddirc-core`, and it stays useful because it prints everything and hides
//! nothing. If the core cannot connect, negotiate SASL, join, and carry a
//! conversation here, no amount of UI will help. Running it alongside the app
//! against the same channel isolates core bugs from UI bugs.

use std::process::ExitCode;

use ddirc_core::api::events::IrcEvent;
use ddirc_core::api::types::{AuthOutcome, ChatMessage, ConnectionStatus, Target};
use ddirc_core::conn::actor::ClientCommand;
use ddirc_core::text::format::TextSpan;
use tokio::io::{AsyncBufReadExt, BufReader};

use super::commands::{command_for, command_for_with, Action, HELP};
use crate::cli::Connection;

pub async fn run(connection: Connection) -> ExitCode {
    if let Err(error) = connection.validate() {
        eprintln!("error: {error}");
        return ExitCode::FAILURE;
    }

    println!("{}", connection.describe());

    // Track a default target so plain lines can be sent without a command.
    let mut current = connection.first_channel();
    let xmpp = connection.is_xmpp();
    // The rooms joined, for an XMPP account: there a room is an address like a
    // person's, so what has been joined is the only thing that tells them apart.
    let mut rooms: Vec<String> = Vec::new();
    let (handle, mut events) = connection.spawn();
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
                    if !rooms.contains(channel) {
                        rooms.push(channel.clone());
                    }
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
                        say_goodbye(&mut events).await;
                        return ExitCode::SUCCESS;
                    }
                };

                let action = if xmpp {
                    let is_room = |name: &str| {
                        rooms.iter().any(|r| r.eq_ignore_ascii_case(name))
                            || (name.contains('@') && !name.contains('/'))
                    };
                    command_for_with(&line, current.as_deref(), &is_room, false)
                } else {
                    command_for(&line, current.as_deref())
                };
                match action {
                    Some(Action::Send(command)) => {
                        if let ClientCommand::Join { channel, .. } = &command {
                            current = Some(channel.clone());
                        }
                        let quitting = matches!(command, ClientCommand::Disconnect { .. });
                        if handle.send(command).await.is_err() {
                            println!("-- not connected --");
                        }
                        if quitting {
                            say_goodbye(&mut events).await;
                            return ExitCode::SUCCESS;
                        }
                    }
                    Some(Action::Notice(text)) => println!("-- {text} --"),
                    // No tabs to open here, so the nick becomes the target of
                    // whatever is typed next.
                    Some(Action::Query(nick)) => {
                        println!("-- talking to {nick} --");
                        current = Some(nick);
                    }
                    Some(Action::Help) => {
                        for (usage, what) in HELP {
                            println!("-- {usage:<28} {what}");
                        }
                    }
                    Some(Action::Close | Action::Clear) => {
                        println!("-- there is only one stream of text here; try without --no-tui --");
                    }
                    None => {}
                }
            }
        }
    }
}

/// Let the core finish saying goodbye before the process ends.
///
/// Returning the moment the command is queued exits before the `QUIT` has been
/// written, and the server then reports a dropped connection instead of the
/// reason that was typed. Two seconds is generous for one line.
async fn say_goodbye(events: &mut tokio::sync::mpsc::Receiver<IrcEvent>) {
    let _ = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        while let Some(event) = events.recv().await {
            render(&event);
        }
    })
    .await;
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
        IrcEvent::MemberChanged {
            channel,
            previous,
            member,
        } => match member {
            Some(member) if member.nick != *previous => {
                println!("-- {channel}: {previous} is now {} --", member.nick);
            }
            Some(member) => {
                let away = if member.away { " (away)" } else { "" };
                println!(
                    "-- {channel}: {}{}{} --",
                    member.prefix.as_deref().unwrap_or_default(),
                    member.nick,
                    away
                );
            }
            None => println!("-- {channel}: {previous} is gone --"),
        },
        IrcEvent::FileOffered {
            channel,
            from,
            offer,
            ..
        } => {
            // Printed, and that is all the harness does with it — the same
            // policy the core has. Accepting means dialling an address a
            // stranger chose, which is not something a test harness decides.
            let size = match offer.size {
                Some(bytes) => format!(", {bytes} bytes"),
                None => String::new(),
            };
            let how = if offer.is_reverse() {
                "reverse".to_owned()
            } else {
                match (offer.addr, offer.port) {
                    (Some(addr), Some(port)) => format!("{addr}:{port}"),
                    _ => "?".to_owned(),
                }
            };
            println!(
                "-- {from} offered \"{}\" [{channel}] via {how}{size} --",
                offer.filename
            );
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
        // The harness offers no files and accepts none, so these only ever
        // arrive if something else on this connection started a transfer.
        // Printed rather than ignored, because a silent transfer is the one
        // thing a diagnostic tool should never allow.
        IrcEvent::FileTransferStarted {
            filename,
            incoming,
            total,
            ..
        } => {
            let direction = if *incoming { "receiving" } else { "sending" };
            let size = match total {
                Some(bytes) => format!(", {bytes} bytes"),
                None => String::new(),
            };
            println!("-- {direction} \"{filename}\"{size} --");
        }
        IrcEvent::FileTransferProgress { .. } => {}
        IrcEvent::Contact(_)
        | IrcEvent::ContactRemoved { .. }
        | IrcEvent::UploadAvailable { .. } => {}
        IrcEvent::SubscriptionRequest { jid } => {
            println!(
                "-- {jid} asks to see when you are online: /accept {jid} or /decline {jid} --"
            );
        }
        IrcEvent::MessageEdited {
            target,
            sender,
            message,
            ..
        } => {
            println!(
                "({}) * {sender} corrected a message: {}",
                target.name(),
                plain(&message.spans)
            );
        }
        IrcEvent::MessageRetracted { target, sender, .. } => {
            println!("({}) * {sender} deleted a message", target.name());
        }
        IrcEvent::FileTransferEnded {
            filename,
            path,
            error,
            ..
        } => match error {
            Some(reason) => println!("-- \"{filename}\" failed: {reason} --"),
            None => match path {
                Some(path) => println!("-- \"{filename}\" saved to {path} --"),
                None => println!("-- \"{filename}\" sent --"),
            },
        },
        // Only the finished answer. A LIST reports itself as it arrives so a
        // browser can fill in, and reprinting the busiest hundred every couple
        // of thousand replies would bury the scrollback in redraws of the same
        // list.
        IrcEvent::ChannelList {
            channels,
            done: true,
            truncated,
        } => {
            for channel in channels {
                let topic = if channel.topic.is_empty() {
                    String::new()
                } else {
                    format!("  {}", channel.topic)
                };
                println!("{:>6}  {}{topic}", channel.users, channel.name);
            }
            let count = channels.len();
            if *truncated {
                println!("-- the {count} busiest; there are more --");
            } else {
                println!("-- {count} channels --");
            }
        }
        IrcEvent::ChannelList { done: false, .. } => {}

        IrcEvent::Whois(whois) if !whois.found => println!("-- no such nick: {} --", whois.nick),
        IrcEvent::Whois(whois) => {
            println!(
                "-- {} is {}@{} ({}) --",
                whois.nick,
                whois.user.as_deref().unwrap_or("?"),
                whois.host.as_deref().unwrap_or("?"),
                whois.realname.as_deref().unwrap_or(""),
            );
            if !whois.channels.is_empty() {
                println!("-- on {} --", whois.channels.join(" "));
            }
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
