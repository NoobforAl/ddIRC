// Tests for selecting and copying out of the scrollback.
//
// Two things have to hold at once, and they pull in opposite directions.
//
// Message text has to be selectable *across* messages — quoting a conversation
// means taking the three lines it took to have it, and a selection that stopped
// at one message would be no use. But Flutter's own aggregation writes every
// selected paragraph into one buffer with nothing in between, so the naive
// version of that hands back a single run-on string.
//
// And the metadata must stay out of it. The nick and the clock time are the
// app's annotation on what somebody said, not part of it, and a quote that
// drags them along is a quote that has to be tidied up by hand every time.
//
// Both are checked here through the clipboard rather than through the widget
// tree, because the clipboard is the thing the user actually ends up with.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

rust.ChatMessage _said(String sender, String text, {bool isSelf = false}) =>
    rust.ChatMessage(
      target: const rust.Target.channel(name: '#test'),
      sender: sender,
      spans: [rust.TextSpan(text: text, style: _plain)],
      isSelf: isSelf,
      isMention: false,
      isAction: false,
      isNotice: false,
    );

/// A conversation holding [said] in the order given, one minute apart so the
/// grouping rule never suppresses a sender label — the labels are precisely
/// what must not end up on the clipboard.
Conversation _conversation(List<rust.ChatMessage> said) {
  final conversation = Conversation(name: '#test', isChannel: true);
  var at = DateTime(2026, 1, 1, 9);
  for (final message in said) {
    conversation.lines.add(ChatLine.message(message, at));
    at = at.add(const Duration(minutes: 5));
  }
  return conversation;
}

Future<void> _pump(WidgetTester tester, Conversation conversation) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load();
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
}

/// Select the whole scrollback and copy it, returning what landed on the
/// clipboard. Driven through [SelectableRegionState] rather than a synthesised
/// drag so the assertion is about what is copied, not about gesture arithmetic.
Future<String?> _selectAllAndCopy(WidgetTester tester) async {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );

  final region = tester.state<SelectableRegionState>(
    find.byType(SelectableRegion),
  );
  region.selectAll();
  await tester.pump();
  // Through the region's own Copy button rather than a synthesised Ctrl+C or
  // the deprecated `copySelection`, so this exercises the same path the
  // context menu takes.
  region.contextMenuButtonItems
      .firstWhere((item) => item.type == ContextMenuButtonType.copy)
      .onPressed!();
  await tester.pump();
  return copied;
}

void main() {
  testWidgets('copies across messages, one line each', (tester) async {
    await _pump(
      tester,
      _conversation([
        _said('alice', 'the build is green'),
        _said('bob', 'finally'),
        _said('me', 'shipping it', isSelf: true),
      ]),
    );

    expect(
      await _selectAllAndCopy(tester),
      'the build is green\nfinally\nshipping it',
      reason: 'three messages, three lines — not one run-on string',
    );
  });

  testWidgets('leaves the nick and the clock time behind', (tester) async {
    await _pump(tester, _conversation([_said('alice', 'the build is green')]));

    final copied = await _selectAllAndCopy(tester);
    expect(copied, 'the build is green');
    // Named individually, because either one leaking is the same bug and the
    // equality above would not say which.
    expect(copied, isNot(contains('alice')));
    expect(copied, isNot(contains('09:00')));
  });

  testWidgets('a single message copies without a trailing newline', (
    tester,
  ) async {
    await _pump(tester, _conversation([_said('alice', 'just the one')]));

    // The separator is put *between* messages rather than after each of them:
    // copying inside one message must not come back with a line break the user
    // never selected.
    expect(await _selectAllAndCopy(tester), 'just the one');
  });

  testWidgets('system lines are copyable too', (tester) async {
    final conversation = Conversation(name: '#test', isChannel: true);
    conversation.lines
      ..add(ChatLine.message(_said('alice', 'hello'), DateTime(2026, 1, 1, 9)))
      ..add(
        ChatLine.system(
          'bob left',
          DateTime(2026, 1, 1, 9, 5),
          SystemKind.presence,
        ),
      );

    await _pump(tester, conversation);

    // They report something that happened, so a copied excerpt that silently
    // dropped them would be a misleading record of the conversation.
    expect(await _selectAllAndCopy(tester), 'hello\nbob left');
  });
}
