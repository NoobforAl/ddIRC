import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/session.dart';
import '../theme.dart';
import 'settings/settings_chrome.dart';

/// What the connection has been doing, in full.
///
/// This is where the hostname lookups, the TLS handshakes, the reconnect
/// countdowns and the server's own complaints go now that they are out of the
/// scrollback. They were never conversation; they were an account of the
/// plumbing, filed into whichever channel happened to be on screen when they
/// happened.
///
/// Kept deliberately plain — a timestamp, a line, monospaced, selectable. It is
/// read for two reasons and both want the same thing: working out why a
/// connection will not come up, and pasting the answer into a bug report.
class ConnectionLogDialog extends StatefulWidget {
  const ConnectionLogDialog({super.key, required this.session});

  final SessionModel session;

  static Future<void> show(
    BuildContext context, {
    required SessionModel session,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => ConnectionLogDialog(session: session),
    );
  }

  @override
  State<ConnectionLogDialog> createState() => _ConnectionLogDialogState();
}

class _ConnectionLogDialogState extends State<ConnectionLogDialog> {
  /// Set once the whole log has been put on the clipboard, so the button can
  /// say it worked. Reset on the next line to arrive, because a "Copied"
  /// standing over a log that has since grown is a claim about the wrong thing.
  bool _copied = false;

  SessionModel get session => widget.session;

  @override
  void initState() {
    super.initState();
    // Live: the common case for opening this is a connection that is still
    // failing, and a snapshot would stop updating at exactly the moment the
    // interesting line arrives.
    session.addListener(_onChanged);
  }

  @override
  void dispose() {
    session.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() => _copied = false);
  }

  Future<void> _copyAll() async {
    final text = session.connectionLog
        .map((entry) => '${_stamp(entry.at)}  ${entry.text}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  /// Seconds included, unlike the clock beside a message.
  ///
  /// A conversation does not need them; a connection does — the whole question
  /// this log answers is what happened in what order, and half of that order
  /// falls inside a single minute.
  static String _stamp(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final entries = session.connectionLog;

    return SettingsDialog(
      title: 'Connection log',
      subtitle: '${session.config.host}:${session.config.port}',
      width: 520,
      children: [
        if (entries.isEmpty)
          const SettingsNote(
            text:
                'Nothing yet. This fills in as the connection is attempted — '
                'the address it dialled, the handshake, and whatever the '
                'server had to say about it.',
          )
        else ...[
          for (final entry in entries)
            _LogLine(at: _stamp(entry.at), text: entry.text),
          const SizedBox(height: 6),
          SettingsActions(
            children: [
              SettingsSecondaryButton(
                label: _copied ? 'Copied' : 'Copy all',
                onPressed: _copyAll,
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: Text(
            'Nothing here is written to disk unless debug logging is switched '
            'on in App settings, and message content never reaches it either '
            'way.',
            style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// One line: the time it happened, then what happened.
class _LogLine extends StatelessWidget {
  const _LogLine({required this.at, required this.text});

  final String at;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fixed width and tabular figures, so the times line up into a
          // column and the eye can find the gap where a connection stalled.
          SizedBox(
            width: 58,
            child: Text(
              at,
              style: TextStyle(
                color: t.faint,
                fontSize: 11.5,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontFamily: Fonts.mono,
                fontFamilyFallback: Fonts.monoFallback,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              text,
              style: TextStyle(
                color: t.muted,
                fontSize: 11.5,
                height: 1.45,
                fontFamily: Fonts.mono,
                fontFamilyFallback: Fonts.monoFallback,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
