import 'package:flutter/foundation.dart';

import '../rust/api/client.dart' as core;
import '../rust/api/types.dart';
import 'settings.dart';

/// What happened to a file on its way out, in terms the UI can show.
///
/// Deliberately not a boolean. "Cleaned" and "there was nothing in it" are
/// different facts, and so are "this is not an image" and "this image is
/// damaged" — each leads somewhere different, and collapsing them would mean
/// telling the user something that is not quite true in three cases out of
/// four.
enum CleanState {
  /// Metadata was found and removed.
  cleaned,

  /// A supported image that carried nothing. Screenshots usually do.
  alreadyClean,

  /// Not an image this can rewrite, so nothing was removed from it.
  notAnImage,

  /// A supported format that would not parse — usually a damaged file.
  damaged,

  /// An image, but too big to be loaded and rewritten, so it is sent as it is.
  /// Said separately from [notAnImage], because "this is not an image" would be
  /// untrue and would hide that the protection did not apply.
  tooLarge,

  /// The setting is off, so nothing was attempted.
  notAttempted,
}

/// A file, and what was done to it.
@immutable
class CleanedFile {
  const CleanedFile({
    required this.bytes,
    required this.state,
    this.kind,
    this.removed = const [],
    this.detail,
  });

  /// The bytes to send. The original, unless something was removed.
  final Uint8List bytes;
  final CleanState state;

  /// `JPEG`, `PNG`, `GIF`, `WebP`, or null when it was not recognised.
  final String? kind;

  /// What was taken out, longest first, so the UI can name the largest thing.
  final List<RemovedItem> removed;

  /// Why it would not parse, when [state] is [CleanState.damaged].
  final String? detail;

  int get removedBytes =>
      removed.fold(0, (total, item) => total + item.bytes.toInt());

  /// Whether the user should be told before this is sent.
  ///
  /// True for a file nothing could be removed from, because that is the case
  /// where the protection quietly did not apply. Not true for one that was
  /// cleaned, or for one that had nothing in it to begin with — those are
  /// working as intended and do not need to interrupt anyone.
  bool get carriesUnknownData =>
      state == CleanState.notAnImage ||
      state == CleanState.damaged ||
      state == CleanState.tooLarge ||
      state == CleanState.notAttempted;

  /// One line describing what happened, for a caption under an attachment.
  String describe() => switch (state) {
    CleanState.cleaned =>
      removed.length == 1
          ? 'Removed ${removed.first.what} from this $kind'
          : 'Removed ${removed.length} pieces of metadata from this $kind',
    CleanState.alreadyClean => 'This $kind carried no metadata',
    CleanState.notAnImage =>
      'Not an image ddIRC can clean — it will be sent as it is',
    CleanState.damaged =>
      'This file would not open, so nothing was removed from it',
    CleanState.tooLarge =>
      'Too large for ddIRC to clean — it will be sent as it is',
    CleanState.notAttempted =>
      'Metadata removal is switched off — this will be sent as it is',
  };
}

/// Runs the metadata stripper over outgoing files.
///
/// The stripping itself is Rust, on a worker thread; what lives here is the
/// decision of whether to run it and how to describe the result. That split is
/// deliberate — the policy is the part worth testing, and it can be tested
/// without the native library loaded.
class MediaCleaner {
  MediaCleaner(this.settings, {Future<CleanOutcome> Function(Uint8List)? strip})
    : _strip = strip ?? _viaCore;

  final AppSettings settings;
  final Future<CleanOutcome> Function(Uint8List) _strip;

  static Future<CleanOutcome> _viaCore(Uint8List bytes) =>
      core.cleanMedia(bytes: bytes);

  /// The largest image that is loaded and rewritten.
  ///
  /// The whole file goes into memory, across the FFI boundary and into the
  /// cleaner, and each of those is a copy of it. Photographs are a few
  /// megabytes and this has ample room above them; anything past it is not a
  /// photograph worth opening a gigabyte of memory for, and is sent as it is,
  /// with the confirmation saying so.
  static const maxCleanableBytes = 64 * 1024 * 1024;

  /// How many leading bytes are enough to tell an image from anything else.
  static const headBytes = 16;

  /// Whether the first bytes of a file are one of the image formats the cleaner
  /// rewrites: JPEG, PNG, GIF or WebP.
  ///
  /// By the file's own signature, not its name: a `.jpg` that is something
  /// else should not be handed to an image parser, and a photograph with the
  /// wrong extension should not skip the cleaning.
  static bool looksLikeImage(Uint8List head) {
    bool starts(List<int> signature, [int at = 0]) {
      if (head.length < at + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (head[at + i] != signature[i]) return false;
      }
      return true;
    }

    return starts(const [0xFF, 0xD8, 0xFF]) || // JPEG
        starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) || // PNG
        starts(const [0x47, 0x49, 0x46, 0x38]) || // GIF8
        (starts(const [0x52, 0x49, 0x46, 0x46]) &&
            starts(const [0x57, 0x45, 0x42, 0x50], 8)); // RIFF....WEBP
  }

  /// The answer for a file that does not need to be read at all, or null when
  /// it does.
  ///
  /// Decided from the first few bytes and the length alone, so that attaching a
  /// gigabyte archive costs a stat and sixteen bytes instead of a gigabyte of
  /// memory and a frozen window. The [CleanedFile.bytes] of such an answer are
  /// empty: nothing was loaded, and the file on disk is the file to send.
  CleanedFile? withoutReading({required Uint8List head, required int size}) {
    if (!settings.stripImageMetadata) {
      return CleanedFile(bytes: Uint8List(0), state: CleanState.notAttempted);
    }
    if (!looksLikeImage(head)) {
      return CleanedFile(bytes: Uint8List(0), state: CleanState.notAnImage);
    }
    if (size > maxCleanableBytes) {
      return CleanedFile(bytes: Uint8List(0), state: CleanState.tooLarge);
    }
    return null;
  }

  /// Clean a file, or explain why it was not cleaned.
  ///
  /// Never throws for a file it cannot handle. Refusing to send a document
  /// because it is not a JPEG would be answering a question nobody asked; the
  /// caller is told what happened and decides.
  Future<CleanedFile> prepare(Uint8List bytes) async {
    if (!settings.stripImageMetadata) {
      return CleanedFile(bytes: bytes, state: CleanState.notAttempted);
    }

    final CleanOutcome outcome;
    try {
      outcome = await _strip(bytes);
    } catch (e) {
      // A failure in the stripper must not stop the file being sent, but it
      // must not silently claim to have cleaned it either.
      debugPrint('could not clean media: $e');
      return CleanedFile(bytes: bytes, state: CleanState.damaged, detail: '$e');
    }

    return switch (outcome) {
      CleanOutcome_Cleaned(:final bytes, :final kind, :final removed) =>
        CleanedFile(
          bytes: Uint8List.fromList(bytes),
          state: CleanState.cleaned,
          kind: kind,
          // Largest first: if only one thing can be named, name the one that
          // took up the most room.
          removed: [...removed]..sort((a, b) => b.bytes.compareTo(a.bytes)),
        ),
      CleanOutcome_AlreadyClean(:final kind) => CleanedFile(
        bytes: bytes,
        state: CleanState.alreadyClean,
        kind: kind,
      ),
      CleanOutcome_NotAnImage() => CleanedFile(
        bytes: bytes,
        state: CleanState.notAnImage,
      ),
      CleanOutcome_Malformed(:final detail) => CleanedFile(
        bytes: bytes,
        state: CleanState.damaged,
        detail: detail,
      ),
    };
  }
}
