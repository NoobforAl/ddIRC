// Tests for the error shake.
//
// Two things worth pinning. It has to actually move — a shake that silently
// stopped working would leave a rejected field looking accepted, and nothing
// in a screenshot would say so. And it has to stop moving when the platform
// asks for reduced motion, which is the whole reason it now reads its duration
// from `context.motion` instead of carrying its own.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/ui/shake.dart';

const _field = SizedBox(key: Key('field'), width: 200, height: 30);

Widget _host({required int tick, bool reduceMotion = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Shake(tick: tick, child: _field),
      ),
    ),
  );
}

double _dx(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const Key('field'))).dx;

void main() {
  testWidgets('sits still until the tick changes', (tester) async {
    await tester.pumpWidget(_host(tick: 0));
    expect(_dx(tester), 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_dx(tester), 0);
  });

  testWidgets('nudges the field, then settles exactly where it started', (
    tester,
  ) async {
    await tester.pumpWidget(_host(tick: 0));
    await tester.pumpWidget(_host(tick: 1));

    await tester.pump(const Duration(milliseconds: 30));
    expect(_dx(tester), isNot(0));

    // Back to the origin, not merely near it: the oscillation is damped so it
    // lands where it began and the form does not end up subtly crooked.
    await tester.pumpAndSettle();
    expect(_dx(tester), 0);
  });

  testWidgets('does not move under reduced motion', (tester) async {
    await tester.pumpWidget(_host(tick: 0, reduceMotion: true));
    await tester.pumpWidget(_host(tick: 1, reduceMotion: true));

    // Sampled across the window the shake would have occupied. The red border
    // and the message under the field carry the error on their own.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(_dx(tester), 0);
    }
  });
}
