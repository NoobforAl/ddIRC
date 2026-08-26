import 'package:flutter/material.dart';

/// Motion tokens, and the few widgets that need more than a duration.
///
/// Three durations and two curves, narrow for the same reason the palette
/// has one accent and three status colours: a small named set that every
/// widget draws from is what makes a hundred transitions read as one app
/// rather than a hundred separate decisions.
///
/// Nothing here animates for decoration. Motion answers one question — *what
/// just changed, and where did it go* — so every duration is short enough to
/// finish before the next click, and none of it ever delays input.
///
/// Read it as `context.motion`, never as a constant. The getter returns zero
/// durations when the platform's "reduce motion" accessibility setting is on,
/// so honouring that is automatic instead of something each call site has to
/// remember.
@immutable
class Motion {
  const Motion._({
    required this.fast,
    required this.normal,
    required this.slow,
  });

  /// A colour changing in place: a status dot, a hover tint.
  final Duration fast;

  /// The default. Selection moving, a badge arriving, a pane swapping.
  final Duration normal;

  /// Layout — a strip that pushes everything below it along as it grows. The
  /// eye is tracking the displaced content rather than the strip, so it wants
  /// longer than a colour change does.
  final Duration slow;

  static const _on = Motion._(
    fast: Duration(milliseconds: 110),
    normal: Duration(milliseconds: 170),
    slow: Duration(milliseconds: 240),
  );

  static const _off = Motion._(
    fast: Duration.zero,
    normal: Duration.zero,
    slow: Duration.zero,
  );

  /// Decelerating: leaves at once, arrives gently. That asymmetry is what
  /// makes a transition read as a response to the click rather than a delay
  /// before it.
  static const curve = Curves.easeOutCubic;

  /// For something on its way out, which should not linger.
  static const exit = Curves.easeInCubic;

  /// True when motion is switched off, for the cases a zero duration cannot
  /// express — a loop that should simply never start.
  bool get disabled => normal == Duration.zero;

  /// Transition builder for [AnimatedSwitcher]: fade with a small scale, for
  /// something appearing in place that has no room to travel — a badge, a
  /// status pip.
  static Widget scaleFade(Widget child, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        // Not from zero. A badge that grows from nothing draws more attention
        // than the unread count it is reporting deserves.
        scale: Tween<double>(
          begin: 0.82,
          end: 1,
        ).animate(CurvedAnimation(parent: animation, curve: curve)),
        child: child,
      ),
    );
  }
}

extension MotionOf on BuildContext {
  Motion get motion => (MediaQuery.maybeDisableAnimationsOf(this) ?? false)
      ? Motion._off
      : Motion._on;
}

/// Breathes its child's opacity while [running].
///
/// The only looping animation in the app, and it earns the exception: waiting
/// for a connection is the one state the user sits through, and a still amber
/// dot is indistinguishable from a settled one. The pulse is the part that
/// says the client is still trying.
class Pulse extends StatefulWidget {
  const Pulse({super.key, required this.running, required this.child});

  final bool running;
  final Widget child;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  /// Never to zero: the dot is a status, and a status that disappears twice a
  /// second is worse at its job than one that dims.
  static const _dimmest = 0.35;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
    value: 1,
  );

  bool _looping = false;

  void _sync() {
    final wanted = widget.running && !context.motion.disabled;
    if (wanted == _looping) return;
    _looping = wanted;
    if (wanted) {
      _controller.repeat(reverse: true, min: _dimmest, max: 1);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(Pulse old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _controller, child: widget.child);
  }
}

/// Grows a full-width strip into place, pushing what is below it along.
///
/// For the bars that come and go around the conversation — a topic, a command
/// error. They change the height of the column, so appearing without motion
/// jumps the whole scrollback under the pointer, which is how a misclick
/// happens.
class Reveal extends StatelessWidget {
  const Reveal({super.key, this.child});

  /// Null when there is nothing to show. The callers hold nullable content —
  /// a topic, an error — and have nothing left to draw once it is gone, so
  /// the collapse is a size animation alone with no fade riding on it.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final m = context.motion;
    final content = child ?? const SizedBox(width: double.infinity, height: 0);

    // Not merely pointless with motion off: AnimatedSize restarts its
    // controller from inside its own performLayout, and a zero duration
    // finishes that synchronously, which re-dirties the render object mid
    // layout and trips an assertion. Step out of the way entirely instead.
    if (m.disabled) return content;

    return AnimatedSize(
      duration: m.slow,
      curve: Motion.curve,
      // Anchored at the top, so it unrolls downwards instead of sliding up
      // out of whatever sits above it.
      alignment: Alignment.topCenter,
      child: content,
    );
  }
}

