// Tests for keeping the app running with its window closed.
//
// None of this drives a real tray or a real window: both are native controls
// with no test double, and a widget test has neither. What is tested is the
// part that carries a decision — which platforms the feature is offered on,
// what closing the window does, what the icon says it is doing, and that the
// way back in and the way out both exist. The plumbing around those is a
// handful of calls into two plugins.
//
// The one thing here that is not a decision is [Workspace.closeAll] being safe
// to call twice, and it earns its place: quitting closes the connections and
// then tears the window down, and the teardown runs the widget tree's dispose
// on the way out. Get that wrong and quitting throws on the way to the exit,
// which is the worst place to find out.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/workspace.dart';
import 'package:ddirc/src/ui/background.dart';

/// The keychain, which a test host does not have.
const _keychain = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _keychain,
      (call) async => call.method == 'read' ? null : true,
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_keychain, null);
  });

  group('which platforms it is offered on', () {
    test('the three desktops, where hiding a window keeps a process', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(runsInBackgroundOn(platform), isTrue, reason: '$platform');
      }
    });

    test('neither phone, and for two different reasons', () {
      // Android could do this and does not yet — it needs a foreground service
      // that has not been built. iOS cannot: it will not hold a socket open
      // for an app that is not in front. Both are excluded, because a switch
      // that does nothing is worse than no switch.
      expect(runsInBackgroundOn(TargetPlatform.android), isFalse);
      expect(runsInBackgroundOn(TargetPlatform.iOS), isFalse);
    });
  });

  group('the setting', () {
    test('is off, because closing a window means closing it', () async {
      final settings = await AppSettings.load();
      expect(settings.runInBackground, isFalse);
    });

    test('persists once turned on', () async {
      (await AppSettings.load()).runInBackground = true;
      expect((await AppSettings.load()).runInBackground, isTrue);
    });
  });

  group('closing the window', () {
    test('hides it when the setting is on', () {
      expect(
        closeAction(runInBackground: true, quitting: false),
        CloseAction.hide,
      );
    });

    test('quits when the setting is off', () {
      expect(
        closeAction(runInBackground: false, quitting: false),
        CloseAction.quit,
      );
    });

    test('quits while quitting, however the setting is set', () {
      // Quitting destroys the window, which arrives back here as another
      // close. Without this the app would hide itself on the way out and
      // never actually leave.
      for (final background in [true, false]) {
        expect(
          closeAction(runInBackground: background, quitting: true),
          CloseAction.quit,
          reason: 'runInBackground: $background',
        );
      }
    });
  });

  group('the tray', () {
    test('offers a way back in and a way out, and nothing else', () {
      final keys = backgroundMenu().items!
          .where((i) => i.key != null)
          .map((i) => i.key)
          .toList();
      // The way back is the half that makes hiding safe; without it a closed
      // window is a lost app rather than a backgrounded one.
      expect(keys, containsAll([showItemKey, quitItemKey]));
      expect(keys, hasLength(2));
    });

    test('every item that is not a separator is labelled', () {
      for (final item in backgroundMenu().items!) {
        if (item.type == 'separator') continue;
        expect(item.label, isNotNull);
        expect(item.label, isNotEmpty);
      }
    });

    test('says whether it is connected, not just that it is running', () {
      // The question the icon exists to answer.
      expect(trayTooltip(0), contains('not connected'));
      expect(trayTooltip(1), contains('1 network connected'));
      expect(trayTooltip(3), contains('3 networks connected'));
    });

    test('names the app, so a tray full of icons can be told apart', () {
      for (final count in [0, 1, 5]) {
        expect(trayTooltip(count), startsWith('ddIRC'));
      }
    });
  });

  group('closing down', () {
    Future<Workspace> workspace() async => Workspace(
      profiles: await ProfileStore.load(),
      settings: await AppSettings.load(),
      proxies: await ProxySettings.load(),
    );

    test('can be done twice without throwing', () async {
      // Quitting from the tray closes the connections, then destroys the
      // window — and the teardown runs the widget tree's dispose, which closes
      // them again. Disposing a ChangeNotifier twice throws; this must not.
      final w = await workspace();
      w.closeAll();
      w.closeAll();
      expect(() => w.dispose(), returnsNormally);
    });

    test('leaves nothing connected', () async {
      final w = await workspace();
      w.closeAll();
      expect(w.sessions, isEmpty);
      expect(w.active, isNull);
      w.dispose();
    });

    test(
      'is what dispose does, so neither path can be the careful one',
      () async {
        // The two must not drift: a quit that says goodbye and a teardown that
        // does not would mean the servers hear from us only sometimes.
        final w = await workspace();
        expect(() => w.dispose(), returnsNormally);
      },
    );
  });

  test('the grace period is short enough not to read as a hang', () {
    // A bounded courtesy. Long enough for a QUIT already handed to the core to
    // reach the wire, short enough that quitting still feels immediate.
    expect(quitGrace, greaterThan(Duration.zero));
    expect(quitGrace, lessThan(const Duration(milliseconds: 500)));
  });
}
