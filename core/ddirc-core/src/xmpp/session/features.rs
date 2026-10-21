//! What a person does on top of chatting: keep contacts, say how they are,
//! correct what they wrote, share a file.
//!
//! The same [`Session`] as the rest, in a file of its own because these are
//! the parts that can be left alone and the conversation still works. Each one
//! is a request the user made or a thing the server told us, and none is ever
//! answered on the user's behalf.

use super::*;

impl Session {
    // ---- contacts -----------------------------------------------------

    /// A person's address from what was typed or clicked: the bare form, since
    /// a contact is a person and not one of the places they are signed in.
    fn contact_jid(&self, text: &str) -> Option<BareJid> {
        let jid = text.trim().parse::<Jid>().ok()?.to_bare();
        // A person has a name before the `@`.
        jid.node()?;
        Some(jid)
    }

    pub(super) fn add_contact(&mut self, text: &str, name: Option<&str>, fx: &mut Effects) {
        let Some(jid) = self.contact_jid(text) else {
            fx.error(format!(
                "'{}' is not a person's address; it looks like name@example.org.",
                clean_name(text)
            ));
            return;
        };
        if jid == self.account {
            fx.error("That is your own address.");
            return;
        }
        if self.rooms.contains_key(&jid) {
            fx.error("That is a room. Join it instead of adding it as a contact.");
            return;
        }
        if !self.contacts.contains(&jid) && self.contacts.is_full() {
            fx.error("Your contact list is full.");
            return;
        }
        let name = name.map(clean_name).filter(|n| !n.is_empty());

        // Put them on the list, and ask to see them. Two requests, in this
        // order: the server will not forward a subscription for someone who is
        // not on the list.
        let id = self.next_id();
        self.pending
            .insert(id.clone(), Pending::RosterSet { jid: jid.clone() });
        fx.send(Iq::from_set(
            id,
            Roster {
                ver: None,
                items: vec![Item {
                    jid: jid.clone(),
                    name,
                    subscription: RosterSubscription::None,
                    ask: Ask::None,
                    groups: Vec::new(),
                    approved: None,
                }],
            },
        ));
        fx.send(Presence::subscribe().with_to(Jid::from(jid)));
    }

    pub(super) fn remove_contact(&mut self, text: &str, fx: &mut Effects) {
        let Some(jid) = self.contact_jid(text) else {
            fx.error(format!("'{}' is not an address.", clean_name(text)));
            return;
        };
        let id = self.next_id();
        self.pending
            .insert(id.clone(), Pending::RosterSet { jid: jid.clone() });
        fx.send(Iq::from_set(
            id,
            Roster {
                ver: None,
                items: vec![Item {
                    jid,
                    name: None,
                    subscription: RosterSubscription::Remove,
                    ask: Ask::None,
                    groups: Vec::new(),
                    approved: None,
                }],
            },
        ));
    }

    pub(super) fn answer_subscription(&mut self, text: &str, accept: bool, fx: &mut Effects) {
        let Some(jid) = self.contact_jid(text) else {
            fx.error(format!("'{}' is not an address.", clean_name(text)));
            return;
        };
        // Only a request that was made. Granting presence to someone who never
        // asked is telling them we exist and are reading, unasked, which is
        // exactly what waiting for the user's answer is there to prevent.
        if !self.contacts.take_request(&jid) {
            fx.error(format!("{jid} has not asked to see you."));
            return;
        }
        let answer = if accept {
            Presence::subscribed()
        } else {
            Presence::new(PresenceType::Unsubscribed)
        };
        fx.send(answer.with_to(Jid::from(jid)));
    }

    /// A roster update the server pushed.
    ///
    /// Believed only from our own server - no `from`, or our own bare address.
    /// A push from anyone else is a way to put a name on someone else's list.
    pub(super) fn on_roster_push(
        &mut self,
        from: Option<Jid>,
        id: String,
        payload: Element,
        fx: &mut Effects,
    ) {
        let ours = from
            .as_ref()
            .is_none_or(|f| f.resource().is_none() && f.to_bare() == self.account);
        let roster = if ours {
            Roster::try_from(payload).ok()
        } else {
            None
        };
        let Some(roster) = roster else {
            let error = StanzaError::new(
                ErrorType::Cancel,
                DefinedCondition::ServiceUnavailable,
                "en",
                "",
            );
            let mut reply = Iq::from_error(id, error);
            *reply.to_mut() = from;
            fx.send(reply);
            return;
        };
        for event in self
            .contacts
            .apply_roster(roster.items, &self.account, false)
        {
            fx.event(event);
        }
        // A push is a request, and has to be answered.
        fx.send(Iq::empty_result(
            from.unwrap_or_else(|| Jid::from(self.account.clone())),
            id,
        ));
    }

    // ---- how we are ---------------------------------------------------

