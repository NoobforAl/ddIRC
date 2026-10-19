// What the palette test next door does not cover.
//
// `theme_contrast_test.dart` holds the *text* colours to AA on the grounds text
// sits on. It does not look at the colours that are chosen per person or per
// state — a nick's colour, an "ok" green, a "bad" red — and those are drawn on
// the same grounds, including the translucent tint behind your own messages.
// In the light theme five of the twelve nick colours fell short there, so some
// names were hard to read in the very messages you wrote. This is the check
// that would have said so.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/nick_color.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final (name, t, palette) in [
    ('dark', Tokens.dark, NickPalette.dark),
    ('light', Tokens.light, NickPalette.light),
  ]) {
    group('$name theme', () {
      // Every ground a name is drawn on.
      final grounds = {
        'the page': t.bg,
        'a bubble': t.bubble,
        'your own bubble': Color.alphaBlend(t.own, t.bg),
        'a mention': Color.alphaBlend(t.mention, t.bubble),
      };

      for (var i = 0; i < palette.length; i++) {
        test('nick colour $i reads on every ground (AA, 4.5:1)', () {
          for (final MapEntry(key: label, value: ground) in grounds.entries) {
            expect(
              _contrast(palette[i], ground),
              greaterThanOrEqualTo(4.5),
              reason: 'nick colour $i on $label',
            );
          }
        });
      }

      for (final (label, colour) in [
        ('ok', t.ok),
        ('warn', t.warn),
        ('bad', t.bad),
      ]) {
        test('$label reads as text on the page, the chrome and a bubble', () {
          for (final ground in [t.bg, t.surface, t.bubble]) {
            expect(_contrast(colour, ground), greaterThanOrEqualTo(4.5));
          }
        });
      }

      test(
        'a bubble, the chrome and the rule are all told apart from the page',
        () {
          expect(t.bubble, isNot(t.bg));
          expect(t.surface, isNot(t.bg));
          expect(t.rule, isNot(t.bg));
        },
      );
    });
  }

  test('the palettes have twelve distinct colours each', () {
    expect(NickPalette.dark.toSet().length, 12);
    expect(NickPalette.light.toSet().length, 12);
  });
}
