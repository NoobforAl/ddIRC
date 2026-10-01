import 'package:flutter/foundation.dart';

import '../rust/api/store.dart' as store;
import '../rust/api/types.dart' as rust;
import 'history.dart';
import 'session.dart';

/// What a [store.Mark] is.
enum MarkKind {
  /// Pinned to its conversation, shown in a bar at the top of it.
  pinned(1),

  /// Saved for the user's own list, across every network.
  saved(2);

  const MarkKind(this.code);

  /// As the store files it.
  final int code;
}

/// Messages the user pinned or saved.
///
/// Only while history is being kept — see [available]. Unlike a draft, a pin
/// is nothing but a promise to still be there later, and one that vanished on
/// the next launch would be a feature that lies.
///
/// Each mark is a *copy* of the message, not a pointer to it: the store prunes
/// its oldest lines, and a saved message lost because enough was said since
/// would be a bookmark that does not keep its page. The whole list is small —
/// a row per message somebody chose — and held in memory whole.
class Marks extends ChangeNotifier {
  Marks._();

  static final instance = Marks._();

  List<store.Mark> _all = const [];

  bool get available => MessageHistory.instance.enabled;

  /// The messages pinned in one conversation, oldest first.
  List<store.Mark> pinsFor(String profileId, String conversation) {
    final key = MessageHistory.key(conversation);
    return [
      for (final mark in _all)
        if (mark.kind == MarkKind.pinned.code &&
            mark.profileId == profileId &&
            mark.conversation == key)
          mark,
    ];
  }

  /// Everything saved, most recently saved first.
  List<store.Mark> get saved {
    final list = [
      for (final mark in _all)
        if (mark.kind == MarkKind.saved.code) mark,
    ];
    list.sort((a, b) => b.createdMs.compareTo(a.createdMs));
    return list;
  }

  /// The mark of [kind] on [line], if there is one.
  ///
  /// Matched the way the store makes a mark unique — the time, who said it,
  /// and what they said — because the line on screen may never have been
  /// given an id, and a server id is the exception rather than the rule.
  store.Mark? find(
    MarkKind kind,
    String profileId,
    String conversation,
    ChatLine line,
  ) {
    final message = line.message;
    if (message == null) return null;
    final key = MessageHistory.key(conversation);
    final at = line.at.millisecondsSinceEpoch;
    final text = plainText(message.spans);
    for (final mark in _all) {
      if (mark.kind == kind.code &&
          mark.profileId == profileId &&
          mark.conversation == key &&
          mark.atMs == at &&
          mark.sender == message.sender &&
          plainText(mark.spans) == text) {
        return mark;
      }
    }
    return null;
  }

  bool isMarked(
    MarkKind kind,
    String profileId,
    String conversation,
    ChatLine line,
  ) => find(kind, profileId, conversation, line) != null;

  /// Mark [line], or unmark it if it already is. Returns whether it is
  /// marked afterwards.
  Future<bool> toggle(
    MarkKind kind,
    String profileId,
    String conversation,
    ChatLine line,
  ) async {
    final message = line.message;
    if (!available || message == null) return false;
    final existing = find(kind, profileId, conversation, line);
    if (existing != null) {
      await remove(existing);
      return false;
    }
    final mark = store.Mark(
      id: 0,
      kind: kind.code,
      profileId: profileId,
      conversation: MessageHistory.key(conversation),
      lineId: line.dbId,
      msgid: message.msgid,
      atMs: line.at.millisecondsSinceEpoch,
      sender: message.sender,
      spans: message.spans,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final id = await store.storeAddMark(mark: mark);
      _all = [
        ..._all,
        store.Mark(
          id: id,
          kind: mark.kind,
          profileId: mark.profileId,
          conversation: mark.conversation,
          lineId: mark.lineId,
          msgid: mark.msgid,
          atMs: mark.atMs,
          sender: mark.sender,
          spans: mark.spans,
          createdMs: mark.createdMs,
        ),
      ];
      notifyListeners();
      return true;
    } catch (error) {
      debugPrint('ddIRC: could not mark a message ($error)');
      return false;
    }
  }

  Future<void> remove(store.Mark mark) async {
    _all = [
      for (final m in _all)
        if (m.id != mark.id) m,
    ];
    notifyListeners();
    if (!available) return;
    try {
      await store.storeRemoveMark(id: mark.id);
    } catch (error) {
      debugPrint('ddIRC: could not unmark a message ($error)');
    }
  }

  /// Load every mark once the database opens, and let them go when it
  /// closes — with history off there is nowhere they are kept.
  Future<void> sync() async {
    if (!available) {
      if (_all.isNotEmpty) {
        _all = const [];
        notifyListeners();
      }
      return;
    }
    try {
      _all = await store.storeMarks();
    } catch (error) {
      debugPrint('ddIRC: could not load pinned and saved messages ($error)');
      _all = const [];
    }
    notifyListeners();
  }

  /// Forget one network's marks from memory; the store forgets its side in
  /// [MessageHistory.forgetProfile].
  void forgetProfile(String profileId) {
    _all = [
      for (final m in _all)
        if (m.profileId != profileId) m,
    ];
    notifyListeners();
  }

  /// A mark's message as a line, for showing it and for finding it again.
  static ChatLine lineOf(store.Mark mark) {
    final name = mark.conversation;
    return ChatLine.message(
      rust.ChatMessage(
        target: MessageHistory.looksLikeChannel(name)
            ? rust.Target.channel(name: name)
            : rust.Target.direct(nick: name),
        sender: mark.sender ?? '',
        spans: mark.spans,
        isSelf: false,
        isMention: false,
        isAction: false,
        isNotice: false,
        msgid: mark.msgid,
      ),
      DateTime.fromMillisecondsSinceEpoch(mark.atMs),
    )..dbId = mark.lineId;
  }

  static String plainText(List<rust.TextSpan> spans) =>
      spans.map((s) => s.text).join();

  @visibleForTesting
  void resetForTest([List<store.Mark> marks = const []]) {
    _all = marks;
  }
}
