/// widgets/stroke_dots.dart
///
/// Handicap stroke dots — one dot per stroke, everywhere strokes are drawn.
///
/// **There is no cap.** A golfer getting three strokes gets three dots. The
/// old `strokes.clamp(0, 2)` silently misreported a real state: the row said
/// two and the golfer had three, on nine surfaces at once. It was never a
/// layout constraint on the score box, which has room for four; it was a cap
/// put in for the 32px scorecard cell and then applied everywhere.
///
/// **Two treatments, because the two surfaces are genuinely different sizes.**
/// Do not unify them — a 40×36 score box and a 32×26 grid cell want different
/// answers and were given different ones on purpose
/// (`~/Downloads/handoff-app-fixes/stroke-dots.html`, option B):
///
/// * [StrokeDotRow] — the score box. Horizontal, pinned top-right, unchanged
///   from what shipped. Three dots cost 15px of 40 and clear the digit easily.
/// * [StrokeDotColumn] — the scorecard grid. The SAME dot rotated ninety
///   degrees into a column down the right edge. Three dots then cost **7px of
///   the cell's width instead of 14** — a 4px column inset 3px — so the dots
///   cannot reach the centred digit at three strokes or at four. Horizontally
///   they overlapped the number by about 6px at three, which is why the cap
///   existed.
///
/// **The column is anchored at the TOP right, not centred.** The first dot
/// therefore sits exactly where a single stroke has always sat — the corner —
/// and the column only grows downward when there is a second and a third. That
/// matters because the common case is one stroke: centring it moved the
/// familiar corner dot for every ordinary hole in order to accommodate a
/// three-stroke case that, in strokes-off, is extreme. One stroke now looks
/// identical in the grid and in the score box.
///
/// * [StrokeDotCap] — the Sixes entry card, where the box is a `ScoreNotation`
///   that can be FILLED deep pine (a net birdie) or outlined. A 4px dot inside
///   the corner disappears against the filled state, so this one straddles the
///   top edge in bright mint with a deep-pine ring — readable on either fill,
///   and outside the box rather than competing with the digit
///   (`handoff-sixes-score-entry` §1: "stroke dots sit on top of the box").
///
/// Dot size, gap and colour are identical in the first two. Only the axis
/// differs, which is what keeps it one vocabulary rather than two marks
/// meaning the same thing. The cap is a third because its surface is a third
/// thing — but it lives HERE, so a change to how a stroke is drawn is still
/// one file.
library;

import 'package:flutter/material.dart';

/// Dot geometry, in one place so the two axes cannot drift apart.
const double kStrokeDot = 4.0;
const double kStrokeDotGap = 1.0;

/// The score box: a horizontal run in the top-right corner.
///
/// Returns a `Positioned`, so it belongs directly inside a `Stack`.
class StrokeDotRow extends StatelessWidget {
  final int strokes;
  final Color color;
  final double top;
  final double right;

  const StrokeDotRow({
    super.key,
    required this.strokes,
    required this.color,
    this.top = 2,
    this.right = 2,
  });

  @override
  Widget build(BuildContext context) {
    if (strokes <= 0) return const SizedBox.shrink();
    return Positioned(
      top: top,
      right: right,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < strokes; i++)
            Container(
              width: kStrokeDot,
              height: kStrokeDot,
              margin: const EdgeInsets.only(left: kStrokeDotGap),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}

/// The scorecard grid: a vertical column growing down from the top-right.
///
/// Returns a `Positioned`, so it belongs directly inside a `Stack`.
class StrokeDotColumn extends StatelessWidget {
  final int strokes;
  final Color color;

  /// Distance from the cell's right edge. The design's number is 3; the
  /// fallback if a future cell is too narrow is to move the column to the
  /// LEFT edge, which carries nothing, rather than to shrink the dot — a 3px
  /// dot reads as a speck and would make the grid disagree with the score box
  /// about how big a stroke is.
  final double inset;

  /// Distance from the cell's top. Matches [StrokeDotRow]'s, so a single
  /// stroke lands in the same place on both surfaces.
  final double top;

  const StrokeDotColumn({
    super.key,
    required this.strokes,
    required this.color,
    this.inset = 3,
    this.top = 2,
  });

  @override
  Widget build(BuildContext context) {
    if (strokes <= 0) return const SizedBox.shrink();
    return Positioned(
      top: top,
      right: inset,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < strokes; i++)
            Container(
              width: kStrokeDot,
              height: kStrokeDot,
              // No gap above the FIRST dot — it has to land in the corner,
              // where a single stroke has always been drawn.
              margin: EdgeInsets.only(top: i == 0 ? 0 : kStrokeDotGap),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}


/// Dots straddling the TOP EDGE of a score box, centred — the Sixes card.
///
/// Returns a `Positioned`, so it belongs directly inside a `Stack` whose
/// `clipBehavior` is `Clip.none`: half the dot sits outside the box.
class StrokeDotCap extends StatelessWidget {
  final int strokes;

  /// Fill and ring. The ring is what keeps the dot visible when the box
  /// underneath is filled in the same family of greens.
  final Color color;
  final Color ring;
  final double size;

  const StrokeDotCap({
    super.key,
    required this.strokes,
    this.color = const Color(0xFF3BD89A),
    this.ring = const Color(0xFF0B1F1A),
    this.size = 9,
  });

  @override
  Widget build(BuildContext context) {
    if (strokes <= 0) return const SizedBox.shrink();
    return Positioned(
      top: -size / 2,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < strokes; i++) ...[
            if (i > 0) SizedBox(width: size * 0.4),
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
