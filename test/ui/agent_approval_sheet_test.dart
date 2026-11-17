// The sheet is the whole of the promise that nothing is sent without the user,
// so what matters is that the answers that send cannot be given unread.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/mcp.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/agent_approval_sheet.dart';

void main() {
  McpSendRequest request(String text, {String conversation = '#chat'}) =>
      McpSendRequest(
        profileId: 'p',
        networkName: 'Libera',
        conversation: conversation,
        text: text,
      );

  Future<void> pump(WidgetTester tester, McpSendRequest request) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: Scaffold(body: AgentApprovalSheet(request: request)),
      ),
    );
    await tester.pump();
  }

  bool enabled(WidgetTester tester, String label) =>
      tester
          .widget<ButtonStyleButton>(
            find.ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            ),
          )
          .onPressed !=
      null;

  testWidgets('a message that fits can be answered at once', (tester) async {
    await pump(tester, request('hello there'));

    expect(enabled(tester, 'Send'), isTrue);
    expect(enabled(tester, 'Allow in #chat for a day'), isTrue);
    expect(find.text('1 line · 11 characters'), findsOneWidget);
  });

  testWidgets('a long one cannot be sent until its end has been seen', (
    tester,
  ) async {
    final long = [
      'a harmless first line',
      for (var i = 0; i < 60; i++) 'more $i',
    ];
    await pump(tester, request(long.join('\n')));

    expect(enabled(tester, 'Send'), isFalse);
    expect(enabled(tester, 'Allow in #chat for a day'), isFalse);
    expect(enabled(tester, "Don't send"), isTrue, reason: 'never held back');
    expect(
      find.text('61 lines · ${long.join('\n').length} characters'),
      findsOneWidget,
    );
    expect(find.textContaining('Scroll to the end'), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    await tester.pump();
    expect(enabled(tester, 'Send'), isFalse, reason: 'partway is not the end');

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -9000),
    );
    await tester.pumpAndSettle();
    expect(enabled(tester, 'Send'), isTrue);
    expect(find.textContaining('Scroll to the end'), findsNothing);

    // Going back to reread takes nothing away.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, 9000),
    );
    await tester.pumpAndSettle();
    expect(enabled(tester, 'Send'), isTrue);
  });

  testWidgets('a direct message has no way to be allowed', (tester) async {
    await pump(
      tester,
      McpSendRequest(
        profileId: 'p',
        networkName: 'Libera',
        conversation: 'bob',
        text: 'hello',
        canAllow: false,
      ),
    );

    expect(find.textContaining('for a day'), findsNothing);
    expect(enabled(tester, 'Send'), isTrue);
  });

  group('when the request ends without an answer', () {
    Future<void> openSheets(
      WidgetTester tester,
      List<McpSendRequest> requests,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                for (final request in requests) {
                  AgentApprovalSheet.show(context, request);
                }
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the sheet closes, rather than offer a Send that does nothing',
      (tester) async {
        final timedOut = request('hello');
        await openSheets(tester, [timedOut]);
        expect(find.text('hello'), findsOneWidget);

        timedOut.decide(McpDecision.deny);
        await tester.pumpAndSettle();

        expect(find.text('hello'), findsNothing);
        expect(find.text('open'), findsOneWidget);
      },
    );

    testWidgets('and it takes itself away, not the sheet on top of it', (
      tester,
    ) async {
      final under = request('underneath');
      final over = request('on top');
      await openSheets(tester, [under, over]);

      under.decide(McpDecision.deny);
      await tester.pumpAndSettle();

      expect(find.text('underneath'), findsNothing);
      expect(find.text('on top'), findsOneWidget);
    });

    testWidgets('an answer given is the answer, and closes it once', (
      tester,
    ) async {
      final answered = request('hello');
      McpDecision? got;
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  AgentApprovalSheet.show(context, answered).then((decision) {
                    got = decision;
                    answered.decide(decision ?? McpDecision.deny);
                  }),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(got, McpDecision.once);
      expect(
        find.text('open'),
        findsOneWidget,
        reason: 'nothing else was closed',
      );
    });
  });

  testWidgets('anything invisible is shown, and in the names too', (
    tester,
  ) async {
    await pump(tester, request('a\u200Bb', conversation: '#ch\u202Eat'));

    expect(find.text('a⟦U+200B⟧b'), findsOneWidget);
    expect(find.textContaining('#ch⟦U+202E⟧at on Libera'), findsOneWidget);
  });
}
