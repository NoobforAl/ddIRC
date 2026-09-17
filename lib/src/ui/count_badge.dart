import 'package:flutter/material.dart';

import '../theme.dart';

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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: highlighted ? t.accent : t.badge,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: highlighted ? t.onAccent : t.text,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
