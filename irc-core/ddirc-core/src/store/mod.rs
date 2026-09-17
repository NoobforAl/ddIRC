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
//! The one other thing kept is what the user has written down *about* people:
//! a name to show instead of a nick, a note, a colour, a picture. That is the
//! user's own annotation rather than anyone's speech, but it is still a record
//! of who they talk to, so it rides on the same switch and lives in the same
//! file. See [`People`](people).
//!
//! Alongside that are the user's own *identities*: a private label per
//! identity, and the throwaway nick each one wears on each network. A map of
//! which random handles all belong to one person is exactly what wants keeping
//! private, so it lives here too, behind the same switch. See [`Persona`].
//!
//! Nothing else is kept. No passwords, no capability negotiation, no
//! connection log: this is a record of conversations, and everything about how
//! the connection was made belongs in the debug log if it belongs anywhere.
//!
//! # Where the file is, and who can read it
//!
//! The caller resolves the path to the app's own per-user data directory —
//! `%APPDATA%` on Windows, `~/Library/Application Support` on macOS,
//! `~/.local/share` on Linux, the app's private files dir on Android — which
//! every platform already keeps out of other users' reach. On the Unix-likes
//! that is a convention of the directory rather than a property of the file,
//! so [`open`] also narrows the file itself to its owner: a database created
//! under a permissive umask should not be readable by every account on the
//! machine just because the folder above it happened to be.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use rusqlite::{params, Connection, OptionalExtension};

/// The schema this build writes and expects.
///
/// Kept in the file's own `user_version` rather than a table of our own, which
/// is what SQLite provides the pragma for. A file from a *newer* build is
/// refused rather than opened: silently reading a schema we do not know would
/// mean losing whatever the newer columns held the moment we wrote to it.
const SCHEMA_VERSION: i32 = 3;

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
    restrict_to_owner(path);
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

/// Owner-only permissions on the database and its journal, where the
/// platform has such a thing.
///
/// The WAL and shared-memory files sit beside the database with the same
/// name and a suffix; they carry the same content and get the same treatment.
/// Best effort: a filesystem that cannot do this is not a reason to refuse
/// to open the store, only to leave it as the directory's own permissions put
/// it. On Windows the per-user profile directory is already access-controlled
/// and there is nothing to add.
fn restrict_to_owner(path: &str) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for suffix in ["", "-wal", "-shm"] {
            let file = format!("{path}{suffix}");
            if Path::new(&file).exists() {
                let _ = std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600));
            }
        }
        if let Some(parent) = Path::new(path).parent() {
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
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

    // A ladder: each step brings a file from the version below it, and a file
    // at zero climbs every rung. `IF NOT EXISTS` throughout, so a step that
    // was applied but whose version bump never landed is harmless to repeat.
    if version < 1 {
        migrate_to_1(connection)?;
    }
    if version < 2 {
        migrate_to_2(connection)?;
    }
    if version < 3 {
        migrate_to_3(connection)?;
    }
    connection.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))?;
    Ok(())
}

/// Version 1: the lines. Nothing to migrate *from*, so this is the create.
fn migrate_to_1(connection: &Connection) -> Result<(), StoreError> {
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
    Ok(())
}

/// Version 2: what the user has written down about people.
///
/// One row per (network, nick), the nick folded to lower case by the caller
/// so `Alice` and `alice` are one person here as they are on IRC. Every
/// column but the key is optional: a row exists because at least one of them
/// is set, and [`set_person`] deletes it when the last one is cleared.
fn migrate_to_2(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS people (
             profile_id  TEXT NOT NULL,
             nick        TEXT NOT NULL,
             alias       TEXT,
             note        TEXT,
             color       INTEGER,
             avatar      BLOB,
             pixel_seed  INTEGER,
             PRIMARY KEY (profile_id, nick)
         );",
    )?;
    Ok(())
}

