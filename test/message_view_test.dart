// Tests for how a message row is drawn.
//
// Three things a busy channel needs to be readable, each of which was
// missing: your own messages set apart by shape, a time beside every line
// rather than one at the top of a run, and a name for the day when the
// scrollback crosses one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/people.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/message_view.dart';
import 'package:ddirc/src/ui/nick_color.dart';

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

ChatLine _said(
  String sender,
  String text, {
  bool isSelf = false,
  DateTime? at,
}) => ChatLine.message(
  rust.ChatMessage(
    target: const rust.Target.channel(name: '#test'),
    sender: sender,
    spans: [rust.TextSpan(text: text, style: _plain)],
    isSelf: isSelf,
    isMention: false,
    isAction: false,
    isNotice: false,
  ),
  at ?? DateTime(2026, 1, 1, 9),
);

Conversation _conversation(List<ChatLine> lines) {
  final conversation = Conversation(name: '#test', isChannel: true);
  conversation.lines.addAll(lines);
  return conversation;
}

Future<AppSettings> _pump(
  WidgetTester tester,
  Conversation conversation, {
  Map<String, Object> prefs = const {},
  String? profileId,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final settings = await AppSettings.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: SettingsScope(
        settings: settings,
        child: Scaffold(
          body: MessageView(conversation: conversation, profileId: profileId),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

/// The colour of the leading spine on the row [text] sits in, if it has one.
Color? _spineOf(WidgetTester tester, String text) {
  final rows = find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final d = w.decoration;
      return d is BoxDecoration &&
          d.border is Border &&
          d.border!.top == BorderSide.none &&
          (d.border! as Border).left.width > 0;
    }),
  );
  if (rows.evaluate().isEmpty) return null;
  final decoration =
      tester.widget<Container>(rows.first).decoration! as BoxDecoration;
  return (decoration.border! as Border).left.color;
}

/// The tinted block around [text], if it sits in one.
Container? _blockAround(WidgetTester tester, String text) {
  final blocks = find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == Tokens.dark.own,
    ),
  );
  return blocks.evaluate().isEmpty ? null : tester.widget<Container>(blocks);
}

Color? _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  testWidgets('own messages sit in a block on the right; others do not', (
    tester,
  ) async {
    await _pump(
      tester,
      _conversation([
        _said('alice', 'the build is green'),
        _said(
          'me',
          'shipping it',
          isSelf: true,
          at: DateTime(2026, 1, 1, 9, 5),
        ),
      ]),
    );

    expect(_blockAround(tester, 'the build is green'), isNull);
    expect(_blockAround(tester, 'shipping it'), isNotNull);

    final theirs = tester.getRect(find.text('the build is green'));
    final mine = tester.getRect(find.text('shipping it'));
    expect(mine.right, greaterThan(theirs.right), reason: 'mine on the right');
    expect(mine.left, greaterThan(theirs.left));
  });

  testWidgets('a run of messages carries one time, beside the name', (
    tester,
  ) async {
    // Two lines from one person a minute apart: grouped, so the second has
    // no sender label and no time of its own — a time on every line was
    // tried and was noise.
    await _pump(
      tester,
      _conversation([
        _said('alice', 'first', at: DateTime(2026, 1, 1, 9, 0)),
        _said('alice', 'second', at: DateTime(2026, 1, 1, 9, 1)),
      ]),
    );

    expect(find.text('alice'), findsOneWidget, reason: 'grouped: one label');
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('09:01'), findsNothing, reason: 'and one time');
  });

  testWidgets('times can still be turned off', (tester) async {
    await _pump(
      tester,
      _conversation([_said('alice', 'first')]),
      prefs: {'ui.timestamps': false},
    );
    expect(find.text('09:00'), findsNothing);
  });

  testWidgets('a change of day gets a rule, and the first line its day', (
    tester,
  ) async {
    await _pump(
      tester,
      _conversation([
        _said('alice', 'late', at: DateTime(2026, 1, 1, 23, 59)),
        _said('alice', 'early', at: DateTime(2026, 1, 2, 0, 1)),
        _said('alice', 'later', at: DateTime(2026, 1, 2, 0, 2)),
      ]),
    );

    // Neither is today, so both are dated; a fixed clock is not available
    // to the view, which is why the labels are asserted by shape.
    expect(find.textContaining('1 January'), findsOneWidget);
    expect(find.textContaining('2 January'), findsOneWidget);
    expect(
      find.text('alice'),
      findsNWidgets(2),
      reason: 'the day rule breaks the run: a new day names its speaker',
    );
  });

  testWidgets('nicks wear their colour; yours wears the accent', (
    tester,
  ) async {
    await _pump(
      tester,
      _conversation([
        _said('alice', 'hi'),
        _said('me', 'hello', isSelf: true, at: DateTime(2026, 1, 1, 9, 5)),
      ]),
    );
    expect(_colorOf(tester, 'alice'), NickPalette.of('alice', Tokens.dark));
    expect(_colorOf(tester, 'me'), Tokens.dark.accent);
  });

  testWidgets('with the switch off, nicks go back to grey', (tester) async {
    await _pump(
      tester,
      _conversation([_said('alice', 'hi')]),
      prefs: {'ui.nickColors': false},
    );
    expect(_colorOf(tester, 'alice'), Tokens.dark.muted);
  });

  group('the colour spine', () {
    setUp(() => People.instance.resetForTest());
    tearDown(() => People.instance.resetForTest());

    testWidgets('carries a chosen colour down a whole run, labels and all', (
      tester,
    ) async {
      const chosen = Color(0xFF123456);
      People.instance.set('p1', 'alice', const PersonCard(color: chosen));
      await _pump(
        tester,
        _conversation([
          _said('alice', 'first', at: DateTime(2026, 1, 1, 9, 0)),
          _said('alice', 'second', at: DateTime(2026, 1, 1, 9, 1)),
        ]),
        profileId: 'p1',
      );

      // The second line is a grouped continuation with no name of its own —
      // the case the label alone could not colour. The spine reaches it, at
      // nearly full strength because the colour was chosen on purpose.
      expect(_spineOf(tester, 'first'), chosen.withValues(alpha: 0.9));
      expect(
        _spineOf(tester, 'second'),
        chosen.withValues(alpha: 0.9),
        reason: 'the continuation line is coloured too',
      );
    });

    testWidgets('a hashed colour is only a faint hint', (tester) async {
      await _pump(
        tester,
        _conversation([_said('alice', 'hi')]),
        profileId: 'p1',
      );
      expect(
        _spineOf(tester, 'hi'),
        NickPalette.of('alice', Tokens.dark).withValues(alpha: 0.4),
      );
    });

    testWidgets('your own messages have none', (tester) async {
      await _pump(
        tester,
        _conversation([_said('me', 'mine', isSelf: true)]),
        profileId: 'p1',
      );
      expect(_spineOf(tester, 'mine'), isNull);
    });

    testWidgets('with nick colours off, an unnamed person has none', (
      tester,
    ) async {
      await _pump(
        tester,
        _conversation([_said('alice', 'hi')]),
        prefs: {'ui.nickColors': false},
        profileId: 'p1',
      );
      expect(_spineOf(tester, 'hi'), isNull);
    });
  });
}
