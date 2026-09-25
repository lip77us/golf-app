/// test/flight_share_test.dart
/// --------------------------
/// The per-place readback under the payout table — and the guarantee that it
/// predicts what `services/flights.py` will actually pay.
///
/// **Whole dollars when the table is whole dollars.** Asked for directly,
/// 25 Sep 2026, against a $39/$16/$10 table on 13 golfers cut 7/6, which was
/// showing `$7.38–$8.62` for second: *"I would always move payouts to create
/// even dollars rather than maintain the proportions."*
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/flight_share.dart';

void main() {
  // The screenshot: $39 / $16 / $10 over 13 golfers, cut 7 and 6.
  const table = [39.0, 16.0, 10.0];
  const cut   = [7, 6];

  group('**the reported case, to the dollar**', () {
    test('every place lands on whole dollars', () {
      expect(flightShareLabel(table, 0, cut), 'Flights pay \$18–\$21');
      expect(flightShareLabel(table, 1, cut), 'Flights pay \$7–\$9');
      expect(flightShareLabel(table, 2, cut), 'Each flight pays \$5');
    });

    test('each flight still adds up to its own purse', () {
      // $65 cut 7/6 is $35 and $30 — what those golfers actually put in.
      final purses = apportion(65, cut);
      expect(purses, [35, 30]);
      for (final p in purses) {
        expect(apportion(p, table).reduce((a, b) => a + b), p);
      }
      // ...and 21+9+5 / 18+7+5, which is the TD's own arithmetic.
      expect(apportion(35, table), [21, 9, 5]);
      expect(apportion(30, table), [18, 7, 5]);
    });

    test('the flights together pay the table exactly once', () {
      final purses = apportion(65, cut);
      expect(purses.reduce((a, b) => a + b), 65);
    });
  });

  group('**where cents survive**', () {
    test('a table the TD built with cents keeps them', () {
      // $33.33 is a number somebody chose; rounding it to $33 would be
      // overruling him rather than tidying up after the division.
      expect(tableUnit(const [33.33, 33.33, 33.34]), 100);
      expect(tableUnit(table), 1);
    });

    test('a cents table still adds up', () {
      const cents = [33.33, 33.33, 33.34];
      final purses = apportion(10000, cut);
      expect(purses.reduce((a, b) => a + b), 10000);
      for (final p in purses) {
        expect(apportion(p, cents).reduce((a, b) => a + b), p);
      }
    });
  });

  group('**when it says nothing**', () {
    test('one board has nothing to divide', () {
      expect(flightShareLabel(table, 0, const [13]), isEmpty);
      expect(flightShareLabel(table, 0, const []), isEmpty);
    });

    test('an empty place says nothing', () {
      expect(flightShareLabel(const [39.0, 0.0], 1, cut), isEmpty);
      expect(flightShareLabel(const [], 0, cut), isEmpty);
    });
  });

  group('**apportion is largest-remainder**', () {
    test('the leftover goes to the biggest fraction, not the first place', () {
      // $35 of 39:16:10 is 21.0 / 8.615 / 5.385 — second has the bigger
      // fraction, so second gets the dollar. Handing it to first every time
      // would pay 22/8/5 and quietly overweight the winner.
      expect(apportion(35, table), [21, 9, 5]);
    });

    test('equal weights split as evenly as a whole number allows', () {
      expect(apportion(10, const [1, 1, 1]), [4, 3, 3]);
      expect(apportion(9, const [1, 1, 1]), [3, 3, 3]);
    });

    test('a zero total pays nobody', () {
      expect(apportion(0, const [1, 1]), [0, 0]);
      expect(apportion(50, const [0, 0]), [0, 0]);
    });
  });
}
