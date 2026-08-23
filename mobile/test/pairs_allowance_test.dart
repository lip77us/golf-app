/// test/pairs_allowance_test.dart
/// ------------------------------
/// The pairs allowance, computed on the client so the format and handicap
/// steps are not blind while the field is still being built
/// (docs/design-review/handoff-team-pairs/SPEC.md §4).
///
/// `services/team_handicap.py` is the source of truth and the server recomputes
/// every figure — these tests exist so the two never drift, because a figure
/// that changes when the round is created is worse than no figure at all.
///
/// **The finding under test is that the allowance is doing enormous work.**
/// The same pair — Maiolini 4, Yau 19 — plays off 4 in a scramble and 12 in an
/// alternate shot. Three times the strokes for the same two men, purely from
/// the format, which is why the format step prints the figure on every option
/// before it is chosen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/grouping.dart';
import 'package:golf_mobile/utils/team_allowance.dart';

int _pairFigure(String format, List<int> hcaps) =>
    teamAllowanceFor(teamSize: 2, format: format, courseHandicaps: hcaps)
        .rounded;

void main() {
  const pair = [4, 19];   // Maiolini and Yau

  group('the five pairs formats', () {
    test('scramble — 35% low + 15% high', () {
      final a = teamAllowanceFor(
          teamSize: 2, format: 'scramble', courseHandicaps: pair);
      expect(a.raw, '4.25');
      expect(a.rounded, 4);
      expect(a.lines.map((l) => l.pct), [35, 15]);
    });

    test('alternate shot — 50% of the combined, half rounding UP', () {
      final a = teamAllowanceFor(
          teamSize: 2, format: 'alternate_shot', courseHandicaps: pair);
      expect(a.raw, '11.50');
      expect(a.rounded, 12);
    });

    test('scotch — 60% low + 40% high', () {
      expect(_pairFigure('scotch', pair), 10);
    });

    test('chapman shares scotch\'s table', () {
      // Both are two drives then one ball. Chapman buys one extra shot of
      // position, which is not worth a stroke — the honest answer rather than
      // a manufactured difference.
      expect(kPairsTables['chapman'], kPairsTables['scotch']);
      expect(_pairFigure('chapman', pair), 10);
    });

    test('best ball is per golfer — 3 / 16, not one figure', () {
      expect(playerOwnBallHandicap(4, kBestBallPct), 3);
      expect(playerOwnBallHandicap(19, kBestBallPct), 16);
    });

    test('the format alone triples the strokes', () {
      expect(_pairFigure('alternate_shot', pair),
             3 * _pairFigure('scramble', pair));
    });
  });

  group('the three arithmetic rules', () {
    test('rounded once, on the total', () {
      // 3.15 + 3.45 = 6.60 → 7. Rounding each contribution first gives 6.
      final a = teamAllowanceFor(
          teamSize: 2, format: 'scramble', courseHandicaps: [9, 23]);
      expect(a.raw, '6.60');
      expect(a.rounded, 7);
    });

    test('half rounds up', () {
      expect(_pairFigure('alternate_shot', [4, 19]), 12);   // 11.50
    });

    test('the table is positional, not roster order', () {
      expect(_pairFigure('scramble', [19, 4]),
             _pairFigure('scramble', [4, 19]));
      final a = teamAllowanceFor(
          teamSize: 2, format: 'scramble', courseHandicaps: [19, 4]);
      expect(a.lines.map((l) => l.courseHandicap), [4, 19]);
    });

    test('an override applies one flat percentage to both men', () {
      final a = teamAllowanceFor(
          teamSize: 2, format: 'scramble', courseHandicaps: pair,
          overridePct: 50);
      expect(a.raw, '11.50');
      expect(a.lines.map((l) => l.pct), [50, 50]);
    });
  });

  group('the six pairs on the build screen', () {
    const field = [
      ('Maiolini & Yau',    [4, 19],  '4.25', 4),
      ('Petersen & Reilly', [6, 21],  '5.25', 5),
      ('Mercer & Vaughn',   [5, 24],  '5.35', 5),
      ('Morgan & Lipkin',   [7, 20],  '5.45', 5),
      ('Ferraro & Nunes',   [3, 22],  '4.35', 4),
      ('Bellini & Ortega',  [9, 23],  '6.60', 7),
    ];

    test('every drawn pair reproduces', () {
      for (final (name, hcaps, raw, rounded) in field) {
        final a = teamAllowanceFor(
            teamSize: 2, format: 'scramble', courseHandicaps: hcaps);
        expect(a.raw, raw, reason: name);
        expect(a.rounded, rounded, reason: name);
      }
    });

    test('the balance strip reads 4 to 7', () {
      final figures = [
        for (final (_, hcaps, __, ___) in field)
          _pairFigure('scramble', hcaps),
      ]..sort();
      expect(figures.first, 4);
      expect(figures.last, 7);
    });

    test('two handicaps do not average out the way four do', () {
      // The argument for keeping the balance strip: three strokes apart on a
      // card the field will finish inside six.
      expect(_pairFigure('scramble', [3, 22]), 4);
      expect(_pairFigure('scramble', [9, 23]), 7);
    });
  });

  group('the size decides the table', () {
    test('scramble is the one format both sizes run, and it is NOT shared', () {
      expect(kFormatsBySize[4], contains('scramble'));
      expect(kFormatsBySize[2], contains('scramble'));
      expect(kScrambleTable, isNot(kPairsTables['scramble']));
      // Four men: Pine 6.15 → 6. Two men on the same low handicaps: a
      // different table entirely.
      expect(teamAllowanceFor(
          teamSize: 4, format: 'scramble',
          courseHandicaps: [4, 8, 11, 19]).rounded, 6);
    });

    test('a foursome scramble is untouched by any of this', () {
      expect(teamAllowanceFor(
          teamSize: 4, format: 'scramble',
          courseHandicaps: [6, 9, 14, 21]).rounded, 8);   // Clay, 7.50 → 8
    });

    test('four of the five pairs formats end in one ball', () {
      expect(kFormatsBySize[2]!.where(playsOneBall).length, 4);
      expect(playsOneBall('best_ball'), isFalse);
    });
  });

  group('a pairs field is twos, and the odd man stays visible', () {
    test('an even field pairs cleanly', () {
      expect(pairSizes(12), [2, 2, 2, 2, 2, 2]);
    });

    test('an odd field leaves a group of one', () {
      // Left visible on purpose: there is no phantom partner to hide him
      // behind, and the block has to name him.
      expect(pairSizes(13), [2, 2, 2, 2, 2, 2, 1]);
    });

    test('an empty field is empty', () {
      expect(pairSizes(0), isEmpty);
    });
  });

  group('two pairs share a playing group', () {
    // A pair is the SCORING unit; it is not the group that walks the course.
    // Two pairs go off each tee time as a foursome, share one scorer and one
    // card, and are scored apart.
    test('six golfers are two groups, not three', () {
      expect(pairPlayGroupSizes(6), [4, 2]);
    });

    test('twelve golfers are three groups of four', () {
      expect(pairPlayGroupSizes(12), [4, 4, 4]);
    });

    test('an odd number of PAIRS leaves a twosome on the end', () {
      expect(pairPlayGroupSizes(10), [4, 4, 2]);
    });

    test('an odd FIELD still leaves the unpaired man visible', () {
      expect(pairPlayGroupSizes(13), [4, 4, 4, 1]);
    });

    test('a group splits into its pairs by position', () {
      expect(splitIntoPairs([1, 2, 3, 4]), [[1, 2], [3, 4]]);
      expect(splitIntoPairs([1, 2]), [[1, 2]]);
    });

    test('three men in best ball are ONE team, not a pair and a spare', () {
      expect(splitIntoPairs([1, 2, 3], bestBall: true), [[1, 2, 3]]);
      expect(splitIntoPairs([1, 2, 3]), [[1, 2], [3]]);
    });
  });

  group('a pair is complete at two — nothing pads it', () {
    // The review step labelled a finished pair "+ 1 phantom" for being two
    // men, because "anything under four gets a phantom" was written out
    // longhand wherever groups are drawn.
    test('a pair never gets a phantom, at any roster size', () {
      expect(groupNeedsPhantom(2, teamPlaySize: 2), isFalse);
      expect(groupNeedsPhantom(3, teamPlaySize: 2), isFalse);
      // Even a golfer with no partner: that is a problem to fix, named on the
      // Handicap step, not a gap to pad with an imaginary man.
      expect(groupNeedsPhantom(1, teamPlaySize: 2), isFalse);
    });

    test('a foursome still fields a phantom 4th', () {
      expect(groupNeedsPhantom(3, teamPlaySize: 4), isTrue);
      expect(groupNeedsPhantom(4, teamPlaySize: 4), isFalse);
    });

    test('every other shape fills to four, unchanged', () {
      expect(groupNeedsPhantom(3), isTrue);
      expect(groupNeedsPhantom(4), isFalse);
    });
  });
}
