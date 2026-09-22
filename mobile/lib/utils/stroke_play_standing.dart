/// utils/stroke_play_standing.dart
/// -------------------------------
/// What the standing ribbon says on a Stroke Play round.
///
/// The packet drew this one itself — `2nd of 38 · −1 · thru 4` — and it is the
/// shape the row was designed around: a place, a score, and how far in.
///
///   * **the standing** is the place — `2nd of 4`
///   * **the figure** is the score and the progress — `−1 thru 4`
///
/// **The place leads because the place is the money.** The score is what a
/// golfer controls and the place is what it buys; on a stroke-play board the
/// second is the question and the first is the working.
///
/// ## No colour, and no side to have one
///
/// Stroke Play has no teams. There is nothing for a tint to identify, so the
/// row stays grey throughout — the same default Sixes falls back to when its
/// colour would lie. Tinting the score by par instead was considered and left
/// alone: red-for-under-par is the scorecard's vocabulary, and lifting it into
/// a row whose hue means *which side you are on* everywhere else would make
/// one colour mean two things across the app.
///
/// ## Why the place can be withheld
///
/// Score entry holds ONE foursome's scorecard. On a single-group round that is
/// the whole field and the place is the real one; on a multi-group round it
/// would be a place among four golfers presented as a place in the field,
/// which is worse than not saying it. There is no round-level Stroke Play
/// result endpoint to ask — the standings come through the leaderboard — so
/// the row reports the score alone there and leaves the place to the board.
library;

import '../api/models.dart';
import 'handicap_rounding.dart';
import 'match_handicap.dart';

/// Strokes [m] gets on hole [h] under the active handicap mode.
///
/// **Extracted from `_StrokePlayProgressGrid`, which now calls it.** The grid
/// draws the stroke dots and the ribbon reports the net they produce; two
/// implementations would eventually disagree about a golfer's score on the one
/// screen showing both.
int strokePlayStrokesOnHole(
  Membership m,
  int h, {
  required Scorecard scorecard,
  required List<Membership> players,
  required String handicapMode,
  required int netPercent,
  required List<int> holesInPlay,
}) {
  if (handicapMode == 'gross') return 0;

  final hole = scorecard.holeData(h);
  if (hole == null) return 0;
  final entry = hole.scoreFor(m.player.id);

  final universe = scorecard.holes.isEmpty
      ? 18
      : scorecard.holes
          .map((x) => x.holeNumber)
          .reduce((a, b) => a > b ? a : b);
  int siFor(int hh) =>
      scorecard.holeData(hh)?.scoreFor(m.player.id)?.strokeIndex ??
      scorecard.holeData(hh)?.strokeIndex ??
      18;

  if (handicapMode == 'net') {
    if (netPercent == 100 && entry != null) return entry.handicapStrokes;
    final effective = roundHalfUp(m.playingHandicap * netPercent / 100.0);
    return partialStrokesOnHole(effective, h, holesInPlay, universe, siFor);
  }
  // strokes_off — anchored on the foursome low.
  if (players.isEmpty) return 0;
  final low =
      players.map((p) => p.playingHandicap).reduce((a, b) => a < b ? a : b);
  final rawSo = m.playingHandicap - low;
  if (rawSo <= 0) return 0;
  final so = roundHalfUp(rawSo * netPercent / 100.0);
  if (so <= 0) return 0;
  return partialStrokesOnHole(so, h, holesInPlay, universe, siFor);
}

class StrokePlayStanding {
  /// `2nd of 4`, or empty when score entry cannot honestly know the field.
  final String place;

  /// `−1 thru 4`, or `E thru 4`.
  final String score;

  const StrokePlayStanding(this.place, this.score);
}

/// `1st`, `2nd`, `3rd` — and `T-1` when the place is shared.
///
/// **The `T` is in the layout, not bolted on** — a net stroke-play field ties
/// constantly, and a place that cannot show a tie is wrong most weeks.
///
/// **A tie drops the ordinal.** `T1st` is the tie marker and the ordinal
/// fighting for the same two characters, and it reads as a word nobody says;
/// `T-1` is how a leaderboard writes it. The untied form keeps its ordinal,
/// because there is nothing in front of it to collide with.
String placeLabel(int rank, bool tied) {
  if (tied) return 'T-$rank';
  final suffix = (rank % 100 >= 11 && rank % 100 <= 13)
      ? 'th'
      : {1: 'st', 2: 'nd', 3: 'rd'}[rank % 10] ?? 'th';
  return '$rank$suffix';
}

/// `+3` / `E` / `−2`, with U+2212 rather than a hyphen — the same minus the
/// money figure uses, and visibly the right length beside a `+`.
String toParLabel(int v) => v == 0 ? 'E' : (v > 0 ? '+$v' : '−${v.abs()}');

/// One golfer's net-to-par and holes played, over the holes he has scored.
({int toPar, int thru}) _netToPar(
  Membership m, {
  required Scorecard scorecard,
  required List<Membership> players,
  required String handicapMode,
  required int netPercent,
  required List<int> holesInPlay,
}) {
  var toPar = 0;
  var thru = 0;
  for (final hole in scorecard.holes) {
    final par = hole.par;
    final entry = hole.scoreFor(m.player.id);
    final gross = entry?.grossScore;
    if (gross == null || par == 0) continue;
    final strokes = strokePlayStrokesOnHole(m, hole.holeNumber,
        scorecard: scorecard, players: players, handicapMode: handicapMode,
        netPercent: netPercent, holesInPlay: holesInPlay);
    toPar += (gross - strokes) - par;
    thru += 1;
  }
  return (toPar: toPar, thru: thru);
}

/// The row's two strings, or null before the reader has a score.
///
/// [fieldIsThisGroup] must be true only when the round has ONE foursome. It is
/// what licenses the place: anywhere else this is four golfers out of a larger
/// field and a rank among them would be a different fact wearing the same
/// words.
StrokePlayStanding? strokePlayStanding({
  required Scorecard? scorecard,
  required List<Membership> players,
  required int? playerId,
  required String handicapMode,
  required int netPercent,
  required List<int> holesInPlay,
  required bool fieldIsThisGroup,
}) {
  if (scorecard == null || playerId == null) return null;
  final real = players.where((m) => !m.player.isPhantom).toList();
  final me = real.where((m) => m.player.id == playerId).firstOrNull;
  if (me == null) return null;

  ({int toPar, int thru}) net(Membership m) => _netToPar(m,
      scorecard: scorecard, players: players, handicapMode: handicapMode,
      netPercent: netPercent, holesInPlay: holesInPlay);

  final mine = net(me);
  if (mine.thru == 0) return null;
  final score = '${toParLabel(mine.toPar)} thru ${mine.thru}';

  if (!fieldIsThisGroup) return StrokePlayStanding('', score);

  // Rank on net to par among the golfers who have started. Somebody with no
  // score is not last — he is not on the board yet, and counting him would
  // move everybody else up a place for nothing.
  final started = real.map((m) => (m: m, n: net(m)))
      .where((e) => e.n.thru > 0)
      .toList()
    ..sort((a, b) => a.n.toPar.compareTo(b.n.toPar));
  final better = started.where((e) => e.n.toPar < mine.toPar).length;
  final level = started.where((e) => e.n.toPar == mine.toPar).length;
  return StrokePlayStanding(
      '${placeLabel(better + 1, level > 1)} of ${started.length}', score);
}
