//! The message store: scrollback that outlives the process, when asked for.
//!
//! Off unless the user turns it on, and that is the first thing to understand
//! about this module rather than a footnote. A file recording what people said
//! is the most sensitive thing this app can write — more so than the password
//! store, which at least is encrypted by the platform — so nothing here runs
//! until [`open`] is called, and [`open`] is only called because somebody
//! ticked a box that says what it does. See `AppLog`, which made the same
//! decision for plain-text chat logs and for the same reasons.
//!
//! # Why SQLite, compiled in, on this side of the boundary
//!
//! The scrollback is capped in memory at a couple of thousand lines per
//! conversation, and that cap is not the problem it looks like — the problem is
//! that closing the app throws all of it away. Persisting it needs indexed
//! reads over a growing file, which is a database, and the database that ships
//! inside the binary is SQLite.
//!
//! It lives here, in the core, rather than in a Dart package. The alternative
//! was a second persistence layer in a second language: two schemas to keep in
//! step, two places to get a migration wrong, and the storage logic sitting
//! next to none of the connection and session state it is a record of. It also
//! means one SQLite — `rusqlite`'s `bundled` feature compiles the amalgamation
//! from source on every target this tree already cross-compiles for, so a
//! database written on Windows opens on Android against the same version.
//!
//! # What is stored
//!
//! One row per line, with its text held as the mIRC codes it arrived in rather
//! than flattened — see [`crate::text::format::encode`]. Reloading therefore
//! goes through the same parser every live message goes through, so restored
//! history is styled exactly as it was and there is no second representation
//! of a message to keep in step with the first.
//!
//! Nothing else is kept. No passwords, no capability negotiation, no
//! connection log: this is a record of conversations, and everything about how
//! the connection was made belongs in the debug log if it belongs anywhere.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use rusqlite::{params, Connection, OptionalExtension};

/// The schema this build writes and expects.
///
/// Kept in the file's own `user_version` rather than a table of our own, which
/// is what SQLite provides the pragma for. A file from a *newer* build is
/// refused rather than opened: silently reading a schema we do not know would
/// mean losing whatever the newer columns held the moment we wrote to it.
const SCHEMA_VERSION: i32 = 1;

/// How many lines the store keeps in total, across every network.
///
/// A ceiling rather than a preference. Nobody opens a settings screen wanting
/// to choose a row count, and the number only has to be large enough to hold
/// far more history than anybody scrolls back through and small enough that
/// the file cannot quietly eat a disk. At roughly 150 bytes a line this is a
/// few hundred megabytes at the very worst, and a small fraction of that in
/// practice.
///
/// Oldest first, globally rather than per conversation: a channel nobody has
/// spoken in for a year should not hold its share of the budget against one
/// that is busy today.
const MAX_ROWS: i64 = 2_000_000;

/// Failures a caller can act on.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("no message store is open")]
    Closed,
    #[error(
        "this history file was written by a newer version of ddIRC \
         (format {found}, this build understands {understood}). Update ddIRC, \
         or turn message history off to start a new file."
    )]
    FromTheFuture { found: i32, understood: i32 },
    #[error("the message store could not be used: {0}")]
    Sqlite(#[from] rusqlite::Error),
}

/// One stored line, on its way in or out.
///
/// Deliberately flat, and deliberately ignorant of what a system line *means*.
/// [`kind`](Self::kind) is an opaque small integer the app assigns: the core
/// has no business knowing that 1 is a join and 2 is a topic change, and
/// keeping it out of here is what stops a UI category becoming a schema
/// migration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredLine {
    /// Which saved network this belongs to. Scopes everything: `#chat` on one
    /// server has nothing to do with `#chat` on another.
    pub profile_id: String,

    /// The conversation's key, already case-folded by the caller.
    ///
    /// Folded there rather than here because the app already owns that rule —
    /// IRC's case mapping is a property of the server, not of a database.
    pub conversation: String,

    /// Milliseconds since the Unix epoch, and the sort order for everything.
    pub at_ms: i64,

    /// Who said it, or `None` for a system line.
    pub sender: Option<String>,

    /// Their channel privilege at the time, e.g. `@`.
    pub sender_prefix: Option<String>,

    /// The line itself, carrying its mIRC formatting codes.
    pub text: String,

    pub is_self: bool,
    pub is_mention: bool,
    pub is_action: bool,
    pub is_notice: bool,

    /// What kind of system line this is, for the app to interpret. Zero, and
    /// meaningless, when [`sender`](Self::sender) is set.
    pub kind: i64,
}

