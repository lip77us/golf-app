/// widgets/stroke_play_progress_grid.dart
/// --------------------------------------
/// The gross card under the hole being entered — hole, par, then a row per
/// golfer with his score and his stroke dots, closed by OUT / IN / TOT.
///
/// **Extracted from `score_entry_screen.dart`, where it was private.** It is
/// the card a tournament round draws under the hole (stroke or Stableford), and
/// Pink Ball — a stroke-play tournament with a carried ball on top — had no
/// card at all: the one screen in the app where a golfer could not see what his
/// group had shot. Copying it would have made a second card that reads the same
/// scorecard and could disagree with the first about a stroke.
///
/// `GridPlayerRow` comes with it because the grid is built out of it, and
/// because Nassau's own grid in score entry draws the same row — one row shared
/// by three cards is the point.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../utils/stroke_play_standing.dart';
import 'pinned_hole_grid.dart';
import 'score_mark.dart';
import 'stroke_dots.dart';

// ---------------------------------------------------------------------------
// Stroke Play (low_net_round) per-hole grid — modelled on _NassauProgressGrid
// but without team tinting or a winner row.  Shows hole #, par, then per-
// player gross scores with stroke-dot indicators in the corner so the user
// can see both the raw score and the strokes used to compute net.
// ---------------------------------------------------------------------------

class StrokePlayProgressGrid extends StatefulWidget {
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int hole)? onTapHole;
  final String           handicapMode;   // 'net' | 'gross' | 'strokes_off'
  final int              netPercent;
  final List<int>        holesInPlay;     // play order; empty = full 1-18

  const StrokePlayProgressGrid({
    super.key,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
    required this.handicapMode,
    required this.netPercent,
    this.holesInPlay = const [],
  });

  @override
  State<StrokePlayProgressGrid> createState() =>
      StrokePlayProgressGridState();
}

class StrokePlayProgressGridState extends State<StrokePlayProgressGrid> {
  static const double _labelColW = 56.0;
  static const double _cellW     = 34.0;
  static const double _rowH      = 28.0;

  // The controller, the pin and the scroll target live in PinnedHoleGrid.
  // This grid interleaves OUT / IN / TOT among the holes, so it hands over an
  // explicit right edge rather than a column index — a back-nine hole sits one
  // summary column further right than its position suggests.

  /// Strokes this player gets on hole [h] under the active handicap mode.
  ///
  /// Moved to `utils/stroke_play_standing.dart` so the standing row reports
  /// the net these dots produce. Two implementations would eventually disagree
  /// about a golfer's score on the one screen showing both.
  int _strokesOnHoleFor(Membership m, int h) => strokePlayStrokesOnHole(
        m, h,
        scorecard:    widget.scorecard,
        players:      widget.players,
        handicapMode: widget.handicapMode,
        netPercent:   widget.netPercent,
        holesInPlay:  widget.holesInPlay,
      );

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final players     = widget.players;
    final scorecard   = widget.scorecard;
    final currentHole = widget.currentHole;
    final onTapHole   = widget.onTapHole;
    // Only the holes actually in play (play order, wraparound) — a back-9 /
    // partial round shows just those columns, not a blank 1-9.
    final holeRange   = widget.holesInPlay.isNotEmpty
        ? widget.holesInPlay
        : List.generate(18, (i) => i + 1);

    // Nine-based gross totals, matching the leaderboard. OUT/IN show for a nine
    // that's in play; TOT only when BOTH nines are (a full round) — on a single
    // nine its OUT/IN already IS the round total, so a separate TOT is noise.
    final front    = holeRange.where((h) => h <= 9).toList();
    final back     = holeRange.where((h) => h > 9).toList();
    final showOut  = front.isNotEmpty;
    final showIn   = back.isNotEmpty;
    final showTot  = front.isNotEmpty && back.isNotEmpty;
    const summaryW = 34.0;

    int parSum(List<int> holes) {
      var t = 0;
      for (final h in holes) t += scorecard.holeData(h)?.par ?? 0;
      return t;
    }

    Widget headSummary(String label) => SizedBox(
          width: summaryW, height: _rowH,
          child: Center(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        );
    Widget parSummary(List<int> holes) => SizedBox(
          width: summaryW, height: _rowH,
          child: Center(
            child: Text('${parSum(holes)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
        );

    Widget holeCell(int h, {required Widget child, Color? bg}) {
      final isCurrent = h == currentHole;
      return GestureDetector(
        onTap: onTapHole == null ? null : () => onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? (isCurrent
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
                : null),
            border: isCurrent
                ? Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
                    width: 1.2)
                : null,
          ),
          child: child,
        ),
      );
    }

