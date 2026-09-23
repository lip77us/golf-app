/// utils/triple_nassau_standing.dart
/// ---------------------------------
/// What the standing ribbon says on a Triple Nassau round.
///
/// Three golfers, no teams, every pair playing its own match — so the reader
/// is in TWO matches at once and both slots are spoken for:
///
///   * **the standing** is one of them — `v JS  2 UP`
///   * **the figure** is the other — `v DP  ALL SQ`
///
/// ## A bare number is worthless here, which is why the row names the opponent
///
/// **The confusion this game produces is knowing you are two up and not
/// remembering two up on whom.** Two-player Nassau never has it — one
/// opponent, so a bare margin is unambiguous — and the lock-screen card was
/// built around exactly this. The label slot carries `v JS`, which is what
/// attaches the number to a match.
///
/// ## Never a direction word, and the colour says who
///
/// `2 UP` wears the colour of whoever is WINNING that match, and there is no
/// `2 DN` anywhere. That is not a style rule: a direction word is relative to
/// a reader, and in the third match — the two other men — **there is no reader
/// to be relative to**. Holding one rule for all three is what keeps the row
/// readable, and the card made the same call.
///
/// Colour comes from the golfer, not from a side: each of the three has one on
/// this screen, so the leader's own colour identifies him inside the same
/// glyph that carries the number.
///
/// ## Which BET, and why `thru` is dropped
///
/// The nine the hole on screen belongs to — the rule every game on this row
/// follows. `thru` comes off because both matches are on the same hole and the
/// header above says which; spending it twice would cost the opponent's name,
/// which is the fact this row exists to carry.
library;

import '../api/models.dart';
import 'match_notation.dart';

class TripleNassauPart {
  /// `v JS` — which match this is.
  final String label;

  /// `2 UP`, `ALL SQ`, `4&2`. Never `2 DN`.
  final String value;

  /// The player id whose colour the value wears — the leader. Null when level
  /// or settled, where no one is "ahead" for a colour to be about.
  final int? leaderId;

  const TripleNassauPart(this.label, this.value, this.leaderId);
}

class TripleNassauStanding {
  final TripleNassauPart first;
  final TripleNassauPart? second;
  const TripleNassauStanding(this.first, this.second);
}

/// One bet, written neutrally.
///
/// **Closed out, not merely finished.** A nine's `result` is only set once its
/// ninth hole is in, but a match decided 4&2 has been over for two holes — and
/// a row still reporting it as live is the one figure here a golfer would act
/// on wrongly.
TripleNassauPart _part(NassauBetResult bet, String label,
                       {required int p1Id, required int p2Id}) {
  if (bet.holesPlayed == 0) return TripleNassauPart(label, kTeeOff, null);

  final decided = bet.decidedMargin;
  if (decided != null || bet.result != null) {
    if (bet.result == 'halved') {
      return TripleNassauPart(label, 'HALVED', null);
    }
    final m = (decided ?? bet.margin).abs();
    final left = bet.decidedRemaining ?? 0;
    // Grey, not the winner's colour: the match is over, and the colour is this
    // row's way of saying *this is live and this man is ahead*.
    return TripleNassauPart(label, closeOut(m, left), null);
  }

  if (bet.margin == 0) return TripleNassauPart(label, 'ALL SQ', null);
  return TripleNassauPart(label, '${bet.margin.abs()} UP',
      bet.margin > 0 ? p1Id : p2Id);
}

/// The row's parts, or null when the reader is not one of the three.
///
/// [hole] picks the nine, and [onBack] is the screen's own answer to which one
/// that is — the same input the score card and the player rows use.
TripleNassauStanding? tripleNassauStanding(
    TripleNassauSummary? summary, int? playerId,
    {required int hole}) {
  if (summary == null || playerId == null) return null;

  // His two matches, in the summary's own order so the row does not reshuffle
  // as margins move.
  final mine = summary.matches
      .where((m) => m.player1Id == playerId || m.player2Id == playerId)
      .toList();
  if (mine.isEmpty) return null;

  String shortOf(int? id) => summary.players
      .where((p) => p.playerId == id)
      .map((p) => p.shortName)
      .firstOrNull ?? '';

  TripleNassauPart partFor(TripleNassauMatch m) {
    final opp = m.player1Id == playerId ? m.player2Id : m.player1Id;
    final n = m.match;
    // The nine the hole belongs to, falling back to the overall on a round
    // playing neither — the same order Nassau's own row resolves in.
    final bet = hole > 9
        ? (n.playBack ? n.back9 : n.overall)
        : (n.playFront ? n.front9 : n.overall);
    return _part(bet, 'v ${shortOf(opp)}',
        p1Id: m.player1Id ?? -1, p2Id: m.player2Id ?? -1);
  }

  return TripleNassauStanding(
      partFor(mine.first), mine.length > 1 ? partFor(mine[1]) : null);
}
