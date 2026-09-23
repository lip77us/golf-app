/// utils/points_race_standing.dart
/// -------------------------------
/// The standing ribbon on a POINTS RACE — Wolf and Points 5-3-1.
///
/// Two games, one shape: every golfer is on his own, a hole hands out points,
/// and the points settle into money. So the row says the same two things for
/// both — `2nd of 4 · 12 pts` and `+$6 so far` — and says them from one
/// definition, because two copies would eventually disagree about how a tie is
/// written or whether a whole number keeps its decimal.
///
/// ## What makes a game belong here
///
/// **A points race accumulates and never resets**, which is why neither row
/// takes a hole: a hole adds points and never re-opens one, so backing up to
/// the 4th does not change where a golfer stands. The games that take a hole
/// do so because a match, a nine, a leg or a Survivor resets underneath them.
///
/// **And it has no sides**, so the row stays grey. Wolf re-draws its
/// partnership every hole and Points 5-3-1 is three men playing for
/// themselves; there is no colour that means the same thing for the whole
/// round, which is the test the ribbon applies before tinting anything.
///
/// ## Ties are the common case, not the edge one
///
/// Both games SPLIT a tied hole's points — Wolf halves them, Points averages
/// 5 and 3 into 4 and 4 — so two golfers level is ordinary and half points are
/// real. `placeLabel` is shared with Stroke Play so `T-2` is written the same
/// way on all three, and `racePoints` keeps the half while refusing the `.0`:
/// the Points 5-3-1 lock card shipped `41.0 PTS` on every row by forgetting
/// that the decimal is load-bearing only when it is a half.
library;

import 'match_notation.dart';
import 'standing_money.dart';
import 'stroke_play_standing.dart' show placeLabel;

class PointsRaceStanding {
  /// `2nd of 4 · 12 pts`, or `Tee off` before anything is scored.
  final String standing;

  /// `+$6 so far` — empty at nothing.
  final String figure;

  const PointsRaceStanding(this.standing, this.figure);
}

/// One golfer's place in the race, as the row needs him.
typedef RaceEntry = ({int id, double points, double money});

/// `12`, `12.5` — never `12.0`.
///
/// A tied hole SPLITS its points, so the decimal is load-bearing when it is a
/// half and noise on every whole number.
String racePoints(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// The row's two strings, or null when the reader is not in the game.
///
/// [anyScored] is the game's own answer to whether a hole has been played —
/// each summary knows it differently, and guessing from a zero point total
/// would silence the row for a golfer who has simply not scored yet.
PointsRaceStanding? pointsRaceStanding(
  List<RaceEntry> field,
  int? playerId, {
  required bool anyScored,
}) {
  if (playerId == null) return null;
  final me = field.where((e) => e.id == playerId).firstOrNull;
  if (me == null) return null;

  final money = standingMoney(me.money);

  // **Before the first score the row still draws.** The pill is the way in,
  // and losing it here gives the feature up exactly when a first-time player
  // goes looking for the leaderboard.
  if (!anyScored) return PointsRaceStanding(kTeeOff, money);

  final better = field.where((e) => e.points > me.points).length;
  final tied = field.where((e) => e.points == me.points).length > 1;

  // `of N` stays even though the field is the names on the screen below: a tie
  // SPLITS, so how many are in the race is what makes `T-2` legible — and it
  // is the wording Stroke Play, the one other ranked game on this row, uses.
  return PointsRaceStanding(
      '${placeLabel(better + 1, tied)} of ${field.length}'
      ' · ${racePoints(me.points)} pts',
      money);
}
