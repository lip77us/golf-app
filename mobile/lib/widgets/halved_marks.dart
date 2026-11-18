/// Small Halved-style marks drawn with paths: the stats mark (three rising
/// bars on a deep pine tile, the tallest in mint with a pennant) and the flag
/// mark used by Find a course and the home-course bar.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

class StatsMark extends StatelessWidget {
  final double size;
  const StatsMark({super.key, this.size = 44});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: Halved.deepPine,
            borderRadius: BorderRadius.circular(size * 0.27)),
        child: CustomPaint(painter: _StatsPainter()),
      );
}

class _StatsPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final bar = w * 0.14;
    final base = h * 0.74;
    final xs = [w * 0.26, w * 0.5, w * 0.74];
    final tops = [h * 0.56, h * 0.44, h * 0.24];
    for (var i = 0; i < 3; i++) {
      final p = Paint()
        ..color = i == 2 ? Halved.brightMint : const Color(0xFF6FA894);
      c.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTRB(xs[i] - bar / 2, tops[i], xs[i] + bar / 2, base),
              Radius.circular(bar / 3)),
          p);
    }
    // The pennant on the tallest bar.
    final path = Path()
      ..moveTo(xs[2] + bar / 2, tops[2])
      ..lineTo(xs[2] + bar / 2 + w * 0.12, tops[2] + h * 0.05)
      ..lineTo(xs[2] + bar / 2, tops[2] + h * 0.10)
      ..close();
    c.drawPath(path, Paint()..color = Halved.cream);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class FlagMark extends StatelessWidget {
  final double size;
  const FlagMark({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0F6E56), Color(0xFF0B1F1A)]),
            borderRadius: BorderRadius.circular(size * 0.3)),
        child: CustomPaint(painter: _FlagPainter()),
      );
}

class _FlagPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    c.drawRect(Rect.fromLTRB(w * 0.40, h * 0.22, w * 0.45, h * 0.78),
        Paint()..color = Halved.cream);
    final path = Path()
      ..moveTo(w * 0.45, h * 0.22)
      ..lineTo(w * 0.72, h * 0.34)
      ..lineTo(w * 0.45, h * 0.46)
      ..close();
    c.drawPath(path, Paint()..color = Halved.brightMint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
