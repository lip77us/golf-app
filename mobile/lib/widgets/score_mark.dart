import 'package:flutter/material.dart';

import '../utils/golf_colors.dart';

/// A score digit with golf-scorecard notation, shared by the score-entry grid
/// and the leaderboard so a score reads the same everywhere:
///   under par → red digit inside a circle   (double circle for eagle or better)
///   par       → plain digit (default colour), no shape
///   over par  → digit inside a square        (double square for double-bogey+)
///
/// [diff] is the score (net or gross, per the caller's settings) minus par;
/// null means par is unknown → plain digit.  [baseStyle] sets the font; the
/// colour is applied on top (red for under par via [toParColor]).
Widget scoreMark({
  required String text,
  required int? diff,
  required TextStyle baseStyle,
  required ThemeData theme,
}) {
  final number = Text(text, style: baseStyle.copyWith(color: toParColor(diff)));
  if (diff == null || diff == 0) return number; // par / unknown → plain

  final under     = diff < 0;
  final mag       = diff.abs().clamp(1, 2);
  final markColor = under ? underParColor : theme.colorScheme.onSurface;

  Widget ring(double size) => Container(
        width: size,
        height: size,
        decoration: under
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: markColor, width: 1.3))
            : BoxDecoration(
                border: Border.all(color: markColor, width: 1.3),
                borderRadius: BorderRadius.circular(2)),
      );

  return Stack(
    alignment: Alignment.center,
    children: [
      ring(mag >= 2 ? 22 : 19),
      if (mag >= 2) ring(15),
      number,
    ],
  );
}
