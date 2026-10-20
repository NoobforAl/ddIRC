import 'package:flutter/material.dart';

import '../model/settings.dart';
import '../model/transfer.dart';
import '../theme.dart';
import 'layout.dart';

/// A file in the conversation, drawn the way a messenger draws one.
///
/// A round button on the left that is the whole interaction: an arrow while
/// there is something to download, a ring that fills with a cross in it while it
/// comes down, and the file's own icon once it is here. Beside it the name and,
/// underneath, whatever is true of it right now — how big it is claimed to be,
/// how far it has got, where it ended up.
///
/// This is the one place a file is accepted. It used to be a bar between the
/// scrollback and the composer, which meant a file arriving put a prompt where
/// the message box should be; now it is a message like any other and the
/// composer stays a composer.
///
/// It listens to its [transfer], so a moving percentage repaints this card and
/// nothing around it.
class FileMessage extends StatelessWidget {
  const FileMessage({
    super.key,
    required this.transfer,
    required this.at,
    required this.settings,
    required this.showSender,
    required this.onAccept,
    required this.onCancel,
    this.blockedReason,
    this.onReveal,
  });

  final FileTransfer transfer;
  final DateTime at;
  final AppSettings settings;

  /// Whether to name who offered it above the card — in a channel, where it is
  /// not obvious, and not in a private conversation, where it is.
  final bool showSender;

  final VoidCallback onAccept;
  final VoidCallback onCancel;

  /// Why this offer cannot be taken up at all, when it cannot: through a proxy,
  /// or from somebody who has not yet been let in. Said on the card instead of
  /// offering a button whose only outcome is a refusal.
  final String? blockedReason;

  /// Show the received file to the person, where there is a file manager to
  /// show it in. Null where there is not.
  final VoidCallback? onReveal;

  static const _maxWidth = 340.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gutter = context.layout.gutter;

    return ListenableBuilder(
      listenable: transfer,
      builder: (context, _) {
        final mine = !transfer.incoming;
        const big = Radius.circular(Tokens.radiusL);
        const tail = Radius.circular(4);
        final radius = mine
            ? const BorderRadius.only(
                topLeft: big,
                bottomLeft: big,
                topRight: big,
                bottomRight: tail,
              )
            : const BorderRadius.only(
                topLeft: big,
                bottomLeft: tail,
                topRight: big,
                bottomRight: big,
              );

        final offered = transfer.stage == TransferStage.offered;
        final blocked = offered ? blockedReason : null;
        final timeStyle = TextStyle(
          color: t.muted,
          fontSize: 10.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        );

        final card = Container(
          decoration: BoxDecoration(
            color: mine ? t.own : t.bubble,
            borderRadius: radius,
          ),
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSender && transfer.from != null)
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 6),
                  child: Text(
                    transfer.from!,
                    style: TextStyle(
                      color: t.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _RoundButton(
                    transfer: transfer,
                    blocked: blocked != null,
                    onAccept: onAccept,
                    onCancel: onCancel,
                    onReveal: onReveal,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          transfer.filename,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.text,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          blocked ?? _subtitle(transfer),
                          style: TextStyle(
                            color: blocked != null
                                ? t.warn
                                : _isProblem(transfer)
                                ? t.bad
                                : t.muted,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Declining is a thing to be able to do, and there is no
                    // way to say it with a round button that downloads. Small
                    // and plain, beside the time, where it is findable and not
                    // an invitation.
                    if (offered && blocked == null)
                      TextButton(
                        onPressed: onCancel,
                        style: TextButton.styleFrom(
                          foregroundColor: t.muted,
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('Decline'),
                      ),
                    if (offered && blocked != null)
                      TextButton(
                        onPressed: onCancel,
                        style: TextButton.styleFrom(
                          foregroundColor: t.muted,
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('Dismiss'),
                      ),
                    const Spacer(),
                    if (settings.showTimestamps)
                      Text(settings.formatTime(at), style: timeStyle),
                  ],
                ),
              ),
            ],
          ),
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth * 0.8).clamp(0.0, _maxWidth);
              return Row(
                mainAxisAlignment: mine
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                children: [
                  // A file is not text, so it is not part of a selection: a
                  // drag across the conversation takes what was said and not
                  // the name of a download.
                  SelectionContainer.disabled(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: width,
                        minWidth: width < 240 ? width : 240,
                      ),
                      child: card,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  static bool _isProblem(FileTransfer transfer) =>
      transfer.stage == TransferStage.failed;

  /// The line under the name: what is true of the file at this moment.
  static String _subtitle(FileTransfer transfer) {
    switch (transfer.stage) {
      case TransferStage.offered:
        // The size is the sender's claim, and is written as one. Nothing has
        // verified it, and a download that turns out ten times larger should
        // not be able to say it was never flagged.
        final from = transfer.from ?? 'they';
        final claim = transfer.total == null
            ? '$from did not say how big it is'
            : '$from says ${FileTransfer.describeSize(transfer.total)}';
        // An earlier attempt left part of it here, so pressing the button
        // carries on instead of starting over. Said before the press, because
        // it changes what the press does.
        final have = transfer.resumeFrom;
        return have == null
            ? claim
            : '$claim · ${FileTransfer.describeSize(have)} already here';
      case TransferStage.running:
        // A file we are sending sits at nothing until the other side connects.
        // "0 B / 3.0 MB" reads as stuck; this says what it is actually doing.
        if (!transfer.incoming && transfer.transferred == BigInt.zero) {
          return 'Waiting for them to accept · '
              '${FileTransfer.describeSize(transfer.total)}';
        }
        final done = FileTransfer.describeSize(transfer.transferred);
        return transfer.total == null
            ? done
            : '$done / ${FileTransfer.describeSize(transfer.total)}';
      case TransferStage.done:
        final size = FileTransfer.describeSize(
          transfer.total ?? transfer.transferred,
        );
        if (!transfer.incoming) return '$size · Sent';
        final path = transfer.path;
        return path == null ? size : '$size · ${describeLocation(path)}';
      case TransferStage.failed:
        final reason = transfer.error ?? 'It did not complete';
        final kept = transfer.kept;
        // What arrived is still on disk, and the way to finish it is for the
        // sender to offer the file again — which the card then says carries on.
        return kept == null
            ? reason
            : '$reason · ${FileTransfer.describeSize(kept)} kept. '
                  'Ask them to send it again to carry on.';
      case TransferStage.declined:
        return 'Declined';
      case TransferStage.cancelled:
        return 'Cancelled';
    }
  }
}

/// The round button: the only control, and it changes with the file.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.transfer,
    required this.blocked,
    required this.onAccept,
    required this.onCancel,
    required this.onReveal,
  });

