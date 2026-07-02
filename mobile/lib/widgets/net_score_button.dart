import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../utils/golf_colors.dart';

/// Wraps a score [box] (a NetScoreButton or an empty cell) and shows its
/// handicap stroke dots in a small strip ABOVE the box — the traditional
/// scorecard placement — so they never collide with the bogey / double-bogey
/// square that fills the cell.  The strip is always reserved (fixed height) so
/// rows stay aligned whether or not a player gets strokes on the hole.
Widget scoreCellWithDots(Widget box, int strokes, Color color) {
  final n = strokes.clamp(0, 2);
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 5,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < n; i++)
              Container(
                width: 5, height: 5,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
      const SizedBox(height: 2),
      box,
    ],
  );
}

/// A tappable score button using golf-scorecard notation.  When the user's Net
/// Style Entry preference is on (the default), the shape/colour are driven by
/// NET par (par + the player's strokes on the hole); when off, by GROSS par.
///
/// Visual encoding (diff = score - baseline):
///   under par → RED digit in a circle   (double circle for eagle or better)
///   par       → black digit, white box, no shape  (plain scorecard look)
///   over par  → black digit in a square  (double square for double-bogey+)
///
/// The colour is on the digit (and the circle/square outline), not a fill — the
/// background stays white.  Selection is a thicker primary-coloured outer border.
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
    final theme         = Theme.of(context);
    final netStyleEntry =
        context.watch<SettingsProvider>().netStyleEntry;
    final baseline      = netStyleEntry ? par + strokes : par;
    final diff          = score - baseline;

    // Shape style driven by diff (net or gross per the preference).
    final _ShapeStyle shape;
    if (diff <= -2) {
      shape = _ShapeStyle.doubleCircle;
    } else if (diff == -1) {
      shape = _ShapeStyle.singleCircle;
    } else if (diff == 0) {
      shape = _ShapeStyle.none;
    } else if (diff == 1) {
      shape = _ShapeStyle.singleSquare;
    } else {
      shape = _ShapeStyle.doubleSquare;
    }

    // Golf convention: under par = red, par/over = black.  Colour goes on the
    // digit + outline; the background stays white.
    final color = diff < 0 ? underParColor : Colors.black87;

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
        child: _decorated(shape, color),
      ),
    );

    if (onTap == null) return button;
    return GestureDetector(onTap: onTap, child: button);
  }

  Widget _decorated(_ShapeStyle shape, Color color) {
    const lineWidth = 1.3;
    const fill      = Colors.white;

    final text = Text(
      '$score',
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 16,
        color: color,
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
            border: Border.all(color: color, width: lineWidth),
          ),
          alignment: Alignment.center,
          child: text,
        );

      case _ShapeStyle.doubleCircle:
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: lineWidth),
          ),
          padding: const EdgeInsets.all(2),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              border: Border.all(color: color, width: lineWidth),
            ),
            alignment: Alignment.center,
            child: text,
          ),
        );

      case _ShapeStyle.singleSquare:
        return Container(
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: color, width: lineWidth),
          ),
          alignment: Alignment.center,
          child: text,
        );

      case _ShapeStyle.doubleSquare:
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: color, width: lineWidth),
          ),
          padding: const EdgeInsets.all(2),
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: color, width: lineWidth),
            ),
            alignment: Alignment.center,
            child: text,
          ),
        );
    }
  }
}

enum _ShapeStyle { none, singleCircle, doubleCircle, singleSquare, doubleSquare }
