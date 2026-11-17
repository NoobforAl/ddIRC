// Tests for an XMPP account where the session model meets the app: that rooms
// are channels and people are conversations although neither looks like the
// IRC names the model was built around, and that what the user types is sent
// the way each protocol can carry it.
//
// The core reports both protocols through one event shape, so most of the model
// needs no change. The tests here are about the few places that read a name or
// the text of a message and used to assume IRC.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/chat_state.dart';
import 'package:ddirc/src/model/history.dart';
import 'package:ddirc/src/model/marks.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/rust/frb_generated.dart';

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

const _room = 'lobby@conference.example.org';

/// Records what the session sends, and answers nothing else: a call this test
/// did not mean to cause fails.
class _FakeCore implements RustLibApi {
  final sent = <({String target, String text})>[];

  @override
  Future<void> crateApiClientSendMessage({
    required BigInt id,
    required String target,
    required String text,
  }) async => sent.add((target: target, text: text));

  @override
  Future<void> crateApiClientSendAction({
    required BigInt id,
    required String target,
    required String text,
  }) async => sent.add((target: target, text: '/me $text'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SessionModel> _session({
  required bool xmpp,
  bool markdown = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load();
  settings.markdown = markdown;
  return SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: rust.ServerConfig(
      host: xmpp ? 'example.org' : 'irc.example.org',
      port: xmpp ? 5223 : 6697,
      nickname: xmpp ? 'alice@example.org' : 'alice',
      altNicks: const [],
      channels: const [],
    ),
    settings: settings,
    isXmpp: xmpp,
  );
}

rust.IrcEvent _joined(String channel) =>
    rust.IrcEvent.joined(channel: channel, nick: 'alice', isSelf: true);

rust.IrcEvent _said({
  required rust.Target target,
  required String sender,
  required String text,
}) => rust.IrcEvent.message(
  message: rust.ChatMessage(
    target: target,
    sender: sender,
    spans: [rust.TextSpan(text: text, style: _plain)],
    isSelf: false,
    isMention: false,
    isAction: false,
    isNotice: false,
  ),
);

Conversation _named(SessionModel s, String name) =>
    s.conversations.firstWhere((c) => c.name == name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeCore core;

  setUpAll(() {
    core = _FakeCore();
    RustLib.initMock(api: core);
  });

  setUp(() {
    core.sent.clear();
    MessageHistory.instance.resetForTest();
    ConversationStates.instance.resetForTest();
    Marks.instance.resetForTest();
  });

  group('rooms and people', () {
    test(
      'a room is a channel although its name does not look like one',
      () async {
        final s = await _session(xmpp: true);
        s.receiveForTesting(_joined(_room));
        expect(_named(s, _room).isChannel, isTrue);
      },
    );

    test('what is said in a room goes to the room', () async {
      final s = await _session(xmpp: true);
      s.receiveForTesting(_joined(_room));
      s.receiveForTesting(
        _said(
          target: const rust.Target.channel(name: _room),
          sender: 'bob',
          text: 'hello room',
        ),
      );
      final room = _named(s, _room);
      expect(room.lines.whereType<ChatLine>().isNotEmpty, isTrue);
      expect(room.pending, isFalse, reason: 'a room is not a stranger');
    });

    test('a first message from a stranger is a request, as on IRC', () async {
      final s = await _session(xmpp: true);
      s.receiveForTesting(
        _said(
          target: const rust.Target.direct(nick: 'carol@example.net'),
          sender: 'carol@example.net',
          text: 'hi',
        ),
      );
      final carol = _named(s, 'carol@example.net');
      expect(carol.isChannel, isFalse);
      expect(carol.pending, isTrue, reason: 'consent applies to people');
    });

    test('and accepting one lets them in', () async {
      final s = await _session(xmpp: true);
      s.receiveForTesting(
        _said(
          target: const rust.Target.direct(nick: 'carol@example.net'),
          sender: 'carol@example.net',
          text: 'hi',
        ),
      );
      s.acceptDirect('carol@example.net');
      expect(_named(s, 'carol@example.net').pending, isFalse);
    });
  });

  group('/query', () {
    test('refuses a room we are in, and says to join', () async {
      final s = await _session(xmpp: true);
      s.receiveForTesting(_joined(_room));
      expect(await s.submit('/query $_room'), contains('use /join'));
    });

    test('opens a conversation with a person', () async {
      final s = await _session(xmpp: true);
      expect(await s.submit('/query bob@example.net'), isNull);
      final bob = _named(s, 'bob@example.net');
      expect(bob.isChannel, isFalse);
      expect(
        bob.pending,
        isFalse,
        reason: 'choosing to talk answers the request',
      );
    });

    test('on IRC, the first character still decides', () async {
      final s = await _session(xmpp: false);
      expect(await s.submit('/query #chat'), contains('use /join'));
      expect(await s.submit('/query bob'), isNull);
    });
  });

  group('what is typed', () {
    test('goes to an XMPP account as it was typed', () async {
      final s = await _session(xmpp: true);
      s.receiveForTesting(_joined(_room));
      s.select(_room);
      expect(await s.submit('this is **bold** and *italic*'), isNull);
      expect(core.sent.single.text, 'this is **bold** and *italic*');
    });

    test('is turned into IRC formatting for an IRC network', () async {
      final s = await _session(xmpp: false);
      s.receiveForTesting(_joined('#chat'));
      s.select('#chat');
      expect(await s.submit('this is **bold**'), isNull);
      expect(
        core.sent.single.text,
        isNot('this is **bold**'),
        reason: 'the asterisks became a control code',
      );
      expect(core.sent.single.text, contains('\u0002'));
    });

    test('an action goes to an account without IRC codes either', () async {
      final s = await _session(xmpp: true);
      s.receiveForTesting(_joined(_room));
      s.select(_room);
      expect(await s.submit('/me waves **hard**'), isNull);
      expect(core.sent.single.text, '/me waves **hard**');
    });

    test('a join takes the room address as typed', () async {
      final s = await _session(xmpp: true);
      // The half of joining that does not need the native library.
      s.requestForTesting(_room);
      s.receiveForTesting(_joined(_room));
      expect(s.active?.name, _room, reason: 'a requested join opens its tab');
    });
  });
}
