/// utils/team_allowance.dart
/// ------------------------
/// The Team Play allowance, computed on the client so the build-teams screen
/// can show a team's figure move as the TD assigns golfers to it.
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

/// The pairs tables — low handicap first
/// (docs/design-review/handoff-team-pairs/SPEC.md §4).
///
/// **The allowance is doing enormous work here.** The same pair — Maiolini 4,
/// Yau 19 — plays off 4 in a scramble and 12 in an alternate shot. Three times
/// the strokes for the same two golfers, purely from the format, which is why the
/// format screen prints the figure on EVERY option before it is chosen.
///
/// Scotch and Chapman share a table, and that is the honest answer rather than
/// a manufactured difference: both are two drives then one ball, and Chapman
/// buys one extra shot of position, which is not worth a stroke.
///
/// 50% low + 50% high IS 50% of the combined, so alternate shot needs no
/// special case — it is a positional table like the rest.
const Map<String, List<int>> kPairsTables = {
  'scramble'      : [35, 15],
  'alternate_shot': [50, 50],
  'scotch'        : [60, 40],
  'chapman'       : [60, 40],
};

/// Best ball is the ONE pairs format whose allowance is per golfer: each golfer
/// plays their own strokes at 85% and the better net counts. The card reads
/// `3 / 16`, not one figure.
const int kBestBallPct = 85;

/// The formats each team size may play. `scramble` is the only one both run,
/// and its table is NOT shared — four golfers take 25/20/15/10 and two take 35/15.
const Map<int, List<String>> kFormatsBySize = {
  4: ['scramble', 'shamble'],
  2: ['scramble', 'best_ball', 'alternate_shot', 'scotch', 'chapman'],
};

/// Display names, so nothing in the UI spells `alternate_shot` by hand.
const Map<String, String> kTeamFormatNames = {
  'scramble'      : 'Scramble',
  'shamble'       : 'Shamble',
  'best_ball'     : 'Best ball',
  'alternate_shot': 'Alternate shot',
  'scotch'        : 'Scotch',
  'chapman'       : 'Chapman',
};

/// True for the four pair formats that end in one ball. They take the
/// scramble's one-number card; best ball is the only pairs format entering two
/// scores.
bool playsOneBall(String format) =>
    format == 'scramble' || format == 'alternate_shot' ||
    format == 'scotch'   || format == 'chapman';

/// The drive rules a format may use — mirrors
/// `TeamPlayConfig.drive_rules_allowed`.
///
/// The tee-shot control does three different jobs, and the FORMAT picks which:
///
///   * **A record** — scramble, either size. Compliance against a quota.
///   * **An instruction** — Scotch. The pick says who hits next, so the tap
///     happens every hole and a quota is available on top, off by default.
///   * **A rota** — alternate shot. Odd/even, set on the 1st tee, fixed for
///     eighteen. Not a quota: nothing to fall short of.
///   * **Absent** — best ball and Chapman. Both golfers drive every hole with no
///     choice to record.
///
/// Alternating pairs stays a FOURS rule: two golfers have no pairs to alternate,
/// and their alternate-shot rota is the `alternate_shot` format's own schedule.
List<String> driveRulesFor(int teamSize, String format) {
  if (format == 'best_ball' || format == 'chapman') return const ['none'];
  if (format == 'alternate_shot') return const ['alternating'];
  if (teamSize == 2) return const ['none', 'per_nine', 'per_eighteen'];
  return const ['none', 'per_nine', 'per_eighteen', 'alternating'];
}

/// Whether the wizard shows a Drives step at all.
///
/// **A step with nothing to set is not a step.** In best ball and Chapman both
/// golfers drive every hole, so there is no drive to choose, no quota to count and
/// no penalty to apply — the page's whole content was a note saying so, which
/// is a worse way to say it than not asking.
///
/// Alternate shot keeps its step despite having no control either: the rota is
/// a real thing that happens on the course — the pair sets it on the 1st tee
/// and the card names the tee for eighteen holes — and the step is the only
/// place the TD is told it is coming. The line is whether something happens,
/// not whether there is a widget.
bool hasDriveStep(int teamSize, String format) {
  final rules = driveRulesFor(teamSize, format);
  return !(rules.length == 1 && rules.first == 'none');
}