/// Fades and scales [child] in when it arrives and out when it goes.
///
/// A null child takes no space at all, so this can sit in the corner of a
/// stack or in a row without reserving a slot for something that is not there.
class Appear extends StatelessWidget {
  const Appear({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: context.motion.normal,
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.exit,
      transitionBuilder: Motion.scaleFade,
      child: child ?? const SizedBox.shrink(),
    );
  }
}

/// Fades and lifts its child into place once, on the frame it first appears.
///
/// For rows arriving in a list that is already on screen — a message, a nick
/// joining. Unlike [Appear] this never animates out: the caller is a
/// `ListView.builder`, whose rows are disposed the moment they leave, so
/// there is nothing left to animate away with.
///
/// The offset is a [Transform], not padding or a size, and that is the whole
/// trick. A scrollback auto-scrolls to `maxScrollExtent` when a message lands,
/// and an entry animation that changed the row's height would move that target
/// while the jump was being calculated, landing short and leaving the newest
/// line half off the bottom. A transform costs no layout, so the row occupies
/// its final box immediately and only the pixels travel.
///
/// [play] is the caller's judgement about whether this row is *new*. Rows
/// scrolled back into view, or a whole conversation swapped in at once, pass
/// false and appear at rest — two hundred lines fading in at once is a flash,
/// not an animation.
class Arrive extends StatefulWidget {
  const Arrive({super.key, required this.play, required this.child});

  final bool play;
  final Widget child;

  @override
  State<Arrive> createState() => _ArriveState();
}

class _ArriveState extends State<Arrive> with SingleTickerProviderStateMixin {
  /// Small enough to read as the line settling rather than as it flying in.
  static const _lift = 6.0;

  /// Null except while this row is actually travelling.
  ///
  /// Almost every [Arrive] in the app never animates: a scrollback is
  /// thousands of rows that were already there, and each one used to build a
  /// controller, an [AnimatedBuilder], an [Opacity] and a [Transform] to
  /// express standing still. Held lazily and released on arrival, so the cost
  /// belongs to the handful of rows that are moving rather than to every row
  /// that scrolls past.
  AnimationController? _controller;

  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Once, and only on the first build. A row that rebuilds — because the
    // theme changed, or a sibling was inserted above it — has already arrived.
    if (_decided) return;
    _decided = true;
    final m = context.motion;
    if (!widget.play || m.disabled) return;
    _controller = AnimationController(vsync: this, duration: m.normal)
      ..addStatusListener(_onArrived)
      ..forward(from: 0);
  }

  /// Landed. Drop the machinery and rebuild as the plain child.
  void _onArrived(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    final controller = _controller;
    _controller = null;
    setState(() {});
    // After the frame, because disposing a controller an [AnimatedBuilder] is
    // still listening to throws.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller?.dispose());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;

    return AnimatedBuilder(
      animation: controller,
      child: widget.child,
      builder: (context, child) {
        final t = Motion.curve.transform(controller.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * _lift),
            child: child,
          ),
        );
      },
    );
  }
}

/// A rotating arc, for work under way with no knowable duration.
///
/// Hand-drawn rather than Material's `CircularProgressIndicator`, which
/// arrives with its own stroke weight, its own easing and a footprint that
/// will not sit inside a line of text. This is a hairline arc in whatever
/// colour the caller is already using, sized to the text beside it.
class Spinner extends StatefulWidget {
  const Spinner({
    super.key,
    required this.color,
    this.size = 13,
    this.stroke = 1.6,
  });

  final Color color;
  final double size;
  final double stroke;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool _spinning = false;

  void _sync() {
    // With motion off the arc is still drawn — it says "waiting" by being
    // there — it simply does not turn.
    final wanted = !context.motion.disabled;
    if (wanted == _spinning) return;
    _spinning = wanted;
    wanted ? _controller.repeat() : _controller.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: RotationTransition(
        turns: _controller,
        child: CustomPaint(
          painter: _Arc(color: widget.color, stroke: widget.stroke),
        ),
      ),
    );
  }
}

class _Arc extends CustomPainter {
  const _Arc({required this.color, required this.stroke});

  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // Three-quarters of a turn: enough of a gap that the rotation is legible,
    // enough arc that it still reads as a ring rather than a stray tick.
    // Inset by half the stroke: an arc is drawn centred on the rectangle's
    // edge, so at full size its outer half falls outside the box and is clipped.
    canvas.drawArc(
      (Offset.zero & size).deflate(stroke / 2),
      0,
      3.6,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_Arc old) => old.color != color || old.stroke != stroke;
}
