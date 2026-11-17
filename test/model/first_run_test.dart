// A fresh install starts private — the built-in Tor on, every connection
// through it — and an upgrade keeps exactly what it had.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/first_run.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/tor.dart';

void main() {
  test('a fresh install turns Tor on and routes through it', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await FirstRun.apply(hasProfiles: false), isTrue);

    final tor = await TorSettings.load();
    final proxies = await ProxySettings.load(tor: tor);
    expect(tor.enabled, isTrue);
    expect(proxies.route, ProxyRoute.builtIn);
    expect(proxies.overridesProfiles, isTrue);
  });

  test('an install with saved networks is left alone', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await FirstRun.apply(hasProfiles: true), isFalse);

    final tor = await TorSettings.load();
    final proxies = await ProxySettings.load(tor: tor);
    expect(tor.enabled, isFalse);
    expect(proxies.route, ProxyRoute.off);
  });

  test('a choice already made is never overwritten', () async {
    for (final prefs in <Map<String, Object>>[
      {FirstRun.torKey: false},
      {FirstRun.routeKey: ProxyRoute.off.name},
      {FirstRun.legacyProxyKey: false},
    ]) {
      SharedPreferences.setMockInitialValues(prefs);
      expect(
        await FirstRun.apply(hasProfiles: false),
        isFalse,
        reason: '$prefs',
      );
      final tor = await TorSettings.load();
      expect(tor.enabled, isFalse, reason: '$prefs');
    }
  });

  test('it runs once: switching Tor off afterwards sticks', () async {
    SharedPreferences.setMockInitialValues({});
    await FirstRun.apply(hasProfiles: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(FirstRun.torKey);
    await prefs.remove(FirstRun.routeKey);
    expect(await FirstRun.apply(hasProfiles: false), isFalse);
    expect(prefs.containsKey(FirstRun.torKey), isFalse);
  });
}
