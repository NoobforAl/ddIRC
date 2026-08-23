import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Nudges its child sideways whenever [tick] changes.
///
/// A field that is wrong should say so where the user is looking — at the
/// field — rather than in a note somewhere else on the screen. The motion is a
/// damped oscillation over a fifth of a second: enough to catch the eye,
/// short enough that it never delays a retry.
class Shake extends StatefulWidget {
  const Shake({super.key, required this.tick, required this.child});

  /// Increment this to shake. Any change triggers one run.
  final int tick;
  final Widget child;

  @override
  State<Shake> createState() => _ShakeState();
}

class _ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  static const _amplitude = 7.0;
  static const _cycles = 3;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void didUpdateWidget(Shake old) {
    super.didUpdateWidget(old);
    if (widget.tick != old.tick) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      // The child is built once and reused: a text field must keep its state
      // and its caret through the animation.
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        // Decaying so it settles exactly where it started, with no snap back.
        final offset =
            math.sin(t * _cycles * 2 * math.pi) * _amplitude * (1 - t);
        return Transform.translate(offset: Offset(offset, 0), child: child);
      },
    );
  }
}

/// Disables Flutter's own error decoration in favour of ours.
///
/// Material grows the field when it shows an error, which makes the whole form
/// jump. We colour the existing border and put the message underneath instead,
/// so nothing moves except the shake.
InputBorder outlinedBorder(Color color, double width) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(7),
  borderSide: BorderSide(color: color, width: width),
);
