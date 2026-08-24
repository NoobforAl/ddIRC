// Tests for the motion primitives.
//
// They check the one thing a screenshot cannot: that these widgets *animate*
// rather than snapping, and that they stop when they are told to. Nothing here
// asserts a particular duration — those are design decisions and are meant to
// be tunable without breaking a test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/ui/motion.dart';

/// A child with a known size, so growth can be measured rather than eyeballed.
const _barHeight = 40.0;
const _bar = SizedBox(key: Key('bar'), width: 100, height: _barHeight);
const _chip = SizedBox(key: Key('chip'), width: 20, height: 20);

Widget _host({required Widget child, bool reduceMotion = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      // Top-left, so the tested widget is measured at its own size instead of
      // being stretched by the viewport.
      child: Align(alignment: Alignment.topLeft, child: child),
    ),
  );
}

void main() {
  group('Reveal', () {
    testWidgets('grows into place instead of appearing', (tester) async {
      await tester.pumpWidget(_host(child: const Reveal()));
      expect(tester.getSize(find.byType(Reveal)).height, 0);

      await tester.pumpWidget(_host(child: const Reveal(child: _bar)));
      await tester.pump();
      // Caught mid-flight: neither collapsed nor already finished. This is the
      // assertion that would fail if the AnimatedSize were dropped.
      await tester.pump(const Duration(milliseconds: 80));
      final midway = tester.getSize(find.byType(Reveal)).height;
      expect(midway, greaterThan(0));
      expect(midway, lessThan(_barHeight));

      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Reveal)).height, _barHeight);
    });

    testWidgets('collapses again when its content goes', (tester) async {
      await tester.pumpWidget(_host(child: const Reveal(child: _bar)));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_host(child: const Reveal()));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Reveal)).height, 0);
    });

    testWidgets('is instant when the platform asks for reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(_host(reduceMotion: true, child: const Reveal()));
      await tester.pumpWidget(
        _host(reduceMotion: true, child: const Reveal(child: _bar)),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(find.byType(Reveal)).height, _barHeight);
    });
  });

  group('Appear', () {
    testWidgets('fades a child in and back out', (tester) async {
      await tester.pumpWidget(_host(child: const Appear()));
      expect(find.byKey(const Key('chip')), findsNothing);

      await tester.pumpWidget(_host(child: const Appear(child: _chip)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chip')), findsOneWidget);

      await tester.pumpWidget(_host(child: const Appear()));
      await tester.pump(const Duration(milliseconds: 40));
      // Still on screen part-way through: the exit is animated, not a removal.
      expect(find.byKey(const Key('chip')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chip')), findsNothing);
    });

    testWidgets('takes no space while empty', (tester) async {
      await tester.pumpWidget(_host(child: const Appear()));
      expect(tester.getSize(find.byType(Appear)), Size.zero);
    });

    testWidgets('is instant when the platform asks for reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(_host(reduceMotion: true, child: const Appear()));
      await tester.pumpWidget(
        _host(reduceMotion: true, child: const Appear(child: _chip)),
      );
      await tester.pump();
      expect(find.byKey(const Key('chip')), findsOneWidget);

      await tester.pumpWidget(_host(reduceMotion: true, child: const Appear()));
      await tester.pump();
      expect(find.byKey(const Key('chip')), findsNothing);
    });
  });

  group('Pulse', () {
    double opacityOf(WidgetTester tester) {
      final fade = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byType(Pulse),
          matching: find.byType(FadeTransition),
        ),
      );
      return fade.opacity.value;
    }

    testWidgets('breathes while running and settles opaque when it stops', (
      tester,
    ) async {
      Future<void> pump(bool running) => tester.pumpWidget(
        _host(
          child: Pulse(running: running, child: _chip),
        ),
      );

      await pump(false);
      expect(opacityOf(tester), 1);

      await pump(true);
      await tester.pump();
      final first = opacityOf(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacityOf(tester), isNot(first));

      // Stopping has to actually stop the ticker. If it did not, the widget
      // would be disposed with a live ticker and this test would fail there —
      // and every pumpAndSettle elsewhere in the app would hang forever.
      await pump(false);
      await tester.pumpAndSettle();
      expect(opacityOf(tester), 1);
    });

    testWidgets('never starts under reduced motion', (tester) async {
      await tester.pumpWidget(
        _host(
          reduceMotion: true,
          child: const Pulse(running: true, child: _chip),
        ),
      );
      // No ticker to settle, and the dot stays at full strength.
      await tester.pumpAndSettle();
      expect(opacityOf(tester), 1);
    });
  });
}