/// Version 3: the user's identities, and the nick each one wears on each
/// network.
///
/// A *persona* is a name the user keeps for their own reference — "Work",
/// say — that a network never sees. What a network sees is a nick generated
/// once and remembered here, in `persona_nicks`, keyed by the persona and the
/// saved network it connects through: the same handle every time on that one
/// server, and nothing tying it to the same person's handle anywhere else.
///
/// Kept here rather than beside the saved networks (which live in plain
/// preferences) precisely because a map of "these random nicks are all the
/// same person" is the thing the feature exists to keep private. It rides on
/// the history switch for the same reason [`people`](self) does.
fn migrate_to_3(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS personas (
             id     TEXT PRIMARY KEY,
             label  TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS persona_nicks (
             persona_id  TEXT NOT NULL,
             network_id  TEXT NOT NULL,
             nick        TEXT NOT NULL,
             PRIMARY KEY (persona_id, network_id)
         );",
    )?;
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

/// What the user has written down about one person on one network.
///
/// The user's annotation, not the person's: nothing here came over the wire.
/// `nick` is stored folded to lower case, because that is how IRC compares
/// nicks and a note on `Alice` is a note on `alice`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Person {
    pub profile_id: String,
    pub nick: String,
    /// Shown in place of the nick.
    pub alias: Option<String>,
    pub note: Option<String>,
    /// An ARGB colour to use instead of the one the nick hashes to.
    pub color: Option<i64>,
    /// A small PNG, already downscaled by the caller.
    pub avatar: Option<Vec<u8>>,
    /// The seed for a generated pixel avatar, when no picture was chosen.
    pub pixel_seed: Option<i64>,
}

impl Person {
    /// Whether there is anything here worth a row.
    pub fn is_blank(&self) -> bool {
        self.alias.is_none()
            && self.note.is_none()
            && self.color.is_none()
            && self.avatar.is_none()
            && self.pixel_seed.is_none()
    }
}

