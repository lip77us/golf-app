/// utils/flight_share.dart
/// ----------------------
/// What one flight actually pays for a place.
///
/// **A flight's purse is its own golfers' entries.** Fifteen golfers cut 8/7
/// at $10 a head means $80 and $70 — so a table typed as the event's total is
/// paid by each flight at its share of the field. A TD needs to see that while
/// he types — *"I want to set the prize pool and see what each flight winner
/// will get"* — because $200 into first place means $200 on one board and
/// about $107 on the larger of two.
///
/// **Proportional, not an equal division.** An equal split pays a 7-man flight
/// and an 8-man flight the same money, so neither plays for what it paid in,
/// and it strands a cent that has to go somewhere. Here the flights differ
/// because their fields differ, which is a fact rather than an artifact.
library;

/// `Each flight pays $50` when the flights are the same size, or
/// `Flights pay $35–$40` when they are not.
///
/// Empty for one board or no amount: there is nothing to divide, and a line
/// saying so would be noise on the ordinary event.
///
/// [sizes] is the golfer count per flight, in board order. Pass an empty list
/// before a cut has been previewed and this stays quiet rather than guessing
/// at an even split the field may not produce.
String flightShareLabel(double amount, List<int> sizes) {
  if (amount <= 0 || sizes.length < 2) return '';
  final field = sizes.fold<int>(0, (a, b) => a + b);
  if (field <= 0) return '';

  // In cents, which is the unit the money is paid in — dividing dollars and
  // rounding twice is what invents a penny.
  final cents = (amount * 100).round();
  final shares = [for (final s in sizes) (cents * s / field).round()];
  String money(int c) => '\$${(c / 100).toStringAsFixed(2)}';

  final lo = shares.reduce((a, b) => a < b ? a : b);
  final hi = shares.reduce((a, b) => a > b ? a : b);
  if (lo == hi) return 'Each flight pays ${money(lo)}';
  return 'Flights pay ${money(lo)}–${money(hi)}';
}
