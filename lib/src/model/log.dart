import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Writes logs to disk, when the user has asked for them.
///
/// Two independent switches, both off by default, because they carry very
/// different risks:
///
/// * **Chat logs** record what people said. This is the most sensitive file
///   the app can write — more sensitive than the password store, which at
///   least is encrypted by the platform. It is off by default and stays off
///   until someone deliberately turns it on.
/// * **Debug logs** record connection and protocol events, and never message
///   content. They exist so a bug report can say what actually happened
///   instead of "it did not connect".
///
/// Nothing here ever writes a password. The debug log is fed from status and
/// error events, which the core produces after secrets have been stripped, and
/// [redact] is a second line of defence over anything assembled by hand.
///
/// Failures are swallowed on purpose. A full disk, a read-only directory or a
/// revoked permission must not take the app down or interrupt a conversation —
/// logging is a diagnostic aid, never something the client depends on.
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// Flushed on a timer rather than per line. A busy channel would otherwise
  /// mean a syscall per message, on the UI isolate.
  static const _flushEvery = Duration(seconds: 2);

  /// Rotated at this size, keeping one previous file. Chat logs grow without
  /// any natural bound, and a log that quietly eats a disk is a bug of its own.
  ///
  /// Fixed at 10 MB rather than offered as a setting. A size limit is not a
  /// preference — nobody opens a settings screen wanting to choose one — and
  /// the number only has to be large enough to hold a useful amount of history
  /// and small enough that two of them cannot matter on any disk this app runs
  /// on. With one rotated copy kept, the ceiling for each log is twice this.
  static const maxLogBytes = 10 * 1024 * 1024;

  Directory? _directory;
  final _pending = <_Target, StringBuffer>{};
  Timer? _timer;
  bool _writing = false;

  bool _chat = false;
  bool _debug = false;

  /// Where the files live, once [start] has resolved it. Null until then, and
  /// on any platform that refused to name a directory.
  String? get directoryPath => _directory?.path;

  bool get chatEnabled => _chat;
  bool get debugEnabled => _debug;

  /// Resolve the log directory. Safe to call more than once.
  ///
  /// A `logs/` folder inside the application support directory — the app's own
  /// private data folder, which is where the settings store and the secret
  /// store already live. So the logs sit beside the rest of the app's state
  /// rather than somewhere the user has to be told about separately:
  ///
  /// | Platform | Where that is |
  /// |---|---|
  /// | Windows | `%APPDATA%\ddIRC\logs\` — the same tree as the settings file |
  /// | Android | `/data/user/0/<package>/files/logs/` — app-private internal storage, not the SD card and not readable by other apps |
  /// | Linux | `$XDG_DATA_HOME/ddirc/logs/`, or `~/.local/share/ddirc/logs/` |
  /// | macOS/iOS | `~/Library/Application Support/<bundle>/logs/` |
  ///
  /// Deliberately *not* Documents, Downloads or external storage. On Android
  /// those are world-readable to anything holding the storage permission, and
  /// a chat log is the last file in this app that should be.
  ///
  /// Called during startup regardless of whether logging is on, so that the
  /// settings screen can show the path *before* the user commits to enabling
  /// anything. Creating the directory is deferred until there is a line to
  /// write, so a user who never turns logging on never gets a stray folder.
  Future<void> start() async {
    if (_directory != null) return;
    try {
      final base = await getApplicationSupportDirectory();
      _directory = Directory('${base.path}${Platform.pathSeparator}logs');
    } catch (error) {
      debugPrint('ddIRC: no writable log directory ($error)');
    }
  }

  /// Turn each log on or off. Disabling flushes what is already buffered.
  void configure({required bool chat, required bool debug}) {
    if (chat == _chat && debug == _debug) return;
    _chat = chat;
    _debug = debug;
    if (!chat) _pending.remove(_Target.chat);
    if (!debug) _pending.remove(_Target.debug);
    if (!chat && !debug) {
      _timer?.cancel();
      _timer = null;
    }
    unawaited(flush());
  }

  /// Record something that was said.
  void chat({
    required String network,
    required String conversation,
    required String text,
  }) {
    if (!_chat) return;
    _write(_Target.chat, '[$network] $conversation  $text');
  }

  /// Record a connection or protocol event. Never message content.
  void debug(String message) {
    if (!_debug) return;
    _write(_Target.debug, redact(message));
  }

  /// Blank out anything that looks like a credential.
  ///
  /// A backstop, not the primary defence — the core strips secrets before they
  /// ever become an event. It earns its place because the cost of being wrong
  /// is a password sitting in a plaintext file that the user is about to
  /// attach to a bug report.
  @visibleForTesting
  static String redact(String message) {
    return message
        .replaceAll(
          RegExp(
            r'\b(pass|password|pwd|token|secret|auth)\s*[:=]\s*\S+',
            caseSensitive: false,
          ),
          r'$1: <redacted>',
        )
        .replaceAll(
          RegExp(r'\b(PASS|AUTHENTICATE|OPER)\s+\S+'),
          r'$1 <redacted>',
        );
  }

  void _write(_Target target, String line) {
    final at = DateTime.now().toIso8601String();
    (_pending[target] ??= StringBuffer()).writeln('$at  $line');
    _timer ??= Timer(_flushEvery, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Write everything buffered. Exposed so a test does not have to wait out
  /// the timer, and so disabling a log does not leave its tail unwritten.
  Future<void> flush() async {
    if (_pending.isEmpty || _writing) return;
    final directory = _directory;
    if (directory == null) return;

    // Guarded rather than queued: two overlapping flushes would interleave
    // their appends. Anything that arrives while one is in flight simply goes
    // out with the next.
    _writing = true;
    try {
      final batch = Map.of(_pending);
      _pending.clear();
      for (final MapEntry(key: target, value: buffer) in batch.entries) {
        await _append(directory, target, buffer.toString());
      }
    } finally {
      _writing = false;
    }
  }

  Future<void> _append(
    Directory directory,
    _Target target,
    String content,
  ) async {
    try {
      if (!directory.existsSync()) await directory.create(recursive: true);
      final file = File(
        '${directory.path}${Platform.pathSeparator}${target.filename}',
      );
      if (await file.exists() && await file.length() > maxLogBytes) {
        // One generation kept. Two files with a known ceiling is a bound the
        // user can reason about; an ever-growing numbered series is not.
        final previous = File('${file.path}.1');
        if (await previous.exists()) await previous.delete();
        await file.rename(previous.path);
      }
      await file.writeAsString(content, mode: FileMode.append, flush: true);
    } catch (error) {
      // Deliberately terminal. Reporting a logging failure through the log is
      // circular, and surfacing it in the UI would interrupt a conversation
      // over a diagnostic the user may not know they enabled.
      debugPrint('ddIRC: could not write ${target.filename} ($error)');
    }
  }

  /// Delete both logs and their rotated copies.
  Future<void> clear() async {
    _pending.clear();
    final directory = _directory;
    if (directory == null || !directory.existsSync()) return;
    for (final target in _Target.values) {
      for (final name in [target.filename, '${target.filename}.1']) {
        try {
          final file = File('${directory.path}${Platform.pathSeparator}$name');
          if (await file.exists()) await file.delete();
        } catch (error) {
          debugPrint('ddIRC: could not delete $name ($error)');
        }
      }
    }
  }

  /// Point the log at a directory of the caller's choosing.
  @visibleForTesting
  void useDirectory(Directory directory) => _directory = directory;

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _chat = false;
    _debug = false;
    _directory = null;
  }
}

enum _Target {
  chat('chat.log'),
  debug('debug.log');

  const _Target(this.filename);

  final String filename;
}
