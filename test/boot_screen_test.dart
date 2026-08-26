// Tests for the startup gate.
//
// Four behaviours, none of which can be seen in a screenshot: a start that
// finishes quickly must never flash a logo, a start that is slow must hold the
// splash long enough to be read, a start that fails must say so and be
// retryable, and on Android the splash must be there from the very first frame
// because the system has already been showing the mark. The failure case is
// the reason this widget exists — before it, a core that would not load
// produced an empty window and no explanation.
//
// Motion is switched off throughout. It makes the frames deterministic, and it
// keeps the splash's own looping animation from stopping `pumpAndSettle` from
// ever returning.

import 'dart:async';

import 'package:flutter/foundation.dart';
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
  testWidgets('on a desktop, shows nothing for a start that finishes at once', (
    tester,
  ) async {
    // Widget tests report Android unless told otherwise, and Android is now
    // the platform with the different answer — so the desktop behaviour has to
    // name its platform or it silently stops being tested. Set and cleared
    // inside the body, because the framework checks the override is unset
    // before any `tearDown` gets to run.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _pumpBoot(tester, () async {});

    // The splash is mounted from the first frame but transparent, so a warm
    // start shows the background and then the app — never a logo blinking.
    expect(_splashOpacity(tester), 0);

    await tester.pump(_beforeReveal);
    expect(find.text(_app), findsOneWidget);
    expect(find.text(_starting), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on Android the splash is there from the first frame', (
    tester,
  ) async {
    // Because the system has been drawing the mark on this same background
    // since the process started. Waiting would take it away and put it back,
    // which is the blink the quiet period exists to prevent — so on the one
    // platform that has a real launch screen, the quiet period is the thing
    // that would cause it.
    expect(defaultTargetPlatform, TargetPlatform.android);

    final gate = Completer<void>();
    await _pumpBoot(tester, () => gate.future);

    expect(_splashOpacity(tester), 1);
    expect(find.text(_starting), findsOneWidget);

    gate.complete();
    await tester.pump(_wellPast);
    await tester.pumpAndSettle();
    expect(find.text(_app), findsOneWidget);
  });

  testWidgets('reveals itself when the start is slow', (tester) async {
    // Timed against the desktop quiet period, which is the one there is a
    // reveal to wait for.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

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
    debugDefaultTargetPlatformOverride = null;
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
