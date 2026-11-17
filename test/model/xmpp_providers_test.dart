// Tests for the list of servers an XMPP account can be made on, and for the
// editor's way into it.
//
// The list is data, so most of what is tested is the rules the data must keep:
// the ones that, if broken, send someone to a page that is not encrypted or
// hand the app a server it would refuse. The editor half checks that choosing a
// server fills in where the account lives and nothing more.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/workspace.dart';
import 'package:ddirc/src/model/xmpp_providers.dart';
import 'package:ddirc/src/rust/frb_generated.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/profile_editor_dialog.dart';
import 'package:ddirc/src/ui/settings/settings_chrome.dart';

const _keychain = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

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

  group('the list', () {
    test('every sign-up page is https, with no credentials in it', () {
      for (final p in xmppProviders) {
        final uri = Uri.parse(p.signUpUrl);
        expect(uri.isScheme('https'), isTrue, reason: p.name);
        expect(uri.userInfo, isEmpty, reason: p.name);
        expect(uri.host, isNotEmpty, reason: p.name);
      }
    });

    test('every domain makes an address the app accepts', () {
      for (final p in xmppProviders) {
        expect(jidProblem('someone@${p.domain}'), isNull, reason: p.name);
        expect(p.domain, p.domain.toLowerCase(), reason: p.name);
      }
    });

    test('a server to dial is a name, without a port stuck on it', () {
      for (final p in xmppProviders) {
        final host = p.host;
        if (host == null) continue;
        expect(host.contains(':'), isFalse, reason: p.name);
        expect(host.contains(' '), isFalse, reason: p.name);
        expect(
          RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host),
          isFalse,
          reason: '${p.name}: a name, so a certificate can be checked',
        );
      }
    });

    test('and never port 5222, which starts in plaintext', () {
      for (final p in xmppProviders) {
        final port = p.port;
        if (port == null) continue;
        expect(port, isNot(5222), reason: p.name);
        expect(port, inInclusiveRange(1, 65535), reason: p.name);
      }
    });

    test('each says something, and no two are the same', () {
      expect(
        xmppProviders.map((p) => p.name).toSet(),
        hasLength(xmppProviders.length),
      );
      expect(
        xmppProviders.map((p) => p.domain).toSet(),
        hasLength(xmppProviders.length),
      );
      for (final p in xmppProviders) {
        expect(p.blurb.trim(), isNotEmpty, reason: p.name);
      }
    });

    test('in alphabetical order, so no one is ranked above another', () {
      final names = xmppProviders.map((p) => p.name.toLowerCase()).toList();
      expect(names, [...names]..sort());
    });

    test('a server needs filling in only where it is not at its domain', () {
      for (final p in xmppProviders) {
        expect(p.needsServer, p.host != null || p.port != null, reason: p.name);
      }
    });

    test('searching finds by name or domain, ignoring case', () {
      expect(searchXmppProviders('JIX').map((p) => p.name), ['jix.im']);
      expect(searchXmppProviders('5222').map((p) => p.domain), ['5222.de']);
      expect(searchXmppProviders(''), xmppProviders);
      expect(searchXmppProviders('no such server'), isEmpty);
    });
  });

  group('the editor', () {
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

    Future<void> open(WidgetTester tester, {Profile? profile}) async {
      tester.view.physicalSize = const Size(1400, 1800);
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
    }

    Finder field(String label) => find.descendant(
      of: find.widgetWithText(SettingsLabelledField, label),
      matching: find.byType(EditableText),
    );

    String text(WidgetTester tester, String label) =>
        tester.widget<EditableText>(field(label)).controller.text;

    testWidgets('IRC has no such button, and an account being edited neither', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('No account yet? Choose a server'), findsNothing);
      await tester.tap(find.text('XMPP'));
      await tester.pumpAndSettle();
      expect(find.text('No account yet? Choose a server'), findsOneWidget);
    });

    testWidgets('an existing account is not sent shopping', (tester) async {
      await open(
        tester,
        profile: const Profile(
          id: 'x',
          name: 'alice@example.org',
          host: '',
          port: Profile.xmppDefaultPort,
          nickname: 'alice@example.org',
          protocol: NetworkProtocol.xmpp,
        ),
      );
      expect(find.text('No account yet? Choose a server'), findsNothing);
    });

    testWidgets('choosing a server fills in its domain and where to dial', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('XMPP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No account yet? Choose a server'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a server'), findsOneWidget);
      for (final p in xmppProviders) {
        expect(find.text(p.name), findsOneWidget);
      }
      // The second of the three: one that is dialled elsewhere, on 443.
      await tester.tap(find.text('I have an account here').at(2));
      await tester.pumpAndSettle();

      expect(text(tester, 'Address'), '@jix.im');
      expect(text(tester, 'Server'), 'xmpp.jix.im');
      expect(text(tester, 'Port'), '443');
    });

    testWidgets(
      'a name already typed is kept, and the domain is the chosen one',
      (tester) async {
        await open(tester);
        await tester.tap(find.text('XMPP'));
        await tester.pumpAndSettle();
        await tester.enterText(field('Address'), 'alice@somewhere.else');
        await tester.pump();
        await tester.tap(find.text('No account yet? Choose a server'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('I have an account here').at(1));
        await tester.pumpAndSettle();

        expect(text(tester, 'Address'), 'alice@jabbers.one');
        // At its own domain on the usual port: nothing more to say. The fields
        // for it are behind Advanced, which this choice had no reason to open.
        expect(find.text('Server'), findsNothing);
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();
        expect(text(tester, 'Server'), '');
        expect(text(tester, 'Port'), '${Profile.xmppDefaultPort}');
      },
    );

    testWidgets('closing the list changes nothing', (tester) async {
      await open(tester);
      await tester.tap(find.text('XMPP'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Address'), 'alice@example.org');
      await tester.pump();
      await tester.tap(find.text('No account yet? Choose a server'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(text(tester, 'Address'), 'alice@example.org');
    });
  });
}
