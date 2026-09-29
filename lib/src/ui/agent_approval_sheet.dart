import 'package:flutter/material.dart';

import '../model/mcp.dart';
import '../theme.dart';
import 'settings/settings_chrome.dart';

/// "An agent wants to send this." Shown for every message an agent asks to
/// send, before anything leaves the app.
///
/// Everything that will happen is on the sheet: which network, which
/// conversation, and the exact text — in full, not summarised, because the
/// point is that the user reads what goes out under their name. The answers
/// are Send once, Always allow here, and Don't send; dismissing the sheet any
/// other way is Don't send.
class AgentApprovalSheet extends StatelessWidget {
  const AgentApprovalSheet({super.key, required this.request});

  final McpSendRequest request;

  static Future<McpDecision?> show(
    BuildContext context,
    McpSendRequest request,
  ) => showDialog<McpDecision>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AgentApprovalSheet(request: request),
  );

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final reply = request.replyTo;
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
              'To ${request.conversation} on ${request.networkName}',
              style: TextStyle(color: t.muted, fontSize: 13),
            ),
            if (reply != null) ...[
              const SizedBox(height: 8),
              Text(
                'In reply to ${reply.nick}: “${reply.excerpt}”',
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
              child: SingleChildScrollView(
                child: SelectableText(
                  request.text,
                  style: TextStyle(color: t.text, fontSize: 14, height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Nothing is sent unless you choose Send.',
              style: TextStyle(color: t.faint, fontSize: 12),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(McpDecision.deny),
          style: TextButton.styleFrom(foregroundColor: t.muted),
          child: const Text("Don't send"),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(McpDecision.always),
          style: TextButton.styleFrom(foregroundColor: t.accent),
          child: Text('Always allow in ${request.conversation}'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(McpDecision.once),
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
