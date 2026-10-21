// A long run of XMPP traffic through the session model: how long each event
// takes, and whether anything it keeps grows without bound.
//
// Not a benchmark with a pass mark to the microsecond — a CI machine is not a
// phone — but a guard against the two ways this goes wrong quietly: work per
// event that grows with how much has already happened (a scan of everything
// held, for each thing that arrives), and a collection that only ever gains.
// The limits are loose enough that only one of those can trip them.

import 'dart:io';

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

const _room = 'lobby@conference.example.org';

Future<SessionModel> _session() async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load();
  return SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: rust.ServerConfig(
      host: 'example.org',
      port: 5223,
      nickname: 'alice@example.org',
      altNicks: const [],
      channels: const [],
    ),
    settings: settings,
    isXmpp: true,
  );
}

rust.IrcEvent _said(rust.Target target, String sender, String text, int i) =>
    rust.IrcEvent.message(
      message: rust.ChatMessage(
        target: target,
        sender: sender,
        spans: [rust.TextSpan(text: text, style: _plain)],
        isSelf: false,
        isMention: i % 10 == 0,
        isAction: false,
        isNotice: false,
        msgid: 'm$i',
      ),
    );

int _held(SessionModel s) =>
    s.conversations.fold(0, (sum, c) => sum + c.lines.length);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a busy room costs the same per message at the start and the end',
    () async {
      final s = await _session();
      s.receiveForTesting(
        rust.IrcEvent.joined(channel: _room, nick: 'alice', isSelf: true),
      );
      const target = rust.Target.channel(name: _room);

      Duration run(int from, int count) {
        final w = Stopwatch()..start();
        for (var i = from; i < from + count; i++) {
          s.receiveForTesting(
            _said(target, 'user${i % 60}', 'hello number $i', i),
          );
        }
        return w.elapsed;
      }

      run(0, 2000); // fill the room to its cap and warm the code up
      final early = run(2000, 10000);
      run(12000, 30000);
      final late = run(42000, 10000);

      final earlyUs = early.inMicroseconds / 10000;
      final lateUs = late.inMicroseconds / 10000;
      // ignore: avoid_print
      print(
        'room: ${earlyUs.toStringAsFixed(1)} us/message early, '
        '${lateUs.toStringAsFixed(1)} us/message after 50k, '
        '${_held(s)} lines held',
      );
      expect(_held(s), lessThanOrEqualTo(2000), reason: 'the room is capped');
      // No growth with history: the late batch costs about what the early one did.
      expect(lateUs, lessThan(earlyUs * 3 + 20));
      expect(
        lateUs,
        lessThan(500),
        reason: 'per message, even on a slow machine',
      );
    },
  );

  test('many private chats are each capped and none is kept twice', () async {
    final s = await _session();
    const people = 300;
    final w = Stopwatch()..start();
    for (var i = 0; i < 60000; i++) {
      final who = 'person${i % people}@example.net';
      s.receiveForTesting(
        _said(rust.Target.direct(nick: who), who, 'hi $i', i),
      );
    }
    final us = w.elapsed.inMicroseconds / 60000;
    // ignore: avoid_print
    print(
      'chats: ${us.toStringAsFixed(1)} us/message over $people conversations, '
      '${s.conversations.length} conversations, ${_held(s)} lines held',
    );
    expect(s.conversations.length, lessThanOrEqualTo(people + 1));
    expect(_held(s), lessThanOrEqualTo((people + 1) * 2000));
    expect(us, lessThan(500));
  });

  test('presence churn over a large roster leaves one entry per contact', () async {
    final s = await _session();
    const contacts = 2000;
    for (var i = 0; i < contacts; i++) {
      s.receiveForTesting(
        rust.IrcEvent.contact(
          rust.ContactView(
            jid: 'user$i@example.net',
            name: null,
            subscription: rust.Subscription.both,
            asked: false,
            availability: rust.Availability.available,
            status: '',
          ),
        ),
      );
    }
    final before = ProcessInfo.currentRss;
    final w = Stopwatch()..start();
    for (var i = 0; i < 100000; i++) {
      s.receiveForTesting(
        rust.IrcEvent.contact(
          rust.ContactView(
            jid: 'user${i % contacts}@example.net',
            name: null,
            subscription: rust.Subscription.both,
            asked: false,
            availability: rust.Availability.values[i % 5],
            status: 'status ${i % 7}',
          ),
        ),
      );
    }
    final us = w.elapsed.inMicroseconds / 100000;
    final grew = (ProcessInfo.currentRss - before) / (1024 * 1024);
    // ignore: avoid_print
    print(
      'presence: ${us.toStringAsFixed(1)} us/update, ${s.contacts.length} '
      'contacts, resident memory grew ${grew.toStringAsFixed(1)} MiB over 100k updates',
    );
    expect(s.contacts.length, contacts);
    expect(us, lessThan(500));
    // Garbage not yet collected shows up here, so the bar is "not hundreds".
    expect(grew, lessThan(150));
  });
}
