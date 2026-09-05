/// favorite_flag.dart
///
/// The mark for "this one" — the control that puts a golfer on your shortlist.
///
/// A pin flag, not a heart and not a star: a heart is a social-app gesture
/// applied to a playing partner, and a star reads as a rating of the man (four
/// stars for Dave) and collides with the course ratings elsewhere in the app.
/// A planted pin is golf's own mark, with no sentiment in either direction.
///
/// Outline = not a favorite, filled = favorite, on a soft backing so the set
/// state is legible without reading the glyph shape.  The glyph is drawn rather
/// than pulled from Material because Material has no pin flag and the outline /
/// filled pair has to be the SAME shape; if the mark is ever changed it is one
/// swap, here, and the control, target and states stay as they are.
///
/// Design reference: handoff-select-players §3.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/halved_brand.dart';

/// Stroke colour of an unplanted flag — muted enough not to compete with the
/// checkbox at the other end of the row.
const _outlineInk = Color(0xFFA9B6AD);

/// Backing behind a planted flag.
const _plantedBacking = Color(0xFFEAF4EE);

class FavoriteFlag extends StatelessWidget {
  const FavoriteFlag({
    super.key,
    required this.isFavorite,
    required this.onPressed,
    required this.golferName,
  });

  final bool isFavorite;

  /// Called on tap.  The caller owns the optimistic write; this widget only
  /// reports the tap and never selects the row it sits in.
  final VoidCallback onPressed;

  /// Used for the tooltip and the semantics label, so the control says which
  /// golfer it belongs to rather than just "favorite".
  final String golferName;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isFavorite
          ? 'Remove $golferName from favorites'
          : 'Add $golferName to favorites',
      child: Semantics(
        toggled: isFavorite,
        button: true,
        label: '$golferName favorite',
        child: InkResponse(
          radius: 24,
          // A 44pt target, hard against the trailing edge and well clear of the
          // checkbox at the leading edge: adding a golfer to the round and
          // adding him to your shortlist can never be confused.
          onTap: () {
            // Planting one is worth a tick of feedback; pulling one is not —
            // that case carries an Undo toast instead.
            if (!isFavorite) HapticFeedback.lightImpact();
            onPressed();
          },
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isFavorite ? _plantedBacking : Colors.transparent,
              borderRadius: BorderRadius.circular(Halved.rChip),
            ),
            child: CustomPaint(
              size: const Size(21, 21),
              painter: PinFlagGlyph(
                color: isFavorite ? Halved.pine : _outlineInk,
                filled: isFavorite,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pin-flag glyph itself, authored on the design's 24 × 24 grid and scaled
/// to whatever size the caller paints it at.  Public so the filter chip can
/// draw the same mark at 13px that the row control draws at 21px — one glyph,
/// one place to change it.
class PinFlagGlyph extends CustomPainter {
  const PinFlagGlyph({
    required this.color,
    this.filled = false,
    this.strokeWidth = 1.9,
  });

  final Color color;

  /// Filled cloth (planted) versus outline only (not planted).
  final bool filled;

  /// In grid units, so it keeps its proportion at any size.
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // The pole.
    canvas.drawLine(Offset(7 * s, 3.5 * s), Offset(7 * s, 20.5 * s), stroke);

    // The cloth.
    final cloth = Path()
      ..moveTo(7 * s, 4.5 * s)
      ..lineTo(17 * s, 7.7 * s)
      ..lineTo(7 * s, 11 * s)
      ..close();
    if (filled) canvas.drawPath(cloth, Paint()..color = color);
    canvas.drawPath(cloth, stroke);
  }

  @override
  bool shouldRepaint(PinFlagGlyph old) =>
      old.filled != filled ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