/// The most drives one golfer can be asked for in a window: the window's holes
/// divided between the golfers. Mirrors `TeamPlayConfig.max_drives_per_golfer`.
///
/// Four golfers sharing nine holes top out at two each, and four each across
/// eighteen. **Two golfers sharing the same nine top out at four each**, and nine
/// each across eighteen — every hole spoken for, nothing left over.
int maxDrivesPerGolfer(int teamSize, String driveRule) {
  final holes = driveRule == 'per_nine' ? 9 : 18;
  return (holes ~/ (teamSize < 1 ? 1 : teamSize)).clamp(1, 18);
}

/// One golfer's line on the worked card.
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

/// The two numbers a TD needs: the one they play with, and the one that
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

/// A team of three fields a phantom 4th at the AVERAGE of its three real golfers.
/// Bellini 9, Kwan 15, Ortega 23 → 16.
///
/// Four handicaps, so the ordinary table applies with no special three-golfer
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

/// A positional table applied to a roster — the arithmetic behind every format
/// that ends in one ball, at either size.
TeamAllowanceResult positionalAllowance(
  List<int> courseHandicaps,
  List<int> table, {
  int? overridePct,
  int? phantomHandicap,
}) {
  final entries = <(int, bool)>[
    for (final h in courseHandicaps) (h, false),
    if (phantomHandicap != null) (phantomHandicap, true),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  final lines = <AllowanceLine>[];
  for (var i = 0; i < entries.length; i++) {
    final pct = overridePct ?? (i < table.length ? table[i] : 0);
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

/// The team's figure for any (size, format) pair — what the format step prints
/// on every option, and what the handicap step works on the TD's own teams.
///
/// Returns a balance figure for the own-ball formats (shamble, best ball),
/// where the strokes belong to golfers and the sum only stacks one team
/// against another.
TeamAllowanceResult teamAllowanceFor({
  required int teamSize,
  required String format,
  required List<int> courseHandicaps,
  double avgBallCount = 2,
  int? overridePct,
  int? phantomHandicap,
}) {
  if (format == 'best_ball') {
    return positionalAllowance(
      courseHandicaps,
      List.filled(courseHandicaps.length, overridePct ?? kBestBallPct),
      phantomHandicap: null,
    );
  }
  if (teamSize == 2) {
    return positionalAllowance(
      courseHandicaps, kPairsTables[format] ?? kPairsTables['scramble']!,
      overridePct: overridePct);
  }
  if (format == 'shamble') {
    return shambleAllowance(courseHandicaps,
        avgBallCount: avgBallCount, overridePct: overridePct,
        phantomHandicap: phantomHandicap);
  }
  return scrambleAllowance(courseHandicaps,
      overridePct: overridePct, phantomHandicap: phantomHandicap);
}

/// One golfer's whole-stroke figure when they play their own ball — shamble and
/// best ball alike. Rounded PER GOLFER, unlike a team total, because it is the
/// number they play with.
int playerOwnBallHandicap(int courseHandicap, int pct) =>
    _roundHalfUp(courseHandicap * pct);

/// A ceiling, not a round-to-nearest: a grid averaging 2.3 asks for three
/// balls somewhere, so it takes 95% rather than 85%.
int shambleAllowancePct(double avgBallCount) {
  if (avgBallCount <= 0) return 85;
  final balls = avgBallCount.ceil().clamp(1, 4);
  return kShamblePctByBalls[balls] ?? 85;
}

/// A shamble handicaps each golfer on their own ball, so the figure this returns
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
