//! The server with no screen: a log on stdout, and Ctrl-C to stop.
//!
//! For a service, a container, a `nohup`, or anywhere the output is going to a
//! file. It takes no input on purpose — a daemon reading its stdin is a daemon
//! that exits when someone closes the terminal it was started from.
//!
//! One event, one line, flushed as it happens, so `tail -f` and a pipe into
//! `grep` both behave.

use std::io::{self, Write};

use ddirc_server::ServerHandle;
use tokio::sync::broadcast::error::RecvError;

use super::model::Info;
use crate::cli::ServerArgs;
use crate::widgets::clock;

pub async fn run(handle: &ServerHandle, info: &Info, args: &ServerArgs) {
    let mut out = io::stdout().lock();
    let banner = [
        format!(
            "ddirc server \"{}\" ({}) listening on 127.0.0.1:{} over TLS",
            args.network, args.name, info.port
        ),
        format!("certificate to trust: {}", info.anchor),
        format!("connect with: {}", info.connect),
        "times are UTC · Ctrl-C stops the server".to_owned(),
    ];
    for line in banner {
        if writeln!(out, "{line}").is_err() {
            return;
        }
    }
    let _ = out.flush();
    drop(out);

    let mut events = handle.subscribe();
    loop {
        let line = tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                println!("stopping");
                return;
            }
            event = events.recv() => match event {
                Ok(event) => format!("{}  {}", clock(event.at), event.describe()),
                Err(RecvError::Lagged(n)) => format!("-- {n} events were missed --"),
                Err(RecvError::Closed) => return,
            },
        };
        let mut out = io::stdout().lock();
        // A closed pipe (`| head`) ends the log rather than panicking.
        if writeln!(out, "{line}").and_then(|()| out.flush()).is_err() {
            return;
        }
    }
}
