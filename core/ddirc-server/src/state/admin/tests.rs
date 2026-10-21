use super::*;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver};

fn network(n: u64) -> (Network, Vec<UnboundedReceiver<Message>>) {
    let mut net = Network::new(DEFAULT_SERVER_NAME, DEFAULT_NETWORK_NAME);
    let mut rxs = Vec::new();
    for id in 0..n {
        let (tx, rx) = unbounded_channel();
        net.connect(id, tx);
        rxs.push(rx);
    }
    (net, rxs)
}

fn register(net: &mut Network, id: ClientId, nick: &str) {
    net.handle(id, Message::new(None, "NICK", vec![nick]).unwrap());
    net.handle(
        id,
        Message::new(None, "USER", vec![nick, "0", "*", "Real"]).unwrap(),
    );
}

fn say(net: &mut Network, id: ClientId, command: &str, args: Vec<&str>) {
    net.handle(id, Message::new(None, command, args).unwrap());
}

fn drain(rx: &mut UnboundedReceiver<Message>) -> Vec<String> {
    let mut out = Vec::new();
    while let Ok(m) = rx.try_recv() {
        out.push(m.to_string().trim_end().to_owned());
    }
    out
}

fn has(lines: &[String], needle: &str) -> bool {
    lines.iter().any(|l| l.contains(needle))
}

/// alice (the operator, having created it) and bob in `#room`, queues empty.
fn room() -> (Network, Vec<UnboundedReceiver<Message>>) {
    let (mut net, mut rxs) = network(2);
    register(&mut net, 0, "alice");
    register(&mut net, 1, "bob");
    say(&mut net, 0, "JOIN", vec!["#room"]);
    say(&mut net, 1, "JOIN", vec!["#room"]);
    for rx in &mut rxs {
        drain(rx);
    }
    (net, rxs)
}

#[test]
fn the_operator_can_kick_and_the_victim_is_told_first() {
    let (mut net, mut rxs) = room();

    let outcome = net.run_admin(AdminCommand::Kick {
        channel: "#ROOM".to_owned(),
        nick: "BOB".to_owned(),
        reason: Some("spam".to_owned()),
    });
    assert_eq!(outcome, Ok("kicked BOB from #room".to_owned()));

    let line = ":ddirc.local KICK #room bob spam";
    assert!(has(&drain(&mut rxs[1]), line), "the victim hears why");
    assert!(has(&drain(&mut rxs[0]), line), "so does the room");

    // Out of the room, still on the server: a message to the room is now
    // refused, and a message to alice is not.
    say(&mut net, 1, "PRIVMSG", vec!["#room", "hello"]);
    assert!(has(&drain(&mut rxs[1]), " 404 "));
    say(&mut net, 1, "PRIVMSG", vec!["alice", "still here"]);
    assert!(has(&drain(&mut rxs[0]), "still here"));
}

#[test]
fn a_refusal_says_what_was_wrong() {
    let (mut net, _rxs) = room();
    let kick = |net: &mut Network, channel: &str, nick: &str| {
        net.run_admin(AdminCommand::Kick {
            channel: channel.to_owned(),
            nick: nick.to_owned(),
            reason: None,
        })
    };
    assert_eq!(
        kick(&mut net, "#nowhere", "bob"),
        Err("no such channel: #nowhere".into())
    );
    assert_eq!(
        kick(&mut net, "#room", "carol"),
        Err("no such nick: carol".into())
    );

    say(&mut net, 1, "PART", vec!["#room"]);
    assert_eq!(
        kick(&mut net, "#room", "bob"),
        Err("bob is not in #room".into())
    );
}

#[test]
fn a_channel_operator_can_kick_but_nobody_else_can() {
    let (mut net, mut rxs) = room();

    // bob is not an operator.
    say(&mut net, 1, "KICK", vec!["#room", "alice", "coup"]);
    assert!(has(&drain(&mut rxs[1]), " 482 "), "bob may not");
    assert!(
        drain(&mut rxs[0]).is_empty(),
        "and nothing happened to alice"
    );

    // alice created the room, so she may.
    say(&mut net, 0, "KICK", vec!["#room", "bob", "bye"]);
    assert!(has(
        &drain(&mut rxs[1]),
        "alice!alice@localhost KICK #room bob bye"
    ));

    // And an absent target is an error for her, not a silent no-op.
    say(&mut net, 0, "KICK", vec!["#room", "bob"]);
    assert!(has(&drain(&mut rxs[0]), " 441 "));
}

#[test]
fn disconnecting_says_goodbye_to_the_room_and_the_person() {
    let (mut net, mut rxs) = room();

    let outcome = net.run_admin(AdminCommand::Disconnect {
        nick: "bob".to_owned(),
        reason: Some("maintenance".to_owned()),
    });
    assert_eq!(outcome, Ok("disconnected bob".to_owned()));

    assert!(has(
        &drain(&mut rxs[1]),
        "ERROR :Closing Link: localhost (maintenance)"
    ));
    assert!(has(
        &drain(&mut rxs[0]),
        "bob!bob@localhost QUIT maintenance"
    ));
    assert_eq!(net.client_count(), 1);

    // The session task reports the socket closing a moment later. The
    // client is already gone, and hearing about it again must change nothing.
    net.disconnect(1, "Connection closed");
    assert!(drain(&mut rxs[0]).is_empty());
}

