//! Where `tracing` goes.
//!
//! A full-screen interface owns the terminal, so anything written to it
//! tears the picture — and that includes the core's own diagnostics. They go
//! to a file if one was asked for and nowhere otherwise; the lines that matter
//! have their own place on screen.

use std::fs::OpenOptions;
use std::io::IsTerminal;
use std::path::Path;
use std::sync::Mutex;

use tracing_subscriber::EnvFilter;

const DEFAULT_FILTER: &str = "ddirc_core=info,ddirc_server=info,ddirc_cli=info";

/// `to_terminal` is whether stdout is free to use: true for the plain modes.
pub fn init(to_terminal: bool, file: Option<&Path>) -> Result<(), String> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| DEFAULT_FILTER.into());

    if let Some(path) = file {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| format!("cannot open {}: {e}", path.display()))?;
        tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_target(false)
            .with_ansi(false)
            .with_writer(Mutex::new(file))
            .init();
    } else if to_terminal {
        tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_target(false)
            // Colour is for a person watching. A log piped into a file or
            // `grep` gets the escape codes as literal noise.
            .with_ansi(std::io::stdout().is_terminal())
            .init();
    }
    Ok(())
}
