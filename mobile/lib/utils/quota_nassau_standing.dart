/// utils/quota_nassau_standing.dart
/// -------------------------------
/// What the standing ribbon says on a Quota Nassau — the cup's Four Ball
/// Quota, where each golfer plays a quota (36 − course handicap) and the
/// match margin is the difference between how far each is BEATING it.
///
/// ## The margin is POINTS, and it has to say so
///
/// `3 UP` is the Nassau form and it is wrong here: a hole is not the unit,
/// and a golfer who is three quota points clear may be level on holes. So
/// the row reads `+3 pts`, the same correction the watch card needed — and
/// the plus is kept because a quota margin is a count of points ahead, not a
/// score against par where `+` means worse.
///
/// **Halves are real.** A hole shared on Stableford points leaves a margin of
/// `2.5`, so the figure is formatted `:g`-style rather than rounded away —
/// the same rule Points 5-3-1's lock card needed after it shipped `41.0 PTS`.
///
/// ## The reader's own match, and the nine he is standing on
///
/// A cup Quota Nassau runs two matches in a foursome, so the row reports the
/// one the reader is in. The bet follows the hole on screen — front nine
/// while he is on it, back nine after — with the eighteen beside it, which is
/// the division `nassau_standing.dart` settled and this mirrors rather than
/// reinvents.
///
/// ## Neutral margin, leader's colour
///
/// RULINGS §3: a direction word may only appear on a row whose colour is the
/// READER's. Here the colour names the leader, so the margin is neutral and
/// says who is ahead by naming him — never `DOWN`.
library;

import '../api/models.dart';
import 'match_notation.dart';

/// One bet's line — `F9` and `+3 pts`.
class QuotaPart {
  final String label;
  final String value;

  /// 1 or 2 — the player leading, for the colour. Null while level.
  final int? side;

  const QuotaPart(this.label, this.value, this.side);
}

class QuotaNassauStanding {
  final QuotaPart main;
  final QuotaPart? second;
  const QuotaNassauStanding(this.main, this.second);
}

/// `2½`, `3`, `0` — halves are real in a quota and whole numbers are not
/// decimals.
String quotaPoints(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  final whole = v.abs().floor();
  final sign = v < 0 ? '-' : '';
  return '$sign${whole == 0 ? '' : whole}½';
}

/// The match to report: the reader's if he is in one, otherwise the GROUP's
/// first.
///
/// **A TD entering for a group he is not in is the ordinary case here, not an
/// edge.** This is a cup screen: every golfer in the field can be a
/// login-less roster entry, so whoever holds the phone is frequently in
/// neither match. Returning null for him made the row say `Tee off` over a
/// match that had been played — the third time this exact gate has been
/// found, after the tournament stroke row and cup Nassau. RULINGS §10.4.
///
/// Nothing downstream is relative to him: the margin is neutral and names the
/// LEADER, so the fallback reports a fact rather than a perspective.
QuotaNassauMatchSummary? readerMatch(
    QuotaNassauSummary s, int? playerId) {
  if (s.matches.isEmpty) return null;
  if (playerId != null) {
    for (final m in s.matches) {
      if (m.player1.playerId == playerId || m.player2.playerId == playerId) {
        return m;
      }
    }
  }
  // He is in neither. The screen he is looking at is entirely about this
  // group, so report the match it is drawing rather than nothing.
  return s.matches.first;
}

QuotaPart _part(String label, QuotaNassauSegment seg, QuotaNassauMatchSummary m,
    {required bool played}) {
  final margin = seg.margin;
  final side = margin == 0 ? null : (margin > 0 ? 1 : 2);
  if (!played) return QuotaPart(label, kTeeOff, null);
  if (margin == 0) return QuotaPart(label, kAllSquare, null);
  final who = side == 1 ? m.player1.shortName : m.player2.shortName;
  // The leader is NAMED rather than the margin being signed from the reader:
  // two golfers read the same row, and `+3` from one side is `−3` from the
  // other.
  return QuotaPart(label, '$who +${quotaPoints(margin.abs())} pts', side);
}

/// The row's parts, or null when the reader is not in a match here.
///
/// [hole] picks the bet the way the Nassau row does — the nine on screen,
/// with the eighteen beside it.
QuotaNassauStanding? quotaNassauStanding(
    QuotaNassauSummary? summary, int? playerId, {required int hole}) {
  if (summary == null) return null;
  final m = readerMatch(summary, playerId);
  if (m == null) return null;

  // Holes with a score in them, so a bet that has not started says `Tee off`
  // rather than `All square` — level on nothing is not level.
  final playedFront = m.holes.any((h) => h.hole <= 9 && h.p1VsQuota != null);
  final playedBack  = m.holes.any((h) => h.hole > 9 && h.p1VsQuota != null);

  final onBack = hole > 9;
  final main = onBack
      ? _part('B9', m.back9, m, played: playedBack)
      : _part('F9', m.front9, m, played: playedFront);
  final second =
      _part('Overall', m.overall, m, played: playedFront || playedBack);
  return QuotaNassauStanding(main, second);
}
