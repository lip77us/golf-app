/// utils/standing_money.dart
/// -------------------------
/// The money figure on the standing ribbon, in one place.
///
/// Five games had written this: Rabbit, Survivor, Vegas, Wolf and Points
/// 5-3-1, each with its own near-identical body. They agreed — but agreeing is
/// not the same as being one thing, and the registry's `gross_to_par` comment
/// records what happens next: four copies of one traversal, each guessing at a
/// key, one of them guessing wrong and failing INVISIBLY.
///
/// A money figure fails the same way. A hyphen where the rest of the strip
/// uses U+2212 is legible and wrong; a `$0` where the others go silent reads
/// as a settled nothing rather than as nothing settled. Neither breaks a test
/// that only checks its own game.
///
/// **Banker is deliberately not a caller.** It rounds to whole dollars and
/// carries no `so far`, because a Banker bet is named out loud on the tee and
/// the floor is a round number — cents there would be an accuracy the game
/// does not have. That is a different figure, not this one written differently.
library;

/// `+$10 so far` / `−$4.50 so far`, or empty at nothing.
///
/// **Empty, never `$0`.** A round that has settled nothing has nothing to say
/// about money, and a zero there reads as a settled result — the same reason
/// Sixes waits for a segment to close before it speaks at all.
///
/// The minus is **U+2212**, not a hyphen: beside a `+` at 11.5px the hyphen is
/// visibly the wrong length, and this row sets the two within six characters
/// of each other.
///
/// Whole dollars print without a decimal and anything else to the cent, so a
/// pot split three ways does not silently round away a third of a dollar.
String standingMoney(double v, {String suffix = ' so far'}) {
  if (v.abs() < 0.005) return '';
  final n = v.abs();
  final amount =
      n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
  return '${v > 0 ? "+" : "−"}\$$amount$suffix';
}
