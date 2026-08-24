/// The ddIRC mark, as numbers.
///
/// A hash on a rounded square. `#` is the channel sigil — it is what an IRC
/// address looks like, it predates every other use of the character, and it is
/// legible at sixteen pixels where a wordmark or a speech bubble is a smear.
/// Slanted, because the typed character is, and because a perfectly upright
/// one reads as a tic-tac-toe grid.
///
/// Everything is a fraction of the side, so one set of numbers describes the
/// icon at 16 pixels and at 1024. Two things draw from it and they must not
/// drift: [AppMark], the widget on the splash and the empty screen, and
/// `tool/make_icons.dart`, which rasterises the launcher icons. Hence a file
/// with no Flutter import — the generator runs on the plain Dart VM, where
/// `dart:ui` does not exist.
///
/// The colours are fixed rather than themed. This is the app's mark: it is the
/// same on a light desktop, a dark taskbar and an Android launcher, which is
/// the whole point of having one.
library;

class MarkSpec {
  const MarkSpec._();

  /// Corner radius of the field.
  static const corner = 0.22;

  /// Stroke width of the hash. At a 16-pixel icon this is 1.6 physical
  /// pixels — thin enough to stay a hash, thick enough to survive a taskbar.
  static const stroke = 0.10;

  /// The glyph's bounding box, inset from each edge.
  static const inset = 0.24;

  /// Where the two horizontal bars sit, as a fraction of the height.
  static const barTop = 0.395;
  static const barBottom = 0.605;

  /// Where the two vertical bars cross the middle, as a fraction of the width.
  static const stemLeft = 0.395;
  static const stemRight = 0.605;

  /// How far each vertical leans: its top is this much to the right of
  /// [stemLeft] / [stemRight], its foot the same distance to the left. About
  /// ten degrees, which is the lean of the character in most text faces.
  static const slant = 0.05;

  /// The field. The light theme's accent — strong enough to hold a shape at
  /// any size, and already part of the palette rather than a fourth blue.
  static const fieldColor = 0xFF2A62C4;

  /// The hash. Near-white rather than white: the same off-white the light
  /// theme uses for its background, so the mark is made of the app's colours.
  static const glyphColor = 0xFFF7F9FC;

  /// The four strokes, as `(x1, y1, x2, y2)` in unit coordinates.
  ///
  /// One list rather than two loops, so the painter and the rasteriser cannot
  /// disagree about which bar goes where.
  static const strokes = <(double, double, double, double)>[
    // Horizontals, left to right.
    (inset, barTop, 1 - inset, barTop),
    (inset, barBottom, 1 - inset, barBottom),
    // Verticals, top to bottom, leaning right.
    (stemLeft + slant, inset, stemLeft - slant, 1 - inset),
    (stemRight + slant, inset, stemRight - slant, 1 - inset),
  ];
}
