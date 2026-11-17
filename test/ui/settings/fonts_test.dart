// Tests for the typeface stack.
//
// The bug these exist to prevent already happened once: two places asked for
// `fontFamily: 'monospace'`, which is an Android and CSS convention. Nothing
// on Windows, macOS or Linux is called that, so the request found no font and
// silently fell back to the proportional default — monospaced text was not
// monospaced anywhere but Android, and nothing failed to say so.
//
// A widget test cannot see which font actually rendered: `flutter test` uses a
// stand-in face where every glyph is the same box, so measuring would prove
// nothing. What it can check is that the app asks for fonts that exist, which
// is precisely what went wrong.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/settings_chrome.dart';

/// The style a readout's value is actually painted with.
///
/// Values are rendered with [SelectableText], which finds as the [EditableText]
/// underneath it - and that is the useful one to read, because it carries the
/// style after the theme has been merged in rather than only what the widget
/// asked for.
TextStyle _valueStyle(WidgetTester tester, String text) =>
    tester.widget<EditableText>(find.text(text)).style;

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('the monospace stack', () {
    test('does not rely on the generic name alone', () {
      // The whole bug in one assertion: `monospace` is not a font on three of
      // the four platforms this ships to.
      expect(Fonts.mono, isNot('monospace'));
      expect(Fonts.mono, isNotEmpty);
    });

    test('names a real font for every platform it ships to', () {
      final all = [Fonts.mono, ...Fonts.monoFallback];
      // One from each, so no platform is left resolving to nothing.
      for (final expected in [
        'Consolas', // Windows
        'Menlo', // macOS and iOS
        'DejaVu Sans Mono', // Linux
        'Roboto Mono', // Android
      ]) {
        expect(all, contains(expected));
      }
    });

    test('keeps the generic name last, where it cannot shadow a real one', () {
      // It still resolves on Android and Linux. Ahead of a named font it would
      // win over a better one.
      expect(Fonts.monoFallback.last, 'monospace');
    });
  });

  group('the text stack', () {
    test('leaves the primary face to the platform and only adds the net', () {
      // Flutter has already chosen a family per platform - Roboto under test
      // and on Android, Segoe UI on Windows, the San Francisco faces on Apple
      // hardware. That choice is left alone; all that is added is the list to
      // fall back through for glyphs it does not carry.
      final theme = Tokens.themeFor(Tokens.dark);
      final body = theme.textTheme.bodyMedium;

      expect(body?.fontFamily, isNotNull, reason: 'platform default expected');
      expect(body?.fontFamilyFallback, Fonts.ui);
    });

    test('covers each platform and ends with emoji', () {
      for (final expected in ['Segoe UI', 'Roboto', 'Noto Sans']) {
        expect(Fonts.ui, contains(expected));
      }
      // IRC carries plenty of emoji, and a missing glyph box is worse than an
      // imperfect match.
      expect(Fonts.ui.any((f) => f.contains('Emoji')), isTrue);
    });

    test('is applied in both themes', () {
      for (final tokens in [Tokens.dark, Tokens.light]) {
        final theme = Tokens.themeFor(tokens);
        expect(theme.textTheme.bodyLarge?.fontFamilyFallback, Fonts.ui);
        expect(theme.primaryTextTheme.bodyLarge?.fontFamilyFallback, Fonts.ui);
      }
    });
  });

  group('on screen', () {
    testWidgets('a monospace readout asks for a monospace font', (
      tester,
    ) async {
      await _pump(
        tester,
        const SettingsReadout(
          label: 'Server',
          value: '127.0.0.1:6697',
          monospace: true,
        ),
      );

      final style = _valueStyle(tester, '127.0.0.1:6697');
      expect(style.fontFamily, Fonts.mono);
      expect(style.fontFamilyFallback, Fonts.monoFallback);
    });

    testWidgets('an ordinary readout asks for no family at all', (
      tester,
    ) async {
      await _pump(
        tester,
        const SettingsReadout(label: 'Network', value: 'ErgoTest'),
      );

      final style = _valueStyle(tester, 'ErgoTest');
      // Not the monospace stack, and the theme's net has reached it - which
      // is the half a theme-level assertion alone cannot show.
      expect(style.fontFamily, isNot(Fonts.mono));
      expect(style.fontFamilyFallback, Fonts.ui);
    });
  });
}
