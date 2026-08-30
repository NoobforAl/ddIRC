// Tests for the secrets a saved profile carries: the SASL password, this
// network's own proxy password, the server password (PASS) and the NickServ
// password. All four live in the platform keychain, never in the plain
// preferences file, and each keeps to the same null/empty/value contract:
// null on save leaves what is stored alone, empty clears it, anything else
// replaces it.
//
// The keychain itself is stubbed with a small in-memory fake rather than the
// no-op used elsewhere, because these tests care about what a write then a
// read actually round-trips to, not just that the calls do not throw.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';

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
  final fakeKeychain = <String, String>{};

  setUp(() {
    fakeKeychain.clear();
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_keychain, (
      call,
    ) async {
      final key = call.arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          return fakeKeychain[key];
        case 'write':
          fakeKeychain[key!] = call.arguments['value'] as String;
          return null;
        case 'delete':
          fakeKeychain.remove(key);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_keychain, null);
  });

  group('server password', () {
    test('round-trips through save', () async {
      final store = await ProfileStore.load();
      await store.save(_profile('a'), serverPassword: 'hunter2');
      expect(await store.serverPasswordFor('a'), 'hunter2');
    });

    test('null leaves a stored value untouched', () async {
      final store = await ProfileStore.load();
      await store.save(_profile('a'), serverPassword: 'hunter2');
      await store.save(_profile('a').copyWith(nickname: 'other'));
      expect(await store.serverPasswordFor('a'), 'hunter2');
    });

    test('empty string deletes it', () async {
      final store = await ProfileStore.load();
      await store.save(_profile('a'), serverPassword: 'hunter2');
      await store.save(_profile('a'), serverPassword: '');
      expect(await store.serverPasswordFor('a'), isNull);
    });
  });

  group('NickServ password', () {
    test('round-trips through save', () async {
      final store = await ProfileStore.load();
      await store.save(_profile('a'), nickservPassword: 'swordfish');
      expect(await store.nickservPasswordFor('a'), 'swordfish');
    });

    test('null leaves a stored value untouched', () async {
      final store = await ProfileStore.load();
      await store.save(_profile('a'), nickservPassword: 'swordfish');
      await store.save(_profile('a').copyWith(nickname: 'other'));
      expect(await store.nickservPasswordFor('a'), 'swordfish');
    });

    test('empty string deletes it', () async {
      final store = await ProfileStore.load();
      await store.save(_profile('a'), nickservPassword: 'swordfish');
      await store.save(_profile('a'), nickservPassword: '');
      expect(await store.nickservPasswordFor('a'), isNull);
    });
  });

  test('remove clears every secret prefix, not just SASL and proxy', () async {
    final store = await ProfileStore.load();
    await store.save(
      _profile('a'),
      password: 'sasl-pw',
      proxyPassword: 'proxy-pw',
      serverPassword: 'server-pw',
      nickservPassword: 'nickserv-pw',
    );

    await store.remove('a');

    expect(await store.passwordFor('a'), isNull);
    expect(await store.proxyPasswordFor('a'), isNull);
    expect(await store.serverPasswordFor('a'), isNull);
    expect(await store.nickservPasswordFor('a'), isNull);
  });

  group('Profile.toConfig', () {
    test('carries both secrets through to ServerConfig', () {
      final config = _profile(
        'a',
      ).toConfig(serverPassword: 'server-pw', nickservPassword: 'nickserv-pw');
      expect(config.serverPassword, 'server-pw');
      expect(config.nickservPassword, 'nickserv-pw');
    });

    test('normalizes an empty string to null for both', () {
      final config = _profile(
        'a',
      ).toConfig(serverPassword: '', nickservPassword: '');
      expect(config.serverPassword, isNull);
      expect(config.nickservPassword, isNull);
    });

    test('omitting both leaves them null', () {
      final config = _profile('a').toConfig();
      expect(config.serverPassword, isNull);
      expect(config.nickservPassword, isNull);
    });
  });
}
