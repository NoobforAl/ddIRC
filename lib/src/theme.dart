import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Design tokens.
///
/// The palette is deliberately narrow — two surfaces, one rule, two text
/// weights, one accent, three status colours. Typography and spacing carry the
/// layout, so there are no gradients, shadows or elevation anywhere in the app,
/// and separation is a hairline.
class Tokens {
  /// 0.5 logical pixels: a true hairline on any density.
  static const hairline = 0.5;

  static const bg = Color(0xFF101012);
  static const surface = Color(0xFF161619);
  static const surfaceHover = Color(0xFF1D1D22);
  static const rule = Color(0xFF2A2A30);

  static const text = Color(0xFFE6E6EA);
  static const muted = Color(0xFF83838F);
  static const faint = Color(0xFF5A5A64);

  static const accent = Color(0xFF7FB3FF);

  /// A wash, not a shout — a mention should catch the eye on a scan without
  /// making the message harder to read.
  static const mention = Color(0x1A7FB3FF);
  static const mentionRule = Color(0xFF7FB3FF);

  static const ok = Color(0xFF6FCF8B);
  static const warn = Color(0xFFE0B341);
  static const bad = Color(0xFFE06C6C);

  static const badge = Color(0xFF3A6EA5);

  static ThemeData theme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        surface: bg,
      ),
      // Ornament the design excludes.
      dividerTheme: const DividerThemeData(
        thickness: hairline,
        color: rule,
        space: hairline,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }
}

/// The mIRC colour palette, indices 0-98.
///
/// Servers and users pick these freely, so they cannot be trusted to be legible
/// against our background — see [MircPalette.resolve], which is what UI code
/// should actually call.
class MircPalette {
  static const _colors = <int>[
    // 0-15: the classic palette everyone actually uses.
    0xFFFFFF, 0x000000, 0x00007F, 0x009300, 0xFF0000, 0x7F0000, 0x9C009C,
    0xFC7F00, 0xFFFF00, 0x00FC00, 0x009393, 0x00FFFF, 0x0000FC, 0xFF00FF,
    0x7F7F7F, 0xD2D2D2,
    // 16-98: the extended palette.
    0x470000, 0x472100, 0x474700, 0x324700, 0x004700, 0x00472C, 0x004747,
    0x004031, 0x000047, 0x2E0047, 0x470047, 0x47002A, 0x740000, 0x743A00,
    0x747400, 0x517400, 0x007400, 0x007449, 0x007474, 0x006474, 0x000074,
    0x4B0074, 0x740074, 0x740045, 0xB50000, 0xB56300, 0xB5B500, 0x7DB500,
    0x00B500, 0x00B571, 0x00B5B5, 0x009DB5, 0x0000B5, 0x7500B5, 0xB500B5,
    0xB5006B, 0xFF0000, 0xFF8C00, 0xFFFF00, 0xB2FF00, 0x00FF00, 0x00FFA0,
    0x00FFFF, 0x00CCFF, 0x0000FF, 0xA500FF, 0xFF00FF, 0xFF0098, 0xFF5959,
    0xFFB459, 0xFFFF71, 0xCFFF60, 0x6FFF6F, 0x65FFC9, 0x6DFFFF, 0x59CCFF,
    0x5959FF, 0xC459FF, 0xFF66FF, 0xFF59BC, 0xFF9C9C, 0xFFD39C, 0xFFFF9C,
    0xE2FF9C, 0x9CFF9C, 0x9CFFDB, 0x9CFFFF, 0x9CD3FF, 0x9C9CFF, 0xDC9CFF,
    0xFF9CFF, 0xFF94D3, 0x000000, 0x131313, 0x282828, 0x363636, 0x4D4D4D,
    0x656565, 0x818181, 0x9F9F9F, 0xBCBCBC, 0xE2E2E2, 0xFFFFFF,
  ];

  static Color? _raw(int? index) {
    if (index == null || index < 0 || index >= _colors.length) return null;
    return Color(0xFF000000 | _colors[index]);
  }

  /// A background colour for a run of text, or null to leave it transparent.
  static Color? background(int? index) => _raw(index);

  /// A foreground colour that is guaranteed readable on `on`.
  ///
  /// Colour 1 (black) is extremely common in messages written on light-themed
  /// clients, and rendering it literally on our dark background produces
  /// invisible text. Rather than dropping colour support, nudge anything with
  /// too little contrast back to the normal text colour — the styling intent is
  /// mostly decorative, but legibility is not optional.
  static Color resolve(
    int? index, {
    required Color on,
    Color fallback = Tokens.text,
  }) {
    final color = _raw(index);
    if (color == null) return fallback;
    if (_contrast(color, on) < 2.0) return fallback;
    return color;
  }

  /// WCAG relative-luminance contrast ratio.
  static double _contrast(Color a, Color b) {
    final la = _luminance(a);
    final lb = _luminance(b);
    final (hi, lo) = la > lb ? (la, lb) : (lb, la);
    return (hi + 0.05) / (lo + 0.05);
  }

  static double _luminance(Color c) {
    double channel(double v) {
      return v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    }

    // Color.r/g/b are already normalised to 0..1.
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }
}
