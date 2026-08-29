import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared chrome for the app's popup menus.
///
/// There are two of them now — the settings menu in the session header and the
/// context menu on a network — and a menu that is drawn twice is a menu that
/// drifts. Everything about how one looks lives here; the callers only say
/// what is in it.

/// The border a menu is cut out with: a hairline on the panel colour, no
/// shadow. The same hairline language as every other surface.
ShapeBorder menuShape(Tokens t) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(8),
  side: BorderSide(color: t.rule, width: Tokens.hairline),
);

/// One row in a popup menu: an icon, a label, and nothing else.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.enabled = true,
    this.danger = false,
  });

  final IconData icon;
  final String label;

  /// Disabled rows stay in the menu rather than disappearing from it, so the
  /// menu never changes shape between openings.
  final bool enabled;

  /// An action that removes something. Marked in the theme's bad colour so it
  /// is not picked up by accident on the way past.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = !enabled
        ? t.faint
        : danger
        ? t.bad
        : t.text;
    final iconColor = !enabled
        ? t.faint
        : danger
        ? t.bad
        : t.muted;
    return Row(
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// Open a menu at a point on the screen.
///
/// The point comes from the gesture that asked for it: the pointer that
/// right-clicked, or the middle of the row that was long-pressed — a finger
/// covers what it is pressing, so anchoring to the touch would put the menu
/// under the hand that opened it.
Future<T?> showPointerMenu<T>(
  BuildContext context, {
  required Offset at,
  required List<PopupMenuEntry<T>> items,
}) {
  final t = context.tokens;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<T>(
    context: context,
    color: t.surface,
    elevation: 0,
    shape: menuShape(t),
    position: RelativeRect.fromRect(
      Rect.fromPoints(at, at),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}
