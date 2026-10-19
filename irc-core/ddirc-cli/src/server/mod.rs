//! The server: the one that ships inside the app, run on its own.
//!
//! [`ddirc_server`] is the protocol and the operator's controls; this is the
//! two ways of sitting at them. The full-screen manager ([`model`], [`ui`]) is
//! for running a server and looking after it. [`headless`] is for leaving one
//! running.
//!
//! The listener is loopback-only here as it is inside the app, and for the same
//! reason (see the `ddirc_server` crate docs): reaching it from elsewhere would
//! mean teaching other machines to trust a certificate it issued itself, which
//! is exactly the control this codebase will not build.

use std::process::ExitCode;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use ddirc_server::{AdminCommand, Config, LocalServer, ServerHandle};
use ratatui::crossterm::event::Event;
use tokio::sync::broadcast::error::RecvError;

use crate::cli::ServerArgs;
use crate::term::{self, Screen};

mod commands;
mod headless;
mod model;
mod ui;

pub async fn run(args: ServerArgs) -> ExitCode {
    let full_screen = args.tui && term::interactive();
    if let Err(message) = crate::logging::init(!full_screen, None) {
        eprintln!("error: {message}");
        return ExitCode::FAILURE;
    }

    let mut config = Config::new(&args.data_dir);
    config.port = args.port;
    config.server_name = args.name.clone();
    config.network_name = args.network.clone();
    let server = match LocalServer::start(config).await {
        Ok(server) => server,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let handle = server.handle();

    if !args.motd.is_empty() {
        let lines = args.motd.clone();
        if let Err(e) = handle.execute(AdminCommand::SetMotd { lines }).await {
            eprintln!("warning: could not set the message of the day: {e}");
        }
    }

    let anchor = server.anchor_path().display().to_string();
    let info = model::Info {
        port: server.port(),
        connect: format!(
            "ddirc-cli client --server 127.0.0.1 --port {} --ca-file \"{anchor}\" --nick <you>",
            server.port()
        ),
        anchor,
    };

    let code = if full_screen {
        full_screen_run(&handle, info).await
    } else {
        headless::run(&handle, &info, &args).await;
        ExitCode::SUCCESS
    };

    // Tell whoever is still connected, and give it a moment to arrive. Then
    // drop the server rather than `stop()` it: stopping waits for every
    // connection to close, and one that never does would hold this process
    // open after the person running it had said to stop.
    handle.send(AdminCommand::Wall {
        text: "The server is shutting down.".to_owned(),
    });
    tokio::time::sleep(Duration::from_millis(200)).await;
    drop(server);
    code
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

async fn full_screen_run(handle: &ServerHandle, info: model::Info) -> ExitCode {
    let Some(snapshot) = handle.snapshot().await else {
        eprintln!("error: the server stopped before it could be shown");
        return ExitCode::FAILURE;
    };
    let mut app = model::App::new(info, snapshot, unix_now());
    let mut events = handle.subscribe();
    let mut keys = term::events();
    let mut screen = match Screen::enter() {
        Ok(screen) => screen,
        Err(e) => {
            eprintln!("error: cannot start the full-screen interface ({e}); try --no-tui");
            return ExitCode::FAILURE;
        }
    };

    // A snapshot is a copy of everything, so it is taken when something has
    // changed and at most a few times a second — not once per event, which on a
    // busy channel would be once per message.
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    let mut changed = false;
    let result = loop {
        if let Err(e) = screen.terminal.draw(|frame| ui::draw(frame, &app)) {
            break Err(e);
        }
        tokio::select! {
            event = events.recv() => match event {
                Ok(event) => {
                    app.apply_event(&event);
                    changed = true;
                }
                Err(RecvError::Lagged(missed)) => {
                    app.note_skipped(missed);
                    changed = true;
                }
                Err(RecvError::Closed) => break Ok(()),
            },
            input = keys.recv() => match input {
                Some(Event::Key(key)) => {
                    if let Some(key) = term::pressed(&Event::Key(key)) {
                        for command in app.key(key) {
                            if !handle.send(command) {
                                app.say("the server has stopped", false);
                            }
                        }
                    }
                }
                Some(_) => {}
                None => break Ok(()),
            },
            _ = tick.tick() => {
                app.tick(unix_now());
                if changed {
                    changed = false;
                    if let Some(snapshot) = handle.snapshot().await {
                        app.set_snapshot(snapshot);
                    }
                }
            }
        }
        if app.quit {
            break Ok(());
        }
    };
    drop(screen);

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: the terminal stopped working: {e}");
            ExitCode::FAILURE
        }
    }
}
