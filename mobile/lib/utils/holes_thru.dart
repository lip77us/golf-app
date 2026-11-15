import '../providers/round_provider.dart';

/// How many holes the group has finished, for the app bar's `Game · Thru 6`.
///
/// A hole counts when every golfer on the card has a gross score for it, or
/// when it is waiting in the sync queue (the phone has it, the server does
/// not yet — it is still a hole played). Counted, never the highest hole
/// number: a shotgun group off the 7th that has played three holes is thru 3.
///
/// The shared score entry screen has its own copy that also knows alt-shot
/// partners and phantoms; the dedicated play screens have neither.
int holesThruOf(RoundProvider rp) {
  final sc = rp.scorecard;
  if (sc == null) return 0;
  var n = 0;
  for (var h = 1; h <= 18; h++) {
    final hd = sc.holeData(h);
    if (hd == null || hd.scores.isEmpty) {
      if (rp.localPendingByHole.containsKey(h)) n++;
      continue;
    }
    if (hd.scores.every((s) => s.grossScore != null) ||
        rp.localPendingByHole.containsKey(h)) {
      n++;
    }
  }
  return n;
}
