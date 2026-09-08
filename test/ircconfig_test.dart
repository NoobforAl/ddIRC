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

void main() {
  group('round trip', () {
    test('the fields every network has', () {
      final networks = parseIrcConfig(writeIrcConfig([_profile()]));
      expect(networks, hasLength(1));
      final network = networks.single;
      expect(network.name, 'Libera');
      expect(network.host, 'irc.libera.chat');
      expect(network.port, 6697);
      expect(network.nickname, 'ddirc');
    });

    test('a channel name is not read back as a comment', () {
      final networks = parseIrcConfig(
        writeIrcConfig([
          _profile(channels: const ['#ddirc', '#offtopic']),
        ]),
      );
      expect(networks.single.channels, ['#ddirc', '#offtopic']);
    });

    test('alternate nicknames', () {
      final networks = parseIrcConfig(
        writeIrcConfig([
          _profile(altNicks: const ['ddirc_', 'ddirc__']),
        ]),
      );
      expect(networks.single.altNicks, ['ddirc_', 'ddirc__']);
    });

    test('a SASL account, with no password beside it', () {
      final networks = parseIrcConfig(
        writeIrcConfig([_profile(saslAccount: 'alice')]),
      );
      expect(networks.single.saslAccount, 'alice');
    });

    test('a network set to connect directly', () {
      final networks = parseIrcConfig(
        writeIrcConfig([_profile(proxyMode: ProxyMode.direct)]),
      );
      expect(networks.single.proxyMode, ProxyMode.direct);
    });

    test('a network with its own proxy', () {
      final networks = parseIrcConfig(
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
      final networks = parseIrcConfig(
        writeIrcConfig([_profile(autoConnect: true)]),
      );
      expect(networks.single.autoConnect, isTrue);
    });

    test('more than one network in one file', () {
      final networks = parseIrcConfig(
        writeIrcConfig([
          _profile(name: 'Libera', host: 'irc.libera.chat'),
          _profile(name: 'OFTC', host: 'irc.oftc.net'),
        ]),
      );
      expect(networks.map((n) => n.name), ['Libera', 'OFTC']);
    });

    test('a fresh id, never the one that was written', () {
      final networks = parseIrcConfig(writeIrcConfig([_profile()]));
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
      expect(parseIrcConfig(text).map((n) => n.name), ['Fine']);
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
  });
}
