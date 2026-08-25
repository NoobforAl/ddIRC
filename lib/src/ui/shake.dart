import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// Nudges its child sideways whenever [tick] changes.
///
/// A field that is wrong should say so where the user is looking — at the
/// field — rather than in a note somewhere else on the screen. The motion is a
/// damped oscillation over [Motion.slow]: enough to catch the eye, short
/// enough that it never delays a retry.
///
/// With "reduce motion" on it does not shake at all. That leaves the red
/// border and the message under the field carrying the news on their own,
/// which is the point — a shake is an amplifier, never the only signal.
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

  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didUpdateWidget(Shake old) {
    super.didUpdateWidget(old);
    if (widget.tick == old.tick) return;
    // Read at the moment of the shake rather than once at construction, so a
    // change to the accessibility setting takes effect on the next error
    // instead of on the next restart.
    final m = context.motion;
    if (m.disabled) return;
    _controller
      ..duration = m.slow
      ..forward(from: 0);
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
