// What the scrollback must do when something it shows changes underneath it: a
// correction replaces a message in place, a setting changes how every message
// is drawn, and a new line from the same person joins the bubble above it.
//
// These hold the scrollback to doing them. A message that is edited in place
// keeps its line, so anything that decides "nothing changed" by looking at the
// line rather than at what it says would show the old words forever.

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

rust.ChatMessage _message(String sender, String text, {String? msgid}) =>
    rust.ChatMessage(
      target: const rust.Target.channel(name: '#test'),
      sender: sender,
      spans: [rust.TextSpan(text: text, style: _plain)],
      isSelf: false,
      isMention: false,
      isAction: false,
      isNotice: false,
      msgid: msgid,
    );

/// Every line is from someone different, so each is a bubble of its own.
ChatLine _line(int i, [String? text]) => ChatLine.message(
  _message('user$i', text ?? 'message number $i', msgid: 'm$i'),
  DateTime(2026, 1, 1, 9, i % 50),
);

class _Rig {
  _Rig(this.tester, this.settings, this.conversation);

  final WidgetTester tester;
  final AppSettings settings;
  final Conversation conversation;
  final tick = ValueNotifier<int>(0);

  static Future<_Rig> start(WidgetTester tester, List<ChatLine> lines) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    final conversation = Conversation(name: '#test', isChannel: true)
      ..lines.addAll(lines);
    final rig = _Rig(tester, settings, conversation);
    await tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: SettingsScope(
          settings: settings,
          child: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: rig.tick,
              builder: (context, _, _) =>
                  MessageView(conversation: conversation, onReply: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return rig;
  }

  /// Let the view know the conversation changed, as the session does.
  Future<void> changed() async {
    tick.value++;
    await tester.pump();
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('a correction shows the new words and says it was changed', (
    tester,
  ) async {
    final rig = await _Rig.start(tester, [
      for (var i = 0; i < 4; i++) _line(i),
    ]);
    expect(find.text('message number 2'), findsOneWidget);

    final line = rig.conversation.lines[2];
    line.message = _message('user2', 'the corrected words', msgid: 'm2');
    line.edited = true;
    await rig.changed();

    expect(find.text('message number 2'), findsNothing);
    expect(find.text('the corrected words'), findsOneWidget);
    expect(find.textContaining('edited'), findsOneWidget);
    // The others were left alone.
    expect(find.text('message number 1'), findsOneWidget);
    expect(find.text('message number 3'), findsOneWidget);
  });

  testWidgets('a setting that changes how messages are drawn reaches them', (
    tester,
  ) async {
    final rig = await _Rig.start(tester, [
      _line(0, 'some **bold** words'),
      _line(1, 'another line'),
    ]);
    rig.settings.markdown = true;
    await tester.pumpAndSettle();
    expect(find.textContaining('**bold**', findRichText: true), findsNothing);

    rig.settings.markdown = false;
    await tester.pumpAndSettle();
    expect(find.textContaining('**bold**', findRichText: true), findsOneWidget);

    rig.settings.markdown = true;
    await tester.pumpAndSettle();
    expect(find.textContaining('**bold**', findRichText: true), findsNothing);
  });

  testWidgets('a line that joins a bubble is drawn in it', (tester) async {
    // The same person, the same minute: one bubble that grows.
    ChatLine same(String text) =>
        ChatLine.message(_message('carol', text), DateTime(2026, 1, 1, 9, 30));
    final rig = await _Rig.start(tester, [same('first thing')]);
    expect(find.text('first thing'), findsOneWidget);

    rig.conversation.lines.add(same('second thing'));
    await rig.changed();

    expect(find.text('first thing'), findsOneWidget);
    expect(find.text('second thing'), findsOneWidget);
  });

  testWidgets('a full scrollback keeps showing the newest lines', (
    tester,
  ) async {
    // One off the top for each one on the end, as at the cap.
    final rig = await _Rig.start(tester, [
      for (var i = 0; i < 30; i++) _line(i),
    ]);
    for (var i = 30; i < 70; i++) {
      rig.conversation.lines
        ..removeAt(0)
        ..add(_line(i));
      await rig.changed();
    }
    expect(find.text('message number 69'), findsOneWidget);
    expect(find.text('message number 5'), findsNothing);
  });
}
