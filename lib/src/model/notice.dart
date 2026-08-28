// Something the app needs to say, and how loudly.
//
// Split out from the screen that used to hold a bare `String? _error`, because
// three different things were being rendered identically: a mistyped command,
// a transfer that failed after two minutes, and a refusal that is the app
// working correctly. They want different colours, different words and
// different lifetimes, and none of that is expressible as a nullable string.

import 'package:flutter/foundation.dart';

/// How long a notice stays on screen before it clears itself.
///
/// Ten seconds, and the same for every level. Long enough to read a sentence
/// and a path twice over; short enough that a bar nobody dismissed is not
/// still sitting above the composer an hour later.
///
/// What makes this safe is that nothing here is *only* said in the bar. Every
/// failure worth keeping is also a line in the conversation, and the debug log
/// has the rest — so a notice timing out loses the alert, never the record.
const noticeLifetime = Duration(seconds: 10);

/// How much attention a notice is owed.
enum NoticeLevel {
  /// Something did not happen. A command was rejected, a transfer failed, a
  /// file could not be read.
  error,

  /// Something happened, or was prevented, and the user should know why. The
  /// important case is a refusal that is the app keeping a promise — declining
  /// to send a file from behind Tor is not a fault, and painting it the same
  /// red as a crash teaches people to ignore red.
  warning,

  /// Something worth confirming. A file saved, a transfer finished.
  info,
}

/// One thing to tell the user, with what to do about it.
@immutable
class Notice {
  const Notice(this.level, this.message, {this.detail});

  const Notice.error(String message, {String? detail})
    : this(NoticeLevel.error, message, detail: detail);

  const Notice.warning(String message, {String? detail})
    : this(NoticeLevel.warning, message, detail: detail);

  const Notice.info(String message, {String? detail})
    : this(NoticeLevel.info, message, detail: detail);

  final NoticeLevel level;

  /// The headline: what happened, in one line.
  final String message;

  /// What to do about it, when there is something. Kept separate from
  /// [message] so the bar can weight them differently — the failure in full
  /// strength, the suggestion underneath it — rather than running the two
  /// together into a sentence nobody finishes reading.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is Notice &&
      other.level == level &&
      other.message == message &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(level, message, detail);

  @override
  String toString() => 'Notice(${level.name}, $message)';
}

/// Read an error coming back from the core and decide how loud it is.
///
/// The core returns prose, because it is the side that knows what happened.
/// What it cannot know is whether a given outcome is a fault or the app
/// working as designed — so that judgement is made here, from the text, in one
/// place rather than at each of the call sites that shows one.
///
/// Refusals that protect the user are warnings, not errors. A transfer
/// declined because sending would publish an address behind Tor is the proxy
/// doing its job; showing it in the same red as "the disk is full" would teach
/// people that red means nothing.
Notice noticeForFailure(String message) {
  final text = message.trim();
  final lower = text.toLowerCase();

  // The deliberate refusals. Matched on the distinctive phrase rather than the
  // whole string, so rewording the message does not silently reclassify it.
  const protective = [
    'would publish your address',
    'would tell the sender your address',
    'defeat the proxy',
  ];
  if (protective.any(lower.contains)) {
    return Notice.warning(
      'Not sent — that would give away your address',
      detail: text,
    );
  }

  if (lower.contains('cancelled')) {
    return Notice.info('Cancelled', detail: null);
  }

  return Notice.error(text);
}

/// The notice for a transfer that ended, or null when there is nothing to say.
///
/// A file that arrived is worth confirming, because a download the user cannot
/// find is a download that did not happen — so the path is the point of the
/// message, not a decoration on it.
Notice? noticeForTransfer({
  required String filename,
  required String? path,
  required String? error,
}) {
  if (error != null) return noticeForFailure(error);
  if (path != null) {
    return Notice.info('Saved "$filename"', detail: path);
  }
  return Notice.info('Sent "$filename"');
}
