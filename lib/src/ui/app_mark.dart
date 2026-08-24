import 'package:flutter/material.dart';

import 'mark_spec.dart';

/// The app's mark, drawn at any size.
///
/// Painted rather than shipped as an asset. It is four strokes on a rounded
/// square, so a rasterised copy would only be a second version of
/// [MarkSpec] to keep in step — and one that goes soft at whatever size the
/// asset was not exported for.
class AppMark extends StatelessWidget {
  const AppMark({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: _MarkPainter()),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final origin = Offset((size.width - side) / 2, (size.height - side) / 2);
    Offset at(double x, double y) => origin + Offset(x * side, y * side);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        origin & Size.square(side),
        Radius.circular(MarkSpec.corner * side),
      ),
      Paint()..color = const Color(MarkSpec.fieldColor),
    );

    final ink = Paint()
      ..color = const Color(MarkSpec.glyphColor)
      ..strokeWidth = MarkSpec.stroke * side
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (final (x1, y1, x2, y2) in MarkSpec.strokes) {
      canvas.drawLine(at(x1, y1), at(x2, y2), ink);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}