fn store() -> &'static Mutex<Option<Connection>> {
    static STORE: OnceLock<Mutex<Option<Connection>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(None))
}

/// Run `f` against the open connection.
///
/// A poisoned lock is recovered from rather than propagated, for the same
/// reason the connection registry recovers from one: a panic while writing one
/// line must not make the store permanently unusable for the rest of the
/// session.
fn with<T>(f: impl FnOnce(&Connection) -> Result<T, StoreError>) -> Result<T, StoreError> {
    let guard = store().lock().unwrap_or_else(|e| e.into_inner());
    f(guard.as_ref().ok_or(StoreError::Closed)?)
}

/// Open (or create) the store at `path`, and bring its schema up to date.
///
/// Safe to call again: an already-open store is closed first, so switching
/// files never leaves two connections to two databases and no way to say which
/// one a write went to.
pub fn open(path: &str) -> Result<(), StoreError> {
    close();

    // The parent is the app's own data directory, which the caller resolved.
    // Created rather than required, so a first run does not fail on a folder
    // that has never had a reason to exist.
    if let Some(parent) = Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let connection = Connection::open(path)?;
    // WAL, because the write pattern is an append every couple of seconds and
    // the read pattern is a scrollback query at the same time; the rollback
    // journal would have those two waiting on each other.
    //
    // `query_row` rather than `execute`: setting the journal mode returns the
    // mode as a row, and `execute` treats a statement that returns rows as an
    // error.
    connection.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
    // NORMAL rather than FULL. The difference is whether a *power cut* can cost
    // the last moment of writes — not a crash, which WAL survives either way —
    // and the thing at risk is the tail of a chat log that is also still on
    // screen. Paying an fsync per message for that is the wrong trade.
    connection.execute_batch("PRAGMA synchronous = NORMAL")?;
    connection.execute_batch("PRAGMA foreign_keys = ON")?;

    migrate(&connection)?;

    *store().lock().unwrap_or_else(|e| e.into_inner()) = Some(connection);
    Ok(())
}

/// Close the store. Idempotent, so the UI never has to track whether it is open.
pub fn close() {
    *store().lock().unwrap_or_else(|e| e.into_inner()) = None;
}

/// Whether anything is open to write to.
pub fn is_open() -> bool {
    store().lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

fn migrate(connection: &Connection) -> Result<(), StoreError> {
    let version: i32 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;

    if version > SCHEMA_VERSION {
        return Err(StoreError::FromTheFuture {
            found: version,
            understood: SCHEMA_VERSION,
        });
    }
    if version == SCHEMA_VERSION {
        return Ok(());
    }

    // One statement per version as the schema grows. At version 1 there is
    // nothing to migrate *from*, so this is the create.
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS lines (
             id             INTEGER PRIMARY KEY AUTOINCREMENT,
             profile_id     TEXT    NOT NULL,
             conversation   TEXT    NOT NULL,
             at_ms          INTEGER NOT NULL,
             sender         TEXT,
             sender_prefix  TEXT,
             text           TEXT    NOT NULL,
             is_self        INTEGER NOT NULL,
             is_mention     INTEGER NOT NULL,
             is_action      INTEGER NOT NULL,
             is_notice      INTEGER NOT NULL,
             kind           INTEGER NOT NULL
         );
         -- The only query there is: the tail of one conversation, in order.
         CREATE INDEX IF NOT EXISTS lines_by_conversation
             ON lines (profile_id, conversation, at_ms, id);",
    )?;
    connection.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))?;
    Ok(())
}

