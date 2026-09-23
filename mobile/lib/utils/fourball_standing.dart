/// utils/fourball_standing.dart
/// ----------------------------
/// What the standing ribbon says on a Fourball round.
///
///   * **the standing** is the match — `2 UP thru 5`, `All Square thru 5`,
///     `win 3&2`
///   * **the figure** is the bet, once there is one — `+$20`
///
/// ## No names, because the rows below are already the two sides
///
/// The status card this replaces led every line with the leading pair's short
/// names: `Paul & Mike 2 UP thru 5`. That was right on a card that also had to
/// say WHO the two sides were; it is not right on a row sitting directly above
/// four player rows tinted team 1 blue and team 2 orange. It is the ruling
/// Nassau's `Paul Lipkin vs Jim …` banner got — *I don't need the names when I
/// have the colours* — and Fourball can take it for the same reason Vegas can:
/// **the two sides are fixed at setup and never change**, so the colour means
/// one thing for eighteen holes.
///
/// So the margin is NEUTRAL and wears the leader's colour. Not signed, unlike
/// Vegas: there the figure had to agree with a money column beside it, and
/// here the number IS the match — `2 UP` is what a golfer says out loud, and
/// `−2 pts` is not.
///
/// ## `&M` comes from the server or it is wrong
///
/// The holes left at a close-out are counted along the GROUP's play order,
/// which only the server knows. `18 − finishedOnHole` reads right off the 1st
/// tee and wrong off every shotgun — a match closing on the 7th played from a
/// shotgun on 13, with five left, printed `3&11`.
///
/// ## The money waits for the match
///
/// A single match settles exactly once, so there is nothing to report until it
/// does. `$0` on the 9th would read as a match played for nothing, which is
/// the same silence Sixes needed before a segment closes.
library;

import '../api/models.dart';
import 'match_notation.dart';

class FourballStanding {
  /// `2 UP thru 5`, `All Square thru 5`, `win 3&2`, or `Tee off`.
  final String standing;

  /// `+$20` once the match settles. Empty until then.
  final String figure;

  /// `team1` / `team2` / null — which side the standing's colour names.
  final String? leader;

  const FourballStanding(this.standing, this.figure, this.leader);
}

/// The row's strings, or null before the teams are set.
///
/// **No `hole` argument.** A fourball is ONE match over eighteen holes; there
/// is no nine, leg or segment to back up into, so the state is the state.
FourballStanding? fourballStanding(FourballSummary? summary, int? playerId) {
  if (summary == null || !summary.isStarted) return null;

  // What the reader's side is owed, once it is owed. A watcher gets the match
  // and no money, which is right: he has no stake in it.
  final mine = playerId == null
      ? null
      : summary.money
          .where((m) => m.name == _nameOf(summary, playerId))
          .firstOrNull;
  final figure = (mine == null || mine.amount.abs() < 0.005)
      ? ''
      : '${mine.amount > 0 ? '+' : '−'}\$'
        '${mine.amount.abs() == mine.amount.abs().roundToDouble()
            ? mine.amount.abs().toStringAsFixed(0)
            : mine.amount.abs().toStringAsFixed(2)}';

  final margin = summary.holesUp.abs();

  if (summary.status == 'complete') {
    // `holes_to_play` walks the group's own play order; `18 − finishedOnHole`
    // is the shotgun bug.
    return FourballStanding(
        'win ${closeOut(margin, summary.holesToPlay ?? 0)}',
        figure, summary.leader);
  }
  if (summary.status == 'halved') {
    return FourballStanding(kAllSquare, figure, null);
  }

  // `holesPlayed` is a COUNT, not a hole number — a shotgun group that has
  // played 7 through 12 is thru 6.
  final thru = summary.holesPlayed;
  if (thru == 0) return FourballStanding(kTeeOff, figure, null);
  if (summary.holesUp == 0) {
    return FourballStanding('$kAllSquare thru $thru', figure, null);
  }
  return FourballStanding(
      '${marginLabel(margin)} thru $thru', figure, summary.leader);
}

/// The display name the money list keys on. It carries names rather than ids,
/// so the reader has to be matched through the team rosters.
String? _nameOf(FourballSummary s, int playerId) {
  for (final t in [s.team1, s.team2]) {
    final i = t.playerIds.indexOf(playerId);
    if (i >= 0 && i < t.players.length) return t.players[i];
  }
  return null;
}
