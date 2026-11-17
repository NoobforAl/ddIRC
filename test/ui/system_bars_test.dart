// The phone's own bars take the app's colours.
//
// Nothing used to set them, so a light app got a grey status bar and a black
// navigation bar. These hold the two properties that matter: the bars are the
// app's ground colour, and their icons are the opposite brightness to it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/system_bars.dart';

void main() {
  for (final (name, t) in [('dark', Tokens.dark), ('light', Tokens.light)]) {
    group('$name theme', () {
      final style = SystemBars.styleFor(t);

      test('both bars are the colour of the page', () {
        expect(style.statusBarColor, t.bg);
        expect(style.systemNavigationBarColor, t.bg);
      });

      test('the icons contrast with the bar they sit on', () {
        final onLightBar = t.bg.computeLuminance() > 0.5;
        final expected = onLightBar ? Brightness.dark : Brightness.light;
        expect(style.statusBarIconBrightness, expected);
        expect(style.systemNavigationBarIconBrightness, expected);
      });

      test(
        'there is no seam and no darkening between the app and the bars',
        () {
          expect(style.systemNavigationBarDividerColor, Colors.transparent);
          expect(style.systemNavigationBarContrastEnforced, isFalse);
          expect(style.systemStatusBarContrastEnforced, isFalse);
        },
      );

      testWidgets('is applied to everything beneath it', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: Tokens.themeFor(t),
            home: const SystemBars(child: SizedBox.expand()),
          ),
        );
        final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
        );
        expect(region.value.statusBarColor, t.bg);
        expect(region.value.systemNavigationBarColor, t.bg);
      });
    });
  }

  test('the two themes disagree about icons, which is the whole point', () {
    expect(
      SystemBars.styleFor(Tokens.light).statusBarIconBrightness,
      isNot(SystemBars.styleFor(Tokens.dark).statusBarIconBrightness),
    );
  });
}
