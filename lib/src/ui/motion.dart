import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';
import 'layout.dart';

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

  /// Calmer than they were (110 / 170 / 240). At those speeds everything that
  /// moved did so inside a blink, and a screen where each change finishes
  /// before the eye has found it reads as flicker rather than as motion. These
  /// are still short enough to finish before the next tap, which is the limit.
  static const _on = Motion._(
    fast: Duration(milliseconds: 130),
    normal: Duration(milliseconds: 220),
    slow: Duration(milliseconds: 320),
  );

  static const _off = Motion._(
    fast: Duration.zero,
    normal: Duration.zero,
    slow: Duration.zero,
  );

  /// Decelerating: leaves promptly, arrives gently. That asymmetry is what
  /// makes a transition read as a response to the click rather than a delay
  /// before it.
  ///
  /// Material's "standard decelerate" rather than `easeOutCubic`. Cubic-out
  /// covers about half the distance in the first tenth of the time, which is a
  /// lurch; this starts a little softer and spends its length settling, so the
  /// eye can follow where the thing is going to stop.
  static const curve = Cubic(0.2, 0.0, 0.0, 1.0);

  /// For something on its way out, which should not linger. Accelerating, and
  /// without the sharp tail `easeInCubic` has.
  static const exit = Cubic(0.3, 0.0, 1.0, 1.0);

  /// For travel that starts and ends at rest — a scroll across a long
  /// conversation — where a decelerate alone would start at full speed.
  static const glide = Curves.easeInOutCubic;

  /// How long to take over moving [pixels] along a scroll view.
  ///
  /// By distance, because one fixed time is a gentle drift across two screens
  /// and a blur across two hundred. Never less than a settled-looking third of
  /// a second, and never more than three quarters of one: past that it is
  /// making the reader wait to be where they asked to be.
  Duration travel(double pixels) {
    if (disabled) return Duration.zero;
    final ms = 260 + pixels.abs() / 8;
    return Duration(milliseconds: ms.clamp(320, 720).round());
  }

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
    // A slow breath reads as waiting; a quick one reads as an alarm.
    duration: const Duration(milliseconds: 1300),
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
    duration: const Duration(milliseconds: 1200),
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

/// [showDialog], arriving the way everything else in the app arrives.
///
/// Material's own dialog transition is a bare fade on its own curve and its own
/// timing — the one transition in the app that did not draw from [Motion]. This
/// is the same route with that one thing replaced.
///
/// Three shapes, because three things get shown this way:
///
/// * A **page** — the settings shell on a phone, which is opaque and fills the
///   screen. It slides up from the bottom edge, fully opaque the whole way. It
///   used to fade, which on something that covers the screen means fading
///   *through* what is underneath: for a quarter of a second the welcome screen
///   and the open menu showed through the form, and then it snapped solid. A
///   page that is all there from the first pixel and simply travels is the
///   version that can be followed.
/// * A **dialog** on a phone, small enough to float: fades in while rising a few
///   pixels.
/// * A dialog on a wide screen: settles into place from slightly smaller.
///
/// A page says it is one by calling [claimFullBleed] from its `build`; nothing
/// else needs to be told.
///
/// Takes only what the app's callers pass. Safe area and captured themes are
/// exactly what [showDialog] would have given them; the barrier is lighter.
Future<T?> showSoftDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context);
  return navigator.push<T>(
    _SoftDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      // Dimmer than Material's 54% black, which turns everything behind a
      // dialog into a hole. Enough to say "not now" about what is beneath,
      // and no more — and lighter still on a light ground, where the same
      // black reads twice as heavy.
      barrierColor: Colors.black.withValues(
        alpha: context.tokens.brightness == Brightness.dark ? 0.42 : 0.24,
      ),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      duration: context.motion.slow,
      rises: context.layout.isCompact,
    ),
  );
}

/// Tell the dialog route holding [context] that what it is showing fills the
/// screen, so it should arrive as a page rather than as a dialog.
///
/// Safe to call on every build; it does its work once. A no-op outside a route
/// made by [showSoftDialog].
void claimFullBleed(BuildContext context) {
  context.getInheritedWidgetOfExactType<_BleedHint>()?.flag.claim();
}

/// Whether the page under a route fills the screen. Learned from the page, which
/// builds after the route does, so it is known one frame in.
class _BleedFlag extends ChangeNotifier {
  bool _full = false;
  bool _pending = false;

  bool get full => _full;

  void claim() {
    if (_full || _pending) return;
    _pending = true;
    // After the frame, because the page is building right now and what listens
    // to this is part of the same tree.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      _full = true;
      notifyListeners();
    });
  }
}

