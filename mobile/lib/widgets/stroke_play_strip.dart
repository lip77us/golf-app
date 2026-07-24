/// widgets/stroke_play_strip.dart
/// ------------------------------
/// The horizontal per-player scorecard strip shown when you tap a row in the
/// Stroke Play leaderboard tab — hole numbers, par, and the gross score coloured
/// net/gross vs par (circle/square notation + stroke dots), with Out / In / Tot
/// (/ Net) subtotals.
///
/// Extracted from leaderboard_screen.dart's `_LowNetView._holeStrip` so the
/// Stroke Play *championship* view (tournament_leaderboard_screen.dart) can
/// render the exact same strip on expand instead of the old F9/B9 grid.

import 'package:flutter/material.dart';

import '../utils/golf_colors.dart';
import 'net_score_button.dart' show scoreCellWithDots;
import 'score_mark.dart';

/// One hole's cell: the gross digit coloured by NET (or gross) vs par with
/// circle/square scorecard notation. Net cap comes from `capped` (falls back to
/// `net`). No stroke dots here — the wrapping strip adds those.
Widget _scoreCell(ThemeData theme, Map h, bool showNet, TextStyle cellStyle) {
  final gross    = h['gross'] as int?;
  final par      = h['par'] as int?;
  final colourBy = showNet ? ((h['capped'] ?? h['net']) as int?) : gross;
  return scoreMark(
    text: gross == null ? '–' : '$gross',
    diff: (colourBy != null && par != null) ? colourBy - par : null,
    baseStyle: cellStyle.copyWith(fontWeight: FontWeight.w600),
    theme: theme,
  );
}

