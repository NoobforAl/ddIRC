import 'package:flutter/material.dart';

import '../theme.dart';

/// A stable colour for every nick, so a busy channel can be read by shape.
///
/// The colour is a function of the name and nothing else: the same nick gets
/// the same colour on every launch, on every device, in every channel, with
/// nothing written anywhere. That is the property that matters — a colour that
/// changed between sessions would be decoration, one that holds is a handle
/// the eye learns in a minute and keeps.
///
/// Folded to lower case before hashing, because IRC treats `Alice` and `alice`
/// as one person and the palette should too. Hashed with FNV-1a rather than
/// `String.hashCode`, which the Dart VM is free to change between versions and
/// platforms; a colour that differed between the phone and the desktop would
/// undo the point.
///
/// Twelve colours per theme. More would be hard to tell apart at 11 points;
/// fewer would put too many people in the same coat. Two people sharing one
/// is possible and fine — the colour is a hint, and the nick is still printed.
class NickPalette {
  NickPalette._();

  /// Read against `0xFF101012`: light enough to carry text, desaturated enough
  /// not to shout beside the accent.
  static const dark = <Color>[
    Color(0xFFE57373),
    Color(0xFFF0A860),
    Color(0xFFE6C84A),
    Color(0xFF9CCC65),
    Color(0xFF4DD0B0),
    Color(0xFF4FC3F7),
    Color(0xFFA48CFF),
    Color(0xFFCE93D8),
    Color(0xFFF48FB1),
    Color(0xFFD7A57A),
    Color(0xFF80CBC4),
    Color(0xFFB0BEC5),
  ];

  /// Read against `0xFFFCFCFD`: the same twelve families, darkened rather than
  /// inverted, for the same reason [Tokens.light] darkens the accent.
  static const light = <Color>[
    Color(0xFFB3261E),
    Color(0xFFB5560A),
    Color(0xFF7A5C00),
    Color(0xFF3D7A1F),
    Color(0xFF127A66),
    Color(0xFF0E6E9E),
    Color(0xFF5A3FBF),
    Color(0xFF8A3A9C),
    Color(0xFFB0296E),
    Color(0xFF7A4B2A),
    Color(0xFF2F6F73),
    Color(0xFF4B5E8A),
  ];

  /// The colour for [nick] under the palette [t] belongs to.
  static Color of(String nick, Tokens t) {
    final palette = t.brightness == Brightness.dark ? dark : light;
    return palette[index(nick, palette.length)];
  }

  /// Which slot of a palette of [count] colours [nick] lands in.
  ///
  /// Separate from [of] so a test can pin the hash without a theme in hand.
  static int index(String nick, int count) =>
      _fnv1a(nick.toLowerCase()) % count;

  /// FNV-1a, 32-bit, over UTF-16 code units. Any stable hash would do; this
  /// one is four lines and has no dependencies.
  static int _fnv1a(String text) {
    var hash = 0x811C9DC5;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
