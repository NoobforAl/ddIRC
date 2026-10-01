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
//! And the user's own bookkeeping about conversations: what was typed and not
//! yet sent, how far each one has been read, which ones are pinned or put
//! away, and the messages they pinned or saved. See [`ConversationState`] and
//! [`Mark`]. All of it describes what was said, so it rides on the same switch.
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
const SCHEMA_VERSION: i32 = 5;

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

    /// The server's id for the line, when it had one.
    pub msgid: Option<String>,

    /// What the line replies to, if it is a reply. The three columns of a
    /// [`crate::text::reply::ReplyRef`], flattened: a reply by tag alone has no
    /// nick or excerpt, one by text alone has no id.
    pub reply_msgid: Option<String>,
    pub reply_nick: Option<String>,
    pub reply_excerpt: Option<String>,
}

/// The writer. Every change goes through here, one at a time.
fn store() -> &'static Mutex<Option<Connection>> {
    static STORE: OnceLock<Mutex<Option<Connection>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(None))
}

/// A second connection to the same file, for reading only.
///
/// WAL lets a reader see the last committed state while a write is in
/// progress, but only if the two are different connections: with one, the
/// mutex in front of it serialises them anyway, and restoring a conversation
/// or answering a search waits behind whatever batch of messages happens to be
/// landing. Two connections is what turns WAL's promise into an actual one.
fn reader() -> &'static Mutex<Option<Connection>> {
    static READER: OnceLock<Mutex<Option<Connection>>> = OnceLock::new();
    READER.get_or_init(|| Mutex::new(None))
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

/// [`with`], for a read: runs on the reading connection, so it does not queue
/// behind a write.
fn read<T>(f: impl FnOnce(&Connection) -> Result<T, StoreError>) -> Result<T, StoreError> {
    let guard = reader().lock().unwrap_or_else(|e| e.into_inner());
    f(guard.as_ref().ok_or(StoreError::Closed)?)
}

