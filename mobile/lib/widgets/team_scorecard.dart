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

/// One line of a [TeamScorecard]: a golfer's ball, or the team's total.
class TeamScorecardRow {
  /// `Team`, or a golfer's surname.
  final String label;
  final Map<int, int> scores;
  /// `{hole: strokes received}` — the dots.
  final Map<int, int> strokes;
  /// Holes whose score COUNTED toward the team. On a shamble two of four do,
  /// and a board that does not mark them cannot answer whose scores made the
  /// total.
  final Set<int> counted;
  /// Draws italic — the phantom is a row everywhere, never a footnote.
  final bool italic;
  /// Bold, with a rule above: the team's line under the golfers'.
  final bool total;

  const TeamScorecardRow({
    required this.label,
    required this.scores,
    this.strokes = const {},
    this.counted = const {},
    this.italic = false,
    this.total = false,
  });
}

class TeamScorecard extends StatelessWidget {
  /// `{hole: par}` — also defines which holes exist.
  final Map<int, int> pars;
  /// `{hole: stroke index}`, optional; drawn as the Index row when present.
  final Map<int, int> strokeIndexes;
  /// One or more score lines. A scramble has one; a shamble has four balls
  /// and a team total.
  final List<TeamScorecardRow> rows;
  /// Highlighted, and tappable when [onTapHole] is given.
  final int? currentHole;
  final ValueChanged<int>? onTapHole;

  const TeamScorecard({
    super.key,
    required this.pars,
    required this.rows,
    this.strokeIndexes = const {},
    this.currentHole,
    this.onTapHole,
  });

  /// The common case: a single line.
  factory TeamScorecard.single({
    Key? key,
    required Map<int, int> pars,
    required Map<int, int> scores,
    required String label,
    Map<int, int> strokeIndexes = const {},
    Map<int, int> strokes = const {},
    int? currentHole,
    ValueChanged<int>? onTapHole,
  }) =>
      TeamScorecard(
        key: key,
        pars: pars,
        strokeIndexes: strokeIndexes,
        currentHole: currentHole,
        onTapHole: onTapHole,
        rows: [TeamScorecardRow(
            label: label, scores: scores, strokes: strokes)],
      );

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
      bool counted = false,
      bool faded = false,
      bool italic = false,
      int dots = 0,
      int? goTo,
      double width = _cellW,
    }) {
      final body = Container(
        width: width, height: _rowH,
        decoration: BoxDecoration(
          // A counting ball is tinted; the ones that did not count go pale,
          // so the two that made the total are readable at a glance.
          color: counted
              ? theme.colorScheme.primary.withValues(alpha: 0.16)
              : (current
                  ? theme.colorScheme.primary.withValues(alpha: 0.12)
                  : null),
        ),
        child: Stack(children: [
          Center(
            child: Text(text,
                style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: (bold || counted)
                        ? FontWeight.bold : FontWeight.w500,
                    fontStyle: italic ? FontStyle.italic : null,
                    color: faded
                        ? theme.colorScheme.onSurfaceVariant : null)),
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
          for (final r in rows)
            Container(
              decoration: r.total
                  ? BoxDecoration(
                      border: Border(top: BorderSide(
                          color: theme.colorScheme.outlineVariant)))
                  : null,
              child: Row(children: [
                labelCell(r.label, bold: r.total, italic: r.italic),
                for (final h in hs)
                  cell(r.scores[h]?.toString() ?? '',
                       current: h == currentHole,
                       counted: r.counted.contains(h),
                       faded  : r.scores[h] != null &&
                                r.counted.isNotEmpty &&
                                !r.counted.contains(h),
                       italic : r.italic,
                       bold   : r.total,
                       dots   : r.strokes[h] ?? 0,
                       goTo   : h),
                cell(hs.any((h) => r.scores[h] != null)
                        ? '${total(hs, r.scores)}' : '',
                     bold: true, width: _totalW),
              ]),
            ),
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
