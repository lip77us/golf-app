/// utils/flight_share.dart
/// ----------------------
/// What one flight actually pays for a place, shown under the payout editor
/// while the TD types.
///
/// **A flight's purse is its own golfers' entries.** Fifteen golfers cut 8/7
/// at $10 a head means $80 and $70 — so a table typed as the event's total is
/// paid by each flight at its share of the field.
///
/// **Whole dollars when the table is whole dollars.** Asked for directly:
/// *"I would always move payouts to create even dollars rather than maintain
/// the proportions."* A $39/$16/$10 table cut 7/6 pays 21/9/5 and 18/7/5 —
/// not 21/8.62/5.38 — and each flight still adds up to its own purse.
///
/// ## This mirrors `services/flights.py` and must keep mirroring it
///
/// The server apportions the money; this only predicts it, because the setup
/// screen has no round trip for a table that has not been saved. Two
/// implementations of one rule is exactly the hazard this codebase keeps
/// finding, so the algorithm is the same in both — largest remainder, first
/// across the flights and then across the places — and both are tested on the
/// same worked example.
library;

/// Divide [total] by [weights] so the parts sum EXACTLY to it.
///
/// Largest remainder: every part takes its floor, and the leftover units go
/// to the biggest fractions, ties by position. Rounding each part on its own
/// invents money — three flights of three each rounding $66.666 up pays
/// $200.01 of a $200 table.
List<int> apportion(int total, List<num> weights) {
  final totalW = weights.fold<num>(0, (a, b) => a + b);
  if (totalW <= 0) return List<int>.filled(weights.length, 0);
  final exact = [for (final w in weights) total * w / totalW];
  final parts = [for (final e in exact) e.floor()];
  var left = total - parts.fold<int>(0, (a, b) => a + b);
  final order = List<int>.generate(weights.length, (i) => i)
    ..sort((a, b) {
      final fa = exact[a] - parts[a], fb = exact[b] - parts[b];
      return fa == fb ? a.compareTo(b) : fb.compareTo(fa);
    });
  for (var i = 0; i < left && i < order.length; i++) {
    parts[order[i]] += 1;
  }
  return parts;
}

/// The golfer count per flight, in board order.
///
/// Mirrors `services/flights.assign_flights`: **equal-sized, remainder to the
/// LOWER flights** — 23 golfers in two is 12 and 11, the better players'
/// flight absorbing the odd man rather than the other way round.
///
/// Depends on the COUNT alone, which is what lets the wizard show an exact
/// split on the payouts step: the field is already chosen two steps earlier,
/// and the indexes only decide who goes where, not how many go.
///
/// The server's rule has one wrinkle this does not: a golfer whose index is a
/// guess drops out of the sizing and is appended to the bottom flight. That is
/// named on the hub, never in the wizard, so there is nothing here to model.
List<int> flightSizes(int golfers, int flights) {
  if (flights < 2 || golfers <= 0) return const [];
  final base = golfers ~/ flights;
  final rem  = golfers % flights;
  return [for (var i = 0; i < flights; i++) base + (i < rem ? 1 : 0)];
}

/// 1 when every amount is a whole dollar, else 100 (cents).
int tableUnit(List<double> amounts) =>
    amounts.every((a) => a == a.roundToDouble()) ? 1 : 100;

/// `Each flight pays $5` for place [placeIndex], or `Flights pay $7–$9`.
///
/// Empty for one board or an empty table: there is nothing to divide, and a
/// line saying so would be noise on the ordinary event.
String flightShareLabel(
    List<double> amounts, int placeIndex, List<int> sizes) {
  if (sizes.length < 2 || placeIndex >= amounts.length) return '';
  final total = amounts.fold<double>(0, (a, b) => a + b);
  if (total <= 0 || amounts[placeIndex] <= 0) return '';

  final unit   = tableUnit(amounts);
  final purses = apportion((total * unit).round(), sizes);
  final paid   = [
    for (final p in purses) apportion(p, amounts)[placeIndex],
  ];

  String money(int u) => unit == 1
      ? '\$$u'
      : '\$${(u / 100).toStringAsFixed(2)}';
  final lo = paid.reduce((a, b) => a < b ? a : b);
  final hi = paid.reduce((a, b) => a > b ? a : b);
  return lo == hi
      ? 'Each flight pays ${money(lo)}'
      : 'Flights pay ${money(lo)}–${money(hi)}';
}