/// [holes] — each a map with `hole`, `par`, `gross`, `net` (and optionally
/// `capped`). [holesInPlay] renders unplayed holes as blanks (defaults to the
/// scored holes). [holePars] supplies pars for unplayed holes (else each hole's
/// own `par`). [netTotal] / [netToPar] feed the trailing Net subtotal.
Widget strokePlayHoleStrip(
  BuildContext context, {
  required List holes,
  List<int>? holesInPlay,
  Map<int, int>? holePars,
  Map<int, int>? holeStrokeIndex,
  bool showNet = true,
  int? netTotal,
  int? netToPar,
  /// Prospective full-round stroke allocation ({hole: strokes}). When supplied,
  /// the dots come from this (so they show on EVERY hole a player gets a shot,
  /// even before it's played) rather than being derived from gross − net.
  Map<int, int>? strokePlan,
}) {
  final theme = Theme.of(context);
  final hm = <int, Map>{};
  for (final h in holes) {
    final m = h as Map;
    final n = m['hole'] as int?;
    if (n != null) hm[n] = m;
  }
  // With a prospective plan + holes-in-play we can render the whole card even
  // before a single score is entered (all holes blank, dots on stroke holes);
  // only bail when there's genuinely nothing to show.
  final _canRenderEmpty =
      (strokePlan != null && strokePlan.isNotEmpty) ||
      (holesInPlay != null && holesInPlay.isNotEmpty);
  if (hm.isEmpty && !_canRenderEmpty) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Text('No scores yet.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }

  final pars = holePars ?? const <int, int>{};
  final inPlay = (holesInPlay == null || holesInPlay.isEmpty) ? null : holesInPlay;
  final renderHoles = (inPlay == null)
      ? (hm.keys.toList()..sort())
      : ([...inPlay]..sort());
  final front = renderHoles.where((n) => n <= 9).toList();
  final back  = renderHoles.where((n) => n > 9).toList();
  final showOut = front.isNotEmpty && front.every(hm.containsKey);
  final showIn  = back.isNotEmpty && back.every(hm.containsKey);
  final showTot = renderHoles.every(hm.containsKey);
  final sis = holeStrokeIndex ?? const <int, int>{};
  int parOf(int n) => (hm[n]?['par'] as int?) ?? pars[n] ?? 0;
  int siOf(int n) => (hm[n]?['stroke_index'] as int?) ?? sis[n] ?? 0;
  int grossSum(List<int> hs) =>
      hs.fold<int>(0, (s, n) => s + ((hm[n]?['gross'] as int?) ?? 0));
  int parSum(List<int> hs) => hs.fold<int>(0, (s, n) => s + parOf(n));

  const double holeW = 30, sumW = 34, headH = 20, parH = 17, scoreH = 32;
  const cellStyle = TextStyle(fontSize: 12);
  final headerStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold, color: theme.colorScheme.onSurfaceVariant);
  final parStyle = theme.textTheme.labelSmall
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
  final siStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 9, color: theme.colorScheme.onSurfaceVariant);
  // Crisp 1px cell separators (12A): right + bottom on every cell, closed on the
  // left/top by the block's own wrapping border.
  final line = BorderSide(color: theme.colorScheme.outlineVariant, width: 1);
  final cellBorder = Border(right: line, bottom: line);

  Widget headCell(String t, double w) => Container(
        width: w, height: headH, alignment: Alignment.center,
        decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest, border: cellBorder),
        child: Text(t, style: headerStyle),
      );
  Widget shadeCell(String t, double w, double h, TextStyle? st) => Container(
        width: w, height: h, alignment: Alignment.center,
        decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow, border: cellBorder),
        child: Text(t, style: st),
      );
  Widget scoreCell(int n) {
    final hole    = hm[n];
    final gross   = hole?['gross'] as int?;
    final net     = hole?['net'] as int?;
    // Prefer the prospective plan (shows a dot on every stroke hole up front);
    // fall back to gross − net for callers that don't supply a plan.
    final int strokes;
    if (strokePlan != null) {
      strokes = (strokePlan[n] ?? 0).clamp(0, 9);
    } else {
      final raw = (gross != null && net != null) ? gross - net : 0;
      strokes = raw < 0 ? 0 : (raw > 9 ? 9 : raw);
    }
    return Container(
      width: holeW, height: scoreH, alignment: Alignment.center,
      decoration: BoxDecoration(border: cellBorder),
      child: scoreCellWithDots(
        Center(
          child: gross == null
              ? const Text('–', style: cellStyle)
              : _scoreCell(theme, hole!, showNet, cellStyle),
        ),
        strokes,
        theme.colorScheme.primary,
      ),
    );
  }
  Widget sumCell(String t, double w, {Color? color}) => Container(
        width: w, height: scoreH, alignment: Alignment.center,
        decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow, border: cellBorder),
        child: Text(t,
            style: cellStyle.copyWith(fontWeight: FontWeight.bold, color: color)),
      );

  // One nine-hole block: Hole / Par / SI header rows + the score row, with the
  // given trailing subtotal cells appended (Out for the front; In·Tot·Net for
  // the back). Front 9 stacks above Back-9-plus-total (12A two-row scorecard).
  Widget block(List<int> holeNums, List<({String label, Widget cell})> tail) {
    return Container(
      // Close the left + top edges the per-cell right/bottom borders leave open.
      decoration: BoxDecoration(border: Border(top: line, left: line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          for (final n in holeNums) headCell('$n', holeW),
          for (final t in tail) headCell(t.label, sumW),
        ]),
        Row(children: [
          for (final n in holeNums)
            shadeCell('${parOf(n) > 0 ? parOf(n) : '-'}', holeW, parH, parStyle),
          for (final t in tail)
            shadeCell(t.label == 'Out' ? '${parSum(holeNums)}'
                      : t.label == 'In' ? '${parSum(holeNums)}'
                      : t.label == 'Tot' ? '${parSum(renderHoles)}'
                      : '', sumW, parH, parStyle),
        ]),
        Row(children: [
          for (final n in holeNums)
            shadeCell('${siOf(n) > 0 ? siOf(n) : '-'}', holeW, parH, siStyle),
          for (final _ in tail) shadeCell('', sumW, parH, siStyle),
        ]),
        Row(children: [
          for (final n in holeNums) scoreCell(n),
          for (final t in tail) t.cell,
        ]),
      ]),
    );
  }

  final frontTail = <({String label, Widget cell})>[
    if (showOut) (label: 'Out', cell: sumCell('${grossSum(front)}', sumW)),
  ];
  final backTail = <({String label, Widget cell})>[
    if (showIn) (label: 'In', cell: sumCell('${grossSum(back)}', sumW)),
    if (showTot) (label: 'Tot', cell: sumCell('${grossSum(renderHoles)}', sumW)),
    if (showTot && showNet)
      (label: 'Net',
       cell: sumCell('${netTotal ?? ''}', sumW, color: toParColor(netToPar))),
  ];

  return Container(
    color: theme.colorScheme.surface,
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (front.isNotEmpty)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal, child: block(front, frontTail)),
      if (back.isNotEmpty) ...[
        const SizedBox(height: 6),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal, child: block(back, backTail)),
      ],
    ]),
  );
}