/// Append a batch of lines.
///
/// A batch rather than one line at a time, and the reason is the FFI boundary
/// rather than SQLite: a busy channel produces messages faster than it is worth
/// crossing into Rust for, so the caller buffers and flushes. Everything in one
/// transaction, so a failure halfway leaves the store exactly as it was.
///
/// Pruning happens here too, since this is the only thing that makes the file
/// grow.
pub fn append(lines: &[StoredLine]) -> Result<(), StoreError> {
    if lines.is_empty() {
        return Ok(());
    }
    with(|connection| {
        let transaction = connection.unchecked_transaction()?;
        {
            let mut insert = transaction.prepare_cached(
                "INSERT INTO lines (
                     profile_id, conversation, at_ms, sender, sender_prefix,
                     text, is_self, is_mention, is_action, is_notice, kind
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            )?;
            for line in lines {
                insert.execute(params![
                    line.profile_id,
                    line.conversation,
                    line.at_ms,
                    line.sender,
                    line.sender_prefix,
                    line.text,
                    line.is_self,
                    line.is_mention,
                    line.is_action,
                    line.is_notice,
                    line.kind,
                ])?;
            }
        }
        prune(&transaction)?;
        transaction.commit()?;
        Ok(())
    })
}

/// Drop the oldest lines once the file is over its ceiling.
///
/// By rowid rather than by timestamp: the id is the order things were written
/// in, which is the order they should leave in, and it is immune to a server
/// whose clock disagrees with ours.
fn prune(connection: &Connection) -> Result<(), StoreError> {
    let highest: Option<i64> = connection
        .query_row("SELECT MAX(id) FROM lines", [], |row| row.get(0))
        .optional()?
        .flatten();
    let Some(highest) = highest else {
        return Ok(());
    };
    connection.execute("DELETE FROM lines WHERE id <= ?1", [highest - MAX_ROWS])?;
    Ok(())
}

/// The tail of one conversation, oldest first.
///
/// Ordered newest-first inside the query and reversed on the way out, because
/// "the last N" is what the index can answer without walking the whole
/// conversation — and oldest-first is the order the scrollback wants them in.
pub fn recent(
    profile_id: &str,
    conversation: &str,
    limit: u32,
) -> Result<Vec<StoredLine>, StoreError> {
    with(|connection| {
        let mut select = connection.prepare_cached(
            "SELECT profile_id, conversation, at_ms, sender, sender_prefix,
                    text, is_self, is_mention, is_action, is_notice, kind
             FROM lines
             WHERE profile_id = ?1 AND conversation = ?2
             ORDER BY at_ms DESC, id DESC
             LIMIT ?3",
        )?;
        let rows = select.query_map(params![profile_id, conversation, limit], |row| {
            Ok(StoredLine {
                profile_id: row.get(0)?,
                conversation: row.get(1)?,
                at_ms: row.get(2)?,
                sender: row.get(3)?,
                sender_prefix: row.get(4)?,
                text: row.get(5)?,
                is_self: row.get(6)?,
                is_mention: row.get(7)?,
                is_action: row.get(8)?,
                is_notice: row.get(9)?,
                kind: row.get(10)?,
            })
        })?;

        let mut lines = rows.collect::<Result<Vec<_>, _>>()?;
        lines.reverse();
        Ok(lines)
    })
}

/// How many lines are held, for the settings screen to report.
pub fn count() -> Result<i64, StoreError> {
    with(|connection| Ok(connection.query_row("SELECT COUNT(*) FROM lines", [], |r| r.get(0))?))
}

