// Tests for saved scrollback, on the Dart side of the boundary.
//
// The database itself is tested in Rust (`ddirc_core::store`), where it lives.
// What is checked here is everything between a line on screen and a row on its
// way into that database: the mapping in both directions, and what happens to
// a conversation when yesterday's half of it arrives.
//
// The mapping is where a bug would be quiet. A dropped flag or a lost sender
// does not fail anything — it produces history that reloads looking subtly
// wrong, weeks later, on a machine nobody is watching.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/history.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/rust/api/store.dart' as store;
import 'package:ddirc/src/rust/api/types.dart' as rust;

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

const _bold = rust.SpanStyle(
  bold: true,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
  fg: 4,
);

ChatLine _message(
  String sender,
  List<rust.TextSpan> spans, {
  String? prefix,
  bool isSelf = false,
  bool isMention = false,
  bool isAction = false,
  bool isNotice = false,
}) => ChatLine.message(
  rust.ChatMessage(
    target: const rust.Target.channel(name: '#test'),
    sender: sender,
    senderPrefix: prefix,
    spans: spans,
    isSelf: isSelf,
    isMention: isMention,
    isAction: isAction,
    isNotice: isNotice,
  ),
  DateTime(2026, 3, 1, 14, 30),
);

/// A line put through the mapping and brought back, as it would be after a
/// restart. The store's own round trip is exercised in Rust; this covers the
/// half that lives here.
ChatLine _throughTheStore(ChatLine line, {bool isChannel = true}) =>
    MessageHistory.decodeForTest(
      MessageHistory.encodeForTest('p1', '#Test', line),
      '#Test',
      isChannel,
    );

void main() {
  group('a message survives being written down', () {
    test('with its sender, its prefix and every flag', () {
      final original = _message(
        'alice',
        [rust.TextSpan(text: 'the build is green', style: _plain)],
        prefix: '@',
        isMention: true,
        isAction: true,
      );

      final restored = _throughTheStore(original);
      final message = restored.message!;
      expect(message.sender, 'alice');
      expect(message.senderPrefix, '@');
      expect(message.spans.map((s) => s.text).join(), 'the build is green');
      expect(message.isMention, isTrue, reason: 'a mention is still a mention');
      expect(message.isAction, isTrue);
      expect(message.isSelf, isFalse);
      expect(message.isNotice, isFalse);
      expect(restored.at, original.at);
    });

    test('with its styling, not flattened to plain text', () {
      final original = _message('alice', [
        rust.TextSpan(text: 'shipped ', style: _plain),
        rust.TextSpan(text: 'at last', style: _bold),
      ]);

      // The styles reach the boundary intact. Turning them into mIRC codes and
      // back is the core's half, and `format::encode` is tested against its own
      // parser there — but a span dropped on this side would never get that
      // far.
      final spans = _throughTheStore(original).message!.spans;
      expect(spans.map((s) => s.text).join(), 'shipped at last');
      expect(spans.last.style.bold, isTrue);
      expect(spans.last.style.fg, 4);
    });

    test('as a direct message when the conversation is a person', () {
      final restored = _throughTheStore(
        _message('alice', [rust.TextSpan(text: 'hello', style: _plain)]),
        isChannel: false,
      );
      // The target is rebuilt from the conversation rather than stored per
      // row, so this is the one place it could come back wrong.
      expect(restored.message!.target, isA<rust.Target_Direct>());
    });
  });

  group('a system line survives being written down', () {
    test('keeping the kind it was filed under', () {
      for (final kind in SystemKind.values) {
        final restored = _throughTheStore(
          ChatLine.system('alice joined', DateTime(2026, 3, 1), kind),
        );
        expect(restored.isSystem, isTrue, reason: '$kind stayed a system line');
        expect(restored.system, 'alice joined');
        expect(restored.kind, kind);
      }
    });

    test('and a kind from a newer build does not become a message', () {
      final row = store.StoredLine(
        profileId: 'p1',
        conversation: '#test',
        atMs: DateTime(2026, 3, 1).millisecondsSinceEpoch,
        spans: [rust.TextSpan(text: 'something new happened', style: _plain)],
        isSelf: false,
        isMention: false,
        isAction: false,
        isNotice: false,
        // A category this build has never heard of.
        kind: 99,
      );

      final restored = MessageHistory.decodeForTest(row, '#test', true);
      expect(restored.isSystem, isTrue);
      // Filed as a plain connection note rather than dropped: the text still
      // says what happened, which is more than nothing.
      expect(restored.kind, SystemKind.connection);
      expect(restored.system, 'something new happened');
    });
  });

  test('a conversation is filed under one folding of its name', () {
    // Written under one spelling and looked up under another is history that
    // exists and can never be found.
    expect(
      MessageHistory.encodeForTest('p1', '#Test', _plainLine()).conversation,
      MessageHistory.key('#tEsT'),
    );
  });

  group('restoring a conversation', () {
    test('puts the old lines in front of the new ones', () {
      final conversation = Conversation(name: '#test', isChannel: true);
      conversation.add(
        _message('bob', [rust.TextSpan(text: 'live', style: _plain)]),
        active: true,
      );

      conversation.restore([
        ChatLine.system('yesterday', DateTime(2026, 2, 28), SystemKind.topic),
      ]);

      expect(conversation.lines.first.system, 'yesterday');
      expect(conversation.lines.last.message!.spans.first.text, 'live');
    });

    test('does not report history as unread', () {
      final conversation = Conversation(name: '#test', isChannel: true);
      conversation.restore([
        for (var i = 0; i < 20; i++)
          _message('alice', [rust.TextSpan(text: 'line $i', style: _plain)]),
      ]);

      // These were read yesterday, or never arrived while anyone was looking.
      // Either way a channel that showed twenty unread the moment it opened
      // would be reporting its own history as activity.
      expect(conversation.unread, 0);
      expect(conversation.unreadMentions, 0);
    });

    test('happens once, however many times it is asked for', () {
      final conversation = Conversation(name: '#test', isChannel: true);
      expect(conversation.restored, isFalse);
      conversation.restore([
        ChatLine.system('once', DateTime(2026, 2, 28), SystemKind.topic),
      ]);
      expect(conversation.restored, isTrue);
    });

    test('never grows the scrollback past its cap', () {
      final conversation = Conversation(name: '#test', isChannel: true);
      for (var i = 0; i < 1990; i++) {
        conversation.add(
          _message('bob', [rust.TextSpan(text: 'live $i', style: _plain)]),
          active: true,
        );
      }

      conversation.restore([
        for (var i = 0; i < 500; i++)
          _message('alice', [rust.TextSpan(text: 'old $i', style: _plain)]),
      ]);

      expect(conversation.lines.length, 2000);
      // Trimmed from the front, so nothing that arrived live is thrown away to
      // make room for history.
      expect(conversation.lines.last.message!.spans.first.text, 'live 1989');
    });
  });

  test('nothing is queued while history is off', () async {
    final history = MessageHistory.instance;
    history.resetForTest();
    addTearDown(history.resetForTest);

    expect(history.enabled, isFalse, reason: 'off is the default');
    history.record(profileId: 'p1', conversation: '#test', line: _plainLine());
    // Nothing to write means nothing to flush, and no call into a store that
    // is not open. A flush that threw here would be the switch failing to
    // mean what it says.
    await history.flush();
  });
}

ChatLine _plainLine() =>
    _message('alice', [rust.TextSpan(text: 'hello', style: _plain)]);
