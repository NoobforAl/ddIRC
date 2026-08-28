// A file moving, or an offer waiting to be answered.
//
// Deliberately not a chat line. A transfer changes — it has a percentage that
// moves and a button that stops it — and the scrollback is a record of things
// that were said, which do not. So a live transfer is a row of its own above
// the composer, and only its *outcome* becomes a line in the conversation,
// where it belongs and where it will still make sense a week later.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where a transfer has got to.
enum TransferStage {
  /// Someone has offered a file and nobody has answered yet. The only stage
  /// where nothing has been sent to the other side at all.
  offered,

  /// The connection is up and bytes are moving.
  running,
}

/// One offer, or one transfer in flight.
class FileTransfer {
  FileTransfer.offered({
    required this.id,
    required this.filename,
    required this.from,
    required this.total,
    required this.isReverse,
  }) : stage = TransferStage.offered,
       incoming = true,
       transferred = BigInt.zero;

  FileTransfer.running({
    required this.id,
    required this.filename,
    required this.incoming,
    required this.total,
  }) : stage = TransferStage.running,
       from = null,
       isReverse = false,
       transferred = BigInt.zero;

  final BigInt id;
  final String filename;

  /// True when the file is arriving. An offer is always incoming — an outgoing
  /// one is not offered to us, it is made by us.
  final bool incoming;

  /// Who offered it, for an offer. Null once it is running, because by then
  /// the row is about the file rather than about the decision.
  final String? from;

  /// What the sender claims, which for an outgoing transfer is a fact read off
  /// the disk. Null when an old client omitted it, which is allowed.
  final BigInt? total;

  /// Whether accepting would mean listening for them rather than dialling
  /// them — which is the case the core refuses behind a proxy, because
  /// listening means telling them where you are.
  final bool isReverse;

  TransferStage stage;
  BigInt transferred;

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

  /// The line that goes into the scrollback once this is over.
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

/// Where a received file is written.
///
/// Inside the app's own support directory, beside the logs, and deliberately
/// *not* the system Downloads folder. A file arriving over DCC was chosen by
/// somebody else, and putting it where the user's own downloads live — among
/// things they trust because they fetched them — is how one gets opened by
/// mistake. On Android the difference is larger still: shared storage is
/// readable by anything holding the storage permission, and app-private
/// storage is not.
///
/// Created on demand, so a user who never accepts a file never gets a stray
/// folder.
Future<Directory> receivedFilesDirectory() async {
  final base = await getApplicationSupportDirectory();
  final directory = Directory('${base.path}${Platform.pathSeparator}received');
  await directory.create(recursive: true);
  return directory;
}
