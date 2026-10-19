//! The operator's commands, applied.
//!
//! A child of [`super`] so it can reach the state it changes without that state
//! being public. Everything here runs on the one task that owns the [`Network`],
//! between two client messages like any other event, which is why none of it
//! takes a lock: an admin command cannot observe a half-applied `JOIN`.
//!
//! Each command returns a sentence, success or refusal, because that sentence
//! is the whole user interface of a command line: "kicked bob from #room" and
//! "bob is not in #room" are the two outcomes the operator needs told apart.

use super::*;
use crate::admin::{AdminCommand, ChannelInfo, MemberInfo, Snapshot, UserInfo};

/// Longest MOTD line kept. A line is sent as one `372` and has to fit in 512
/// bytes with its prefix; this is comfortably inside that.
const MOTD_LINE_LEN: usize = 300;

impl Network {
    /// Apply `command`, and tell the operator's view how it went.
    pub fn run_admin(&mut self, command: AdminCommand) -> Result<String, String> {
        let outcome = self.execute(command);
        let (ok, text) = match &outcome {
            Ok(text) => (true, text.clone()),
            Err(text) => (false, text.clone()),
        };
        self.emit(EventKind::Admin { ok, text });
        outcome
    }

    fn execute(&mut self, command: AdminCommand) -> Result<String, String> {
        match command {
            AdminCommand::Kick {
                channel,
                nick,
                reason,
            } => {
                let (key, victim) = self.member(&channel, &nick)?;
                let shown = self.channels[&key].name.clone();
                let reason = reason.map(|r| truncate(&r, TOPIC_LEN));
                self.kick_member(&key, victim, self.server_prefix(), reason.as_deref());
                Ok(format!("kicked {nick} from {shown}"))
            }

            AdminCommand::Disconnect { nick, reason } => {
                let id = self.registered(&nick)?;
                let name = self.nick_of(id);
                self.close(id, reason.as_deref().unwrap_or("Removed by the operator"));
                Ok(format!("disconnected {name}"))
            }

            AdminCommand::Ban { nick, reason } => {
                if !valid_nick(&nick) {
                    return Err(format!("{nick} is not a nickname"));
                }
                if !self.banned.insert(fold(&nick)) {
                    return Err(format!("{nick} is already banned"));
                }
                // The ban is on the name; whoever is wearing it right now goes
                // too, or the ban would only apply to the next person.
                if let Some(&id) = self.nicks.get(&fold(&nick)) {
                    let why = reason.as_deref().unwrap_or("Banned by the operator");
                    self.close(id, &format!("Banned: {why}"));
                }
                Ok(format!("banned {nick}"))
            }

            AdminCommand::Unban { nick } => {
                if self.banned.remove(&fold(&nick)) {
                    Ok(format!("unbanned {nick}"))
                } else {
                    Err(format!("{nick} is not banned"))
                }
            }

            AdminCommand::SetTopic { channel, topic } => {
                let key = self.channel_key(&channel)?;
                let topic = truncate(&topic, TOPIC_LEN);
                let server = self.server_name.clone();
                let shown = self.channels[&key].name.clone();
                if let Some(c) = self.channels.get_mut(&key) {
                    c.topic = (!topic.is_empty()).then(|| Topic {
                        text: topic.clone(),
                        set_by: server.clone(),
                        at: now(),
                    });
                }
                self.emit(EventKind::Topic {
                    channel: shown.clone(),
                    by: server,
                    topic: topic.clone(),
                });
                let change = Message {
                    tags: None,
                    prefix: Some(self.server_prefix()),
                    command: Command::TOPIC(shown.clone(), Some(topic)),
                };
                self.broadcast(&key, change, None);
                Ok(format!("topic of {shown} updated"))
            }

            AdminCommand::CloseChannel { channel, reason } => {
                let key = self.channel_key(&channel)?;
                let shown = self.channels[&key].name.clone();
                let reason = reason.map(|r| truncate(&r, TOPIC_LEN));
                let why = reason
                    .as_deref()
                    .unwrap_or("Channel closed by the operator");
                // Collected first: kicking the last member removes the channel,
                // and iterating a set that is being emptied is not iterating.
                let mut members: Vec<ClientId> =
                    self.channels[&key].members.iter().copied().collect();
                members.sort_unstable();
                let count = members.len();
                for member in members {
                    self.kick_member(&key, member, self.server_prefix(), Some(why));
                }
                Ok(format!("closed {shown} ({count} removed)"))
            }

            AdminCommand::Op { channel, nick } => self.set_op(&channel, &nick, true),
            AdminCommand::Deop { channel, nick } => self.set_op(&channel, &nick, false),

            AdminCommand::Notice { target, text } => {
                let text = truncate(&text, TOPIC_LEN);
                if text.is_empty() {
                    return Err("nothing to say".to_owned());
                }
                let message = self.server_notice(&target, &text);
                if is_channel(&target) {
                    let key = self.channel_key(&target)?;
                    self.broadcast(&key, message, None);
                } else {
                    let id = self.registered(&target)?;
                    self.send(id, message);
                }
                Ok(format!("sent to {target}"))
            }

            AdminCommand::Wall { text } => {
                let text = truncate(&text, TOPIC_LEN);
                if text.is_empty() {
                    return Err("nothing to say".to_owned());
                }
                let everyone: Vec<ClientId> = self
                    .clients
                    .iter()
                    .filter(|(_, c)| c.registered)
                    .map(|(&id, _)| id)
                    .collect();
                for &id in &everyone {
                    let nick = self.nick_of(id);
                    self.send(id, self.server_notice(&nick, &text));
                }
                Ok(format!("sent to {} connected", everyone.len()))
            }

            AdminCommand::SetMotd { lines } => {
                let lines: Vec<String> = lines
                    .iter()
                    .map(|l| {
                        let clean: String = l.chars().filter(|c| !c.is_control()).collect();
                        truncate(&clean, MOTD_LINE_LEN)
                    })
                    .filter(|l| !l.is_empty())
                    .collect();
                if lines.is_empty() {
                    self.motd = default_motd();
                    Ok("message of the day restored to the default".to_owned())
                } else {
                    let n = lines.len();
                    self.motd = lines;
                    Ok(format!("message of the day set ({n} lines)"))
                }
            }
        }
    }

