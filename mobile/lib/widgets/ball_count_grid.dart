/// widgets/ball_count_grid.dart
/// ----------------------------
/// "How many balls count on which holes" — the shared control.
///
/// Two games ask this question: **Irish Rumble** (where the escalating count
/// is the whole character of the game) and the **Foursome Play shamble**
/// (docs/design-review/handoff-team-play/SPEC.md §4). They ask it with
/// different presets, because they are different games — but they must ask it
/// the SAME WAY, or a golfer who has set one has learned nothing about the
/// other.
///
/// So the presets stay with each game and the two surfaces below are shared:
///
///   * [BallCountPreview] — the run readback. *Holes 1–6, best 1 net.* It is
///     the check that catches a per-hole grid accidentally left at all 2s, or
///     a par-based setting on a course with five par 3s that turns out much
///     harder than intended.
///   * [BallCountGrid] — the 18-cell editor, tap to cycle 1→2→3→4. Tight
///     cycling beats a full picker when there are eighteen cells on screen.
///
/// Both are theme-driven rather than brand-scoped, so they render identically
/// wherever they land.
library;

import 'package:flutter/material.dart';

import 'section_card.dart';

/// Group a per-hole list into contiguous same-value runs, so the preview reads
/// back in sentences rather than eighteen lines.
List<({int start, int end, int balls})> collapseBallRuns(List<int> perHole) {
  final out = <({int start, int end, int balls})>[];
  if (perHole.isEmpty) return out;
  var segStart = 1;
  var curBalls = perHole[0];
  for (var i = 1; i < perHole.length; i++) {
    if (perHole[i] != curBalls) {
      out.add((start: segStart, end: i, balls: curBalls));
      segStart = i + 1;
      curBalls = perHole[i];
    }
  }
  out.add((start: segStart, end: perHole.length, balls: curBalls));
  return out;
}

/// The run readback, plus the totals that describe the round.
class BallCountPreview extends StatelessWidget {
  /// Resolved balls-to-count, hole 1 first.
  final List<int> perHole;
  final String    title;
  /// `per group` in Irish Rumble; empty on a shamble, where the card it sits
  /// under already says "Balls that count". Same rule, named for whoever is
  /// playing it.
  final String    subjectSuffix;
  /// Foursome Play reports `36 counted of 72 played`: the number that tells a
  /// TD more than any of the settings do. Fixed-at-2 and escalating both give
  /// 36, distributed differently, and seeing that is what makes the choice
  /// read as character rather than difficulty.
  final bool      showTotals;

  const BallCountPreview({
    super.key,
    required this.perHole,
    this.title = 'Segment Preview',
    this.subjectSuffix = 'per group',
    this.showTotals = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (perHole.isEmpty) return const SizedBox.shrink();

    final runs    = collapseBallRuns(perHole);
    final counted = perHole.fold<int>(0, (a, b) => a + b);
    final played  = perHole.length * 4;
    final avg     = counted / perHole.length;
    // Legal, and worth a word: a 4-ball hole has no drop score, so one blow-up
    // is the team's. Deliberate on a closing hole, an accident anywhere else.
    final allFour = [
      for (var i = 0; i < perHole.length; i++) if (perHole[i] >= 4) i + 1,
    ];

    return SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in runs)
            _RunRow(
              r.start == r.end ? 'Hole ${r.start}' : 'Holes ${r.start}–${r.end}',
              (r.balls == 1
                      ? 'Best 1 net $subjectSuffix'
                      : 'Best ${r.balls} nets $subjectSuffix')
                  .trimRight(),
            ),
          if (showTotals) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _Total(value: '$counted', label: 'BALLS COUNTED'),
                _Total(value: '$played',  label: 'BALLS PLAYED'),
                _Total(value: avg.toStringAsFixed(1), label: 'AVG PER HOLE'),
              ],
            ),
          ],
          if (allFour.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                     size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    allFour.length == 1
                        ? 'Hole ${allFour.first} counts all four — no drop '
                          'score, so one blow-up is the team\'s.'
                        : 'Holes ${allFour.join(', ')} count all four — no '
                          'drop score, so one blow-up is the team\'s.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The 18-cell editor. Tap a cell to cycle 1→2→3→4.
class BallCountGrid extends StatelessWidget {
  final List<int> holePars;
  final List<int> perHole;
  final void Function(int holeIndex, int value) onChanged;
  final String title;
  /// Read-only when the counts are locked — a hole already scored under
  /// "best 2" cannot be re-read as "best 1".
  final bool enabled;

  const BallCountGrid({
    super.key,
    required this.holePars,
    required this.perHole,
    required this.onChanged,
    this.title = 'Per-hole balls (tap to cycle 1→2→3→4)',
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final holes = perHole.length;

    Widget holeCell(int idx) {
      final hole = idx + 1;
      final par  = idx < holePars.length ? holePars[idx] : 4;
      final val  = perHole[idx];
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$hole',
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text('Par $par',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, fontSize: 10)),
            const SizedBox(height: 4),
            InkWell(
              onTap: enabled ? () => onChanged(idx, val >= 4 ? 1 : val + 1) : null,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 28, height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // All four is flagged here too — the cell a TD is looking at
                  // when he sets it, not only in the preview underneath.
                  color: val >= 4
                      ? theme.colorScheme.error
                      : (enabled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text('$val',
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      );
    }

    Widget nine(String label, int from, int to) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Row(children: [
              for (var i = from; i < to; i++) Expanded(child: holeCell(i)),
            ]),
          ],
        );

    return SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          nine('Front 9', 0, holes < 9 ? holes : 9),
          if (holes > 9) ...[
            const SizedBox(height: 10),
            nine('Back 9', 9, holes),
          ],
        ],
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  final String holes;
  final String rule;
  const _RunRow(this.holes, this.rule);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 100,
          child: Text(holes,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(rule,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

class _Total extends StatelessWidget {
  final String value;
  final String label;
  const _Total({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
