import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../model/media.dart';
import '../model/transfer.dart';
import '../theme.dart';
import 'motion.dart';

/// What the user is agreeing to before a file leaves the machine.
///
/// Shown every time, and not behind a "do not ask again". Two of the three
/// things on it are facts about *this* file — what was stripped out of it, and
/// how big it is — and the third is the one property of DCC that never stops
/// being true: the offer carries an address, and accepting it means somebody
/// connects to this machine. A dialog that can be turned off is a dialog that
/// stops saying that.
class SendFileSheet extends StatelessWidget {
  const SendFileSheet({
    super.key,
    required this.filename,
    required this.target,
    required this.cleaned,
    required this.sizeBytes,
    this.uploadedTo,
  });

  /// The server a file is uploaded to, when it is sent that way (XMPP) rather
  /// than offered to a person's machine (IRC's DCC). Changes what the sheet
  /// warns about, because the two disclose different things: DCC reveals an
  /// address, an upload hands the file to a server.
  final String? uploadedTo;

  final String filename;

  /// Who it is going to — a nick, or a channel, and the difference matters
  /// enough to be said out loud.
  final String target;

  final CleanedFile cleaned;
  final int sizeBytes;

  /// Returns true if the user chose to send.
  static Future<bool> ask(
    BuildContext context, {
    required String filename,
    required String target,
    required CleanedFile cleaned,
    required int sizeBytes,
    String? uploadedTo,
  }) async {
    final agreed = await showSoftDialog<bool>(
      context: context,
      builder: (context) => SendFileSheet(
        filename: filename,
        target: target,
        cleaned: cleaned,
        sizeBytes: sizeBytes,
        uploadedTo: uploadedTo,
      ),
    );
    return agreed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final toChannel =
        target.startsWith('#') ||
        target.startsWith('&') ||
        target.startsWith('+') ||
        target.startsWith('!');
    final server = uploadedTo;

    return AlertDialog(
      backgroundColor: t.surface,
      title: Text('Send this file?', style: TextStyle(color: t.text)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(
            label: filename,
            detail:
                '${FileTransfer.describeSize(BigInt.from(sizeBytes))} '
                '→ $target',
          ),
          const SizedBox(height: 14),

          // What the metadata stripper did, in its own words. Reported even
          // when it did nothing, because "nothing was removed" and "nothing
          // was attempted" are different facts and only one of them is fine.
          _Note(
            icon: cleaned.carriesUnknownData
                ? Icons.info_outline
                : Icons.check_circle_outline,
            colour: cleaned.carriesUnknownData ? t.warn : t.ok,
            text: cleaned.describe(),
          ),
          const SizedBox(height: 10),

          // The property of DCC that never goes away - and for an upload, its
          // own: the server keeps the file, and anyone with the link has it.
          _Note(
            icon: server != null ? Icons.cloud_upload_outlined : Icons.podcasts,
            colour: t.warn,
            text: server != null
                ? 'This file is uploaded to $server, which keeps it and sends '
                      '$target a link. Anyone who gets the link can download '
                      'it, and it is not encrypted end to end.'
                : toChannel
                ? 'This offer carries your address, and everyone in $target '
                      'will see it. Anyone there can connect to this machine '
                      'to collect the file.'
                : 'This offer carries your address. $target has to connect to '
                      'this machine to collect the file, so they will learn '
                      'it.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: t.muted),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: t.accent,
            foregroundColor: t.onAccent,
          ),
          child: const Text('Send'),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(color: t.text, fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(detail, style: TextStyle(color: t.faint, fontSize: 12)),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.colour, required this.text});

  final IconData icon;
  final Color colour;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: t.muted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// The first few bytes of [file], or as many as it has.
Future<Uint8List> _readHead(File file) async {
  final reader = await file.open();
  try {
    return await reader.read(MediaCleaner.headBytes);
  } finally {
    await reader.close();
  }
}

/// Prepare a picked file for sending.
///
/// Runs the metadata stripper, and — when it actually removed something —
/// writes the cleaned bytes to a temporary file, because the core sends a
/// *path* rather than bytes. That indirection is what keeps a large file out
/// of memory on the way to the socket; the small cost is this copy, and it is
/// only paid for images that had something worth taking out.
///
/// Returns the path to send and what was done, or null if the file could not
/// be read at all.
Future<({String path, CleanedFile cleaned, int size})?> prepareForSending(
  MediaCleaner cleaner,
  String sourcePath,
) async {
  final file = File(sourcePath);
  final int size;
  final Uint8List head;
  try {
    size = await file.length();
    head = await _readHead(file);
  } catch (e) {
    debugPrint('could not read $sourcePath: $e');
    return null;
  }

  // Most files are not photographs, and a file that is not one has nothing to
  // clean and nothing to gain from being read. Decided from the first few bytes
  // so that a large archive is a stat and a sixteen-byte read, not a window
  // that stops responding while gigabytes are copied for a cleaner that was
  // always going to say "not an image".
  final skipped = cleaner.withoutReading(head: head, size: size);
  if (skipped != null) {
    return (path: sourcePath, cleaned: skipped, size: size);
  }

  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (e) {
    debugPrint('could not read $sourcePath: $e');
    return null;
  }

  final cleaned = await cleaner.prepare(bytes);
  if (identical(cleaned.bytes, bytes) || cleaned.removed.isEmpty) {
    // Nothing was taken out, so the file on disk is already the file to send.
    return (path: sourcePath, cleaned: cleaned, size: bytes.length);
  }

  try {
    final directory = await Directory.systemTemp.createTemp('ddirc-send');
    final scrubbed = File(
      '${directory.path}${Platform.pathSeparator}'
      '${sourcePath.split(Platform.pathSeparator).last}',
    );
    await scrubbed.writeAsBytes(cleaned.bytes, flush: true);
    return (path: scrubbed.path, cleaned: cleaned, size: cleaned.bytes.length);
  } catch (e) {
    // Failing to write the cleaned copy must not mean sending the dirty
    // original by accident. Refusing is the only safe answer.
    debugPrint('could not write the cleaned copy: $e');
    return null;
  }
}