/// Settings every connection to the file gets.
///
/// None of them changes what is stored, only how fast it is reached:
/// - `busy_timeout`, because with two connections one can briefly find the
///   other holding a lock, and waiting a moment is the right answer to that
///   rather than an error the user sees.
/// - a larger page cache and memory-mapped reads, because the hot path is
///   scrolling back through one conversation, which is the same few index
///   pages again and again.
/// - temporary tables in memory, which is where a sort for a search goes.
fn tune(connection: &Connection) -> Result<(), StoreError> {
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    connection.execute_batch(
        "PRAGMA temp_store = MEMORY;
         PRAGMA cache_size = -16000;",
    )?;
    // Returns the size it settled on as a row, like `journal_mode` below.
    connection.query_row("PRAGMA mmap_size = 67108864", [], |_| Ok(()))?;
    Ok(())
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
    tune(&connection)?;

    migrate(&connection)?;

    // Opened after the migration, so it never sees a schema half-built.
    // `query_only` makes "this one only reads" a property of the connection
    // rather than of the code that happens to use it today.
    let reading = Connection::open(path)?;
    tune(&reading)?;
    reading.execute_batch("PRAGMA query_only = ON")?;

    *store().lock().unwrap_or_else(|e| e.into_inner()) = Some(connection);
    *reader().lock().unwrap_or_else(|e| e.into_inner()) = Some(reading);
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
///
/// `PRAGMA optimize` on the way out is SQLite's own advice for a connection
/// that is about to close: it refreshes the planner's statistics for whatever
/// this session's queries actually used, cheaply, so the next session's plans
/// are made from numbers that resemble the file.
pub fn close() {
    *reader().lock().unwrap_or_else(|e| e.into_inner()) = None;
    let mut writer = store().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(connection) = writer.as_ref() {
        let _ = connection.execute_batch("PRAGMA optimize");
    }
    *writer = None;
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
    if version < 4 {
        migrate_to_4(connection)?;
    }
    if version < 5 {
        migrate_to_5(connection)?;
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

/// Version 4: replies, and the ids they point at.
///
/// Columns on `lines` rather than a table of their own: every one is a
/// property of exactly one line, and all of them are usually empty. SQLite has
/// no `ADD COLUMN IF NOT EXISTS`, so each is checked for first, which keeps
/// this step as safe to repeat as the ones before it.
fn migrate_to_4(connection: &Connection) -> Result<(), StoreError> {
    let existing: Vec<String> = connection
        .prepare("SELECT name FROM pragma_table_info('lines')")?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    for column in ["msgid", "reply_msgid", "reply_nick", "reply_excerpt"] {
        if !existing.iter().any(|c| c == column) {
            connection.execute_batch(&format!("ALTER TABLE lines ADD COLUMN {column} TEXT"))?;
        }
    }
    Ok(())
}

/// Version 5: what scales, and what the user keeps about conversations.
///
/// Four things, each answering a query the app now asks:
///
/// - **A server id is unique per conversation.** A bouncer replaying the last
///   hour, or a reconnect that sees the same lines twice, used to store them
///   twice. The index makes the second copy a no-op (see [`append`]) and is
///   also what a lookup by id walks. Existing duplicates are removed first,
///   keeping the earliest, or the index could not be built.
/// - **Full-text search**, in an FTS5 table — see [`create_search_index`].
/// - **[`ConversationState`]**: drafts, read positions, pins, archiving.
/// - **[`Mark`]s**: messages the user pinned or saved.
///
/// One transaction, because the backfill of the search index is the one step
/// in this ladder that touches every row, and a file left with half an index
/// is worse than one with none.
fn migrate_to_5(connection: &Connection) -> Result<(), StoreError> {
    let transaction = connection.unchecked_transaction()?;
    transaction.execute_batch(
        "DELETE FROM lines
         WHERE msgid IS NOT NULL
           AND id NOT IN (SELECT MIN(id) FROM lines
                          WHERE msgid IS NOT NULL
                          GROUP BY profile_id, conversation, msgid);
         CREATE UNIQUE INDEX IF NOT EXISTS lines_by_msgid
             ON lines (profile_id, conversation, msgid) WHERE msgid IS NOT NULL;

         CREATE TABLE IF NOT EXISTS conversation_state (
             profile_id         TEXT    NOT NULL,
             conversation       TEXT    NOT NULL,
             draft              TEXT,
             draft_reply_msgid  TEXT,
             read_line_id       INTEGER,
             read_at_ms         INTEGER,
             pin_order          INTEGER,
             archived           INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY (profile_id, conversation)
         ) WITHOUT ROWID;

         CREATE TABLE IF NOT EXISTS marks (
             id            INTEGER PRIMARY KEY,
             kind          INTEGER NOT NULL,
             profile_id    TEXT    NOT NULL,
             conversation  TEXT    NOT NULL,
             line_id       INTEGER,
             msgid         TEXT,
             at_ms         INTEGER NOT NULL,
             sender        TEXT,
             text          TEXT    NOT NULL,
             created_ms    INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS marks_by_conversation
             ON marks (profile_id, conversation, kind, at_ms);
         CREATE INDEX IF NOT EXISTS marks_by_kind ON marks (kind, created_ms);
         -- One pin per message, one save per message.
         CREATE UNIQUE INDEX IF NOT EXISTS marks_unique
             ON marks (kind, profile_id, conversation, at_ms, sender, text);",
    )?;

    let indexed: bool = transaction.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'lines_fts')",
        [],
        |row| row.get(0),
    )?;
    if !indexed {
        create_search_index(&transaction)?;
        backfill_search_index(&transaction)?;
    }
    transaction.commit()?;
    Ok(())
}

/// The full-text index over what people said.
///
/// *Contentless*: it holds the tokens and the row id, not a second copy of the
/// text, so searching costs index space rather than doubling the file. The
/// text itself is read back from `lines` by id. `contentless_delete` is what
/// lets a row be removed from such an index at all (SQLite 3.43 and later; the
/// bundled copy is newer).
///
/// What is indexed is the line with its mIRC codes stripped — a word split by
/// a colour code is still one word to the person reading it — and only lines
/// somebody said: a search for "joined" should find a person saying it, not
/// every join in the history.
///
/// Rows leave the index through a trigger, so every delete — pruning,
/// forgetting a conversation or a network — keeps the two in step without
/// each having to remember to. Rows *enter* it from [`append`], because the
/// stripping is Rust's parser and not something SQL can do.
fn create_search_index(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE VIRTUAL TABLE IF NOT EXISTS lines_fts USING fts5(
             sender, body,
             content = '',
             contentless_delete = 1,
             tokenize = 'unicode61 remove_diacritics 2'
         );
         CREATE TRIGGER IF NOT EXISTS lines_fts_delete AFTER DELETE ON lines
         BEGIN
             DELETE FROM lines_fts WHERE rowid = old.id;
         END;",
    )?;
    Ok(())
}

/// Index every existing line, a page at a time so a large file is never held
/// in memory at once.
fn backfill_search_index(connection: &Connection) -> Result<(), StoreError> {
    const PAGE: i64 = 5_000;
    let mut after = 0_i64;
    loop {
        let page: Vec<(i64, String, String)> = connection
            .prepare(
                "SELECT id, sender, text FROM lines
                 WHERE id > ?1 AND sender IS NOT NULL
                 ORDER BY id LIMIT ?2",
            )?
            .query_map(params![after, PAGE], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?
            .collect::<Result<_, _>>()?;
        let Some(last) = page.last() else {
            return Ok(());
        };
        after = last.0;
        let mut insert = connection
            .prepare_cached("INSERT INTO lines_fts (rowid, sender, body) VALUES (?1, ?2, ?3)")?;
        for (id, sender, text) in &page {
            insert.execute(params![id, sender, crate::text::format::strip(text)])?;
        }
    }
}

/// One stored line together with the id the store gave it.
///
/// The id is what everything that points *at* a message holds on to — a read
/// position, a pin, the place a search result is — because a server id is
/// only there when the server sent one, and a timestamp is not unique.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub id: i64,
    pub line: StoredLine,
}

/// The columns [`row`] reads, in its order, each qualified by the table's
/// alias `l` so a query that joins another table can use them as they are.
const COLUMNS: &str = "l.id, l.profile_id, l.conversation, l.at_ms, l.sender,
                       l.sender_prefix, l.text, l.is_self, l.is_mention,
                       l.is_action, l.is_notice, l.kind, l.msgid,
                       l.reply_msgid, l.reply_nick, l.reply_excerpt";

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Row> {
    Ok(Row {
        id: row.get(0)?,
        line: StoredLine {
            profile_id: row.get(1)?,
            conversation: row.get(2)?,
            at_ms: row.get(3)?,
            sender: row.get(4)?,
            sender_prefix: row.get(5)?,
            text: row.get(6)?,
            is_self: row.get(7)?,
            is_mention: row.get(8)?,
            is_action: row.get(9)?,
            is_notice: row.get(10)?,
            kind: row.get(11)?,
            msgid: row.get(12)?,
            reply_msgid: row.get(13)?,
            reply_nick: row.get(14)?,
            reply_excerpt: row.get(15)?,
        },
    })
}

/// Append a batch of lines, and say what each one became.
///
/// A batch rather than one line at a time, and the reason is the FFI boundary
/// rather than SQLite: a busy channel produces messages faster than it is worth
/// crossing into Rust for, so the caller buffers and flushes. Everything in one
/// transaction, so a failure halfway leaves the store exactly as it was.
///
/// The result is one entry per line, in order: the id it was stored under, or
/// `None` when it was already there — a line carrying a server id this
/// conversation has already stored. That is a replay, not a second message,
/// and keeping both is how a scrollback ends up saying everything twice.
///
/// Pruning happens here too, since this is the only thing that makes the file
/// grow.
pub fn append(lines: &[StoredLine]) -> Result<Vec<Option<i64>>, StoreError> {
    if lines.is_empty() {
        return Ok(Vec::new());
    }
    with(|connection| {
        let transaction = connection.unchecked_transaction()?;
        let mut ids = Vec::with_capacity(lines.len());
        {
            let mut insert = transaction.prepare_cached(
                "INSERT OR IGNORE INTO lines (
                     profile_id, conversation, at_ms, sender, sender_prefix,
                     text, is_self, is_mention, is_action, is_notice, kind,
                     msgid, reply_msgid, reply_nick, reply_excerpt
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                           ?12, ?13, ?14, ?15)",
            )?;
            let mut index = transaction.prepare_cached(
                "INSERT INTO lines_fts (rowid, sender, body) VALUES (?1, ?2, ?3)",
            )?;
            for line in lines {
                let inserted = insert.execute(params![
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
                    line.msgid,
                    line.reply_msgid,
                    line.reply_nick,
                    line.reply_excerpt,
                ])?;
                if inserted == 0 {
                    ids.push(None);
                    continue;
                }
                let id = transaction.last_insert_rowid();
                if let Some(sender) = &line.sender {
                    index.execute(params![id, sender, crate::text::format::strip(&line.text)])?;
                }
                ids.push(Some(id));
            }
        }
        prune(&transaction)?;
        transaction.commit()?;
        Ok(ids)
    })
}

