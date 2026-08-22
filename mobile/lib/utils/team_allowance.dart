/// utils/team_allowance.dart
/// ------------------------
/// The Team Play allowance, computed on the client so the build-teams screen
/// can show a team's figure move as the TD assigns men to it.
///
/// **`services/team_handicap.py` is the source of truth.** The server
/// recomputes every figure and the board reads its answer; this exists only so
/// the screen is not blind while the teams are still being built, which is the
/// whole argument for that screen — a hand-built scramble is unbalanced by
/// accident and normally discovered on the leaderboard.
///
/// Arithmetic is in HUNDREDTHS of a stroke, as integers, for the same reason
/// the Python side uses Decimal: an integer course handicap times an integer
/// percentage is exact at two places, and floating point is not.
///
/// The three rules (docs/design-review/handoff-team-play/SPEC.md §6):
///   1. Round ONCE, on the total. Rounding each contribution first turns
///      1.00 + 1.60 + 1.65 + 1.90 into 7; rounding the sum gives 6.
///   2. Half rounds up. 7.50 → 8.
///   3. Whole strokes, never fractions — which makes ties normal.
library;

/// Lowest handicap first. The order IS the rule: 25% attaches to the lowest
/// handicap, not to the captain or the first name on the list.
const List<int> kScrambleTable = [25, 20, 15, 10];

/// The shamble percentage follows the ball-count average — the fewer balls
/// that count, the lower the percentage.
const Map<int, int> kShamblePctByBalls = {1: 75, 2: 85, 3: 95, 4: 100};

/// One man's line on the worked card.
class AllowanceLine {
  final int  courseHandicap;
  final int  pct;
  /// Hundredths of a stroke — 160 is `1.60`.
  final int  hundredths;
  final bool isPhantom;

  const AllowanceLine({
    required this.courseHandicap,
    required this.pct,
    required this.hundredths,
    this.isPhantom = false,
  });

  /// `1.60` — always two places, because `1.6` next to `1.65` reads as a typo.
  String get strokes => (hundredths / 100).toStringAsFixed(2);
}

/// The two numbers a TD needs: the one he plays with, and the one that
/// explains it.
class TeamAllowanceResult {
  final int rounded;
  final int rawHundredths;
  final List<AllowanceLine> lines;

  const TeamAllowanceResult({
    required this.rounded,
    required this.rawHundredths,
    required this.lines,
  });

  String get raw => (rawHundredths / 100).toStringAsFixed(2);
}

/// Half up — Clay's 7.50 becomes 8. Dart's `round()` rounds half AWAY from
/// zero, which agrees for positives, but the intent is stated rather than
/// inherited.
int _roundHalfUp(int hundredths) => (hundredths + 50) ~/ 100;

/// A three-man team fields a phantom 4th at the AVERAGE of its three real men.
/// Bellini 9, Kwan 15, Ortega 23 → 16.
///
/// Four handicaps, so the ordinary table applies with no special three-man
/// row. Dropping the table's bottom row instead would give 9 — a stroke TAKEN
/// from a team already short a ball, which is backwards. The allowance follows
/// the roster, not the number of balls hit.
int phantomCourseHandicap(List<int> realHandicaps) {
  if (realHandicaps.isEmpty) return 0;
  final sum = realHandicaps.fold<int>(0, (a, b) => a + b);
  final n   = realHandicaps.length;
  // Half up on sum/n, in integers: (2·sum + n) ~/ (2·n).
  return (2 * sum + n) ~/ (2 * n);
}

/// 25 / 20 / 15 / 10 of course handicap, lowest first, summed.
///
/// [phantomHandicap] is the phantom's figure when the team plays three; it
/// sorts into the order like anyone else and takes its percentage like anyone
/// else.
TeamAllowanceResult scrambleAllowance(
  List<int> courseHandicaps, {
  int? overridePct,
  int? phantomHandicap,
}) {
  final entries = <(int, bool)>[
    for (final h in courseHandicaps) (h, false),
    if (phantomHandicap != null) (phantomHandicap, true),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  final lines = <AllowanceLine>[];
  for (var i = 0; i < entries.length; i++) {
    final pct = overridePct ??
        (i < kScrambleTable.length ? kScrambleTable[i] : 0);
    lines.add(AllowanceLine(
      courseHandicap: entries[i].$1,
      pct           : pct,
      hundredths    : entries[i].$1 * pct,
      isPhantom     : entries[i].$2,
    ));
  }

  final raw = lines.fold<int>(0, (a, l) => a + l.hundredths);
  return TeamAllowanceResult(
    rounded: _roundHalfUp(raw), rawHundredths: raw, lines: lines);
}

/// A ceiling, not a round-to-nearest: a grid averaging 2.3 asks for three
/// balls somewhere, so it takes 95% rather than 85%.
int shambleAllowancePct(double avgBallCount) {
  if (avgBallCount <= 0) return 85;
  final balls = avgBallCount.ceil().clamp(1, 4);
  return kShamblePctByBalls[balls] ?? 85;
}

/// A shamble handicaps each golfer on his own ball, so the figure this returns
/// is a BALANCE number only — the sum of the four allowances, for the strip
/// that shows one team against another. It is never subtracted from anything.
TeamAllowanceResult shambleAllowance(
  List<int> courseHandicaps, {
  double avgBallCount = 2,
  int? overridePct,
  int? phantomHandicap,
}) {
  final pct = overridePct ?? shambleAllowancePct(avgBallCount);
  final all = [
    ...courseHandicaps.map((h) => (h, false)),
    if (phantomHandicap != null) (phantomHandicap, true),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  final lines = [
    for (final e in all)
      AllowanceLine(courseHandicap: e.$1, pct: pct,
                    hundredths: e.$1 * pct, isPhantom: e.$2),
  ];
  final raw = lines.fold<int>(0, (a, l) => a + l.hundredths);
  return TeamAllowanceResult(
    rounded: _roundHalfUp(raw), rawHundredths: raw, lines: lines);
}

/// `{hole: balls}` for all eighteen, whatever mode the TD picked — the same
/// resolution the server does, so the preview and the card agree.
Map<int, int> resolveBallCounts({
  required String mode,
  required int fixed,
  required Map<int, int> perHole,
  required Map<int, int> parByHole,
}) {
  final holes = parByHole.keys.toList()..sort();
  switch (mode) {
    case 'escalating':
      return {for (final h in holes) h: h <= 6 ? 1 : (h <= 12 ? 2 : 3)};
    case 'par_based':
      return {
        for (final h in holes) h: const {3: 3, 4: 2, 5: 1}[parByHole[h]] ?? 1,
      };
    case 'per_hole':
      return {for (final h in holes) h: perHole[h] ?? fixed};
    default:
      return {for (final h in holes) h: fixed};
  }
}

/// The preview, collapsed into runs — the check that catches a per-hole grid
/// accidentally left at all 2s.
List<(int, int, int)> ballCountRuns(Map<int, int> counts) {
  final runs = <(int, int, int)>[];
  for (final hole in counts.keys.toList()..sort()) {
    final n = counts[hole]!;
    if (runs.isNotEmpty && runs.last.$3 == n && runs.last.$2 == hole - 1) {
      runs[runs.length - 1] = (runs.last.$1, hole, n);
    } else {
      runs.add((hole, hole, n));
    }
  }
  return runs;
}
