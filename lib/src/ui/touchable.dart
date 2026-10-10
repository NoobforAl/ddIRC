import 'package:flutter/material.dart';

import 'motion.dart';

/// What the pointer is currently doing to a surface.
enum Touch {
  none,
  hover,
  press;

  /// How strongly to wash the surface, as an alpha on the theme's hover
  /// colour.
  ///
  /// Hover is deliberately weaker than the selection it shares a colour with:
  /// a row the pointer merely happens to be over must never read as the row
  /// the user is actually in. Press goes most of the way there, because on
  /// these surfaces pressing is usually about to make it so.
  double get wash => switch (this) {
    Touch.none => 0,
    Touch.hover => 0.45,
    Touch.press => 0.85,
  };
}

/// A tappable surface that tells its builder what the pointer is doing.
///
/// The theme sets `NoSplash.splashFactory` and a transparent `highlightColor`,
/// so Material's own press feedback is gone on purpose — a ripple is exactly
/// the ornament this design excludes. Nor could it be inherited: every row
/// here paints an opaque background over the Material that the ink would land
/// on, so it would be invisible anyway.
///
/// Feedback therefore has to be part of the row's own decoration, which means
/// the row has to know. [InkWell] stays underneath for gestures, focus and
/// semantics; only the painting moves out.
///
/// The surface also gives a little under a press, and springs back on
/// release. That is the tactile half of what a ripple was for, without
/// the ornament: on a phone, where there is no hover, it is the only sign the
/// finger landed before the thing it pressed responds.
class Touchable extends StatefulWidget {
  const Touchable({
    super.key,
    required this.builder,
    this.onTap,
    this.onSecondaryTap,
    this.onContextMenu,
    this.borderRadius,
  });

  final Widget Function(BuildContext context, Touch touch) builder;

  /// Null disables the surface: it stops reporting hover, so it cannot go on
  /// looking clickable while it is not.
  final VoidCallback? onTap;

  /// Right-click on desktop, with no touch equivalent.
  ///
  /// For a surface that should also answer a long press, use [onContextMenu]
  /// instead — this one is for the rare action that only makes sense with a
  /// pointer.
  final VoidCallback? onSecondaryTap;

  /// Right-click on desktop, long-press on touch: the one gesture that means
  /// "what else can I do with this?".
  ///
  /// Reported with a point in global coordinates for a menu to open at — the
  /// pointer that right-clicked, or the middle of this surface when a finger
  /// long-pressed it, since the finger is covering the spot it pressed.
  final ValueChanged<Offset>? onContextMenu;

  /// Clips the focus and gesture area to a rounded surface, for the callers
  /// whose own decoration is rounded.
  final BorderRadius? borderRadius;

  @override
  State<Touchable> createState() => _TouchableState();
}

class _TouchableState extends State<Touchable> {
  bool _hovered = false;
  bool _pressed = false;

  Touch get _touch {
    if (widget.onTap == null) return Touch.none;
    if (_pressed) return Touch.press;
    return _hovered ? Touch.hover : Touch.none;
  }

  /// How far to sink, measured when the press lands.
  ///
  /// A few pixels at the edges whatever the size, rather than one fraction for
  /// everything: 3% of a full-width row is a lurch, and 3% of a close button is
  /// barely there. Clamped so neither end goes silly.
  double _sink = 1;

  void _press() {
    final box = context.findRenderObject();
    final width = box is RenderBox && box.hasSize ? box.size.width : 0.0;
    _sink = width <= 0 ? 0.97 : (1 - 6 / width).clamp(0.96, 0.99);
    setState(() => _pressed = true);
  }

  /// The middle of this surface, in global coordinates.
  Offset get _centre {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Offset.zero;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.onContextMenu;
    final m = context.motion;
    final inkWell = InkWell(
      onTap: widget.onTap,
      onSecondaryTap: menu == null ? widget.onSecondaryTap : null,
      // On the way up, which is where every desktop opens its context menu,
      // and the only one of the pair that carries a position.
      onSecondaryTapUp: menu == null ? null : (d) => menu(d.globalPosition),
      onLongPress: menu == null ? null : () => menu(_centre),
      borderRadius: widget.borderRadius,
      onHover: (over) => setState(() => _hovered = over),
      onTapDown: (_) => _press(),
      onTapUp: (_) => setState(() => _pressed = false),
      // Sliding off the surface mid-press is a cancelled tap, and the surface
      // has to let go too — otherwise it stays lit under a pointer that is no
      // longer there.
      onTapCancel: () => setState(() => _pressed = false),
      child: widget.builder(context, _touch),
    );
    if (m.disabled) return inkWell;
    return AnimatedScale(
      scale: _touch == Touch.press ? _sink : 1,
      // Sinks at the speed of a colour change and comes back a little slower,
      // the way something springy does.
      duration: _touch == Touch.press ? m.fast : m.normal,
      curve: _touch == Touch.press ? Motion.curve : Curves.easeOutBack,
      child: inkWell,
    );
  }
}
