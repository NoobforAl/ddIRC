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

MemberView _member(String nick, {bool away = false}) =>
    MemberView(nick: nick, away: away);

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

double _opacityOf(WidgetTester tester, String nick) {
  return tester
      .widget<Opacity>(
        find.ancestor(of: find.text(nick), matching: find.byType(Opacity)).first,
      )
      .opacity;
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
}