/// Roughly how much disk the store is using.
///
/// Page count times page size rather than the file's length on disk: the
/// caller has no reliable way to find the WAL and shared-memory files that go
/// with it, and this is the number those add up to once they are checkpointed.
pub fn size_bytes() -> Result<i64, StoreError> {
    with(|connection| {
        let pages: i64 = connection.query_row("PRAGMA page_count", [], |r| r.get(0))?;
        let size: i64 = connection.query_row("PRAGMA page_size", [], |r| r.get(0))?;
        Ok(pages * size)
    })
}

/// Delete everything, and give the space back.
///
/// `VACUUM` is not optional here. Deleting rows leaves the pages in the file,
/// which for this store would mean "delete my history" producing a file that is
/// exactly as large as it was and still holds every deleted message in its
/// free pages. That is not what the button says.
pub fn clear() -> Result<(), StoreError> {
    with(|connection| {
        connection.execute("DELETE FROM lines", [])?;
        connection.execute_batch("VACUUM")?;
        Ok(())
    })
}

/// Delete one conversation's history, leaving the rest.
///
/// For the case the whole-store version is too blunt for: leaving a network
/// but keeping everything else, or forgetting one conversation that should
/// never have been written down.
pub fn forget(profile_id: &str, conversation: &str) -> Result<(), StoreError> {
    with(|connection| {
        connection.execute(
            "DELETE FROM lines WHERE profile_id = ?1 AND conversation = ?2",
            params![profile_id, conversation],
        )?;
        connection.execute_batch("VACUUM")?;
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::format;

    /// Every test in this file shares one process-wide store, so they are
    /// serialised behind this rather than run in parallel against each other.
    fn lock() -> std::sync::MutexGuard<'static, ()> {
        static SERIAL: Mutex<()> = Mutex::new(());
        SERIAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    struct TempStore {
        directory: std::path::PathBuf,
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl TempStore {
        fn new(name: &str) -> Self {
            let guard = lock();
            let directory = std::env::temp_dir().join(format!("ddirc-store-{name}"));
            let _ = std::fs::remove_dir_all(&directory);
            open(directory.join("history.db").to_str().unwrap()).unwrap();
            Self {
                directory,
                _guard: guard,
            }
        }
    }

    impl Drop for TempStore {
        fn drop(&mut self) {
            close();
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    fn said(conversation: &str, at_ms: i64, sender: &str, text: &str) -> StoredLine {
        StoredLine {
            profile_id: "p1".to_owned(),
            conversation: conversation.to_owned(),
            at_ms,
            sender: Some(sender.to_owned()),
            sender_prefix: None,
            text: text.to_owned(),
            is_self: false,
            is_mention: false,
            is_action: false,
            is_notice: false,
            kind: 0,
        }
    }

    #[test]
    fn a_conversation_comes_back_in_the_order_it_happened() {
        let _store = TempStore::new("order");
        append(&[
            said("#one", 300, "carol", "third"),
            said("#one", 100, "alice", "first"),
            said("#one", 200, "bob", "second"),
        ])
        .unwrap();

        let lines = recent("p1", "#one", 50).unwrap();
        assert_eq!(
            lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            ["first", "second", "third"],
        );
    }

    #[test]
    fn conversations_and_networks_do_not_bleed_into_each_other() {
        let _store = TempStore::new("scope");
        let mut elsewhere = said("#one", 100, "mallory", "another network");
        elsewhere.profile_id = "p2".to_owned();
        append(&[
            said("#one", 100, "alice", "here"),
            said("#two", 100, "bob", "next door"),
            elsewhere,
        ])
        .unwrap();

        let lines = recent("p1", "#one", 50).unwrap();
        assert_eq!(lines.len(), 1, "one network, one channel, one line");
        assert_eq!(lines[0].text, "here");
    }

    #[test]
    fn only_the_tail_is_returned_and_it_is_the_newest_end() {
        let _store = TempStore::new("tail");
        let lines: Vec<_> = (0..20)
            .map(|i| said("#one", i, "alice", &format!("line {i}")))
            .collect();
        append(&lines).unwrap();

        let tail = recent("p1", "#one", 5).unwrap();
        assert_eq!(
            tail.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            ["line 15", "line 16", "line 17", "line 18", "line 19"],
        );
    }

    #[test]
    fn styling_survives_the_round_trip() {
        let _store = TempStore::new("styling");
        let original = "\u{02}bold\u{02} and \u{03}04red";
        let spans = format::parse(original);
        append(&[said("#one", 1, "alice", &format::encode(&spans))]).unwrap();

        let restored = format::parse(&recent("p1", "#one", 1).unwrap()[0].text);
        // The point of storing the codes rather than the flattened text: what
        // comes back out of the database renders exactly as what went in.
        assert_eq!(restored, spans);
    }

    #[test]
    fn a_system_line_keeps_its_kind_and_has_no_sender() {
        let _store = TempStore::new("system");
        let mut joined = said("#one", 1, "alice", "alice joined");
        joined.sender = None;
        joined.kind = 3;
        append(&[joined]).unwrap();

        let line = &recent("p1", "#one", 1).unwrap()[0];
        assert_eq!(line.sender, None);
        assert_eq!(line.kind, 3);
    }

    #[test]
    fn clearing_leaves_nothing_behind() {
        let _store = TempStore::new("clear");
        append(&[said("#one", 1, "alice", "something private")]).unwrap();
        assert_eq!(count().unwrap(), 1);

        clear().unwrap();
        assert_eq!(count().unwrap(), 0);
        assert!(recent("p1", "#one", 50).unwrap().is_empty());
    }

    #[test]
    fn forgetting_one_conversation_keeps_the_others() {
        let _store = TempStore::new("forget");
        append(&[
            said("#one", 1, "alice", "kept"),
            said("#two", 1, "bob", "dropped"),
        ])
        .unwrap();

        forget("p1", "#two").unwrap();
        assert!(recent("p1", "#two", 50).unwrap().is_empty());
        assert_eq!(recent("p1", "#one", 50).unwrap().len(), 1);
    }

    #[test]
    fn a_closed_store_refuses_rather_than_pretending() {
        let _guard = lock();
        close();
        // Silently succeeding would mean history that the user believes is
        // being kept and is not.
        assert!(matches!(
            append(&[said("#one", 1, "alice", "hello")]),
            Err(StoreError::Closed)
        ));
        assert!(matches!(recent("p1", "#one", 1), Err(StoreError::Closed)));
    }

    #[test]
    fn a_file_from_a_newer_build_is_refused_rather_than_written_to() {
        let _guard = lock();
        let directory = std::env::temp_dir().join("ddirc-store-future");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("history.db");

        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(&format!("PRAGMA user_version = {}", SCHEMA_VERSION + 1))
                .unwrap();
        }

        let error = open(path.to_str().unwrap()).unwrap_err();
        assert!(matches!(error, StoreError::FromTheFuture { .. }));
        // And it says what to do about it, rather than only that it failed.
        assert!(error.to_string().contains("Update ddIRC"));

        close();
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn reopening_finds_what_was_written_before() {
        let _guard = lock();
        let directory = std::env::temp_dir().join("ddirc-store-reopen");
        let _ = std::fs::remove_dir_all(&directory);
        let path = directory.join("history.db");
        let path = path.to_str().unwrap();

        open(path).unwrap();
        append(&[said("#one", 1, "alice", "still here tomorrow")]).unwrap();
        close();

        open(path).unwrap();
        // The whole feature in one assertion: the app was closed and the
        // conversation was not lost.
        assert_eq!(
            recent("p1", "#one", 50).unwrap()[0].text,
            "still here tomorrow"
        );

        close();
        let _ = std::fs::remove_dir_all(&directory);
    }
}
