import '../api/models.dart';

/// Should the Segment-2 draw reveal be shown right now?
///
/// The draw is a **reveal**, not a decision: all three pairings are assigned
/// when the game is set up, and the slot machine only uncovers the one that
/// was always going to be next. Nothing about the teams changes when it runs.
///
/// That makes the timing the whole point. It is worth seeing at the moment
/// Segment 1 settles and Segment 2 has not begun. Shown any later it
/// interrupts play to announce a pairing the group is already playing — and
/// dismissing it jumps the card back to Segment 2's first hole, which is how
/// a group standing on the 13th got sent back to the 7th.
///
/// The screen also remembers, per round and per device, that it has shown the
/// draw. That flag is a convenience and not the rule: it is device-local, so
/// a reinstall or a second phone loses it, and it cannot stand in for the one
/// thing that actually decides this — whether the group has played on.
bool shouldRevealSixesSegmentTwoDraw(SixesSummary? summary) {
  if (summary == null) return false;

  final segs = summary.segments.where((s) => !s.isExtra).toList();
  if (segs.length < 3) return false;
  final seg1 = segs[0], seg2 = segs[1], seg3 = segs[2];

  // Segment 1 has to be settled — including an early close-out on 4 or 5.
  final seg1Done = seg1.status == 'complete' || seg1.status == 'halved';
  if (!seg1Done) return false;

  // Both remaining pairings must be assigned, or there is nothing to reveal.
  if (!seg2.team1.hasPlayers || !seg3.team1.hasPlayers) return false;

  // And the group must not have played on. A single scored hole in either
  // later segment means this moment has passed.
  if (seg2.holes.isNotEmpty || seg3.holes.isNotEmpty) return false;

  return true;
}
