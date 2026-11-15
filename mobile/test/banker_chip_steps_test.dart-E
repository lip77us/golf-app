/// test/banker_chip_steps_test.dart
/// -------------------------------
/// The bet chips on the Banker play screen.
///
/// They are chips rather than a stepper because a hole maximum is one of four
/// or five habitual numbers, and a stepper invites a $17 bet nobody wants to
/// settle. That only holds if the numbers offered ARE habitual — the first
/// implementation interpolated quarters and rounded to multiples of five,
/// which quietly offered a single chip on a $1–$4 band.
library;

import 'package:flutter_test/flutter_test.dart';

const _ladder = [1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200];

/// Mirrors `_BankerScreenState._chipSteps`. Kept here rather than reached into
/// because the rule is worth pinning on its own — the screen is a `State`.
List<double> chipSteps(double lo, double hi) {
  if (hi <= lo) return [lo];
  final vals = <double>{lo, hi};
  for (final v in _ladder) {
    if (v > lo && v < hi) vals.add(v.toDouble());
  }
  final all = vals.toList()..sort();
  if (all.length <= 4) return all;
  final out = <double>{};
  for (var i = 0; i < 4; i++) {
    out.add(all[((i * (all.length - 1)) / 3).round()]);
  }
  return out.toList()..sort();
}

void main() {
  test('a dollar game gets dollar increments', () {
    expect(chipSteps(1, 5), [1, 2, 3, 5]);
  });

  test('the band that used to offer one chip now offers four', () {
    // $1–$4: every interpolated quarter rounded to 0 or 5, both outside the
    // band, and the whole set was filtered away to just the floor.
    expect(chipSteps(1, 4), [1, 2, 3, 4]);
  });

  test('a big band thins to four round numbers', () {
    expect(chipSteps(5, 50), [5, 15, 30, 50]);
  });

  test('both ends always survive', () {
    for (final band in [[1, 5], [1, 4], [5, 50], [10, 100], [2, 3], [25, 25]]) {
      final lo = band[0].toDouble(), hi = band[1].toDouble();
      final steps = chipSteps(lo, hi);
      expect(steps.first, lo, reason: 'floor missing from $band');
      expect(steps.last, hi, reason: 'ceiling missing from $band');
    }
  });

  test('never more than four, never zero', () {
    for (var lo = 1; lo <= 20; lo++) {
      for (var hi = lo; hi <= 200; hi += 7) {
        final steps = chipSteps(lo.toDouble(), hi.toDouble());
        expect(steps.length, inInclusiveRange(1, 4),
            reason: 'band \$$lo–\$$hi offered ${steps.length} chips');
        expect(steps.every((v) => v >= lo && v <= hi), isTrue,
            reason: 'band \$$lo–\$$hi strayed outside itself: $steps');
      }
    }
  });
}
