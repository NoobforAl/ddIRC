// Tests for connecting at launch.
//
// Two things carry a decision here and both are worth pinning. The first is
// that this is off, and stays off for every profile saved before it existed —
// opening connections nobody asked for is a default you opt into. The second
// is the order, because it decides which network the app opens into, and
// leaving that to whichever server answered fastest would make the answer
// different every morning.
//
// The connecting itself crosses the FFI and cannot run here.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/workspace.dart';

Profile _profile(String id, {bool auto = false}) => Profile(
  id: id,
  name: id,
  host: '$id.example.org',
  port: 6697,
  nickname: 'ddirc',
  autoConnect: auto,
);

/// The keychain, which a test host does not have.
///
/// Stubbed rather than left to fail: the store already survives a missing
/// keychain by logging and carrying on, which is right in production and a
/// wall of noise in a test run. This gives it somewhere to write instead.
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

  Future<Workspace> workspaceWith(List<Profile> saved) async {
    final profiles = await ProfileStore.load();
    for (final profile in saved) {
      await profiles.save(profile);
    }
    return Workspace(
      profiles: profiles,
      settings: await AppSettings.load(),
      proxies: await ProxySettings.load(),
    );
  }

  group('the setting', () {
    test('is off by default', () {
      expect(_profile('a').autoConnect, isFalse);
    });

    test('round-trips', () {
      final back = Profile.fromJson(_profile('a', auto: true).toJson());
      expect(back?.autoConnect, isTrue);
    });

    test('reads as off on a profile saved before it existed', () {
      // The upgrade path. Anything else would open connections on the first
      // launch after an update that the user never asked for.
      final back = Profile.fromJson({
        'id': 'a',
        'name': 'a',
        'host': 'a.example.org',
        'port': 6697,
        'nickname': 'ddirc',
      });
      expect(back?.autoConnect, isFalse);
    });

    test('survives an edit that does not mention it', () {
      final edited = _profile('a', auto: true).copyWith(nickname: 'other');
      expect(edited.autoConnect, isTrue);
    });
  });

  group('what launches', () {
    test('nothing, when nothing is marked', () async {
      final workspace = await workspaceWith([_profile('a'), _profile('b')]);
      expect(workspace.automatic, isEmpty);
    });

    test('only the marked ones', () async {
      final workspace = await workspaceWith([
        _profile('a'),
        _profile('b', auto: true),
        _profile('c'),
      ]);
      expect(workspace.automatic.map((p) => p.id), ['b']);
    });

    test('in saved order, which is what decides where you land', () async {
      // The first of these takes the selection. If this list came back in
      // another order the app would open into a different network depending
      // on how the profiles happened to be stored.
      final workspace = await workspaceWith([
        _profile('first', auto: true),
        _profile('skipped'),
        _profile('second', auto: true),
      ]);
      expect(workspace.automatic.map((p) => p.id), ['first', 'second']);
    });

    test('runs once per launch, however often it is asked', () async {
      final workspace = await workspaceWith([_profile('a')]);
      expect(workspace.startedAutomatic, isFalse);

      await workspace.connectAutomatic();
      expect(workspace.startedAutomatic, isTrue);

      // A second call must not open a second set of connections.
      await workspace.connectAutomatic();
      expect(workspace.startedAutomatic, isTrue);
    });
  });
}
