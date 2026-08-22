/// test/team_allowance_test.dart
/// ----------------------------
/// The client-side allowance must agree with services/team_handicap.py to the
/// last cent — the TD sees this figure while building teams and the server's
/// on the board afterwards, and a disagreement between them is the kind of bug
/// that only surfaces at the scoring table.
///
/// Every number here is the packet's own worked example.
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/team_allowance.dart';

void main() {
  group('scramble allowance — 25/20/15/10, lowest first', () {
    test('Pine: 6.15 rounds to 6', () {
      final a = scrambleAllowance([4, 8, 11, 19]);
      expect(a.lines.map((l) => l.strokes).toList(),
          ['1.00', '1.60', '1.65', '1.90']);
      expect(a.raw, '6.15');
      expect(a.rounded, 6);
    });

    test('Clay: 7.50 rounds UP to 8', () {
      final a = scrambleAllowance([6, 9, 14, 21]);
      expect(a.raw, '7.50');
      expect(a.rounded, 8);
    });

    test('Slate: 8.45 rounds to 8', () {
      expect(scrambleAllowance([5, 12, 16, 24]).rounded, 8);
    });

    test('rounding happens once, on the total', () {
      // Per contribution it would be 1 + 2 + 2 + 2 = 7 — a full stroke out.
      final a = scrambleAllowance([4, 8, 11, 19]);
      final perLine = a.lines
          .map((l) => (l.hundredths + 50) ~/ 100)
          .fold<int>(0, (x, y) => x + y);
      expect(perLine, 7);
      expect(a.rounded, 6);
    });

    test('the order is the rule, not the input order', () {
      expect(scrambleAllowance([19, 4, 11, 8]).rounded,
             scrambleAllowance([4, 8, 11, 19]).rounded);
      expect(scrambleAllowance([19, 4, 11, 8]).lines.map((l) => l.pct).toList(),
             [25, 20, 15, 10]);
    });

    test('an override applies one flat percentage', () {
      final a = scrambleAllowance([4, 8, 11, 19], overridePct: 20);
      expect(a.lines.every((l) => l.pct == 20), isTrue);
      expect(a.raw, '8.40');
    });
  });

  group('the phantom 4th', () {
    test('is the average of the three real men', () {
      expect(phantomCourseHandicap([9, 15, 23]), 16);
      expect(phantomCourseHandicap([9, 15, 21]), 15);   // 15.0
      expect(phantomCourseHandicap([9, 15, 22]), 15);   // 15.33
    });

    test('Dune plays off 10, and the phantom sorts into third', () {
      final ph = phantomCourseHandicap([9, 15, 23]);
      final a  = scrambleAllowance([9, 15, 23], phantomHandicap: ph);
      expect(a.lines.map((l) => (l.courseHandicap, l.pct, l.strokes)).toList(),
          [(9, 25, '2.25'), (15, 20, '3.00'), (16, 15, '2.40'),
           (23, 10, '2.30')]);
      expect(a.raw, '9.95');
      expect(a.rounded, 10);
      expect(a.lines[2].isPhantom, isTrue);
    });

    test('fewer balls must never mean fewer strokes', () {
      final withPhantom = scrambleAllowance(
          [9, 15, 23], phantomHandicap: phantomCourseHandicap([9, 15, 23]));
      final threeManTable = scrambleAllowance([9, 15, 23]);
      expect(withPhantom.rounded, 10);
      expect(threeManTable.rounded, 9);
      expect(withPhantom.rounded, greaterThan(threeManTable.rounded));
    });
  });

  group('shamble', () {
    test('the percentage tracks the ball count', () {
      expect(shambleAllowancePct(1), 75);
      expect(shambleAllowancePct(2), 85);
      expect(shambleAllowancePct(3), 95);
    });

    test('an average of 2.3 gets 95, not 85', () {
      expect(shambleAllowancePct(2.3), 95);
      expect(shambleAllowancePct(1.5), 85);
    });
  });

  group('ball counts', () {
    final pars = {for (var h = 1; h <= 18; h++) h: 4};

    test('escalating is one, two, three by sixes', () {
      final c = resolveBallCounts(
          mode: 'escalating', fixed: 2, perHole: {}, parByHole: pars);
      expect(ballCountRuns(c), [(1, 6, 1), (7, 12, 2), (13, 18, 3)]);
    });

    test('fixed at 2 and escalating both total 36', () {
      int total(Map<int, int> c) => c.values.fold(0, (a, b) => a + b);
      expect(total(resolveBallCounts(
          mode: 'fixed', fixed: 2, perHole: {}, parByHole: pars)), 36);
      expect(total(resolveBallCounts(
          mode: 'escalating', fixed: 2, perHole: {}, parByHole: pars)), 36);
    });

    test('par-based reads the card', () {
      final mixed = {...pars, 3: 3, 4: 5};
      final c = resolveBallCounts(
          mode: 'par_based', fixed: 2, perHole: {}, parByHole: mixed);
      expect(c[3], 3);   // par 3 → 3 balls
      expect(c[4], 1);   // par 5 → 1 ball
      expect(c[1], 2);   // par 4 → 2 balls
    });
  });
}