/// Drop the oldest lines once the file is over its ceiling.
///
/// By rowid rather than by timestamp: the id is the order things were written
/// in, which is the order they should leave in, and it is immune to a server
/// whose clock disagrees with ours.
///
/// Pins and saved messages are not lost with them: a [`Mark`] is a copy of the
/// message, not a pointer into this table, precisely so that this can run.
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
    Ok(tail(profile_id, conversation, limit)?
        .into_iter()
        .map(|r| r.line)
        .collect())
}

/// [`recent`], with each line's id.
pub fn tail(profile_id: &str, conversation: &str, limit: u32) -> Result<Vec<Row>, StoreError> {
    before(profile_id, conversation, i64::MAX, i64::MAX, limit)
}

/// The `limit` lines just older than the line at (`at_ms`, `id`), oldest
/// first — the page above what the scrollback already holds.
///
/// A *keyset*, not an offset: "older than this exact line" stays correct while
/// new lines arrive, where "skip the first 200" would shift under them. Both
/// halves of the key, because two lines can share a millisecond and the
/// timestamp alone would either repeat one or skip one at the page boundary.
pub fn before(
    profile_id: &str,
    conversation: &str,
    at_ms: i64,
    id: i64,
    limit: u32,
) -> Result<Vec<Row>, StoreError> {
    read(|connection| {
        let mut select = connection.prepare_cached(&format!(
            "SELECT {COLUMNS} FROM lines l
             WHERE l.profile_id = ?1 AND l.conversation = ?2
               AND (l.at_ms, l.id) < (?3, ?4)
             ORDER BY l.at_ms DESC, l.id DESC
             LIMIT ?5"
        ))?;
        let mut rows = select
            .query_map(params![profile_id, conversation, at_ms, id, limit], row)?
            .collect::<Result<Vec<_>, _>>()?;
        rows.reverse();
        Ok(rows)
    })
}

/// The lines either side of one, oldest first: `radius` before it, the line
/// itself, and `radius` after.
///
/// For opening a conversation *at* something — a search result, a saved
/// message — that has long since left the part of the scrollback in memory.
pub fn around(
    profile_id: &str,
    conversation: &str,
    at_ms: i64,
    id: i64,
    radius: u32,
) -> Result<Vec<Row>, StoreError> {
    let mut rows = before(profile_id, conversation, at_ms, id, radius)?;
    read(|connection| {
        let mut select = connection.prepare_cached(&format!(
            "SELECT {COLUMNS} FROM lines l
             WHERE l.profile_id = ?1 AND l.conversation = ?2
               AND (l.at_ms, l.id) >= (?3, ?4)
             ORDER BY l.at_ms, l.id
             LIMIT ?5"
        ))?;
        rows.extend(
            select
                .query_map(
                    params![profile_id, conversation, at_ms, id, radius + 1],
                    row,
                )?
                .collect::<Result<Vec<_>, _>>()?,
        );
        Ok(rows)
    })
}

