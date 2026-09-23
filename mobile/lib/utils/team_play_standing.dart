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
/// A pairs card draws its two teams in their own colours, and the row reports
/// BOTH — so a tint would have to name two sides at once, in a slot that
/// holds one. This is Stroke Play's case rather than Sixes': the contest is
/// the field, not the other block on the card, and each place is already
/// tagged with its side's initials.
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

/// The row's two strings, or null before anything on the card has a score.
///
/// Null rather than a zero: a team with nothing entered is not level par, it
/// is not on the board — and the row draws `Tee off` for exactly that state,
/// which is the caller's job and not a string to invent here.
TeamPlayStandingText? teamPlayStanding(TeamPlayCardTeam? team) =>
    teamPlayCardStanding(team == null ? const [] : [team]);

/// **Every team on the card, not just the reader's.**
///
/// A foursome event puts one team on a card and this is the ordinary row:
/// `2nd of 6` then `−4 thru 12`.
///
/// A PAIRS event puts two. One person enters for both of them — that is what
/// the card is for — so reporting one and hiding the other picks a favourite
/// among two teams the same thumb is scoring. Reported from a two-man
/// scramble, 23 Sep 2026: *it should have both places for the 2 twosomes.*
///
/// With two teams the places are tagged with each side's initials and the
/// field is said once at the end, since both share it:
///
///     B&P 1st · D&D 2nd of 4          thru 1
///
/// **The whole bar goes to the places when there are two of them.** Two
/// places, two to-par figures and a field do not fit 27px, and the place is
/// the money — so the score goes and the board carries it.
///
/// `thru` goes with it, and for a better reason than width: each team's own
/// block on the card already reads `thru 1 · Net −1` in its header, a few
/// pixels below. A third copy bought nothing and cost the row the margin that
/// made it read as cramped. A one-team card keeps `−4 thru 12`, because there
/// is room for it and no second block competing.
TeamPlayStandingText? teamPlayCardStanding(List<TeamPlayCardTeam> teams) {
  final rows = [
    for (final t in teams)
      if (t.standing != null) (team: t, st: t.standing!),
  ];
  if (rows.isEmpty) return null;
  // Nothing on the card has started. `Tee off`, which is the caller's string.
  if (rows.every((r) => r.st.thru == 0 || r.st.netToPar == null)) return null;

  final field = rows.first.st.field;

  if (rows.length == 1) {
    final st = rows.first.st;
    final score = '${toParLabel(st.netToPar!)} thru ${st.thru}';
    // A place needs a rank AND somebody to be ranked against. `1st of 1` in a
    // one-team event is true and says nothing, so the score carries the row.
    if (st.rank == null || field < 2) return TeamPlayStandingText('', score);
    return TeamPlayStandingText(
        '${placeLabel(st.rank!, st.tied)} of $field', score);
  }

  // `B & P` is the scorecard's label, sized for its own column. The row is
  // tighter and there are two of them, so the spaces around the ampersand go.
  String tag(TeamPlayCardTeam t) =>
      (t.shortName.isEmpty ? t.name : t.shortName).replaceAll(' & ', '&');

  final parts = [
    for (final r in rows)
      // An em dash for a team that has not started: it is on the card and on
      // the board, so leaving it out would read as one twosome in a pairs
      // event. This is transient — the scorer enters both on the same hole.
      '${tag(r.team)} ${r.st.rank == null
          ? '—'
          : placeLabel(r.st.rank!, r.st.tied)}',
  ];
  final place = field < 2
      ? parts.join(' · ')
      : '${parts.join(' · ')} of $field';

  // No figure: the places take the whole bar, and each team's own block says
  // `thru 1 · Net −1` in its header a few pixels below.
  return TeamPlayStandingText(place, '');
}
