import 'package:flutter/material.dart';

import '../model/notice.dart';
import '../theme.dart';
import 'layout.dart';
import 'motion.dart';

/// What the app has to say, above the composer.
///
/// Replaces a flat red strip that said everything in the same voice at 12px.
/// Three things changed and each earns its place:
///
/// - **A level.** A refused command, a protective refusal and a saved file are
///   not the same news. Painting all three red is how people learn that red
///   means nothing.
/// - **An icon and a tinted rule.** Colour alone carries it for most people and
///   for nobody with a red-green deficiency, which is roughly one man in twelve.
/// - **A way to dismiss it.** The old bar cleared only when the next command
///   was submitted, so a failed transfer sat there until the user typed
///   something, and there was no way to say "yes, I read it".
class NoticeBar extends StatelessWidget {
  const NoticeBar({super.key, required this.notice, required this.onDismiss});

  final Notice notice;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    final (colour, icon) = _style(notice.level, t);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(g, 9, 6, 9),
      decoration: BoxDecoration(
        // A wash rather than a fill: this sits directly above the composer
        // and a saturated band there pulls the eye off what is being typed.
        color: colour.withValues(alpha: 0.10),
        border: Border(
          // The rule is the loud part, and it is on the leading edge where
          // the eye starts rather than under the text where it reads as a
          // divider between two unrelated things.
          left: BorderSide(color: colour, width: 2),
          top: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: colour),
          ),
          const SizedBox(width: 9),
          Expanded(
            // The announcement is one node covering the text and nothing
            // else. Wrapping the whole row would swallow the dismiss button,
            // which a screen reader needs to find on its own; letting the
            // two Texts speak for themselves would read the level out as
            // part of neither.
            child: Semantics(
              liveRegion: true,
              container: true,
              label: _spoken(notice),
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    notice.message,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                  if (notice.detail case final detail?) ...[
                    const SizedBox(height: 3),
                    // Selectable, because a detail is often a path or a reason
                    // worth pasting into a bug report — and a message you have
                    // to retype by hand is one nobody reports.
                    SelectableText(
                      detail,
                      style: TextStyle(
                        color: t.muted,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 15),
            color: t.faint,
            visualDensity: VisualDensity.compact,
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }

  static (Color, IconData) _style(NoticeLevel level, Tokens t) =>
      switch (level) {
        NoticeLevel.error => (t.bad, Icons.error_outline),
        NoticeLevel.warning => (t.warn, Icons.shield_outlined),
        NoticeLevel.info => (t.ok, Icons.check_circle_outline),
      };

  /// What a screen reader says, which has to name the level out loud — the
  /// colour and the icon both being invisible to it.
  static String _spoken(Notice notice) {
    final prefix = switch (notice.level) {
      NoticeLevel.error => 'Error',
      NoticeLevel.warning => 'Warning',
      NoticeLevel.info => 'Notice',
    };
    final detail = notice.detail;
    return detail == null
        ? '$prefix. ${notice.message}'
        : '$prefix. ${notice.message}. $detail';
  }
}

/// The bar, growing and shrinking rather than appearing.
///
/// Wrapped here so every caller gets the same behaviour: a notice arriving
/// must not shove the composer out from under a caret already being typed
/// into, which is what an abrupt insertion above it does.
class NoticeReveal extends StatelessWidget {
  const NoticeReveal({
    super.key,
    required this.notice,
    required this.onDismiss,
  });

  final Notice? notice;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Reveal(
    child: notice == null
        ? null
        : NoticeBar(
            // Keyed on the message, so a second notice replacing a first
            // animates as a change rather than silently swapping its text.
            key: ValueKey(notice!.message),
            notice: notice!,
            onDismiss: onDismiss,
          ),
  );
}
