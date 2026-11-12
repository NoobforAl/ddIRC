import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../model/mcp.dart';
import '../text/visible.dart';
import '../theme.dart';
import 'motion.dart';

/// "An agent wants to send this." Shown for every message an agent asks to
/// send, before anything leaves the app.
///
/// Everything that will happen is on the sheet: which network, which
/// conversation, and the exact text — in full, not summarised, because the
/// point is that the user reads what goes out under their name. The answers
/// are Send once, allow this channel for a day, and Don't send; dismissing the
/// sheet any other way is Don't send.
///
/// An agent may be acting on what a stranger wrote, so the sheet has to hold up
/// against text written to get past it. A long message could put an innocent line
/// in view and the real one below the fold, so the answers that send stay disabled
/// until the end has been on screen, and the sheet says how much there is.
class AgentApprovalSheet extends StatefulWidget {
  const AgentApprovalSheet({super.key, required this.request});

  final McpSendRequest request;

  static Future<McpDecision?> show(
    BuildContext context,
    McpSendRequest request,
  ) => showSoftDialog<McpDecision>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AgentApprovalSheet(request: request),
  );

  @override
  State<AgentApprovalSheet> createState() => _AgentApprovalSheetState();
}

class _AgentApprovalSheetState extends State<AgentApprovalSheet> {
  final _scroll = ScrollController();

  /// Whether the end of the text has been on screen. Stays true once it has:
  /// someone scrolling back up to reread is not someone who has seen less.
  bool _seenEnd = false;

  /// Whether this sheet has already closed itself or been answered.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // The request can end without the sheet: it timed out, the app locked, or the
    // server was switched off. A sheet left up would have a Send that did nothing,
    // while looking as if it had worked.
    //
    // This route by name rather than a pop, which takes whatever is on top, and
    // that may already be the sheet for the next request in the queue.
    unawaited(
      widget.request.decision.then((_) {
        if (!mounted || _closing) return;
        _closing = true;
        final route = ModalRoute.of(context);
        if (route != null) Navigator.of(context).removeRoute(route);
      }),
    );
  }

  void _answer(McpDecision decision) {
    _closing = true;
    Navigator.of(context).pop(decision);
  }

  void _checkEnd() {
    if (_seenEnd || !mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    // A little slack, because a fractional scroll position can stop just short
    // of the end, and nobody can scroll a button into working from there.
    if (position.pixels >= position.maxScrollExtent - 4) {
      setState(() => _seenEnd = true);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final request = widget.request;
    final reply = request.replyTo;
    final conversation = showHidden(request.conversation);
    final lines = '\n'.allMatches(request.text).length + 1;
    final characters = request.text.runes.length;

    // Afterwards, because how far there is to scroll is only known once laid
    // out. A message that fits has nothing to scroll, and so is seen in full.
    if (!_seenEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkEnd());
    }

    return AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusL),
      ),
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
      title: Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 20, color: t.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'An agent wants to send a message',
              style: TextStyle(
                color: t.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const BetaBadge(),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'To $conversation on ${showHidden(request.networkName)}',
              style: TextStyle(color: t.muted, fontSize: 13),
            ),
            if (reply != null) ...[
              const SizedBox(height: 8),
              Text(
                'In reply to ${showHidden(reply.nick)}: '
                '“${showHidden(reply.excerpt)}”',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.muted, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.bubble,
                borderRadius: BorderRadius.circular(Tokens.radiusM),
                border: Border.all(color: t.rule, width: Tokens.hairline),
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) {
                  _checkEnd();
                  return false;
                },
                // Always showing, including on a phone, where a scrollbar is
                // otherwise hidden: it is the sign that there is more below.
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: SelectableText(
                      showHidden(request.text, keepLines: true),
                      style: TextStyle(
                        color: t.text,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '$lines ${lines == 1 ? 'line' : 'lines'} · '
              '$characters ${characters == 1 ? 'character' : 'characters'}',
              style: TextStyle(color: t.muted, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              _seenEnd
                  ? 'Nothing is sent unless you choose Send.'
                  : 'Scroll to the end of the message to send it.',
              style: TextStyle(
                color: _seenEnd ? t.faint : t.warn,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      actions: [
        TextButton(
          onPressed: () => _answer(McpDecision.deny),
          style: TextButton.styleFrom(foregroundColor: t.muted),
          child: const Text("Don't send"),
        ),
        if (request.canAllow)
          TextButton(
            onPressed: _seenEnd ? () => _answer(McpDecision.forADay) : null,
            style: TextButton.styleFrom(foregroundColor: t.accent),
            child: Text('Allow in $conversation for a day'),
          ),
        FilledButton(
          onPressed: _seenEnd ? () => _answer(McpDecision.once) : null,
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
