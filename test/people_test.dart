// Tests for what the user writes down about people.
//
// Two promises are protected here. The annotation is the user's, so it shows
// wherever the person does — the roster and the scrollback — and follows the
// nick however it is capitalised. And it is kept only as far as the user
// asked: in memory always, on disk only with message history on. The disk
// half is tested in Rust; here the store is off, and nothing must try it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/history.dart';
import 'package:ddirc/src/model/people.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/store.dart' as store;
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/avatar.dart';
import 'package:ddirc/src/ui/member_list.dart';
import 'package:ddirc/src/ui/message_view.dart';
import 'package:ddirc/src/ui/nick_color.dart';
import 'package:ddirc/src/ui/person_dialog.dart';

const _plain = rust.SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

ChatLine _said(String sender, String text) => ChatLine.message(
  rust.ChatMessage(
    target: const rust.Target.channel(name: '#test'),
    sender: sender,
    spans: [rust.TextSpan(text: text, style: _plain)],
    isSelf: false,
    isMention: false,
    isAction: false,
    isNotice: false,
  ),
  DateTime(2026, 1, 1, 9),
);

rust.MemberView _member(String nick) => rust.MemberView(
  nick: nick,
  away: false,
  sortKey: 'ffff${nick.toLowerCase()}',
);

Future<AppSettings> _settings() async {
  SharedPreferences.setMockInitialValues({});
  return AppSettings.load();
}

Widget _app(AppSettings settings, Widget body) => MaterialApp(
  theme: Tokens.themeFor(Tokens.dark),
  home: SettingsScope(
    settings: settings,
    child: Scaffold(body: body),
  ),
);

