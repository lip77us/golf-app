import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/nine_totals.dart';

void main() {
  const cellW = 34.0, sumW = 34.0;
  final full = List.generate(18, (i) => i + 1);

  group('a full round', () {
    final s = NineSplit.of(full);
    test('splits at the turn', () {
      expect(s.front.length, 9);
      expect(s.back.length, 9);
      expect(s.count, 3);
    });
    test('the content is the holes plus the three summary columns', () {
      expect(s.contentWidth(cellW, sumW), 18 * cellW + 3 * sumW);
    });
    test('a front-nine hole ignores the summary columns', () {
      expect(s.rightEdgeOf(1, cellW, sumW), cellW);
      expect(s.rightEdgeOf(9, cellW, sumW), 9 * cellW);
    });
    test('a back-nine hole counts the OUT column before it', () {
      // Hole 10 is the 10th cell, but OUT sits between it and the front nine.
      expect(s.rightEdgeOf(10, cellW, sumW), 9 * cellW + sumW + cellW);
    });
    test('a hole not in play has no edge', () {
      expect(s.rightEdgeOf(99, cellW, sumW), isNull);
    });
  });

  group('a back-nine round', () {
    final s = NineSplit.of(List.generate(9, (i) => i + 10));
    test('has IN and nothing else — an OUT could only ever be blank', () {
      expect(s.showOut, isFalse);
      expect(s.showIn, isTrue);
      expect(s.showTot, isFalse);
      expect(s.count, 1);
    });
    test('and its first hole is the first cell', () {
      expect(s.rightEdgeOf(10, cellW, sumW), cellW);
    });
  });

  group('a front-nine round', () {
    final s = NineSplit.of(List.generate(9, (i) => i + 1));
    test('has OUT and no TOT — there is nothing to total it with', () {
      expect(s.showOut, isTrue);
      expect(s.showIn, isFalse);
      expect(s.showTot, isFalse);
    });
  });

  test('a shotgun round still splits by hole NUMBER, not play order', () {
    // Starting on the 7th: play order is 7..18 then 1..6.
    final order = [...List.generate(12, (i) => i + 7), ...List.generate(6, (i) => i + 1)];
    final s = NineSplit.of(order);
    expect(s.front, [7, 8, 9, 1, 2, 3, 4, 5, 6]);
    expect(s.back.first, 10);
    expect(s.count, 3);
  });
}
