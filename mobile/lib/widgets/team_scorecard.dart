/// widgets/team_scorecard.dart
/// --------------------------
/// The by-hole scorecard for Foursome Play — one widget, drawn the same under
/// score entry and inside an expanded leaderboard row.
///
/// **One strip of eighteen, scrolled to the hole being played** — the shape
/// Nassau uses. Front-nine-over-back-nine stacked two grids on a phone and
/// made the reader find which half they were in before they could read anything;
/// eighteen across with the current hole parked seven slots in is one glance.
///
/// Par and stroke index stay called out as their own rows: they are the fixed
/// facts about the hole, and having them under the number is what lets a
/// golfer check a score without leaving the card.
///
/// **Column one is frozen.** The labels — Hole, Par, Index and the golfers'
/// names — stay put while the eighteen scroll under them, because a scorecard
/// you have scrolled three holes into is unreadable the moment you cannot see
/// whose row you are on.
///
/// White card, quiet bands. Only the header rows are tinted, so the scores
/// read as ink on paper rather than as cells in a spreadsheet.
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
  /// Print each cell against par — `+2` / `E` / `-1` — instead of as a raw
  /// score. Two 5s on a par 4 is +2, and "10" says nothing without doing the
  /// multiplication in your head.
  final bool toPar;
  /// Draw the rule BELOW this row rather than above it.
  ///
  /// `total` puts a rule ABOVE, which is right when the row sums the rows over
  /// it — golfers, then the team's line. It is wrong when one card carries two
  /// TEAMS: there the rule fell between a pair's score row and its own net
  /// row, splitting the pair it was supposed to bind. Setting this instead
  /// puts the line under the pair, where it separates one pair from the next.
  final bool ruleBelow;
  /// A colour bar down the left of the label, binding this row to a team.
  ///
  /// **One card can carry two teams.** A pairs playing group is four golfers
  /// on one scorecard, and the label column is 58 pixels — nowhere near enough
  /// for `Bronson & Petersen`. So the rows stay labelled `Team` and `Net` and
  /// the colour says whose, matching the swatch beside the name on the entry
  /// block directly above. Null when there is only one team and nothing to
  /// tell apart.
  final Color? accent;

  const TeamScorecardRow({
    required this.label,
    required this.scores,
    this.strokes = const {},
    this.counted = const {},
    this.italic = false,
    this.total = false,
    this.toPar = false,
    this.ruleBelow = false,
    this.accent,
  });

  /// A rule above is the default for a summing row, and is suppressed when the
  /// row asks for one below instead — two lines around one row is a box.
  bool get ruleAbove => total && !ruleBelow;
}

class TeamScorecard extends StatefulWidget {
  /// `{hole: par}` — also defines which holes exist.
  final Map<int, int> pars;
  /// `{hole: stroke index}`, optional; drawn as the Index row when present.
  final Map<int, int> strokeIndexes;
  /// One or more score lines. A scramble has one; a shamble has four balls
  /// and a net line.
  final List<TeamScorecardRow> rows;
  /// Highlighted, scrolled to, and tappable when [onTapHole] is given.
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

  @override
  State<TeamScorecard> createState() => _TeamScorecardState();
}

class _TeamScorecardState extends State<TeamScorecard> {
  final ScrollController _ctrl = ScrollController();

