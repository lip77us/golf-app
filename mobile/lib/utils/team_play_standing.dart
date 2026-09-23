/// utils/team_play_standing.dart
/// -----------------------------
/// What the standing ribbon says on a Foursome Play round — scramble,
/// alternate shot, Scotch, Chapman, shamble, best ball.
///
///   * **the standing** is the team's place — `T-2 of 6`
///   * **the figure** is the team's score and progress — `−4 thru 12`
///
/// ## The place leads, and here it can
///
/// This is Stroke Play's shape one level up: a place, a score, how far in.
/// The place leads for the same reason — **the place is the money.**
///
/// What is different is that it can be SAID. Stroke Play's row withholds the
/// place on a multi-group round, because score entry holds one foursome's
/// card and a rank off it would be a place among four golfers wearing the
/// words of a place in the field. A Foursome Play card is a playing group too
/// — but the event is a tournament with a real board behind it, so the server
/// sends the field place down with the card and there is nothing to guess.
///
/// **Ranked by the same call the board uses** (`team_play_scoring.rank_rows`),
/// so the row and the board its own pill opens cannot put a team in two
/// different places.
///
/// ## Net against the par of the holes PLAYED
///
/// A team thru 4 and a team thru 18 are on the same scale, which is what
/// makes a live place mean anything at all. The figure comes down from the
/// server rather than being recomputed here: on a shamble par is multiplied
/// by the ball count — best-2 on a par 4 is a par of 8 — and a client adding
/// up `pars` alone is wrong by a whole par a hole.
///
/// ## No colour, and no side to have one
///
/// A pairs card draws its two teams in their own colours, but the row reports
/// ONE team — the reader's — so a tint would be naming a side nobody is
/// playing against. This is Stroke Play's case rather than Sixes': the
/// contest is the field, not the other block on the card. The team's name is
/// already the screen's title.
///
/// ## Money stays off it
///
/// The board's own rule is that money is a PROJECTION until every team has
/// signed for eighteen, drawn muted italic until then. A dollar figure beside
/// a team with four holes left is not a result, and the row has no room to
/// say it is provisional — which is settled-or-silent, the rule this strip
/// has held since Sixes.
library;

import '../api/models.dart';
import 'stroke_play_standing.dart';

class TeamPlayStandingText {
  /// `T-2 of 6`, or empty before the team has a score.
  final String place;

  /// `−4 thru 12`, or `E thru 12`.
  final String score;

  const TeamPlayStandingText(this.place, this.score);
}

/// The team on this card the reader plays for — his own, else the first.
///
/// A foursome event sends exactly one block, so this is the only team there
/// is. A pairs group sends two and he is in one of them.
///
/// **The fallback is the first block, not nothing.** A TD or a scorer opening
/// a group he is not playing in gets a screen entirely about that group, and
/// a row that went blank there would report nothing about the thing on
/// screen. Same ruling Triple Cup's row needed.
TeamPlayCardTeam? readersTeam(List<TeamPlayCardTeam> teams, int? playerId) {
  if (teams.isEmpty) return null;
  if (playerId == null) return teams.first;
  for (final t in teams) {
    if (t.playerIds.contains(playerId)) return t;
    // An own-ball format's rows carry the golfers too, and an older server
    // sends those without `player_ids`.
    if (t.golfersByHole.any((g) => !g.isPhantom && g.playerId == playerId)) {
      return t;
    }
  }
  return teams.first;
}

/// The row's two strings, or null before the team has a score.
///
/// Null rather than a zero: a team with nothing entered is not level par, it
/// is not on the board — and the row draws `Tee off` for exactly that state,
/// which is the caller's job and not a string to invent here.
TeamPlayStandingText? teamPlayStanding(TeamPlayCardTeam? team) {
  final st = team?.standing;
  if (st == null || st.netToPar == null || st.thru == 0) return null;
  final score = '${toParLabel(st.netToPar!)} thru ${st.thru}';
  // A place needs a rank AND somebody to be ranked against. `1st of 1` on the
  // first group out is true and says nothing, so the score carries the row
  // until a second team has a number.
  if (st.rank == null || st.field < 2) return TeamPlayStandingText('', score);
  return TeamPlayStandingText(
      '${placeLabel(st.rank!, st.tied)} of ${st.field}', score);
}
