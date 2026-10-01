import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/store.dart' as store;
import 'history.dart';
import 'session.dart';

/// What the user keeps about one conversation, apart from what was said in it.
///
/// Everything here is the user's own doing: something typed and not sent, how
/// far they have read, whether they pinned the conversation to the top of the
/// list or put it away.
class ConversationPrefs {
  ConversationPrefs();

  ConversationPrefs.fromRow(store.ConversationState row)
    : draft = row.draft,
      draftReplyMsgid = row.draftReplyMsgid,
      readLineId = row.readLineId?.toInt(),
      readAtMs = row.readAtMs?.toInt(),
      pinOrder = row.pinOrder?.toInt(),
      archived = row.archived;

  /// Text typed into the composer and not sent. Null rather than empty.
  String? draft;

  /// The server id of the message the draft is a reply to, when it is one.
  String? draftReplyMsgid;

  /// The last line read: its store id when it had one, and its time, which
  /// is what places the "new messages" rule after a restart.
  int? readLineId;
  int? readAtMs;

  /// Where among the pinned conversations, lowest first; null when not pinned.
  int? pinOrder;
  bool archived = false;

  bool get isBlank =>
      draft == null &&
      draftReplyMsgid == null &&
      readLineId == null &&
      readAtMs == null &&
      pinOrder == null &&
      !archived;

  store.ConversationState toRow(String profileId, String conversation) =>
      store.ConversationState(
        profileId: profileId,
        conversation: conversation,
        draft: draft,
        draftReplyMsgid: draftReplyMsgid,
        readLineId: readLineId,
        readAtMs: readAtMs,
        pinOrder: pinOrder,
        archived: archived,
      );
}

/// Drafts, read positions, pins and archives, for every conversation on every
/// network.
///
/// The same arrangement as [People]: always in memory, written through to the
/// history database only while that is on. Drafts and read positions are
/// useful within a session whether or not anything is kept; pinning and
/// archiving are offered only while there is somewhere to keep them — see
/// [available] — because an arrangement of the list that quietly evaporates on
/// the next launch is an arrangement nobody asked for.
///
/// Keyed by network and conversation, the name folded to lower case, the same
/// way [MessageHistory] files lines.
class ConversationStates extends ChangeNotifier {
  ConversationStates._();

  static final instance = ConversationStates._();

  /// How long a draft or a read position waits before it is written. A draft
  /// changes as fast as somebody types, and only the last version matters.
  static const _writeAfter = Duration(milliseconds: 500);

  final Map<String, ConversationPrefs> _states = {};
  final Map<String, Timer> _writes = {};

  static String _key(String profileId, String name) =>
      '$profileId/${MessageHistory.key(name)}';

  /// Whether pinning and archiving can be offered: only while history is
  /// being kept.
  bool get available => MessageHistory.instance.enabled;

  ConversationPrefs? of(String profileId, String name) =>
      _states[_key(profileId, name)];

  ConversationPrefs _edit(String profileId, String name) =>
      _states.putIfAbsent(_key(profileId, name), ConversationPrefs.new);

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  String? draftOf(String profileId, String name) => of(profileId, name)?.draft;