#[test]
fn a_ban_removes_the_holder_and_refuses_the_name_until_lifted() {
    let (mut net, mut rxs) = room();

    assert_eq!(
        net.run_admin(AdminCommand::Ban {
            nick: "Bob".to_owned(),
            reason: None
        }),
        Ok("banned Bob".to_owned())
    );
    assert_eq!(net.client_count(), 1, "the holder goes with it");
    assert!(has(
        &drain(&mut rxs[0]),
        "QUIT :Banned: Banned by the operator"
    ));
    assert_eq!(
        net.run_admin(AdminCommand::Ban {
            nick: "bob".to_owned(),
            reason: None
        }),
        Err("bob is already banned".to_owned())
    );

    let (tx, mut rx) = unbounded_channel();
    net.connect(7, tx);
    say(&mut net, 7, "NICK", vec!["BOB"]);
    assert!(has(&drain(&mut rx), " 432 "), "case does not get around it");

    net.run_admin(AdminCommand::Unban {
        nick: "bob".to_owned(),
    })
    .unwrap();
    say(&mut net, 7, "NICK", vec!["bob"]);
    say(&mut net, 7, "USER", vec!["bob", "0", "*", "Bob"]);
    assert!(has(&drain(&mut rx), " 001 bob "));
}

#[test]
fn closing_a_channel_empties_it_and_forgets_it() {
    let (mut net, mut rxs) = room();

    let outcome = net.run_admin(AdminCommand::CloseChannel {
        channel: "#room".to_owned(),
        reason: None,
    });
    assert_eq!(outcome, Ok("closed #room (2 removed)".to_owned()));
    assert!(has(&drain(&mut rxs[0]), "KICK #room alice"));
    assert!(has(&drain(&mut rxs[1]), "KICK #room bob"));
    assert!(net.snapshot().channels.is_empty());
    assert_eq!(net.client_count(), 2, "nobody left the server");
}

#[test]
fn operator_status_can_be_given_and_taken_and_the_room_is_told() {
    let (mut net, mut rxs) = room();

    let give = AdminCommand::Op {
        channel: "#room".to_owned(),
        nick: "bob".to_owned(),
    };
    assert_eq!(
        net.run_admin(give.clone()),
        Ok("bob is now an operator in #room".into())
    );
    assert!(has(&drain(&mut rxs[0]), ":ddirc.local MODE #room +o bob"));
    let snapshot = net.snapshot();
    assert!(snapshot.channels[0].members.iter().all(|m| m.op));

    // Said twice is an error rather than a second announcement.
    assert!(net.run_admin(give).is_err());

    net.run_admin(AdminCommand::Deop {
        channel: "#room".to_owned(),
        nick: "bob".to_owned(),
    })
    .unwrap();
    assert!(has(&drain(&mut rxs[1]), "MODE #room -o bob"));
}

#[test]
fn the_topic_notices_and_wall_come_from_the_server() {
    let (mut net, mut rxs) = room();

    net.run_admin(AdminCommand::SetTopic {
        channel: "#room".to_owned(),
        topic: "be nice".to_owned(),
    })
    .unwrap();
    assert!(has(
        &drain(&mut rxs[1]),
        ":ddirc.local TOPIC #room :be nice"
    ));
    assert_eq!(net.snapshot().channels[0].topic.as_deref(), Some("be nice"));

    net.run_admin(AdminCommand::Notice {
        target: "#room".to_owned(),
        text: "five minutes".to_owned(),
    })
    .unwrap();
    assert!(has(
        &drain(&mut rxs[0]),
        ":ddirc.local!server@localhost NOTICE #room :five minutes"
    ));

    let outcome = net.run_admin(AdminCommand::Wall {
        text: "restarting".to_owned(),
    });
    assert_eq!(outcome, Ok("sent to 2 connected".to_owned()));
    assert!(has(&drain(&mut rxs[1]), "NOTICE bob restarting"));

    assert!(net
        .run_admin(AdminCommand::Notice {
            target: "carol".into(),
            text: "hi".into()
        })
        .is_err());
}

#[test]
fn the_motd_can_be_replaced_and_never_emptied() {
    let (mut net, mut rxs) = network(2);

    net.run_admin(AdminCommand::SetMotd {
        lines: vec!["welcome\u{7} home".to_owned(), String::new()],
    })
    .unwrap();
    register(&mut net, 0, "alice");
    let lines = drain(&mut rxs[0]);
    assert!(has(&lines, " 372 alice :- welcome home"), "{lines:?}");
    assert!(!has(&lines, "on this machine only"));

    net.run_admin(AdminCommand::SetMotd { lines: vec![] })
        .unwrap();
    register(&mut net, 1, "bob");
    assert!(has(&drain(&mut rxs[1]), "on this machine only"));
}

