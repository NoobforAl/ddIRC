import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../rust/api/store.dart' as store;
import '../rust/api/types.dart' as rust;
import 'errors.dart';
import 'session.dart';

/// Saved scrollback, when the user has asked for it.
///
/// The in-memory scrollback is capped and dies with the process, which is fine
/// for a session and useless the moment somebody wants to know what was said
/// yesterday. This keeps it, in a database, on disk — and it is off until
/// somebody turns it on, because a file recording what people said is the most
/// sensitive thing this app writes. The same reasoning as [AppLog]'s chat log,
/// and it is deliberately offered in the same place with the same framing.
///
/// The two are not redundant. The chat log is a plain-text file, written for a
/// person to open in an editor and never read back by the app. This is
/// structured, indexed, and read back: it is what fills the top of a channel
/// when you rejoin it, formatting intact.
///
/// # Where the work happens
///
/// In Rust, in `ddirc_core::store`. Not because Dart could not open a database,
/// but because a second persistence layer in a second language means two
/// schemas to keep in step and two places to get a migration wrong — and this
/// one belongs next to the session state it is a record of. See that module for
/// the rest of the argument.
///
/// # Writes are buffered
///
/// A busy channel produces messages faster than it is worth crossing an FFI
/// boundary for, so lines queue here and go over in batches on a timer. The
/// same shape [AppLog] uses, and for the same reason: a syscall per message, on
/// the UI isolate, is the thing to avoid.
///
/// Failures are swallowed on purpose. A full disk or a revoked permission must
/// not take the app down or interrupt a conversation — history is a
/// convenience, never something the client depends on.
class MessageHistory {
  MessageHistory._();

  static final MessageHistory instance = MessageHistory._();

  /// Flushed on a timer rather than per line. See the class doc.
  static const _flushEvery = Duration(seconds: 2);

  /// How much of a conversation is restored when it opens.
  ///
  /// Not the whole of it. What this is for is arriving in a channel and finding
  /// the last conversation still there rather than an empty screen; scrolling
  /// back through a year is a different feature and would want a different
  /// interface than a list that has to be rendered all at once.
  static const restoreLines = 200;

  String? _path;
  final List<store.StoredLine> _pending = [];
  Timer? _timer;
  bool _writing = false;
  bool _enabled = false;

  /// Where the database lives, once [start] has resolved it. Null until then,
  /// and on any platform that refused to name a directory.
  String? get path => _path;

  bool get enabled => _enabled;

  /// Resolve where the database would go. Safe to call more than once.
  ///
  /// Beside the logs and the settings, in the app's own private data directory
  /// — see [AppLog.start] for the per-platform table and for why it is
  /// deliberately not Documents or external storage. Nothing is created here:
  /// a user who never turns this on never gets a stray file.
  Future<void> start() async {
    if (_path != null) return;
    try {
      final base = await getApplicationSupportDirectory();
      _path = '${base.path}${Platform.pathSeparator}history.db';
    } catch (error) {
      debugPrint('ddIRC: nowhere to keep message history ($error)');
    }
  }

  /// Turn history on or off.
  ///
  /// Turning it off flushes what is already queued and closes the database.
  /// Nothing is deleted — the user asked to stop recording, not to destroy what
  /// was already recorded, and [clear] is the separate thing that does that.
  Future<void> configure({required bool enabled}) async {
    if (enabled == _enabled) return;
    final path = _path;
    if (enabled && path == null) return;

    if (!enabled) {
      _enabled = false;
      await flush();
      _pending.clear();
      _timer?.cancel();
      _timer = null;
      try {
        await store.storeClose();
      } catch (error) {
        debugPrint('ddIRC: could not close the message store ($error)');
      }
      return;
    }

    try {
      await store.storeOpen(path: path!);
      _enabled = true;
      _lastError = null;
    } catch (error) {
      // Left off rather than half on, and the reason is kept rather than only
      // printed. The commonest cause is a file written by a newer build, and a
      // switch that appears to be on while nothing is being written would be
      // history the user believes they have and does not.
      _enabled = false;
      _lastError = describeError(error);
      debugPrint('ddIRC: message history unavailable ($error)');
    }
  }

  /// Why history is not being kept, when it was asked for and could not be.
  ///
  /// Read by the settings page, which is the only place that can do anything
  /// about it. Cleared as soon as the store opens.
  String? get lastError => _lastError;
  String? _lastError;