  final FileTransfer transfer;
  final bool blocked;
  final VoidCallback onAccept;
  final VoidCallback onCancel;
  final VoidCallback? onReveal;

  static const _size = 48.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final stage = transfer.stage;

    final Color fill;
    final Widget glyph;
    final VoidCallback? onTap;
    final String label;

    switch (stage) {
      case TransferStage.offered:
        fill = blocked ? t.rule : t.accent;
        glyph = Icon(
          Icons.arrow_downward_rounded,
          color: blocked ? t.faint : t.onAccent,
          size: 24,
        );
        onTap = blocked ? null : onAccept;
        label = transfer.resumeFrom == null
            ? 'Download ${transfer.filename}'
            : 'Resume download of ${transfer.filename}';
      case TransferStage.running:
        fill = t.accent;
        glyph = Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: _size - 8,
              height: _size - 8,
              child: CircularProgressIndicator(
                // Null spins, which is the honest drawing for a sender who did
                // not say how big the file is.
                value: transfer.fraction,
                strokeWidth: 2.5,
                color: t.onAccent,
                backgroundColor: t.onAccent.withValues(alpha: 0.28),
              ),
            ),
            Icon(Icons.close_rounded, color: t.onAccent, size: 20),
          ],
        );
        onTap = onCancel;
        label = 'Cancel ${transfer.filename}';
      case TransferStage.done:
        fill = t.accent.withValues(alpha: 0.16);
        glyph = Icon(_iconFor(transfer.filename), color: t.accent, size: 24);
        onTap = transfer.incoming ? onReveal : null;
        label = onTap == null
            ? transfer.filename
            : 'Show ${transfer.filename} in its folder';
      case TransferStage.failed:
        fill = t.bad.withValues(alpha: 0.14);
        glyph = Icon(Icons.error_outline_rounded, color: t.bad, size: 24);
        onTap = null;
        label = '${transfer.filename} failed';
      case TransferStage.declined:
      case TransferStage.cancelled:
        fill = t.rule;
        glyph = Icon(Icons.block_rounded, color: t.faint, size: 22);
        onTap = null;
        label = transfer.filename;
    }

    final button = Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        child: KeyedSubtree(key: ValueKey(stage), child: glyph),
      ),
    );

    return Semantics(
      // Its own node. Without it a screen reader finds the button folded into
      // the row around it, as one unlabelled thing to press, instead of a
      // button that says what it will do.
      container: true,
      button: onTap != null,
      label: label,
      excludeSemantics: true,
      child: onTap == null
          ? button
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: button,
              ),
            ),
    );
  }

  /// The icon for what the file is, by its extension — enough to tell a photo
  /// from an archive at a glance, which is all a glance is for.
  static IconData _iconFor(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'bmp' ||
      'heic' ||
      'svg' => Icons.image_outlined,
      'mp4' || 'mkv' || 'mov' || 'avi' || 'webm' => Icons.movie_outlined,
      'mp3' ||
      'ogg' ||
      'opus' ||
      'wav' ||
      'flac' ||
      'm4a' => Icons.audiotrack_outlined,
      'zip' ||
      'rar' ||
      '7z' ||
      'tar' ||
      'gz' ||
      'xz' ||
      'bz2' => Icons.folder_zip_outlined,
      'pdf' ||
      'doc' ||
      'docx' ||
      'odt' ||
      'txt' ||
      'md' ||
      'rtf' => Icons.description_outlined,
      'apk' || 'exe' || 'msi' || 'dmg' || 'deb' => Icons.apps_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}
