//! A terminal IRC client and a terminal IRC server, both on `ddirc-core`.
//!
//! The client began as the Phase 1 acceptance gate — if the core cannot
//! connect, negotiate SASL, join, and carry a conversation here, no amount of UI
//! will help — and that role stays: `--no-tui` is the original harness. The full-screen interface is for using it, and
//! the server (the one that ships inside the app, run on its own) is for having
//! somewhere to point a client.

use std::process::ExitCode;

mod cli;
mod client;
mod composer;
mod keymap;
mod logging;
mod server;
mod term;
mod widgets;

#[tokio::main]
async fn main() -> ExitCode {
    match cli::parse(std::env::args().skip(1)) {
        Ok(cli::Parsed::Help(text)) => {
            print!("{text}");
            ExitCode::SUCCESS
        }
        Ok(cli::Parsed::Client(args)) => client::run(*args).await,
        Ok(cli::Parsed::Server(args)) => server::run(args).await,
        Err(message) => {
            eprintln!("error: {message}\n\n{}", cli::USAGE);
            ExitCode::FAILURE
        }
    }
}