  /// Queue one line for writing.
  ///
  /// [conversation] is the display name; the key it is filed under is derived
  /// here so that every caller cannot get the case folding subtly different.
  void record({
    required String profileId,
    required String conversation,
    required ChatLine line,
  }) {
    if (!_enabled) return;
    _pending.add(_encode(profileId, conversation, line));
    _timer ??= Timer(_flushEvery, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Write everything queued.
  ///
  /// Exposed so a test does not have to wait out the timer, and so turning
  /// history off does not leave its tail unwritten.
  Future<void> flush() async {
    if (_pending.isEmpty || _writing) return;

    // Guarded rather than queued: two overlapping flushes would write the same
    // batch twice. Anything that arrives while one is in flight goes out with
    // the next.
    _writing = true;
    final batch = List<store.StoredLine>.of(_pending);
    _pending.clear();
    try {
      await store.storeAppend(lines: batch);
    } catch (error) {
      // Deliberately terminal, and deliberately not put back on the queue: a
      // store that is failing will fail the retry too, and a queue that only
      // grows is a memory leak wearing a recovery strategy's clothes.
      debugPrint('ddIRC: could not save ${batch.length} line(s) ($error)');
    } finally {
      _writing = false;
    }
  }

  /// The tail of one conversation, oldest first, or empty if there is none.
  Future<List<ChatLine>> load({
    required String profileId,
    required String conversation,
    required bool isChannel,
    int limit = restoreLines,
  }) async {
    if (!_enabled) return const [];
    try {
      final rows = await store.storeRecent(
        profileId: profileId,
        conversation: key(conversation),
        limit: limit,
      );
      return [for (final row in rows) _decode(row, conversation, isChannel)];
    } catch (error) {
      debugPrint('ddIRC: could not read message history ($error)');
      return const [];
    }
  }

  /// How much is being kept, or null when nothing is open or it cannot be read.
  Future<store.StoreStats?> stats() async {
    if (!_enabled) return null;
    try {
      await flush();
      return await store.storeStats();
    } catch (error) {
      debugPrint('ddIRC: could not measure the message store ($error)');
      return null;
    }
  }

  /// Delete everything, and give the disk space back.
  Future<void> clear() async {
    _pending.clear();
    if (!_enabled) return;
    try {
      await store.storeClear();
    } catch (error) {
      debugPrint('ddIRC: could not clear message history ($error)');
    }
  }

  /// Delete one conversation, leaving the rest.
  Future<void> forget({
    required String profileId,
    required String conversation,
  }) async {
    if (!_enabled) return;
    try {
      await store.storeForget(
        profileId: profileId,
        conversation: key(conversation),
      );
    } catch (error) {
      debugPrint('ddIRC: could not forget $conversation ($error)');
    }
  }

  /// How a conversation name is filed.
  ///
  /// The same fold [SessionModel] uses for its own map, and it has to stay that
  /// way: a channel stored under one spelling and looked up under another is
  /// history that exists and can never be found.
  @visibleForTesting
  static String key(String name) => name.toLowerCase();

  /// Zero for a message; a system line's kind is stored one higher so that the
  /// two can never be confused by a row whose sender was lost.
  static int _kindOf(ChatLine line) =>
      line.kind == null ? 0 : line.kind!.index + 1;

  static SystemKind? _kindFrom(int kind) {
    final index = kind - 1;
    // A row written by a build that knew a system kind this one does not.
    // Filed as a plain connection note rather than dropped: the text still
    // says what happened.
    if (index < 0 || index >= SystemKind.values.length) {
      return SystemKind.connection;
    }
    return SystemKind.values[index];
  }

  static store.StoredLine _encode(
    String profileId,
    String conversation,
    ChatLine line,
  ) {
    final message = line.message;
    return store.StoredLine(
      profileId: profileId,
      conversation: key(conversation),
      atMs: line.at.millisecondsSinceEpoch,
      sender: message?.sender,
      senderPrefix: message?.senderPrefix,
      spans:
          message?.spans ?? [rust.TextSpan(text: line.system!, style: _flat)],
      isSelf: message?.isSelf ?? false,
      isMention: message?.isMention ?? false,
      isAction: message?.isAction ?? false,
      isNotice: message?.isNotice ?? false,
      kind: _kindOf(line),
    );
  }

  static ChatLine _decode(
    store.StoredLine row,
    String conversation,
    bool isChannel,
  ) {
    final at = DateTime.fromMillisecondsSinceEpoch(row.atMs);
    final sender = row.sender;
    if (sender == null) {
      return ChatLine.system(
        row.spans.map((span) => span.text).join(),
        at,
        _kindFrom(row.kind),
      );
    }
    return ChatLine.message(
      rust.ChatMessage(
        // Rebuilt from the conversation it was filed under rather than stored
        // alongside every row: it is the same answer for every line in a
        // conversation, and a stored copy is a second place for it to be wrong.
        target: isChannel
            ? rust.Target.channel(name: conversation)
            : rust.Target.direct(nick: conversation),
        sender: sender,
        senderPrefix: row.senderPrefix,
        spans: row.spans,
        isSelf: row.isSelf,
        isMention: row.isMention,
        isAction: row.isAction,
        isNotice: row.isNotice,
      ),
      at,
    );
  }

  /// The style a system line is written with: none. System text carries no
  /// formatting codes, and the store keeps spans rather than strings.
  static const _flat = rust.SpanStyle(
    bold: false,
    italic: false,
    underline: false,
    strikethrough: false,
    monospace: false,
    inverse: false,
  );

  /// The two halves of the mapping, for a test that has no native library to
  /// put a row through. Everything about a line that has to survive being
  /// written down passes through exactly these.
  @visibleForTesting
  static store.StoredLine encodeForTest(
    String profileId,
    String conversation,
    ChatLine line,
  ) => _encode(profileId, conversation, line);

  @visibleForTesting
  static ChatLine decodeForTest(
    store.StoredLine row,
    String conversation,
    bool isChannel,
  ) => _decode(row, conversation, isChannel);

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _enabled = false;
    _lastError = null;
    _path = null;
  }

  /// Point the store at a path of the caller's choosing.
  @visibleForTesting
  void useFile(String path) => _path = path;
}
