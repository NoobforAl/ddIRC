import 'dart:async';

import 'package:flutter/material.dart';

import '../model/app_lock.dart';
import '../model/biometrics.dart';
import '../theme.dart';
import 'app_mark.dart';
import 'motion.dart';

/// Sits between the boot splash and the workspace. Locks on first build — a
/// cold launch — and again every time the app returns from the background,
/// for as long as [AppLockSettings.enabled] says to.
///
/// A UI gate only: connections already open keep running behind it. This
/// protects a device someone else has picked up, not data at rest — the
/// platform keychain already does that regardless of this switch.
///
/// Deliberately does not use [lib/src/ui/presence.dart]'s `AppPresence`: that
/// class also treats a desktop window losing focus as "backgrounded", which
/// would re-lock on a plain alt-tab. This only cares about the raw lifecycle
/// transition — actually leaving and returning to the app.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child, this.biometrics});

  final Widget child;

  /// For tests: bypasses `local_auth` entirely.
  @visibleForTesting
  final Biometrics? biometrics;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late final Biometrics _bio = widget.biometrics ?? Biometrics();

  AppLockSettings? _lock;
  bool _locked = false;
  bool _authenticating = false;
  bool _primed = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cached rather than looked up again in the lifecycle callback below,
    // which runs outside the build phase this scope lookup expects.
    _lock = AppLockScope.of(context);
    if (!_primed) {
      _primed = true;
      _lockIfEnabled();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasResumed = _lifecycle == AppLifecycleState.resumed;
    _lifecycle = state;
    // Ask first, unconditionally: a check made elsewhere in the app (the
    // confirmation `AppLockSection` shows when the switch is first turned
    // on, say) can blip the lifecycle exactly the way this widget's own
    // checks can, and BiometricActivity is what recognises either as an
    // echo rather than a real return. See its own doc comment for why this
    // cannot be a private flag on this State.
    final isEcho = BiometricActivity.noteLifecycleChange(wasResumed, state);
    if (BiometricActivity.checking || isEcho) return;
    if (state == AppLifecycleState.resumed && !wasResumed) _lockIfEnabled();
  }

  void _lockIfEnabled() {
    if (_lock?.enabled != true) return;
    setState(() => _locked = true);
    unawaited(_unlock());
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() => _authenticating = true);
    final ok = await _bio.authenticate('Unlock ddIRC');
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      if (ok) _locked = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Keyed rather than swapped for null on every busy-state change, so
        // the fade-and-scale in `Appear` plays once on the way in and once on
        // the way out — not every time a check starts or finishes.
        Appear(
          child: _locked
              ? _LockScreen(
                  key: const ValueKey('lock'),
                  busy: _authenticating,
                  onRetry: _unlock,
                )
              : null,
        ),
      ],
    );
  }
}

/// The app is locked. Filled in behind whatever was already on screen, so the
/// window never goes blank while a fingerprint reader is being asked.
class _LockScreen extends StatelessWidget {
  const _LockScreen({super.key, required this.busy, required this.onRetry});

  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return ColoredBox(
      color: t.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BadgedMark(color: t.muted),
              const SizedBox(height: 22),
              Text(
                'ddIRC is locked',
                style: TextStyle(
                  color: t.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Unlock with your fingerprint, face or device passcode to '
                'get back in.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: t.faint,
                  fontSize: 12,
                  height: 1.4,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 26),
              _UnlockButton(busy: busy, onPressed: busy ? null : onRetry),
            ],
          ),
        ),
      ),
    );
  }
}

/// [AppMark] with a small lock badge over its corner, the same way the
/// network rail badges a mark with a status pip — a second small shape
/// anchored to the first, not a second icon competing with it.
class _BadgedMark extends StatelessWidget {
  const _BadgedMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const AppMark(size: 56),
        Positioned(
          bottom: -3,
          right: -3,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: t.bg, shape: BoxShape.circle),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: t.surface,
                shape: BoxShape.circle,
                border: Border.all(color: t.rule, width: Tokens.hairline),
              ),
              child: Icon(Icons.lock_rounded, size: 12, color: color),
            ),
          ),
        ),
      ],
    );
  }
}

/// The one action on this screen, so it carries the weight a filled button
/// does elsewhere — [SettingsPrimaryButton]'s style, plus the icon that
/// button never needed.
class _UnlockButton extends StatelessWidget {
  const _UnlockButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FilledButton.icon(
      onPressed: onPressed,
      icon: busy
          ? Spinner(color: t.onAccent, size: 14)
          : const Icon(Icons.fingerprint, size: 18),
      label: Text(busy ? 'Waiting…' : 'Unlock'),
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        disabledBackgroundColor: t.surfaceHover,
        disabledForegroundColor: t.faint,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}
