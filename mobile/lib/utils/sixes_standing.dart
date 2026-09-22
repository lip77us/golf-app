/// utils/sixes_standing.dart
/// -------------------------
/// What the standing ribbon says on a casual Sixes round.
///
/// Sixes is the first screen to carry D2, and it is a good first one because
/// it is the awkward case: **the pairings rotate every six holes**, so "your
/// side" is not a fixed thing the way it is in a Nassau. The reader is on team
/// 1 in one segment and team 2 in the next, and a standing computed from team
/// 1's point of view would be right a third of the time.
///
/// Two figures, per the design's casual-money row — `1 DOWN · +$10 so far`:
///
///   * **the standing** is the segment being PLAYED, from the reader's side.
///     Not the segment tally: a golfer on the fourth hole of match two is
///     asking how match two is going, and "1–0 up on segments" is the thing
///     the leaderboard is for.
///   * **the money** is what is SETTLED — decided segments only, straight off
///     the engine's own per-segment settlement. A segment in progress
///     contributes nothing, which is what lets the row say `so far` and mean
///     it rather than forecasting a match that could still turn.
///
/// Pure, so both rules are testable without a widget: the rotation is the part
/// that is easy to get subtly wrong and impossible to see in a screenshot.
library;

import '../api/models.dart';

/// The two strings the ribbon draws, or null when there is nothing to say yet.
class SixesStanding {
  /// `2 UP`, `1 DOWN`, `ALL SQUARE` — the live segment, reader-relative.
  final String standing;

  /// `+$10 so far`, `−$5 so far`, or `Even so far`.
  final String figure;

  const SixesStanding(this.standing, this.figure);
}

/// Which side of a segment the reader is on — 1, 2, or null when he is in
/// neither (a watcher, or a pairing not yet drawn).
int? readerTeamIn(SixesSegment segment, int playerId) {
  if (segment.team1.playerIds.contains(playerId)) return 1;
  if (segment.team2.playerIds.contains(playerId)) return 2;
  return null;
}

/// The segment the group is standing in, or the last one that was played.
///
/// **In progress first, then the last one with holes in it.** Between
/// segments — the draw is up but nobody has teed off — the honest answer is
/// the match just finished rather than a match with no holes, which would
/// read `ALL SQUARE` about golf nobody has played.
SixesSegment? liveSegment(SixesSummary summary) {
  final real = summary.segments.where((s) => !s.isExtra).toList();
  for (final s in real) {
    if (s.status == 'in_progress') return s;
  }
  for (final s in real.reversed) {
    if (s.holes.any((h) => h.winner != null)) return s;
  }
  return null;
}

String _money(double v) {
  if (v.abs() < 0.005) return 'Even so far';
  // U+2212, not a hyphen: beside a `+` at this size the hyphen is visibly the
  // wrong length, and the two appear within a few characters of each other.
  final sign = v > 0 ? '+' : '−';
  final n = v.abs();
  final amount = n == n.roundToDouble() ? n.toStringAsFixed(0)
                                        : n.toStringAsFixed(2);
  return '$sign\$$amount so far';
}

/// The ribbon's two strings for this reader, or null when the round has not
/// said anything yet.
SixesStanding? sixesStanding(SixesSummary? summary, int? playerId) {
  if (summary == null || playerId == null) return null;

  final money = _money(summary.moneyByPlayer[playerId] ?? 0);

  final segment = liveSegment(summary);
  if (segment == null) return null;
  final side = readerTeamIn(segment, playerId);
  if (side == null) return null;

  final played = segment.holes.where((h) => h.winner != null).toList();
  if (played.isEmpty) return null;

  // `margin` is written from team 1's side, so the reader's is the same number
  // negated when he is on team 2. This is the whole reason this file exists.
  final margin = played.last.margin * (side == 1 ? 1 : -1);

  final String standing;
  if (margin == 0) {
    standing = 'ALL SQUARE';
  } else if (segment.status == 'complete' || segment.status == 'halved') {
    // A decided segment reports the RESULT, not a running margin — `2 UP` on
    // a match that is over reads as a match still to play.
    standing = margin > 0 ? 'WON ${margin.abs()} UP' : 'LOST ${margin.abs()}';
  } else {
    standing = margin > 0 ? '${margin.abs()} UP' : '${margin.abs()} DOWN';
  }
  return SixesStanding(standing, money);
}
