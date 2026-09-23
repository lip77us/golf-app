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
import 'points_race_standing.dart';
import 'standing_money.dart';

/// Wolf's row IS the shared points-race row — see
/// `utils/points_race_standing.dart` for the shape and the reasoning. These
/// names stay because the screen and its tests speak in them.
typedef WolfStanding = PointsRaceStanding;

/// `12`, `12.5` — never `12.0`. Shared with Points 5-3-1.
const wolfPoints = racePoints;

/// `+$6 so far` / `−$4 so far`, or empty at nothing.
///
/// **Live from the first hole, and still settled money.** Wolf points net to
/// zero on every hole — `services/wolf.py` says so where it configures the
/// wager engine — so a hole IS its own settlement and the running figure is
/// money already owed, not a projection of one. That is what lets this row say
/// `so far` and mean it where Sixes and Rabbit had to wait for a leg to close.
///
/// **A loss cap is the one thing that bends it.** Capped, the total is no
/// longer points x stake, so the figure can move as the cap binds. It is still
/// the settlement of the holes played, which is the claim being made.
String wolfMoney(WolfSummary s, int playerId) => standingMoney(
    s.players.where((p) => p.playerId == playerId).firstOrNull?.money ?? 0);

/// The row's two strings, or null when the reader is not in the game.
///
/// **Unlike every other game on this row, there is no `hole` argument.** Wolf
/// accumulates: a hole adds points and never re-opens one, so backing up to
/// the 4th does not change where a golfer stands — his total is his total. The
/// games that take a hole do so because a match, a leg or a Survivor RESETS,
/// and the row has to report the one the screen is showing. Wolf has nothing
/// to reset.
WolfStanding? wolfStanding(WolfSummary? summary, int? playerId) {
  if (summary == null) return null;
  return pointsRaceStanding(
    [
      for (final p in summary.players)
        (id: p.playerId, points: p.points, money: p.money),
    ],
    playerId,
    anyScored: summary.holes.any((h) => h.isScored),
  );
}
