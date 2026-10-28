import 'package:flutter/material.dart';

/// A dashed rounded rectangle, for anything drawn as **not yet there**.
///
/// Flutter's `Border` has no dash, and the distinction carries meaning on
/// these boards: a solid outline is an empty thing that exists, a dashed one
/// is a thing that has not happened. A Nassau nine that has not started and
/// a skins hole that carried are both that, so they share one painter —
/// otherwise they drift to different dash lengths and stop reading as one
/// treatment (Design, 28 Oct 2026).
class DashedRRect extends CustomPainter {
  const DashedRRect({
    required this.color,
    this.width = 1.5,
    this.radius = 6,
  });

  final Color color;
  final double width;
  final double radius;

  /// One dash length everywhere, for the reason above.
  static const double dash = 4;
  static const double gap = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(DashedRRect old) =>
      old.color != color || old.width != width || old.radius != radius;
}
