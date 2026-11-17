// Tests for where reading starts.
//
// The unread *count* is zeroed the moment a tab is picked — before anything
// is on screen — which is why it cannot also say where the new messages
// begin. That is the marker's job: set by the first arrival while the user is
// elsewhere, kept through `markRead`, and forgotten only when they leave.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

ChatLine _said(String sender, String text, {String channel = '#test'}) =>
    ChatLine.message(
      rust.ChatMessage(
        target: rust.Target.channel(name: channel),
        sender: sender,
        spans: [rust.TextSpan(text: text, style: _plain)],
        isSelf: false,
        isMention: false,
        isAction: false,
        isNotice: false,
      ),
      DateTime(2026, 3, 1, 14, 30),
    );

ChatLine _joined(String nick) => ChatLine.system(
  '$nick joined',
  DateTime(2026, 3, 1, 14, 30),
  SystemKind.presence,
);

Conversation _conversation() => Conversation(name: '#test', isChannel: true);

Future<SessionModel> _session() async {
  SharedPreferences.setMockInitialValues({});
  return SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: const rust.ServerConfig(
      host: 'example.test',
      port: 6697,
      nickname: 'me',
      altNicks: [],
      channels: ['#one', '#two'],
    ),
    settings: await AppSettings.load(),
  );
}

void _join(SessionModel s, String channel) => s.receiveForTesting(
  rust.IrcEvent.joined(channel: channel, nick: 'me', isSelf: true),
);

void _speak(SessionModel s, String channel, String text) => s.receiveForTesting(
  rust.IrcEvent.message(
    message: _said('alice', text, channel: channel).message!,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Conversation', () {
    test('the first arrival while away becomes the marker, and stays it', () {
      final c = _conversation();
      final first = _said('alice', 'one');
      c.add(first, active: false);
      c.add(_said('alice', 'two'), active: false);
      expect(identical(c.unreadMarker, first), isTrue);
    });

    test('nothing read while looking, and no join, is a place to start', () {
      final c = _conversation();
      c.add(_joined('alice'), active: false);
      expect(c.unreadMarker, isNull, reason: 'a join is not news');
      c.add(_said('alice', 'hi'), active: true);
      expect(c.unreadMarker, isNull, reason: 'it was read as it arrived');
    });

    test('a muted channel still knows where its unread begins', () {
      final c = _conversation();
      final line = _said('alice', 'hi');
      c.add(line, active: false, notify: NotifyLevel.none);
      expect(c.unread, 0, reason: 'muted: no count');
      expect(identical(c.unreadMarker, line), isTrue, reason: 'but a place');
    });

    test('markRead zeroes the count and keeps the marker', () {
      final c = _conversation();
      final line = _said('alice', 'hi');
      c.add(line, active: false);
      c.markRead();
      expect(c.unread, 0);
      expect(identical(c.unreadMarker, line), isTrue);
    });

    test('once cleared, the next arrival sets a new one', () {
      final c = _conversation();
      c.add(_said('alice', 'old'), active: false);
      c.unreadMarker = null;
      final fresh = _said('alice', 'new');
      c.add(fresh, active: false);
      expect(identical(c.unreadMarker, fresh), isTrue);
    });

    test('restored history moves the index but not the line', () {
      final c = _conversation();
      final line = _said('alice', 'now');
      c.add(line, active: false);
      expect(c.lines.indexOf(line), 0);
      c.restore([_said('bob', 'yesterday'), _said('bob', 'and before')]);
      expect(c.lines.indexOf(line), 2);
      expect(identical(c.unreadMarker, line), isTrue);
    });

    test('the cap can trim the marker away, which the view must survive', () {
      final c = _conversation();
      final line = _said('alice', 'first');
      c.add(line, active: false);
      for (var i = 0; i < 2000; i++) {
        c.add(_said('alice', '$i'), active: false);
      }
      expect(c.lines.contains(line), isFalse);
      // Still held: it is the view that decides what a missing line means.
      expect(identical(c.unreadMarker, line), isTrue);
    });
  });

  group('SessionModel', () {
    test('opening a tab keeps its marker; leaving it forgets it', () async {
      final s = await _session();
      s.requestForTesting('#one');
      _join(s, '#one');
      s.requestForTesting('#two');
      _join(s, '#two');
      s.select('#two');

      _speak(s, '#one', 'hello?');
      final one = s.conversations.firstWhere((c) => c.name == '#one');
      expect(one.unread, 1);
      expect(one.unreadMarker, isNotNull);

      s.select('#one');
      expect(one.unread, 0, reason: 'picked, so read');
      expect(one.unreadMarker, isNotNull, reason: 'but still being read');

      s.select('#one');
      expect(
        one.unreadMarker,
        isNotNull,
        reason: 'picking it again is not leaving',
      );

      s.select('#two');
      expect(one.unreadMarker, isNull, reason: 'now it was left');
    });

    test(
      'closing the open tab is leaving it; closing another is not',
      () async {
        final s = await _session();
        s.requestForTesting('#one');
        _join(s, '#one');
        s.requestForTesting('#two');
        _join(s, '#two');
        s.select('#two');
        _speak(s, '#one', 'psst');
        final one = s.conversations.firstWhere((c) => c.name == '#one');

        s.closeTab('#one');
        expect(one.unreadMarker, isNotNull, reason: 'closed unread, not read');

        s.select('#one');
        s.closeTab('#one');
        expect(one.unreadMarker, isNull);
      },
    );
  });
}
