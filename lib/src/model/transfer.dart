// A file moving, or an offer waiting to be answered — and, once it is over,
// the record of what became of it.
//
// A transfer lives *in the conversation*, as a message of its own, the way a
// file does in a messenger: the same card is the offer you accept, the progress
// you watch, and the file you find afterwards. It is a [ChangeNotifier] because
// it changes while you look at it — a percentage that moves, a button that
// becomes a different button — and the card listening to it is the only thing
// that has to rebuild, not the scrollback around it.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Where a transfer has got to.
enum TransferStage {
  /// Someone has offered a file and nobody has answered yet. The only stage
  /// where nothing has been sent to the other side at all.
  offered,

  /// The connection is up and bytes are moving.
  running,

  /// It arrived (or, for one we sent, it was taken).
  done,

  /// It stopped for a reason that is not the user's own choice.
  failed,

  /// An offer turned down. Nothing was sent to whoever made it.
  declined,

  /// Stopped by the user part-way through.
  cancelled,
}

/// One offer, one transfer in flight, or one that has finished.
class FileTransfer extends ChangeNotifier {
  FileTransfer.offered({
    required this.id,
    required this.filename,
    required String this.from,
    required this.total,
    required this.isReverse,
  }) : _stage = TransferStage.offered,
       incoming = true;

  FileTransfer.running({
    required this.id,
    required this.filename,
    required this.incoming,
    required this.total,
  }) : _stage = TransferStage.running,
       from = null,
       isReverse = false;

  final BigInt id;
  final String filename;

  /// True when the file is arriving. An offer is always incoming — an outgoing
  /// one is not offered to us, it is made by us.
  final bool incoming;

  /// Who offered it, for an offer. Null for one we sent: the card is about the
  /// file then, not about whose decision it was.
  final String? from;

  /// What the sender claims, which for an outgoing transfer is a fact read off
  /// the disk. Null when an old client omitted it, which is allowed.
  BigInt? total;

  /// Whether accepting would mean listening for them rather than dialling
  /// them — which is the case the core refuses behind a proxy, because
  /// listening means telling them where you are.
  final bool isReverse;

  TransferStage _stage;
  TransferStage get stage => _stage;

  BigInt _transferred = BigInt.zero;
  BigInt get transferred => _transferred;
  set transferred(BigInt value) {
    if (value == _transferred) return;
    _transferred = value;
    notifyListeners();
  }

  /// Where a received file was written, once it has been.
  String? path;

  /// Why it stopped, when it stopped badly.
  String? error;

  /// Whether nothing more will happen to it.
  bool get isOver =>
      _stage == TransferStage.done ||
      _stage == TransferStage.failed ||
      _stage == TransferStage.declined ||
      _stage == TransferStage.cancelled;

  /// An offer became a transfer: the connection is up. [size] replaces the
  /// sender's claim with what the core found, when it says.
  void begin({BigInt? size}) {
    if (size != null) total = size;
    _stage = TransferStage.running;
    notifyListeners();
  }

  /// It is over. A [error] of `cancelled` is the user's own doing and is not
  /// reported as a failure.
  void finish({String? path, String? error}) {
    this.path = path;
    this.error = error;
    if (error == null) {
      _stage = TransferStage.done;
      // Whatever the sender claimed, what arrived is what there is.
      if (incoming && total == null) total = _transferred;
    } else if (error == cancelledError) {
      _stage = TransferStage.cancelled;
    } else {
      _stage = TransferStage.failed;
    }
    notifyListeners();
  }

  /// An offer turned down.
  void decline() {
    _stage = TransferStage.declined;
    notifyListeners();
  }

  /// What the core says when the user stopped a transfer.
  static const cancelledError = 'cancelled';

  /// How far along, from 0 to 1, or null when the size is unknown.
  ///
  /// Clamped, because the total is the sender's claim and a sender who
  /// understated it would otherwise drive a progress bar past its end.
  double? get fraction {
    final size = total;
    if (size == null || size <= BigInt.zero) return null;
    final done = transferred / size;
    return done.clamp(0.0, 1.0);
  }

  /// A plain sentence about it, for anything that reads a conversation as text
  /// — search, a copy of the scrollback, an agent — and so never sees the card.
  String get summary {
    final size = total == null ? '' : ' (${describeSize(total)})';
    return switch (_stage) {
      TransferStage.offered =>
        '${from ?? 'someone'} offered you "$filename"'
            '${total == null ? '' : ', says it is ${describeSize(total)}'}',
      TransferStage.running =>
        '${incoming ? 'receiving' : 'sending'} "$filename"$size',
      TransferStage.done => describeOutcome(
        filename: filename,
        path: incoming ? path : null,
        error: null,
      ),
      TransferStage.failed => describeOutcome(
        filename: filename,
        path: null,
        error: error ?? 'it did not complete',
      ),
      TransferStage.declined => 'you declined "$filename"',
      TransferStage.cancelled => 'cancelled "$filename"',
    };
  }

