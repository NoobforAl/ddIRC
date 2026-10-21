// Tests for an XMPP account as a saved profile: that it is a Profile like any
// other and stays out of the way of IRC's, that its one password survives the
// store, and that it crosses a `.irc` file and back.
//
// The most important tests here are the ones about what did *not* change. Every
// profile on every device that has ever run ddIRC was saved before XMPP
// existed, and each of them has to read back as exactly what it was.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/ircconfig.dart';
import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;

const _keychain = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

Profile _account({
  String jid = 'alice@example.org',
  String host = '',
  int port = Profile.xmppDefaultPort,
  List<String> rooms = const [],
  String? personaId,
}) => Profile(
  id: 'x',
  name: jid,
  host: host,
  port: port,
  nickname: jid,
  channels: rooms,
  personaId: personaId,
  protocol: NetworkProtocol.xmpp,
);

Profile _irc() => const Profile(
  id: 'i',
  name: 'Libera',
  host: 'irc.libera.chat',
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

  group('what existing profiles read back as', () {
    test('a profile saved before XMPP existed is IRC', () {
      final profile = Profile.fromJson({
        'id': 'old',
        'name': 'Libera',
        'host': 'irc.libera.chat',
        'port': 6697,
        'nickname': 'ddirc',
      });
      expect(profile!.protocol, NetworkProtocol.irc);
      expect(profile.isXmpp, isFalse);
    });

    test('an unrecognised protocol is IRC, not an error', () {
      expect(NetworkProtocol.byName('gopher'), NetworkProtocol.irc);
      expect(NetworkProtocol.byName(null), NetworkProtocol.irc);
      expect(NetworkProtocol.byName(42), NetworkProtocol.irc);
    });

    test('an IRC network still needs a host and a port', () {
      expect(
        Profile.fromJson({'id': 'a', 'nickname': 'n', 'port': 6697}),
        isNull,
        reason: 'no host',
      );
      expect(
        Profile.fromJson({'id': 'a', 'nickname': 'n', 'host': 'h'}),
        isNull,
        reason: 'no port',
      );
    });

    test('an IRC network is unchanged by being stored', () {
      final back = Profile.fromJson(_irc().toJson());
      expect(back!.protocol, NetworkProtocol.irc);
      expect(back.host, 'irc.libera.chat');
      expect(back.usesPassword, isFalse);
    });
  });

  group('an XMPP account', () {
    test('round-trips through storage', () {
      final saved = _account(
        host: 'xmpp.hosting.example',
        port: 5443,
        rooms: ['lobby@conference.example.org'],
      );
      final back = Profile.fromJson(saved.toJson())!;
      expect(back.isXmpp, isTrue);
      expect(back.nickname, 'alice@example.org');
      expect(back.host, 'xmpp.hosting.example');
      expect(back.port, 5443);
      expect(back.channels, ['lobby@conference.example.org']);
    });

    test('needs no host and no port of its own', () {
      final profile = Profile.fromJson({
        'id': 'x',
        'protocol': 'xmpp',
        'nickname': 'alice@example.org',
      });
      expect(profile, isNotNull);
      expect(profile!.host, isEmpty);
      expect(profile.port, Profile.xmppDefaultPort);
    });

    test('is named for its address when nothing else names it', () {
      final profile = Profile.fromJson({
        'id': 'x',
        'protocol': 'xmpp',
        'nickname': 'alice@example.org',
      });
      expect(profile!.name, 'alice@example.org');
    });

    test('lives on the server its address names, unless told otherwise', () {
      expect(_account().serverName, 'example.org');
      expect(
        _account(host: 'xmpp.hosting.example').serverName,
        'xmpp.hosting.example',
      );
      expect(_irc().serverName, 'irc.libera.chat');
    });

    test('has no identity to hide behind', () {
      final profile = _account(personaId: 'someone');
      expect(profile.personaId, 'someone');
      expect(
        profile.usesPersona,
        isFalse,
        reason: 'a persona is a random IRC nick, not an address',
      );
    });

    test('always has a password to keep', () {
      expect(_account().usesPassword, isTrue);
      expect(_irc().usesPassword, isFalse);
      expect(_irc().copyWith(saslAccount: 'me').usesPassword, isTrue);
    });
  });

  group('the address', () {
    test('the domain is what follows the @', () {
      expect(jidDomain('alice@example.org'), 'example.org');
      expect(jidDomain('  alice@example.org  '), 'example.org');
    });

    test('a resource is not part of the domain', () {
      expect(jidDomain('alice@example.org/phone'), 'example.org');
      expect(jidDomain('alice@example.org/a@b'), 'example.org');
    });
  });

  group('what is wrong with an address', () {
    test('a good one has nothing wrong', () {
      expect(jidProblem('alice@example.org'), isNull);
      expect(jidProblem('  alice@example.org '), isNull);
      expect(jidProblem('alice@localhost'), isNull);
    });

    test('each common mistake is named', () {
      expect(jidProblem(''), contains('Enter your account address'));
      expect(jidProblem('alice'), contains('looks like name@example.org'));
      expect(jidProblem('@example.org'), contains('looks like'));
      expect(jidProblem('alice@'), contains('looks like'));
      expect(jidProblem('a@b@c'), contains('looks like'));
      expect(jidProblem('al ice@example.org'), contains('no spaces'));
      expect(jidProblem('alice@example.org/phone'), contains('Leave off'));
    });

    test('a good room has nothing wrong', () {
      expect(roomProblem('lobby@conference.example.org'), isNull);
    });

    test('an IRC channel is not a room, and says what one is', () {
      for (final bad in ['#lobby', 'lobby', 'lobby@', '@conf.example.org']) {
        expect(roomProblem(bad), contains('room@conference'), reason: bad);
      }
      expect(roomProblem('lobby@conf.example.org/nick'), isNotNull);
      expect(roomProblem('lo bby@conf.example.org'), isNotNull);
    });
  });

  group('the config the core connects with', () {
    test('carries the address, the password and the rooms', () {
      final config = _account(rooms: ['a@c.example.org'])
          .toXmppConfig(password: 'hunter2');
      expect(config.jid, 'alice@example.org');
      expect(config.password, 'hunter2');
      expect(config.rooms, ['a@c.example.org']);
    });

    test(
      'leaves the server and port to the core when they were not chosen',
      () {
        final config = _account().toXmppConfig(password: 'p');
        expect(config.host, isNull);
        expect(config.port, isNull);
      },
    );

    test('sends the server and port when they were', () {
      final config = _account(
        host: ' xmpp.hosting.example ',
        port: 5443,
      ).toXmppConfig(password: 'p');
      expect(config.host, 'xmpp.hosting.example');
      expect(config.port, 5443);
    });

    test('passes the resolved proxy through', () {
      const proxy = rust.ProxyConfig(host: '127.0.0.1', port: 9050);
      final config = _account().toXmppConfig(password: 'p', proxy: proxy);
      expect(config.proxy, proxy);
    });

    test('is described to the session in the shape it already reads', () {
      final display = _account(rooms: ['a@c.example.org']).toDisplayConfig();
      expect(display.host, 'example.org');
      expect(display.nickname, 'alice@example.org');
    });
  });

  group('the account password in the keychain', () {
    test('survives saving the account', () async {
      final store = await ProfileStore.load();
      await store.save(_account(), password: 'hunter2');
      expect(await store.passwordFor('x'), 'hunter2');
    });

    test(
      'survives saving it again without touching it - IRC would drop it here',
      () async {
        final store = await ProfileStore.load();
        await store.save(_account(), password: 'hunter2');
        // No `password:` this time, and no SASL account either: for an IRC
        // network that combination means the password has nothing to be used
        // with and is deleted. For an account it is the account's only secret.
        await store.save(_account(rooms: ['a@c.example.org']));
        expect(await store.passwordFor('x'), 'hunter2');
      },
    );

    test('is still dropped from an IRC network with no SASL account', () async {
      final store = await ProfileStore.load();
      await store.save(_irc(), password: 'orphan');
      expect(await store.passwordFor('i'), isNull);
    });

    test('is removed with the account', () async {
      final store = await ProfileStore.load();
      await store.save(_account(), password: 'hunter2');
      await store.remove('x');
      expect(await store.passwordFor('x'), isNull);
    });
  });

  group('the .irc file', () {
    test('an XMPP account round-trips', () {
      final text = writeIrcConfig([
        _account(host: 'xmpp.hosting.example', rooms: ['a@c.example.org']),
      ]);
      final back = parseIrcConfig(text).single.profile;
      expect(back.isXmpp, isTrue);
      expect(back.nickname, 'alice@example.org');
      expect(back.host, 'xmpp.hosting.example');
      expect(back.channels, ['a@c.example.org']);
    });

    test('says what protocol it is, and an IRC network does not', () {
      expect(writeIrcConfig([_account()]), contains('protocol: xmpp'));
      expect(
        writeIrcConfig([_irc()]),
        isNot(contains('protocol')),
        reason: 'a file of IRC networks is what it always was',
      );
    });

    test('a hand-written account needs only an address', () {
      final imported = parseIrcConfig('''
ddirc: 1
networks:
  - protocol: xmpp
    nickname: alice@example.org
''').single;
      expect(imported.profile.isXmpp, isTrue);
      expect(imported.profile.serverName, 'example.org');
      expect(imported.profile.port, Profile.xmppDefaultPort);
    });

    test('its password is the account password, not a server password', () {
      final imported = parseIrcConfig('''
ddirc: 1
networks:
  - protocol: xmpp
    nickname: alice@example.org
    password: hunter2
''').single;
      expect(imported.saslPassword, 'hunter2');
      expect(
        imported.serverPassword,
        isNull,
        reason: 'an account has no PASS to send',
      );
      expect(imported.carriesSecret, isTrue);
    });

    test('an IRC network keeps its meaning of password', () {
      final imported = parseIrcConfig('''
ddirc: 1
networks:
  - host: irc.example.org
    port: 6697
    nickname: ddirc
    password: hunter2
''').single;
      expect(imported.serverPassword, 'hunter2');
      expect(imported.saslPassword, isNull);
    });

    test('never writes the password back out', () {
      final text = writeIrcConfig([_account()]);
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('password')));
    });

    test('one file can hold both kinds', () {
      final text = writeIrcConfig([_irc(), _account()]);
      final back = parseIrcConfig(text).map((n) => n.profile).toList();
      expect(back.map((p) => p.protocol), [
        NetworkProtocol.irc,
        NetworkProtocol.xmpp,
      ]);
    });
  });
}
