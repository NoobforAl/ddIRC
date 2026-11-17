// Tests for the nick palette.
//
// The property that matters is stability: the colour is a handle the eye
// learns, and a handle that moves is not one. Legibility is the other half —
// these are our colours, so a bad one is a bug to fix here, not a value to
// nudge at runtime the way sender-chosen mIRC colours are.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/nick_color.dart';

void main() {
  test('the same nick always gets the same colour', () {
    expect(
      NickPalette.of('alice', Tokens.dark),
      NickPalette.of('alice', Tokens.dark),
    );
    expect(
      NickPalette.of('alice', Tokens.light),
      NickPalette.of('alice', Tokens.light),
    );
  });

  test('case does not change the colour, because IRC does not care', () {
    expect(
      NickPalette.of('Alice', Tokens.dark),
      NickPalette.of('alice', Tokens.dark),
    );
    expect(NickPalette.index('BOB', 12), NickPalette.index('bob', 12));
  });

  test('the hash is pinned, so a colour cannot drift between releases', () {
    // FNV-1a of "alice", modulo 12. If this changes, every user's channel
    // recolours itself on update — which is the one thing the palette
    // promised not to do.
    expect(NickPalette.index('alice', 12), 11);
    expect(NickPalette.index('bob', 12), 8);
  });

  test('different nicks spread across the palette', () {
    final used = {
      for (final nick in ['alice', 'bob', 'carol', 'dave', 'erin', 'frank'])
        NickPalette.index(nick, 12),
    };
    // Six people, at least four coats between them: not a proof of
    // distribution, but a hash that sent everyone to one slot would fail it.
    expect(used.length, greaterThanOrEqualTo(4));
  });

  test('every colour reads on both surfaces of its theme', () {
    for (final (palette, t) in [
      (NickPalette.dark, Tokens.dark),
      (NickPalette.light, Tokens.light),
    ]) {
      expect(palette.length, 12);
      for (final color in palette) {
        for (final on in [t.bg, t.surface]) {
          expect(
            MircPalette.contrast(color, on),
            greaterThanOrEqualTo(3.0),
            reason:
                '${color.toARGB32().toRadixString(16)} on '
                '${on.toARGB32().toRadixString(16)} (${t.brightness})',
          );
        }
      }
    }
  });

  test('the switch is on by default and survives a reload', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await AppSettings.load()).colorNicks, isTrue);
    (await AppSettings.load()).colorNicks = false;
    expect((await AppSettings.load()).colorNicks, isFalse);
  });

  group('describeDay', () {
    final now = DateTime(2026, 9, 17, 23, 30);

    test('names the two days people think of relatively', () {
      expect(
        AppSettings.describeDay(DateTime(2026, 9, 17, 0, 5), now: now),
        'Today',
      );
      expect(
        AppSettings.describeDay(DateTime(2026, 9, 16, 23, 59), now: now),
        'Yesterday',
      );
    });

    test('and dates everything older, with the year only when it differs', () {
      expect(
        AppSettings.describeDay(DateTime(2026, 9, 15), now: now),
        '15 September',
      );
      expect(
        AppSettings.describeDay(DateTime(2025, 12, 31), now: now),
        '31 December 2025',
      );
    });

    test('sameDay is about the calendar, not the clock', () {
      expect(
        AppSettings.sameDay(
          DateTime(2026, 9, 17, 0, 1),
          DateTime(2026, 9, 17, 23),
        ),
        isTrue,
      );
      expect(
        AppSettings.sameDay(
          DateTime(2026, 9, 17, 23, 59),
          DateTime(2026, 9, 18),
        ),
        isFalse,
      );
    });
  });
}