    /// The presence that says how the user is: plain when they have said
    /// nothing, and otherwise what they said.
    pub(super) fn own_presence(&self) -> Presence {
        let mut presence = Presence::available();
        if let Some((availability, status)) = &self.own {
            presence.show = match availability {
                Availability::Away => Some(Show::Away),
                Availability::Dnd => Some(Show::Dnd),
                Availability::ExtendedAway => Some(Show::Xa),
                Availability::Available | Availability::Offline => None,
            };
            if !status.is_empty() {
                presence.set_status("", status.clone());
            }
        }
        presence
    }

    pub(super) fn set_availability(
        &mut self,
        availability: Availability,
        status: Option<&str>,
        fx: &mut Effects,
    ) {
        let status = status
            .map(|s| clean_line(s, STATUS_CHARS))
            .unwrap_or_default();
        self.own = Some((availability, status));
        // To everyone who can see us, and to each room we are in: a room has
        // its own idea of who is there and does not hear the first.
        fx.send(self.own_presence());
        let joined: Vec<(BareJid, String)> = self
            .rooms
            .values()
            .filter(|r| r.joined)
            .map(|r| (r.jid.clone(), r.nick.clone()))
            .collect();
        for (jid, nick) in joined {
            if let Ok(occupant) = jid.with_resource_str(&nick) {
                fx.send(self.own_presence().with_to(Jid::from(occupant)));
            }
        }
    }

    // ---- correcting and taking back ---------------------------------------

    /// Where a conversation's messages go, and whether it is a room.
    fn destination(&self, target: &str) -> Option<(Jid, bool)> {
        let to = target.trim().parse::<Jid>().ok()?;
        let group = self.rooms.contains_key(&to.to_bare()) && to.resource().is_none();
        Some((to, group))
    }

    pub(super) fn edit(&mut self, target: &str, msgid: &str, text: &str, fx: &mut Effects) {
        let Some((to, group)) = self.destination(target) else {
            fx.error(format!("'{}' is not an address.", clean_name(target)));
            return;
        };
        let Some(entry) = self.index.ours(target, msgid).cloned() else {
            fx.error("That message can no longer be edited.");
            return;
        };
        let Some(origin) = entry.origin.clone() else {
            fx.error("That message can no longer be edited.");
            return;
        };
        let mut parts = sanitize_outgoing(text);
        if parts.len() != 1 {
            fx.error(if parts.is_empty() {
                "An edited message cannot be empty. Delete it instead."
            } else {
                "That is too long to edit into one message."
            });
            return;
        }
        let body = parts.remove(0);
        let id = self.next_id();
        fx.send(edits::correction(to, group, &id, &origin, body.clone()));

        // A room reflects the correction and that is what is shown, as it does
        // a message. A person does not, so it is shown now.
        if !group {
            let (reply_to, shown) = split_reply(&body);
            let message = ChatMessage {
                target: Target::Direct(target.to_owned()),
                sender: self.account.to_string(),
                sender_prefix: None,
                spans: format::parse(shown),
                is_self: true,
                is_mention: false,
                is_action: false,
                is_notice: false,
                msgid: Some(entry.msgid.clone()),
                server_time_ms: None,
                reply_to,
            };
            fx.event(IrcEvent::MessageEdited {
                target: Target::Direct(target.to_owned()),
                msgid: entry.msgid,
                sender: self.account.to_string(),
                message: Box::new(message),
            });
        }
    }

    pub(super) fn retract(&mut self, target: &str, msgid: &str, fx: &mut Effects) {
        let Some((to, group)) = self.destination(target) else {
            fx.error(format!("'{}' is not an address.", clean_name(target)));
            return;
        };
        let Some(entry) = self.index.ours(target, msgid).cloned() else {
            fx.error("That message can no longer be deleted.");
            return;
        };
        let id = self.next_id();
        // Named by the id the UI knows it by: the room's own, in a room, which
        // is what retraction asks for there, and the sender's own in a chat,
        // which is the same thing.
        fx.send(edits::retract(to, group, &id, &entry.msgid));
        if !group {
            self.index.forget(target, &entry.msgid);
            fx.event(IrcEvent::MessageRetracted {
                target: Target::Direct(target.to_owned()),
                msgid: entry.msgid,
                sender: self.account.to_string(),
            });
        }
    }

    // ---- sharing a file ---------------------------------------------------

    /// Whether the server has somewhere to put a file, and how large one may be.
    pub fn upload_limit(&self) -> Option<u64> {
        self.upload.as_ref().map(upload::limit)
    }

