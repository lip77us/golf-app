/// test/flight_share_test.dart
/// --------------------------
/// The per-place readback under the payout table.
///
/// **A flight's purse is its own golfers' entries.** Reported from a real
/// event: *"If I have 15 in to 2 flights, then the first flight has 8 players
/// and the second flight 7 players and at $10 entry, the first flight divides
/// $80 and the second flight $70."*
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/flight_share.dart';

void main() {
  test('the reported case — 15 golfers cut 8 and 7', () {
    // A $150 table: first place is half of it.
    expect(flightShareLabel(75, const [8, 7]), 'Flights pay \$35.00–\$40.00');
  });

  test('equal flights say one number, not a range', () {
    // A range where both ends are the same reads as an arithmetic accident.
    expect(flightShareLabel(100, const [8, 8]), 'Each flight pays \$50.00');
  });

  test('three flights of different sizes span the whole spread', () {
    expect(flightShareLabel(120, const [5, 4, 3]),
        'Flights pay \$30.00–\$50.00');
  });

  test('one board says nothing', () {
    // There is nothing to divide, and a line saying so would be noise on the
    // ordinary event.
    expect(flightShareLabel(100, const [12]), isEmpty);
    expect(flightShareLabel(100, const []), isEmpty);
  });

  test('an empty amount says nothing', () {
    expect(flightShareLabel(0, const [8, 7]), isEmpty);
  });

  test('the shares add up to the amount', () {
    // What the server guarantees, checked at the only other place the
    // arithmetic is written down.
    const sizes = [8, 7];
    const amount = 75.0;
    final field = sizes.reduce((a, b) => a + b);
    final cents = (amount * 100).round();
    final shares = [for (final s in sizes) (cents * s / field).round()];
    expect(shares.reduce((a, b) => a + b), cents);
  });
}
