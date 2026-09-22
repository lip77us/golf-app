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

  /// Which side he is on — 1 or 2 — or **null when the colour would lie.**
  ///
  /// Colour is right while the standing is about the match whose teams are
  /// colouring the player rows: blue on the row and blue below are then the
  /// same two golfers. It is wrong for exactly one state — **the hole after a
  /// match concludes and the teams re-draw** — where the row still reports the
  /// match just finished while the rows below have already repaired. That is
  /// the state this is null for, and the names carry it alone.
  ///
  /// The rule went through three passes: coloured always (wrong between
  /// segments), dropped entirely (lost a true signal on every other hole),
  /// and now conditioned on the one thing that actually decides it.
  final int? team;

  const SixesStanding(this.standing, this.figure, this.team);
}

/// Which side of a segment the reader is on — 1, 2, or null when he is in
/// neither (a watcher, or a pairing not yet drawn).
int? readerTeamIn(SixesSegment segment, int playerId) {
  if (segment.team1.playerIds.contains(playerId)) return 1;
  if (segment.team2.playerIds.contains(playerId)) return 2;
  return null;
}

/// Which segment a given hole belongs to.
///
/// **By POSITION in play order**, so a wrapped shotgun segment (start 14 → end
/// 1) matches correctly; falls back to the hole-number range when the order is
/// unknown, which on a normal round is identical. Extras are checked first
/// because an extra segment's holes sit inside a regular one's range.
///
/// Shared rather than private to the score card: it is what colours the player
/// rows AND what tells the standing row whether its colour still means the
/// same thing, and those two must never disagree.
SixesSegment? segmentForHole(SixesSummary summary, int hole,
                             List<int> holesInPlay) {
  bool inSeg(SixesSegment s) {
    if (holesInPlay.isEmpty) return hole >= s.startHole && hole <= s.endHole;
    final sp = holesInPlay.indexOf(s.startHole);
    final ep = holesInPlay.indexOf(s.endHole);
    final hp = holesInPlay.indexOf(hole);
    if (sp < 0 || ep < 0 || hp < 0 || ep < sp) {
      return hole >= s.startHole && hole <= s.endHole;
    }
    return hp >= sp && hp <= ep;
  }

  for (final s in summary.segments) {
    if (s.isExtra && inSeg(s)) return s;
  }
  for (final s in summary.segments.where((s) => !s.isExtra).toList().reversed) {
    if (inSeg(s)) return s;
  }
  return null;
}

/// `Paul, Jim` — the app's short-name field, which is what the golfer set for
/// himself and what every other narrow surface in the app already shows.
/// Falls back to first names on an older payload that does not send it.
String pairNames(SixesTeamInfo team) {
  final short = team.playersShort.where((n) => n.trim().isNotEmpty).toList();
  if (short.isNotEmpty) return short.join(', ');
  return team.players
      .map((n) => n.trim().split(RegExp(r'\s+')).first)
      .where((n) => n.isNotEmpty)
      .join(', ');
}

bool _played(SixesSegment s) => s.holes.any((h) => h.winner != null);

/// The match the group is standing in, or the last one that was played.
///
/// **In progress first, then the last one with holes in it.** Between
/// segments — the draw is up but nobody has teed off — the honest answer is
/// the match just finished rather than a match with no holes, which would
/// read `all square` about golf nobody has played.
SixesSegment? liveSegment(SixesSummary summary) {
  final real = summary.segments.where((s) => !s.isExtra).toList();
  for (final s in real) {
    if (s.status == 'in_progress') return s;
  }
  for (final s in real.reversed) {
    if (_played(s)) return s;
  }
  return null;
}

/// **The match the row is about: the one the reader is LOOKING AT.**
///
/// Not the live one. Backing up to a hole in match 1 while match 2 is running
/// should report match 1 — the header, the player rows and the scores on
/// screen are all that match, and a standing row describing a different one is
/// the only thing on the screen disagreeing with the rest of it.
///
/// It falls back to the last match that was played when the hole on screen
/// belongs to one nobody has teed off in — which is the between-segments
/// case, on the hole after a match concludes.
SixesSegment? standingSegment(SixesSummary summary, SixesSegment? onScreen) {
  if (onScreen != null && _played(onScreen)) return onScreen;
  return liveSegment(summary);
}

/// `1UP` / `2DN` — tight and capitalised, the way a margin is written on a
/// card. Set against the lower-case words around it so the number reads as the
/// figure in the row rather than as part of the sentence.
String _margin(int m) => '${m.abs()}${m > 0 ? "UP" : "DN"}';

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
/// [onScreen] is the segment the score card is showing — the one whose teams
/// are colouring the player rows. It is what tells the standing whether its
/// own colour still means what those rows mean.
SixesStanding? sixesStanding(SixesSummary? summary, int? playerId,
                             {SixesSegment? onScreen}) {
  if (summary == null || playerId == null) return null;

  final money = _money(summary.moneyByPlayer[playerId] ?? 0);

  final segment = standingSegment(summary, onScreen);
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

  // **The row NAMES his pairing, on every state.**
  //
  // Colour cannot carry identity in this game: the teams repair every six
  // holes, so blue is a different pair of golfers in match two than it was in
  // match one. It broke first between segments — the row reported the match
  // just finished while the player rows had already repaired, so `WON 1 UP` in
  // blue credited a pair that had not won it — but the same reasoning applies
  // inside a segment, where a golfer reading a colour has to remember which
  // draw he is looking at. Names never need that.
  //
  // Always the READER's side, so the row is about him from end to end — the
  // money beside it is his, and the verb carries whether his pair won.
  final mine = side == 1 ? segment.team1 : segment.team2;
  final names = pairNames(mine);
  final prefix = names.isEmpty ? '' : '$names ';

  // A segment is identified by its hole RANGE: the objects are rebuilt on
  // every poll, so object identity would be false every time.
  final sameAsScreen = onScreen != null &&
      onScreen.startHole == segment.startHole &&
      onScreen.endHole == segment.endHole;

  final decided = segment.status == 'complete' || segment.status == 'halved';

  final String standing;
  if (decided) {
    // A decided segment reports the RESULT, not a running margin — `2 UP` on
    // a match that is over reads as a match still to play. Early close-outs
    // take golf's own notation, so `3 and 2` rather than `3 UP thru 4`.
    final left = segment.totalHoles - thru;
    // A close-out keeps golf's own `2 and 1`; a match played to the last hole
    // is `1UP`. Two notations because they are two different facts — one says
    // how many holes were left, the other that there were none.
    final result = left > 0 ? '${margin.abs()} and $left' : _margin(margin);
    standing = margin == 0
        ? '${prefix}halved'
        : '$prefix${margin > 0 ? "won" : "lost"} $result';
  } else if (margin == 0) {
    standing = '${prefix}all square thru $thru';
  } else {
    standing = '$prefix${_margin(margin)} thru $thru';
  }
  // **The money shows on the decision holes and nowhere else.** It only moves
  // when a match concludes, so a figure repeated under every live hole is
  // furniture — and `so far` beside a margin that is still moving invites
  // reading it as a forecast. It appears when it changed, beside the result
  // that changed it, and goes when the next match starts.
  return SixesStanding(standing, decided ? money : '',
                       sameAsScreen ? side : null);
}
