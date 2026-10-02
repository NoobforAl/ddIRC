// The "new messages" rule placed after the scrollback is already on screen.
//
// That is what happens in the conversation you land in on connecting: it is
// opened the moment it is joined, and saved history — with where reading
// stopped last time — arrives a moment later. The session then rebuilds the
// view under a new key so it picks the rule up. A short unread tail must
// still open at the bottom, with the rule a few rows up, not pinned to the
// top of the screen with empty space beneath it.

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

/// The session screen's arrangement: the view inside an AnimatedSwitcher,
/// keyed on the conversation, with a bar below it that can grow — the
/// composer's notice — while the view settles.
Widget _screen(
  Conversation conversation,
  AppSettings settings, {
  bool bar = false,
}) => MaterialApp(
  theme: Tokens.themeFor(Tokens.dark),
  home: SettingsScope(
    settings: settings,
    child: Scaffold(
      body: Column(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: MessageView(
                key: ValueKey(conversation.name),
                conversation: conversation,
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            child: SizedBox(height: bar ? 100 : 0),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  for (final bar in [false, true]) {
    testWidgets('a rule placed late still opens at the bottom'
        '${bar ? ', while a bar arrives' : ''}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      final conversation = Conversation(name: '#test', isChannel: true);
      var at = DateTime(2026, 1, 1, 9);
      for (var i = 0; i < 60; i++) {
        conversation.lines.add(_said('alice', 'read $i', at));
        at = at.add(const Duration(minutes: 5));
      }
      await tester.pumpWidget(_screen(conversation, settings));
      await tester.pumpAndSettle();

      // History arrives: three lines nobody has read, and the session puts
      // the rule on the first and rebuilds the view.
      final unread = [
        for (var i = 0; i < 3; i++)
          _said('bob', 'unread $i', at.add(Duration(minutes: i + 1))),
      ];
      conversation.lines.addAll(unread);
      conversation.unreadMarker = unread.first;
      conversation.markerEpoch++;
      await tester.pumpWidget(_screen(conversation, settings, bar: bar));
      await tester.pumpAndSettle();

      final view = tester.getRect(find.byType(CustomScrollView).last);
      final last = tester.getRect(find.text('unread 2').last);
      final rule = tester.getRect(find.text('New messages').last);
      expect(
        view.bottom - last.bottom,
        lessThan(60),
        reason: 'the last line sits at the bottom, not floating mid-screen',
      );
      expect(
        rule.top,
        greaterThan(view.top + 100),
        reason: 'the rule is a few rows up',
      );
      expect(find.byTooltip('Jump to latest'), findsNothing);
    });
  }
}
