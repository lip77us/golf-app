import 'package:flutter/material.dart';

import '../game_colors.dart';
import 'hole_grid_scorecard.dart';

/// The Wolf scorecard — on the leaderboard's Wolf card.
///
/// It was the play screen's (`_WolfGrid`, under the keypad and the tray) and
/// moved here on 10 Nov 2026 (Paul: *"move the Wolf scorecard from the score
/// entry board to the leaderboard … keep the colors … and add the gets"*),
/// where it replaced a gross card with a second block of per-hole points and
/// a strokes table.
///
/// **Drawn through [HoleGridScorecard], not a grid of its own.** What makes
/// it Wolf's is what it is handed:
///
/// * a `Wolf` row above the golfers — who held the Wolf on each hole, which
///   is the one thing a gross card cannot say for itself;
/// * each gross tinted in the colour of the SIDE that won the hole — blue
///   for the Wolf's, orange for the opponents', the two the play screen's
///   rows wear. Not the win green: everywhere else that means *this ball
///   won*, and a Wolf hole is won by a side. A tie tints nobody;
/// * both colours keyed beside the title;
/// * `gets N` beside each name, and no strokes table — the dots are on the
///   cells;
/// * each golfer's POINTS per hole, as a second block at the bottom.
///
/// **Which side won, and who was on it, is the SERVER's** (`winner_team` on
/// the hole, `team` on each score — the sides change every hole). The phone
/// used to decide it; this widget decides nothing.
class WolfScorecard extends StatelessWidget {
  /// `wolf_summary`, as the leaderboard holds it.
  final Map<String, dynamic> summary;
  const WolfScorecard({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final card = summary['scorecard'] as Map<String, dynamic>? ?? const {};
    final holes = (card['holes'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final players = (card['players'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    if (holes.isEmpty || players.isEmpty) return const SizedBox.shrink();
    final inPlay = (card['holes_in_play'] as List? ?? const [])
        .map((e) => (e as num).toInt())
        .toList();

    final wolfOf = <int, String>{
      for (final h in holes)
        (h['hole'] as num).toInt(): h['wolf_short']?.toString() ?? '',
    };

    return HoleGridScorecard(
      holes: holes,
      participants: players,
      holesInPlay: inPlay,
      showStrokes: false,
      // The points each golfer took on each hole, as a second block under
      // the scores (Paul, 10 Nov 2026 — they came off with the old card and
      // he asked for them back the same afternoon).
      showPoints: true,
      legend: null,
      legendSwatches: [
        (fill: GameColors.team1Bg, line: GameColors.team1,
         label: 'Wolf side won'),
        (fill: GameColors.team2Bg, line: GameColors.team2,
         label: 'opponents won'),
      ],
      headerRows: [
        HoleGridFooterRow(
          label: 'Wolf',
          // Three characters: the cell is 32pt and a short name runs to
          // five. Enough to tell four golfers apart, which is its only job.
          text: (h) {
            final w = wolfOf[h] ?? '';
            return w.isEmpty ? null : w.characters.take(3).toString();
          },
        ),
      ],
    );
  }
}
