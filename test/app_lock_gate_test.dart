// Tests for the lock gate itself, not the preference behind it (see
// app_lock_test.dart). `Biometrics` is injected as a fake throughout, so none
// of this touches a platform channel — local_auth 3.x is Pigeon-based and is
// not something a raw MethodChannel mock can stand in for the way
// flutter_secure_storage's can.
//
// Motion is switched off throughout, the same as boot_screen_test.dart and
// for the same reason: it makes frames deterministic and keeps the busy
// spinner's own animation from stopping `pumpAndSettle`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/app_lock.dart';
import 'package:ddirc/src/model/biometrics.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/app_lock_gate.dart';

const _child = 'the workspace';
const _locked = 'ddIRC is locked';

Future<AppLockSettings> _settings({required bool enabled}) async {
  SharedPreferences.setMockInitialValues({'app_lock.enabled': enabled});
  return AppLockSettings.load();
}

Future<void> _pump(
  WidgetTester tester,
  AppLockSettings settings,
  Biometrics biometrics,
) async {
  await tester.pumpWidget(
    AppLockScope(
      settings: settings,
      child: MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: AppLockGate(
              biometrics: biometrics,
              child: const Text(_child),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('disabled: the child renders immediately, no lock ever shown', (
    tester,
  ) async {
    final settings = await _settings(enabled: false);
    await _pump(tester, settings, Biometrics.fake((_) async => true));
    await tester.pump();

    expect(find.text(_child), findsOneWidget);
    expect(find.text(_locked), findsNothing);
  });

  testWidgets('enabled: locks on first build, then a successful check '
      'reveals the child', (tester) async {
    final settings = await _settings(enabled: true);
    await _pump(tester, settings, Biometrics.fake((_) async => true));

    // The very first frame is already locked — the same "never a blank
    // moment" guarantee BootScreen makes for its own splash. The child stays
    // mounted underneath throughout: this is a UI overlay, not a swap, so
    // whatever it is doing keeps running behind the lock screen.
    expect(find.text(_locked), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text(_locked), findsNothing);
    expect(find.text(_child), findsOneWidget);
  });

  testWidgets('a failed check leaves the lock up, and retry tries again', (
    tester,
  ) async {
    var attempts = 0;
    final settings = await _settings(enabled: true);
    await _pump(
      tester,
      settings,
      Biometrics.fake((_) async {
        attempts++;
        return false;
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text(_locked), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text(_locked), findsOneWidget);
  });

  testWidgets(
    'returning from the background locks again, even though the child '
    'was already on screen',
    (tester) async {
      // The cold-launch check resolves on its own; the one triggered by
      // resuming is held open with a Completer, the same technique
      // boot_screen_test.dart uses to inspect a moment mid-flight — pumping
      // once flushes an already-scheduled future before the frame draws, so
      // without this the intermediate locked frame is never observable.
      var calls = 0;
      final resumeCheck = Completer<bool>();
      final settings = await _settings(enabled: true);
      await _pump(
        tester,
        settings,
        Biometrics.fake((_) async {
          calls++;
          return calls == 1 ? true : resumeCheck.future;
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text(_child), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text(_locked), findsOneWidget);

      resumeCheck.complete(true);
      await tester.pumpAndSettle();
      expect(find.text(_locked), findsNothing);
      expect(find.text(_child), findsOneWidget);
    },
  );

  testWidgets(
    'a lifecycle blip caused by the prompt itself does not start a second '
    'check',
    (tester) async {
      var authCalls = 0;
      final settings = await _settings(enabled: true);
      await _pump(
        tester,
        settings,
        Biometrics.fake((_) async {
          authCalls++;
          // Simulates the OS's own biometric prompt nudging the app's
          // lifecycle mid-authentication — exactly what BiometricActivity
          // exists to absorb. Found on real Samsung hardware: showing the
          // prompt there pauses and resumes the hosting activity for real.
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          return true;
        }),
      );
      await tester.pumpAndSettle();

      expect(authCalls, 1);
      expect(find.text(_child), findsOneWidget);
      expect(find.text(_locked), findsNothing);
    },
  );

  testWidgets(
    'a lifecycle blip from a biometric check made elsewhere in the app '
    'does not lock this gate',
    (tester) async {
      // Reproduces the actual bug found on a real Samsung phone: turning
      // the switch on in AppLockSection makes its own, unrelated
      // confirmation check, which on that hardware blipped the app's
      // lifecycle exactly the way this gate's own checks do. This gate has
      // no local flag for a check it did not make itself — only
      // BiometricActivity, shared across every caller, can tell the two
      // apart.
      final settings = await _settings(enabled: true);
      await _pump(tester, settings, Biometrics.fake((_) async => true));
      await tester.pumpAndSettle();
      expect(find.text(_child), findsOneWidget);

      final elsewhere = Biometrics.fake((_) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        return true;
      });
      await elsewhere.authenticate('Confirm to turn on app lock');
      await tester.pumpAndSettle();

      expect(find.text(_locked), findsNothing);
      expect(find.text(_child), findsOneWidget);
    },
  );
}
