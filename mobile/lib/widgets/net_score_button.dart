import 'package:flutter/material.dart';

/// A tappable score button that communicates a golf score's relationship to
/// NET par (par + the player's handicap strokes on the hole).
///
/// Visual encoding (netDiff = score - netPar):
///   netDiff <= -2  (net eagle or better)  green fill, 2 concentric circles
///   netDiff == -1  (net birdie)           green fill, 1 circle
///   netDiff ==  0  (net par)              white fill, no shape
///   netDiff ==  1  (net bogey)            red   fill, 1 square
///   netDiff >=  2  (net double or worse)  red   fill, 2 concentric squares
///
/// Selection is shown with a thicker primary-colored outer border so it
/// never hides the net-vs-par shape inside.
class NetScoreButton extends StatelessWidget {
  /// The score displayed on this button (1-based — never 0).
  final int score;

  /// Par for this hole.
  final int par;

  /// Handicap strokes this player receives on this hole.
  final int strokes;

  /// True if this button is the currently chosen score.
  final bool selected;

  /// Overall button size. Defaults to a compact 40x40.
  final double width;
  final double height;

  /// Optional tap callback. If null, the button is still rendered but
  /// the caller is expected to wrap it in its own gesture handler.
  final VoidCallback? onTap;

  const NetScoreButton({
    super.key,
    required this.score,
    required this.par,
    required this.strokes,
    required this.selected,
    this.width = 40,
    this.height = 40,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final netPar  = par + strokes;
    final netDiff = score - netPar;

    // Fill color driven purely by net diff.
    //   under par  -> green  (single shade)
    //   net par    -> white
    //   over par   -> red    (single shade)
    final Color fill;
    if (netDiff < 0) {
      fill = Colors.green.shade200;    // net birdie or better
    } else if (netDiff == 0) {
      fill = Colors.white;             // net par
    } else {
      fill = Colors.red.shade200;      // over net par
    }

    // Shape style driven by net diff.
    final _ShapeStyle shape;
    if (netDiff <= -2) {
      shape = _ShapeStyle.doubleCircle;
    } else if (netDiff == -1) {
      shape = _ShapeStyle.singleCircle;
    } else if (netDiff == 0) {
      shape = _ShapeStyle.none;
    } else if (netDiff == 1) {
      shape = _ShapeStyle.singleSquare;
    } else {
      shape = _ShapeStyle.doubleSquare;
    }

    final button = SizedBox(
      width: width,
      height: height,
      child: Container(
        // Outer wrapper hosts the selection border so it never interferes
        // with the inner circle/square decorations.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: selected
              ? Border.all(color: theme.colorScheme.primary, width: 2.5)
              : null,
        ),
        padding: const EdgeInsets.all(2),
        child: _decorated(shape, fill),
      ),
    );

    if (onTap == null) return button;
    return GestureDetector(onTap: onTap, child: button);
  }

  Widget _decorated(_ShapeStyle shape, Color fill) {
    const borderColor = Colors.black87;
    const lineWidth   = 1.2;

    final text = Text(
      '$score',
      style: const TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 16,
        color: Colors.black87,
      ),
    );

    switch (shape) {
      case _ShapeStyle.none:
        return Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: text,
        );

      case _ShapeStyle.singleCircle:
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
            border: Border.all(color: borderColor, width: lineWidth),
          ),
          alignment: Alignment.center,
          child: text,
        );

      case _ShapeStyle.doubleCircle:
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: lineWidth),
          ),
          padding: const EdgeInsets.all(2),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              border: Border.all(color: borderColor, width: lineWidth),
            ),
            alignment: Alignment.center,
            child: text,
          ),
        );

      case _ShapeStyle.singleSquare:
        return Container(
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: borderColor, width: lineWidth),
          ),
          alignment: Alignment.center,
          child: text,
        );

      case _ShapeStyle.doubleSquare:
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: lineWidth),
          ),
          padding: const EdgeInsets.all(2),
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: borderColor, width: lineWidth),
            ),
            alignment: Alignment.center,
            child: text,
          ),
        );
    }
  }
}

enum _ShapeStyle { none, singleCircle, doubleCircle, singleSquare, doubleSquare }
