// Tests for the startup gate.
//
// Three behaviours, none of which can be seen in a screenshot: a start that
// finishes quickly must never flash a logo, a start that is slow must hold the
// splash long enough to be read, and a start that fails must say so and be
// retryable. The last one is the reason this widget exists — before it, a core
// that would not load produced an empty window and no explanation.
//
// Motion is switched off throughout. It makes the frames deterministic, and it
// keeps the splash's own looping animation from stopping `pumpAndSettle` from
// ever returning.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/boot_screen.dart';

const _starting = 'Starting the core…';
const _failed = 'ddIRC could not start';
const _app = 'the app';

Future<void> _pumpBoot(
  WidgetTester tester,
  Future<void> Function() load,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: BootScreen(load: load, builder: (context) => const Text(_app)),
        ),
      ),
    ),
  );
}

/// How far into the splash a given moment is. Deliberately loose: the exact
/// timings are design decisions, and these tests are about the order of
/// events, not the numbers.
const _beforeReveal = Duration(milliseconds: 60);
const _afterReveal = Duration(milliseconds: 260);
const _wellPast = Duration(seconds: 1);

double _splashOpacity(WidgetTester tester) {
  final opacity = tester.widget<AnimatedOpacity>(
    find
        .ancestor(
          of: find.text(_starting),
          matching: find.byType(AnimatedOpacity),
        )
        .first,
  );
  return opacity.opacity;
}

void main() {
  testWidgets('shows nothing at all for a start that finishes at once', (
    tester,
  ) async {
    await _pumpBoot(tester, () async {});

    // The splash is mounted from the first frame but transparent, so a warm
    // start shows the background and then the app — never a logo blinking.
    expect(_splashOpacity(tester), 0);

    await tester.pump(_beforeReveal);
    expect(find.text(_app), findsOneWidget);
    expect(find.text(_starting), findsNothing);
  });

  testWidgets('reveals itself when the start is slow', (tester) async {
    final gate = Completer<void>();
    await _pumpBoot(tester, () => gate.future);

    await tester.pump(_afterReveal);
    expect(_splashOpacity(tester), 1);
    expect(find.text(_app), findsNothing);

    gate.complete();
    await tester.pump();
    // Still there: once the splash is on screen it stays put, because one that
    // blinks out reads as a glitch rather than as a start.
    expect(find.text(_starting), findsOneWidget);
    expect(find.text(_app), findsNothing);

    await tester.pump(_wellPast);
    await tester.pumpAndSettle();
    expect(find.text(_app), findsOneWidget);
    expect(find.text(_starting), findsNothing);
  });

  testWidgets('reports a failure instead of an empty window', (tester) async {
    await _pumpBoot(tester, () async => throw StateError('no such library'));
    await tester.pump(_wellPast);
    await tester.pumpAndSettle();

    expect(find.text(_failed), findsOneWidget);
    // The real message, verbatim — it names the library, which is the only
    // thing that will fix this.
    expect(find.textContaining('no such library'), findsOneWidget);
    expect(find.text(_app), findsNothing);
  });

  testWidgets('retries, and gets there on the second attempt', (tester) async {
    var attempts = 0;
    await _pumpBoot(tester, () async {
      attempts++;
      if (attempts == 1) throw StateError('not yet');
    });
    await tester.pump(_wellPast);
    await tester.pumpAndSettle();
    expect(find.text(_failed), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump(_wellPast);
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text(_app), findsOneWidget);
    expect(find.text(_failed), findsNothing);
  });
}
