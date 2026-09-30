/// utils/triple_cup_allowance.dart
/// -------------------------------
/// **What a Triple Cup segment is played off, said in that segment's terms.**
///
/// Three formats in one round and three allowances, and they are not the same
/// SHAPE of number: four-ball and singles take a percentage of one player's
/// handicap, while alt-shot takes a share of the PAIR's combined figure. That
/// is why the app-bar badge has never been able to state the alt-shot one —
/// there is no percentage of a single handicap that says it.
///
/// Pure, so the wording is testable and can be reused wherever a segment is
/// drawn.
library;

/// The allowance note for [segment], or null when there is nothing to report
/// (gross — no handicap is applied at all).
///
/// [segment] is the engine's own value: `fourball`, `foursomes` or `singles`.
String? tripleCupAllowanceNote({
  required String mode,
  required String segment,
  required int fourballPercent,
  required int singlesPercent,
  required int altShotLowPct,
  required int altShotHighPct,
}) {
  if (mode == 'gross') return null;

  if (segment == 'foursomes') {
    // **Equal weights ARE the percentage of combined**, not their sum:
    // (low + high) each applied to one partner is that percent of the two
    // together. 40 + 40 is 40% of combined — the same thing as 80% of half.
    return altShotLowPct == altShotHighPct
        ? '$altShotLowPct% of the pair’s combined handicap'
        : '$altShotLowPct% of the lower handicap + '
            '$altShotHighPct% of the higher';
  }

  final pct = segment == 'singles' ? singlesPercent : fourballPercent;
  // In strokes-off the percentage scales the DIFFERENTIAL, not the handicap,
  // and saying "of handicap" there would describe a number nobody is playing.
  return mode == 'strokes_off'
      ? '$pct% of strokes off the low handicap'
      : '$pct% of handicap';
}
