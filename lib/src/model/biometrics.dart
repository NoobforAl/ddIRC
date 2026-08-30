import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:local_auth/local_auth.dart';

/// Whether a biometric check is in flight anywhere in the app, and whether a
/// lifecycle transition is the tail of one rather than a genuine return from
/// the background.
///
/// This exists because of something found testing on real Samsung hardware:
/// showing the biometric prompt there pauses and resumes the hosting
/// activity, which reaches Flutter as an ordinary `AppLifecycleState`
/// transition — indistinguishable, on its own, from the user actually
/// leaving and coming back. [AppLockGate] reacts to exactly that transition,
/// so without this it would see its own prompt's dismissal as "the user
/// returned", show itself again, and loop forever the instant it succeeded.
///
/// A per-widget flag is not enough: any biometric check anywhere in the app —
/// including the one-off confirmation `AppLockSection` makes when the switch
/// is first turned on — can trigger the same blip, and `AppLockGate`'s
/// lifecycle observer cannot tell which call caused it. So this is shared and
/// static rather than owned by [Biometrics] or by whichever widget made the
/// call: everything that prompts biometrics reports through it, and anything
/// reacting to app lifecycle can ask it whether the current transition is
/// worth acting on.
///
/// Driven entirely by events, not elapsed time. A wall-clock "ignore
/// anything within N seconds" window was tried first and rejected: it cannot
/// tell a check's own echo apart from a genuinely fast switch away and back,
/// and it makes tests racy for no better reason than one device's dismissal
/// animation happening to be slow.
class BiometricActivity {
  BiometricActivity._();

  static int _inFlight = 0;
  static bool _sawAwayWhileChecking = false;

  /// A check is currently running somewhere in the app.
  static bool get checking => _inFlight > 0;

  /// Record one lifecycle transition. Returns true exactly for the `resumed`
  /// that is the tail of a check which was active when the app went away —
  /// that one transition should be swallowed rather than acted on.
  static bool noteLifecycleChange(bool wasResumed, AppLifecycleState state) {
    if (_inFlight > 0) {
      if (wasResumed && state != AppLifecycleState.resumed) {
        _sawAwayWhileChecking = true;
      } else if (state == AppLifecycleState.resumed) {
        // Regained focus before the check's own Future resolved — still the
        // same blip, accounted for here rather than left to fire once the
        // check finishes and nothing is listening for it anymore.
        _sawAwayWhileChecking = false;
      }
      return false;
    }
    if (state == AppLifecycleState.resumed && _sawAwayWhileChecking) {
      _sawAwayWhileChecking = false;
      return true;
    }
    return false;
  }

  static void _begin() => _inFlight++;
  static void _end() => _inFlight = _inFlight > 0 ? _inFlight - 1 : 0;
}

/// The one call this app makes into `local_auth`.
///
/// Wrapped rather than used directly so a widget test can stand in for it
/// without a platform channel — the app has no dependency-injection framework,
/// so a constructor-supplied fake is the whole mechanism, matching the
/// `@visibleForTesting` seam [lib/src/ui/presence.dart]'s `AppPresence` already
/// uses for its own platform dependency.
class Biometrics {
  Biometrics() : _authenticate = null;

  /// For tests: bypasses `local_auth` entirely.
  Biometrics.fake(Future<bool> Function(String reason) authenticate)
    : _authenticate = authenticate;

  final Future<bool> Function(String reason)? _authenticate;
  final LocalAuthentication _auth = LocalAuthentication();

  /// Whether this device can even be asked — no sensor, or no way to fail
  /// over to the device's own PIN/pattern/password either.
  Future<bool> get isSupported async {
    if (_authenticate != null) return true;
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      debugPrint('could not tell whether biometrics are supported: $e');
      return false;
    }
  }

  /// Prompts biometrics, falling back to the device PIN/pattern/password —
  /// `biometricOnly: false` is the point of that fallback, not a weaker path
  /// added on top of it.
  ///
  /// `persistAcrossBackgrounding` is deliberately left at its default
  /// (`false`), not turned on. It sounds like the right answer to the OS's
  /// own prompt blipping the app's lifecycle mid-authentication, but on real
  /// Samsung hardware it did the opposite: the prompt's own focus churn was
  /// enough to make the plugin think the app had been backgrounded and needed
  /// retrying, which produced a prompt that re-showed itself the instant it
  /// succeeded. [AppLockGate] already re-arms the lock on every genuine
  /// return from the background, so nothing is lost by letting an
  /// interrupted attempt simply fail here instead of the plugin retrying it
  /// internally.
  ///
  /// Wrapped in [BiometricActivity] regardless of whether this resolves for
  /// real or through the test fake — see that class for why every call,
  /// wherever it comes from, has to report through the same place.
  Future<bool> authenticate(String reason) async {
    BiometricActivity._begin();
    try {
      if (_authenticate != null) return await _authenticate(reason);
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
      );
    } catch (e) {
      debugPrint('biometric authentication failed: $e');
      return false;
    } finally {
      BiometricActivity._end();
    }
  }
}
