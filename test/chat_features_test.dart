// Tests for the client-side chat features: drafts, read positions, pinned and
// archived conversations, timed mutes, nicks hidden in channels, WHOIS, the
// @-mention jump, and what the message and list menus offer with message
// history on and off.
//
// None of this loads the native library. What is kept on disk is the store's
// business and is tested in Rust; what is tested here is what the app does
// with it in memory — and that the features which need a database to keep
// their promise say so, rather than quietly working until the next launch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/chat_state.dart';
import 'package:ddirc/src/model/history.dart';
import 'package:ddirc/src/model/marks.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/store.dart' as store;
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/channel_list.dart';
import 'package:ddirc/src/ui/message_view.dart';

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

rust.ChatMessage _message(
  String sender,
  String text, {
  String channel = '#test',
  bool mention = false,
}) => rust.ChatMessage(
  target: rust.Target.channel(name: channel),
  sender: sender,
  spans: [rust.TextSpan(text: text, style: _plain)],
  isSelf: false,
  isMention: mention,
  isAction: false,
  isNotice: false,
);

ChatLine _said(
  String sender,
  String text, {
  DateTime? at,
  bool mention = false,
}) => ChatLine.message(
  _message(sender, text, mention: mention),
  at ?? DateTime(2026, 1, 1, 9),
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

void _joined(SessionModel s, String channel) => s.receiveForTesting(
  rust.IrcEvent.joined(channel: channel, nick: 'me', isSelf: true),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MessageHistory.instance.resetForTest();
    ConversationStates.instance.resetForTest();
    Marks.instance.resetForTest();
  });

  group('drafts', () {
    test('are kept per conversation, and an empty one is no draft', () {
      final states = ConversationStates.instance;
      states.setDraft('p1', '#One', 'half a thought');
      expect(states.draftOf('p1', '#one'), 'half a thought');
      expect(states.draftOf('p1', '#two'), isNull);
      expect(states.draftOf('p2', '#one'), isNull, reason: 'per network');

      states.setDraft('p1', '#one', '   ');
      expect(states.draftOf('p1', '#one'), isNull);
    });
  });

  group('read positions', () {
    test('only what came after the recorded position is unread', () {
      final states = ConversationStates.instance;
      final early = _said('a', 'x', at: DateTime(2026, 1, 1, 9));
      final late = _said('a', 'y', at: DateTime(2026, 1, 1, 10));
      // Nothing recorded: nothing is "after" it, so history is not news.
      expect(states.isAfterRead('p1', '#c', late), isFalse);

      states.markRead('p1', '#c', early);
      expect(states.isAfterRead('p1', '#c', early), isFalse);
      expect(states.isAfterRead('p1', '#c', late), isTrue);

      // Reading never goes backwards.
      states.markRead('p1', '#c', late);
      states.markRead('p1', '#c', early);
      expect(states.isAfterRead('p1', '#c', late), isFalse);
    });

    test('the same millisecond is told apart by the store id', () {
      final states = ConversationStates.instance;
      final at = DateTime(2026, 1, 1, 9);
      final first = _said('a', 'x', at: at)..dbId = 1;
      final second = _said('a', 'y', at: at)..dbId = 2;
      states.markRead('p1', '#c', first);
      expect(states.isAfterRead('p1', '#c', second), isTrue);
    });
  });

  group('pinned and archived conversations', () {
    test('need message history, and do nothing without it', () {
      final states = ConversationStates.instance;
      states.setPinned('p1', '#a', true);
      states.setArchived('p1', '#b', true);
      expect(states.isPinned('p1', '#a'), isFalse);
      expect(states.isArchived('p1', '#b'), isFalse);
    });

    test('pinned go first in pin order, archived go apart', () {
      MessageHistory.instance.enableForTest(true);
      final states = ConversationStates.instance;
      final list = [
        for (final name in ['#a', '#b', '#c', '#d', '#e'])
          Conversation(name: name, isChannel: true),
      ];
      states.setPinned('p1', '#d', true);
      states.setPinned('p1', '#b', true);
      states.setArchived('p1', '#c', true);

      final arranged = states.arrange('p1', list);
      expect(arranged.shown.map((c) => c.name), ['#d', '#b', '#a', '#e']);
      expect(arranged.archived.map((c) => c.name), ['#c']);

      // Pinning takes a conversation out of the archive.
      states.setPinned('p1', '#c', true);
      expect(states.isArchived('p1', '#c'), isFalse);
    });

    test('a mention brings an archived conversation back', () async {
      MessageHistory.instance.enableForTest(true);
      final s = await _session();
      _joined(s, '#busy');
      _joined(s, '#other');
      s.select('#other');
      ConversationStates.instance.setArchived('p1', '#busy', true);

      s.receiveForTesting(
        rust.IrcEvent.message(
          message: _message('bob', 'chatter', channel: '#busy'),
        ),
      );
      expect(ConversationStates.instance.isArchived('p1', '#busy'), isTrue);

      s.receiveForTesting(
        rust.IrcEvent.message(
          message: _message('bob', 'me: look', channel: '#busy', mention: true),
        ),
      );
      expect(ConversationStates.instance.isArchived('p1', '#busy'), isFalse);
    });
  });

  group('muting', () {
    test(
      'for a while is muted until then, and a level choice ends it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = await AppSettings.load();
        settings.muteFor('p1', '#chat', const Duration(hours: 1));
        expect(settings.notifyFor('p1', '#chat'), NotifyLevel.none);
        expect(settings.mutedUntil('p1', '#chat'), isNotNull);
        expect(settings.notifyFor('p1', '#elsewhere'), NotifyLevel.all);

        settings.setNotifyFor('p1', '#chat', NotifyLevel.all);
        expect(settings.notifyFor('p1', '#chat'), NotifyLevel.all);
        expect(settings.mutedUntil('p1', '#chat'), isNull);
        settings.dispose();
      },
    );

    test('one that has run out is no mute at all', () async {
      SharedPreferences.setMockInitialValues({
        'muteUntil.p1/#chat': DateTime(2020).millisecondsSinceEpoch,
      });
      final settings = await AppSettings.load();
      expect(settings.notifyFor('p1', '#chat'), NotifyLevel.all);
      settings.dispose();
    });

    test('with no end is the Muted level itself', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      settings.muteFor('p1', '#chat', null);
      expect(settings.notifyFor('p1', '#chat'), NotifyLevel.none);
      expect(settings.mutedUntil('p1', '#chat'), isNull);
      settings.dispose();
    });

    test('a nick hidden in channels says nothing there, and still can '
        'message you', () async {
      final s = await _session();
      _joined(s, '#chat');
      s.settings.setNickMuted('p1', 'Troll', true);

      s.receiveForTesting(
        rust.IrcEvent.message(
          message: _message('troll', 'noise', channel: '#chat'),
        ),
      );
      final chat = s.conversations.firstWhere((c) => c.name == '#chat');
      expect(chat.lines.where((l) => !l.isSystem), isEmpty);

      s.settings.accept('p1', 'troll');
      s.receiveForTesting(
        rust.IrcEvent.message(
          message: rust.ChatMessage(
            target: const rust.Target.direct(nick: 'troll'),
            sender: 'troll',
            spans: [const rust.TextSpan(text: 'psst', style: _plain)],
            isSelf: false,
            isMention: false,
            isAction: false,
            isNotice: false,
          ),
        ),
      );
      expect(s.conversations.any((c) => c.name == 'troll'), isTrue);
    });
  });

  test('a WHOIS answer reaches whoever asked', () async {
    final s = await _session();
    final asked = s.whoisForTesting('Alice');
    s.receiveForTesting(
      const rust.IrcEvent.whois(
        rust.WhoisInfo(
          nick: 'alice',
          found: true,
          host: 'example.org',
          channels: ['#chat'],
          operator_: false,
          secure: true,
        ),
      ),
    );
    final answer = await asked;
    expect(answer?.host, 'example.org');
    expect(answer?.secure, isTrue);
  });

  group('the scrollback', () {
    Future<void> pump(
      WidgetTester tester,
      Conversation conversation, {
      String? profileId,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: SettingsScope(
            settings: settings,
            child: Scaffold(
              body: MessageView(
                conversation: conversation,
                profileId: profileId,
                onReply: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers a way to unread mentions', (tester) async {
      final conversation = Conversation(name: '#test', isChannel: true);
      final read = [
        for (var i = 0; i < 30; i++)
          _said('a', 'read $i', at: DateTime(2026, 1, 1, 8, i)),
      ];
      final unread = [
        for (var i = 0; i < 30; i++)
          _said(
            'b',
            i == 3 ? 'me: over here' : 'unread $i',
            at: DateTime(2026, 1, 1, 9, i),
            mention: i == 3,
          ),
      ];
      conversation.lines
        ..addAll(read)
        ..addAll(unread);
      conversation.unreadMarker = unread.first;
      await pump(tester, conversation);

      expect(find.byTooltip('Jump to mention'), findsOneWidget);
      await tester.tap(find.byTooltip('Jump to mention'));
      await tester.pumpAndSettle();
      // The line it lands on blinks for a moment; let that finish.
      await tester.pump(const Duration(seconds: 2));
      expect(find.byTooltip('Jump to mention'), findsNothing);
      expect(find.text('me: over here'), findsOneWidget);
    });

    testWidgets('pin and save say they need message history', (tester) async {
      final conversation = Conversation(name: '#test', isChannel: true)
        ..lines.add(_said('alice', 'hold me'));
      await pump(tester, conversation, profileId: 'p1');

      await tester.longPress(find.text('hold me'));
      await tester.pumpAndSettle();
      expect(find.text('Pin'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Turn on message history in Privacy'), findsOneWidget);

      // Disabled: tapping does nothing, and the menu stays.
      await tester.tap(find.text('Pin'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Pinned'), findsNothing);
    });

    testWidgets('a pinned message offers to be unpinned', (tester) async {
      MessageHistory.instance.enableForTest(true);
      final line = _said('alice', 'the rules');
      Marks.instance.resetForTest([
        store.Mark(
          id: 1,
          kind: MarkKind.pinned.code,
          profileId: 'p1',
          conversation: '#test',
          atMs: line.at.millisecondsSinceEpoch,
          sender: 'alice',
          spans: line.message!.spans,
          createdMs: 0,
        ),
      ]);
      final conversation = Conversation(name: '#test', isChannel: true)
        ..lines.add(line);
      await pump(tester, conversation, profileId: 'p1');

      await tester.longPress(find.text('the rules'));
      await tester.pumpAndSettle();
      expect(find.text('Unpin'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Turn on message history in Privacy'), findsNothing);
    });

    testWidgets('links and markdown are drawn, the text kept', (tester) async {
      final conversation = Conversation(name: '#test', isChannel: true)
        ..lines.add(_said('alice', 'see **this** at https://example.org'));
      await pump(tester, conversation);
      expect(
        find.textContaining(
          'see this at https://example.org',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });
  });

  group('the conversation list', () {
    Future<SessionModel> pumpList(WidgetTester tester) async {
      final s = await _session();
      for (final channel in ['#a', '#b', '#c']) {
        _joined(s, channel);
      }
      s.select('#a');
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: SettingsScope(
            settings: s.settings,
            child: Scaffold(
              body: ChannelList(
                session: s,
                networkName: 'Test',
                onSelect: s.select,
                onBrowse: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return s;
    }

    testWidgets('shows a draft under the conversation it belongs to', (
      tester,
    ) async {
      await pumpList(tester);
      ConversationStates.instance.setDraft('p1', '#b', 'later');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Draft: later', findRichText: true),
        findsOneWidget,
      );

      // Not under the one on screen: its draft is in the composer.
      ConversationStates.instance.setDraft('p1', '#a', 'here');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Draft: here', findRichText: true),
        findsNothing,
      );
    });

    testWidgets('puts pinned first and folds the archived away', (
      tester,
    ) async {
      MessageHistory.instance.enableForTest(true);
      await pumpList(tester);
      ConversationStates.instance.setPinned('p1', '#c', true);
      ConversationStates.instance.setArchived('p1', '#b', true);
      await tester.pumpAndSettle();

      final c = tester.getTopLeft(find.text('#c')).dy;
      final a = tester.getTopLeft(find.text('#a')).dy;
      expect(c, lessThan(a), reason: 'pinned first');
      expect(find.text('#b'), findsNothing, reason: 'archived is folded');
      expect(find.text('Archived (1)'), findsOneWidget);

      await tester.tap(find.text('Archived (1)'));
      await tester.pumpAndSettle();
      expect(find.text('#b'), findsOneWidget);
      // History "on" queues every line, and every read position, for a write
      // that has nowhere to go in a test; let those come due and stop.
      await tester.pump(const Duration(seconds: 1));
      MessageHistory.instance.resetForTest();
    });

    testWidgets('its menu says pinning needs message history', (tester) async {
      await pumpList(tester);
      await tester.longPress(find.text('#b'));
      await tester.pumpAndSettle();
      expect(find.text('Pin to top'), findsOneWidget);
      expect(
        find.text('Turn on message history in Privacy to pin and archive'),
        findsOneWidget,
      );
      expect(find.text('Mute…'), findsOneWidget);
    });
  });
}
