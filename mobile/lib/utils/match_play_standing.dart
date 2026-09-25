/// utils/match_play_standing.dart
/// ------------------------------
/// What the standing ribbon says on a Mini Singles Bracket round.
///
///   * **the standing** is the reader's own match — `Gunst 1 UP thru 4`,
///     `All square thru 4`, `Gunst 4&2`
///   * **the figure** is empty; the bracket has no money of its own on this row
///
/// ## It renders the ENGINE's line, and writes nothing of its own
///
/// `_match_line` in `services/tournament_match_play.py` already produces the
/// one-line state the board and the bracket card both show, and it produces it
/// NEUTRALLY — it names the golfer who is up by surname rather than saying UP
/// or DOWN at anybody. That is the division the whole strip settled on, and
/// this game had it first.
///
/// It also handles three cases a client-side margin could not: a halved semi
/// that played on, a back-nine match against a semi that has not resolved
/// (`1 UP thru 11`, read from the named golfer's side because the other has no
/// name yet), and the close-out's `&M` counted along the match's own nine. The
/// row would have to re-derive all three to gain nothing.
///
/// ## The phase is the quiet slot
///
/// `Semi 1`, `Final`, `3rd Place` — the match's own label, which is what says
/// WHICH of the bracket's matches this is. The card below shows the pairings;
/// this says where the reader's own stands without him scrolling to it.
library;

class MatchPlayStanding {
  /// `Semi 1`, `Final`, `3rd Place`.
  final String label;

  /// The engine's own line for the reader's match.
  final String standing;

  const MatchPlayStanding(this.label, this.standing);
}

/// The matches of the phase being played — round 2 once every round-1 match is
/// done, round 1 until then.
///
/// **Not when the FIRST semi finishes**: the other is still the live match for
/// two of the four golfers. The bracket card shows its matches by this same
/// rule, so the card, the scorecard under it and this row are never about
/// different nines.
List<Map<String, dynamic>> bracketLiveMatches(Map<String, dynamic> data) {
  final all =
      (data['matches'] as List? ?? const []).cast<Map<String, dynamic>>();
  final r1 = all.where((m) => m['round'] == 1).toList();
  final r2 = all.where((m) => m['round'] == 2).toList();
  final done = r1.isEmpty ||
      r1.every((m) => m['status'] == 'complete' || m['status'] == 'halved');
  return (r2.isNotEmpty && done) ? r2 : r1;
}

/// The row's strings, or null when the reader is not in the live phase.
///
/// **No `hole` argument.** A bracket match is a nine of its own and the phase
/// picks itself from what has finished, so there is nothing the hole on screen
/// would change.
MatchPlayStanding? matchPlayStanding(
    Map<String, dynamic>? data, int? playerId) {
  if (data == null) return null;

  // The reader's match in the live phase. In the three-player layout the top
  // seed plays both semis at once; the first is taken, because two rows cannot
  // fit and the card below has the other.
  final live = bracketLiveMatches(data);
  if (live.isEmpty) return null;
  final mine = live.where((m) {
        final p1 = m['player1_id'] ?? m['player1_player_id'];
        final p2 = m['player2_id'] ?? m['player2_player_id'];
        return p1 == playerId || p2 == playerId;
      }).firstOrNull ??
      // **He is in no match, which on a tournament screen is ordinary.**
      // Every golfer in the field can be a login-less roster entry, so the TD
      // entering the scores is frequently in none of them — and refusing here
      // put `Tee off` over a bracket that was being played. RULINGS §10.4,
      // the same gate found on the tournament stroke row, cup Nassau and
      // Quota Nassau.
      //
      // Safe because the line is the ENGINE's and is written NEUTRALLY —
      // naming the golfer who is up rather than saying UP or DOWN at anybody
      // — so it reports a fact rather than a perspective.
      live.first;

  final label = (mine['label'] as String?)?.trim() ?? '';
  final line = (mine['line'] as String?)?.trim() ?? '';
  // An empty line means the engine had nothing to say — a match whose golfers
  // are not settled and whose holes are not played. The row still draws,
  // because the pill is the way in.
  return MatchPlayStanding(label, line.isEmpty ? 'Not started' : line);
}