    /// A copy of what the operator's view needs.
    pub fn snapshot(&self) -> Snapshot {
        let shown = |keys: &HashSet<String>| -> Vec<String> {
            let mut names: Vec<String> = keys
                .iter()
                .filter_map(|k| self.channels.get(k).map(|c| c.name.clone()))
                .collect();
            names.sort_by_key(|n| fold(n));
            names
        };

        let mut users: Vec<UserInfo> = self
            .clients
            .iter()
            .map(|(&id, c)| UserInfo {
                id,
                nick: c.nick.clone(),
                user: c.user.clone(),
                realname: c.real.clone(),
                registered: c.registered,
                channels: shown(&c.channels),
                connected_at: c.connected_at,
            })
            .collect();
        // Registered people by nick, then the connections that have not got
        // that far, oldest first.
        users.sort_by(|a, b| {
            b.registered
                .cmp(&a.registered)
                .then_with(|| {
                    a.nick
                        .as_deref()
                        .map(fold)
                        .cmp(&b.nick.as_deref().map(fold))
                })
                .then_with(|| a.id.cmp(&b.id))
        });

        let mut channels: Vec<ChannelInfo> = self
            .channels
            .values()
            .map(|c| {
                let mut members: Vec<MemberInfo> = c
                    .members
                    .iter()
                    .filter_map(|m| {
                        Some(MemberInfo {
                            nick: self.clients.get(m)?.nick.clone()?,
                            op: c.operators.contains(m),
                        })
                    })
                    .collect();
                members.sort_by(|a, b| {
                    b.op.cmp(&a.op)
                        .then_with(|| fold(&a.nick).cmp(&fold(&b.nick)))
                });
                ChannelInfo {
                    name: c.name.clone(),
                    topic: c.topic.as_ref().map(|t| t.text.clone()),
                    topic_set_by: c.topic.as_ref().map(|t| t.set_by.clone()),
                    members,
                }
            })
            .collect();
        channels.sort_by_key(|c| fold(&c.name));

        let mut banned: Vec<String> = self.banned.iter().cloned().collect();
        banned.sort();

        Snapshot {
            server_name: self.server_name.clone(),
            network_name: self.network_name.clone(),
            started_at: self.started_at,
            connections_total: self.connections_total,
            messages_total: self.messages_total,
            users,
            channels,
            banned,
            motd: self.motd.clone(),
        }
    }

