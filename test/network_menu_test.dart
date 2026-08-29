// Tests for the context menu on a saved network.
//
// The gesture is the interesting half. Right-click and long-press are the same
// question asked by two input devices, and until now they were wired to two
// separate callbacks that a caller could easily give different answers to — or
// forget one of. These check that both openings reach the same menu, from both
// surfaces that list networks.
//
// The other half is that deleting asks first. The editor's Delete button sits
// at the bottom of a form; this one is one click from a row, and a row is an
// easy thing to click by accident.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/workspace.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/network_rail.dart';
import 'package:ddirc/src/ui/workspace_screen.dart';

/// The keychain, which a test host does not have. Deleting a profile writes
/// its stored passwords away, so this has to answer.
const _keychain = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

Profile _profile(String id) => Profile(
  id: id,
  name: id,
  host: '$id.example.org',
  port: 6697,
  nickname: 'ddirc',
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late ProfileStore store;

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

  /// The whole screen with one saved network and nothing connected, which is
  /// the state where both the rail and the list on the empty screen are up.
  Future<void> pump(WidgetTester tester) async {
    // Wide enough that the rail is pinned rather than folded into a drawer —
    // the drawer only exists once something is connected, and nothing here is.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    store = await ProfileStore.load();
    await store.save(_profile('libera'));
    final workspace = Workspace(
      profiles: store,
      settings: await AppSettings.load(),
      proxies: await ProxySettings.load(),
    );
    addTearDown(workspace.dispose);

    // Scopes above the app, exactly as `main.dart` nests them. Dialogs are
    // built by the navigator, which is inside MaterialApp — put the scopes
    // under `home:` and every dialog that reads one asserts.
    await tester.pumpWidget(
      SettingsScope(
        settings: workspace.settings,
        child: ProfileScope(
          store: store,
          child: WorkspaceScope(
            workspace: workspace,
            child: MaterialApp(
              theme: Tokens.themeFor(Tokens.dark),
              home: const WorkspaceScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The mark in the rail, which is the network's initials.
  final railEntry = find.descendant(
    of: find.byType(NetworkRail),
    matching: find.text('LI'),
  );

  /// The row on the empty screen, found by the address rather than the name:
  /// the name is also what the menu's Delete item says, and a finder that
  /// matches both cannot tell you the menu opened.
  final listRow = find.text('libera.example.org:6697');

  void expectMenu() {
    expect(find.text('Edit network…'), findsOneWidget);
    expect(find.text('Delete libera…'), findsOneWidget);
  }

  group('opening it', () {
    testWidgets('right-clicking a network in the rail', (tester) async {
      await pump(tester);
      await tester.tap(railEntry, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expectMenu();
    });

    testWidgets('long-pressing a network in the rail', (tester) async {
      await pump(tester);
      await tester.longPress(railEntry);
      await tester.pumpAndSettle();
      expectMenu();
    });

    testWidgets('right-clicking a network on the empty screen', (tester) async {
      await pump(tester);
      await tester.tap(listRow, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expectMenu();
    });

    testWidgets('long-pressing a network on the empty screen', (tester) async {
      await pump(tester);
      await tester.longPress(listRow);
      await tester.pumpAndSettle();
      expectMenu();
    });

    testWidgets('a plain tap opens no menu', (tester) async {
      await pump(tester);
      // Left-clicking the rail selects, and on the empty screen it dials.
      // Neither may put a menu on screen on the way past.
      await tester.tap(railEntry);
      await tester.pumpAndSettle();
      expect(find.text('Edit network…'), findsNothing);
    });
  });

  group('deleting', () {
    /// Open the menu and choose Delete, stopping at the confirmation.
    Future<void> ask(WidgetTester tester) async {
      await tester.longPress(listRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete libera…'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks before it does anything', (tester) async {
      await pump(tester);
      await ask(tester);

      expect(find.text('Delete libera?'), findsOneWidget);
      // Still saved: the question has been asked, not answered.
      expect(store.profiles, hasLength(1));
    });

    testWidgets('keeping it changes nothing', (tester) async {
      await pump(tester);
      await ask(tester);

      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      expect(find.text('Delete libera?'), findsNothing);
      expect(store.profiles.map((p) => p.id), ['libera']);
    });

    testWidgets('going through with it forgets the network', (tester) async {
      await pump(tester);
      await ask(tester);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(store.profiles, isEmpty);
      // And the row it was invoked from is gone with it.
      expect(listRow, findsNothing);
    });
  });
}
