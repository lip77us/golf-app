/// utils/spots_earned.dart
/// ----------------------
/// One golfer's spots, inverted out of the summary's hole-ordered rows.
///
/// Pure, so the rule is testable and reusable — the same reason
/// `nine_totals.dart` and `roster_sections.dart` are functions rather than
/// markup inside the one screen that needed them first. The leaderboard draws
/// the result as bubbles; the play screens may well want it later.
library;

/// A spot a golfer was given: what it was, where, and what it was worth.
typedef EarnedSpot = ({String label, int hole, int worth});

/// Every spot [playerId] has, in the order they happened.
///
/// The summary groups by HOLE because that is how the money is settled. A
/// leaderboard ranks golfers, so it needs the other grouping — and doing it
/// here rather than in the widget is what lets the hole-order guarantee be
/// stated and tested instead of inherited from whatever the server sent.
///
/// `holes` is the summary's raw `holes` list. An entry with no `types` (an
/// older server, before the types work) yields nothing rather than a bubble
/// with no name on it.
List<EarnedSpot> spotsEarnedFor(List<Map<String, dynamic>> holes,
                                int? playerId) {
  if (playerId == null) return const [];
  final out = <EarnedSpot>[];
  final sorted = [...holes]..sort((a, b) =>
      ((a['hole'] as num?)?.toInt() ?? 0)
          .compareTo((b['hole'] as num?)?.toInt() ?? 0));
  for (final h in sorted) {
    final hole = (h['hole'] as num?)?.toInt() ?? 0;
    for (final e in (h['spots'] as List? ?? []).cast<Map<String, dynamic>>()) {
      if ((e['player_id'] as num?)?.toInt() != playerId) continue;
      for (final t in (e['types'] as List? ?? []).cast<Map<String, dynamic>>()) {
        final label = t['label']?.toString() ?? '';
        if (label.isEmpty) continue;
        out.add((
          label: label,
          hole: hole,
          worth: (t['worth'] as num?)?.toInt() ?? 1,
        ));
      }
    }
  }
  return out;
}

/// `Chippy on 2`, or `Greenie on 7 ×2` when it is worth more than one.
///
/// **`on` is in the text deliberately**: `Chippy 2` reads as two chippies,
/// and the one thing these bubbles exist to remove is ambiguity about what
/// the money was for.
String earnedSpotLabel(EarnedSpot s) => s.worth.abs() == 1
    ? '${s.label} on ${s.hole}'
    : '${s.label} on ${s.hole} ×${s.worth.abs()}';