Color? _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  setUp(() => People.instance.resetForTest());

  group('PersonCard', () {
    test('is blank until something is set, and copyWith can clear', () {
      const blank = PersonCard();
      expect(blank.isBlank, isTrue);
      final named = blank.copyWith(alias: 'Al');
      expect(named.isBlank, isFalse);
      expect(named.copyWith(alias: null).isBlank, isTrue);
      // The sentinel default keeps what was there.
      expect(named.copyWith(note: 'x').alias, 'Al');
    });

    test('round-trips through a store row', () {
      final card = PersonCard(
        alias: 'Al',
        note: 'ops',
        color: const Color(0xFFE57373),
        pixelSeed: 7,
      );
      final row = card.toRow('p1', 'alice');
      expect(row.color, 0xFFE57373);
      expect(PersonCard.fromRow(row), card);
    });
  });

  group('People', () {
    test('finds a person whatever the case of the nick', () {
      People.instance.set('p1', 'Alice', const PersonCard(alias: 'Al'));
      expect(People.instance.displayName('p1', 'alice'), 'Al');
      expect(People.instance.displayName('p1', 'ALICE'), 'Al');
      expect(
        People.instance.displayName('p2', 'alice'),
        'alice',
        reason: 'per network',
      );
    });

    test('a blank card forgets the person; a network can be forgotten', () {
      People.instance.set('p1', 'alice', const PersonCard(note: 'x'));
      People.instance.set('p1', 'bob', const PersonCard(note: 'y'));
      People.instance.set('p1', 'alice', const PersonCard());
      expect(People.instance.of('p1', 'alice'), isNull);
      expect(People.instance.of('p1', 'bob'), isNotNull);
      People.instance.forgetProfile('p1');
      expect(People.instance.of('p1', 'bob'), isNull);
    });

    test('with history off, nothing reaches the store', () async {
      // No native library is loaded in tests, so a call into the store
      // would throw; the guard is what keeps this a memory-only feature.
      expect(MessageHistory.instance.enabled, isFalse);
      await People.instance.set('p1', 'alice', const PersonCard(note: 'x'));
      await People.instance.sync();
      expect(People.instance.of('p1', 'alice')?.note, 'x');
    });

    test('notifies on every change', () {
      var ticks = 0;
      void tick() => ticks++;
      People.instance.addListener(tick);
      addTearDown(() => People.instance.removeListener(tick));
      People.instance.set('p1', 'alice', const PersonCard(note: 'x'));
      People.instance.forgetProfile('p1');
      expect(ticks, 2);
    });
  });

  group('pixel avatars', () {
    test('are the same picture for the same seed', () {
      expect(PixelAvatarPainter(5).shouldRepaint(PixelAvatarPainter(5)), false);
      expect(PixelAvatarPainter(5).shouldRepaint(PixelAvatarPainter(6)), true);
      expect(PixelAvatarPainter.roll(), isNonNegative);
    });
  });

  testWidgets('the roster shows the name, note, colour and picture', (
    tester,
  ) async {
    People.instance.set(
      'p1',
      'alice',
      const PersonCard(
        alias: 'Alice from ops',
        note: 'runs the mail server',
        color: Color(0xFF123456),
        pixelSeed: 3,
      ),
    );
    final settings = await _settings();
    await tester.pumpWidget(
      _app(
        settings,
        MemberList(
          members: [_member('Alice'), _member('bob')],
          profileId: 'p1',
        ),
      ),
    );

    expect(find.text('Alice from ops'), findsOneWidget);
    expect(find.text('Alice'), findsNothing, reason: 'the alias replaces it');
    expect(find.text('runs the mail server'), findsOneWidget);
    expect(find.byType(Avatar), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    // The chosen colour beats the hashed one, read off the animated style.
    final style = tester
        .widget<AnimatedDefaultTextStyle>(
          find
              .ancestor(
                of: find.text('Alice from ops'),
                matching: find.byType(AnimatedDefaultTextStyle),
              )
              .first,
        )
        .style;
    expect(style.color, const Color(0xFF123456));
    expect(find.text('bob'), findsOneWidget, reason: 'unannotated: as is');
  });

  testWidgets('the scrollback shows the name and colour, and opens the card', (
    tester,
  ) async {
    People.instance.set(
      'p1',
      'alice',
      const PersonCard(alias: 'Al', color: Color(0xFF123456)),
    );
    final conversation = Conversation(name: '#test', isChannel: true)
      ..lines.add(_said('alice', 'hi'))
      ..lines.add(_said('bob', 'hello'));
    String? tapped;
    final settings = await _settings();
    await tester.pumpWidget(
      _app(
        settings,
        MessageView(
          conversation: conversation,
          profileId: 'p1',
          onPersonTap: (nick) => tapped = nick,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_colorOf(tester, 'Al'), const Color(0xFF123456));
    expect(_colorOf(tester, 'bob'), NickPalette.of('bob', Tokens.dark));
    await tester.tap(find.text('Al'));
    expect(tapped, 'alice', reason: 'the real nick, not the alias');
  });

  testWidgets('the dialog saves what was typed and can remove it', (
    tester,
  ) async {
    // The card is taller than the default test surface.
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = await _settings();
    // Opened the way the app opens it, on top of a page, so Save has
    // somewhere to pop back to.
    await tester.pumpWidget(
      _app(
        settings,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                PersonDialog.show(context, profileId: 'p1', nick: 'alice'),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing, reason: 'nothing to remove yet');
    expect(find.textContaining('until ddIRC closes'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '  Al  ');
    await tester.enterText(find.byType(TextField).last, 'ops');
    await tester.tap(find.text('Random pixels'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final card = People.instance.of('p1', 'alice')!;
    expect(card.alias, 'Al', reason: 'trimmed');
    expect(card.note, 'ops');
    expect(card.pixelSeed, isNotNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('Al'), findsOneWidget, reason: 'the card comes back');
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(People.instance.of('p1', 'alice'), isNull);
  });

  test('the generated store row type carries what the card needs', () {
    // A compile-time check on the bridge surface, so a regenerated binding
    // that dropped a field fails here rather than at runtime.
    const row = store.Person(profileId: 'p', nick: 'n', pixelSeed: 1);
    expect(row.avatar, isNull);
  });
}
