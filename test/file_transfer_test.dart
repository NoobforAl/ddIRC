// Tests for file transfers, end to end on the Dart side.
//
// Receiving a file means dialling an address a stranger chose, and sending one
// hands out your own, so this is the part of the app where a wrong default
// costs somebody something. What is held here is the shape of the consent: that
// nothing is shown, accepted or sent unless the switch is on; that nothing is
// ever accepted *for* the user; that declining sends nothing; that an offer the
// connection could only refuse is not offered an Accept button; and that the
// dialog a person reads before turning it on describes what the feature does
// rather than what it did two versions ago.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/media.dart';
import 'package:ddirc/src/model/notice.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/transfer.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/send_file_sheet.dart';
import 'package:ddirc/src/ui/settings/file_transfer_section.dart';
import 'package:ddirc/src/ui/file_message.dart';
import 'package:ddirc/src/ui/message_view.dart';

Future<SessionModel> _session({
  bool transfers = true,
  rust.ProxyConfig? proxy,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load();
  settings.fileTransfers = transfers;
  return SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: rust.ServerConfig(
      host: 'example.test',
      port: 6697,
      nickname: 'me',
      altNicks: const [],
      channels: const [],
      proxy: proxy,
    ),
    settings: settings,
  );
}

void _joined(SessionModel s, String channel) => s.receiveForTesting(
  rust.IrcEvent.joined(channel: channel, nick: 'me', isSelf: true),
);

Conversation _named(SessionModel s, String name) =>
    s.conversations.firstWhere((c) => c.name == name);

/// An offer from `alice`. A null [port] makes it a reverse offer — one that asks
/// the receiver to listen — which is how the core spells that.
rust.IrcEvent _offer({
  int id = 1,
  String channel = '#chat',
  String from = 'alice',
  String filename = 'report.pdf',
  int? port = 5000,
  int? size = 2048,
}) => rust.IrcEvent.fileOffered(
  id: BigInt.from(id),
  channel: channel,
  from: from,
  offer: rust.DccOffer(
    filename: filename,
    host: port == null ? null : '203.0.113.5',
    port: port,
    size: size == null ? null : BigInt.from(size),
    token: port == null ? BigInt.from(7) : null,
  ),
);

rust.IrcEvent _started({int id = 1, bool incoming = true, int? total = 2048}) =>
    rust.IrcEvent.fileTransferStarted(
      id: BigInt.from(id),
      channel: '#chat',
      filename: 'report.pdf',
      incoming: incoming,
      total: total == null ? null : BigInt.from(total),
    );

rust.IrcEvent _progress(int transferred, {int id = 1}) =>
    rust.IrcEvent.fileTransferProgress(
      id: BigInt.from(id),
      transferred: BigInt.from(transferred),
    );

rust.IrcEvent _ended({int id = 1, String? path, String? error}) =>
    rust.IrcEvent.fileTransferEnded(
      id: BigInt.from(id),
      channel: '#chat',
      filename: 'report.pdf',
      path: path,
      error: error,
    );

/// The files in a conversation: every message that is a card, in order.
List<FileTransfer> _files(Conversation c) =>
    c.lines.map((l) => l.transfer).whereType<FileTransfer>().toList();

