/// widgets/team_scorecard.dart
/// --------------------------
/// The by-hole scorecard for Foursome Play — one widget, drawn the same under
/// score entry and inside an expanded leaderboard row.
///
/// It follows the banded format every other scorecard in the app uses: hole
/// numbers on `surfaceContainerHighest`, par and index a step lighter on
/// `surfaceContainerLow`, scores plain underneath. The bands do real work
/// outdoors — they separate the fixed course information from the scores
/// without adding a single word — and every scorecard reading as the same
/// object is the point.
///
/// Stroke dots sit in the **top-right corner** of a cell, 4pt, at most two,
/// matching the leaderboard's own cells. Centred over the digit they collide
/// with it, which is exactly what they do nowhere else in the app.
library;

import 'package:flutter/material.dart';

class TeamScorecard extends StatelessWidget {
  /// `{hole: par}` — also defines which holes exist.
  final Map<int, int> pars;
  /// `{hole: stroke index}`, optional; drawn as the Index row when present.
  final Map<int, int> strokeIndexes;
  /// `{hole: gross}` for the row being drawn.
  final Map<int, int> scores;
  /// `{hole: strokes received}` — the dots.
  final Map<int, int> strokes;
  /// The row's label: `Team`, or a golfer's surname on a shamble.
  final String label;
  /// Highlighted, and tappable when [onTapHole] is given.
  final int? currentHole;
  final ValueChanged<int>? onTapHole;

  const TeamScorecard({
    super.key,
    required this.pars,
    required this.scores,
    required this.label,
    this.strokeIndexes = const {},
    this.strokes = const {},
    this.currentHole,
    this.onTapHole,
  });

  static const double _labelW = 54;
  static const double _cellW  = 30;
  static const double _totalW = 38;
  static const double _rowH   = 26;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (pars.isEmpty) return const SizedBox.shrink();

    final holes = pars.keys.toList()..sort();
    final front = holes.where((h) => h <= 9).toList();
    final back  = holes.where((h) => h > 9).toList();

    int total(Iterable<int> hs, Map<int, int> from) =>
        hs.map((h) => from[h] ?? 0).fold(0, (a, b) => a + b);
    bool anyScored(Iterable<int> hs) => hs.any((h) => scores[h] != null);

    Widget band(Widget child, Color? colour) =>
        Container(color: colour, child: child);

    Widget labelCell(String text, {bool bold = false, bool italic = false}) =>
        SizedBox(
          width: _labelW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(text,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: bold ? FontWeight.bold : null,
                    fontStyle: italic ? FontStyle.italic : null,
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
          ),
        );

    Widget cell(String text, {
      bool bold = false,
      bool current = false,
      int dots = 0,
      int? goTo,
      double width = _cellW,
    }) {
      final body = Container(
        width: width, height: _rowH,
        decoration: BoxDecoration(
          color: current
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : null,
        ),
        child: Stack(children: [
          Center(
            child: Text(text,
                style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: bold ? FontWeight.bold : FontWeight.w500)),
          ),
          if (dots > 0)
            Positioned(
              // Top-right, clear of the digit — the leaderboard's own
              // placement, so the two cards read identically.
              top: 2, right: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  dots.clamp(0, 2),
                  (i) => Container(
                    width: 4, height: 4,
                    margin: const EdgeInsets.only(left: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
      return goTo == null || onTapHole == null
          ? body
          : InkWell(onTap: () => onTapHole!(goTo), child: body);
    }

    Widget nine(List<int> hs, String totalLabel) {
      if (hs.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          band(
            Row(children: [
              labelCell('Hole', bold: true),
              for (final h in hs)
                cell('$h',
                     bold: true, goTo: h, current: h == currentHole),
              cell(totalLabel, bold: true, width: _totalW),
            ]),
            theme.colorScheme.surfaceContainerHighest,
          ),
          band(
            Row(children: [
              labelCell('Par', italic: true),
              for (final h in hs) cell('${pars[h]}'),
              cell('${total(hs, pars)}', bold: true, width: _totalW),
            ]),
            theme.colorScheme.surfaceContainerLow,
          ),
          if (strokeIndexes.isNotEmpty)
            band(
              Row(children: [
                labelCell('Index'),
                for (final h in hs) cell('${strokeIndexes[h] ?? ''}'),
                cell('', width: _totalW),
              ]),
              theme.colorScheme.surfaceContainerLow,
            ),
          Row(children: [
            labelCell(label, bold: true),
            for (final h in hs)
              cell(scores[h]?.toString() ?? '',
                   current: h == currentHole,
                   dots: strokes[h] ?? 0,
                   goTo: h),
            cell(anyScored(hs) ? '${total(hs, scores)}' : '',
                 bold: true, width: _totalW),
          ]),
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          nine(front, 'OUT'),
          if (back.isNotEmpty) ...[
            const SizedBox(height: 8),
            nine(back, 'IN'),
          ],
        ],
      ),
    );
  }
}
