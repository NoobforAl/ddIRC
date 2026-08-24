import 'package:flutter/material.dart';

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
class Touchable extends StatefulWidget {
  const Touchable({
    super.key,
    required this.builder,
    this.onTap,
    this.onSecondaryTap,
    this.onLongPress,
    this.borderRadius,
  });

  final Widget Function(BuildContext context, Touch touch) builder;

  /// Null disables the surface: it stops reporting hover, so it cannot go on
  /// looking clickable while it is not.
  final VoidCallback? onTap;

  /// Right-click on desktop, and its long-press equivalent on touch.
  final VoidCallback? onSecondaryTap;
  final VoidCallback? onLongPress;

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

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      onSecondaryTap: widget.onSecondaryTap,
      onLongPress: widget.onLongPress,
      borderRadius: widget.borderRadius,
      onHover: (over) => setState(() => _hovered = over),
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      // Sliding off the surface mid-press is a cancelled tap, and the surface
      // has to let go too — otherwise it stays lit under a pointer that is no
      // longer there.
      onTapCancel: () => setState(() => _pressed = false),
      child: widget.builder(context, _touch),
    );
  }
}
