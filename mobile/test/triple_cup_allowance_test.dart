/// **What a Triple Cup segment is played off.**
///
/// Three formats, three allowances, and two different SHAPES of number:
/// four-ball and singles are a percentage of one player's handicap, alt-shot
/// is a share of the pair's combined. The app-bar badge can only carry the
/// first shape, which is why it never stated the alt-shot one — reported from
/// testing on 30 Sep, and this pins the wording that answers it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/triple_cup_allowance.dart';

String? note(String segment,
        {String mode = 'net',
        int fourball = 90,
        int singles = 100,
        int low = 50,
        int high = 50}) =>
    tripleCupAllowanceNote(
      mode: mode,
      segment: segment,
      fourballPercent: fourball,
      singlesPercent: singles,
      altShotLowPct: low,
      altShotHighPct: high,
    );

void main() {
  group('the alt-shot allowance', () {
    test('is stated as a share of the COMBINED handicap', () {
      expect(note('foursomes', low: 40, high: 40),
          '40% of the pair’s combined handicap');
    });

    test('equal weights are the percentage, never their sum', () {
      // 40 + 40 is 40% of combined — the same thing as 80% of half. Adding
      // them would print 80% on the very setting this was built for.
      expect(note('foursomes', low: 40, high: 40), contains('40%'));
      expect(note('foursomes', low: 50, high: 50), contains('50%'));
      expect(note('foursomes', low: 40, high: 40), isNot(contains('80%')));
    });

    test('unequal weights are named separately, because no single % says it',
        () {
      expect(note('foursomes', low: 60, high: 0),
          '60% of the lower handicap + 0% of the higher');
    });
  });

  group('four-ball and singles', () {
    test('each report their own number', () {
      expect(note('fourball', fourball: 90, singles: 100), '90% of handicap');
      expect(note('singles', fourball: 90, singles: 100), '100% of handicap');
    });

    test('one does not move when the other does', () {
      expect(note('singles', fourball: 50, singles: 100),
          note('singles', fourball: 90, singles: 100));
    });

    test('strokes-off scales the DIFFERENTIAL, and says so', () {
      // "% of handicap" would describe a number nobody is playing off.
      expect(note('fourball', mode: 'strokes_off', fourball: 90),
          '90% of strokes off the low handicap');
    });
  });

  test('gross reports nothing — there is no allowance', () {
    for (final seg in ['fourball', 'foursomes', 'singles']) {
      expect(note(seg, mode: 'gross'), isNull);
    }
  });
}
