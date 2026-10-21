// Tests for what an XMPP account has that IRC does not: a contact list with
// presence, requests to see when you are online, a status of your own, and
// messages that can be corrected or taken back.
//
// The model half feeds events in as the core would send them; the dialog half
// checks that what the user does reaches the core as the right command and
// that nothing is answered on their behalf.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/notifications.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/rust/frb_generated.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/contacts_dialog.dart';

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

/// Records the calls the session makes into the core, and answers nothing
/// else: a call this test did not mean to cause fails.
class _FakeCore implements RustLibApi {
  final calls = <String>[];
  String? failWith;

  Future<void> _record(String call) async {
    calls.add(call);
    final failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<void> crateApiClientAddContact({
    required BigInt id,
    required String jid,
    String? name,
  }) => _record('add $jid ${name ?? ''}'.trim());

  @override
  Future<void> crateApiClientRemoveContact({
    required BigInt id,
    required String jid,
  }) => _record('remove $jid');

  @override
  Future<void> crateApiClientAnswerSubscription({
    required BigInt id,
    required String jid,
    required bool accept,
  }) => _record('${accept ? 'accept' : 'decline'} $jid');

  @override
  Future<void> crateApiClientSetAvailability({
    required BigInt id,
    required rust.Availability availability,
    String? status,
  }) => _record('status ${availability.name} ${status ?? ''}'.trim());

  @override
  Future<void> crateApiClientEditMessage({
    required BigInt id,
    required String target,
    required String msgid,
    required String text,
  }) => _record('edit $target $msgid $text');

  @override
  Future<void> crateApiClientRetractMessage({
    required BigInt id,
    required String target,
    required String msgid,
  }) => _record('retract $target $msgid');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

rust.ContactView _contact(
  String jid, {
  String? name,
  rust.Availability availability = rust.Availability.offline,
  rust.Subscription subscription = rust.Subscription.both,
  bool asked = false,
  String status = '',
}) => rust.ContactView(
  jid: jid,
  name: name,
  subscription: subscription,
  asked: asked,
  availability: availability,
  status: status,
);

rust.ChatMessage _message(
  String sender,
  String text, {
  String? msgid,
  bool isSelf = false,
  rust.Target? target,
}) => rust.ChatMessage(
  target: target ?? const rust.Target.direct(nick: 'bob@example.net'),
  sender: sender,
  spans: [rust.TextSpan(text: text, style: _plain)],
  isSelf: isSelf,
  isMention: false,
  isAction: false,
  isNotice: false,
  msgid: msgid,
);

String _text(ChatLine line) => line.message!.spans.map((s) => s.text).join();

void main() {
  late _FakeCore core;

  setUp(() {
    core = _FakeCore();
    RustLib.initMock(api: core);
  });

  tearDown(RustLib.dispose);

  group('the contact list', () {
    test('a contact arrives, changes in place and leaves', () async {
      final s = await _session();
      s.receiveForTesting(
        rust.IrcEvent.contact(_contact('bob@example.net', name: 'Bob')),
      );
      expect(s.contacts.map((c) => c.jid), ['bob@example.net']);

      s.receiveForTesting(
        rust.IrcEvent.contact(
          _contact(
            'bob@example.net',
            name: 'Bob',
            availability: rust.Availability.away,
            status: 'lunch',
          ),
        ),
      );
      expect(s.contacts, hasLength(1), reason: 'an upsert, not a second row');
      expect(s.contacts.single.status, 'lunch');

      s.receiveForTesting(
        const rust.IrcEvent.contactRemoved(jid: 'bob@example.net'),
      );
      expect(s.contacts, isEmpty);
    });

    test('those who are there come first, then everyone by name', () async {
      final s = await _session();
      for (final c in [
        _contact('zed@example.net', availability: rust.Availability.available),
        _contact('amy@example.net'),
        _contact('bob@example.net', name: 'Bobby'),
        _contact('cat@example.net', availability: rust.Availability.dnd),
      ]) {
        s.receiveForTesting(rust.IrcEvent.contact(c));
      }
      expect(s.contacts.map((c) => c.jid), [
        'cat@example.net',
        'zed@example.net',
        'amy@example.net',
        'bob@example.net',
      ]);
    });

    test(
      'a request is kept until the user answers it, and told to them',
      () async {
        final s = await _session();
        s.receiveForTesting(
          const rust.IrcEvent.subscriptionRequest(jid: 'dave@example.net'),
        );
        expect(s.subscriptionRequests, ['dave@example.net']);
        expect(s.notice?.message, contains('dave@example.net'));
        // Nothing was sent: it is the user's to answer.
        expect(core.calls, isEmpty);

        // The same person asking again is not a second request.
        s.receiveForTesting(
          const rust.IrcEvent.subscriptionRequest(jid: 'dave@example.net'),
        );
        expect(s.subscriptionRequests, hasLength(1));
      },
    );

    test('accepting sends the answer and clears the request', () async {
      final s = await _session();
      s.receiveForTesting(
        const rust.IrcEvent.subscriptionRequest(jid: 'dave@example.net'),
      );
      expect(
        await s.answerSubscription('dave@example.net', accept: true),
        isNull,
      );
      expect(core.calls, ['accept dave@example.net']);
      expect(s.subscriptionRequests, isEmpty);
    });

    test(
      'declining sends no, and a refusal from the core keeps the request',
      () async {
        final s = await _session();
        s.receiveForTesting(
          const rust.IrcEvent.subscriptionRequest(jid: 'dave@example.net'),
        );
        core.failWith = 'nope';
        expect(
          await s.answerSubscription('dave@example.net', accept: false),
          isNotNull,
        );
        expect(s.subscriptionRequests, ['dave@example.net']);
      },
    );

    test(
      'saying how you are is remembered once the core has taken it',
      () async {
        final s = await _session();
        expect(s.myAvailability, rust.Availability.available);
        await s.setAvailability(
          rust.Availability.dnd,
          status: ' in a meeting ',
        );
        expect(core.calls.last, 'status dnd  in a meeting');
        expect(s.myAvailability, rust.Availability.dnd);
        expect(s.myStatus, 'in a meeting');

        core.failWith = 'nope';
        await s.setAvailability(rust.Availability.away);
        expect(s.myAvailability, rust.Availability.dnd, reason: 'not changed');
      },
    );
  });

  group('corrections and retractions', () {
    Future<(SessionModel, Conversation)> withMessage({
      String sender = 'bob@example.net',
      bool isSelf = false,
    }) async {
      final s = await _session();
      s.receiveForTesting(
        rust.IrcEvent.message(
          message: _message(sender, 'teh plan', msgid: 'm1', isSelf: isSelf),
        ),
      );
      return (s, s.conversations.single);
    }

    test(
      'the author corrects a message and it changes where it stands',
      () async {
        final (s, c) = await withMessage();
        final line = c.lines.single;
        s.receiveForTesting(
          rust.IrcEvent.messageEdited(
            target: const rust.Target.direct(nick: 'bob@example.net'),
            msgid: 'm1',
            sender: 'bob@example.net',
            message: _message('bob@example.net', 'the plan', msgid: 'm1'),
          ),
        );
        expect(c.lines, hasLength(1), reason: 'in place, not a second line');
        expect(identical(c.lines.single, line), isTrue);
        expect(_text(line), 'the plan');
        expect(line.edited, isTrue);
      },
    );

    test(
      'a correction naming someone else as its author changes nothing',
      () async {
        final (s, c) = await withMessage();
        s.receiveForTesting(
          rust.IrcEvent.messageEdited(
            target: const rust.Target.direct(nick: 'bob@example.net'),
            msgid: 'm1',
            sender: 'mallory@evil.example',
            message: _message(
              'mallory@evil.example',
              'I love you',
              msgid: 'm1',
            ),
          ),
        );
        expect(_text(c.lines.single), 'teh plan');
        expect(c.lines.single.edited, isFalse);
      },
    );

    test('a correction of something never shown changes nothing', () async {
      final (s, c) = await withMessage();
      s.receiveForTesting(
        rust.IrcEvent.messageEdited(
          target: const rust.Target.direct(nick: 'bob@example.net'),
          msgid: 'unknown',
          sender: 'bob@example.net',
          message: _message('bob@example.net', 'x', msgid: 'unknown'),
        ),
      );
      expect(_text(c.lines.single), 'teh plan');
    });

    test(
      'a retraction removes the line and says that something was removed',
      () async {
        final (s, c) = await withMessage();
        s.receiveForTesting(
          const rust.IrcEvent.messageRetracted(
            target: rust.Target.direct(nick: 'bob@example.net'),
            msgid: 'm1',
            sender: 'bob@example.net',
          ),
        );
        expect(c.lines.any((l) => l.message != null), isFalse);
        expect(c.lines.single.system, contains('deleted a message'));
      },
    );

    test('a retraction by someone else removes nothing', () async {
      final (s, c) = await withMessage();
      s.receiveForTesting(
        const rust.IrcEvent.messageRetracted(
          target: rust.Target.direct(nick: 'bob@example.net'),
          msgid: 'm1',
          sender: 'mallory@evil.example',
        ),
      );
      expect(c.lines.single.message, isNotNull);
    });

    test('only our own messages with an id can be changed', () async {
      final s = await _session();
      ChatLine line(ChatMessage m) => ChatLine.message(m, DateTime(2026));
      expect(
        s.canChange(line(_message('alice', 'x', msgid: 'a', isSelf: true))),
        isTrue,
      );
      expect(
        s.canChange(line(_message('alice', 'x', isSelf: true))),
        isFalse,
        reason: 'no id to name it by',
      );
      expect(s.canChange(line(_message('bob', 'x', msgid: 'b'))), isFalse);
    });

    test(
      'editing and deleting reach the core by conversation and id',
      () async {
        final (s, c) = await withMessage(
          sender: 'alice@example.org',
          isSelf: true,
        );
        await s.editMessage(c, c.lines.single, 'the plan');
        await s.retractMessage(c, c.lines.single);
        expect(core.calls, [
          'edit bob@example.net m1 the plan',
          'retract bob@example.net m1',
        ]);
      },
    );
  });

  group('sending files', () {
    test(
      'uploading is offered only once the server has said it takes files',
      () async {
        final s = await _session();
        expect(s.canUpload, isFalse);
        s.receiveForTesting(
          rust.IrcEvent.uploadAvailable(maxBytes: BigInt.from(5 * 1024 * 1024)),
        );
        expect(s.canUpload, isTrue);
        expect(s.uploadLimit, BigInt.from(5 * 1024 * 1024));
      },
    );

    test('a new login forgets it, because the next login asks again', () async {
      final s = await _session();
      s.receiveForTesting(rust.IrcEvent.uploadAvailable(maxBytes: BigInt.one));
      s.receiveForTesting(
        const rust.IrcEvent.registered(
          nick: 'alice@example.org',
          network: 'example.org',
          auth: rust.AuthOutcome.sasl(),
        ),
      );
      expect(s.canUpload, isFalse);
    });
  });

  group('what is worth a notification', () {
    test('a message from the archive is history, a fresh one is news', () {
      final now = DateTime(2026, 5, 1, 12);
      expect(isHistory(now.subtract(const Duration(hours: 3)), now), isTrue);
      expect(
        isHistory(now.subtract(const Duration(seconds: 30)), now),
        isFalse,
      );
      expect(isHistory(now.add(const Duration(minutes: 5)), now), isFalse);
    });
  });

  group('the contacts dialog', () {
    Future<SessionModel> open(
      WidgetTester tester, {
      List<String>? chats,
    }) async {
      // Tall enough that nothing is below the fold: the dialog's body is a
      // lazily built list, and what is not on screen is not built.
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await _session();
      s.receiveForTesting(
        rust.IrcEvent.contact(
          _contact(
            'bob@example.net',
            name: 'Bob',
            availability: rust.Availability.available,
            status: 'around',
          ),
        ),
      );
      s.receiveForTesting(
        rust.IrcEvent.contact(
          _contact('carol@example.net', subscription: rust.Subscription.from),
        ),
      );
      s.receiveForTesting(
        const rust.IrcEvent.subscriptionRequest(jid: 'dave@example.net'),
      );
      // The request raised a notice, and a notice runs a timer that a widget
      // test would otherwise find still pending when the tree goes.
      s.dismissNotice();
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Scaffold(
            body: ContactsDialog(
              session: s,
              onOpenChat: (jid) => chats?.add(jid),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return s;
    }

    testWidgets('shows contacts with what they say, and who is waiting', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('around'), findsOneWidget);
      expect(find.text('carol@example.net'), findsOneWidget);
      expect(
        find.text('They can see you; you cannot see them'),
        findsOneWidget,
      );
      expect(find.text('Waiting for your answer'), findsOneWidget);
      expect(find.text('dave@example.net'), findsOneWidget);
    });

    testWidgets('accept and decline are the user\'s, and send nothing before', (
      tester,
    ) async {
      final s = await open(tester);
      expect(core.calls, isEmpty);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(core.calls, ['accept dave@example.net']);
      expect(s.subscriptionRequests, isEmpty);
      expect(find.text('Waiting for your answer'), findsNothing);
    });

    testWidgets('decline says no', (tester) async {
      await open(tester);
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(core.calls, ['decline dave@example.net']);
    });

    testWidgets('an address is added, and one that is not an address is not', (
      tester,
    ) async {
      await open(tester);
      final field = find.byType(TextField).first;
      await tester.enterText(field, 'not an address');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(core.calls, isEmpty);
      expect(find.textContaining('is not an address'), findsOneWidget);

      await tester.enterText(field, 'erin@example.net');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(core.calls, ['add erin@example.net']);
    });

    testWidgets('choosing a contact opens a conversation with them', (
      tester,
    ) async {
      final chats = <String>[];
      await open(tester, chats: chats);
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(chats, ['bob@example.net']);
    });

    testWidgets('removing a contact asks the core to', (tester) async {
      await open(tester);
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(core.calls.single, startsWith('remove '));
    });

    testWidgets('a contact we cannot see can be asked to be seen', (
      tester,
    ) async {
      await open(tester);
      // Carol follows us and we do not follow her: she is the one offering it.
      final carol = find.ancestor(
        of: find.text('carol@example.net'),
        matching: find.byType(InkWell),
      );
      await tester.tap(
        find.descendant(
          of: carol.first,
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask to see them'));
      await tester.pumpAndSettle();
      expect(core.calls, ['add carol@example.net']);
    });
  });

  group('the status dialog', () {
    testWidgets('saves what was chosen and what was written', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await _session();
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Scaffold(body: StatusDialog(session: s)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Busy'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'deadline');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(core.calls, ['status dnd deadline']);
      expect(s.myAvailability, rust.Availability.dnd);
    });
  });
}

typedef ChatMessage = rust.ChatMessage;
