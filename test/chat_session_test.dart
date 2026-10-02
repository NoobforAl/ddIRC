// Tests for the chat features where the session model and the screen meet:
// what a restart puts back as unread, paging with and without history, marking
// read from the list, and a draft surviving a trip to another conversation.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/chat_state.dart';
import 'package:ddirc/src/model/history.dart';
import 'package:ddirc/src/model/marks.dart';
import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/session_screen.dart';

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
  String text,
  DateTime at, {
  bool mention = false,
  bool self = false,
}) => ChatLine.message(
  rust.ChatMessage(
    target: const rust.Target.channel(name: '#chat'),
    sender: sender,
    spans: [rust.TextSpan(text: text, style: _plain)],
    isSelf: self,
    isMention: mention,
    isAction: false,
    isNotice: false,
  ),
  at,
);

Future<SessionModel> _session() async {
  SharedPreferences.setMockInitialValues({});
  return SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: const rust.ServerConfig(
      host: 'example.test',
      port: 6697,
      nickname: 'me',
      altNicks: [],
      channels: [],
    ),
    settings: await AppSettings.load(),
  );
}

/// Connected, so the status dot stops pulsing and the screen can settle.
void _connected(SessionModel s) => s.receiveForTesting(
  const rust.IrcEvent.status(status: rust.ConnectionStatus.connected()),
);

void _joined(SessionModel s, String channel) => s.receiveForTesting(
  rust.IrcEvent.joined(channel: channel, nick: 'me', isSelf: true),
);