/// Everyone the user has written something about, on every network.
///
/// All at once rather than per network, because the whole table is small
/// — a row per person the user cared to annotate — and the UI wants it in
/// memory for every render of every nick anyway.
pub fn people() -> Result<Vec<Person>, StoreError> {
    with(|connection| {
        let mut statement = connection.prepare(
            "SELECT profile_id, nick, alias, note, color, avatar, pixel_seed
             FROM people ORDER BY profile_id, nick",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(Person {
                profile_id: row.get(0)?,
                nick: row.get(1)?,
                alias: row.get(2)?,
                note: row.get(3)?,
                color: row.get(4)?,
                avatar: row.get(5)?,
                pixel_seed: row.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// Write what is known about one person, replacing what was there.
///
/// A person with nothing left to say about them loses their row rather than
/// keeping an empty one: the table is a list of people the user annotated,
/// and clearing every field is un-annotating them.
pub fn set_person(person: &Person) -> Result<(), StoreError> {
    if person.is_blank() {
        return forget_person(&person.profile_id, &person.nick);
    }
    with(|connection| {
        connection.execute(
            "INSERT INTO people (profile_id, nick, alias, note, color, avatar, pixel_seed)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT (profile_id, nick) DO UPDATE SET
                 alias = excluded.alias,
                 note = excluded.note,
                 color = excluded.color,
                 avatar = excluded.avatar,
                 pixel_seed = excluded.pixel_seed",
            params![
                person.profile_id,
                person.nick,
                person.alias,
                person.note,
                person.color,
                person.avatar,
                person.pixel_seed,
            ],
        )?;
        Ok(())
    })
}

/// Forget one person on one network.
pub fn forget_person(profile_id: &str, nick: &str) -> Result<(), StoreError> {
    with(|connection| {
        connection.execute(
            "DELETE FROM people WHERE profile_id = ?1 AND nick = ?2",
            params![profile_id, nick],
        )?;
        Ok(())
    })
}

/// Forget everyone on one network — for when the network itself is forgotten.
pub fn forget_people(profile_id: &str) -> Result<(), StoreError> {
    with(|connection| {
        connection.execute(
            "DELETE FROM people WHERE profile_id = ?1",
            params![profile_id],
        )?;
        Ok(())
    })
}

/// One of the user's identities: a private label, and nothing a network sees.
///
/// The nick a persona actually wears on a given network is not here — that is
/// per network, and lives in [`PersonaNick`] — because one persona can connect
/// through several networks and wears a different, unlinkable handle on each.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Persona {
    pub id: String,
    pub label: String,
}

/// The nick one persona wears on one saved network, generated once and kept.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PersonaNick {
    pub persona_id: String,
    pub network_id: String,
    pub nick: String,
}

/// Every identity the user has made.
pub fn personas() -> Result<Vec<Persona>, StoreError> {
    with(|connection| {
        let mut statement =
            connection.prepare("SELECT id, label FROM personas ORDER BY label, id")?;
        let rows = statement.query_map([], |row| {
            Ok(Persona {
                id: row.get(0)?,
                label: row.get(1)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// Create or rename an identity.
pub fn set_persona(persona: &Persona) -> Result<(), StoreError> {
    with(|connection| {
        connection.execute(
            "INSERT INTO personas (id, label) VALUES (?1, ?2)
             ON CONFLICT (id) DO UPDATE SET label = excluded.label",
            params![persona.id, persona.label],
        )?;
        Ok(())
    })
}

/// Forget an identity, and every remembered nick that belonged to it.
///
/// Both in one transaction: a persona without its nicks, or nicks without
/// their persona, is a half-deleted identity neither the app nor the user has
/// a use for.
pub fn forget_persona(id: &str) -> Result<(), StoreError> {
    with(|connection| {
        let transaction = connection.unchecked_transaction()?;
        transaction.execute("DELETE FROM personas WHERE id = ?1", params![id])?;
        transaction.execute(
            "DELETE FROM persona_nicks WHERE persona_id = ?1",
            params![id],
        )?;
        transaction.commit()?;
        Ok(())
    })
}

/// Every remembered (persona, network) → nick, for the app to hold in memory.
pub fn persona_nicks() -> Result<Vec<PersonaNick>, StoreError> {
    with(|connection| {
        let mut statement = connection.prepare(
            "SELECT persona_id, network_id, nick FROM persona_nicks ORDER BY persona_id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(PersonaNick {
                persona_id: row.get(0)?,
                network_id: row.get(1)?,
                nick: row.get(2)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// Remember the nick a persona wears on a network, replacing any earlier one.
pub fn set_persona_nick(nick: &PersonaNick) -> Result<(), StoreError> {
    with(|connection| {
        connection.execute(
            "INSERT INTO persona_nicks (persona_id, network_id, nick) VALUES (?1, ?2, ?3)
             ON CONFLICT (persona_id, network_id) DO UPDATE SET nick = excluded.nick",
            params![nick.persona_id, nick.network_id, nick.nick],
        )?;
        Ok(())
    })
}

/// Forget every persona's nick on one network — for when the network is
/// forgotten, alongside [`forget_people`].
pub fn forget_persona_nicks_for_network(network_id: &str) -> Result<(), StoreError> {
    with(|connection| {
        connection.execute(
            "DELETE FROM persona_nicks WHERE network_id = ?1",
            params![network_id],
        )?;
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

    fn person(nick: &str) -> Person {
        Person {
            profile_id: "p1".to_owned(),
            nick: nick.to_owned(),
            ..Person::default()
        }
    }

    #[test]
    fn a_person_is_written_read_back_and_replaced() {
        let _store = TempStore::new("people");
        set_person(&Person {
            alias: Some("Alice from ops".to_owned()),
            note: Some("runs the mail server".to_owned()),
            color: Some(0xFFE57373),
            avatar: Some(vec![1, 2, 3]),
            pixel_seed: None,
            ..person("alice")
        })
        .unwrap();

        let everyone = people().unwrap();
        assert_eq!(everyone.len(), 1);
        assert_eq!(everyone[0].alias.as_deref(), Some("Alice from ops"));
        assert_eq!(everyone[0].avatar.as_deref(), Some(&[1, 2, 3][..]));

        // A second write is a replacement, not a second row.
        set_person(&Person {
            pixel_seed: Some(42),
            ..person("alice")
        })
        .unwrap();
        let everyone = people().unwrap();
        assert_eq!(everyone.len(), 1);
        assert_eq!(everyone[0].alias, None, "replaced, not merged");
        assert_eq!(everyone[0].pixel_seed, Some(42));
    }

    #[test]
    fn clearing_every_field_removes_the_row() {
        let _store = TempStore::new("people-blank");
        set_person(&Person {
            note: Some("x".to_owned()),
            ..person("bob")
        })
        .unwrap();
        set_person(&person("bob")).unwrap();
        assert!(people().unwrap().is_empty());
    }

    #[test]
    fn people_are_forgotten_one_at_a_time_or_a_network_at_a_time() {
        let _store = TempStore::new("people-forget");
        for nick in ["alice", "bob"] {
            set_person(&Person {
                note: Some("x".to_owned()),
                ..person(nick)
            })
            .unwrap();
        }
        set_person(&Person {
            profile_id: "p2".to_owned(),
            note: Some("x".to_owned()),
            ..person("carol")
        })
        .unwrap();

        forget_person("p1", "alice").unwrap();
        assert_eq!(people().unwrap().len(), 2);
        forget_people("p1").unwrap();
        let left = people().unwrap();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].profile_id, "p2");
    }

    #[test]
    fn a_version_one_file_is_brought_up_to_date() {
        let _guard = lock();
        let directory = std::env::temp_dir().join("ddirc-store-v1");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("history.db");

        // A file as the previous release left it: lines only, version 1.
        {
            let connection = Connection::open(&path).unwrap();
            migrate_to_1(&connection).unwrap();
            connection.execute_batch("PRAGMA user_version = 1").unwrap();
        }

        open(path.to_str().unwrap()).unwrap();
        // Both tables answer, and the version is now this build's.
        assert!(people().unwrap().is_empty());
        assert!(recent("p1", "#one", 1).unwrap().is_empty());
        let version: i32 =
            with(|c| Ok(c.query_row("PRAGMA user_version", [], |r| r.get(0))?)).unwrap();
        assert_eq!(version, SCHEMA_VERSION);

        close();
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_persona_is_created_renamed_and_forgotten() {
        let _store = TempStore::new("personas");
        set_persona(&Persona {
            id: "id1".to_owned(),
            label: "Work".to_owned(),
        })
        .unwrap();
        assert_eq!(personas().unwrap().len(), 1);
        assert_eq!(personas().unwrap()[0].label, "Work");

        // Same id, new label: a rename, not a second identity.
        set_persona(&Persona {
            id: "id1".to_owned(),
            label: "Day job".to_owned(),
        })
        .unwrap();
        let all = personas().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].label, "Day job");

        forget_persona("id1").unwrap();
        assert!(personas().unwrap().is_empty());
    }

    #[test]
    fn a_personas_nick_is_remembered_per_network_and_replaced() {
        let _store = TempStore::new("persona-nicks");
        set_persona_nick(&PersonaNick {
            persona_id: "id1".to_owned(),
            network_id: "netA".to_owned(),
            nick: "q7f3kx".to_owned(),
        })
        .unwrap();
        set_persona_nick(&PersonaNick {
            persona_id: "id1".to_owned(),
            network_id: "netB".to_owned(),
            nick: "m2p8wz".to_owned(),
        })
        .unwrap();

        let mut nicks = persona_nicks().unwrap();
        nicks.sort_by(|a, b| a.network_id.cmp(&b.network_id));
        assert_eq!(nicks.len(), 2);
        assert_eq!(nicks[0].nick, "q7f3kx");
        assert_eq!(nicks[1].nick, "m2p8wz");

        // Rewriting the same (persona, network) replaces rather than adds —
        // the nick on a network is settled, one value.
        set_persona_nick(&PersonaNick {
            persona_id: "id1".to_owned(),
            network_id: "netA".to_owned(),
            nick: "renamed".to_owned(),
        })
        .unwrap();
        let after = persona_nicks().unwrap();
        assert_eq!(after.len(), 2);
    }

    #[test]
    fn forgetting_a_persona_takes_its_nicks_and_leaves_the_rest() {
        let _store = TempStore::new("persona-forget");
        for (persona, network) in [("id1", "netA"), ("id1", "netB"), ("id2", "netA")] {
            set_persona_nick(&PersonaNick {
                persona_id: persona.to_owned(),
                network_id: network.to_owned(),
                nick: "x".to_owned(),
            })
            .unwrap();
        }

        forget_persona("id1").unwrap();
        let left = persona_nicks().unwrap();
        assert_eq!(left.len(), 1, "only id2's nick remains");
        assert_eq!(left[0].persona_id, "id2");
    }

    #[test]
    fn forgetting_a_network_takes_every_personas_nick_on_it() {
        let _store = TempStore::new("persona-net-forget");
        for (persona, network) in [("id1", "netA"), ("id2", "netA"), ("id1", "netB")] {
            set_persona_nick(&PersonaNick {
                persona_id: persona.to_owned(),
                network_id: network.to_owned(),
                nick: "x".to_owned(),
            })
            .unwrap();
        }

        forget_persona_nicks_for_network("netA").unwrap();
        let left = persona_nicks().unwrap();
        assert_eq!(left.len(), 1, "only the nick on netB survives");
        assert_eq!(left[0].network_id, "netB");
    }
}
