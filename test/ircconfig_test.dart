// Tests for the `.irc` file format: writing one or more profiles to YAML and
// reading them back. The two halves are tested together — a round trip — for
// everything but the malformed-input cases, because the format's only job is
// that what goes in one side is what comes out the other.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/ircconfig.dart';
import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';

Profile _profile({
  String name = 'Libera',
  String host = 'irc.libera.chat',
  int port = 6697,
  String nickname = 'ddirc',
  List<String> channels = const [],
  List<String> altNicks = const [],
  String? saslAccount,
  ProxyMode proxyMode = ProxyMode.followDefault,
  ProxyEndpoint? proxy,
  bool autoConnect = false,
}) => Profile(
  id: 'ignored',
  name: name,
  host: host,
  port: port,
  nickname: nickname,
  channels: channels,
  altNicks: altNicks,
  saslAccount: saslAccount,
  proxyMode: proxyMode,
  proxy: proxy,
  autoConnect: autoConnect,
);

/// The networks a file names, without their credentials — what every test
/// below the credentials group is actually about.
List<Profile> _parse(String source) =>
    parseIrcConfig(source).map((n) => n.profile).toList();

void main() {
  group('round trip', () {
    test('the fields every network has', () {
      final networks = _parse(writeIrcConfig([_profile()]));
      expect(networks, hasLength(1));
      final network = networks.single;
      expect(network.name, 'Libera');
      expect(network.host, 'irc.libera.chat');
      expect(network.port, 6697);
      expect(network.nickname, 'ddirc');
    });

    test('a channel name is not read back as a comment', () {
      final networks = _parse(
        writeIrcConfig([
          _profile(channels: const ['#ddirc', '#offtopic']),
        ]),
      );
      expect(networks.single.channels, ['#ddirc', '#offtopic']);
    });

    test('alternate nicknames', () {
      final networks = _parse(
        writeIrcConfig([
          _profile(altNicks: const ['ddirc_', 'ddirc__']),
        ]),
      );
      expect(networks.single.altNicks, ['ddirc_', 'ddirc__']);
    });

    test('a SASL account, with no password beside it', () {
      final networks = _parse(
        writeIrcConfig([_profile(saslAccount: 'alice')]),
      );
      expect(networks.single.saslAccount, 'alice');
    });

    test('a network set to connect directly', () {
      final networks = _parse(
        writeIrcConfig([_profile(proxyMode: ProxyMode.direct)]),
      );
      expect(networks.single.proxyMode, ProxyMode.direct);
    });

    test('a network with its own proxy', () {
      final networks = _parse(
        writeIrcConfig([
          _profile(
            proxyMode: ProxyMode.custom,
            proxy: const ProxyEndpoint(
              host: '127.0.0.1',
              port: 9050,
              username: 'bob',
            ),
          ),
        ]),
      );
      final network = networks.single;
      expect(network.proxyMode, ProxyMode.custom);
      expect(
        network.proxy,
        const ProxyEndpoint(host: '127.0.0.1', port: 9050, username: 'bob'),
      );
    });

    test('connect at launch', () {
      final networks = _parse(
        writeIrcConfig([_profile(autoConnect: true)]),
      );
      expect(networks.single.autoConnect, isTrue);
    });

    test('more than one network in one file', () {
      final networks = _parse(
        writeIrcConfig([
          _profile(name: 'Libera', host: 'irc.libera.chat'),
          _profile(name: 'OFTC', host: 'irc.oftc.net'),
        ]),
      );
      expect(networks.map((n) => n.name), ['Libera', 'OFTC']);
    });

    test('a fresh id, never the one that was written', () {
      final networks = _parse(writeIrcConfig([_profile()]));
      expect(networks.single.id, isNot('ignored'));
    });

    test('no password ever appears in the file', () {
      final text = writeIrcConfig([
        _profile(
          proxyMode: ProxyMode.custom,
          proxy: const ProxyEndpoint(
            host: '127.0.0.1',
            port: 9050,
            username: 'bob',
          ),
        ),
      ]);
      expect(text.toLowerCase(), isNot(contains('password')));
    });
  });

  group('malformed input', () {
    test('a network missing its host is dropped, not the whole file', () {
      final text = '''
ddirc: 1
networks:
  - name: 'Broken'
    port: 6697
    nickname: 'ddirc'
  - name: 'Fine'
    host: 'irc.oftc.net'
    port: 6697
    nickname: 'ddirc'
''';
      expect(_parse(text).map((n) => n.name), ['Fine']);
    });

    test('text that is not YAML throws', () {
      expect(() => parseIrcConfig('not: [valid'), throwsFormatException);
    });

    test('YAML with no networks key throws', () {
      expect(() => parseIrcConfig('ddirc: 1'), throwsFormatException);
    });

    test('an empty networks list throws', () {
      expect(
        () => parseIrcConfig('ddirc: 1\nnetworks: []'),
        throwsFormatException,
      );
    });

    test('a file whose every network is bad throws, rather than importing '
        'nothing at all', () {
      // This used to return an empty list, which opened the import screen
      // with nothing in it to show and no explanation.
      expect(
        () => parseIrcConfig(
          "ddirc: 1\nnetworks:\n  - name: 'X'\n    host: 'a'\n"
          "    port: '6697'\n    nickname: 'b'\n",
        ),
        throwsFormatException,
      );
    });
  });

  group('credentials', () {
    ImportedNetwork one(String body) => parseIrcConfig(
      "ddirc: 1\nnetworks:\n  - host: 'irc.libera.chat'\n    port: 6697\n"
      "    nickname: 'ddirc'\n$body",
    ).single;

    test('a server password, under either spelling', () {
      expect(one("    password: 'hunter2'\n").serverPassword, 'hunter2');
      expect(one("    serverPassword: 'hunter2'\n").serverPassword, 'hunter2');
    });

    test('the explicit spelling wins over the alias', () {
      final network = one(
        "    password: 'alias'\n    serverPassword: 'explicit'\n",
      );
      expect(network.serverPassword, 'explicit');
    });

    test('a SASL account and its password', () {
      final network = one(
        "    saslAccount: 'alice'\n    saslPassword: 'hunter2'\n",
      );
      expect(network.profile.saslAccount, 'alice');
      expect(network.saslPassword, 'hunter2');
    });

    test('a NickServ password', () {
      expect(one("    nickservPassword: 'hunter2'\n").nickservPassword,
          'hunter2');
    });

    test('a proxy password, nested where the proxy is', () {
      final network = one(
        "    proxyMode: 'custom'\n    proxy:\n      host: '127.0.0.1'\n"
        "      port: 9050\n      username: 'bob'\n      password: 'hunter2'\n",
      );
      expect(network.proxyPassword, 'hunter2');
      expect(network.profile.proxy?.username, 'bob');
    });

    test('an all-digit password is not lost to YAML reading it as a number',
        () {
      expect(one('    password: 123456\n').serverPassword, '123456');
    });

    test('an empty password is the same as none', () {
      expect(one("    password: ''\n").serverPassword, isNull);
    });

    test('a file with no credentials says so', () {
      expect(one('').carriesSecret, isFalse);
      expect(one("    password: 'x'\n").carriesSecret, isTrue);
    });

    test('no password ever survives a round trip back out', () {
      // The asymmetry that is the whole point: read one, never write one.
      final network = one(
        "    saslAccount: 'alice'\n    password: 'hunter2'\n"
        "    saslPassword: 'hunter2'\n    nickservPassword: 'hunter2'\n",
      );
      final text = writeIrcConfig([network.profile]);
      expect(text, isNot(contains('hunter2')));
      expect(text.toLowerCase(), isNot(contains('password')));
      expect(text, contains('alice'), reason: 'the account is not a secret');
    });

    test('a password is never on the Profile itself', () {
      final network = one(
        "    password: 'hunter2'\n    saslPassword: 'hunter2'\n",
      );
      expect('${network.profile.toJson()}', isNot(contains('hunter2')));
    });
  });
}
