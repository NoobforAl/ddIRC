import 'package:flutter/material.dart';

import '../theme.dart';
import 'motion.dart';

/// An unread count in a pill: on a channel row, and on the jump-to-latest
/// button when messages arrive below the reader.
///
/// One widget for both so they can never drift apart. Highlighted means a
/// mention is among them, which is worth interrupting for in a way ambient
/// chatter is not.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.highlighted = false});

  final int count;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    final label = count > 99 ? '99+' : '$count';
    final text = Text(
      label,
      key: ValueKey(label),
      style: TextStyle(
        color: highlighted ? t.onAccent : t.text,
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return AnimatedContainer(
      duration: m.fast,
      curve: Motion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: highlighted ? t.accent : t.badge,
        borderRadius: BorderRadius.circular(Tokens.pill),
      ),
      // The number rolls rather than swaps: the new one rises into the pill
      // as the old one drops out. A count that changes in place with no
      // motion is easy to miss, and this is the whole of what it is for.
      //
      // Not with motion off, and not merely because it would be pointless: a
      // zero-duration AnimatedSize trips an assertion — see [Reveal].
      child: m.disabled
          ? text
          : ClipRect(
              child: AnimatedSize(
                duration: m.normal,
                curve: Motion.curve,
                child: AnimatedSwitcher(
                  duration: m.normal,
                  switchInCurve: Motion.curve,
                  switchOutCurve: Motion.exit,
                  transitionBuilder: _roll,
                  child: text,
                ),
              ),
            ),
    );
  }

  static Widget _roll(Widget child, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.6),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }
}
