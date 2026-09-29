// The palettes were softened: a lifted ground instead of near-black, a warm
// paper instead of white, a quieter accent. Softer must not mean harder to
// read, so every pairing text actually sits on is held to WCAG AA here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final (name, t) in [('dark', Tokens.dark), ('light', Tokens.light)]) {
    group('$name palette', () {
      // What text is drawn on: the ground, the chrome, someone else's bubble,
      // and your own bubble — a translucent tint, so blended over the ground.
      final grounds = {
        'bg': t.bg,
        'surface': t.surface,
        'bubble': t.bubble,
        'own': Color.alphaBlend(t.own, t.bg),
        'mention': Color.alphaBlend(t.mention, t.bubble),
      };

      for (final MapEntry(key: ground, value: color) in grounds.entries) {
        test('body text reads on $ground (AA, 4.5:1)', () {
          expect(_contrast(t.text, color), greaterThanOrEqualTo(4.5));
        });
        test('muted text reads on $ground (AA, 4.5:1)', () {
          expect(_contrast(t.muted, color), greaterThanOrEqualTo(4.5));
        });
      }

      test('the accent reads as text on the ground (AA, 4.5:1)', () {
        expect(_contrast(t.accent, t.bg), greaterThanOrEqualTo(4.5));
      });

      test('what sits on the accent reads on it (AA, 4.5:1)', () {
        expect(_contrast(t.onAccent, t.accent), greaterThanOrEqualTo(4.5));
      });

      test('faint text is still visible (3:1, for incidental text)', () {
        expect(_contrast(t.faint, t.bg), greaterThanOrEqualTo(3));
      });

      test('a bubble is a shape on the ground without a border', () {
        expect(t.bubble, isNot(t.bg));
      });
    });
  }
}
