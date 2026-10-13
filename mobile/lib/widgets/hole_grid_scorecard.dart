import 'package:flutter/material.dart';
import '../game_colors.dart';
import '../theme/halved_brand.dart';
import 'stroke_dots.dart';
import '../utils/nine_totals.dart';

/// Gold marks a ROLE rather than a result — Banker's, and Hot Spot's anchor.
/// It is deliberately not the win green: the man who banked a hole is as
/// likely to have been beaten on it three times as to have collected, and Hot
/// Spot's anchor is whose score the hole is BUILT from, which is a different
/// fact from whether it was any good.
const _gold     = Halved.role;
const _goldFill = Halved.roleFill;
const _goldLine = Halved.roleLine;

/// A row UNDER the golfers, drawn inside the grid rather than beside it.
///
/// 40 Balls needs two (`Balls`, `Group`) and drew them as a separate scroller
/// underneath: its own label width, its own cell width and its own scroll
/// offset, so the counts sat a column off the scores they described and
/// stayed put while the card scrolled. A row that belongs to the grid has to
/// be built by the grid.
class HoleGridFooterRow {
  final String label;

  /// The cell for one hole — text, or null for an empty slot. The grid owns
  /// the box, so a caller cannot get the geometry wrong.
  final String? Function(int hole) text;

  /// The colour of that cell's text. Null takes the ordinary one.
  final Color? Function(int hole)? colour;

  /// A tint behind the cell, drawn as a small chip inside the grid's own box.
  ///
  /// Solo's Won row needs it: a blue P on a hole the golfer took and a red P
  /// on one par took, told apart by colour alone, which at 11px flat text is
  /// not enough to read. Returning null for a hole leaves the ordinary flat
  /// cell, so a row can chip some holes and not others. The grid still owns
  /// the box — a caller handed a widget builder here would be able to get the
  /// geometry wrong, which is the whole reason this class exists.
  final Color? Function(int hole)? fill;

  /// The OUT / IN / TOT slot. Null leaves it blank — a row with no nine total
  /// says so with a gap rather than a made-up number.
  final String? Function(List<int> holes)? summary;

  const HoleGridFooterRow({
    required this.label,
    required this.text,
    this.colour,
    this.fill,
    this.summary,
  });
}

/// The shared per-hole scorecard grid — one widget behind every game's card.
///
/// Columns: hole numbers + par (+ stroke index when the backend sends it).
/// Rows: one per participant showing their gross score per hole with
/// stroke-dot overlays.  The hole winner's cell is highlighted green so the
/// player + score that won each hole is obvious at a glance; dead-skin holes
/// get a grey "—" header.
///
/// Lives here rather than in a screen because BOTH the leaderboard and the
/// Sixes score-entry screen render it — one implementation is what keeps the
/// two cards identical.
class HoleGridScorecard extends StatefulWidget {
  /// `holes` items are the per-hole payload from the multi-skins summary:
  ///   { hole, par, stroke_index, winner_id, winner_short, is_dead, banker_id,
  ///     scores: [{player_id, gross, strokes}, …] }
  final List<Map<String, dynamic>> holes;
  /// Standings entries (used for the player labels in the leftmost column,
  /// in the same order the standings table shows them).
  final List<Map<String, dynamic>> participants;

  /// When true, a second block of per-player rows shows each hole's points
  /// (read from each score entry's `points`) below the gross rows.
  final bool showPoints;

  /// Legend text shown beside the "Scorecard" heading. Null hides it (used by
  /// games with no skin-winner highlight, e.g. Sixes / Wolf).
  final String? legend;

  /// The round's holes IN PLAY ORDER — render exactly these columns (10-18 for a
  /// back 9; 14,15,…,18,1 for a shotgun). Empty falls back to 1..18.
  final List<int> holesInPlay;

  /// Rows under the golfers, inside the same grid — see [HoleGridFooterRow].
  final List<HoleGridFooterRow> footerRows;

  /// Tint for the Par row and for the golfers' rows.
  ///
  /// Solo is the only card where par is an OPPONENT rather than a reference,
  /// so it is the only one that colours them: red par against a blue golfer,
  /// which is also how the Won row's two "P" chips are told apart. Null
  /// everywhere else, which is every other board — they read par as a
  /// baseline and colouring it would say something untrue about it.
  final Color? parColor;
  final Color? playerColor;