/// The system lines in a conversation, as text.
List<String> _said(Conversation c) =>
    c.lines.map((l) => l.system).whereType<String>().toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileTransfer', () {
    test(
      'sizes are said in the largest unit that leaves a readable number',
      () {
        expect(FileTransfer.describeSize(null), 'unknown size');
        expect(FileTransfer.describeSize(BigInt.zero), '0 B');
        expect(FileTransfer.describeSize(BigInt.from(1023)), '1023 B');
        expect(FileTransfer.describeSize(BigInt.from(2048)), '2 KB');
        expect(
          FileTransfer.describeSize(BigInt.from(5 * 1024 * 1024)),
          '5.0 MB',
        );
        expect(
          FileTransfer.describeSize(BigInt.from(3) * BigInt.from(1 << 30)),
          '3.0 GB',
        );
      },
    );

    test('progress is a fraction, and never more than all of it', () {
      FileTransfer running(int? total) => FileTransfer.running(
        id: BigInt.one,
        filename: 'f',
        incoming: true,
        total: total == null ? null : BigInt.from(total),
      );

      expect(running(null).fraction, isNull, reason: 'unknown size');
      expect(running(0).fraction, isNull, reason: 'a size of nothing');

      final half = running(200)..transferred = BigInt.from(100);
      expect(half.fraction, 0.5);

      // The total is the sender's claim. One who understated it must not be
      // able to push a progress bar past its end.
      final liar = running(100)..transferred = BigInt.from(5000);
      expect(liar.fraction, 1.0);
    });

    FileTransfer offer({int? total = 2048}) => FileTransfer.offered(
      id: BigInt.one,
      filename: 'report.pdf',
      from: 'alice',
      total: total == null ? null : BigInt.from(total),
      isReverse: false,
    );

    test('an offer is incoming, and has not been answered', () {
      final o = offer(total: null);
      expect(o.incoming, isTrue);
      expect(o.stage, TransferStage.offered);
      expect(o.transferred, BigInt.zero);
      expect(o.isOver, isFalse);
    });

    test('an offer, once connected, is the same transfer one step on', () {
      final o = offer();
      var heard = 0;
      o.addListener(() => heard++);

      o.begin(size: BigInt.from(4096));
      expect(o.stage, TransferStage.running);
      expect(o.total, BigInt.from(4096), reason: 'the core knows better');
      expect(o.from, 'alice', reason: 'still the same offer, still hers');
      expect(heard, 1);
    });

    test('every way it can end is its own stage, and ends it', () {
      final done = offer()..begin();
      done.finish(path: '/x/report.pdf');
      expect(done.stage, TransferStage.done);
      expect(done.path, '/x/report.pdf');
      expect(done.isOver, isTrue);

      final failed = offer()..begin();
      failed.finish(error: 'connection reset');
      expect(failed.stage, TransferStage.failed);
      expect(failed.error, 'connection reset');

      // Stopping it yourself is not a failure, and is not drawn as one.
      final cancelled = offer()..begin();
      cancelled.finish(error: FileTransfer.cancelledError);
      expect(cancelled.stage, TransferStage.cancelled);

      final declined = offer()..decline();
      expect(declined.stage, TransferStage.declined);
      expect(declined.isOver, isTrue);
    });

    test(
      'a received file with no claimed size takes the size that arrived',
      () {
        final o = offer(total: null)..begin();
        o.transferred = BigInt.from(1500);
        o.finish(path: '/x/a');
        expect(o.total, BigInt.from(1500));
      },
    );

    test('listeners hear a change, and only a real one', () {
      final o = offer()..begin();
      var heard = 0;
      o.addListener(() => heard++);

      o.transferred = BigInt.from(10);
      o.transferred = BigInt.from(10);
      o.transferred = BigInt.from(20);
      expect(heard, 2, reason: 'the repeat said nothing new');
    });

    test('says in plain words how it stands, for anything that reads text', () {
      final o = offer();
      expect(o.summary, 'alice offered you "report.pdf", says it is 2 KB');
      o.begin();
      expect(o.summary, 'receiving "report.pdf" (2 KB)');
      o.finish(path: '/x/report.pdf');
      expect(o.summary, 'saved "report.pdf" to /x/report.pdf');

      expect((offer()..decline()).summary, 'you declined "report.pdf"');
      expect(
        (offer()
              ..begin()
              ..finish(error: 'cancelled'))
            .summary,
        'cancelled "report.pdf"',
      );
      expect(
        (offer()
              ..begin()
              ..finish(error: 'connection reset'))
            .summary,
        'transfer of "report.pdf" failed: connection reset',
      );
    });

    test('what is said once it is over names where the file went', () {
      expect(
        FileTransfer.describeOutcome(filename: 'a', path: '/x/a', error: null),
        'saved "a" to /x/a',
      );
      expect(
        FileTransfer.describeOutcome(filename: 'a', path: null, error: null),
        'sent "a"',
      );
      expect(
        FileTransfer.describeOutcome(
          filename: 'a',
          path: null,
          error: 'connection reset',
        ),
        'transfer of "a" failed: connection reset',
      );
    });
  });

  group('the session, on an offer', () {
    test('shows nothing at all while file transfers are off', () async {
      final s = await _session(transfers: false);
      _joined(s, '#chat');
      s.receiveForTesting(_offer());

      final chat = _named(s, '#chat');
      expect(_files(chat), isEmpty, reason: 'no card to answer');
      expect(
        _said(chat).where((l) => l.contains('offered')),
        isEmpty,
        reason: 'and no line: an off switch must not be a prompt to turn it on',
      );
    });

    test('becomes one file message in the conversation, once on', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());

      final chat = _named(s, '#chat');
      final file = _files(chat).single;
      expect(file.stage, TransferStage.offered);
      expect(file.filename, 'report.pdf');
      expect(file.from, 'alice');
      expect(file.total, BigInt.from(2048));
      expect(file.isReverse, isFalse);

      // It is a line of the scrollback, so it has a place in it and a time —
      // and as text, for search and anything else that cannot draw a card, the
      // size is the sender's claim and is written as one.
      final line = chat.lines.lastWhere((l) => l.transfer != null);
      expect(line.isSystem, isTrue);
      expect(line.system, contains('"report.pdf"'));
      expect(line.system, contains('says it is 2 KB'));
    });

    test('an offer with no address to dial is a reverse one', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer(port: null));
      expect(_files(_named(s, '#chat')).single.isReverse, isTrue);
    });

    test('is never answered by the session on its own', () async {
      // Nothing here could answer: an offer arriving changes what is on
      // screen and nothing else, and it waits until a person acts on it.
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_offer(id: 2, filename: 'second.zip'));

      final files = _files(_named(s, '#chat'));
      expect(files.map((t) => t.stage), everyElement(TransferStage.offered));
      expect(files.map((t) => t.filename), ['report.pdf', 'second.zip']);
    });

    test('a private offer is filed under the person who made it', () async {
      final s = await _session();
      s.receiveForTesting(_offer(channel: 'alice'));
      expect(_files(_named(s, 'alice')), hasLength(1));
    });
  });

  group('the session, on a transfer', () {
    test('an accepted offer is the same message, one step on', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      final before = _files(_named(s, '#chat')).single;
      final lines = _named(s, '#chat').lines.length;

      s.receiveForTesting(_started());

      final chat = _named(s, '#chat');
      expect(_files(chat), hasLength(1), reason: 'not a second message');
      expect(chat.lines.length, lines, reason: 'nothing was added');
      expect(_files(chat).single, same(before));
      expect(before.stage, TransferStage.running);
      expect(before.incoming, isTrue);
    });

    test('progress moves the card it belongs to and no other', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());
      s.receiveForTesting(_started(id: 2, incoming: false));
      s.receiveForTesting(_progress(1024, id: 1));

      final byId = {for (final t in _files(_named(s, '#chat'))) t.id: t};
      expect(byId[BigInt.one]!.transferred, BigInt.from(1024));
      expect(byId[BigInt.two]!.transferred, BigInt.zero);

      // And one for a transfer that is not there is not an error.
      s.receiveForTesting(_progress(5, id: 99));
    });

    test('progress repaints the card and not the whole conversation', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());
      final card = _files(_named(s, '#chat')).single;

      var sessionHeard = 0;
      var cardHeard = 0;
      s.addListener(() => sessionHeard++);
      card.addListener(() => cardHeard++);

      s.receiveForTesting(_progress(512));
      s.receiveForTesting(_progress(1024));

      expect(cardHeard, 2);
      expect(sessionHeard, 0, reason: 'a percentage is not news to the list');
    });

    test('finishing turns the same message into the received file', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());
      final lines = _named(s, '#chat').lines.length;
      s.receiveForTesting(_ended(path: '/data/received/report.pdf'));

      final chat = _named(s, '#chat');
      final file = _files(chat).single;
      expect(file.stage, TransferStage.done);
      expect(file.path, '/data/received/report.pdf');
      expect(chat.lines.length, lines, reason: 'the card is the record');
      expect(
        chat.lines.last.system,
        'saved "report.pdf" to /data/received/report.pdf',
      );
      expect(s.notice, isNull, reason: 'a good outcome needs no second alert');
    });

    test(
      'a transfer that fails is a failure, and still raises its alert',
      () async {
        final s = await _session();
        _joined(s, '#chat');
        s.receiveForTesting(_offer());
        s.receiveForTesting(_started());
        s.receiveForTesting(_ended(error: 'connection reset'));

        final file = _files(_named(s, '#chat')).single;
        expect(file.stage, TransferStage.failed);
        expect(file.error, 'connection reset');
        expect(s.notice, isNotNull);
        expect(s.notice!.level, isNot(NoticeLevel.info));
      },
    );

    test('stopping one yourself is not reported as a failure', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());
      s.receiveForTesting(_ended(error: FileTransfer.cancelledError));

      expect(_files(_named(s, '#chat')).single.stage, TransferStage.cancelled);
      expect(s.notice, isNull);
    });

    test('a file we sent first appears when the other side connects', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_started(incoming: false));

      final file = _files(_named(s, '#chat')).single;
      expect(file.incoming, isFalse);
      expect(file.stage, TransferStage.running);

      s.receiveForTesting(_ended());
      expect(file.stage, TransferStage.done);
      expect(file.summary, 'sent "report.pdf"');
      expect(s.notice, isNull);
    });

    test('an end with no beginning we saw still leaves a line', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_ended(path: '/x/report.pdf'));

      expect(_files(_named(s, '#chat')), isEmpty);
      expect(
        _said(_named(s, '#chat')),
        contains('saved "report.pdf" to /x/report.pdf'),
      );
    });

    test('declining answers the offer at once', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());

      // Not awaited before looking: the card says so when the user says no, not
      // when the core has finished hearing about it.
      final answered = s.cancelTransfer(BigInt.one);
      expect(_files(_named(s, '#chat')).single.stage, TransferStage.declined);
      await answered;
    });

    test('stopping a running one waits for the core to say it has', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());

      final answered = s.cancelTransfer(BigInt.one);
      expect(
        _files(_named(s, '#chat')).single.stage,
        TransferStage.running,
        reason: 'not drawn as stopped before it is true',
      );
      await answered;
    });
  });

  group('the file card', () {
    late AppSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load();
    });

    FileTransfer offer({bool reverse = false, int? total = 2048}) =>
        FileTransfer.offered(
          id: BigInt.one,
          filename: 'report.pdf',
          from: 'alice',
          total: total == null ? null : BigInt.from(total),
          isReverse: reverse,
        );

    Widget host(
      FileTransfer transfer, {
      VoidCallback? onAccept,
      VoidCallback? onCancel,
      VoidCallback? onReveal,
      String? blocked,
      bool showSender = false,
      double width = 800,
    }) => MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: FileMessage(
              transfer: transfer,
              at: DateTime(2026, 1, 1, 9),
              settings: settings,
              showSender: showSender,
              blockedReason: blocked,
              onAccept: onAccept ?? () {},
              onCancel: onCancel ?? () {},
              onReveal: onReveal,
            ),
          ),
        ),
      ),
    );

    Finder button(String label) => find.bySemanticsLabel(label);

    testWidgets('an offer is a round download button, the name, the claim', (
      tester,
    ) async {
      await tester.pumpWidget(host(offer()));

      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('alice says 2 KB'), findsOneWidget);
      expect(button('Download report.pdf'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
    });

    testWidgets('pressing the button accepts, and only that', (tester) async {
      var accepted = 0;
      var cancelled = 0;
      await tester.pumpWidget(
        host(offer(), onAccept: () => accepted++, onCancel: () => cancelled++),
      );

      await tester.tap(button('Download report.pdf'));
      await tester.pump();

      expect(accepted, 1);
      expect(cancelled, 0);
    });

    testWidgets('Decline turns it down and does not accept', (tester) async {
      var accepted = 0;
      var cancelled = 0;
      await tester.pumpWidget(
        host(offer(), onAccept: () => accepted++, onCancel: () => cancelled++),
      );

      await tester.tap(find.text('Decline'));
      await tester.pump();

      expect(cancelled, 1);
      expect(accepted, 0);
    });

    testWidgets('a sender who gave no size says so', (tester) async {
      await tester.pumpWidget(host(offer(total: null)));
      expect(find.text('alice did not say how big it is'), findsOneWidget);
    });

    testWidgets(
      'an offer that cannot be taken up says why, and has no download',
      (tester) async {
        var accepted = 0;
        const reason =
            'Cannot accept through a proxy — it would reveal your address';
        await tester.pumpWidget(
          host(offer(), blocked: reason, onAccept: () => accepted++),
        );

        expect(find.text(reason), findsOneWidget);
        // The way out stays; the button that could only fail does not work.
        expect(find.text('Dismiss'), findsOneWidget);
        expect(find.text('Decline'), findsNothing);
        await tester.tap(find.byIcon(Icons.arrow_downward_rounded));
        await tester.pump();
        expect(accepted, 0);
      },
    );

    testWidgets('while it comes down it is a ring with a cross that stops it', (
      tester,
    ) async {
      final transfer = offer()..begin();
      transfer.transferred = BigInt.from(1024);
      var cancelled = 0;
      await tester.pumpWidget(host(transfer, onCancel: () => cancelled++));

      expect(find.text('1 KB / 2 KB'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0.5,
      );
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(find.text('Decline'), findsNothing, reason: 'already answered');

      await tester.tap(button('Cancel report.pdf'));
      expect(cancelled, 1);
    });

    testWidgets('a sender who gave no size gets an honest, spinning ring', (
      tester,
    ) async {
      final transfer = offer(total: null)..begin();
      transfer.transferred = BigInt.from(3000);
      await tester.pumpWidget(host(transfer));

      expect(find.text('3 KB'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNull,
      );
    });

    testWidgets('moves by itself as bytes arrive', (tester) async {
      final transfer = offer()..begin();
      await tester.pumpWidget(host(transfer));
      expect(find.text('0 B / 2 KB'), findsOneWidget);

      transfer.transferred = BigInt.from(1536);
      await tester.pump();
      expect(find.text('2 KB / 2 KB'), findsOneWidget);
    });

    testWidgets('becomes the file when it is here, and says where it went', (
      tester,
    ) async {
      final transfer = offer()..begin();
      await tester.pumpWidget(host(transfer, onReveal: () {}));
      transfer.finish(path: r'C:\Users\me\Downloads\ddIRC\report.pdf');
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      expect(find.textContaining('ddIRC'), findsOneWidget);
      expect(find.textContaining('2 KB'), findsOneWidget);
    });

    testWidgets('a received file can be shown where there is a file manager', (
      tester,
    ) async {
      var shown = 0;
      final transfer = offer()
        ..begin()
        ..finish(path: '/home/me/Downloads/ddIRC/report.pdf');
      await tester.pumpWidget(host(transfer, onReveal: () => shown++));

      await tester.tap(button('Show report.pdf in its folder'));
      expect(shown, 1);
    });

    testWidgets('and on a phone, where there is none, it is simply the file', (
      tester,
    ) async {
      final transfer = offer()
        ..begin()
        ..finish(path: '/data/user/0/dev.ddirc/files/received/report.pdf');
      await tester.pumpWidget(host(transfer));

      expect(button('Show report.pdf in its folder'), findsNothing);
      expect(find.textContaining('private storage'), findsOneWidget);
    });

    testWidgets('a failure is drawn as one, with the reason', (tester) async {
      final transfer = offer()
        ..begin()
        ..finish(error: 'connection reset');
      await tester.pumpWidget(host(transfer));

      expect(find.text('connection reset'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('cancelled and declined say so, and neither is an error', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          offer()
            ..begin()
            ..finish(error: FileTransfer.cancelledError),
        ),
      );
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);

      await tester.pumpWidget(host(offer()..decline()));
      expect(find.text('Declined'), findsOneWidget);
    });

    testWidgets('one we are sending says it is waiting until bytes move', (
      tester,
    ) async {
      final sending = FileTransfer.running(
        id: BigInt.one,
        filename: 'photo.jpg',
        incoming: false,
        total: BigInt.from(2048),
      );
      await tester.pumpWidget(host(sending));
      expect(find.text('Waiting for them to accept · 2 KB'), findsOneWidget);
      expect(find.text('0 B / 2 KB'), findsNothing);

      sending.transferred = BigInt.from(1024);
      await tester.pump();
      expect(find.text('1 KB / 2 KB'), findsOneWidget);
    });

    testWidgets('one we sent says it was sent, and is not tappable', (
      tester,
    ) async {
      final transfer =
          FileTransfer.running(
              id: BigInt.one,
              filename: 'photo.jpg',
              incoming: false,
              total: BigInt.from(2048),
            )
            ..transferred = BigInt.from(2048)
            ..finish();
      await tester.pumpWidget(host(transfer, onReveal: () {}));

      expect(find.text('2 KB · Sent'), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(button('Show photo.jpg in its folder'), findsNothing);
    });

    testWidgets(
      'names who offered it in a channel, and not in a private chat',
      (tester) async {
        await tester.pumpWidget(host(offer(), showSender: true));
        expect(find.text('alice'), findsOneWidget);

        await tester.pumpWidget(host(offer(), showSender: false));
        expect(find.text('alice'), findsNothing);
      },
    );

    testWidgets(
      'what we sent sits on the right and what we were sent on the left',
      (tester) async {
        await tester.pumpWidget(host(offer()));
        final received = tester.getRect(find.byType(Container).first);
        expect(received.left, lessThan(300));

        final sent = FileTransfer.running(
          id: BigInt.two,
          filename: 'out.bin',
          incoming: false,
          total: BigInt.from(10),
        );
        await tester.pumpWidget(host(sent));
        final outgoing = tester.getRect(find.byType(Container).first);
        expect(outgoing.right, greaterThan(500));
      },
    );

    testWidgets('fits a phone: a long name wraps instead of overflowing', (
      tester,
    ) async {
      final transfer = FileTransfer.offered(
        id: BigInt.one,
        filename: '${'a-very-long-file-name-' * 6}.tar.gz',
        from: 'alice',
        total: BigInt.from(2048),
        isReverse: false,
      );
      await tester.pumpWidget(host(transfer, width: 360));

      expect(tester.takeException(), isNull);
    });
  });

  group('in the conversation', () {
    late AppSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load();
    });

    Future<void> pump(
      WidgetTester tester,
      Conversation conversation, {
      ValueChanged<FileTransfer>? onAccept,
      ValueChanged<FileTransfer>? onCancel,
      bool proxied = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: SettingsScope(
            settings: settings,
            child: Scaffold(
              body: MessageView(
                conversation: conversation,
                onAcceptFile: onAccept,
                onCancelFile: onCancel,
                proxyBlocksReverseOffers: proxied,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a file offer is a card among the messages, and is accepted there',
      (tester) async {
        final s = await _session();
        _joined(s, '#chat');
        s.receiveForTesting(_offer());
        FileTransfer? accepted;

        await pump(tester, _named(s, '#chat'), onAccept: (t) => accepted = t);

        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('alice says 2 KB'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Download report.pdf'));
        expect(accepted?.filename, 'report.pdf');
      },
    );

    testWidgets('there is no bar, and no prompt over the message box', (
      tester,
    ) async {
      // The old design put Accept and Decline in a bar above the composer. They
      // are on the message now, and nowhere else.
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      await pump(tester, _named(s, '#chat'));

      expect(find.text('Accept'), findsNothing);
      expect(find.text('Decline'), findsOneWidget, reason: 'on the card');
    });

    testWidgets(
      'an offer in a request that has not been let in cannot be taken',
      (tester) async {
        final s = await _session();
        s.receiveForTesting(_offer(channel: 'stranger', from: 'stranger'));
        final chat = _named(s, 'stranger')..pending = true;
        var accepted = 0;

        await pump(tester, chat, onAccept: (_) => accepted++);

        expect(
          find.text('Accept their message request to download this'),
          findsOneWidget,
        );
        await tester.tap(find.byIcon(Icons.arrow_downward_rounded));
        expect(accepted, 0);
      },
    );

    testWidgets('a reverse offer through a proxy says it cannot be accepted', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer(port: null));

      await pump(tester, _named(s, '#chat'), proxied: true);

      expect(
        find.text(
          'Cannot accept through a proxy — it would reveal your address',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a direct offer through a proxy can still be accepted', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());

      await pump(tester, _named(s, '#chat'), proxied: true);

      expect(find.bySemanticsLabel('Download report.pdf'), findsOneWidget);
    });

    testWidgets('the same card follows the file from offer to received', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      await pump(tester, _named(s, '#chat'));
      expect(find.text('alice says 2 KB'), findsOneWidget);

      s.receiveForTesting(_started());
      s.receiveForTesting(_progress(1024));
      await tester.pump();
      expect(find.text('1 KB / 2 KB'), findsOneWidget);

      s.receiveForTesting(_ended(path: '/data/received/report.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('report.pdf'), findsOneWidget, reason: 'still one card');
      expect(find.textContaining('private storage'), findsOneWidget);
    });
  });

  group('where a received file is saved', () {
    late Directory root;
    late Directory downloads;
    late Directory support;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ddirc-saved-');
      downloads = Directory('${root.path}${Platform.pathSeparator}Downloads')
        ..createSync();
      support = Directory('${root.path}${Platform.pathSeparator}support')
        ..createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<Directory> where(
      TargetPlatform platform, {
      Future<Directory?> Function()? downloadsFn,
    }) => receivedFilesDirectory(
      platform: platform,
      downloads: downloadsFn ?? () async => downloads,
      support: () async => support,
    );

    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      test('on $platform it is a ddIRC folder inside Downloads', () async {
        final dir = await where(platform);
        expect(dir.path, '${downloads.path}${Platform.pathSeparator}ddIRC');
        expect(dir.existsSync(), isTrue);
      });
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test(
        'on $platform it is private storage, and Downloads is never asked',
        () async {
          final dir = await where(
            platform,
            downloadsFn: () async => throw StateError('asked for Downloads'),
          );
          expect(dir.path, '${support.path}${Platform.pathSeparator}received');
          expect(dir.existsSync(), isTrue);
        },
      );
    }

    test(
      'a computer that will not say where Downloads is still gets a home',
      () async {
        final none = await where(
          TargetPlatform.windows,
          downloadsFn: () async => null,
        );
        expect(none.path, '${support.path}${Platform.pathSeparator}received');

        final broken = await where(
          TargetPlatform.linux,
          downloadsFn: () async => throw const FileSystemException('no xdg'),
        );
        expect(broken.path, '${support.path}${Platform.pathSeparator}received');
      },
    );

    test('nothing is created until something is saved', () async {
      expect(
        Directory('${downloads.path}${Platform.pathSeparator}ddIRC')
            .existsSync(),
        isFalse,
      );
    });

    test('the settings say where, for the device it is', () {
      expect(
        receivedFilesWhere(platform: TargetPlatform.windows),
        contains('"ddIRC" folder inside your Downloads'),
      );
      expect(
        receivedFilesWhere(platform: TargetPlatform.android),
        contains('private storage'),
      );
      expect(
        receivedFilesWhere(platform: TargetPlatform.iOS),
        contains('private storage'),
      );
    });

    test('a path is described as a place, not a long string', () {
      expect(
        describeLocation(r'C:\Users\me\Downloads\ddIRC\a.pdf', separator: r'\'),
        r'Downloads\ddIRC',
      );
      expect(
        describeLocation('/home/me/Downloads/ddIRC/a.pdf', separator: '/'),
        'Downloads/ddIRC',
      );
      expect(
        describeLocation('/data/user/0/dev.ddirc/files/received/a.pdf'),
        'private storage',
      );
      expect(describeLocation('a.pdf'), 'a.pdf');
    });
  });

  group('the send confirmation', () {
    final clean = CleanedFile(
      bytes: Uint8List(0),
      state: CleanState.alreadyClean,
    );
    final unknown = CleanedFile(
      bytes: Uint8List(0),
      state: CleanState.notAnImage,
    );

    Future<ValueNotifier<bool?>> open(
      WidgetTester tester, {
      String target = '#chat',
      CleanedFile? cleaned,
    }) async {
      final answer = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async => answer.value = await SendFileSheet.ask(
                    context,
                    filename: 'holiday.png',
                    target: target,
                    cleaned: cleaned ?? clean,
                    sizeBytes: 2048,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('says what is leaving and where it is going', (tester) async {
      await open(tester, target: 'alice');
      expect(find.text('Send this file?'), findsOneWidget);
      expect(find.text('holiday.png'), findsOneWidget);
      expect(find.text('2 KB → alice'), findsOneWidget);
    });

    testWidgets('to a person, says they will learn your address', (
      tester,
    ) async {
      await open(tester, target: 'alice');
      expect(
        find.textContaining('alice has to connect to this machine'),
        findsOneWidget,
      );
      expect(find.textContaining('they will learn it'), findsOneWidget);
    });

    testWidgets('to a channel, says everyone in it will see it', (
      tester,
    ) async {
      await open(tester, target: '#chat');
      expect(
        find.textContaining('everyone in #chat will see it'),
        findsOneWidget,
      );
    });

    testWidgets(
      'reports what the stripper did, including that it did nothing',
      (tester) async {
        await open(tester, cleaned: unknown);
        expect(find.text(unknown.describe()), findsOneWidget);
        expect(unknown.carriesUnknownData, isTrue);
      },
    );

    testWidgets('sends only when told to', (tester) async {
      final answer = await open(tester);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(answer.value, isTrue);
    });

    testWidgets('cancelling is not agreeing', (tester) async {
      final answer = await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answer.value, isFalse);
    });

    testWidgets('walking away from it is not agreeing either', (tester) async {
      final answer = await open(tester);
      // Tap the dimmed area outside the dialog.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(answer.value, isFalse);
    });
  });

  group('the settings, and the consent in them', () {
    Future<({AppSettings settings, ProxySettings proxies})> pump(
      WidgetTester tester, {
      bool on = false,
      bool tor = false,
    }) async {
      // Tall, because the consent dialog is long and its list is lazy: on the
      // default surface its buttons are below the fold and never built.
      await tester.binding.setSurfaceSize(const Size(800, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      settings.fileTransfers = on;
      final proxies = await ProxySettings.load();
      if (tor) await proxies.useBuiltIn(true);
      await tester.pumpWidget(
        SettingsScope(
          settings: settings,
          child: ProxyScope(
            settings: proxies,
            child: MaterialApp(
              theme: Tokens.themeFor(Tokens.dark),
              home: const Scaffold(
                body: SingleChildScrollView(child: FileTransferSection()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (settings: settings, proxies: proxies);
    }

    /// The dialog is a card with a lazily built list in it, so what is below
    /// the fold does not exist until somebody scrolls to it. This scrolls the
    /// way a person would and keeps every piece of text that ever appeared.
    Future<String> readWholeDialog(WidgetTester tester) async {
      final seen = <String>[];
      void collect() {
        for (final e in find.byType(Text).evaluate()) {
          final w = e.widget as Text;
          final t = w.data ?? w.textSpan?.toPlainText() ?? '';
          if (!seen.contains(t)) seen.add(t);
        }
      }

      final scrollable = find.byType(Scrollable).last;
      collect();
      for (var i = 0; i < 40; i++) {
        await tester.drag(scrollable, const Offset(0, -120));
        await tester.pump();
        collect();
      }
      return seen.join('\n');
    }

    Future<void> reveal(WidgetTester tester, String label) =>
        tester.scrollUntilVisible(
          find.text(label),
          200,
          scrollable: find.byType(Scrollable).last,
        );

    testWidgets('is off, and turning it on asks before it does anything', (
      tester,
    ) async {
      final (:settings, proxies: _) = await pump(tester);
      expect(settings.fileTransfers, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('Before you turn this on'), findsOneWidget);
      expect(settings.fileTransfers, isFalse, reason: 'not on until agreed to');
    });

    testWidgets('"Leave it off" leaves it off', (tester) async {
      final (:settings, proxies: _) = await pump(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await reveal(tester, 'Leave it off');
      await tester.tap(find.text('Leave it off'));
      await tester.pumpAndSettle();

      expect(settings.fileTransfers, isFalse);
      expect(find.text('Before you turn this on'), findsNothing);
    });

    testWidgets('"Turn it on" turns it on, and the facts about it appear', (
      tester,
    ) async {
      final (:settings, proxies: _) = await pump(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await reveal(tester, 'Turn it on');
      await tester.tap(find.text('Turn it on'));
      await tester.pumpAndSettle();

      expect(settings.fileTransfers, isTrue);
      expect(find.text('Received files'), findsOneWidget);
      expect(find.text(receivedFilesWhere()), findsOneWidget);
    });

    testWidgets('turning it off needs no ceremony', (tester) async {
      final (:settings, proxies: _) = await pump(tester, on: true);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(settings.fileTransfers, isFalse);
      expect(find.text('Before you turn this on'), findsNothing);
    });

    testWidgets('the dialog describes what the feature does now', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      final text = await readWholeDialog(tester);

      // It used to say accepting was not built yet. It is, and the dialog a
      // person reads to give consent is the last place for that to be wrong.
      expect(text, isNot(contains('no way to accept')));
      expect(text, isNot(contains('when it is built')));
      expect(
        text,
        contains('accept what is offered and send files of your own'),
      );
      expect(text, contains('nothing is ever accepted for you'));
      // What is still refused behind a proxy is said, both ways round.
      expect(text, contains('sending is refused'));
      expect(text, contains('an offer that asks you to listen for the sender'));

      // And the four things that cost somebody something are all still there.
      for (final heading in [
        'Sending gives away where you are',
        'You connect to an address a stranger chose',
        'The file is not checked',
        'With no proxy, it is a direct connection',
      ]) {
        expect(text, contains(heading), reason: heading);
      }
    });

    testWidgets('without a proxy there is no note about one', (tester) async {
      await pump(tester, on: true);
      expect(find.textContaining('Built-in Tor is on'), findsNothing);
    });

    testWidgets('behind Tor it says what is refused, both ways round', (
      tester,
    ) async {
      await pump(tester, on: true, tor: true);

      expect(find.textContaining('Built-in Tor is on'), findsOneWidget);
      expect(find.textContaining('Sending is refused'), findsOneWidget);
      expect(
        find.textContaining('asks you to listen for the sender is refused too'),
        findsOneWidget,
      );
    });
  });
}