Conversation _named(SessionModel s, String name) =>
    s.conversations.firstWhere((c) => c.name == name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MessageHistory.instance.resetForTest();
    ConversationStates.instance.resetForTest();
    Marks.instance.resetForTest();
  });

  group('after a restart', () {
    test('what came after the last line read is unread again', () async {
      final s = await _session();
      _joined(s, '#here');
      _joined(s, '#chat');
      s.select('#here');
      final chat = _named(s, '#chat');

      // Last time, #chat was read up to nine o'clock.
      ConversationStates.instance.markRead(
        'p1',
        '#chat',
        _said('a', 'x', DateTime(2026, 1, 1, 9)),
      );
      final older = [
        _said('a', 'seen', DateTime(2026, 1, 1, 8)),
        _said('a', 'seen too', DateTime(2026, 1, 1, 9)),
        _said('b', 'new', DateTime(2026, 1, 1, 10)),
        _said('b', 'me: you there?', DateTime(2026, 1, 1, 11), mention: true),
        _said('me', 'mine', DateTime(2026, 1, 1, 12), self: true),
      ];
      s.restoreForTesting(chat, older);

      expect(chat.unread, 2, reason: 'your own line is not news to you');
      expect(chat.unreadMentions, 1);
      expect(chat.unreadMarker, same(older[2]));
    });

    test('a conversation never opened reports none of its history', () async {
      final s = await _session();
      _joined(s, '#here');
      _joined(s, '#chat');
      s.select('#here');
      final chat = _named(s, '#chat');
      s.restoreForTesting(chat, [_said('a', 'old', DateTime(2026, 1, 1, 9))]);
      expect(chat.unread, 0);
      expect(chat.unreadMarker, isNull);
    });

    test('a muted conversation keeps its place but asks for nothing', () async {
      final s = await _session();
      _joined(s, '#here');
      _joined(s, '#chat');
      s.select('#here');
      s.settings.setNotifyFor('p1', '#chat', NotifyLevel.none);
      ConversationStates.instance.markRead(
        'p1',
        '#chat',
        _said('a', 'x', DateTime(2026, 1, 1, 9)),
      );
      final chat = _named(s, '#chat');
      final news = _said('b', 'news', DateTime(2026, 1, 1, 10));
      s.restoreForTesting(chat, [news]);
      expect(chat.unread, 0);
      expect(chat.unreadMarker, same(news));
    });
  });

  test('the conversation you land in still shows what you missed', () async {
    // Connecting opens the first channel before the disk has answered. That
    // used to record "read up to now" first, so the restore that followed
    // found nothing unread — in exactly the conversation on screen.
    final s = await _session();
    ConversationStates.instance.markRead(
      'p1',
      '#chat',
      _said('a', 'x', DateTime(2026, 1, 1, 9)),
    );
    _joined(s, '#here');
    _joined(s, '#chat');
    final chat = _named(s, '#chat');
    // What creating it does when history is on: the restore is on its way.
    s.pendRestoreForTesting(chat);
    s.select('#chat');
    expect(
      ConversationStates.instance.of('p1', '#chat')?.readAtMs,
      DateTime(2026, 1, 1, 9).millisecondsSinceEpoch,
      reason: 'not overwritten while the restore is on its way',
    );

    final missed = _said('b', 'while you were away', DateTime(2026, 1, 1, 10));
    final epoch = chat.markerEpoch;
    s.restoreForTesting(chat, [
      _said('a', 'seen', DateTime(2026, 1, 1, 8)),
      missed,
    ]);

    expect(chat.unreadMarker, same(missed), reason: 'the rule is drawn');
    expect(
      chat.markerEpoch,
      greaterThan(epoch),
      reason: 'and the view rebuilt',
    );
    expect(chat.unread, 0, reason: 'it is on screen, so it is being read');
    expect(
      ConversationStates.instance.of('p1', '#chat')!.readAtMs,
      greaterThanOrEqualTo(missed.at.millisecondsSinceEpoch),
      reason: 'and once counted, reading is recorded again',
    );
  });

  test('reading a conversation records where reading stopped', () async {
    final s = await _session();
    _joined(s, '#chat');
    s.select('#chat');
    final last = _named(s, '#chat').lines.last;
    expect(
      ConversationStates.instance.of('p1', '#chat')?.readAtMs,
      last.at.millisecondsSinceEpoch,
    );
  });

  test('marking read from the list clears the count without opening', () async {
    final s = await _session();
    _joined(s, '#here');
    _joined(s, '#chat');
    s.select('#here');
    s.receiveForTesting(
      rust.IrcEvent.message(
        message: rust.ChatMessage(
          target: const rust.Target.channel(name: '#chat'),
          sender: 'bob',
          spans: const [rust.TextSpan(text: 'hi', style: _plain)],
          isSelf: false,
          isMention: false,
          isAction: false,
          isNotice: false,
        ),
      ),
    );
    expect(_named(s, '#chat').unread, 1);
    s.markRead('#chat');
    expect(_named(s, '#chat').unread, 0);
    expect(s.active?.name, '#here', reason: 'nothing was opened');
  });

  test('with history off there is nothing above the top to load', () async {
    final s = await _session();
    _joined(s, '#chat');
    expect(await s.loadOlder(_named(s, '#chat')), 0);
  });

  testWidgets('a draft waits in its own conversation', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final s = await _session();
    _joined(s, '#one');
    _joined(s, '#two');
    s.select('#one');
    _connected(s);
    final profiles = await ProfileStore.load();

    await tester.pumpWidget(
      SettingsScope(
        settings: s.settings,
        child: ProfileScope(
          store: profiles,
          child: MaterialApp(
            theme: Tokens.themeFor(Tokens.dark),
            home: SessionScreen(session: s),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final composer = find.byType(TextField).last;
    await tester.enterText(composer, 'half a thought');
    // Kept as it is typed, before any switch: the process can end at any time.
    expect(ConversationStates.instance.draftOf('p1', '#one'), 'half a thought');
    s.select('#two');
    await tester.pumpAndSettle();
    expect(
      find.text('half a thought'),
      findsNothing,
      reason: 'not in the other conversation',
    );
    expect(
      find.textContaining('Draft: half a thought', findRichText: true),
      findsOneWidget,
      reason: 'and the list says where it is',
    );

    s.select('#one');
    await tester.pumpAndSettle();
    expect(find.text('half a thought'), findsOneWidget);

    // Draft and read-position writes wait a moment before going to a store
    // that is not there; let them come due.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Ctrl+F opens a search that finds and counts', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final s = await _session();
    _joined(s, '#one');
    s.select('#one');
    for (final text in ['deploy now', 'lunch', 'deploy done']) {
      s.receiveForTesting(
        rust.IrcEvent.message(
          message: rust.ChatMessage(
            target: const rust.Target.channel(name: '#one'),
            sender: 'bob',
            spans: [rust.TextSpan(text: text, style: _plain)],
            isSelf: false,
            isMention: false,
            isAction: false,
            isNotice: false,
          ),
        ),
      );
    }
    _connected(s);
    final profiles = await ProfileStore.load();
    await tester.pumpWidget(
      SettingsScope(
        settings: s.settings,
        child: ProfileScope(
          store: profiles,
          child: MaterialApp(
            theme: Tokens.themeFor(Tokens.dark),
            home: SessionScreen(session: s),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField).last);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Search this conversation'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'deploy');
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Older match'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.text('Search this conversation'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });
}
