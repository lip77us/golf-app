/// utils/triple_cup_standing.dart
/// ------------------------------
/// What the standing ribbon says on a Triple Cup round.
///
///   * **the standing** is the CUP — `2½–1½`, and `0–0` on the first tee
///   * **the figure** is the reader's own match, NAMED — `Fourball 1 UP thru
///     4`, `Singles 2 win 3&2`
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
/// **`of 4` came off on 22 Sep 2026**, and the segment took its place. How
/// many points are available is a fact that never changes all afternoon; which
/// FORMAT the group is playing changes twice, and it changes what they are
/// about to do on the tee. A golfer walking onto the 7th needs telling that
/// the fourball is over and this is alternate shot far more than he needs
/// reminding the cup is out of four.
///
/// ## The reader's match is the figure, and it names no side
///
/// Four matches run at once and the reader is in exactly one. The figure
/// reports THAT one — neutral margin, leader's colour, the same division
/// Nassau had to be corrected into — because a cup score and a match margin
/// in the same row cannot both be signed from his side without one of them
/// lying.
///
/// **The format sits in the label slot**, grey, in front of the margin: it is
/// the row's own idiom for a quiet word that says which bet this is, and it
/// leaves the colour and the weight on the number that moves.
///
/// A match that has closed out keeps reporting its result rather than going
/// blank: the group is still playing golf in the other three, and `win 3&2`
/// is what he tells them on the next tee.
library;

import '../api/models.dart';
import 'match_notation.dart';

class TripleCupStanding {
  /// `2½–1½`.
  final String standing;

  /// `Fourball`, `Foursomes`, `Singles 2` — the format the reader's match is
  /// playing, grey in front of the margin. Empty when he has no match here.
  final String figureLabel;

  /// `2 UP thru 5`, `All Square thru 5`, `win 3&2`, or empty when the reader
  /// is not in a match on this hole.
  final String figure;

  /// 1 or 2 — the team leading the reader's MATCH, which is what the figure
  /// wears. Null while that match is level.
  final int? matchLeader;

  const TripleCupStanding(
      this.standing, this.figureLabel, this.figure, this.matchLeader);
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
              '${cupPoints(summary.team2Points)}';

  if (playerId == null) return TripleCupStanding(cup, '', '', null);

  // The reader's match on this hole. A watcher, or a golfer whose match does
  // not cover the hole on screen, gets the cup and nothing beside it — which
  // is honest rather than empty: the cup is the point of the round.
  final mine = summary.matches
      .where((m) =>
          hole >= m.startHole &&
          hole <= m.endHole &&
          m.players.any((p) => p.playerId == playerId && !p.isPhantom))
      .firstOrNull;
  if (mine == null) return TripleCupStanding(cup, '', '', null);

  // The leaderboard's own rule for naming a match: its label when it has one,
  // which is what distinguishes `Singles 1` from `Singles 2`, and the segment
  // otherwise.
  final format = segmentLabel(mine);

  final margin = mine.holesUpFinal.abs();
  final leader = mine.holesUpFinal == 0
      ? null
      : (mine.holesUpFinal > 0 ? 1 : 2);

  if (mine.status == 'complete') {
    // `holesToPlay` walks the match's own segment in the group's play order —
    // the only shotgun-safe source for the `M` in `3&2`.
    return TripleCupStanding(
        cup, format, 'win ${closeOut(margin, mine.holesToPlay ?? 0)}', leader);
  }
  if (mine.status == 'halved') {
    return TripleCupStanding(cup, format, kAllSquare, null);
  }

  // Holes played in THIS match, not on the course: a Triple Cup segment is six
  // holes of its own, so the hole number in the header does not say how far
  // into the match the group is.
  final thru = mine.holes.where((h) => h.winner != null).length;
  if (thru == 0) return TripleCupStanding(cup, format, kTeeOff, null);
  if (margin == 0) {
    return TripleCupStanding(cup, format, '$kAllSquare thru $thru', null);
  }
  return TripleCupStanding(
      cup, format, '${marginLabel(margin)} thru $thru', leader);
}

/// `Fourball`, `Foursomes`, `Singles 2` — the match's own label when it has
/// one, the segment otherwise.
///
/// The label is what tells `Singles 1` from `Singles 2`, and it is the same
/// expression the leaderboard's segment pill uses, so the row and the board
/// name a match the same way.
String segmentLabel(TripleCupMatch m) {
  if (m.label.isNotEmpty) return m.label;
  final seg = m.segment;
  return seg.isEmpty ? '' : seg[0].toUpperCase() + seg.substring(1);
}