  const HoleGridScorecard({
    super.key,
    required this.holes,
    required this.participants,
    this.showPoints = false,
    this.legend = 'green = skin winner',
    this.holesInPlay = const [],
    this.footerRows = const [],
    this.parColor,
    this.playerColor,
  });

  @override
  State<HoleGridScorecard> createState() => _HoleGridScorecardState();
}

class _HoleGridScorecardState extends State<HoleGridScorecard> {
  static const double _labelColW = 78.0;
  static const double _cellW     = 32.0;
  static const double _rowH      = 26.0;
  static const double _summaryW  = 34.0;

  final ScrollController _ctrl = ScrollController();

  // Last hole that actually has a score — so the auto-scroll lands on the
  // latest *played* hole, not the highest hole present in the data (Wolf and
  // Sixes list every hole up front — Sixes carries null-gross rows so the
  // prospective stroke dots can render before a hole is played).
  int get _lastScoredHole => widget.holes
      .where((h) => ((h['scores'] as List?) ?? const [])
          .any((s) => (s as Map)['gross'] != null))
      .map((h) => (h['hole'] as int?) ?? 0)
      .fold(0, (a, b) => a > b ? a : b);

  @override
  void initState() {
    super.initState();
    _scheduleScroll();
  }

  @override
  void didUpdateWidget(covariant HoleGridScorecard old) {
    super.didUpdateWidget(old);
    _scheduleScroll();
  }

