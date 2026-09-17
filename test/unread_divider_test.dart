// Tests for opening a conversation where reading stopped.
//
// A scrollback with sixty unread lines used to open at the bottom, which is
// the one place in it that says nothing about what was missed. It should open
// at the first unread line with a rule above it, stay put while more arrives,
// and offer a way back down that says how much is waiting there.
//
// The mechanism under test is a viewport anchored on the first unread row —
// the only way to put an unmeasured row at the top in one layout — with a
// fallback to the ordinary bottom-anchored list when the unread tail is
// short enough to fit. Both halves are exercised.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/message_view.dart';

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

ChatLine _said(String sender, String text, DateTime at) => ChatLine.message(
  rust.ChatMessage(
    target: const rust.Target.channel(name: '#test'),
    sender: sender,
    spans: [rust.TextSpan(text: text, style: _plain)],
    isSelf: false,
    isMention: false,
    isAction: false,
    isNotice: false,
  ),
  at,
);

/// [read] lines that were seen, then [unread] that were not, five minutes
/// apart so nothing groups and every row carries its own label.
Conversation _conversation({required int read, required int unread}) {
  final conversation = Conversation(name: '#test', isChannel: true);
  var at = DateTime(2026, 1, 1, 9);
  for (var i = 0; i < read; i++) {
    conversation.lines.add(_said('alice', 'read $i', at));
    at = at.add(const Duration(minutes: 5));
  }
  for (var i = 0; i < unread; i++) {
    final line = _said('bob', 'unread $i', at);
    conversation.lines.add(line);
    conversation.unreadMarker ??= line;
    at = at.add(const Duration(minutes: 5));
  }
  return conversation;
}

late AppSettings _settings;

Future<void> _pump(WidgetTester tester, Conversation conversation) async {
  SharedPreferences.setMockInitialValues({});
  _settings = await AppSettings.load();
  await _rebuild(tester, conversation);
}

/// Pump again with the same settings, as a repaint after new lines would.
Future<void> _rebuild(WidgetTester tester, Conversation conversation) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: SettingsScope(
        settings: _settings,
        child: Scaffold(body: MessageView(conversation: conversation)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _rule => find.text('New messages');
Finder get _button => find.byTooltip('Jump to latest');

/// A line is on screen if its text is laid out and inside the viewport.
bool _visible(WidgetTester tester, String text) {
  final finder = find.text(text);
  if (finder.evaluate().isEmpty) return false;
  final rect = tester.getRect(finder);
  final view = tester.getRect(find.byType(CustomScrollView));
  return rect.top >= view.top - 1 && rect.bottom <= view.bottom + 1;
}

void main() {
  testWidgets('a long unread tail opens at the rule, with the way down', (
    tester,
  ) async {
    await _pump(tester, _conversation(read: 60, unread: 60));

    expect(_rule, findsOneWidget);
    final view = tester.getRect(find.byType(CustomScrollView));
    expect(
      tester.getTopLeft(_rule).dy,
      closeTo(view.top + 6, 12),
      reason: 'the rule sits at the top of the viewport',
    );
    expect(_visible(tester, 'unread 0'), isTrue);
    expect(find.text('read 20'), findsNothing, reason: 'far above: not built');
    expect(
      find.text('unread 59'),
      findsNothing,
      reason: 'far below: not built',
    );

    expect(_button, findsOneWidget);
    expect(find.text('60'), findsOneWidget, reason: 'sixty below the reader');
  });

  testWidgets('a short unread tail opens at the bottom, rule a few rows up', (
    tester,
  ) async {
    await _pump(tester, _conversation(read: 60, unread: 3));

    expect(_rule, findsOneWidget);
    expect(_visible(tester, 'unread 2'), isTrue, reason: 'the last line shows');
    expect(_visible(tester, 'New messages'), isTrue);
    expect(_button, findsNothing, reason: 'already at the bottom');
  });

  testWidgets('nothing unread opens at the bottom with no rule', (
    tester,
  ) async {
    await _pump(tester, _conversation(read: 60, unread: 0));
    expect(_rule, findsNothing);
    expect(_visible(tester, 'read 59'), isTrue);
    expect(_button, findsNothing);
  });

  testWidgets('everything unread is nowhere to open but the bottom', (
    tester,
  ) async {
    await _pump(tester, _conversation(read: 0, unread: 60));
    expect(_rule, findsNothing);
    expect(_visible(tester, 'unread 59'), isTrue);
  });

  testWidgets('arrivals while reading do not move the page, and are counted', (
    tester,
  ) async {
    final conversation = _conversation(read: 60, unread: 60);
    await _pump(tester, conversation);
    final before = tester.getTopLeft(_rule);

    conversation.lines.add(_said('bob', 'late 0', DateTime(2026, 1, 2)));
    conversation.lines.add(_said('bob', 'late 1', DateTime(2026, 1, 2)));
    await _rebuild(tester, conversation);

    expect(tester.getTopLeft(_rule), before, reason: 'not yanked');
    expect(find.text('62'), findsOneWidget);
    expect(find.text('late 1'), findsNothing);
  });

  testWidgets('the button appears on scrolling up and takes you back down', (
    tester,
  ) async {
    final conversation = _conversation(read: 100, unread: 0);
    await _pump(tester, conversation);
    expect(_button, findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(_button, findsOneWidget);
    expect(find.text('0'), findsNothing, reason: 'nothing has arrived yet');

    for (var i = 0; i < 3; i++) {
      conversation.lines.add(_said('bob', 'late $i', DateTime(2026, 1, 2)));
    }
    await _rebuild(tester, conversation);
    expect(find.text('3'), findsOneWidget);

    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(_button, findsNothing);
    expect(_visible(tester, 'late 2'), isTrue);
  });

  testWidgets('saying something takes you to the bottom, rule or not', (
    tester,
  ) async {
    final conversation = _conversation(read: 60, unread: 60);
    await _pump(tester, conversation);
    expect(_button, findsOneWidget, reason: 'opened at the rule');

    conversation.lines.add(
      ChatLine.message(
        rust.ChatMessage(
          target: const rust.Target.channel(name: '#test'),
          sender: 'me',
          spans: [rust.TextSpan(text: 'hello?', style: _plain)],
          isSelf: true,
          isMention: false,
          isAction: false,
          isNotice: false,
        ),
        DateTime(2026, 1, 2),
      ),
    );
    await _rebuild(tester, conversation);

    expect(_visible(tester, 'hello?'), isTrue);
    expect(_button, findsNothing);
  });

  testWidgets('the rule stays for the visit even after the model forgets', (
    tester,
  ) async {
    final conversation = _conversation(read: 60, unread: 60);
    await _pump(tester, conversation);
    // What `SessionModel.select` does to the conversation being left, while
    // its view is still on screen.
    conversation.unreadMarker = null;
    await _rebuild(tester, conversation);
    expect(_rule, findsOneWidget);
  });
}
