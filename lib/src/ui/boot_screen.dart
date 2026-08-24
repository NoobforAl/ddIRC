import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_mark.dart';
import 'motion.dart';

/// Holds the screen while the app starts, and says so if it cannot.
///
/// The one piece of startup that is neither instant nor certain is loading the
/// native core: a dynamic library, resolved by the operating system, which can
/// simply not be there. Before this, that failure was a window that came up
/// blank and stayed blank. Now it is a sentence and a button.
///
/// The splash is deliberately shy. Nothing is drawn for the first
/// [_quiet] — a start that finishes inside that never flashes a logo at
/// anyone — and once it *has* appeared it stays for [_atLeast], because a
/// splash that blinks reads as a glitch rather than as a start.
class BootScreen extends StatefulWidget {
  const BootScreen({super.key, required this.load, required this.builder});

  /// The work to do before the app can be shown. Called again on retry, so it
  /// must be safe to run twice.
  final Future<void> Function() load;

  /// The app itself, built once [load] has finished.
  final WidgetBuilder builder;

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  /// Long enough to cover a warm start, short enough that a slow one does not
  /// feel like the app has failed to open.
  static const _quiet = Duration(milliseconds: 140);

  /// How long the splash stays once it is on screen.
  static const _atLeast = Duration(milliseconds: 420);

  final _elapsed = Stopwatch();
  Timer? _reveal;
  bool _visible = false;
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _reveal?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _reveal?.cancel();
    setState(() {
      _visible = false;
      _ready = false;
      _error = null;
    });
    _elapsed
      ..reset()
      ..start();
    _reveal = Timer(_quiet, () {
      if (mounted) setState(() => _visible = true);
    });

    Object? failure;
    try {
      await widget.load();
    } catch (error) {
      failure = error;
    }

    // Only pay the minimum if the splash actually got as far as the screen.
    if (_visible) {
      final shown = _elapsed.elapsed - _quiet;
      if (shown < _atLeast) await Future<void>.delayed(_atLeast - shown);
    }
    if (!mounted) return;

    _reveal?.cancel();
    setState(() {
      _error = failure;
      _ready = failure == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (_error != null) {
      child = _Failed(
        key: const ValueKey('failed'),
        error: _error!,
        onRetry: _start,
      );
    } else if (_ready) {
      child = KeyedSubtree(
        key: const ValueKey('app'),
        child: widget.builder(context),
      );
    } else {
      child = _Splash(key: const ValueKey('splash'), visible: _visible);
    }

    return AnimatedSwitcher(
      duration: context.motion.normal,
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.exit,
      // The default centres its children under loose constraints, which is
      // fine for a logo and wrong for the app: everything here should fill the
      // window, including the outgoing splash while it fades.
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: child,
    );
  }
}

/// The mark, the name, and a line that says work is happening.
class _Splash extends StatelessWidget {
  const _Splash({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;

    return ColoredBox(
      color: t.bg,
      // Fading rather than appearing, and scaling from near its own size
      // rather than from nothing: this is the app arriving, not a splash
      // being presented.
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: m.slow,
        curve: Motion.curve,
        child: AnimatedScale(
          scale: visible ? 1 : 0.94,
          duration: m.slow,
          curve: Motion.curve,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppMark(size: 56),
                const SizedBox(height: 18),
                Text(
                  'ddIRC',
                  style: TextStyle(
                    color: t.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 18),
                const _ProgressLine(),
                const SizedBox(height: 11),
                Text(
                  'Starting the core…',
                  style: TextStyle(color: t.faint, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An indeterminate line: a segment crossing a hairline track.
///
/// Indeterminate because it is honest — loading a dynamic library reports no
/// progress, so a bar that filled would be inventing one. A hairline rather
/// than Material's `LinearProgressIndicator`, which brings its own weight and
/// its own easing to an app built out of half-pixel rules.
class _ProgressLine extends StatefulWidget {
  const _ProgressLine();

  static const _width = 128.0;
  static const _height = 2.0;
  static const _segment = 0.4;

  @override
  State<_ProgressLine> createState() => _ProgressLineState();
}

class _ProgressLineState extends State<_ProgressLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );

  bool _running = false;

  void _sync() {
    // With motion off the segment still sits on the track — it says "there is
    // work in hand" by being there — it simply does not travel.
    final wanted = !context.motion.disabled;
    if (wanted == _running) return;
    _running = wanted;
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
    final t = context.tokens;
    final radius = BorderRadius.circular(_ProgressLine._height / 2);

    return Container(
      width: _ProgressLine._width,
      height: _ProgressLine._height,
      decoration: BoxDecoration(color: t.rule, borderRadius: radius),
      child: ClipRRect(
        borderRadius: radius,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Align(
            // Eased at both ends, so the segment gathers itself before each
            // pass instead of ricocheting between the two edges.
            alignment: Alignment(
              Curves.easeInOutCubic.transform(_controller.value) * 2 - 1,
              0,
            ),
            child: child,
          ),
          child: FractionallySizedBox(
            widthFactor: _ProgressLine._segment,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(color: t.accent, borderRadius: radius),
            ),
          ),
        ),
      ),
    );
  }
}

/// The core did not load.
///
/// Nothing has been connected to at this point, so there is nothing to lose
/// and nothing to recover — which is worth saying, because a failure this
/// early looks much more alarming than it is.
class _Failed extends StatelessWidget {
  const _Failed({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return ColoredBox(
      color: t.bg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, color: t.bad, size: 24),
                const SizedBox(height: 14),
                Text(
                  'ddIRC could not start',
                  style: TextStyle(
                    color: t.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'The native core failed to load. Nothing has been '
                  'connected to, so there is nothing to recover.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.rule, width: Tokens.hairline),
                  ),
                  // The real message, verbatim. It names the library and the
                  // reason, which is the only thing that will fix this.
                  child: SelectableText(
                    '$error',
                    style: TextStyle(
                      color: t.faint,
                      fontSize: 11.5,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Try again'),
                  style: TextButton.styleFrom(
                    foregroundColor: t.accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