  // Scroll so the latest scored hole is visible (~7 columns from the left), so
  // the most recent activity shows without scrolling right.
  void _scheduleScroll() {
    final hole = _lastScoredHole;
    if (hole == 0) return;
    // Scroll by the hole's POSITION in play order (columns render in that order),
    // not its hole number.
    final order = widget.holesInPlay.isNotEmpty
        ? widget.holesInPlay
        : List.generate(18, (i) => i + 1);
    final pos = order.indexOf(hole);
    if (pos < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      // The scroll view holds the HOLE columns only — the label column is
      // pinned outside it — and OUT / IN / TOT sit among them, so the offset
      // comes from the split rather than from a cell count: a back-nine hole
      // is one summary column further right than its position suggests.
      final split = NineSplit.of(order);
      final edge  = split.rightEdgeOf(hole, _cellW, _summaryW)
          ?? (pos + 1) * _cellW;
      final target = (edge - _ctrl.position.viewportDimension)
          .clamp(0.0, _ctrl.position.maxScrollExtent);
      _ctrl.animateTo(target,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// One footer cell — flat text, or the chip when the row tints that hole.
  ///
  /// 10px at weight 800 on a 4px-radius tint, which is the Solo card's Won
  /// row: two "P"s, one for Paul and one for Par, separated by colour only.
  Widget _footerCell(ThemeData theme, HoleGridFooterRow r, int h) {
    final text = r.text(h) ?? '';
    final fg   = r.colour?.call(h);
    final bg   = r.fill?.call(h);
    if (text.isEmpty || bg == null) {
      return Text(text,
          style: theme.textTheme.labelSmall
              ?.copyWith(fontWeight: FontWeight.bold, color: fg));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w800, color: fg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final holes  = widget.holes;
    final winBg  = Colors.green.shade100;
    final winFg  = Colors.green.shade900;
    // Survivor marks the player knocked out on a hole; every other game omits
    // the flag, so these are inert there.
    final outBg  = Colors.red.shade100;
    final outFg  = Colors.red.shade900;
    final deadBg = Colors.grey.shade200;

    final holeMap = {for (final h in holes) (h['hole'] as int): h};
    final visibleHoles = widget.holesInPlay.isNotEmpty
        ? widget.holesInPlay
        : List.generate(18, (i) => i + 1);

    Widget headerCell(int h) {
      final entry  = holeMap[h];
      final isDead = entry?['is_dead'] == true;
      return Container(
        width: _cellW, height: _rowH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDead ? deadBg : null,
        ),
        child: Text(
          '$h',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isDead ? Colors.grey.shade600 : null,
          ),
        ),
      );
    }

    Widget parCell(int h) {
      final par = holeMap[h]?['par'] as int?;
      return SizedBox(
        width: _cellW, height: _rowH,
        child: Center(
          child: Text(
            par == null ? '–' : '$par',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      );
    }

    // Stroke index (hole handicap 1–18) — shown so an observer can see which
    // holes are hardest and read off where strokes fall. Only rendered when the
    // backend supplies it (Sixes does; older/other cards may not).
    final hasStrokeIndex =
        holes.any((h) => h['stroke_index'] != null);
    // Player → team number (Nassau supplies `team`; Skins/Multi-Skins don't).
    // Used to tint the winning team's cells on each hole (`winner_team`).
    final teamOf = <int, int>{
      for (final p in widget.participants)
        if (p['player_id'] is int && p['team'] is int)
          p['player_id'] as int: p['team'] as int,
    };
    Widget siCell(int h) {
      final si = holeMap[h]?['stroke_index'] as int?;
      return SizedBox(
        width: _cellW, height: _rowH,
        child: Center(
          child: Text(
            si == null ? '–' : '$si',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    Widget scoreCell(int playerId, int h) {
      final entry = holeMap[h];
      if (entry == null) {
        return SizedBox(width: _cellW, height: _rowH);
      }
      final scores = (entry['scores'] as List? ?? []).cast<Map<String, dynamic>>();
      final mine = scores.firstWhere(
        (s) => s['player_id'] == playerId,
        orElse: () => const {},
      );
      final gross   = mine['gross'] as int?;   // null until this hole is scored
      final strokes = mine['strokes'] as int? ?? 0;
      // Unplayed hole with no stroke planned → nothing to show. A planned
      // stroke on an unplayed hole still renders (blank digit + dot) so the
      // whole stroke plan is visible up front.
      if (mine.isEmpty || (gross == null && strokes == 0)) {
        return SizedBox(width: _cellW, height: _rowH);
      }
      // A per-player win, however the game words it. 40 Balls sends
      // `counted` — the ball the group spent — which is its version of the
      // same fact and wears the same green. Every other game omits it.
      final isWinner = entry['winner_id'] == playerId || mine['counted'] == true;
      // Survivor: this hole knocked the player out of the current Survivor.
      final isOut = mine['eliminated'] == true;
      // Survivor + Zombie Option: this hole is where he won his way back in.
      // Every other game omits the flag, so it is inert there.
      final isBack = mine['resurrected'] == true;
      // Whoever HELD the hole's role. Gold, and gold means the role here and
      // nothing else — not a win, which is why it cannot borrow the green.
      // Every game without one omits both keys, so it is inert there.
      //
      // `role_id` is the general name; `banker_id` is read beside it because
      // Banker is where it started and its payload still says that. Hot Spot
      // sends `role_id` for the anchor.
      final roleId = entry['role_id'] ?? entry['banker_id'];
      final isBanker = roleId != null && roleId == playerId;
      // A capped score — Hot Spot's net double bogey. It is the LAST branch
      // on purpose: it describes how a number was arrived at, which never
      // outranks what the number did. Inert everywhere that omits it.
      final isCapped = mine['capped'] == true;
      // Nassau: the whole winning TEAM's cells get tinted in their colour.
      final winnerTeam = entry['winner_team'] as int?;
      // A side carried on the SCORE wins over the per-player map: Sequoya 3s
      // rotates the pairing every third hole, so which side a golfer is on is
      // a fact about the hole, not about him. Every other game omits it.
      final myTeam     = (mine['team'] as int?) ?? teamOf[playerId];
      final teamWin    = winnerTeam != null && myTeam != null && myTeam == winnerTeam;

      Color? cellBg;
      Color? cellFg;
      Border? cellBorder;
      if (teamWin) {
        cellBg = winnerTeam == 1 ? GameColors.team1Bg : GameColors.team2Bg;
        cellFg = winnerTeam == 1 ? GameColors.team1   : GameColors.team2;
      } else if (isWinner) {
        cellBg     = winBg;
        cellFg     = winFg;
        cellBorder = Border.all(color: Colors.green.shade400, width: 1);
      } else if (isBack) {
        cellBg     = Halved.zombie.withOpacity(0.18);
        cellFg     = Halved.zombie;
        cellBorder = Border.all(color: Halved.zombie, width: 1);
      } else if (isOut) {
        cellBg     = outBg;
        cellFg     = outFg;
        cellBorder = Border.all(color: Colors.red.shade400, width: 1);
      } else if (isBanker) {
        cellBg     = _goldFill;
        cellFg     = _gold;
        cellBorder = Border.all(color: _goldLine, width: 1);
      } else if (isCapped) {
        cellBg     = Halved.cautionGround;
        cellBorder = Border.all(color: Halved.caution, width: 1);
      }
      final highlight =
          teamWin || isWinner || isOut || isBack || isBanker || isCapped;

      return Container(
        width: _cellW, height: _rowH,
        decoration: BoxDecoration(
          color: cellBg,
          border: cellBorder,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Stack(children: [
          Center(
            child: Text(
              gross == null ? '' : '$gross',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: highlight ? FontWeight.bold : FontWeight.w500,
                color: cellFg,
              ),
            ),
          ),
          // The 32x26 cell the cap was invented for. A column down the right
          // edge costs 7px of it instead of 14, so three strokes — or four —
          // never reach the centred digit.
          StrokeDotColumn(
              strokes: strokes,
              color: isWinner ? winFg : theme.colorScheme.primary),
        ]),
      );
    }

    final split = NineSplit.of(visibleHoles);

    Widget summaryCell(String text) => SizedBox(
          width: _summaryW, height: _rowH,
          child: Center(
            child: Text(text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
        );

    /// A golfer's gross over a set of holes — **an em dash until every hole in
    /// the set is scored**, so a subtotal appears once its nine is complete
    /// and never as a misleading partial.
    Widget grossTotal(int playerId, List<int> holes) {
      var total = 0;
      for (final h in holes) {
        final entry = holeMap[h];
        final scores =
            (entry?['scores'] as List? ?? []).cast<Map<String, dynamic>>();
        final mine = scores.firstWhere((x) => x['player_id'] == playerId,
            orElse: () => const {});
        final g = mine['gross'] as int?;
        if (g == null) return summaryCell('—');
        total += g;
      }
      return summaryCell(holes.isEmpty ? '' : '$total');
    }

    int parSum(List<int> holes) {
      var t = 0;
      for (final h in holes) {
        t += (holeMap[h]?['par'] as int?) ?? 0;
      }
      return t;
    }

    /// The three columns, interleaved among the holes: front · OUT · back ·
    /// IN · TOT. `summary` fills a slot that has no meaning for the row —
    /// the stroke-index line has no nine total, and neither do points.
    List<Widget> withTotals(
      Widget Function(int hole) cell, {
      Widget Function(List<int> holes)? summary,
    }) {
      Widget blank(List<int> _) => summaryCell('');
      final sum = summary ?? blank;
      return [
        for (final h in split.front) cell(h),
        if (split.showOut) sum(split.front),
        for (final h in split.back) cell(h),
        if (split.showIn) sum(split.back),
        if (split.showTot) sum(split.all),
      ];
    }

    Widget pointsCell(int playerId, int h) {
      final entry = holeMap[h];
      if (entry == null) return SizedBox(width: _cellW, height: _rowH);
      final scores =
          (entry['scores'] as List? ?? []).cast<Map<String, dynamic>>();
      final mine = scores.firstWhere(
        (s) => s['player_id'] == playerId,
        orElse: () => const {},
      );
      if (mine.isEmpty || mine['points'] == null) {
        return SizedBox(width: _cellW, height: _rowH);
      }
      final pts = (mine['points'] as num).toDouble();
      final color = pts > 0
          ? Colors.green.shade700
          : pts < 0
              ? Colors.red.shade700
              : theme.colorScheme.onSurfaceVariant;
      final txt = pts == 0
          ? '·'
          : '${pts > 0 ? '+' : '−'}${pts.abs() == pts.abs().roundToDouble() ? pts.abs().toStringAsFixed(0) : pts.abs().toStringAsFixed(1)}';
      return SizedBox(
        width: _cellW, height: _rowH,
        child: Center(
          child: Text(txt,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ),
      );
    }

    Widget participantLabel(Map<String, dynamic> p, {String? suffix}) => SizedBox(
          width: _labelColW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              ((p['short_name'] as String?)?.isNotEmpty == true
                      ? p['short_name'] as String
                      : (p['name'] as String? ?? '')) +
                  (suffix ?? ''),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600, color: widget.playerColor),
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Scorecard',
                style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            // Expanded, not Spacer: the legend grew a third clause for the
            // Zombie, and an unbounded Text has no width to wrap into — it
            // just ran off the right edge on a 13 mini. Bounding it lets it
            // wrap to a second line instead.
            if (widget.legend != null)
              Expanded(
                child: Text(widget.legend!,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
          ]),
        ),
        // **The label column is pinned; only the holes scroll.** One
        // horizontal scroll view over the whole grid took the names away with
        // the holes, so by hole 12 the rows were anonymous. The two halves are
        // built as matched lists — same length, same row heights, same order —
        // because a grid whose columns disagree by one row is worse than one
        // that scrolls.
        Builder(builder: (context) {
          final labelCol = <Widget>[];
          final cellCol  = <Widget>[];

          void band(Color? colour, Widget label, List<Widget> cells) {
            labelCol.add(Container(color: colour, child: label));
            cellCol.add(Container(color: colour, child: Row(children: cells)));
          }

          void rule() {
            labelCol.add(Container(
                height: 1, width: _labelColW,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(vertical: 2)));
            cellCol.add(Container(
                height: 1,
                width: split.contentWidth(_cellW, _summaryW),
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(vertical: 2)));
          }

          Widget textLabel(String text, TextStyle? style) => SizedBox(
                width: _labelColW, height: _rowH,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(text, style: style),
                ),
              );

          // Banded header rows, matching the full ScorecardGrid: the hole
          // numbers on surfaceContainerHighest, par and index a step lighter
          // on surfaceContainerLow. Every scorecard in the app should read as
          // the same object, and the bands do the real work outdoors — they
          // separate the fixed course information from the scores underneath
          // without adding a single word of text.
          band(
            theme.colorScheme.surfaceContainerHighest,
            textLabel('Hole',
                const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            // Built out rather than through `withTotals`: the header's three
            // slots carry different WORDS, not a function of their holes.
            [
              for (final h in split.front) headerCell(h),
              if (split.showOut) summaryCell('OUT'),
              for (final h in split.back) headerCell(h),
              if (split.showIn) summaryCell('IN'),
              if (split.showTot) summaryCell('TOT'),
            ],
          );
          band(
            theme.colorScheme.surfaceContainerLow,
            textLabel('Par',
                theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: widget.parColor,
                    fontWeight:
                        widget.parColor == null ? null : FontWeight.w700)),
            withTotals(parCell,
                summary: (holes) => summaryCell('${parSum(holes)}')),
          );
          if (hasStrokeIndex) {
            band(
              theme.colorScheme.surfaceContainerLow,
              textLabel('Index',
                  theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
              // A stroke index has no nine total — the slots stay empty.
              withTotals(siCell),
            );
          }
          rule();

          // One row per participant — name plus "(N)" net strokes in play so
          // an observer can see who is shooting net what.
          for (final p in widget.participants) {
            labelCol.add(SizedBox(
              width: _labelColW, height: _rowH,
              child: Align(
                alignment: Alignment.centerLeft,
                child: RichText(
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false,
                  text: TextSpan(
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    children: [
                      TextSpan(text:
                        (p['short_name'] as String?)?.isNotEmpty == true
                            ? p['short_name'] as String
                            : (p['name'] as String? ?? '')),
                      if (p['phcp_in_play'] != null)
                        TextSpan(
                          text: ' (${p['phcp_in_play']})',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w400),
                        ),
                    ],
                  ),
                ),
              ),
            ));
            cellCol.add(Row(children: withTotals(
              (h) => scoreCell(p['player_id'] as int, h),
              summary: (holes) => grossTotal(p['player_id'] as int, holes),
            )));
          }

          // Rows that describe the GROUP rather than a golfer — 40 Balls'
          // `Balls` and `Group`. Inside the grid, so they pin and scroll with
          // everything above them.
          if (widget.footerRows.isNotEmpty) {
            rule();
            for (final r in widget.footerRows) {
              labelCol.add(textLabel(r.label,
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)));
              cellCol.add(Row(children: withTotals(
                (h) => SizedBox(
                  width: _cellW, height: _rowH,
                  child: Center(
                    child: _footerCell(theme, r, h),
                  ),
                ),
                summary: r.summary == null
                    ? null
                    : (holes) => summaryCell(r.summary!(holes) ?? ''),
              )));
            }
          }

          // Second block: per-player points won on each hole.
          if (widget.showPoints) {
            rule();
            for (final p in widget.participants) {
              labelCol.add(participantLabel(p, suffix: ' pts'));
              cellCol.add(Row(children: withTotals(
                (h) => pointsCell(p['player_id'] as int, h))));
            }
          }

          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: labelCol),
            Expanded(
              child: SingleChildScrollView(
                controller: _ctrl,
                scrollDirection: Axis.horizontal,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: cellCol),
              ),
            ),
          ]);
        }),
      ],
    );
  }
}
