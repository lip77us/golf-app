/// utils/sequoya_standing.dart
/// ---------------------------
/// What the standing ribbon says on a Sequoya 3s round.
///
///   * **the standing** is the match the hole belongs to — `2 up`, `Dormie`,
///     `All square`, `3 & 2`
///   * **the figure** is the money settled so far — `+$12 so far`
///
/// ## It reuses `betState`, it does not restate it
///
/// The six-match strip two cards below already writes a Sequoya bet, and it
/// writes it NEUTRALLY — `2 up`, never `2 down` — with the colour naming the
/// leading side. That is the same division Nassau had to be corrected into on
/// 22 Sep, and this screen had it right already. So the row calls the screen's
/// own `betState` rather than growing a second notation that would drift from
/// it by a word.
///
/// ## The colour is safe here, and it is not safe in Sixes
///
/// A Sequoya pairing re-draws every three holes, exactly the thing that forces
/// Sixes to withhold its colour. The difference is that **this row always
/// reports the match the screen is showing**: the player rows under it are
/// tinted side 1 blue and side 2 orange for that same match, so the row's blue
/// and the screen's blue are the same two golfers by construction.
///
/// Sixes' problem was the hole AFTER a segment concludes, where the rows below
/// have re-drawn and the standing has not. Sequoya has no such gap — a match
/// runs to its last hole even when it was decided early, so the pairing on
/// screen is the pairing being reported until the moment both change together.
///
/// ## One bet, and the banner has the rest
///
/// A match can carry presses. The row reports the MATCH bet — the one every
/// match has — and leaves the presses to the bet banner, which names each with
/// its own holes and stake. Nassau made the same call for the same reason:
/// there can be several, and a row reporting one would have to say which.
library;

import '../api/models.dart';

class SequoyaStanding {
  /// `M3` — which of the six. Grey; it is identity, not news.
  final String label;

  /// `2 up`, `Dormie`, `All square`, `3 & 2`, `1 up · final`.
  final String standing;

  /// `+$12 so far` — empty at nothing.
  final String figure;

  /// 1 or 2 — the side that is up, and the colour the standing wears. Null
  /// while level, where there is no side for a colour to be about.
  final int? leader;

  const SequoyaStanding(this.label, this.standing, this.figure, this.leader);
}

/// The match the hole on screen belongs to, or null when none does.
///
/// **By hole number, because a Sequoya match IS a hole range** — three holes
/// each, six of them — and the screen names that range in the banner. Backing
/// up to the 4th reports match 2, which is what the pairing, the score rows
/// and the header on screen are all showing.
SequoyaMatch? sequoyaMatchAt(SequoyaThreesSummary s, int hole) =>
    s.matches
        .where((m) => hole >= m.startHole && hole <= m.endHole)
        .firstOrNull;

/// The row's strings, or null when the reader is not in the game.
SequoyaStanding? sequoyaStanding(
  SequoyaThreesSummary? summary,
  int? playerId, {
  required int hole,
  required String Function(SequoyaBet) betState,
}) {
  if (summary == null || playerId == null) return null;
  if (!summary.players.any((p) => p.playerId == playerId)) return null;

  final me = summary.players
      .where((p) => p.playerId == playerId).firstOrNull;
  final figure = _money(me?.money ?? 0);

  final match = sequoyaMatchAt(summary, hole);
  if (match == null || match.bets.isEmpty) {
    // Before the pairing is set, or on a hole no match covers. The row still
    // draws — the pill is the way in — and says which match is coming rather
    // than inventing a state for one that has not started.
    return SequoyaStanding(
        match == null ? '' : 'M${match.index}', 'Tee off', figure, null);
  }

  // **The MATCH bet, not a press.** Every match has exactly one; presses are
  // extra and the banner names them with their own holes and stakes.
  final bet = match.bets.first;
  return SequoyaStanding(
      'M${match.index}',
      betState(bet),
      figure,
      bet.margin == 0 ? null : (bet.margin > 0 ? 1 : 2));
}

/// `+$12 so far` / `−$8 so far`, or empty at nothing.
///
/// Settled bets only — a Sequoya bet pays when its three holes are done or it
/// closes out, so the running figure is money already owed rather than a
/// forecast of six matches that can all still turn.
String _money(double v) {
  if (v.abs() < 0.005) return '';
  final n = v.abs();
  final amount =
      n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
  // U+2212, not a hyphen — beside a `+` at this size the hyphen is visibly
  // the wrong length.
  return '${v > 0 ? "+" : "−"}\$$amount so far';
}
