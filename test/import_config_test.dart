// Tests for the import screen: the last place a network can be looked at
// before it is saved, and now the place its credentials are settled.
//
// The invariant worth pinning is where a password ends up. A `.irc` file may
// carry one, and the moment it does there are two stores it could plausibly
// land in — the plain settings store that holds the profile, and the keychain.
// Only one of those is acceptable, and no test above this one would notice if
// it changed: `ProfileStore.save` would still succeed, the network would still
// appear, and the password would simply be readable by anything that can read
// app settings.
//
// So these check the destination rather than the outcome: what was written to
// the keychain channel, under which key, and that the profile written beside
// it does not mention the password at all.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/ircconfig.dart';
import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/import_config_dialog.dart';
import 'package:ddirc/src/ui/settings/settings_chrome.dart';

const _keychain = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// A file naming one complete network, credentials and all.
const _withPasswords = '''
ddirc: 1
networks:
  - name: 'Libera'
    host: 'irc.libera.chat'
    port: 6697
    nickname: 'ddirc'
    saslAccount: 'alice'
    password: 'serverpass'
    saslPassword: 'saslpass'
    nickservPassword: 'nickservpass'
''';

const _withoutPasswords = '''
ddirc: 1
networks:
  - name: 'Libera'
    host: 'irc.libera.chat'
    port: 6697
    nickname: 'ddirc'
  - name: 'OFTC'
    host: 'irc.oftc.net'
    port: 6697
    nickname: 'ddirc'
''';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  /// Everything written to the keychain, by key. The real one is not there in
  /// a test host, and what reached it is the whole point of these tests.
  late Map<String, String?> keychain;

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
          keychain[key!] = args['value'] as String?;
          return true;
        case 'delete':
          keychain.remove(key);
          return true;
      }
      return true;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_keychain, null);
  });

  /// Open the import screen over a store, the way the workspace does.
  Future<ProfileStore> open(WidgetTester tester, String config) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = await ProfileStore.load();
    final networks = parseIrcConfig(config);

    await tester.pumpWidget(
      ProfileScope(
        store: store,
        child: MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => ImportConfigDialog.show(context, networks),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return store;
  }

  /// Open the row's credentials. There is one chevron per network.
  Future<void> expand(WidgetTester tester, {int at = 0}) async {
    await tester.tap(find.byIcon(Icons.expand_more).at(at));
    await tester.pumpAndSettle();
  }

  group('what the file brought', () {
    testWidgets('every network is listed and ticked', (tester) async {
      await open(tester, _withoutPasswords);

      expect(find.text('Libera'), findsOneWidget);
      expect(find.text('OFTC'), findsOneWidget);
      expect(find.text('Import 2'), findsOneWidget);
    });

    testWidgets('unticking one narrows what will be saved', (tester) async {
      final store = await open(tester, _withoutPasswords);

      await tester.tap(find.text('OFTC'));
      await tester.pumpAndSettle();
      expect(find.text('Import 1 of 2'), findsOneWidget);

      await tester.tap(find.text('Import 1 of 2'));
      await tester.pumpAndSettle();
      expect(store.profiles.map((p) => p.name), ['Libera']);
    });

    testWidgets('passwords from the file prefill the fields', (tester) async {
      await open(tester, _withPasswords);
      await expand(tester);

      // Each is in its own field rather than pooled, so a file that set only
      // one does not look like it set them all.
      expect(find.text('serverpass'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('saslpass'), findsOneWidget);
      expect(find.text('nickservpass'), findsOneWidget);
    });

    testWidgets('a file with a password in it says so', (tester) async {
      await open(tester, _withPasswords);
      expect(find.textContaining('still plain text'), findsOneWidget);
    });

    testWidgets('a file without one does not', (tester) async {
      await open(tester, _withoutPasswords);
      expect(find.textContaining('still plain text'), findsNothing);
      expect(find.textContaining('No passwords came with'), findsOneWidget);
    });
  });

  group('what the user is told', () {
    testWidgets('where a password goes is said beside the fields, not '
        'behind a help dot', (tester) async {
      await open(tester, _withPasswords);
      expect(find.byType(SecretStorageNote), findsNothing);

      await expand(tester);
      expect(find.byType(SecretStorageNote), findsOneWidget);
      expect(find.textContaining('device keychain'), findsWidgets);
    });

    testWidgets('and it is said for every network, not once for the file', (
      tester,
    ) async {
      await open(tester, _withoutPasswords);
      await expand(tester);
      await expand(tester, at: 1);

      expect(find.byType(SecretStorageNote), findsNWidgets(2));
    });

    testWidgets('a file with no passwords still says where one would go', (
      tester,
    ) async {
      await open(tester, _withoutPasswords);
      expect(
        find.textContaining('stored as a secret in the device keychain'),
        findsOneWidget,
      );
    });

    testWidgets('and a file carrying one says where it lands', (tester) async {
      await open(tester, _withPasswords);
      expect(find.textContaining('stored as secrets'), findsOneWidget);
    });
  });

  group('where the passwords go', () {
    testWidgets('into the keychain, under the profile id', (tester) async {
      final store = await open(tester, _withPasswords);

      await tester.tap(find.text('Import 1'));
      await tester.pumpAndSettle();

      final id = store.profiles.single.id;
      expect(keychain['server-pass.$id'], 'serverpass');
      expect(keychain['sasl.$id'], 'saslpass');
      expect(keychain['nickserv.$id'], 'nickservpass');
    });

    testWidgets('and never onto the profile itself', (tester) async {
      final store = await open(tester, _withPasswords);

      await tester.tap(find.text('Import 1'));
      await tester.pumpAndSettle();

      final saved = store.profiles.single;
      expect(saved.saslAccount, 'alice', reason: 'the account is not a secret');
      expect('${saved.toJson()}', isNot(contains('serverpass')));
      expect('${saved.toJson()}', isNot(contains('saslpass')));
      expect('${saved.toJson()}', isNot(contains('nickservpass')));
    });

    testWidgets('an edit made here wins over what the file said', (
      tester,
    ) async {
      final store = await open(tester, _withPasswords);
      await expand(tester);

      await tester.enterText(find.text('serverpass'), 'corrected');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import 1'));
      await tester.pumpAndSettle();

      expect(keychain['server-pass.${store.profiles.single.id}'], 'corrected');
    });

    testWidgets('clearing the SASL account drops its password with it', (
      tester,
    ) async {
      final store = await open(tester, _withPasswords);
      await expand(tester);

      await tester.enterText(find.text('alice'), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import 1'));
      await tester.pumpAndSettle();

      // ProfileStore clears a SASL password that has no account to belong to,
      // and that has to hold for a network arriving this way too.
      final id = store.profiles.single.id;
      expect(store.profiles.single.usesSasl, isFalse);
      expect(keychain['sasl.$id'], isNull);
      expect(keychain['server-pass.$id'], 'serverpass');
    });

    testWidgets('nothing is written for a network left unticked', (
      tester,
    ) async {
      await open(tester, _withPasswords);

      // The address line rather than the name: with one network the name is
      // also the dialog's subtitle, and there is only one row to hit.
      await tester.tap(find.text('irc.libera.chat:6697 · ddirc'));
      await tester.pumpAndSettle();
      expect(find.text('Import 0 of 1'), findsOneWidget);

      // The import button is the only way out that saves, and it is off.
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('Import 0 of 1'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(keychain, isEmpty);
    });
  });
}
