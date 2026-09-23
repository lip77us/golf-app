/// utils/stableford_standing.dart
/// ------------------------------
/// What the standing ribbon says on a Stableford round.
///
/// **It is the shared points race** — `2nd of 12 · 27 pts` — so the shape, the
/// tie rule and the grey all come from `utils/points_race_standing.dart`, with
/// Wolf and Points 5-3-1 as the other callers.
///
/// ## The place is honest here, where Stroke Play's was not
///
/// Stroke Play withholds its place on a multi-group round: score entry holds
/// ONE foursome's card, so a rank computed from it would be a place among four
/// golfers wearing the words of a place in the field.
///
/// Stableford does not have that problem. Its summary is ROUND-level and
/// arrives already ranked over everybody who has posted a score, so `2nd of
/// 12` means second of twelve however many groups are out.
///
/// ## The money waits for the round
///
/// `payout` is a PRIZE projection — a pool split by the standings as they
/// stand — and the standings can turn on the last hole. A figure beside a
/// points total that is still moving invites reading it as money owed, which
/// is the rule this strip has held since Sixes: settled, or silent.
///
/// So the figure fills only when the round is complete. In per-point mode it
/// is computed on final totals too, so the same rule holds.
library;

import 'points_race_standing.dart';

/// The row's two strings, or null when the reader has no standing.
///
/// **No `hole` argument.** Stableford accumulates — a hole adds its points and
/// never re-opens one — so backing up does not change where a golfer stands.
PointsRaceStanding? stablefordStanding(
    Map<String, dynamic>? result, int? playerId,
    {required bool roundComplete}) {
  if (result == null) return null;
  final rows = (result['results'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  if (rows.isEmpty) return null;

  return pointsRaceStanding(
    [
      for (final r in rows)
        (
          id: (r['player_id'] as num?)?.toInt() ?? -1,
          points: (r['total_points'] as num?)?.toDouble() ?? 0,
          // A prize projection is not settled money — see above.
          money: roundComplete
              ? ((r['payout'] as num?)?.toDouble() ?? 0)
              : 0.0,
        ),
    ],
    playerId,
    // The game's own answer, rather than a guess from a zero total: a golfer
    // can legitimately have no points after a hole he picked up on.
    anyScored: rows.any((r) => ((r['holes_played'] as num?)?.toInt() ?? 0) > 0),
  );
}
