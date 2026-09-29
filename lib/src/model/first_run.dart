import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'proxy.dart';

/// What a fresh install starts with: the most private configuration the app
/// has, rather than the most convenient one.
///
/// Concretely, the built-in Tor is switched on and every connection is routed
/// through it. Everything else that touches privacy already starts in its
/// careful position — no logs, no history, no notification previews, image
/// metadata stripped — so Tor was the one default still pointing the other
/// way, and the first network someone adds is exactly the connection that
/// should not carry their address.
///
/// Only a *fresh* install. Someone upgrading has already decided how they
/// connect, even if the decision was to leave the default alone, and a
/// release that quietly rerouted them would be the app choosing for them.
/// So this runs once, before the Tor and proxy preferences are read, and only
/// where nothing says the app has been set up before: no saved networks, and
/// neither preference ever written.
class FirstRun {
  FirstRun._();

  /// Written once the defaults have been applied (or found unnecessary), so
  /// the question is never asked twice.
  static const marker = 'firstRun.secureDefaults.v1';

  /// Mirrors of the keys [TorSettings] and [ProxySettings] own. Named here
  /// rather than exported from there because this is the only other reader,
  /// and a test pins that the three agree.
  static const torKey = 'tor.enabled';
  static const routeKey = 'proxy.route.v1';
  static const legacyProxyKey = 'proxy.enabled';

  /// Apply the secure defaults if this is a fresh install. Returns whether it
  /// was — the welcome screen says so when it was.
  static Future<bool> apply({required bool hasProfiles}) async {
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('first-run check unavailable: $e');
      return false;
    }
    if (prefs.getBool(marker) ?? false) return false;

    final fresh =
        !hasProfiles &&
        !prefs.containsKey(torKey) &&
        !prefs.containsKey(routeKey) &&
        !prefs.containsKey(legacyProxyKey);
    if (fresh) {
      await prefs.setBool(torKey, true);
      await prefs.setString(routeKey, ProxyRoute.builtIn.name);
    }
    await prefs.setBool(marker, true);
    return fresh;
  }
}
