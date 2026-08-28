import 'package:flutter/material.dart';

import '../model/session.dart';
import '../model/transfer.dart';
import '../theme.dart';
import 'layout.dart';

/// Offers waiting for an answer, and transfers in flight.
///
/// Sits between the scrollback and the composer, in the same place a topic bar
/// sits above it: attached to the conversation, not floating over it, and out
/// of the way of the text. Nothing here is in the scrollback, because a row
/// with a moving percentage and a cancel button is not a record of what was
/// said — the outcome becomes a line once it stops changing.
class TransferBar extends StatelessWidget {
  const TransferBar({
    super.key,
    required this.session,
    required this.conversation,
    required this.onAccept,
  });

  final SessionModel session;
  final Conversation conversation;

  /// Accepting has to choose somewhere to put the file, which needs a
  /// directory and a `BuildContext`, so it is the screen's job rather than
  /// this widget's.
  final void Function(FileTransfer) onAccept;

  @override
  Widget build(BuildContext context) {
    final transfers = conversation.transfers;
    if (transfers.isEmpty) return const SizedBox.shrink();

    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          top: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final transfer in transfers)
            _TransferRow(
              // Keyed by id: a transfer finishing removes its row, and without
              // this the row below would inherit its progress mid-animation.
              key: ValueKey(transfer.id),
              transfer: transfer,
              // A reverse offer asks us to listen, and listening tells the
              // sender where we are — which the core refuses behind a proxy.
              // Withholding the button is better than offering one whose only
              // possible outcome is a refusal ten milliseconds later.
              refusable: transfer.isReverse && session.usesProxy,
              onAccept: () => onAccept(transfer),
              onCancel: () => session.cancelTransfer(transfer.id),
            ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    super.key,
    required this.transfer,
    required this.refusable,
    required this.onAccept,
    required this.onCancel,
  });

  /// True when accepting is impossible on this connection, so the button is
  /// withheld and the row says why instead.
  final bool refusable;

  final FileTransfer transfer;
  final VoidCallback onAccept;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    final offered = transfer.stage == TransferStage.offered;

    return Padding(
      padding: EdgeInsets.fromLTRB(g, 8, 8, 8),
      child: Row(
        children: [
          Icon(
            offered
                ? Icons.download_outlined
                : (transfer.incoming
                      ? Icons.arrow_downward
                      : Icons.arrow_upward),
            size: 16,
            color: t.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  transfer.filename,
                  style: TextStyle(color: t.text, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  refusable ? _cannotAccept : _subtitle(transfer),
                  style: TextStyle(
                    color: refusable ? t.warn : t.faint,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (!offered) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      // Null is indeterminate, which is the honest rendering
                      // for a sender who did not say how big the file is.
                      value: transfer.fraction,
                      minHeight: 3,
                      backgroundColor: t.rule,
                      color: t.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (offered && !refusable)
            TextButton(
              onPressed: onAccept,
              style: TextButton.styleFrom(foregroundColor: t.accent),
              child: const Text('Accept'),
            ),
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(foregroundColor: t.muted),
            child: Text(offered ? 'Decline' : 'Cancel'),
          ),
        ],
      ),
    );
  }

  /// Why an offer cannot be taken up on this connection.
  ///
  /// Said on the row rather than left for the error bar, because this is not a
  /// failure to report after the fact — it is a fact about the offer, knowable
  /// the moment it arrives.
  static const _cannotAccept =
      'Cannot accept through a proxy — it would reveal your address';

  /// The line under the filename, which answers a different question depending
  /// on whether there is a decision still to make.
  static String _subtitle(FileTransfer transfer) {
    if (transfer.stage == TransferStage.offered) {
      final from = transfer.from ?? 'someone';
      final size = FileTransfer.describeSize(transfer.total);
      // The size is the sender's claim and is labelled as one. Nothing has
      // verified it, and a transfer that turns out to be ten times larger
      // should not be able to say it was never flagged.
      return '$from says it is $size';
    }
    final done = FileTransfer.describeSize(transfer.transferred);
    final total = FileTransfer.describeSize(transfer.total);
    final direction = transfer.incoming ? 'receiving' : 'sending';
    return transfer.total == null
        ? '$direction — $done so far'
        : '$direction — $done of $total';
  }
}