class _BleedHint extends InheritedWidget {
  const _BleedHint({required this.flag, required super.child});

  final _BleedFlag flag;

  @override
  bool updateShouldNotify(_BleedHint old) => false;
}

/// An [AnimationController] that starts its first run on the frame *after* the
/// one that builds the page.
///
/// The clock of a route's animation starts in the frame the route is inserted
/// in. A page that takes a long time to build — the network editor is about
/// ninety milliseconds on a mid-range phone — makes that frame long, and the
/// next frame then finds a third of the animation already used up: it freezes,
/// and then skips. Starting after the page is built spends no animation on
/// work the eye cannot see, at the cost of one frame of delay that the build
/// had already imposed.
class _PatientController extends AnimationController {
  _PatientController({
    required super.vsync,
    super.duration,
    super.reverseDuration,
    super.debugLabel,
    this.onStarted,
  });

  /// Called once the delayed run has begun, so the route can refresh what it
  /// derived from the animation's status while it was still waiting.
  ///
  /// The scrim behind a dialog ignores taps for as long as the animation is
  /// "dismissed" — which is what it is for the whole of the delay — and it only
  /// learns otherwise when the route is told its internal state changed. The
  /// framework does that on a status change, but not reliably from where a
  /// delayed start happens, and a dialog whose scrim cannot be tapped away is
  /// a dialog that cannot be dismissed the way everyone expects to.
  final VoidCallback? onStarted;

  bool _gone = false;

  @override
  TickerFuture forward({double? from}) {
    if (from != null || status != AnimationStatus.dismissed || value != 0) {
      return super.forward(from: from);
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      // Dismissed again, or disposed, before the page had finished building:
      // nothing left to bring in.
      if (_gone || status != AnimationStatus.dismissed) return;
      super.forward();
      onStarted?.call();
    });
    SchedulerBinding.instance.scheduleFrame();
    // The navigator waits on this to know a push has finished. It is told so
    // at once; the animation is a flourish on a push that has already happened.
    return TickerFuture.complete();
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}

class _SoftDialogRoute<T> extends DialogRoute<T> {
  _SoftDialogRoute({
    required super.context,
    required super.builder,
    required super.barrierDismissible,
    required super.barrierColor,
    required super.barrierLabel,
    required super.themes,
    required this.duration,
    required this.rises,
  });

  final Duration duration;

  /// A phone: floating dialogs rise rather than grow. See [showSoftDialog].
  final bool rises;

  final _bleed = _BleedFlag();

  @override
  Duration get transitionDuration => duration;

  /// Shorter on the way out: something dismissed should be gone by the time
  /// the eye is back on what was beneath it.
  @override
  Duration get reverseTransitionDuration => duration * 0.7;

  @override
  AnimationController createAnimationController() => _PatientController(
    duration: transitionDuration,
    reverseDuration: reverseTransitionDuration,
    debugLabel: debugLabel,
    vsync: navigator!,
    onStarted: changedInternalState,
  );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _BleedHint(
    flag: _bleed,
    child: super.buildPage(context, animation, secondaryAnimation),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Motion.curve,
      reverseCurve: Motion.exit,
    );
    // The same three wrappers whatever the shape, with the animations swapped
    // between them. Changing which *widgets* wrap the page when it announces
    // itself as full-bleed would unmount it and build it again — the ninety
    // milliseconds this exists to hide, paid twice.
    return ListenableBuilder(
      listenable: _bleed,
      child: child,
      builder: (context, child) {
        final page = _bleed.full;
        const still = AlwaysStoppedAnimation<double>(1);
        return FadeTransition(
          // A page is opaque from its first pixel. Full opacity also means no
          // offscreen layer, which on a phone is the expensive part of a fade.
          opacity: page ? still : curved,
          child: SlideTransition(
            position: Tween(
              begin: page
                  ? const Offset(0, 1)
                  : (rises ? const Offset(0, 0.035) : Offset.zero),
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              // Not from far. A dialog is answering the click that opened it,
              // and a long zoom is a delay before the answer.
              scale: page || rises
                  ? still
                  : Tween(begin: 0.95, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Pulls a dragged thing back to rest along a spring rather than jumping.
///
/// For the swipe-to-reply bubble: let go short of the threshold, or past it,
/// and the bubble has to go home either way. Snapping is what made the gesture
/// feel like a switch; a spring with a little give is what makes it feel like
/// something held.
const snapBack = SpringDescription(mass: 1, stiffness: 520, damping: 30);
