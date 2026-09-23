/// utils/points_531_standing.dart
/// ------------------------------
/// What the standing ribbon says on a Points 5-3-1 round.
///
/// **It is the shared points race** — `2nd of 3 · 27 pts` with `+$4 so far`
/// beside it — so the shape, the tie rule and the grey both come from
/// `utils/points_race_standing.dart`. Wolf is the other caller.
///
/// The two games are genuinely one thing on this row: every golfer is on his
/// own, a hole hands out points, and the points settle into money. Writing it
/// twice would have meant two answers to how a tie is written and whether a
/// whole number keeps its decimal — and the lock card already shipped
/// `41.0 PTS` on every row of THIS game by getting the second one wrong.
///
/// ## What is different about Points, and why the row does not show it
///
/// The nine points on a hole are DIVIDED: a point you took is one neither of
/// the others got, which is why the lock card keeps three ranked rows where
/// every other four-name card became a strip. A single margin cannot describe
/// a three-way split.
///
/// The ribbon has one slot and cannot carry three rows, so it reports the
/// reader's own place and total and leaves the division to the card below —
/// which is the same division of labour Stroke Play makes with the field.
library;

import '../api/models.dart';
import 'points_race_standing.dart';

/// The row's two strings, or null when the reader is not in the game.
///
/// **No `hole` argument.** Points accumulates: a hole adds its award and never
/// re-opens one, so backing up does not change where a golfer stands.
PointsRaceStanding? points531Standing(
    Points531Summary? summary, int? playerId) {
  if (summary == null) return null;
  return pointsRaceStanding(
    [
      for (final p in summary.players)
        (id: p.playerId, points: p.points, money: p.money),
    ],
    playerId,
    // Each summary knows this differently; guessing it from a zero total
    // would silence the row for a golfer who has simply not scored yet.
    anyScored: summary.players.any((p) => p.holesPlayed > 0),
  );
}
