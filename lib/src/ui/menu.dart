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
  borderRadius: BorderRadius.circular(Tokens.radiusM),
  side: BorderSide(color: t.rule, width: Tokens.hairline),
);

/// One row in a popup menu: an icon, a label, and — for a disabled row — the
/// reason it is disabled.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.note,
    this.enabled = true,
    this.danger = false,
  });

  final IconData icon;
  final String label;

  /// A second line under the label, for saying why a row cannot be used. Kept
  /// off the label itself, where a long reason is cut short by the menu's
  /// width and the part that matters is the part that goes.
  final String? note;

  /// Disabled rows stay in the menu rather than disappearing from it, so the
  /// menu never changes shape between openings.
  final bool enabled;

  /// An action that removes something. Marked in the theme's bad colour so it
  /// is not picked up by accident on the way past.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Disabled is `muted` turned down rather than `faint`: `faint` is for
    // things that are decoration, and a disabled entry still has to be read
    // to learn why it is disabled.
    final dimmed = t.muted.withValues(alpha: 0.65);
    final color = !enabled
        ? dimmed
        : danger
        ? t.bad
        : t.text;
    final iconColor = !enabled
        ? dimmed
        : danger
        ? t.bad
        : t.muted;
    final shownNote = enabled ? null : note;
    return Row(
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 13),
              ),
              if (shownNote != null)
                Text(
                  shownNote,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted, fontSize: 11.5),
                ),
            ],
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
