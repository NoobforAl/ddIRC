// Tests for the account editor: choosing XMPP when adding, what the form asks
// for, what it refuses, and what it saves.
//
// The editor is one dialog for both protocols rather than two, so the risk is
// less that the XMPP form is wrong than that it leaks into the IRC one - or the
// reverse - which is why a few of these assert what is *absent*.
//
// The core's two constants the editor reads at build time are answered by a
// stand-in for the native library; nothing here dials anything.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/workspace.dart';
import 'package:ddirc/src/rust/frb_generated.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/profile_editor_dialog.dart';
import 'package:ddirc/src/ui/settings/settings_chrome.dart';

const _keychain = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// The two native answers the editor asks for while it builds. Anything else
/// reaching the library is a test doing more than it means to, and fails.
class _FakeCore implements RustLibApi {
  @override
  int crateApiClientDefaultTlsPort() => 6697;

  @override
  int crateApiClientTorSocksPort() => 9050;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> keychain;

  setUpAll(() => RustLib.initMock(api: _FakeCore()));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keychain = {};
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_keychain, (
      call,
    ) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return keychain[key];
        case 'write':
          keychain[key!] = args['value'] as String;
          return null;
        case 'delete':
          keychain.remove(key);
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_keychain, null);
  });

  /// Open the editor over a real store, the way the app does.
  Future<ProfileStore> open(WidgetTester tester, {Profile? profile}) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = await ProfileStore.load();
    if (profile != null) await store.save(profile);
    final proxies = await ProxySettings.load();
    final workspace = Workspace(
      profiles: store,
      settings: await AppSettings.load(),
      proxies: proxies,
    );

    await tester.pumpWidget(
      ProfileScope(
        store: store,
        child: ProxyScope(
          settings: proxies,
          child: WorkspaceScope(
            workspace: workspace,
            child: MaterialApp(
              theme: Tokens.themeFor(Tokens.dark),
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      ProfileEditorDialog.show(context, profile: profile),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return store;
  }

  Finder field(String label) => find.descendant(
    of: find.widgetWithText(SettingsLabelledField, label),
    matching: find.byType(EditableText),
  );

  Future<void> choose(WidgetTester tester, String protocol) async {
    await tester.tap(find.text(protocol));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String label, String text) async {
    await tester.enterText(field(label), text);
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
  }

  Profile account({String password = 'hunter2'}) => const Profile(
    id: 'x',
    name: 'alice@example.org',
    host: '',
    port: Profile.xmppDefaultPort,
    nickname: 'alice@example.org',
    protocol: NetworkProtocol.xmpp,
  );

  group('adding', () {
    testWidgets('offers the choice, and IRC is what is shown first', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('IRC'), findsOneWidget);
      expect(find.text('XMPP'), findsOneWidget);
      expect(find.text('Add a network'), findsOneWidget);
      expect(field('Nickname'), findsOneWidget);
    });

    testWidgets('XMPP swaps the form for an address and a password', (
      tester,
    ) async {
      await open(tester);
      await choose(tester, 'XMPP');

      expect(find.text('Add an account'), findsOneWidget);
      expect(field('Address'), findsOneWidget);
      expect(field('Password'), findsOneWidget);
      expect(field('Rooms'), findsOneWidget);

      // None of IRC's three kinds of password, and no nickname to pick.
      expect(field('Nickname'), findsNothing);
      expect(find.text('NickServ password'), findsNothing);
      expect(find.text('SASL account'), findsNothing);
    });

    testWidgets('switching back restores the IRC form', (tester) async {
      await open(tester);
      await choose(tester, 'XMPP');
      await choose(tester, 'IRC');
      expect(field('Nickname'), findsOneWidget);
      expect(field('Password'), findsNothing);
    });
  });

  group('refusing', () {
    testWidgets('an address with no name before the @', (tester) async {
      final store = await open(tester);
      await choose(tester, 'XMPP');
      await type(tester, 'Address', 'example.org');
      await type(tester, 'Password', 'hunter2');
      await save(tester);

      expect(find.textContaining('looks like name@example.org'), findsWidgets);
      expect(store.profiles, isEmpty);
    });

    testWidgets('an address with a resource, rather than trimming it', (
      tester,
    ) async {
      final store = await open(tester);
      await choose(tester, 'XMPP');
      await type(tester, 'Address', 'alice@example.org/phone');
      await type(tester, 'Password', 'hunter2');
      await save(tester);

      expect(find.textContaining('Leave off anything after'), findsOneWidget);
      expect(store.profiles, isEmpty);
    });

    testWidgets('a missing password, for a new account', (tester) async {
      final store = await open(tester);
      await choose(tester, 'XMPP');
      await type(tester, 'Address', 'alice@example.org');
      await save(tester);

      expect(find.textContaining("account's password"), findsOneWidget);
      expect(store.profiles, isEmpty);
    });

    testWidgets('an IRC channel where a room belongs', (tester) async {
      final store = await open(tester);
      await choose(tester, 'XMPP');
      await type(tester, 'Address', 'alice@example.org');
      await type(tester, 'Password', 'hunter2');
      await type(tester, 'Rooms', '#lobby');
      await save(tester);

      expect(find.textContaining('not a room address'), findsOneWidget);
      expect(store.profiles, isEmpty);
    });

    testWidgets('the port where servers start in plaintext', (tester) async {
      final store = await open(tester);
      await choose(tester, 'XMPP');
      await type(tester, 'Address', 'alice@example.org');
      await type(tester, 'Password', 'hunter2');
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      await type(tester, 'Port', '5222');
      await save(tester);

      expect(find.textContaining('starts in plaintext'), findsWidgets);
      expect(store.profiles, isEmpty);
    });
  });

  group('saving', () {
    testWidgets('keeps the account and puts its password in the keychain', (
      tester,
    ) async {
      final store = await open(tester);
      await choose(tester, 'XMPP');
      await type(tester, 'Address', 'alice@example.org');
      await type(tester, 'Password', 'hunter2');
      await type(
        tester,
        'Rooms',
        'lobby@conference.example.org, dev@conference.example.org',
      );
      await save(tester);

      final saved = store.profiles.single;
      expect(saved.isXmpp, isTrue);
      expect(saved.nickname, 'alice@example.org');
      expect(
        saved.name,
        'alice@example.org',
        reason: 'unnamed takes the address',
      );
      expect(saved.host, isEmpty, reason: 'the address names the server');
      expect(saved.port, Profile.xmppDefaultPort);
      expect(saved.channels, [
        'lobby@conference.example.org',
        'dev@conference.example.org',
      ]);
      expect(saved.usesPersona, isFalse);

      // The password went to the keychain under the profile's id, and the
      // profile that was written to settings does not mention it.
      expect(keychain.values, contains('hunter2'));
      expect(saved.toJson().toString(), isNot(contains('hunter2')));
    });

    testWidgets('lands the port on 5223 without being told', (tester) async {
      await open(tester);
      await choose(tester, 'XMPP');
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      final port = tester.widget<EditableText>(field('Port'));
      expect(port.controller.text, '5223');
    });

    testWidgets('an IRC network saved afterwards is unaffected', (
      tester,
    ) async {
      final store = await open(tester);
      await type(tester, 'Address', 'irc.example.org');
      await type(tester, 'Nickname', 'ddirc');
      await save(tester);

      final saved = store.profiles.single;
      expect(saved.protocol, NetworkProtocol.irc);
      expect(saved.host, 'irc.example.org');
      expect(saved.port, 6697);
    });
  });

  group('editing', () {
    testWidgets('an account offers no protocol choice, and says it is one', (
      tester,
    ) async {
      await open(tester, profile: account());
      expect(find.text('Edit account'), findsOneWidget);
      expect(find.text('XMPP'), findsNothing);
      expect(field('Address'), findsOneWidget);
    });

    testWidgets('a blank password means keep the stored one', (tester) async {
      final store = await open(tester, profile: account());
      await store.save(account(), password: 'stored-secret');
      await type(tester, 'Address', 'alice@example.org');
      await save(tester);

      expect(await store.passwordFor('x'), 'stored-secret');
    });
  });
}
