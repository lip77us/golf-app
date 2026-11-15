/// test/handicap_rounding_test.dart
/// -------------------------------
/// WHS Rule 6.1 rounding and the Net % scaling of a strokes-off differential,
/// on the client side.
///
/// Two drifts these lock down:
///
///   1. Dart's `num.round()` rounds half AWAY FROM ZERO while Python's builtin
///      `round()` is banker's rounding, so a course handicap of 28.5 became 29
///      here and 28 on the server. Both sides now use floor(x + 0.5) —
///      `roundHalfUp` here, `core.handicap_math.round_half_up` there.
///
///   2. `effectiveMatchHandicap` took `netPercent` and ignored it in
///      strokes-off, so every non-low player's displayed handicap was a stroke
///      high against what the backend actually scored.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/handicap_rounding.dart';
import 'package:golf_mobile/utils/match_handicap.dart';

void main() {
  group('roundHalfUp', () {
    test('half rounds up', () {
      expect(roundHalfUp(4.5), 5);
      expect(roundHalfUp(22.5), 23);
      expect(roundHalfUp(28.5), 29);
    });

    test('plus handicaps round upward toward zero, not away from it', () {
      // Dart's own .round() gives -1 and -4 here; WHS "upward" is numeric.
      expect(roundHalfUp(-0.5), 0);
      expect(roundHalfUp(-3.5), -3);
    });

    test('away from the tie it agrees with .round()', () {
      for (final v in [0.4, 0.6, 17.1, 23.83, 29.78]) {
        expect(roundHalfUp(v), v.round(), reason: '$v');
      }
    });
  });

  group('effectiveMatchHandicap', () {
    test('gross gives no strokes', () {
      expect(
        effectiveMatchHandicap(
            mode: 'gross', netPercent: 100, playingHandicap: 31),
        0,
      );
    });

    test('net scales by netPercent, half up', () {
      expect(
        effectiveMatchHandicap(
            mode: 'net', netPercent: 90, playingHandicap: 25),
        23, // 22.5 → 23
      );
      expect(
        effectiveMatchHandicap(
            mode: 'net', netPercent: 100, playingHandicap: 25),
        25,
      );
    });

    test('strokes-off scales the differential by netPercent', () {
      // Playing handicaps 31/30/29/24 off a low of 24, at Net % 90 — the same
      // figures services/nassau.py produces.
      int so(int ph) => effectiveMatchHandicap(
            mode: 'strokes_off',
            netPercent: 90,
            playingHandicap: ph,
            lowestPlayingHandicap: 24,
          );
      expect(so(31), 6); // 6.3 → 6
      expect(so(30), 5); // 5.4 → 5
      expect(so(29), 5); // 4.5 → 5
      expect(so(24), 0); // the low player plays to 0
    });

    test('strokes-off at 100% is the raw differential', () {
      expect(
        effectiveMatchHandicap(
            mode: 'strokes_off',
            netPercent: 100,
            playingHandicap: 31,
            lowestPlayingHandicap: 24),
        7,
      );
    });

    test('a player below the low never gets negative strokes', () {
      expect(
        effectiveMatchHandicap(
            mode: 'strokes_off',
            netPercent: 90,
            playingHandicap: 20,
            lowestPlayingHandicap: 24),
        0,
      );
    });
  });
}
