// Tests for the app-lock preference itself — not the gate that reads it,
// which lives in app_lock_gate_test.dart. Pure model, no platform channel:
// this is a plain boolean in shared_preferences, the same store every other
// non-secret setting uses.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/app_lock.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('is off by default', () async {
    final settings = await AppLockSettings.load();
    expect(settings.enabled, isFalse);
  });

  test('round-trips through setEnabled and load', () async {
    final settings = await AppLockSettings.load();
    await settings.setEnabled(true);
    expect(settings.enabled, isTrue);

    final reloaded = await AppLockSettings.load();
    expect(reloaded.enabled, isTrue);
  });

  test('setEnabled notifies listeners on a real change', () async {
    final settings = await AppLockSettings.load();
    var notified = 0;
    settings.addListener(() => notified++);

    await settings.setEnabled(true);
    expect(notified, 1);

    // Setting it to what it already is must not notify — nothing changed.
    await settings.setEnabled(true);
    expect(notified, 1);
  });

  group('appLockSupportedOn', () {
    test('is false only for Linux', () {
      expect(appLockSupportedOn(TargetPlatform.linux), isFalse);
      expect(appLockSupportedOn(TargetPlatform.android), isTrue);
      expect(appLockSupportedOn(TargetPlatform.iOS), isTrue);
      expect(appLockSupportedOn(TargetPlatform.macOS), isTrue);
      expect(appLockSupportedOn(TargetPlatform.windows), isTrue);
    });
  });

  test(
    'a stored true still reads as off on a platform with no local_auth',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock.enabled': true});
      final settings = await AppLockSettings.load();
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      // A `true` carried in from another platform — a synced settings file,
      // a restored backup — must never leave this one unable to open the app
      // it locked. There is no biometric API to fall back to on Linux.
      expect(settings.enabled, isFalse);
    },
  );
}
