import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Design tokens.
///
/// The palette is deliberately narrow — two surfaces, one rule, two text
/// weights, one accent, three status colours. Typography and spacing carry the
/// layout, so there are no gradients, shadows or elevation anywhere in the app,
/// and separation is a hairline.
///
/// There are two instances, [dark] and [light]. They ride on [ThemeData] as a
/// [ThemeExtension] so that `themeMode` picks between them and Flutter animates
/// the change; widgets never name one directly, they read `context.tokens`.
class Tokens extends ThemeExtension<Tokens> {
  const Tokens._({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceHover,
    required this.rule,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.onAccent,
    required this.mention,
    required this.mentionRule,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.badge,
  });

  /// 0.5 logical pixels: a true hairline on any density.
  ///
  /// A metric rather than a colour, so it stays a compile-time constant and
  /// keeps working inside `const` widget expressions.
  static const hairline = 0.5;

  final Brightness brightness;

  final Color bg;
  final Color surface;
  final Color surfaceHover;
  final Color rule;

  final Color text;
  final Color muted;
  final Color faint;

  final Color accent;

  /// What sits *on* [accent] — badge text, a filled button's label, a switch
  /// thumb. Not the same thing as [bg], even though in the dark palette they
  /// happen to share a value.
  final Color onAccent;

  /// A wash, not a shout — a mention should catch the eye on a scan without
  /// making the message harder to read.
  final Color mention;
  final Color mentionRule;

  final Color ok;
  final Color warn;
  final Color bad;

  final Color badge;

  static const dark = Tokens._(
    brightness: Brightness.dark,
    bg: Color(0xFF101012),
    surface: Color(0xFF161619),
    surfaceHover: Color(0xFF1D1D22),
    rule: Color(0xFF2A2A30),
    text: Color(0xFFE6E6EA),
    muted: Color(0xFF83838F),
    faint: Color(0xFF5A5A64),
    accent: Color(0xFF7FB3FF),
    onAccent: Color(0xFF101012),
    mention: Color(0x1A7FB3FF),
    mentionRule: Color(0xFF7FB3FF),
    ok: Color(0xFF6FCF8B),
    warn: Color(0xFFE0B341),
    bad: Color(0xFFE06C6C),
    badge: Color(0xFF3A6EA5),
  );

  /// Not an inversion of [dark]: an accent that reads well *on* near-black is
  /// too pale to read *against* near-white, so the accent and the three status
  /// colours are darkened rather than flipped.
  static const light = Tokens._(
    brightness: Brightness.light,
    bg: Color(0xFFFCFCFD),
    surface: Color(0xFFF3F3F6),
    surfaceHover: Color(0xFFE9E9EE),
    rule: Color(0xFFDCDCE2),
    text: Color(0xFF17171B),
    muted: Color(0xFF63636E),
    faint: Color(0xFF8E8E99),
    accent: Color(0xFF2A62C4),
    onAccent: Color(0xFFFFFFFF),
    mention: Color(0x142A62C4),
    mentionRule: Color(0xFF2A62C4),
    ok: Color(0xFF1E7F45),
    warn: Color(0xFF8A6100),
    bad: Color(0xFFC0392F),
    // Pale rather than solid, so an unread count still carries [text] and only
    // a mention gets the loud accent chip. The dark palette gets the same
    // effect the other way round, from a mid blue under near-white text.
    badge: Color(0xFFC9D9F5),
  );

  /// The palette a mode resolves to right now.
  ///
  /// Inside the app, `themeMode` on [MaterialApp] does this and widgets read
  /// `context.tokens`. This is for the one caller that needs a colour before
  /// there is a context at all: the native window background, which is painted
  /// before the first frame.
  static Tokens forMode(ThemeMode mode) => switch (mode) {
    ThemeMode.light => light,
    ThemeMode.dark => dark,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.light
          ? light
          : dark,
  };

  static ThemeData themeFor(Tokens t) {
    return ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      scaffoldBackgroundColor: t.bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: t.accent,
        brightness: t.brightness,
        surface: t.bg,
      ),
      // Ornament the design excludes.
      dividerTheme: DividerThemeData(
        thickness: hairline,
        color: t.rule,
        space: hairline,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      extensions: [t],
    );
  }

  @override
  Tokens copyWith({
    Brightness? brightness,
    Color? bg,
    Color? surface,
    Color? surfaceHover,
    Color? rule,
    Color? text,
    Color? muted,
    Color? faint,
    Color? accent,
    Color? onAccent,
    Color? mention,
    Color? mentionRule,
    Color? ok,
    Color? warn,
    Color? bad,
    Color? badge,
  }) {
    return Tokens._(
      brightness: brightness ?? this.brightness,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      rule: rule ?? this.rule,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      faint: faint ?? this.faint,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      mention: mention ?? this.mention,
      mentionRule: mentionRule ?? this.mentionRule,
      ok: ok ?? this.ok,
      warn: warn ?? this.warn,
      bad: bad ?? this.bad,
      badge: badge ?? this.badge,
    );
  }

  /// Cross-fades one palette into the other, which is what turns switching
  /// themes into a transition rather than a flash.
  @override
  Tokens lerp(covariant ThemeExtension<Tokens>? other, double t) {
    if (other is! Tokens) return this;
    return Tokens._(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      mention: Color.lerp(mention, other.mention, t)!,
      mentionRule: Color.lerp(mentionRule, other.mentionRule, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      bad: Color.lerp(bad, other.bad, t)!,
      badge: Color.lerp(badge, other.badge, t)!,
    );
  }
}

/// `context.tokens` — the only way UI code should reach the palette.
extension TokensOf on BuildContext {
  Tokens get tokens => Theme.of(this).extension<Tokens>() ?? Tokens.dark;
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
  /// Senders pick a colour for the background *they* are looking at, so either
  /// theme sees the problem from one end or the other: colour 1 (black) is
  /// common in messages written on light clients and vanishes on our dark
  /// surface, and colour 0 (white) does the same on our light one. Rather than
  /// dropping colour support, nudge anything with too little contrast against
  /// `on` back to `fallback` — the styling intent is mostly decorative, but
  /// legibility is not optional.
  static Color resolve(
    int? index, {
    required Color on,
    required Color fallback,
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
