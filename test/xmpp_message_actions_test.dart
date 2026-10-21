// Tests for changing a message you sent, as the scrollback offers it: Edit and
// Delete in a message's menu where the account can do that, and a mark on a
// message that was changed after it was first shown.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
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

ChatLine _said(
  String sender,
  String text, {
  bool isSelf = false,
  String? msgid,
  bool edited = false,
  bool notice = false,
}) {
  final line = ChatLine.message(
    rust.ChatMessage(
      target: const rust.Target.channel(name: '#test'),
      sender: sender,
      spans: [rust.TextSpan(text: text, style: _plain)],
      isSelf: isSelf,
      isMention: false,
      isAction: false,
      isNotice: notice,
      msgid: msgid,
    ),
    DateTime(2026, 1, 1, 9),
  );
  line.edited = edited;
  return line;
}

Future<void> _pump(
  WidgetTester tester,
  List<ChatLine> lines, {
  ValueChanged<ChatLine>? onEdit,
  ValueChanged<ChatLine>? onDelete,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load();
  final conversation = Conversation(name: '#test', isChannel: true);
  conversation.lines.addAll(lines);
  await tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: SettingsScope(
        settings: settings,
        child: Scaffold(
          body: MessageView(
            conversation: conversation,
            onEdit: onEdit,
            onDelete: onDelete,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _rightClick(WidgetTester tester, String text) async {
  final mouse = await tester.startGesture(
    tester.getCenter(find.text(text)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await mouse.up();
  await tester.pumpAndSettle();
}

/// A widget test on a desktop platform, where a right click opens the menu.
/// The override is put back before the test ends: the framework checks that no
/// debug variable was left changed before it runs any teardown.
void desktopTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  desktopTest('our own message offers Edit and Delete, and they are called', (
    tester,
  ) async {
    final edited = <ChatLine>[];
    final deleted = <ChatLine>[];
    final mine = _said('alice', 'teh plan', isSelf: true, msgid: 'm1');
    await _pump(tester, [mine], onEdit: edited.add, onDelete: deleted.add);

    await _rightClick(tester, 'teh plan');
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(edited, [mine]);

    await _rightClick(tester, 'teh plan');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, [mine]);
  });

  desktopTest('someone else\'s message offers neither', (tester) async {
    await _pump(
      tester,
      [_said('bob', 'not mine', msgid: 'm2')],
      onEdit: (_) {},
      onDelete: (_) {},
    );
    await _rightClick(tester, 'not mine');
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  desktopTest('a message with no id to name it by offers neither', (
    tester,
  ) async {
    await _pump(
      tester,
      [_said('alice', 'no id', isSelf: true)],
      onEdit: (_) {},
      onDelete: (_) {},
    );
    await _rightClick(tester, 'no id');
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  desktopTest(
    'where changing is not offered, as on IRC, the menu is unchanged',
    (tester) async {
      await _pump(tester, [
        _said('alice', 'on irc', isSelf: true, msgid: 'm1'),
      ]);
      await _rightClick(tester, 'on irc');
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    },
  );

  desktopTest('a message that was changed says so', (tester) async {
    await _pump(tester, [
      _said('bob', 'the plan', msgid: 'm3', edited: true),
      _said('carol', 'untouched', msgid: 'm4'),
    ]);
    expect(find.textContaining('edited'), findsOneWidget);
  });

  desktopTest('and says so even with timestamps off', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.showTimestamps = false;
    final conversation = Conversation(name: '#test', isChannel: true);
    conversation.lines.add(_said('bob', 'the plan', msgid: 'm3', edited: true));
    await tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: SettingsScope(
          settings: settings,
          child: Scaffold(body: MessageView(conversation: conversation)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('edited'), findsOneWidget);
  });
}
