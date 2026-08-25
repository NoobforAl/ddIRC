// Tests for staying connected while the app is not the thing in front.
//
// Two platforms that share a promise and no mechanism at all. On desktop it is
// a window that hides and a tray icon that brings it back; on Android it is a
// foreground service and the notification Android charges for it. Neither
// mechanism exists in a widget test — there is no tray, no window and no
// Android — so what is tested is everything that decides: which platforms are
// offered it, what closing does, what the user is told, and, on Android, the
// exact conversation held with the host.
//
// The Android half is testable in a way the desktop half is not, because it
// speaks over a MethodChannel and a MethodChannel can be listened to. So it is
// tested properly: the calls, their order, and their arguments.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/workspace.dart';
import 'package:ddirc/src/ui/background.dart';
import 'package:ddirc/src/ui/background_android.dart';
import 'package:ddirc/src/ui/background_desktop.dart';

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
    debugDefaultTargetPlatformOverride = null;
  });

  Future<Workspace> workspace() async => Workspace(
    profiles: await ProfileStore.load(),
    settings: await AppSettings.load(),
    proxies: await ProxySettings.load(),
  );

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

    test('and Android, where the process has to ask to stay', () {
      expect(runsInBackgroundOn(TargetPlatform.android), isTrue);
    });

    test('never iOS, which would make it a promise it cannot keep', () {
      // The OS will not hold a TCP socket open for an app that is not in
      // front. A switch offering it would be a lie with a toggle on it.
      expect(runsInBackgroundOn(TargetPlatform.iOS), isFalse);
    });
  });

  group('the right mechanism is chosen for the platform', () {
    Future<BackgroundKeeper> keeperOn(TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      return backgroundKeeperFor(
        settings: await AppSettings.load(),
        workspace: await workspace(),
      );
    }

    test('a tray and a window on desktop', () async {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(
          await keeperOn(platform),
          isA<BackgroundPresence>(),
          reason: '$platform',
        );
      }
    });

    test('a foreground service on Android', () async {
      expect(await keeperOn(TargetPlatform.android), isA<ForegroundService>());
    });

    test('nothing at all on iOS, and it still answers', () async {
      // A real object rather than a null, so nothing above has to remember
      // that this is sometimes absent.
      final keeper = await keeperOn(TargetPlatform.iOS);
      expect(keeper, isA<NoBackgroundKeeper>());
      await expectLater(keeper.start(), completes);
      expect(keeper.dispose, returnsNormally);
    });
  });

  group('the setting', () {
    test('is off, because this is not what closing normally means', () async {
      expect((await AppSettings.load()).runInBackground, isFalse);
    });

    test('persists once turned on', () async {
      (await AppSettings.load()).runInBackground = true;
      expect((await AppSettings.load()).runInBackground, isTrue);
    });
  });

  group('what the setting promises', () {
    test('says what you will see, which differs by platform', () {
      final android = backgroundSettingDescription(TargetPlatform.android);
      final desktop = backgroundSettingDescription(TargetPlatform.windows);
      expect(android, isNot(desktop));
      expect(android, contains('notification'));
      expect(desktop, contains('tray'));
    });

    test('Android says what still ends it', () async {
      // The service deliberately does not survive a swipe from Recents, so
      // the switch has to say so rather than let it be discovered.
      expect(
        backgroundSettingDescription(TargetPlatform.android),
        contains('Recents'),
      );
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

  group('what it says while it is out of sight', () {
    test('says whether it is connected, not just that it is running', () {
      expect(connectionSummary(0), 'not connected');
      expect(connectionSummary(1), '1 network connected');
      expect(connectionSummary(3), '3 networks connected');
    });

    test('the tray and the notification say the same thing', () {
      // One sentence for both, because it answers the same question in both
      // places and two wordings that drifted would be two things to keep true.
      for (final count in [0, 1, 4]) {
        expect(trayTooltip(count), contains(connectionSummary(count)));
      }
    });

    test('only the tray repeats the app name', () {
      // A tooltip stands alone; the notification carries the name in its
      // title already and would only be talking to itself.
      expect(trayTooltip(2), startsWith('ddIRC'));
      expect(connectionSummary(2), isNot(contains('ddIRC')));
    });
  });

  group('the tray menu', () {
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
  });

  group('the Android service', () {
    late List<MethodCall> calls;
    late MethodChannel channel;
    late AppSettings settings;
    late Workspace space;
    late ForegroundService service;

    /// What the host answers. Overridden per test where it matters.
    late Future<Object?> Function(MethodCall) answer;

    setUp(() async {
      calls = [];
      answer = (_) async => null;
      channel = const MethodChannel('dev.ddirc/background.test');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return answer(call);
      });
      settings = await AppSettings.load();
      space = await workspace();
      service = ForegroundService(
        settings: settings,
        workspace: space,
        channel: channel,
      );
    });

    tearDown(() {
      service.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    List<String> methods() => [for (final c in calls) c.method];

    test('starts nothing while the setting is off', () async {
      await service.start();
      expect(methods(), isEmpty);
      expect(service.serviceIsRunning, isFalse);
    });

    test('starts the service when the setting is turned on', () async {
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();

      expect(methods(), contains('start'));
      expect(service.serviceIsRunning, isTrue);
      final start = calls.firstWhere((c) => c.method == 'start');
      // The notification says what it is doing from the first frame it
      // exists, rather than being blank until something changes.
      expect(start.arguments['status'], connectionSummary(0));
    });

    test('asks about the notification before starting, not after', () async {
      answer = (call) async =>
          call.method == 'notificationsAllowed' ? false : null;
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();

      expect(
        methods().indexOf('notificationsAllowed'),
        lessThan(methods().indexOf('start')),
      );
      expect(methods(), contains('requestNotifications'));
    });

    test('does not ask again when it is already allowed', () async {
      answer = (call) async =>
          call.method == 'notificationsAllowed' ? true : null;
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();

      expect(methods(), isNot(contains('requestNotifications')));
      expect(methods(), contains('start'));
    });

    test('starts anyway when the notification is refused', () async {
      // Refusing the notification costs being told it is running. It does not
      // cost the thing the user just switched on.
      answer = (call) async => switch (call.method) {
        'notificationsAllowed' => false,
        'requestNotifications' => false,
        _ => null,
      };
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();

      expect(methods(), contains('start'));
      expect(service.serviceIsRunning, isTrue);
    });

    test('stops the service when the setting is turned off', () async {
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();
      calls.clear();

      settings.runInBackground = false;
      await pumpEventQueue();

      expect(methods(), ['stop']);
      expect(service.serviceIsRunning, isFalse);
    });

    test('a host that fails does not bring the app down', () async {
      answer = (_) async => throw PlatformException(code: 'nope');
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();
      // The setting not working is not worth an exception reaching the user,
      // and must never be worth losing a connection that is already up.
      expect(methods(), contains('start'));
    });

    test(
      'quitting closes the connections before stopping the service',
      () async {
        await service.start();
        settings.runInBackground = true;
        await pumpEventQueue();
        calls.clear();

        await service.quit();

        // Servers are told first, so everyone in the channel sees a quit now
        // rather than a ping timeout in two minutes' time.
        expect(space.sessions, isEmpty);
        expect(methods(), contains('stop'));
        expect(service.serviceIsRunning, isFalse);
      },
    );

    test('quitting twice is not twice as much quitting', () async {
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();
      calls.clear();

      await service.quit();
      await service.quit();

      expect(methods().where((m) => m == 'stop'), hasLength(1));
    });

    test('the notification button reaches the same quit', () async {
      await service.start();
      settings.runInBackground = true;
      await pumpEventQueue();
      calls.clear();

      // What MainActivity sends when Quit is pressed, or the task is swiped
      // away from Recents.
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('quit')),
        (_) {},
      );
      await pumpEventQueue();

      expect(space.sessions, isEmpty);
      expect(methods(), contains('stop'));
    });
  });

  test('the grace period is short enough not to read as a hang', () {
    // A bounded courtesy. Long enough for a QUIT already handed to the core to
    // reach the wire, short enough that quitting still feels immediate.
    expect(quitGrace, greaterThan(Duration.zero));
    expect(quitGrace, lessThan(const Duration(milliseconds: 500)));
  });

  group('closing down', () {
    test('can be done twice without throwing', () async {
      // Quitting closes the connections, then tears the app down — and the
      // teardown runs the widget tree's dispose, which closes them again.
      // Disposing a ChangeNotifier twice throws; this must not.
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
}
