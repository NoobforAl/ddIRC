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
import 'package:ddirc/src/ui/transfer_bar.dart';

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

    test('an offer is incoming, and has not been answered', () {
      final offer = FileTransfer.offered(
        id: BigInt.one,
        filename: 'f',
        from: 'alice',
        total: null,
        isReverse: false,
      );
      expect(offer.incoming, isTrue);
      expect(offer.stage, TransferStage.offered);
      expect(offer.transferred, BigInt.zero);
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
      expect(chat.transfers, isEmpty, reason: 'no row to answer');
      expect(
        _said(chat).where((l) => l.contains('offered')),
        isEmpty,
        reason: 'and no line: an off switch must not be a prompt to turn it on',
      );
    });

    test('becomes a row to answer and a line to remember, once on', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());

      final chat = _named(s, '#chat');
      expect(chat.transfers, hasLength(1));
      final row = chat.transfers.single;
      expect(row.stage, TransferStage.offered);
      expect(row.filename, 'report.pdf');
      expect(row.from, 'alice');
      expect(row.total, BigInt.from(2048));
      expect(row.isReverse, isFalse);

      // The size is the sender's claim and is written as one.
      final line = _said(chat).singleWhere((l) => l.contains('offered you'));
      expect(line, contains('"report.pdf"'));
      expect(line, contains('says it is 2 KB'));
    });

    test('an offer with no address to dial is a reverse one', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer(port: null));
      expect(_named(s, '#chat').transfers.single.isReverse, isTrue);
    });

    test('is never answered by the session on its own', () async {
      // Nothing here could answer: an offer arriving changes what is on
      // screen and nothing else, and the row stays until a person acts on it.
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_offer(id: 2, filename: 'second.zip'));

      final transfers = _named(s, '#chat').transfers;
      expect(
        transfers.map((t) => t.stage),
        everyElement(TransferStage.offered),
      );
      expect(transfers.map((t) => t.filename), ['report.pdf', 'second.zip']);
    });

    test('a private offer is filed under the person who made it', () async {
      final s = await _session();
      s.receiveForTesting(_offer(channel: 'alice'));
      expect(_named(s, 'alice').transfers, hasLength(1));
    });
  });

  group('the session, on a transfer', () {
    test('an accepted offer becomes the transfer, not a second row', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());

      final transfers = _named(s, '#chat').transfers;
      expect(transfers, hasLength(1));
      expect(transfers.single.stage, TransferStage.running);
      expect(transfers.single.incoming, isTrue);
      expect(transfers.single.from, isNull, reason: 'it is about the file now');
    });

    test('progress moves the row it belongs to and no other', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());
      s.receiveForTesting(_started(id: 2, incoming: false));
      s.receiveForTesting(_progress(1024, id: 1));

      final byId = {for (final t in _named(s, '#chat').transfers) t.id: t};
      expect(byId[BigInt.one]!.transferred, BigInt.from(1024));
      expect(byId[BigInt.two]!.transferred, BigInt.zero);

      // And one for a transfer that is not there is not an error.
      s.receiveForTesting(_progress(5, id: 99));
    });

    test(
      'finishing removes the row, says where the file went, and tells you',
      () async {
        final s = await _session();
        _joined(s, '#chat');
        s.receiveForTesting(_offer());
        s.receiveForTesting(_started());
        s.receiveForTesting(_ended(path: '/data/received/report.pdf'));

        final chat = _named(s, '#chat');
        expect(chat.transfers, isEmpty);
        expect(
          _said(chat),
          contains('saved "report.pdf" to /data/received/report.pdf'),
        );
        expect(s.notice?.level, NoticeLevel.info);
        expect(s.notice?.message, 'Saved "report.pdf"');
        expect(s.notice?.detail, '/data/received/report.pdf');
      },
    );

    test('a transfer that fails is a failure, not a muted line', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      s.receiveForTesting(_started());
      s.receiveForTesting(_ended(error: 'connection reset'));

      final chat = _named(s, '#chat');
      expect(chat.transfers, isEmpty);
      expect(
        _said(chat),
        contains('transfer of "report.pdf" failed: connection reset'),
      );
      expect(s.notice, isNotNull);
      expect(s.notice!.level, isNot(NoticeLevel.info));
    });

    test(
      'a file we sent is "sent", with nothing about where it went',
      () async {
        final s = await _session();
        _joined(s, '#chat');
        s.receiveForTesting(_started(incoming: false));
        s.receiveForTesting(_ended());

        expect(_said(_named(s, '#chat')), contains('sent "report.pdf"'));
        expect(s.notice?.message, 'Sent "report.pdf"');
      },
    );

    test('declining takes the row away at once', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());

      // Not awaited before looking: the row goes when the user says no, not
      // when the core has finished hearing about it.
      final answered = s.cancelTransfer(BigInt.one);
      expect(_named(s, '#chat').transfers, isEmpty);
      await answered;
    });
  });

  group('the transfer bar', () {
    Widget host(
      SessionModel s,
      Conversation c, {
      void Function(FileTransfer)? onAccept,
    }) => MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: s,
          builder: (_, _) => TransferBar(
            session: s,
            conversation: c,
            onAccept: onAccept ?? (_) {},
          ),
        ),
      ),
    );

    testWidgets('is nothing at all when there is nothing to answer', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      await tester.pumpWidget(host(s, _named(s, '#chat')));

      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets(
      'an offer says who, how big they claim, and offers both answers',
      (tester) async {
        final s = await _session();
        _joined(s, '#chat');
        s.receiveForTesting(_offer());
        await tester.pumpWidget(host(s, _named(s, '#chat')));

        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('alice says it is 2 KB'), findsOneWidget);
        expect(find.text('Accept'), findsOneWidget);
        expect(find.text('Decline'), findsOneWidget);
      },
    );

    testWidgets('accepting asks the screen to take it up, and nothing else', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      FileTransfer? accepted;
      await tester.pumpWidget(
        host(s, _named(s, '#chat'), onAccept: (t) => accepted = t),
      );

      await tester.tap(find.text('Accept'));
      await tester.pump();

      expect(accepted?.filename, 'report.pdf');
      // The row waits for the core to say it has started; the bar does not
      // assume it has.
      expect(_named(s, '#chat').transfers, hasLength(1));
    });

    testWidgets('declining removes the row and does not ask to accept', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer());
      var accepted = false;
      await tester.pumpWidget(
        host(s, _named(s, '#chat'), onAccept: (_) => accepted = true),
      );

      await tester.tap(find.text('Decline'));
      await tester.pump();

      expect(accepted, isFalse);
      expect(find.text('report.pdf'), findsNothing);
      expect(_named(s, '#chat').transfers, isEmpty);
    });

    testWidgets(
      'a reverse offer through a proxy cannot be accepted, and says why',
      (tester) async {
        final s = await _session(
          proxy: const rust.ProxyConfig(host: '127.0.0.1', port: 9050),
        );
        _joined(s, '#chat');
        s.receiveForTesting(_offer(port: null));
        await tester.pumpWidget(host(s, _named(s, '#chat')));

        // Listening would tell the sender where you are, which is what the proxy
        // is for. The button that could only fail is withheld; the way out stays.
        expect(find.text('Accept'), findsNothing);
        expect(
          find.text(
            'Cannot accept through a proxy — it would reveal your address',
          ),
          findsOneWidget,
        );
        expect(find.text('Decline'), findsOneWidget);
      },
    );

    testWidgets(
      'a direct offer through a proxy can be accepted — it is dialled through it',
      (tester) async {
        final s = await _session(
          proxy: const rust.ProxyConfig(host: '127.0.0.1', port: 9050),
        );
        _joined(s, '#chat');
        s.receiveForTesting(_offer());
        await tester.pumpWidget(host(s, _named(s, '#chat')));

        expect(find.text('Accept'), findsOneWidget);
      },
    );

    testWidgets('a reverse offer with no proxy can be accepted', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_offer(port: null));
      await tester.pumpWidget(host(s, _named(s, '#chat')));

      expect(find.text('Accept'), findsOneWidget);
    });

    testWidgets(
      'a running transfer shows how far it has got, and can be stopped',
      (tester) async {
        final s = await _session();
        _joined(s, '#chat');
        s.receiveForTesting(_offer());
        s.receiveForTesting(_started());
        s.receiveForTesting(_progress(1024));
        await tester.pumpWidget(host(s, _named(s, '#chat')));

        expect(find.text('receiving — 1 KB of 2 KB'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          0.5,
        );
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Accept'), findsNothing, reason: 'already answered');
      },
    );

    testWidgets('a sender who gave no size gets an honest, indeterminate bar', (
      tester,
    ) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_started(total: null));
      s.receiveForTesting(_progress(3000));
      await tester.pumpWidget(host(s, _named(s, '#chat')));

      expect(find.text('receiving — 3 KB so far'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
    });

    testWidgets('an outgoing transfer says it is sending', (tester) async {
      final s = await _session();
      _joined(s, '#chat');
      s.receiveForTesting(_started(incoming: false));
      await tester.pumpWidget(host(s, _named(s, '#chat')));

      expect(find.textContaining('sending'), findsOneWidget);
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
      expect(
        find.text('Saved inside ddIRC, not in your Downloads folder'),
        findsOneWidget,
      );
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