    // ----------------------------------------------------------------- helpers

    fn server_prefix(&self) -> Prefix {
        Prefix::ServerName(self.server_name.clone())
    }

    /// A notice from the operator, as a client will actually show one.
    ///
    /// Sent from a nick-shaped prefix named for the server rather than from the
    /// bare server name. A client treats a message with no nickname behind it
    /// as server chatter — the connection-time `*** Looking up your hostname`
    /// kind — and drops it, which is the right call for those and the wrong
    /// one for words the operator typed and wants read.
    fn server_notice(&self, target: &str, text: &str) -> Message {
        Message {
            tags: None,
            prefix: Some(Prefix::Nickname(
                self.server_name.clone(),
                "server".to_owned(),
                HOST.to_owned(),
            )),
            command: Command::NOTICE(target.to_owned(), text.to_owned()),
        }
    }

    /// The registered client holding `nick`. Connections that have not
    /// registered have no name worth addressing them by.
    fn registered(&self, nick: &str) -> Result<ClientId, String> {
        self.nicks
            .get(&fold(nick))
            .copied()
            .filter(|&id| self.is_registered(id))
            .ok_or_else(|| format!("no such nick: {nick}"))
    }

    fn channel_key(&self, name: &str) -> Result<String, String> {
        let key = fold(name);
        if self.channels.contains_key(&key) {
            Ok(key)
        } else {
            Err(format!("no such channel: {name}"))
        }
    }

    /// A channel and someone in it, or the reason there is no such pair.
    fn member(&self, channel: &str, nick: &str) -> Result<(String, ClientId), String> {
        let key = self.channel_key(channel)?;
        let id = self.registered(nick)?;
        if self.channels[&key].members.contains(&id) {
            Ok((key, id))
        } else {
            Err(format!("{nick} is not in {channel}"))
        }
    }

    fn set_op(&mut self, channel: &str, nick: &str, give: bool) -> Result<String, String> {
        let (key, id) = self.member(channel, nick)?;
        let shown = self.channels[&key].name.clone();
        let name = self.nick_of(id);
        let changed = match self.channels.get_mut(&key) {
            Some(c) if give => c.operators.insert(id),
            Some(c) => c.operators.remove(&id),
            None => false,
        };
        let verb = if give {
            "an operator"
        } else {
            "not an operator"
        };
        if !changed {
            return Err(format!("{name} is already {verb} in {shown}"));
        }
        let mode = Message {
            tags: None,
            prefix: Some(self.server_prefix()),
            command: Command::Raw(
                "MODE".to_owned(),
                vec![
                    shown.clone(),
                    if give { "+o" } else { "-o" }.to_owned(),
                    name.clone(),
                ],
            ),
        };
        self.broadcast(&key, mode, None);
        self.emit(EventKind::Mode {
            channel: shown.clone(),
            by: self.server_name.clone(),
            nick: name.clone(),
            op: give,
        });
        Ok(format!("{name} is now {verb} in {shown}"))
    }

    /// End a connection from the server's side.
    ///
    /// The person is told why, on the connection that is about to close, and
    /// everyone who shared a channel with them is told they quit — the same
    /// announcement a departure the ordinary way produces, because to the
    /// people left behind it is the same event.
    pub(super) fn close(&mut self, id: ClientId, reason: &str) {
        let reason = truncate(reason, TOPIC_LEN);
        self.send(
            id,
            Message {
                tags: None,
                prefix: None,
                command: Command::ERROR(format!("Closing Link: {HOST} ({reason})")),
            },
        );
        if let Some(client) = self.clients.get_mut(&id) {
            client.quit_reason = Some(reason.clone());
        }
        self.disconnect(id, &reason);
    }
}

#[cfg(test)]
mod tests;
