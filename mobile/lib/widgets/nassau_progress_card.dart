import 'package:flutter/material.dart';

import '../api/models.dart';
import '../utils/nassau_team_style.dart';
import 'hole_grid_scorecard.dart';

/// The Nassau progress grid, on the leaderboard.
///
/// It lived under the hole on score entry, where it sat half-visible behind
/// the hole tray, and the Nassau board carried a scorecard and a strokes
/// table of its own (Paul, 10 Nov 2026: *"move the Nassau progress grid to
/// the leaderboard and remove the scorecard and the strokes table"*). One
/// grid now, on the board: every golfer's gross with the stroke dots, named
/// in his side's colour, and under them **who won each hole**.
///
/// **Drawn through [HoleGridScorecard], not a grid of its own**, so the
/// pinned label column, OUT / IN / TOT and the play-order columns are the
/// ones every other card has. What makes it the Nassau grid is the three
/// things passed in: the title, the side colours on the names, and the
/// `Won by` row (Claremont's `Top` and `Bottom`).
///
/// **The strokes are the SERVER's.** The score-entry grid re-derived each
/// golfer's allocation on the phone from the handicap mode and allowance —
/// a second copy of the engine's rule. This reads the summary's own
/// scorecard block, where every hole carries the strokes the game gave.
///
/// No strokes table: the dots are on the cells, unplayed holes included.
/// No winning-side tint on the score cells either — the row underneath
/// names the winner, and two marks for one fact is one too many.
class NassauProgressCard extends StatelessWidget {
  const NassauProgressCard({
    super.key,
    required this.nassau,
    required this.holes,
    required this.players,
    required this.side0Colour,
    required this.side1Colour,
    this.holesInPlay = const [],
  });

  final NassauSummary nassau;

  /// The summary's `scorecard.holes` / `.players` / `.holes_in_play`.
  final List<Map<String, dynamic>> holes;
  final List<Map<String, dynamic>> players;
  final List<int> holesInPlay;

  final Color side0Colour;
  final Color side1Colour;

  NassauHoleData? _hole(int h) {
    for (final x in nassau.holes) {
      if (x.hole == h) return x;
    }
    return null;
  }

  Color? _sideColour(String? winner) => winner == 'team1'
      ? side0Colour
      : winner == 'team2' ? side1Colour : null;

  /// A 1-v-1 names the winner; a 2-v-2 gives the side's initials.
  String _sideMark(List<NassauPlayerInfo> side) {
    if (side.length == 1) {
      final p = side.first;
      final s = p.shortName.isNotEmpty ? p.shortName : p.name;
      return s.length > 4 ? s.substring(0, 4) : s;
    }
    return nassauTeamInitials(side);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final claremont = nassau.isClaremont;

    String? wonText(int h) {
      final w = _hole(h)?.winner;
      if (w == null) return '·';
      if (w == 'halved') return claremont ? '—' : '=';
      if (claremont) return '1';
      return _sideMark(w == 'team1' ? nassau.team1 : nassau.team2);
    }

    return HoleGridScorecard(
      title: nassau.isEighteenHoleMatch ? 'Match progress' : 'Nassau progress',
      // The row underneath says who won the hole, so the cells stay plain.
      holes: [
        for (final h in holes) {...h}..remove('winner_team'),
      ],
      participants: players,
      holesInPlay: holesInPlay,
      legend: null,
      showStrokes: false,
      teamColours: {1: side0Colour, 2: side1Colour},
      footerRows: [
        HoleGridFooterRow(
          label: claremont ? 'Top' : 'Won by',
          text: wonText,
          colour: (h) => _sideColour(_hole(h)?.winner) ?? muted,
          fill: (h) =>
              _sideColour(_hole(h)?.winner)?.withValues(alpha: 0.14),
        ),
        // Claremont's bottom game: two points a hole, so the cell says how
        // many went and the colour says which way.
        if (claremont)
          HoleGridFooterRow(
            label: 'Bottom',
            text: (h) {
              final d = _hole(h)?.bottomDelta;
              if (d == null) return '·';
              return d == 0 ? '—' : '${d.abs()}';
            },
            colour: (h) {
              final d = _hole(h)?.bottomDelta ?? 0;
              return d > 0 ? side0Colour : d < 0 ? side1Colour : muted;
            },
            fill: (h) {
              final d = _hole(h)?.bottomDelta ?? 0;
              if (d == 0) return null;
              return (d > 0 ? side0Colour : side1Colour)
                  .withValues(alpha: d.abs() == 2 ? 0.20 : 0.10);
            },
          ),
      ],
    );
  }
}
