/// The score box on a golfer's row (`handoff-score-entry-template`): 40 × 40,
/// drawn as the score it holds, **coded to NET par** (gross minus strokes), with
/// the golfer's stroke dots INSIDE it, top right.
///
/// | Net v par | Box |
/// | --- | --- |
/// | empty | white, 1.5 pine border, radius 10 |
/// | −2 or better | deep pine circle, a white ring and an outer deep ring |
/// | −1 | pine circle, white figure |
/// | 0 | `#BFDCC6` square, pine border |
/// | +1 | `#FDF6EF` square, `#D9A27A` border, brown figure |
/// | +2 or worse | `#FAEBDD`, a double `#D9A27A` border |
///
/// The dots used to sit in a strip BELOW the box because a bogey square covered
/// them; the template moves them inside and keeps them clear by position and by
/// colour — deep pine on a light box, mint on the dark circles, set in a little
/// further so they stay inside the circle.
///
/// Distinct from `ScoreNotation`, which draws the KEYPAD's keys as outlines: a
/// key is an option and a box is a result, so a birdie is a ring on the keypad
/// and a filled circle on the row.
library;

import 'package:flutter/material.dart';

import 'dashed_border.dart';

import '../theme/halved_brand.dart';
import 'forty_balls_keypad.dart' show ScoreShape, shapeForScore;

class ScoreBox extends StatelessWidget {
  /// The gross score, or null while nothing is entered.
  final int? score;
  final int par;

  /// Strokes the golfer gets on this hole: they move the baseline AND are
  /// drawn as dots. A gross game passes 0, so the shapes are gross.
  final int strokes;

  /// How many strokes move the SHAPE's baseline. Null means [strokes] — the
  /// template codes to net par. A golfer who has switched Net Style Entry off
  /// still sees his dots but gets shapes coded against bare par, so the dots and
  /// the baseline are separate questions.
  final int? shapeStrokes;

  /// This is the golfer whose score is being entered: a 2.5pt deep pine ring
  /// offset 2pt, drawn outside the box so it never moves the row.
  final bool active;

  /// The golfer was skipped on this hole and still owes a score
  /// (`handoff-score-entry-skip`): a dashed `#8FA79A` border.
  final bool skipped;

  static const double size = 40;

  const ScoreBox({
    super.key,
    required this.score,
    required this.par,
    this.strokes = 0,
    this.shapeStrokes,
    this.active = false,
    this.skipped = false,
  });

  @override
  Widget build(BuildContext context) {
    final shape =
        score == null
            ? null
            : shapeForScore(score!, par, strokes: shapeStrokes ?? strokes);
    final round = shape == ScoreShape.birdie || shape == ScoreShape.eagle;
    final radius = round ? size / 2 : (shape == null || shape == ScoreShape.par
        ? 10.0
        : 5.0);

    final (Color fill, Color line, Color ink) = switch (shape) {
      null => (Colors.white, Halved.pine, Halved.deepPine),
      ScoreShape.eagle => (Halved.deepPine, Halved.deepPine, Colors.white),
      ScoreShape.birdie => (Halved.pine, Halved.pine, Colors.white),
      ScoreShape.par => (const Color(0xFFBFDCC6), Halved.pine, Halved.deepPine),
      ScoreShape.bogey =>
        (const Color(0xFFFDF6EF), const Color(0xFFD9A27A), Halved.clayInk),
      ScoreShape.double =>
        (const Color(0xFFFAEBDD), const Color(0xFFD9A27A), const Color(0xFF7A3A06)),
    };

    final dotColour = round ? Halved.brightMint : Halved.deepPine;
    final dotInset = round ? const Offset(7, 6) : const Offset(4, 4);

    Widget face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: skipped ? null : Border.all(color: line, width: 1.5),
      ),
      foregroundDecoration: null,
      child: shape == ScoreShape.double
          // CSS's `4px double`: a line, a gap, a line.
          ? Container(
              margin: const EdgeInsets.all(1.5),
              width: size - 3 - 3,
              height: size - 3 - 3,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: line, width: 1.2),
              ),
              child: _figure(score, ink),
            )
          : _figure(score, ink),
    );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        // The eagle's second ring: a white one, then a deep one outside it.
        // Drawn as circles rather than a box shadow, which paints a rounded
        // SQUARE once the spread is added to a radius this large.
        if (shape == ScoreShape.eagle) ...[
          Positioned(
            left: -3.5, top: -3.5, right: -3.5, bottom: -3.5,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: Halved.deepPine),
            ),
          ),
          Positioned(
            left: -2, top: -2, right: -2, bottom: -2,
            child: const DecoratedBox(
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: Colors.white),
            ),
          ),
        ],
        face,
        if (skipped)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: DashedRRect(
                    color: const Color(0xFF8FA79A), width: 1.5, radius: radius),
              ),
            ),
          ),
        if (strokes > 0)
          Positioned(
            top: dotInset.dy,
            right: dotInset.dx,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < strokes; i++)
                Container(
                  width: 5,
                  height: 5,
                  margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
                  decoration:
                      BoxDecoration(color: dotColour, shape: BoxShape.circle),
                ),
            ]),
          ),
        if (active)
          Positioned(
            left: -4.5,
            top: -4.5,
            right: -4.5,
            bottom: -4.5,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius + 4.5),
                  border: Border.all(color: Halved.deepPine, width: 2.5),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  static Widget _figure(int? score, Color ink) => score == null
      ? const SizedBox.shrink()
      : Text('$score',
          style: Halved.body(color: ink, weight: FontWeight.w700)
              .copyWith(fontSize: 18, height: 1));
}
