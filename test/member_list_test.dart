// Tests for the member list's arrivals.
//
// The distinction being protected is between *appearing* and *arriving*. The
// people already in a channel when you open it were not watched joining, and
// fading in thirty of them at once is a flash rather than an animation. Only
// the nick that turned up while you were looking should move.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/rust/api/types.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/member_list.dart';
import 'package:ddirc/src/ui/touchable.dart';

MemberView _member(String nick, {bool away = false}) =>
    // The key the core would have given an unprivileged member: rank first,
    // then the nick folded. Written out rather than faked, so a list built
    // here sorts the way one off the wire does.
    MemberView(nick: nick, away: away, sortKey: 'ffff${nick.toLowerCase()}');

Future<void> _pump(WidgetTester tester, List<String> nicks) {
  return tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: Scaffold(
        body: MemberList(members: [for (final n in nicks) _member(n)]),
      ),
    ),
  );
}

/// How strongly the row for [nick] is drawn, where no [Opacity] layer at all
/// counts as full strength.
///
/// A row at rest carries no opacity layer: [Arrive] builds none for a row that
/// was already there, and drops the one it built as soon as the row has
/// landed. So its absence is not a gap in the test — it is the strongest
/// statement available that the row is drawn plainly.
double _opacityOf(WidgetTester tester, String nick) {
  final layers = find.ancestor(
    of: find.text(nick),
    matching: find.byType(Opacity),
  );
  if (layers.evaluate().isEmpty) return 1;
  return tester.widget<Opacity>(layers.first).opacity;
}

void main() {
  testWidgets('shows the people already here at full strength', (tester) async {
    await _pump(tester, ['ada', 'grace']);
    expect(_opacityOf(tester, 'ada'), 1);
    expect(_opacityOf(tester, 'grace'), 1);
  });

  testWidgets('fades in a nick that joins while you are watching', (
    tester,
  ) async {
    await _pump(tester, ['ada']);
    await _pump(tester, ['ada', 'grace']);

    expect(_opacityOf(tester, 'grace'), 0);
    // The person who was already there does not flicker just because someone
    // else arrived.
    expect(_opacityOf(tester, 'ada'), 1);

    await tester.pumpAndSettle();
    expect(_opacityOf(tester, 'grace'), 1);
  });

  testWidgets('does not replay the arrival on a later rebuild', (tester) async {
    await _pump(tester, ['ada']);
    await _pump(tester, ['ada', 'grace']);
    await tester.pumpAndSettle();

    // A rebuild with the same membership — a theme change, a resize. Nothing
    // arrived, so nothing should move.
    await _pump(tester, ['ada', 'grace']);
    expect(_opacityOf(tester, 'grace'), 1);
  });

  testWidgets('counts the room, singular and plural', (tester) async {
    await _pump(tester, ['ada']);
    expect(find.text('1 member'), findsOneWidget);

    await _pump(tester, ['ada', 'grace']);
    await tester.pumpAndSettle();
    expect(find.text('2 members'), findsOneWidget);
  });

  testWidgets('a departure removes the row and moves the count', (
    tester,
  ) async {
    await _pump(tester, ['ada', 'grace']);
    await tester.pumpAndSettle();

    await _pump(tester, ['ada']);
    await tester.pumpAndSettle();
    expect(find.text('grace'), findsNothing);
    expect(find.text('1 member'), findsOneWidget);
  });

  // The whole reason to know who is in a channel is to be able to say
  // something to one of them. Before this the roster was a list you could only
  // read: no tap handler existed anywhere in it.
  testWidgets('tapping a nick asks to open a conversation with them', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: Scaffold(
          body: MemberList(
            members: [_member('ada'), _member('grace')],
            onOpenDirect: opened.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('grace'));
    await tester.pump();

    // The nick that was tapped, not the one that happened to be first.
    expect(opened, ['grace']);
  });

  testWidgets('a roster with nowhere to go does not pretend to be tappable', (
    tester,
  ) async {
    await _pump(tester, ['ada']);
    await tester.pumpAndSettle();

    // `Touchable` reports `Touch.none` and refuses hover when it has no
    // action, so a list built without a handler cannot light up under the
    // pointer as though it were about to do something.
    final touchable = tester.widget<Touchable>(
      find
          .ancestor(of: find.text('ada'), matching: find.byType(Touchable))
          .first,
    );
    expect(touchable.onTap, isNull);
  });
}
