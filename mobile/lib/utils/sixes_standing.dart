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
///     the leaderboard is for. It carries `thru N` because Sixes cuts the
///     round into six-hole matches and can add EXTRA ones, so the hole number
///     in the header does not say how far into THIS match he is.
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
  /// `2 UP thru 4`, `ALL SQUARE thru 1`, `WON 3 AND 2` — the live segment,
  /// reader-relative, with how far into the MATCH he is.
  final String standing;

  /// `+$10 so far` / `−$5 so far`, or **empty until a segment settles.**
  ///
  /// It was `Even so far`, which is true and reads as a contradiction: the
  /// row said `1 UP · Even so far` on the second hole, and a golfer who is one
  /// up does not think of himself as even. Sixes settles per SEGMENT, so
  /// through the first six holes there is genuinely no money to report — and
  /// saying nothing is the honest version of that. The 💰 icon still marks it
  /// as a money game.
  final String figure;

  /// Which side the reader is on in the live segment — 1 or 2.
  ///
  /// The row wears his team's colour because **the pairings rotate every six
  /// holes**: it is the one screen element that can say which side he is on
  /// this match without spending a word on it, and it matches the blue and
  /// orange bars already on the player rows below.
  final int team;

  const SixesStanding(this.standing, this.figure, this.team);
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
  // **Nothing settled says nothing.** See `SixesStanding.figure`.
  if (v.abs() < 0.005) return '';
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

  // **`thru N` rides the standing.** Sixes cuts the round into six-hole
  // matches and can add EXTRA segments, so the hole number in the header does
  // not tell a golfer how far into the match he is — `1 UP` on its own leaves
  // him counting backwards to work out how many holes are left to play it in.
  // N is holes played in THIS match, not on the course.
  final thru = played.length;

  final String standing;
  if (segment.status == 'complete' || segment.status == 'halved') {
    // A decided segment reports the RESULT, not a running margin — `2 UP` on
    // a match that is over reads as a match still to play. Early close-outs
    // take golf's own notation, so `3 AND 2` rather than `3 UP thru 4`.
    final left = segment.totalHoles - thru;
    if (margin == 0) {
      standing = 'HALVED';
    } else {
      final verb = margin > 0 ? 'WON' : 'LOST';
      standing = left > 0
          ? '$verb ${margin.abs()} AND $left'
          : '$verb ${margin.abs()} UP';
    }
  } else if (margin == 0) {
    standing = 'ALL SQUARE thru $thru';
  } else {
    standing = margin > 0
        ? '${margin.abs()} UP thru $thru'
        : '${margin.abs()} DOWN thru $thru';
  }
  return SixesStanding(standing, money, side);
}