/// Lines matching `query`, newest first.
///
/// Scoped to one network, or one conversation, or neither. `before_id` pages:
/// pass the id of the last result to get the next page down.
///
/// What the user typed is never handed to FTS5 as query syntax — see
/// [`match_expression`]. Typing `foo -bar` or `"` into a search box should
/// find those characters, not raise a syntax error or exclude a word.
pub fn search(
    profile_id: Option<&str>,
    conversation: Option<&str>,
    query: &str,
    limit: u32,
    before_id: Option<i64>,
) -> Result<Vec<Row>, StoreError> {
    let Some(expression) = match_expression(query) else {
        return Ok(Vec::new());
    };
    read(|connection| {
        // Newest first by the index's own rowid order, which FTS5 can walk
        // backwards and stop early on — no sort over every match.
        let mut select = connection.prepare_cached(&format!(
            "SELECT {COLUMNS} FROM lines_fts
             JOIN lines l ON l.id = lines_fts.rowid
             WHERE lines_fts MATCH ?1
               AND lines_fts.rowid < ?2
               AND (?3 IS NULL OR l.profile_id = ?3)
               AND (?4 IS NULL OR l.conversation = ?4)
             ORDER BY lines_fts.rowid DESC
             LIMIT ?5"
        ))?;
        let rows = select
            .query_map(
                params![
                    expression,
                    before_id.unwrap_or(i64::MAX),
                    profile_id,
                    conversation,
                    limit
                ],
                row,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

/// What the user typed, as an FTS5 query that means what they typed.
///
/// Every word becomes a quoted string — so no character in it is syntax — and
/// the last one is a prefix, so results appear while a word is still being
/// typed. `None` for a query with no words at all.
fn match_expression(query: &str) -> Option<String> {
    let words: Vec<String> = query
        .split_whitespace()
        .map(|w| format!("\"{}\"", w.replace('"', "\"\"")))
        .collect();
    if words.is_empty() {
        return None;
    }
    Some(format!("{}*", words.join(" ")))
}

/// How many lines are held, exactly.
pub fn count() -> Result<i64, StoreError> {
    read(|connection| Ok(connection.query_row("SELECT COUNT(*) FROM lines", [], |r| r.get(0))?))
}

/// About how many lines are held, for the settings screen to report.
///
/// From the ends of the id range, which the primary key answers at once,
/// rather than [`count`], which reads every row of a table that can hold two
/// million. It runs high by however many lines were forgotten from the middle,
/// and the screen says "about".
pub fn approximate_count() -> Result<i64, StoreError> {
    read(|connection| {
        Ok(connection.query_row(
            "SELECT COALESCE(MAX(id) - MIN(id) + 1, 0) FROM lines",
            [],
            |r| r.get(0),
        )?)
    })
}

/// Roughly how much disk the store is using.
///
/// Page count times page size rather than the file's length on disk: the
/// caller has no reliable way to find the WAL and shared-memory files that go
/// with it, and this is the number those add up to once they are checkpointed.
pub fn size_bytes() -> Result<i64, StoreError> {
    read(|connection| {
        let pages: i64 = connection.query_row("PRAGMA page_count", [], |r| r.get(0))?;
        let size: i64 = connection.query_row("PRAGMA page_size", [], |r| r.get(0))?;
        Ok(pages * size)
    })
}

/// Delete every message, everything kept about a conversation, every pin and
/// saved message — and give the space back.
///
/// What the user wrote about *people*, and their own identities, stay: those
/// are not messages, and the button says messages.
///
/// The search index is dropped and rebuilt empty rather than emptied through
/// its trigger, which would visit every row one at a time to delete what is
/// about to be deleted anyway.
///
/// `VACUUM` is not optional here. Deleting rows leaves the pages in the file,
/// which for this store would mean "delete my history" producing a file that is
/// exactly as large as it was and still holds every deleted message in its
/// free pages. That is not what the button says.
pub fn clear() -> Result<(), StoreError> {
    with(|connection| {
        connection.execute_batch(
            "DROP TRIGGER IF EXISTS lines_fts_delete;
             DROP TABLE IF EXISTS lines_fts;
             DELETE FROM lines;
             DELETE FROM conversation_state;
             DELETE FROM marks;",
        )?;
        create_search_index(connection)?;
        connection.execute_batch("VACUUM")?;
        Ok(())
    })
}

/// Delete one conversation's history, leaving the rest.
///
/// For the case the whole-store version is too blunt for: leaving a network
/// but keeping everything else, or forgetting one conversation that should
/// never have been written down. Its pins, saved messages and draft go with it
/// — they are quotations from it.
///
/// No `VACUUM`: it rewrites the whole file while holding the writer, which
/// can be seconds, for a few pages SQLite will reuse for the next messages
/// anyway. [`clear`] is the button that promises the space back.
pub fn forget(profile_id: &str, conversation: &str) -> Result<(), StoreError> {
    with(|connection| {
        let transaction = connection.unchecked_transaction()?;
        for table in ["lines", "conversation_state", "marks"] {
            transaction.execute(
                &format!("DELETE FROM {table} WHERE profile_id = ?1 AND conversation = ?2"),
                params![profile_id, conversation],
            )?;
        }
        transaction.commit()?;
        Ok(())
    })
}

/// Delete everything kept for one saved network: its history, its
/// conversations' state, its pins and saved messages, what the user wrote
/// about people on it, and the nicks their identities wore there.
///
/// For when the network itself is deleted. Without this, deleting a network
/// left every message from it in the file, unreachable from the app and still
/// on disk — the one outcome a privacy-minded delete must not have.
pub fn forget_profile(profile_id: &str) -> Result<(), StoreError> {
    with(|connection| {
        let transaction = connection.unchecked_transaction()?;
        for table in ["lines", "conversation_state", "marks", "people"] {
            transaction.execute(
                &format!("DELETE FROM {table} WHERE profile_id = ?1"),
                params![profile_id],
            )?;
        }
        transaction.execute(
            "DELETE FROM persona_nicks WHERE network_id = ?1",
            params![profile_id],
        )?;
        transaction.commit()?;
        Ok(())
    })
}

/// What the user keeps about one conversation, apart from its messages.
///
/// Every field is the user's own doing — something typed, a place read up to,
/// a pin, an archive — and a row exists only while at least one is set; see
/// [`set_conversation_state`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ConversationState {
    pub profile_id: String,
    /// Already case-folded by the caller, as for [`StoredLine::conversation`].
    pub conversation: String,
    /// Text typed into the composer and not sent.
    pub draft: Option<String>,
    /// The server id of the message the draft replies to.
    pub draft_reply_msgid: Option<String>,
    /// The last line read: its [`Row::id`], and its time, which is what
    /// placing the marker in a scrollback that may not reach back that far
    /// needs.
    pub read_line_id: Option<i64>,
    pub read_at_ms: Option<i64>,
    /// Where in the pinned group of the conversation list, lowest first;
    /// `None` when not pinned.
    pub pin_order: Option<i64>,
    pub archived: bool,
}

impl ConversationState {
    /// Whether there is anything here worth a row.
    pub fn is_blank(&self) -> bool {
        self.draft.is_none()
            && self.draft_reply_msgid.is_none()
            && self.read_line_id.is_none()
            && self.read_at_ms.is_none()
            && self.pin_order.is_none()
            && !self.archived
    }
}

/// Every conversation's state, on every network. Small — a row per
/// conversation the user has touched — and wanted in memory whole.
pub fn conversation_states() -> Result<Vec<ConversationState>, StoreError> {
    read(|connection| {
        let mut statement = connection.prepare(
            "SELECT profile_id, conversation, draft, draft_reply_msgid,
                    read_line_id, read_at_ms, pin_order, archived
             FROM conversation_state",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(ConversationState {
                profile_id: row.get(0)?,
                conversation: row.get(1)?,
                draft: row.get(2)?,
                draft_reply_msgid: row.get(3)?,
                read_line_id: row.get(4)?,
                read_at_ms: row.get(5)?,
                pin_order: row.get(6)?,
                archived: row.get(7)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// Write one conversation's state, replacing what was there, or remove its
/// row when nothing is left in it.
pub fn set_conversation_state(state: &ConversationState) -> Result<(), StoreError> {
    with(|connection| {
        if state.is_blank() {
            connection.execute(
                "DELETE FROM conversation_state WHERE profile_id = ?1 AND conversation = ?2",
                params![state.profile_id, state.conversation],
            )?;
            return Ok(());
        }
        connection.execute(
            "INSERT INTO conversation_state (
                 profile_id, conversation, draft, draft_reply_msgid,
                 read_line_id, read_at_ms, pin_order, archived)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT (profile_id, conversation) DO UPDATE SET
                 draft = excluded.draft,
                 draft_reply_msgid = excluded.draft_reply_msgid,
                 read_line_id = excluded.read_line_id,
                 read_at_ms = excluded.read_at_ms,
                 pin_order = excluded.pin_order,
                 archived = excluded.archived",
            params![
                state.profile_id,
                state.conversation,
                state.draft,
                state.draft_reply_msgid,
                state.read_line_id,
                state.read_at_ms,
                state.pin_order,
                state.archived,
            ],
        )?;
        Ok(())
    })
}

/// What a [`Mark`] is: pinned to its conversation, for everyone looking at
/// it on this device...
pub const MARK_PINNED: i64 = 1;
/// ...or saved, for the user's own list across every network.
pub const MARK_SAVED: i64 = 2;

/// A message the user pinned to its conversation, or saved for themselves.
///
/// A *copy* of the message — sender, time, text — and not only a pointer to
/// it. The pointer ([`line_id`](Self::line_id), [`msgid`](Self::msgid)) is
/// kept for jumping back to it, but the store prunes old lines, and a saved
/// message that vanished because enough other things were said since would be
/// a bookmark that does not keep its page.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Mark {
    /// Zero for one not yet written; see [`add_mark`].
    pub id: i64,
    /// [`MARK_PINNED`] or [`MARK_SAVED`].
    pub kind: i64,
    pub profile_id: String,
    pub conversation: String,
    pub line_id: Option<i64>,
    pub msgid: Option<String>,
    pub at_ms: i64,
    pub sender: Option<String>,
    /// With its mIRC codes, like [`StoredLine::text`].
    pub text: String,
    pub created_ms: i64,
}

/// Marks of one kind, or every kind, optionally for one network or one
/// conversation — oldest message first.
pub fn marks(
    kind: Option<i64>,
    profile_id: Option<&str>,
    conversation: Option<&str>,
) -> Result<Vec<Mark>, StoreError> {
    read(|connection| {
        let mut statement = connection.prepare_cached(
            "SELECT id, kind, profile_id, conversation, line_id, msgid, at_ms,
                    sender, text, created_ms
             FROM marks
             WHERE (?1 IS NULL OR kind = ?1)
               AND (?2 IS NULL OR profile_id = ?2)
               AND (?3 IS NULL OR conversation = ?3)
             ORDER BY at_ms, id",
        )?;
        let rows = statement.query_map(params![kind, profile_id, conversation], |row| {
            Ok(Mark {
                id: row.get(0)?,
                kind: row.get(1)?,
                profile_id: row.get(2)?,
                conversation: row.get(3)?,
                line_id: row.get(4)?,
                msgid: row.get(5)?,
                at_ms: row.get(6)?,
                sender: row.get(7)?,
                text: row.get(8)?,
                created_ms: row.get(9)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// Pin or save a message, and return the mark's id.
///
/// Doing it twice is not an error and does not make a second mark: the id of
/// the one already there comes back.
pub fn add_mark(mark: &Mark) -> Result<i64, StoreError> {
    with(|connection| {
        let inserted = connection.execute(
            "INSERT OR IGNORE INTO marks (
                 kind, profile_id, conversation, line_id, msgid, at_ms,
                 sender, text, created_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                mark.kind,
                mark.profile_id,
                mark.conversation,
                mark.line_id,
                mark.msgid,
                mark.at_ms,
                mark.sender,
                mark.text,
                mark.created_ms,
            ],
        )?;
        if inserted > 0 {
            return Ok(connection.last_insert_rowid());
        }
        Ok(connection.query_row(
            "SELECT id FROM marks
             WHERE kind = ?1 AND profile_id = ?2 AND conversation = ?3
               AND at_ms = ?4 AND sender IS ?5 AND text = ?6",
            params![
                mark.kind,
                mark.profile_id,
                mark.conversation,
                mark.at_ms,
                mark.sender,
                mark.text
            ],
            |row| row.get(0),
        )?)
    })
}

/// Unpin or unsave.
pub fn remove_mark(id: i64) -> Result<(), StoreError> {
    with(|connection| {
        connection.execute("DELETE FROM marks WHERE id = ?1", params![id])?;
        Ok(())
    })
}

// What the user has written down about one person on one network.
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
            msgid: None,
            reply_msgid: None,
            reply_nick: None,
            reply_excerpt: None,
        }
    }

    #[test]
    fn a_reply_keeps_what_it_answers() {
        let _store = TempStore::new("replies");
        let mut line = said("#one", 1, "bob", "agreed");
        line.msgid = Some("m2".to_owned());
        line.reply_msgid = Some("m1".to_owned());
        line.reply_nick = Some("alice".to_owned());
        line.reply_excerpt = Some("ship it".to_owned());
        append(&[line.clone()]).unwrap();
        assert_eq!(recent("p1", "#one", 10).unwrap(), vec![line]);
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
            connection
                .execute_batch(
                    "INSERT INTO lines (profile_id, conversation, at_ms, sender, text,
                         is_self, is_mention, is_action, is_notice, kind)
                     VALUES ('p1', '#old', 1, 'alice', 'from before', 0, 0, 0, 0, 0);
                     PRAGMA user_version = 1",
                )
                .unwrap();
        }

        open(path.to_str().unwrap()).unwrap();
        // Both tables answer, and the version is now this build's.
        assert!(people().unwrap().is_empty());
        assert!(recent("p1", "#one", 1).unwrap().is_empty());
        // A line written before replies existed reads back as no reply at all.
        let old = recent("p1", "#old", 1).unwrap();
        assert_eq!(old[0].text, "from before");
        assert_eq!(old[0].reply_msgid, None);
        assert_eq!(old[0].msgid, None);
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

    fn tagged(conversation: &str, at_ms: i64, msgid: &str, text: &str) -> StoredLine {
        StoredLine {
            msgid: Some(msgid.to_owned()),
            ..said(conversation, at_ms, "alice", text)
        }
    }

    #[test]
    fn a_replayed_line_is_stored_once() {
        let _store = TempStore::new("dedupe");
        let ids = append(&[tagged("#one", 1, "m1", "hello")]).unwrap();
        assert!(ids[0].is_some());
        // A bouncer replaying the same message, by the same id.
        let again = append(&[
            tagged("#one", 1, "m1", "hello"),
            tagged("#one", 2, "m2", "new"),
        ])
        .unwrap();
        assert_eq!(again[0], None, "the replay is not a second row");
        assert!(again[1].is_some());
        assert_eq!(count().unwrap(), 2);
        // The same id in another conversation is another message.
        assert!(append(&[tagged("#two", 1, "m1", "hello")]).unwrap()[0].is_some());
    }

    #[test]
    fn search_finds_words_whatever_the_formatting() {
        let _store = TempStore::new("search");
        append(&[
            said("#one", 1, "alice", "the \u{02}deploy\u{02} is done"),
            said("#one", 2, "bob", "lunch?"),
            said("#two", 3, "carol", "deploying now"),
        ])
        .unwrap();

        let hits = search(Some("p1"), None, "deploy", 10, None).unwrap();
        // Prefix match, newest first, and a bold word is still a word.
        assert_eq!(
            hits.iter()
                .map(|r| r.line.sender.as_deref().unwrap())
                .collect::<Vec<_>>(),
            ["carol", "alice"],
        );
        assert_eq!(
            search(None, Some("#two"), "deploy", 10, None)
                .unwrap()
                .len(),
            1
        );
        assert!(search(Some("p2"), None, "deploy", 10, None)
            .unwrap()
            .is_empty());
        // Paging down from the first hit.
        let next = search(Some("p1"), None, "deploy", 10, Some(hits[0].id)).unwrap();
        assert_eq!(next.len(), 1);
        assert_eq!(next[0].line.sender.as_deref(), Some("alice"));
    }

    #[test]
    fn search_text_is_never_query_syntax() {
        let _store = TempStore::new("search-syntax");
        append(&[said("#one", 1, "alice", "a \"quoted\" -word OR not")]).unwrap();
        for query in ["\"", "-word", "OR", "quoted\"", "NEAR(", "*", "   "] {
            // Nothing here may be an error; most of it should still match.
            search(None, None, query, 10, None).unwrap();
        }
        assert_eq!(search(None, None, "-word", 10, None).unwrap().len(), 1);
    }

    #[test]
    fn forgotten_lines_leave_the_search_index() {
        let _store = TempStore::new("search-forget");
        append(&[said("#one", 1, "alice", "secret plan")]).unwrap();
        forget("p1", "#one").unwrap();
        assert!(search(None, None, "secret", 10, None).unwrap().is_empty());
        // And the index still takes new lines after a clear rebuilt it.
        clear().unwrap();
        append(&[said("#one", 2, "alice", "secret again")]).unwrap();
        assert_eq!(search(None, None, "secret", 10, None).unwrap().len(), 1);
    }

    #[test]
    fn paging_back_neither_repeats_nor_skips_a_shared_millisecond() {
        let _store = TempStore::new("paging");
        // Ten lines, all in the same millisecond: only the id tells them apart.
        let lines: Vec<_> = (0..10)
            .map(|i| said("#one", 5, "alice", &format!("{i}")))
            .collect();
        append(&lines).unwrap();

        let newest = tail("p1", "#one", 4).unwrap();
        let older = before("p1", "#one", newest[0].line.at_ms, newest[0].id, 4).unwrap();
        let oldest = before("p1", "#one", older[0].line.at_ms, older[0].id, 4).unwrap();
        let all: Vec<_> = oldest
            .iter()
            .chain(&older)
            .chain(&newest)
            .map(|r| r.line.text.as_str())
            .collect();
        assert_eq!(all, ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]);
    }

    #[test]
    fn around_opens_a_window_on_one_line() {
        let _store = TempStore::new("around");
        let lines: Vec<_> = (0..20)
            .map(|i| said("#one", i, "alice", &format!("{i}")))
            .collect();
        let ids = append(&lines).unwrap();
        let ten = ids[10].unwrap();

        let window = around("p1", "#one", 10, ten, 2).unwrap();
        assert_eq!(
            window
                .iter()
                .map(|r| r.line.text.as_str())
                .collect::<Vec<_>>(),
            ["8", "9", "10", "11", "12"],
        );
    }

    #[test]
    fn conversation_state_is_kept_replaced_and_dropped_when_blank() {
        let _store = TempStore::new("conversation-state");
        let state = ConversationState {
            profile_id: "p1".to_owned(),
            conversation: "#one".to_owned(),
            draft: Some("half a thought".to_owned()),
            read_line_id: Some(7),
            read_at_ms: Some(700),
            pin_order: Some(0),
            ..ConversationState::default()
        };
        set_conversation_state(&state).unwrap();
        assert_eq!(conversation_states().unwrap(), vec![state.clone()]);

        let archived = ConversationState {
            draft: None,
            archived: true,
            ..state.clone()
        };
        set_conversation_state(&archived).unwrap();
        assert_eq!(conversation_states().unwrap(), vec![archived]);

        set_conversation_state(&ConversationState {
            profile_id: "p1".to_owned(),
            conversation: "#one".to_owned(),
            ..ConversationState::default()
        })
        .unwrap();
        assert!(conversation_states().unwrap().is_empty());
    }

    fn mark(kind: i64, text: &str) -> Mark {
        Mark {
            kind,
            profile_id: "p1".to_owned(),
            conversation: "#one".to_owned(),
            at_ms: 1,
            sender: Some("alice".to_owned()),
            text: text.to_owned(),
            created_ms: 2,
            ..Mark::default()
        }
    }

    #[test]
    fn a_message_is_marked_once_and_unmarked() {
        let _store = TempStore::new("marks");
        let pinned = add_mark(&mark(MARK_PINNED, "the rules")).unwrap();
        assert_eq!(add_mark(&mark(MARK_PINNED, "the rules")).unwrap(), pinned);
        // Pinning and saving are separate marks on the same message.
        let saved = add_mark(&mark(MARK_SAVED, "the rules")).unwrap();
        assert_ne!(saved, pinned);

        assert_eq!(marks(Some(MARK_PINNED), None, None).unwrap().len(), 1);
        assert_eq!(marks(None, Some("p1"), Some("#one")).unwrap().len(), 2);

        remove_mark(pinned).unwrap();
        let left = marks(None, None, None).unwrap();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].kind, MARK_SAVED);
    }

    #[test]
    fn a_mark_outlives_the_line_it_copied() {
        let _store = TempStore::new("marks-prune");
        let id = append(&[said("#one", 1, "alice", "keep this")]).unwrap()[0];
        add_mark(&Mark {
            line_id: id,
            ..mark(MARK_SAVED, "keep this")
        })
        .unwrap();
        // What pruning does to the oldest lines.
        with(|c| Ok(c.execute("DELETE FROM lines", [])?)).unwrap();
        assert_eq!(marks(None, None, None).unwrap()[0].text, "keep this");
    }

    #[test]
    fn forgetting_a_network_takes_everything_kept_for_it() {
        let _store = TempStore::new("forget-profile");
        let mut elsewhere = said("#one", 1, "mallory", "other network");
        elsewhere.profile_id = "p2".to_owned();
        append(&[said("#one", 1, "alice", "gone soon"), elsewhere]).unwrap();
        add_mark(&mark(MARK_SAVED, "gone soon")).unwrap();
        set_conversation_state(&ConversationState {
            profile_id: "p1".to_owned(),
            conversation: "#one".to_owned(),
            archived: true,
            ..ConversationState::default()
        })
        .unwrap();
        set_person(&Person {
            note: Some("x".to_owned()),
            ..person("alice")
        })
        .unwrap();
        set_persona_nick(&PersonaNick {
            persona_id: "id1".to_owned(),
            network_id: "p1".to_owned(),
            nick: "x".to_owned(),
        })
        .unwrap();

        forget_profile("p1").unwrap();
        assert!(recent("p1", "#one", 10).unwrap().is_empty());
        assert!(search(None, None, "gone", 10, None).unwrap().is_empty());
        assert!(marks(None, None, None).unwrap().is_empty());
        assert!(conversation_states().unwrap().is_empty());
        assert!(people().unwrap().is_empty());
        assert!(persona_nicks().unwrap().is_empty());
        // The other network is untouched.
        assert_eq!(recent("p2", "#one", 10).unwrap().len(), 1);
    }

    #[test]
    fn clearing_takes_conversation_state_and_marks_but_not_people() {
        let _store = TempStore::new("clear-all");
        append(&[said("#one", 1, "alice", "x")]).unwrap();
        add_mark(&mark(MARK_PINNED, "x")).unwrap();
        set_conversation_state(&ConversationState {
            profile_id: "p1".to_owned(),
            conversation: "#one".to_owned(),
            draft: Some("y".to_owned()),
            ..ConversationState::default()
        })
        .unwrap();
        set_person(&Person {
            note: Some("x".to_owned()),
            ..person("alice")
        })
        .unwrap();

        clear().unwrap();
        assert!(marks(None, None, None).unwrap().is_empty());
        assert!(conversation_states().unwrap().is_empty());
        assert_eq!(approximate_count().unwrap(), 0);
        assert_eq!(
            people().unwrap().len(),
            1,
            "notes about people are not messages"
        );
    }

    #[test]
    fn a_version_four_file_gains_an_index_of_what_it_already_held() {
        let _guard = lock();
        let directory = std::env::temp_dir().join("ddirc-store-v4");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("history.db");

        // A file as the previous release left it, with a replayed line in it.
        {
            let connection = Connection::open(&path).unwrap();
            for step in [migrate_to_1, migrate_to_2, migrate_to_3, migrate_to_4] {
                step(&connection).unwrap();
            }
            connection
                .execute_batch(
                    "INSERT INTO lines (profile_id, conversation, at_ms, sender, text,
                         is_self, is_mention, is_action, is_notice, kind, msgid)
                     VALUES ('p1', '#old', 1, 'alice', 'from \x02before\x02', 0, 0, 0, 0, 0, 'm1'),
                            ('p1', '#old', 1, 'alice', 'from \x02before\x02', 0, 0, 0, 0, 0, 'm1'),
                            ('p1', '#old', 2, NULL, 'alice joined', 0, 0, 0, 0, 1, NULL);
                     PRAGMA user_version = 4",
                )
                .unwrap();
        }

        open(path.to_str().unwrap()).unwrap();
        assert_eq!(
            count().unwrap(),
            2,
            "the duplicate went, the system line stayed"
        );
        assert_eq!(search(None, None, "before", 10, None).unwrap().len(), 1);
        assert!(
            search(None, None, "joined", 10, None).unwrap().is_empty(),
            "system lines are not indexed"
        );
        // And the replay is refused from now on.
        assert_eq!(
            append(&[tagged("#old", 1, "m1", "again")]).unwrap(),
            vec![None]
        );

        close();
        let _ = std::fs::remove_dir_all(&directory);
    }
}
