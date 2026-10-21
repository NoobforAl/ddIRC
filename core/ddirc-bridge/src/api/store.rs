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

use crate::api::types::{ReplyRef, TextSpan};

/// One stored line, on its way in or out.
///
/// `kind` is an opaque small integer belonging to the app: zero for a message,
/// and for a system line whatever category the UI files it under. The core
/// deliberately does not know what those mean — a UI category should never
/// become a database migration.
#[derive(Debug, Clone)]
pub struct StoredLine {
    /// The id the store gave this line, on the way out; ignored on the way in.
    ///
    /// What a read position, a pin or a search result holds on to — a server
    /// id is only there when the server sent one.
    pub id: Option<i64>,
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
    /// The server's id for the line, when it had one.
    pub msgid: Option<String>,
    /// What the line replies to, if it is a reply.
    pub reply_to: Option<ReplyRef>,
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
            msgid: line.msgid,
            reply_msgid: line.reply_to.as_ref().and_then(|r| r.msgid.clone()),
            reply_nick: line.reply_to.as_ref().map(|r| r.nick.clone()),
            reply_excerpt: line.reply_to.map(|r| r.excerpt),
        }
    }
}

impl From<store::Row> for StoredLine {
    fn from(row: store::Row) -> Self {
        Self {
            id: Some(row.id),
            ..row.line.into()
        }
    }
}