    String _modeLabel() {
      switch (widget.handicapMode) {
        case 'gross':       return 'Gross';
        case 'strokes_off': return 'SO ${widget.netPercent}%';
        default:            return 'Net ${widget.netPercent}%';
      }
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('Stroke play progress',
                  style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
              const Spacer(),
              Text(_modeLabel(),
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 4),
            Builder(builder: (ctx) {
              Widget lbl(String text, TextStyle? style) => SizedBox(
                    width: _labelColW, height: _rowH,
                    child: Align(alignment: Alignment.centerLeft,
                        child: Text(text, style: style)),
                  );
              final nSummary = (showOut ? 1 : 0) +
                  (showIn ? 1 : 0) + (showTot ? 1 : 0);
              // The current hole's right edge, counting the summary columns
              // that sit before it.
              double? edge;
              final fi = front.indexOf(currentHole);
              final bi = back.indexOf(currentHole);
              if (fi >= 0) {
                edge = (fi + 1) * _cellW;
              } else if (bi >= 0) {
                edge = front.length * _cellW +
                    (showOut ? summaryW : 0) + (bi + 1) * _cellW;
              }
              return PinnedHoleGrid(
                labelWidth  : _labelColW,
                cellWidth   : _cellW,
                holeCount   : holeRange.length,
                currentIndex: edge == null ? -1 : 0,
                currentRightEdge: edge,
                contentWidth: _cellW * holeRange.length + summaryW * nSummary,
                bands: [
                  // Hole numbers
                  HoleGridBand(
                    lbl('Hole', const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold)),
                    [
                    for (final h in front)
                      holeCell(h,
                          child: Text('$h',
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold))),
                    if (showOut) headSummary('OUT'),
                    for (final h in back)
                      holeCell(h,
                          child: Text('$h',
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold))),
                    if (showIn) headSummary('IN'),
                    if (showTot) headSummary('TOT'),
                  ]),
                  // Par row
                  HoleGridBand(
                    lbl('Par', theme.textTheme.bodySmall
                        ?.copyWith(fontStyle: FontStyle.italic)),
                    [
                    for (final h in front)
                      holeCell(h,
                          child: Text(
                            '${scorecard.holeData(h)?.par ?? "-"}',
                            style: theme.textTheme.bodySmall,
                          )),
                    if (showOut) parSummary(front),
                    for (final h in back)
                      holeCell(h,
                          child: Text(
                            '${scorecard.holeData(h)?.par ?? "-"}',
                            style: theme.textTheme.bodySmall,
                          )),
                    if (showIn) parSummary(back),
                    if (showTot) parSummary([...front, ...back]),
                  ]),
                  const HoleGridBand.rule(),
                  // Per-player gross scores with stroke-dot indicators + the
                  // OUT / IN / TOT gross totals (matching the leaderboard).
                  for (final m in players)
                    GridPlayerRow(
                      member:        m,
                      scorecard:     scorecard,
                      holeRange:     holeRange,
                      currentHole:   currentHole,
                      onTapHole:     onTapHole,
                      labelColW:     _labelColW,
                      cellW:         _cellW,
                      rowH:          _rowH,
                      strokesOnHole: (h) => _strokesOnHoleFor(m, h),
                      scoreMarks:    true,
                      frontHoles:    front,
                      backHoles:     back,
                      showOut:       showOut,
                      showIn:        showIn,
                      showTot:       showTot,
                      summaryW:      summaryW,
                    ).toBand(ctx),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// Shared player score row for the summary grid.
class GridPlayerRow extends StatelessWidget {
  final Membership   member;
  final Scorecard    scorecard;
  final List<int>    holeRange;
  final int          currentHole;
  final void Function(int hole)? onTapHole;
  final double       labelColW;
  final double       cellW;
  final double       rowH;
  final int Function(int hole) strokesOnHole;

  /// Optional override color for the player name label.
  /// Used by Nassau to tint names with their team color (blue / red).
  final Color?       nameColor;

  /// When true, colour each digit by net/gross vs par and add circle/square
  /// scorecard notation.  Off by default (e.g. Nassau keeps plain digits).
  final bool         scoreMarks;

  /// Gross-total columns (OUT / IN / TOT), mirroring the leaderboard. When all
  /// three flags are false (the default), the row renders the flat [holeRange]
  /// with no totals — the historic Nassau behaviour. When enabled, [frontHoles]
  /// (≤9) and [backHoles] (>9) drive the two nine subtotals; a subtotal shows
  /// only once every hole in that nine is scored.
  final List<int>    frontHoles;
  final List<int>    backHoles;
  final bool         showOut;
  final bool         showIn;
  final bool         showTot;
  final double       summaryW;

  const GridPlayerRow({
    super.key,
    required this.member,
    required this.scorecard,
    required this.holeRange,
    required this.currentHole,
    required this.onTapHole,
    required this.labelColW,
    required this.cellW,
    required this.rowH,
    required this.strokesOnHole,
    this.nameColor,
    this.scoreMarks = false,
    this.frontHoles = const [],
    this.backHoles  = const [],
    this.showOut    = false,
    this.showIn     = false,
    this.showTot    = false,
    this.summaryW   = 34.0,
  });

  @override
  Widget build(BuildContext context) {
    final b = toBand(context);
    return Row(children: [b.label!, ...b.cells!]);
  }

  /// The row split into its pinned half and its scrolling half.
  ///
  /// The name and the cells are handed over separately now that the label
  /// column does not scroll — a finished `Row` cannot be taken apart
  /// afterwards without introspecting widgets, which is the kind of clever
  /// that breaks silently. `build` composes them back for any caller that
  /// still wants one row.
  HoleGridBand toBand(BuildContext context) {
    final theme = Theme.of(context);

    // Gross total over a set of holes — null (shows '—') until every hole in
    // the set is scored, so a subtotal only appears once its nine is complete.
    int? grossSum(List<int> holes) {
      var total = 0;
      for (final h in holes) {
        final g = scorecard.holeData(h)?.scoreFor(member.player.id)?.grossScore;
        if (g == null) return null;
        total += g;
      }
      return total;
    }

    Widget summaryCell(int? val) => SizedBox(
          width: summaryW, height: rowH,
          child: Center(
            child: Text(val == null ? '—' : '$val',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
        );

    Widget nameCell() => SizedBox(
          width: labelColW, height: rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(member.player.displayShort,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600, color: nameColor)),
          ),
        );

    Widget holeCellWidget(int h) => GestureDetector(
          onTap: onTapHole == null ? null : () => onTapHole!(h),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: cellW, height: rowH,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: h == currentHole
                  ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                  : null,
              border: h == currentHole
                  ? Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.6),
                      width: 1.2)
                  : null,
            ),
            child: Stack(children: [
              Center(
                child: Builder(builder: (_) {
                  final hd = scorecard.holeData(h);
                  final gross = hd?.scoreFor(member.player.id)?.grossScore;
                  final baseStyle = theme.textTheme.bodySmall!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: gross == null
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  );
                  if (gross == null) return Text('–', style: baseStyle);
                  if (!scoreMarks) return Text('$gross', style: baseStyle);
                  // Colour + circle/square by net (or gross) vs par.  Strokes
                  // are 0 in gross mode, so this handles both settings.
                  final par = hd?.par;
                  final diff =
                      par == null ? null : (gross - strokesOnHole(h)) - par;
                  return scoreMark(
                      text: '$gross',
                      diff: diff,
                      baseStyle: baseStyle,
                      theme: theme);
                }),
              ),
              Builder(builder: (_) => StrokeDotColumn(
                    strokes: strokesOnHole(h),
                    color: theme.colorScheme.primary,
                  )),
            ]),
          ),
        );

    // No totals requested → the historic flat row (Nassau).
    if (!showOut && !showIn && !showTot) {
      return HoleGridBand(
        nameCell(),
        [for (final h in holeRange) holeCellWidget(h)],
      );
    }
    // Totals: front nine, OUT, back nine, IN, TOT — mirroring the leaderboard.
    return HoleGridBand(nameCell(), [
      for (final h in frontHoles) holeCellWidget(h),
      if (showOut) summaryCell(grossSum(frontHoles)),
      for (final h in backHoles) holeCellWidget(h),
      if (showIn) summaryCell(grossSum(backHoles)),
      if (showTot) summaryCell(grossSum([...frontHoles, ...backHoles])),
    ]);
  }
}