    /// Start sharing a file: ask the server for a slot.
    ///
    /// Returns the ticket that names the upload, or `None` with the reason in
    /// the effects. The caller has already read the file's size and name and
    /// holds the file; this decides whether it may be sent at all.
    pub fn begin_upload(
        &mut self,
        target: &str,
        filename: &str,
        size: u64,
    ) -> (Option<u64>, Effects) {
        let mut fx = Effects::default();
        let Some((to, group)) = self.destination(target) else {
            fx.error(format!("'{}' is not an address.", clean_name(target)));
            return (None, fx);
        };
        let Some(service) = self.upload.clone() else {
            fx.error("This server has nowhere to put a file.");
            return (None, fx);
        };
        if group && self.rooms.get(&to.to_bare()).is_none_or(|r| !r.joined) {
            fx.error(format!("You are not in {} yet.", to.to_bare()));
            return (None, fx);
        }
        if size == 0 {
            fx.error("That file is empty.");
            return (None, fx);
        }
        let limit = upload::limit(&service);
        if size > limit {
            fx.error(format!(
                "That file is larger than this server takes ({} MB).",
                limit / (1024 * 1024)
            ));
            return (None, fx);
        }
        if self.tickets.len() >= MAX_UPLOADS {
            fx.error("Too many files are already being sent. Wait for one to finish.");
            return (None, fx);
        }

        // Only the name, and only what is fit to show: a path is the user's,
        // and a name with control characters is not one to put in a request.
        let filename = clean_line(filename.rsplit(['/', '\\']).next().unwrap_or(filename), 100);
        let filename = if filename.is_empty() {
            "file".to_owned()
        } else {
            filename
        };

        self.next_ticket += 1;
        let ticket = self.next_ticket;
        self.tickets.insert(
            ticket,
            Ticket {
                target: target.to_owned(),
                filename: filename.clone(),
                get: None,
            },
        );
        fx.event(IrcEvent::FileTransferStarted {
            id: ticket,
            channel: target.to_owned(),
            filename: filename.clone(),
            incoming: false,
            total: Some(size),
        });
        let id = self.next_id();
        self.pending.insert(id.clone(), Pending::Slot { ticket });
        fx.send(
            Iq::from_get(
                id,
                SlotRequest {
                    content_type: Some(upload::content_type(&filename).to_owned()),
                    filename,
                    size,
                },
            )
            .with_to(service.jid),
        );
        (Some(ticket), fx)
    }

    /// The server's answer to a slot request.
    pub(super) fn on_slot(&mut self, ticket: u64, payload: Option<Element>, fx: &mut Effects) {
        if !self.tickets.contains_key(&ticket) {
            return;
        }
        let Some(result) = payload.and_then(|p| SlotResult::try_from(p).ok()) else {
            self.fail_upload(
                ticket,
                "The server's answer about where to put it was not understood.",
                fx,
            );
            return;
        };
        let slot = match upload::check_slot(&result, self.account.domain().as_str()) {
            Ok(slot) => slot,
            Err(error) => {
                self.fail_upload(ticket, &format!("{error}."), fx);
                return;
            }
        };
        let Some(entry) = self.tickets.get_mut(&ticket) else {
            return;
        };
        entry.get = Some(slot.get.clone());
        let content_type = upload::content_type(&entry.filename);
        fx.uploads.push(UploadJob {
            ticket,
            slot,
            content_type,
        });
    }

    /// An upload stopped before it was sent, or finished with an error.
    pub(super) fn fail_upload(&mut self, ticket: u64, why: &str, fx: &mut Effects) {
        let Some(entry) = self.tickets.remove(&ticket) else {
            return;
        };
        fx.event(IrcEvent::FileTransferEnded {
            id: ticket,
            channel: entry.target,
            filename: entry.filename,
            path: None,
            error: Some(why.to_owned()),
        });
    }

    /// The bytes have been sent, or could not be.
    ///
    /// On success the link is sent to whoever the file was for, as a message
    /// that also names it as the thing the message is about.
    pub fn upload_finished(&mut self, ticket: u64, result: Result<(), String>) -> Effects {
        let mut fx = Effects::default();
        if let Err(why) = result {
            self.fail_upload(ticket, &why, &mut fx);
            return fx;
        }
        let Some(entry) = self.tickets.remove(&ticket) else {
            return fx;
        };
        let Some(get) = entry.get else {
            return fx;
        };
        // The link first, and only then the card. A file that is on the server
        // and whose link never reached anyone (the room was left, or the
        // connection dropped, while the bytes were on their way) is not a file
        // that was sent, and a card that says it was would be a lie.
        let mut sent = Effects::default();
        self.say_with(&entry.target, &get, false, Some(&get), &mut sent);
        let refused = sent.events.iter().find_map(|e| match e {
            IrcEvent::Error { message, .. } => Some(message.clone()),
            _ => None,
        });
        let outcome =
            refused.map(|why| format!("It was uploaded, but the link was not sent: {why}"));
        fx.event(IrcEvent::FileTransferEnded {
            id: ticket,
            channel: entry.target.clone(),
            filename: entry.filename,
            path: None,
            error: outcome.clone(),
        });
        if outcome.is_none() {
            fx.events.extend(sent.events);
            fx.send.extend(sent.send);
        }
        fx
    }
}

#[cfg(test)]
mod tests;
