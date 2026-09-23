/// utils/wolf_standing.dart
/// ------------------------
/// What the standing ribbon says on a Wolf round.
///
///   * **the standing** is where you are and what put you there —
///     `2nd of 4 · 12 pts`
///   * **the figure** is what it has cost or paid — `+$6 so far`
///
/// ## The row is grey, because Wolf has no side to name
///
/// Every other team game on this row colours the standing with the reader's
/// side. Wolf re-draws the partnership EVERY HOLE: the wolf picks a man off
/// the tee and they are partners for one hole and opponents on the next. There
/// is no side that lasts long enough to wear a colour, so the row uses none —
/// the same answer Stroke Play arrived at from the other direction, and the
/// same rule Sixes needed after a colour outlived the teams it belonged to.
///
/// ## The money is live from the first hole, and it is still settled money
///
/// Wolf points net to zero on every hole — `services/wolf.py` says so where it
/// configures the wager engine — so a hole IS its own settlement and the
/// running figure is money already owed, not a projection of one. That is what
/// lets this row say `so far` and mean it where Sixes and Rabbit had to wait
/// for a leg to close. Points 5-3-1 is the same shape for the same reason.
///
/// **A loss cap is the one thing that bends it.** Capped, the total is no
/// longer points × stake, so the figure can move as the cap binds. It is still
/// the settlement of the holes played, which is the claim being made.
library;

import '../api/models.dart';
import 'match_notation.dart';
import 'stroke_play_standing.dart' show placeLabel;

class WolfStanding {
  /// `2nd of 4 · 12 pts`, or `Tee off` before anything is scored.
  final String standing;

  /// `+$6 so far` — empty at nothing.
  final String figure;

  const WolfStanding(this.standing, this.figure);
}

/// `12`, `12.5` — never `12.0`.
///
/// Points are fractional because a halved hole SPLITS them, so the decimal is
/// load-bearing when it is a half and noise on every whole number. The Points
/// 5-3-1 lock card shipped `41.0 PTS` on every row by forgetting this.
String wolfPoints(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// `+$6 so far` / `−$4 so far`, or empty at nothing.
String wolfMoney(WolfSummary s, int playerId) {
  final me = s.players.where((p) => p.playerId == playerId).firstOrNull;
  final v = me?.money ?? 0;
  if (v.abs() < 0.005) return '';
  final n = v.abs();
  final amount =
      n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
  // U+2212, not a hyphen — beside a `+` at this size the hyphen is visibly
  // the wrong length.
  return '${v > 0 ? "+" : "−"}\$$amount so far';
}

/// The row's two strings, or null when the reader is not in the game.
///
/// **Unlike every other game on this row, there is no `hole` argument.** Wolf
/// accumulates: a hole adds points and never re-opens one, so backing up to
/// the 4th does not change where a golfer stands — his total is his total. The
/// games that take a hole do so because a match, a leg or a Survivor RESETS,
/// and the row has to report the one the screen is showing. Wolf has nothing
/// to reset.
WolfStanding? wolfStanding(WolfSummary? summary, int? playerId) {
  if (summary == null || playerId == null) return null;
  final me = summary.players
      .where((p) => p.playerId == playerId).firstOrNull;
  if (me == null) return null;

  final money = wolfMoney(summary, playerId);

  // **Before the first score the row still draws.** The pill is the way in,
  // and losing it here gives the feature up exactly when a first-time player
  // goes looking for the leaderboard.
  if (!summary.holes.any((h) => h.isScored)) {
    return WolfStanding(kTeeOff, money);
  }

  // Rank on points, high to low. **Ties are ordinary here** — a halved hole
  // splits its points, so two golfers level is the common case rather than the
  // edge one, and `placeLabel` is shared with Stroke Play precisely so `T-2`
  // is written the same way on both.
  final sorted = [...summary.players]
    ..sort((a, b) => b.points.compareTo(a.points));
  final better = sorted.where((p) => p.points > me.points).length;
  final rank = better + 1;
  final tied = sorted.where((p) => p.points == me.points).length > 1;

  // `of N` stays, even though the field is the four names on the screen below.
  // A tie SPLITS, so how many people are in the race is what makes `T-2`
  // legible — and it is the one other ranked game on this row's own wording.
  return WolfStanding(
      '${placeLabel(rank, tied)} of ${summary.players.length}'
      ' · ${wolfPoints(me.points)} pts',
      money);
}
