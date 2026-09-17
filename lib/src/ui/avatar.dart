import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import '../model/people.dart';

/// A person's picture, at [size]: the photo they were given, or a pixel
/// pattern grown from a seed, or nothing at all.
///
/// Nothing rather than a default: an avatar for everyone would make the
/// scrollback a wall of circles, and the point of a picture is that it marks
/// the few people the user chose to mark.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.card, this.size = 18});

  final PersonCard? card;
  final double size;

  @override
  Widget build(BuildContext context) {
    final card = this.card;
    if (card == null || !card.hasPicture) return const SizedBox.shrink();
    final Widget picture = card.avatar != null
        ? Image.memory(
            card.avatar!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          )
        : CustomPaint(
            size: Size.square(size),
            painter: PixelAvatarPainter(card.pixelSeed!),
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: SizedBox(width: size, height: size, child: picture),
    );
  }
}

/// A 5×5 pattern mirrored down the middle, in two colours drawn from the
/// seed. The shape everyone recognises from the internet's identicons, chosen
/// because being recognisable at 18 pixels is the whole job.
class PixelAvatarPainter extends CustomPainter {
  PixelAvatarPainter(this.seed);

  final int seed;

  /// A fresh seed for the "random" button.
  static int roll() => math.Random().nextInt(1 << 31);

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final hue = random.nextDouble() * 360;
    final fore = HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor();
    final back = HSLColor.fromAHSL(1, hue, 0.35, 0.18).toColor();
    canvas.drawRect(Offset.zero & size, Paint()..color = back);

    final cell = size.width / 5;
    final paint = Paint()..color = fore;
    for (var y = 0; y < 5; y++) {
      // Three columns decided, the other two mirrored: symmetry is what
      // makes a random blob read as a face rather than as noise.
      for (var x = 0; x < 3; x++) {
        if (!random.nextBool()) continue;
        for (final column in {x, 4 - x}) {
          canvas.drawRect(
            Rect.fromLTWH(column * cell, y * cell, cell, cell),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(PixelAvatarPainter old) => old.seed != seed;
}

/// Shrink a picked image to a small square PNG, for storing beside a nick.
///
/// Sixty-four pixels is more than any place the picture is drawn, and a
/// photo straight off a phone is megabytes that would be read back on every
/// render of every message from that person. Cropped to the centre square
/// so faces stay where they are; a portrait made into a circle by squashing
/// is nobody's face.
Future<ui.Image> _decodeSquare(Uint8List bytes, int side) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final source = frame.image;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final crop = math.min(source.width, source.height).toDouble();
  final from = Rect.fromLTWH(
    (source.width - crop) / 2,
    (source.height - crop) / 2,
    crop,
    crop,
  );
  canvas.drawImageRect(
    source,
    from,
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..filterQuality = FilterQuality.high,
  );
  source.dispose();
  return recorder.endRecording().toImage(side, side);
}

/// The PNG bytes of [bytes] shrunk to a 64-pixel square, or null if it was
/// not an image this platform can decode.
Future<Uint8List?> shrinkAvatar(Uint8List bytes, {int side = 64}) async {
  try {
    final image = await _decodeSquare(bytes, side);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
