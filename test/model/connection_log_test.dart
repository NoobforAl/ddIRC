// Tests for where the account of the connection ends up.
//
// It used to be the scrollback. Every attempt, every TLS handshake, every
// reconnect countdown and every complaint the server made was filed as a muted
// grey line into whichever conversation happened to be on screen when it
// arrived — so a channel's history was part conversation and part plumbing,
// and one connection's story was spread across every room the user had visited
// while it was failing.
//
// So the invariant is a separation, and these check both halves of it: none of
// that reaches a conversation any more, and none of it is lost either.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart';

Future<SessionModel> session() async {
  SharedPreferences.setMockInitialValues({});
  return SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: const ServerConfig(
      host: 'example.test',
      port: 6697,
      nickname: 'me',
      altNicks: [],
      channels: [],
    ),
    settings: await AppSettings.load(),
  );
}

/// Everything in the scrollback of every conversation, as plain text.
List<String> everythingSaid(SessionModel s) => [
  for (final conversation in s.conversations)
    for (final line in conversation.lines)
      line.system ?? line.message!.spans.map((span) => span.text).join(),
];

List<String> logged(SessionModel s) =>
    s.connectionLog.map((entry) => entry.text).toList();

/// Put the session in a channel, so there is somewhere for a stray line to
/// land — without one, "not in the scrollback" would pass for the wrong reason.
void joinAChannel(SessionModel s) => s.receiveForTesting(
  const IrcEvent.joined(channel: '#test', nick: 'me', isSelf: true),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connection status never reaches a conversation', () async {
    final s = await session();
    joinAChannel(s);

    s.receiveForTesting(
      const IrcEvent.status(status: ConnectionStatus.connecting()),
    );
    s.receiveForTesting(
      const IrcEvent.status(
        status: ConnectionStatus.disconnected(),
        detail: 'certificate not trusted',
      ),
    );

    expect(
      everythingSaid(s).where((line) => line.contains('connect')),
      isEmpty,
      reason: 'the plumbing does not belong in what people said',
    );
    expect(logged(s), hasLength(2));
    expect(logged(s).last, contains('certificate not trusted'));
  });

  test('registration is recorded, not narrated into the channel', () async {
    final s = await session();
    joinAChannel(s);

    s.receiveForTesting(
      const IrcEvent.registered(
        nick: 'me',
        network: 'ExampleNet',
        auth: AuthOutcome.nickServFallback(
          reason: 'server does not offer SASL',
        ),
      ),
    );

    expect(everythingSaid(s), isNot(contains(contains('registered on'))));
    // Both halves: which network took us, and that the weaker of the two
    // authentication routes was the one used.
    expect(logged(s), [
      'registered on ExampleNet as me',
      'SASL unavailable (server does not offer SASL) — used NickServ',
    ]);
  });

  test('a server error is logged and raised, never filed as a line', () async {
    final s = await session();
    joinAChannel(s);

    s.receiveForTesting(
      const IrcEvent.error(message: 'Nickname is already in use', fatal: false),
    );

    expect(everythingSaid(s), isNot(contains(contains('already in use'))));
    expect(logged(s), ['error: Nickname is already in use']);
    // The notice is the alert half; without it the error would be something
    // the user could only find by going looking for it.
    expect(s.notice?.message, contains('already in use'));
  });

  test(
    'dropped messages stay in the conversation they left a hole in',
    () async {
      final s = await session();
      joinAChannel(s);

      s.receiveForTesting(
        IrcEvent.messagesDropped(channel: '#test', count: BigInt.from(3)),
      );

      // The one report that did not move. It is not about the connection — it
      // is the only thing standing between a gap in the conversation and the
      // impression that nobody spoke.
      expect(everythingSaid(s), contains(contains('3 message(s) dropped')));
      expect(logged(s), isEmpty);
    },
  );

  test('the log is bounded, keeping the most recent', () async {
    final s = await session();

    for (var i = 0; i < 400; i++) {
      s.receiveForTesting(
        IrcEvent.status(
          status: const ConnectionStatus.connecting(),
          detail: 'attempt $i',
        ),
      );
    }

    // A connection that flaps for a day writes a line every few seconds, and
    // the log exists to explain the last failure rather than to archive them.
    expect(s.connectionLog.length, lessThanOrEqualTo(300));
    expect(logged(s).last, contains('attempt 399'));
  });
}
