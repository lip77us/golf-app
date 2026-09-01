import 'package:flutter/material.dart';
import '../game_colors.dart';
import '../theme/halved_brand.dart';

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
  ///   { hole, par, stroke_index, winner_id, winner_short, is_dead,
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

  const HoleGridScorecard({
    super.key,
    required this.holes,
    required this.participants,
    this.showPoints = false,
    this.legend = 'green = skin winner',
    this.holesInPlay = const [],
  });

  @override
  State<HoleGridScorecard> createState() => _HoleGridScorecardState();
}

class _HoleGridScorecardState extends State<HoleGridScorecard> {
  static const double _labelColW = 78.0;
  static const double _cellW     = 32.0;
  static const double _rowH      = 26.0;

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
      final target = (_labelColW + (pos - 7) * _cellW)
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
      final isWinner = entry['winner_id'] == playerId;   // Skins per-player win
      // Survivor: this hole knocked the player out of the current Survivor.
      final isOut = mine['eliminated'] == true;
      // Survivor + Zombie Option: this hole is where he won his way back in.
      // Every other game omits the flag, so it is inert there.
      final isBack = mine['resurrected'] == true;
      // Nassau: the whole winning TEAM's cells get tinted in their colour.
      final winnerTeam = entry['winner_team'] as int?;
      final myTeam     = teamOf[playerId];
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
      }
      final highlight = teamWin || isWinner || isOut || isBack;

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
          if (strokes > 0)
            Positioned(
              top: 2, right: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  strokes.clamp(0, 2),
                  (i) => Container(
                    width: 4, height: 4,
                    margin: const EdgeInsets.only(left: 1),
                    decoration: BoxDecoration(
                      // Neutral green, matching the score-entry stroke dots.
                      color: isWinner ? winFg : theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
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
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
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
        SingleChildScrollView(
          controller: _ctrl,
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Banded header rows, matching the full ScorecardGrid: the
              // hole numbers on surfaceContainerHighest, par and index a
              // step lighter on surfaceContainerLow. Every scorecard in
              // the app should read as the same object, and the bands do
              // the real work outdoors -- they separate the fixed course
              // information from the scores underneath without adding a
              // single word of text.
              Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Row(children: [
                  SizedBox(
                    width: _labelColW, height: _rowH,
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Hole',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  for (final h in visibleHoles) headerCell(h),
                ]),
              ),
              // Par row
              Container(
                color: theme.colorScheme.surfaceContainerLow,
                child: Row(children: [
                  SizedBox(
                    width: _labelColW, height: _rowH,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Par',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontStyle: FontStyle.italic)),
                    ),
                  ),
                  for (final h in visibleHoles) parCell(h),
                ]),
              ),
              // Stroke-index (hole handicap) row
              if (hasStrokeIndex)
                Container(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Row(children: [
                    SizedBox(
                      width: _labelColW, height: _rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Index',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ),
                    ),
                    for (final h in visibleHoles) siCell(h),
                  ]),
                ),
              Container(
                height: 1,
                width: _labelColW + _cellW * visibleHoles.length,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(vertical: 2),
              ),
              // One row per participant — name plus "(N)" net strokes
              // in play so an observer can see who is shooting net what.
              for (final p in widget.participants)
                Row(children: [
                  SizedBox(
                    width: _labelColW, height: _rowH,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: RichText(
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        softWrap: false,
                        text: TextSpan(
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600),
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
                  ),
                  for (final h in visibleHoles)
                    scoreCell(p['player_id'] as int, h),
                ]),

              // Second block: per-player points won on each hole.
              if (widget.showPoints) ...[
                Container(
                  height: 1,
                  width: _labelColW + _cellW * visibleHoles.length,
                  color: theme.colorScheme.outlineVariant,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                ),
                for (final p in widget.participants)
                  Row(children: [
                    participantLabel(p, suffix: ' pts'),
                    for (final h in visibleHoles)
                      pointsCell(p['player_id'] as int, h),
                  ]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
