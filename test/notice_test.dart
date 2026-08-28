// How loudly the app says things.
//
// The judgement being protected: a refusal that is the app keeping a promise
// is not a fault. Declining to send a file from behind Tor is the proxy doing
// its job, and painting it the same red as "the disk is full" is how people
// learn that red means nothing. That classification lives in one place so it
// cannot drift between the half-dozen call sites that show a message.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/notice.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/notice_bar.dart';

void main() {
  group('classifying a failure', () {
    // The exact strings the Rust core produces for its two protective
    // refusals. If either is reworded without updating the classifier, these
    // fail — which is the point: a refusal quietly demoted to a red error is a
    // regression nobody would otherwise notice.
    test('refusing to publish an address while sending is a warning', () {
      final notice = noticeForFailure(
        'sending a file would publish your address, which is the thing the '
        'proxy is there to hide. Send with the proxy off for this network, or '
        'ask them to send to you instead.',
      );

      expect(notice.level, NoticeLevel.warning);
      expect(notice.message, 'Not sent — that would give away your address');
      // The core's own words are kept underneath, because they say what to do.
      expect(notice.detail, contains('proxy off for this network'));
    });

    test('refusing a reverse offer behind a proxy is a warning too', () {
      final notice = noticeForFailure(
        'this offer asks your client to accept a connection, which would tell '
        'the sender your address and defeat the proxy. Ask them to send it '
        'normally instead.',
      );
      expect(notice.level, NoticeLevel.warning);
    });

    test('an ordinary failure is an error, kept verbatim', () {
      final notice = noticeForFailure(
        'a file called \'cat.jpg\' is already there',
      );
      expect(notice.level, NoticeLevel.error);
      expect(notice.message, "a file called 'cat.jpg' is already there");
      expect(notice.detail, isNull);
    });

    test('cancelling is not a failure at all', () {
      expect(noticeForFailure('cancelled').level, NoticeLevel.info);
    });

    test('classification does not depend on the case it arrives in', () {
      expect(
        noticeForFailure('WOULD PUBLISH YOUR ADDRESS').level,
        NoticeLevel.warning,
      );
    });
  });

  group('a transfer that ended', () {
    // A download the user cannot find is a download that did not happen, so
    // the path is the message rather than a decoration on it.
    test('a received file says where it went', () {
      final notice = noticeForTransfer(
        filename: 'holiday.jpg',
        path: r'C:\Users\me\AppData\Roaming\ddIRC\received\holiday.jpg',
        error: null,
      );
      expect(notice!.level, NoticeLevel.info);
      expect(notice.message, 'Saved "holiday.jpg"');
      expect(notice.detail, contains('received'));
    });

    test('a sent file just confirms', () {
      final notice = noticeForTransfer(
        filename: 'holiday.jpg',
        path: null,
        error: null,
      );
      expect(notice!.level, NoticeLevel.info);
      expect(notice.message, 'Sent "holiday.jpg"');
    });

    test('a failure is classified like any other', () {
      final notice = noticeForTransfer(
        filename: 'holiday.jpg',
        path: null,
        error: 'nobody connected within 120 seconds',
      );
      expect(notice!.level, NoticeLevel.error);
    });

    // An error wins over a path: a transfer that failed after writing
    // something must never read as one that succeeded.
    test('an error wins over a path that came back with it', () {
      final notice = noticeForTransfer(
        filename: 'half.bin',
        path: '/somewhere/half.bin',
        error: 'the sender stopped after 4 of 100 bytes',
      );
      expect(notice!.level, NoticeLevel.error);
      expect(notice.message, isNot(contains('Saved')));
    });
  });

  group('how long it stays up', () {
    // Ten seconds is long enough to read a sentence and a path twice over, and
    // short enough that a bar nobody dismissed is not still there an hour
    // later. What makes an expiring alert safe is that nothing is *only* said
    // here — every failure worth keeping is also a line in the conversation.
    test('is ten seconds', () {
      expect(noticeLifetime, const Duration(seconds: 10));
    });

    test('is long enough to read a two-line notice', () {
      // Roughly 150 characters at a slow 200 words per minute. A limit that
      // clears the bar before an average reader finishes is not a limit, it is
      // a bug.
      const slowestWordsPerMinute = 200;
      const charactersPerWord = 5;
      final readable =
          noticeLifetime.inSeconds *
          slowestWordsPerMinute *
          charactersPerWord /
          60;
      expect(readable, greaterThan(150));
    });
  });

  group('the bar', () {
    Future<void> pump(WidgetTester tester, Notice notice, VoidCallback close) {
      return tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Scaffold(
            body: NoticeBar(notice: notice, onDismiss: close),
          ),
        ),
      );
    }

    testWidgets('shows the message and the detail under it', (tester) async {
      await pump(
        tester,
        const Notice.warning('Not sent', detail: 'it would give you away'),
        () {},
      );
      expect(find.text('Not sent'), findsOneWidget);
      expect(find.text('it would give you away'), findsOneWidget);
    });

    testWidgets('a notice with no detail shows only the message', (
      tester,
    ) async {
      await pump(tester, const Notice.error('Nick already taken'), () {});
      expect(find.text('Nick already taken'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('can be dismissed, which the old bar could not', (
      tester,
    ) async {
      var dismissed = 0;
      await pump(tester, const Notice.error('Boom'), () => dismissed++);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(dismissed, 1);
    });

    // Colour alone carries this for nobody with a red-green deficiency, which
    // is roughly one man in twelve. Each level gets its own icon.
    testWidgets('each level is told apart by more than its colour', (
      tester,
    ) async {
      await pump(tester, const Notice.error('e'), () {});
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      await pump(tester, const Notice.warning('w'), () {});
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);

      await pump(tester, const Notice.info('i'), () {});
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    // The icon and the colour are both invisible to a screen reader, so the
    // level has to be said out loud.
    testWidgets('announces its level to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const Notice.warning('Not sent', detail: 'why not'),
        () {},
      );

      expect(
        find.bySemanticsLabel('Warning. Not sent. why not'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('nothing is drawn when there is nothing to say', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Scaffold(body: NoticeReveal(notice: null, onDismiss: () {})),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NoticeBar), findsNothing);
    });
  });
}
