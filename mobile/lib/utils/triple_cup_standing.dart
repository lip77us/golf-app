/// utils/triple_cup_standing.dart
/// ------------------------------
/// What the standing ribbon says on a Triple Cup round.
///
///   * **the standing** is the CUP — `2½–1½ of 4`, and `0–0` on the first tee
///   * **the figure** is the reader's own match — `2 UP thru 5`, `win 3&2`
///
/// ## The cup is the headline, including `0–0`
///
/// This is the lock-screen card's ruling and it holds here for the same
/// reason: **Triple Cup exists to produce a cup score**, and the match in
/// front of you is a way of earning a point in it, which is a different
/// question and gets the smaller slot.
///
/// An earlier design pass swapped the two to avoid showing `0–0` before the
/// first point, and that was wrong: *a headline that means one thing before
/// the first point and another after is a slot nobody can learn.*
///
/// ## The reader's match is the figure, and it names no side
///
/// Four matches run at once and the reader is in exactly one. The figure
/// reports THAT one — neutral margin, leader's colour, the same division
/// Nassau had to be corrected into — because a cup score and a match margin
/// in the same row cannot both be signed from his side without one of them
/// lying.
///
/// A match that has closed out keeps reporting its result rather than going
/// blank: the group is still playing golf in the other three, and `win 3&2`
/// is what he tells them on the next tee.
library;

import '../api/models.dart';
import 'match_notation.dart';

class TripleCupStanding {
  /// `2½–1½ of 4`.
  final String standing;

  /// `2 UP thru 5`, `All Square thru 5`, `win 3&2`, or empty when the reader
  /// is not in a match on this hole.
  final String figure;

  /// 1 or 2 — the team leading the reader's MATCH, which is what the figure
  /// wears. Null while that match is level.
  final int? matchLeader;

  const TripleCupStanding(this.standing, this.figure, this.matchLeader);
}

/// `2½`, `3`, `0` — halves are real in a cup and whole numbers are not
/// decimals. Same rule the lock card needed after Points shipped `41.0 PTS`.
String cupPoints(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  final whole = v.floor();
  return '${whole == 0 ? '' : whole}½';
}

/// The row's strings, or null before the cup is drawn.
///
/// [hole] picks the reader's match — four run at once over different hole
/// ranges, so the one on screen is the one to report.
TripleCupStanding? tripleCupStanding(TripleCupSummary? summary, int? playerId,
                                     {required int hole}) {
  if (summary == null || summary.matches.isEmpty) return null;

  final cup = '${cupPoints(summary.team1Points)}–'
              '${cupPoints(summary.team2Points)} of ${summary.pointsAvailable}';

  if (playerId == null) return TripleCupStanding(cup, '', null);

  // The reader's match on this hole. A watcher, or a golfer whose match does
  // not cover the hole on screen, gets the cup and nothing beside it — which
  // is honest rather than empty: the cup is the point of the round.
  final mine = summary.matches
      .where((m) =>
          hole >= m.startHole &&
          hole <= m.endHole &&
          m.players.any((p) => p.playerId == playerId && !p.isPhantom))
      .firstOrNull;
  if (mine == null) return TripleCupStanding(cup, '', null);

  final margin = mine.holesUpFinal.abs();
  final leader = mine.holesUpFinal == 0
      ? null
      : (mine.holesUpFinal > 0 ? 1 : 2);

  if (mine.status == 'complete') {
    // `holesToPlay` walks the match's own segment in the group's play order —
    // the only shotgun-safe source for the `M` in `3&2`.
    return TripleCupStanding(
        cup, 'win ${closeOut(margin, mine.holesToPlay ?? 0)}', leader);
  }
  if (mine.status == 'halved') {
    return TripleCupStanding(cup, kAllSquare, null);
  }

  // Holes played in THIS match, not on the course: a Triple Cup segment is six
  // holes of its own, so the hole number in the header does not say how far
  // into the match the group is.
  final thru = mine.holes.where((h) => h.winner != null).length;
  if (thru == 0) return TripleCupStanding(cup, kTeeOff, null);
  if (margin == 0) {
    return TripleCupStanding(cup, '$kAllSquare thru $thru', null);
  }
  return TripleCupStanding(cup, '${marginLabel(margin)} thru $thru', leader);
}