  /// Keep what is in the composer for [name], or forget it when it is empty.
  ///
  /// [notify] is false from a screen being torn down: telling listeners then
  /// would ask widgets to rebuild while the tree is locked for unmounting.
  /// The list catches up on its next build, which is moments away.
  void setDraft(
    String profileId,
    String name,
    String text, {
    String? replyMsgid,
    bool notify = true,
  }) {
    final draft = text.trim().isEmpty ? null : text;
    final current = of(profileId, name);
    if (current?.draft == draft && current?.draftReplyMsgid == replyMsgid) {
      return;
    }
    final state = _edit(profileId, name)
      ..draft = draft
      ..draftReplyMsgid = draft == null ? null : replyMsgid;
    _settle(profileId, name, state, later: true);
    if (notify) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Read positions
  // ---------------------------------------------------------------------------

  /// Remember that everything up to [last] has been seen.
  ///
  /// Not announced to listeners: nothing on screen shows a read position
  /// until the next launch, and a rebuild per arriving line in the open
  /// conversation would be a rebuild for nothing.
  void markRead(String profileId, String name, ChatLine? last) {
    if (last == null) return;
    final at = last.at.millisecondsSinceEpoch;
    final state = _edit(profileId, name);
    if (state.readAtMs != null && state.readAtMs! > at) return;
    state
      ..readAtMs = at
      ..readLineId = last.dbId;
    _settle(profileId, name, state, later: true);
  }

  /// Whether [line] arrived after the read position recorded for [name].
  ///
  /// False when nothing was recorded: a conversation never opened has no
  /// position to be past, and calling its whole history unread would report
  /// yesterday as news.
  bool isAfterRead(String profileId, String name, ChatLine line) {
    final state = of(profileId, name);
    final readAt = state?.readAtMs;
    if (readAt == null) return false;
    final at = line.at.millisecondsSinceEpoch;
    if (at != readAt) return at > readAt;
    final readId = state!.readLineId;
    final id = line.dbId;
    return readId != null && id != null && id > readId;
  }

  // ---------------------------------------------------------------------------
  // The list: pinned and archived
  // ---------------------------------------------------------------------------

  bool isPinned(String profileId, String name) =>
      of(profileId, name)?.pinOrder != null;

  bool isArchived(String profileId, String name) =>
      of(profileId, name)?.archived ?? false;

  /// Pin [name] to the top of this network's list, after anything already
  /// pinned — or unpin it. Pinning takes it out of the archive: the two ask
  /// for opposite things.
  void setPinned(String profileId, String name, bool pinned) {
    if (!available || isPinned(profileId, name) == pinned) return;
    final state = _edit(profileId, name);
    if (pinned) {
      final prefix = '$profileId/';
      var highest = -1;
      for (final entry in _states.entries) {
        final order = entry.value.pinOrder;
        if (entry.key.startsWith(prefix) && order != null && order > highest) {
          highest = order;
        }
      }
      state
        ..pinOrder = highest + 1
        ..archived = false;
    } else {
      state.pinOrder = null;
    }
    _settle(profileId, name, state);
    notifyListeners();
  }

  /// Put [name] away at the bottom of the list, or bring it back.
  void setArchived(String profileId, String name, bool archived) {
    if (!available || isArchived(profileId, name) == archived) return;
    final state = _edit(profileId, name)..archived = archived;
    if (archived) state.pinOrder = null;
    _settle(profileId, name, state);
    notifyListeners();
  }

  /// Order [conversations] for the list: pinned first in the order they were
  /// pinned, then the rest as they were, then — separately — the archived.
  ({List<Conversation> shown, List<Conversation> archived}) arrange(
    String profileId,
    List<Conversation> conversations,
  ) {
    final pinned = <Conversation>[];
    final rest = <Conversation>[];
    final archived = <Conversation>[];
    for (final conversation in conversations) {
      final state = of(profileId, conversation.name);
      if (state?.pinOrder != null) {
        pinned.add(conversation);
      } else if (state?.archived ?? false) {
        archived.add(conversation);
      } else {
        rest.add(conversation);
      }
    }
    pinned.sort(
      (a, b) => of(
        profileId,
        a.name,
      )!.pinOrder!.compareTo(of(profileId, b.name)!.pinOrder!),
    );
    return (shown: [...pinned, ...rest], archived: archived);
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Write one conversation's state through to the store, now or after the
  /// pause in [_writeAfter]. A state with nothing left in it is dropped from
  /// memory too, so the map does not fill with empty entries.
  void _settle(
    String profileId,
    String name,
    ConversationPrefs state, {
    bool later = false,
  }) {
    final key = _key(profileId, name);
    if (state.isBlank) _states.remove(key);
    if (!MessageHistory.instance.enabled) return;
    _writes.remove(key)?.cancel();
    final row = state.toRow(profileId, MessageHistory.key(name));
    if (!later) {
      unawaited(_write(row));
      return;
    }
    _writes[key] = Timer(_writeAfter, () {
      _writes.remove(key);
      // Read again at the moment of writing: the draft may have moved on.
      final current = _states[key] ?? ConversationPrefs();
      unawaited(_write(current.toRow(profileId, MessageHistory.key(name))));
    });
  }

  static Future<void> _write(store.ConversationState row) async {
    try {
      await store.storeSetConversationState(state: row);
    } catch (error) {
      debugPrint('ddIRC: could not save a conversation\'s state ($error)');
    }
  }

  /// Write anything still waiting out its pause. For quitting.
  Future<void> flush() async {
    final waiting = Map.of(_writes);
    _writes.clear();
    for (final entry in waiting.entries) {
      entry.value.cancel();
      final slash = entry.key.indexOf('/');
      final state = _states[entry.key] ?? ConversationPrefs();
      await _write(
        state.toRow(
          entry.key.substring(0, slash),
          entry.key.substring(slash + 1),
        ),
      );
    }
  }

  /// Bring memory and disk into step once the database has opened.
  ///
  /// Disk fills in what memory does not have; what memory has and disk does
  /// not is written. Where both have a conversation, memory wins — it is the
  /// more recent of the two by construction.
  Future<void> sync() async {
    if (!MessageHistory.instance.enabled) return;
    List<store.ConversationState> rows;
    try {
      rows = await store.storeConversationStates();
    } catch (error) {
      debugPrint('ddIRC: could not load conversation state ($error)');
      return;
    }
    final onDisk = <String>{};
    for (final row in rows) {
      final key = '${row.profileId}/${row.conversation}';
      onDisk.add(key);
      _states.putIfAbsent(key, () => ConversationPrefs.fromRow(row));
    }
    for (final entry in _states.entries) {
      if (onDisk.contains(entry.key)) continue;
      final slash = entry.key.indexOf('/');
      await _write(
        entry.value.toRow(
          entry.key.substring(0, slash),
          entry.key.substring(slash + 1),
        ),
      );
    }
    notifyListeners();
  }

  /// Forget one network's conversations from memory. The store forgets its
  /// side in [MessageHistory.forgetProfile].
  void forgetProfile(String profileId) {
    final prefix = '$profileId/';
    _states.removeWhere((key, _) => key.startsWith(prefix));
    for (final key
        in _writes.keys.where((k) => k.startsWith(prefix)).toList()) {
      _writes.remove(key)?.cancel();
    }
    notifyListeners();
  }

  /// Forget everything, in memory, after the store was emptied — so a
  /// "delete saved messages" is not followed by drafts and pins that the
  /// next write would put straight back.
  void clear() {
    resetForTest();
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    for (final timer in _writes.values) {
      timer.cancel();
    }
    _writes.clear();
    _states.clear();
  }
}
