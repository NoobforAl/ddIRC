// The window's own controls, drawn by the app because the OS frame is hidden.
//
// Each desktop gets the controls its users already know: macOS keeps the three
// lights, and Windows and Linux get minimise, maximise-or-restore and close
// as caption buttons. The macOS lights were once drawn on every platform, which
// put "close" at the opposite corner from where a Windows or Linux hand looks.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/window_chrome.dart';

const _channel = MethodChannel('window_manager');

Widget _host(Widget child) => MaterialApp(
  theme: Tokens.themeFor(Tokens.dark),
  home: Scaffold(
    body: Align(alignment: Alignment.topRight, child: child),
  ),
);

Finder _button(String label) => find.bySemanticsLabel(label);

/// Runs [body] as if on [platform], and puts the real one back before the test
/// ends — the framework checks for a leftover override before tearDown runs.
Future<void> _as(TargetPlatform platform, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  late List<String> calls;
  var maximised = false;

  setUp(() {
    calls = [];
    maximised = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          if (call.method == 'isMaximized') return maximised;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    group('on $platform', () {
      testWidgets(
        'shows minimise, maximise and close, in that order',
        (tester) => _as(platform, () async {
          await tester.pumpWidget(_host(const WindowControls()));
          await tester.pump();

          expect(_button('Minimise'), findsOneWidget);
          expect(_button('Maximise'), findsOneWidget);
          expect(_button('Close'), findsOneWidget);

          final xs = [
            for (final label in ['Minimise', 'Maximise', 'Close'])
              tester.getCenter(_button(label)).dx,
          ];
          expect(xs, orderedEquals([...xs]..sort()));
        }),
      );

      testWidgets('each button drives the window', (tester) {
        return _as(platform, () async {
          await tester.pumpWidget(_host(const WindowControls()));
          await tester.pump();
          calls.clear();

          await tester.tap(_button('Minimise'));
          await tester.pump();
          expect(calls, contains('minimize'));

          calls.clear();
          await tester.tap(_button('Maximise'));
          await tester.pump();
          expect(calls, containsAllInOrder(['isMaximized', 'maximize']));

          calls.clear();
          await tester.tap(_button('Close'));
          await tester.pump();
          expect(calls, contains('close'));
        });
      });

      testWidgets('offers Restore, not Maximise, once maximised', (tester) {
        return _as(platform, () async {
          maximised = true;
          await tester.pumpWidget(_host(const WindowControls()));
          await tester.pump();

          expect(_button('Restore'), findsOneWidget);
          expect(_button('Maximise'), findsNothing);

          calls.clear();
          await tester.tap(_button('Restore'));
          await tester.pump();
          expect(calls, containsAllInOrder(['isMaximized', 'unmaximize']));
        });
      });
    });
  }

  testWidgets('Windows buttons are full-height, so the whole corner is hit', (
    tester,
  ) {
    return _as(TargetPlatform.windows, () async {
      await tester.pumpWidget(_host(const WindowControls()));
      await tester.pump();

      final size = tester.getSize(_button('Close'));
      expect(size.height, windowChromeHeight);
      expect(size.width, greaterThan(40));
    });
  });

  testWidgets('Linux buttons are compact, the way GTK draws them', (tester) {
    return _as(TargetPlatform.linux, () async {
      await tester.pumpWidget(_host(const WindowControls()));
      await tester.pump();

      expect(
        tester.getSize(_button('Close')).height,
        lessThan(windowChromeHeight),
      );
    });
  });

  testWidgets('hovering Close fills it red on Windows', (tester) {
    return _as(TargetPlatform.windows, () async {
      await tester.pumpWidget(_host(const WindowControls()));
      await tester.pump();

      Color? fillOf() {
        final box = tester.widget<Container>(
          find.descendant(
            of: _button('Close'),
            matching: find.byType(Container),
          ),
        );
        return (box.decoration as BoxDecoration?)?.color;
      }

      expect(fillOf(), isNull);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(_button('Close')));
      await tester.pump();

      expect(fillOf(), const Color(0xFFE81123));
      await mouse.removePointer();
    });
  });

  testWidgets('macOS keeps the three lights and has no caption buttons', (
    tester,
  ) {
    return _as(TargetPlatform.macOS, () async {
      await tester.pumpWidget(_host(const TrafficLights()));
      await tester.pump();

      expect(find.byType(TrafficLights), findsOneWidget);
      expect(_button('Minimise'), findsNothing);
    });
  });
}