  static const double _labelW = 58;
  static const double _cellW  = 34;
  static const double _totalW = 40;
  static const double _rowH   = 26;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo());
  }

  @override
  void didUpdateWidget(TeamScorecard old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Park the current hole about seven slots in, so the holes just played stay
  /// on screen beside it — the same placement Nassau's grid uses.
  void _scrollTo() {
    final hole = widget.currentHole;
    if (hole == null || !_ctrl.hasClients) return;
    // No label width in the offset: the frozen column is outside the scroll
    // view, so hole 1 sits at zero.
    final target = ((hole - 7) * _cellW)
        .clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.animateTo(target,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.pars.isEmpty) return const SizedBox.shrink();

    final holes = widget.pars.keys.toList()..sort();
    final out   = holes.where((h) => h <= 9).toList();
    final back  = holes.where((h) => h > 9).toList();

    int total(Iterable<int> hs, Map<int, int> from) =>
        hs.map((h) => from[h] ?? 0).fold(0, (a, b) => a + b);

    String toParLabel(int v) => v == 0 ? 'E' : (v > 0 ? '+$v' : '$v');
    String fmt(TeamScorecardRow r, int h) {
      final v = r.scores[h];
      if (v == null) return '';
      return r.toPar ? toParLabel(v) : '$v';
    }

    BoxDecoration? _rule(TeamScorecardRow r, ThemeData th) {
      if (!r.ruleAbove && !r.ruleBelow) return null;
      final side = BorderSide(color: th.colorScheme.outlineVariant);
      return BoxDecoration(
        border: Border(
          top:    r.ruleAbove ? side : BorderSide.none,
          bottom: r.ruleBelow ? side : BorderSide.none,
        ),
      );
    }

    Widget labelCell(String text,
            {bool bold = false, bool italic = false, Color? accent}) =>
        Container(
          width: _labelW, height: _rowH,
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.only(left: accent == null ? 8 : 6),
          decoration: accent == null
              ? null
              : BoxDecoration(
                  border: Border(
                      left: BorderSide(color: accent, width: 3))),
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: bold ? FontWeight.bold : null,
                fontStyle: italic ? FontStyle.italic : null,
                color: theme.colorScheme.onSurfaceVariant,
              )),
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
          color: counted
              ? theme.colorScheme.primary.withValues(alpha: 0.14)
              : (current
                  ? theme.colorScheme.primary.withValues(alpha: 0.10)
                  : null),
          border: Border(
            left: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                width: 0.5),
          ),
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
      return goTo == null || widget.onTapHole == null
          ? body
          : InkWell(onTap: () => widget.onTapHole!(goTo), child: body);
    }

    /// Every hole in order, then OUT / IN / TOT — one strip, not two grids.
    List<Widget> line(Widget Function(int hole) forHole,
                      Widget Function(List<int> hs, String label) forTotal) =>
        [
          for (final h in out) forHole(h),
          forTotal(out, 'OUT'),
          for (final h in back) forHole(h),
          if (back.isNotEmpty) forTotal(back, 'IN'),
          if (back.isNotEmpty) forTotal(holes, 'TOT'),
        ];

    /// One row, split in two: the label that stays and the cells that scroll.
    ({Widget label, Widget cells}) rowPair(
        Widget label, List<Widget> cells, Color? colour) => (
          label: Container(color: colour, child: label),
          cells: Container(color: colour, child: Row(children: cells)),
        );

    final built = <({Widget label, Widget cells})>[
      rowPair(
        labelCell('Hole', bold: true),
        line((h) => cell('$h', bold: true, goTo: h,
                         current: h == widget.currentHole),
             (hs, l) => cell(l, bold: true, width: _totalW)),
        theme.colorScheme.surfaceContainerHighest,
      ),
      rowPair(
        labelCell('Par', italic: true),
        line((h) => cell('${widget.pars[h]}'),
             (hs, l) => cell('${total(hs, widget.pars)}',
                             bold: true, width: _totalW)),
        theme.colorScheme.surfaceContainerLow,
      ),
      if (widget.strokeIndexes.isNotEmpty)
        rowPair(
          labelCell('Index'),
          line((h) => cell('${widget.strokeIndexes[h] ?? ''}'),
               (hs, l) => cell('', width: _totalW)),
          theme.colorScheme.surfaceContainerLow,
        ),
      for (final r in widget.rows)
        rowPair(
          Container(
            decoration: _rule(r, theme),
            child: labelCell(r.label,
                bold: r.total, italic: r.italic, accent: r.accent),
          ),
          [
            Container(
              decoration: _rule(r, theme),
              child: Row(children: line(
                (h) => cell(fmt(r, h),
                    current: h == widget.currentHole,
                    counted: r.counted.contains(h),
                    faded  : r.scores[h] != null &&
                             r.counted.isNotEmpty &&
                             !r.counted.contains(h),
                    italic : r.italic,
                    bold   : r.total,
                    dots   : r.strokes[h] ?? 0,
                    goTo   : h),
                (hs, l) => cell(
                    hs.any((h) => r.scores[h] != null)
                        ? (r.toPar
                            ? toParLabel(total(hs, r.scores))
                            : '${total(hs, r.scores)}')
                        : '',
                    bold: true, width: _totalW),
              )),
            ),
          ],
          null,
        ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Frozen column one, with the hairline on its own right edge so it
          // tracks the real height — the total rows each add a border pixel,
          // and a divider sized from the row count would fall short.
          Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(
                  color: theme.colorScheme.outlineVariant)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final r in built) r.label],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _ctrl,
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final r in built) r.cells],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
