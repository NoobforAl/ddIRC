//! The client: `ddirc-core` with a face.
//!
//! Two faces. [`plain`] prints lines and reads lines, for scripts and for
//! seeing exactly what the core says. The full-screen one — [`model`] for what
//! it knows, [`ui`] for where it goes — is for using IRC.

use std::process::ExitCode;
use std::time::Duration;

use ratatui::crossterm::event::Event;

use crate::cli::{ClientArgs, Connection};
use crate::term::{self, Screen};

mod commands;
mod model;
mod plain;
mod ui;

pub async fn run(args: ClientArgs) -> ExitCode {
    let full_screen = args.tui && term::interactive();
    if let Err(message) = crate::logging::init(!full_screen, args.log_file.as_deref()) {
        eprintln!("error: {message}");
        return ExitCode::FAILURE;
    }
    if full_screen {
        full_screen_run(args.connection).await
    } else {
        plain::run(args.connection).await
    }
}

async fn full_screen_run(connection: Connection) -> ExitCode {
    if let Err(error) = connection.validate() {
        eprintln!("error: {error}");
        return ExitCode::FAILURE;
    }

    let mut app = model::App::new(connection.nick(), connection.host());
    if connection.is_xmpp() {
        app = app.for_xmpp();
    }
    let (handle, mut events) = connection.spawn();
    let mut keys = term::events();
    let mut screen = match Screen::enter() {
        Ok(screen) => screen,
        Err(e) => {
            eprintln!("error: cannot start the full-screen interface ({e}); try --no-tui");
            return ExitCode::FAILURE;
        }
    };

    let result = loop {
        if let Err(e) = screen.terminal.draw(|frame| ui::draw(frame, &app)) {
            break Err(e);
        }
        tokio::select! {
            event = events.recv() => match event {
                Some(event) => app.apply(event),
                None => break Ok(()),
            },
            input = keys.recv() => match input {
                Some(Event::Key(key)) => {
                    if let Some(key) = term::pressed(&Event::Key(key)) {
                        for command in app.key(key) {
                            // A closed handle means the core has stopped, which
                            // the event stream is about to say as well.
                            let _ = handle.send(command).await;
                        }
                    }
                }
                // A resize needs nothing but the redraw at the top of the loop.
                Some(_) => {}
                None => break Ok(()),
            },
        }
        if app.quit {
            break Ok(());
        }
    };

    // The terminal back first, so whatever happens next is seen.
    drop(screen);

    // The core says goodbye to the server on its own schedule. Wait for it to
    // finish, briefly, so the QUIT is actually written rather than abandoned.
    let _ = tokio::time::timeout(Duration::from_secs(2), async {
        while events.recv().await.is_some() {}
    })
    .await;

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: the terminal stopped working: {e}");
            ExitCode::FAILURE
        }
    }
}