#[test]
fn the_snapshot_lists_people_and_rooms_in_a_stable_order() {
    let (mut net, mut rxs) = room();
    let (tx, _rx) = unbounded_channel();
    net.connect(9, tx);
    drain(&mut rxs[0]);

    let snapshot = net.snapshot();
    let nicks: Vec<_> = snapshot.users.iter().map(|u| u.nick.as_deref()).collect();
    // Registered by nick, then the connection that has not got a name yet.
    assert_eq!(nicks, vec![Some("alice"), Some("bob"), None]);
    assert!(!snapshot.users[2].registered);
    assert_eq!(snapshot.users[0].channels, vec!["#room".to_owned()]);

    let members: Vec<_> = snapshot.channels[0]
        .members
        .iter()
        .map(|m| (m.nick.as_str(), m.op))
        .collect();
    assert_eq!(members, vec![("alice", true), ("bob", false)]);
    assert_eq!(snapshot.connections_total, 3);
}

#[test]
fn what_happens_is_reported_and_private_messages_stay_private() {
    let (mut net, _rxs) = network(2);
    let (observer, mut events) = broadcast::channel(64);
    net.observe(observer);
    register(&mut net, 0, "alice");
    register(&mut net, 1, "bob");
    say(&mut net, 0, "JOIN", vec!["#room"]);
    say(&mut net, 1, "JOIN", vec!["#room"]);
    say(&mut net, 0, "PRIVMSG", vec!["#room", "hello room"]);
    say(&mut net, 0, "PRIVMSG", vec!["bob", "a secret"]);
    say(&mut net, 0, "KICK", vec!["#room", "bob", "bye"]);

    let mut lines = Vec::new();
    while let Ok(event) = events.try_recv() {
        lines.push(event.describe());
    }
    let all = lines.join("\n");
    assert!(all.contains("alice registered"), "{all}");
    assert!(all.contains("bob joined #room"), "{all}");
    assert!(all.contains("#room <alice> hello room"), "{all}");
    assert!(all.contains("alice kicked bob from #room (bye)"), "{all}");
    // That it happened, yes; what was said, no.
    assert!(all.contains("alice sent a private message to bob"), "{all}");
    assert!(!all.contains("a secret"), "{all}");
}

#[test]
fn what_a_client_types_cannot_drive_the_operators_terminal() {
    let (mut net, _rxs) = network(2);
    let (observer, mut events) = broadcast::channel(64);
    net.observe(observer);
    register(&mut net, 0, "alice");
    register(&mut net, 1, "bob");
    say(&mut net, 0, "JOIN", vec!["#room"]);
    say(
        &mut net,
        0,
        "PRIVMSG",
        vec!["#room", "hi \u{1b}]52;c;aGk=\u{7} \u{9b}2J there"],
    );
    say(
        &mut net,
        0,
        "TOPIC",
        vec!["#room", "\u{1b}[2Jtopic \u{202e}evil"],
    );
    // A real name is the client's own word about itself, and shows in the table.
    say(
        &mut net,
        1,
        "USER",
        vec!["u", "0", "*", "ignored: already registered"],
    );
    say(&mut net, 0, "QUIT", vec!["\u{1b}c bye"]);

    let mut lines = Vec::new();
    while let Ok(event) = events.try_recv() {
        let line = event.describe();
        assert!(
            !line.chars().any(|c| c.is_control() || c == '\u{202e}'),
            "a control character reached the log: {line:?}"
        );
        // The structured form is safe too, for anything that reads it directly.
        if let EventKind::Message {
            text: Some(text), ..
        } = &event.kind
        {
            assert!(!text.chars().any(char::is_control), "{text:?}");
        }
        lines.push(line);
    }
    let all = lines.join("\n");

    // Escaped, not dropped: the operator can still see what was attempted.
    assert!(
        all.contains("hi \\x1b]52;c;aGk=\\x07 \\x9b2J there"),
        "{all}"
    );
    assert!(all.contains("\\x1b[2Jtopic \\u{202e}evil"), "{all}");
    assert!(all.contains("quit (\\x1bc bye)"), "{all}");
}

#[test]
fn the_snapshot_is_safe_to_show_too() {
    let (mut net, _rxs) = network(1);
    net.handle(0, Message::new(None, "NICK", vec!["alice"]).unwrap());
    net.handle(
        0,
        Message::new(
            None,
            "USER",
            vec!["\u{1b}[31mu", "0", "*", "\u{1b}]0;title\u{7}Real"],
        )
        .unwrap(),
    );
    say(&mut net, 0, "JOIN", vec!["#room"]);
    say(&mut net, 0, "TOPIC", vec!["#room", "\u{1b}[2Jtopic"]);

    let snapshot = net.snapshot();
    let user = &snapshot.users[0];
    for field in [
        user.user.as_deref(),
        user.realname.as_deref(),
        snapshot.channels[0].topic.as_deref(),
    ]
    .into_iter()
    .flatten()
    {
        assert!(!field.chars().any(char::is_control), "{field:?}");
    }
    assert_eq!(snapshot.channels[0].topic.as_deref(), Some("\\x1b[2Jtopic"));
}