  /// Bytes, in the largest unit that leaves a number worth reading.
  static String describeSize(BigInt? bytes) {
    if (bytes == null) return 'unknown size';
    final n = bytes.toDouble();
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    return switch (n) {
      < kb => '$bytes B',
      < mb => '${(n / kb).toStringAsFixed(0)} KB',
      < gb => '${(n / mb).toStringAsFixed(1)} MB',
      _ => '${(n / gb).toStringAsFixed(1)} GB',
    };
  }

  /// The line that says how it ended.
  ///
  /// Says where a received file went, because a download the user cannot find
  /// is a download that did not happen.
  static String describeOutcome({
    required String filename,
    required String? path,
    required String? error,
  }) {
    if (error != null) return 'transfer of "$filename" failed: $error';
    if (path != null) return 'saved "$filename" to $path';
    return 'sent "$filename"';
  }
}

/// The folder a received file goes into, named for the app so it is a place of
/// its own among the user's downloads rather than loose in them.
const receivedFolderName = 'ddIRC';

/// Where a received file is written.
///
/// **On a computer**, a folder called `ddIRC` inside the user's Downloads, where
/// a person looks for something that arrived. It is a folder of its own on
/// purpose: a file somebody else chose is kept apart from the ones the user
/// fetched themselves, and the app never opens anything it puts there — see
/// [revealInFileManager].
///
/// **On a phone**, the app's own private storage. Android's shared storage is
/// readable by anything holding the storage permission, and iOS has no shared
/// Downloads to put a file in; private storage is where a messenger keeps what
/// it receives, and nothing else can read it.
///
/// If a computer will not say where Downloads is, the app's own directory is
/// used instead, rather than failing a transfer over where to put it. Created
/// on demand, so a user who never accepts a file never gets a stray folder.
///
/// The three directories are parameters so a test can say where they are; the
/// app passes none.
Future<Directory> receivedFilesDirectory({
  TargetPlatform? platform,
  Future<Directory?> Function()? downloads,
  Future<Directory> Function()? support,
}) async {
  final target = platform ?? defaultTargetPlatform;
  if (_isDesktop(target)) {
    try {
      final base = await (downloads ?? getDownloadsDirectory)();
      if (base != null) {
        final directory = Directory(
          '${base.path}${Platform.pathSeparator}$receivedFolderName',
        );
        await directory.create(recursive: true);
        return directory;
      }
    } catch (_) {
      // Fall through to the app's own directory.
    }
  }
  final base = await (support ?? getApplicationSupportDirectory)();
  final directory = Directory('${base.path}${Platform.pathSeparator}received');
  await directory.create(recursive: true);
  return directory;
}

bool _isDesktop(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => !kIsWeb,
  _ => false,
};

/// Where a received file goes, for the settings screen, in words.
String receivedFilesWhere({TargetPlatform? platform}) =>
    _isDesktop(platform ?? defaultTargetPlatform)
    ? 'Saved in a "$receivedFolderName" folder inside your Downloads'
    : 'Kept in ddIRC\'s private storage, out of reach of other apps';

/// Whether a computer's file manager can be asked to show a file.
bool get canRevealFiles => _isDesktop(defaultTargetPlatform);

/// Where [path] is, in words a person would say: `Downloads\ddIRC` rather than
/// a full path that scrolls off the card.
String describeLocation(String path, {String? separator}) {
  final sep = separator ?? Platform.pathSeparator;
  final parts = path.split(RegExp(r'[\\/]'))..removeWhere((p) => p.isEmpty);
  if (parts.length < 2) return path;
  final folder = parts[parts.length - 2];
  if (folder == receivedFolderName && parts.length >= 3) {
    return '${parts[parts.length - 3]}$sep$folder';
  }
  if (folder == 'received') return 'private storage';
  return folder;
}

/// Show [path] in the system's file manager, selected — and nothing more.
///
/// Deliberately *not* "open it". A file somebody else chose to send is the
/// thing most likely to be something that runs, and a single tap on a message
/// should never be the way it does. Showing it puts it where the user can
/// decide, with the system's own warnings, what to do next.
///
/// Returns false when there is no file manager to ask (a phone) or it would not
/// start.
Future<bool> revealInFileManager(String path) async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        // The comma is part of the switch, and the path is its own argument so
        // a space in it does not split it.
        await Process.run('explorer.exe', ['/select,', path]);
        return true;
      case TargetPlatform.macOS:
        await Process.run('open', ['-R', path]);
        return true;
      case TargetPlatform.linux:
        await Process.run('xdg-open', [File(path).parent.path]);
        return true;
      default:
        return false;
    }
  } catch (_) {
    return false;
  }
}
