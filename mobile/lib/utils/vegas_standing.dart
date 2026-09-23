/// utils/vegas_standing.dart
/// -------------------------
/// What the standing ribbon says on a Las Vegas round.
///
///   * **the standing** is the reader's side's margin in points — `+12 pts`,
///     `−8 pts`, `Even`
///   * **the figure** is what that is worth — `+$6 so far`
///
/// ## The margin is SIGNED, and Vegas is the only game on this row that can be
///
/// Every other team game states a neutral margin and leans on colour, because
/// four golfers read the same string and the pairing changes at the turn or
/// every hole. **Vegas has no perspective problem to solve**: the two sides are
/// fixed at setup and never change, so a signed figure that agrees with the
/// money beside it beats a neutral one that does not. That is the lock-screen
/// card's own ruling and the row follows it.
///
/// ## The colour is the LEADING side's, not the reader's
///
/// The card assigns the reader's own side blue, per phone. This row cannot:
/// the player rows six lines below are tinted team 1 blue and team 2 orange,
/// FIXED, and a row whose blue meant something else while sitting above them
/// would be the Sixes defect arriving by a different door.
///
/// So the two slots divide the work cleanly — **the sign is always the
/// reader's and the colour is always the leader's** — and neither can
/// contradict the screen under it. Level takes no colour, because there is no
/// leader to name.
///
/// ## Absolute point totals are not a standing
///
/// `Team 1: 84 · Team 2: 96` says nothing a golfer can act on; the only figure
/// that settles is the gap. That is why this row carries the difference and
/// why the status card's two team rows came off when it landed.
library;

import '../api/models.dart';
import 'match_notation.dart';

class VegasStanding {
  /// `+12 pts`, `−8 pts`, `Even`, or `Tee off`.
  final String standing;

  /// `+$6 so far` — empty at nothing.
  final String figure;

  /// The team NUMBER that is ahead (1 or 2), or null when level. The row
  /// colours the standing with that side's fixed colour.
  final int? leader;

  const VegasStanding(this.standing, this.figure, this.leader);
}

/// `+$6 so far` / `−$4 so far`, or empty at nothing.
///
/// **Settled, and live from the first hole.** A Vegas hole pays on the hole,
/// so the running figure is money already owed rather than a projection — the
/// same shape as Wolf and Points 5-3-1, and the reason this row can say
/// `so far` and mean it.
String vegasMoney(double v) {
  if (v.abs() < 0.005) return '';
  final n = v.abs();
  final amount =
      n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
  // U+2212, not a hyphen — beside a `+` at this size the hyphen is visibly
  // the wrong length.
  return '${v > 0 ? "+" : "−"}\$$amount so far';
}

/// The row's strings, or null when the reader is not on a side.
///
/// **No `hole` argument.** Vegas accumulates — a hole adds its points swing to
/// a total and never re-opens one — so backing up does not change where a side
/// stands. The games that take a hole do so because a match or a leg RESETS.
VegasStanding? vegasStanding(VegasSummary? summary, int? playerId) {
  if (summary == null || playerId == null) return null;
  if (summary.teams.length != 2) return null;

  final mine = summary.teamOf(playerId);
  // A watcher has no side, and a signed margin is meaningless without one.
  if (mine == null) return null;

  final my = summary.teams.where((t) => t.teamNumber == mine).firstOrNull;
  final their = summary.teams.where((t) => t.teamNumber != mine).firstOrNull;
  if (my == null || their == null) return null;

  final money = vegasMoney(my.money);

  // **Before the first hole is decided the row still draws.** The pill is the
  // way in, and losing it here gives the feature up exactly when a first-time
  // player goes looking for the leaderboard.
  if (!summary.holes.any((h) => h.winner != null)) {
    return VegasStanding(kTeeOff, money, null);
  }

  final margin = my.points - their.points;
  if (margin == 0) {
    // `Even`, not `All Square` — that is match play's phrase and Vegas is a
    // points swing, not a hole count. Grey: nobody leads.
    return VegasStanding('Even', money, null);
  }
  return VegasStanding(
      '${margin > 0 ? '+' : '−'}${margin.abs()} pts',
      money,
      margin > 0 ? mine : their.teamNumber);
}