impl From<store::StoredLine> for StoredLine {
    fn from(line: store::StoredLine) -> Self {
        Self {
            id: None,
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
            msgid: line.msgid,
            // A row has a reply when any of its three parts is there.
            reply_to: (line.reply_msgid.is_some() || line.reply_nick.is_some()).then(|| ReplyRef {
                msgid: line.reply_msgid,
                nick: line.reply_nick.unwrap_or_default(),
                excerpt: line.reply_excerpt.unwrap_or_default(),
            }),
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

/// Write a batch of lines, and return the id each was stored under — `null`
/// for a line already stored, a replay of one the server sent before.
pub fn store_append(lines: Vec<StoredLine>) -> Result<Vec<Option<i64>>, String> {
    let lines: Vec<store::StoredLine> = lines.into_iter().map(Into::into).collect();
    store::append(&lines).map_err(|e| e.to_string())
}

fn rows(result: Result<Vec<store::Row>, store::StoreError>) -> Result<Vec<StoredLine>, String> {
    result
        .map(|rows| rows.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

/// The last `limit` lines of one conversation, oldest first.
pub fn store_recent(
    profile_id: String,
    conversation: String,
    limit: u32,
) -> Result<Vec<StoredLine>, String> {
    rows(store::tail(&profile_id, &conversation, limit))
}

/// The `limit` lines just older than the line at (`at_ms`, `id`), oldest
/// first: the next page up the scrollback.
pub fn store_before(
    profile_id: String,
    conversation: String,
    at_ms: i64,
    id: i64,
    limit: u32,
) -> Result<Vec<StoredLine>, String> {
    rows(store::before(&profile_id, &conversation, at_ms, id, limit))
}

/// The lines either side of one, for opening a conversation at it.
pub fn store_around(
    profile_id: String,
    conversation: String,
    at_ms: i64,
    id: i64,
    radius: u32,
) -> Result<Vec<StoredLine>, String> {
    rows(store::around(&profile_id, &conversation, at_ms, id, radius))
}

/// Lines matching what the user typed, newest first, optionally scoped to a
/// network and a conversation. `before_id` pages down from a previous result.
pub fn store_search(
    profile_id: Option<String>,
    conversation: Option<String>,
    query: String,
    limit: u32,
    before_id: Option<i64>,
) -> Result<Vec<StoredLine>, String> {
    rows(store::search(
        profile_id.as_deref(),
        conversation.as_deref(),
        &query,
        limit,
        before_id,
    ))
}

/// How much history is being kept. The line count is approximate — see
/// `ddirc_core::store::approximate_count` — so the screen says "about".
pub fn store_stats() -> Result<StoreStats, String> {
    let lines = store::approximate_count().map_err(|e| e.to_string())?;
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

/// Delete everything kept for one saved network, for when it is deleted.
pub fn store_forget_profile(profile_id: String) -> Result<(), String> {
    store::forget_profile(&profile_id).map_err(|e| e.to_string())
}

/// What the user keeps about one conversation apart from its messages: an
/// unsent draft, how far it was read, whether it is pinned or archived.
pub struct ConversationState {
    pub profile_id: String,
    /// Already case-folded by the caller.
    pub conversation: String,
    pub draft: Option<String>,
    pub draft_reply_msgid: Option<String>,
    pub read_line_id: Option<i64>,
    pub read_at_ms: Option<i64>,
    /// Place among the pinned conversations, lowest first; null when not
    /// pinned.
    pub pin_order: Option<i64>,
    pub archived: bool,
}

impl From<store::ConversationState> for ConversationState {
    fn from(s: store::ConversationState) -> Self {
        Self {
            profile_id: s.profile_id,
            conversation: s.conversation,
            draft: s.draft,
            draft_reply_msgid: s.draft_reply_msgid,
            read_line_id: s.read_line_id,
            read_at_ms: s.read_at_ms,
            pin_order: s.pin_order,
            archived: s.archived,
        }
    }
}

impl From<ConversationState> for store::ConversationState {
    fn from(s: ConversationState) -> Self {
        Self {
            profile_id: s.profile_id,
            conversation: s.conversation,
            draft: s.draft,
            draft_reply_msgid: s.draft_reply_msgid,
            read_line_id: s.read_line_id,
            read_at_ms: s.read_at_ms,
            pin_order: s.pin_order,
            archived: s.archived,
        }
    }
}

/// Every conversation's state, on every network.
pub fn store_conversation_states() -> Result<Vec<ConversationState>, String> {
    store::conversation_states()
        .map(|list| list.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

/// Write one conversation's state; one with nothing left in it loses its row.
pub fn store_set_conversation_state(state: ConversationState) -> Result<(), String> {
    store::set_conversation_state(&state.into()).map_err(|e| e.to_string())
}

/// A message the user pinned (`kind` 1) or saved (`kind` 2): a copy of it,
/// so it outlives the line it came from.
pub struct Mark {
    /// Zero when adding.
    pub id: i64,
    pub kind: i64,
    pub profile_id: String,
    pub conversation: String,
    pub line_id: Option<i64>,
    pub msgid: Option<String>,
    pub at_ms: i64,
    pub sender: Option<String>,
    pub spans: Vec<TextSpan>,
    pub created_ms: i64,
}

impl From<store::Mark> for Mark {
    fn from(m: store::Mark) -> Self {
        Self {
            id: m.id,
            kind: m.kind,
            profile_id: m.profile_id,
            conversation: m.conversation,
            line_id: m.line_id,
            msgid: m.msgid,
            at_ms: m.at_ms,
            sender: m.sender,
            spans: format::parse(&m.text)
                .into_iter()
                .map(TextSpan::from)
                .collect(),
            created_ms: m.created_ms,
        }
    }
}

impl From<Mark> for store::Mark {
    fn from(m: Mark) -> Self {
        Self {
            id: m.id,
            kind: m.kind,
            profile_id: m.profile_id,
            conversation: m.conversation,
            line_id: m.line_id,
            msgid: m.msgid,
            at_ms: m.at_ms,
            sender: m.sender,
            text: format::encode(
                &m.spans
                    .into_iter()
                    .map(format::TextSpan::from)
                    .collect::<Vec<_>>(),
            ),
            created_ms: m.created_ms,
        }
    }
}

/// Pins and saved messages: of one kind or all, on one network or all, in
/// one conversation or all. Oldest message first.
pub fn store_marks(
    kind: Option<i64>,
    profile_id: Option<String>,
    conversation: Option<String>,
) -> Result<Vec<Mark>, String> {
    store::marks(kind, profile_id.as_deref(), conversation.as_deref())
        .map(|list| list.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

/// Pin or save a message, returning the mark's id. Marking the same message
/// twice returns the first mark's id rather than making a second.
pub fn store_add_mark(mark: Mark) -> Result<i64, String> {
    store::add_mark(&mark.into()).map_err(|e| e.to_string())
}

/// Unpin or unsave.
pub fn store_remove_mark(id: i64) -> Result<(), String> {
    store::remove_mark(id).map_err(|e| e.to_string())
}

/// What the user has written down about one person on one network: a name
/// to show instead of the nick, a note, a colour, a picture.
///
/// The user's annotation, never anything the person sent. Kept in the same
/// database as history and behind the same switch, because it is still a
/// record of who they talk to. `nick` is folded to lower case by the caller.
pub struct Person {
    pub profile_id: String,
    pub nick: String,
    pub alias: Option<String>,
    pub note: Option<String>,
    /// ARGB, as `Color.value` on the Dart side.
    pub color: Option<i64>,
    /// A small PNG, downscaled before it gets here.
    pub avatar: Option<Vec<u8>>,
    /// Seed for a generated pixel avatar, when no picture was chosen.
    pub pixel_seed: Option<i64>,
}

impl From<store::Person> for Person {
    fn from(p: store::Person) -> Self {
        Person {
            profile_id: p.profile_id,
            nick: p.nick,
            alias: p.alias,
            note: p.note,
            color: p.color,
            avatar: p.avatar,
            pixel_seed: p.pixel_seed,
        }
    }
}

impl From<Person> for store::Person {
    fn from(p: Person) -> Self {
        store::Person {
            profile_id: p.profile_id,
            nick: p.nick,
            alias: p.alias,
            note: p.note,
            color: p.color,
            avatar: p.avatar,
            pixel_seed: p.pixel_seed,
        }
    }
}

/// Everyone the user has annotated, on every network.
pub fn store_people() -> Result<Vec<Person>, String> {
    store::people()
        .map(|people| people.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

/// Write what is known about one person, replacing what was there. A person
/// with every field cleared loses their row.
pub fn store_set_person(person: Person) -> Result<(), String> {
    store::set_person(&person.into()).map_err(|e| e.to_string())
}

/// Forget everyone on one network — for when the network itself is forgotten.
pub fn store_forget_people(profile_id: String) -> Result<(), String> {
    store::forget_people(&profile_id).map_err(|e| e.to_string())
}

/// One of the user's own identities: a private label a network never sees.
///
/// The nick a persona actually connects under is per network and lives in
/// [`PersonaNick`], because one identity wears a different, unlinkable handle
/// on each server it touches.
pub struct Persona {
    pub id: String,
    pub label: String,
}

/// The nick one persona wears on one saved network, generated once and kept.
pub struct PersonaNick {
    pub persona_id: String,
    pub network_id: String,
    pub nick: String,
}

impl From<store::Persona> for Persona {
    fn from(p: store::Persona) -> Self {
        Persona {
            id: p.id,
            label: p.label,
        }
    }
}

impl From<Persona> for store::Persona {
    fn from(p: Persona) -> Self {
        store::Persona {
            id: p.id,
            label: p.label,
        }
    }
}

impl From<store::PersonaNick> for PersonaNick {
    fn from(n: store::PersonaNick) -> Self {
        PersonaNick {
            persona_id: n.persona_id,
            network_id: n.network_id,
            nick: n.nick,
        }
    }
}

impl From<PersonaNick> for store::PersonaNick {
    fn from(n: PersonaNick) -> Self {
        store::PersonaNick {
            persona_id: n.persona_id,
            network_id: n.network_id,
            nick: n.nick,
        }
    }
}

/// Every identity the user has made.
pub fn store_personas() -> Result<Vec<Persona>, String> {
    store::personas()
        .map(|list| list.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

/// Create or rename an identity.
pub fn store_set_persona(persona: Persona) -> Result<(), String> {
    store::set_persona(&persona.into()).map_err(|e| e.to_string())
}

/// Forget an identity, and every remembered nick that was hers.
pub fn store_forget_persona(id: String) -> Result<(), String> {
    store::forget_persona(&id).map_err(|e| e.to_string())
}

/// Every remembered (persona, network) → nick, for the app to hold in memory.
pub fn store_persona_nicks() -> Result<Vec<PersonaNick>, String> {
    store::persona_nicks()
        .map(|list| list.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

/// Remember the nick a persona wears on a network, replacing any earlier one.
pub fn store_set_persona_nick(nick: PersonaNick) -> Result<(), String> {
    store::set_persona_nick(&nick.into()).map_err(|e| e.to_string())
}

/// Forget every persona's nick on one network — for when the network itself
/// is forgotten, alongside [`store_forget_people`].
pub fn store_forget_persona_nicks(network_id: String) -> Result<(), String> {
    store::forget_persona_nicks_for_network(&network_id).map_err(|e| e.to_string())
}
