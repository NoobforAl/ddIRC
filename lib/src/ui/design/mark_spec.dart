/// The ddIRC mark, as numbers.
///
/// A hash on a rounded square. `#` is the channel sigil — it is what an IRC
/// address looks like, it predates every other use of the character, and it is
/// legible at sixteen pixels where a wordmark or a speech bubble is a smear.
///
/// Drawn by hand rather than set in type. Each of the four strokes is a gentle
/// curve with its own weight and its own lean — the horizontals bow a little,
/// the verticals slant like a pen stroke, no two quite parallel — so the mark
/// reads as something sketched rather than stamped. Small inside its field,
/// with room around it, and in soft colours: a quiet periwinkle and a warm
/// paper white rather than a hard blue and a clinical one.
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

  /// Corner radius of the field. Rounder than a system squircle, which is
  /// most of what makes the mark read as soft at launcher sizes.
  static const corner = 0.26;

  /// The glyph's bounding box, inset from each edge. The hash spans a little
  /// over two fifths of the field: small enough to sit inside Android's
  /// adaptive-icon safe zone with room to spare, large enough to read at 16px.
  static const inset = 0.28;

  /// The field.
  static const fieldColor = 0xFF6480D8;

  /// The hash: a warm paper white.
  static const glyphColor = 0xFFFFF8EE;

  /// The four strokes, each a quadratic curve `(x1, y1, cx, cy, x2, y2, w)`
  /// in unit coordinates: start, control point, end, and stroke width.
  ///
  /// One list rather than two loops, so the painter and the rasteriser cannot
  /// disagree about which stroke goes where.
  static const strokes =
      <(double, double, double, double, double, double, double)>[
        // Horizontals, top then bottom. The top one rises very slightly and bows
        // up; the bottom one dips and bows down, so the two open away from each
        // other like a pen lifting off the page.
        (0.285, 0.418, 0.50, 0.392, 0.718, 0.404, 0.080),
        (0.280, 0.598, 0.50, 0.620, 0.712, 0.586, 0.074),
        // Verticals, top to bottom, leaning right the way the typed character
        // does, and curving a touch as a wrist would.
        (0.458, 0.282, 0.428, 0.50, 0.396, 0.716, 0.080),
        (0.628, 0.290, 0.590, 0.494, 0.566, 0.722, 0.072),
      ];

  /// How many straight pieces each curve is rasterised as. Enough that no
  /// facet shows at 1024px; the painter draws the true curve.
  static const curveSteps = 24;

  /// A point on stroke [s] at `t` in `[0, 1]`.
  static (double, double) pointOn(
    (double, double, double, double, double, double, double) s,
    double t,
  ) {
    final (x1, y1, cx, cy, x2, y2, _) = s;
    final u = 1 - t;
    return (
      u * u * x1 + 2 * u * t * cx + t * t * x2,
      u * u * y1 + 2 * u * t * cy + t * t * y2,
    );
  }
}
