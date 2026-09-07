//! The Dart-facing message store.
//!
//! Nothing here runs until [`store_open`] is called, and the app only calls it
//! because the user turned message history on. That is the shape of the whole
//! module: a store that is closed is not an error state, it is the default, and
//! every read and write says so plainly rather than quietly doing nothing.
//!
//! Lines cross this boundary as spans, not as flattened text. The store keeps
//! them as the mIRC codes they arrived in, and the encoding happens on this
//! side so that Dart never has to own a second copy of the formatting rules —
//! see [`ddirc_core::text::format::encode`].
//!
//! Writes arrive in batches. A busy channel produces messages faster than it is
//! worth crossing an FFI boundary for, so the app buffers and flushes on a
//! timer the way `AppLog` already does for its files.

use ddirc_core::store;
use ddirc_core::text::format;

use crate::api::types::TextSpan;

/// One stored line, on its way in or out.
///
/// `kind` is an opaque small integer belonging to the app: zero for a message,
/// and for a system line whatever category the UI files it under. The core
/// deliberately does not know what those mean — a UI category should never
/// become a database migration.
#[derive(Debug, Clone)]
pub struct StoredLine {
    /// Which saved network this belongs to.
    pub profile_id: String,
    /// The conversation's key, already case-folded by the caller. IRC's case
    /// mapping is a property of the server, so the app owns that rule.
    pub conversation: String,
    /// Milliseconds since the Unix epoch.
    pub at_ms: i64,
    /// Who said it, or null for a system line.
    pub sender: Option<String>,
    /// Their channel privilege at the time, e.g. `@`.
    pub sender_prefix: Option<String>,
    /// The line itself, styled. Stored as codes and re-parsed on the way back,
    /// so restored history renders exactly as it did live.
    pub spans: Vec<TextSpan>,
    pub is_self: bool,
    pub is_mention: bool,
    pub is_action: bool,
    pub is_notice: bool,
    /// What kind of system line this is. Meaningless when `sender` is set.
    pub kind: i64,
}

/// What the store currently holds, for the settings screen to report.
#[derive(Debug, Clone)]
pub struct StoreStats {
    pub lines: i64,
    pub bytes: i64,
}

impl From<StoredLine> for store::StoredLine {
    fn from(line: StoredLine) -> Self {
        Self {
            profile_id: line.profile_id,
            conversation: line.conversation,
            at_ms: line.at_ms,
            sender: line.sender,
            sender_prefix: line.sender_prefix,
            text: format::encode(
                &line
                    .spans
                    .into_iter()
                    .map(format::TextSpan::from)
                    .collect::<Vec<_>>(),
            ),
            is_self: line.is_self,
            is_mention: line.is_mention,
            is_action: line.is_action,
            is_notice: line.is_notice,
            kind: line.kind,
        }
    }
}

impl From<store::StoredLine> for StoredLine {
    fn from(line: store::StoredLine) -> Self {
        Self {
            profile_id: line.profile_id,
            conversation: line.conversation,
            at_ms: line.at_ms,
            sender: line.sender,
            sender_prefix: line.sender_prefix,
            // Through the same parser every live message goes through, so a
            // reloaded line and a freshly arrived one are indistinguishable by
            // the time they reach the UI.
            spans: format::parse(&line.text)
                .into_iter()
                .map(TextSpan::from)
                .collect(),
            is_self: line.is_self,
            is_mention: line.is_mention,
            is_action: line.is_action,
            is_notice: line.is_notice,
            kind: line.kind,
        }
    }
}

/// Open, or create, the history database at `path`.
///
/// The path comes from Dart because only the app can say where its own data
/// directory is — every platform answers that differently, and two of them can
/// only be asked at runtime. Calling this again with a different path closes
/// the first, so there is never a write with two possible destinations.
pub fn store_open(path: String) -> Result<(), String> {
    store::open(&path).map_err(|e| e.to_string())
}

/// Stop keeping history. Idempotent, and never an error: turning off something
/// that is already off is what the user asked for either way.
pub fn store_close() {
    store::close();
}

/// Whether history is currently being kept.
#[flutter_rust_bridge::frb(sync)]
pub fn store_is_open() -> bool {
    store::is_open()
}

/// Write a batch of lines.
pub fn store_append(lines: Vec<StoredLine>) -> Result<(), String> {
    let lines: Vec<store::StoredLine> = lines.into_iter().map(Into::into).collect();
    store::append(&lines).map_err(|e| e.to_string())
}

/// The last `limit` lines of one conversation, oldest first.
pub fn store_recent(
    profile_id: String,
    conversation: String,
    limit: u32,
) -> Result<Vec<StoredLine>, String> {
    store::recent(&profile_id, &conversation, limit)
        .map(|lines| lines.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

/// How much history is being kept.
pub fn store_stats() -> Result<StoreStats, String> {
    let lines = store::count().map_err(|e| e.to_string())?;
    let bytes = store::size_bytes().map_err(|e| e.to_string())?;
    Ok(StoreStats { lines, bytes })
}

/// Delete every stored line, and give the disk space back.
pub fn store_clear() -> Result<(), String> {
    store::clear().map_err(|e| e.to_string())
}

/// Delete one conversation's history, leaving the rest.
pub fn store_forget(profile_id: String, conversation: String) -> Result<(), String> {
    store::forget(&profile_id, &conversation).map_err(|e| e.to_string())
}
