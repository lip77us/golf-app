import '../api/models.dart';

/// What a hole has actually got, from all three places a score can be.
///
/// Reported from the course (26 Oct 2026): a Sixes round that had been
/// scored hole by hole — and whose per-hole gate will not let you past a
/// hole without all four — warned `1 hole still has no score` at the end.
///
/// A score lives in three places between the tap and the server:
///
/// 1. **the scorecard** — what the server has;
/// 2. **the sync queue** (`RoundProvider.localPendingByHole`) — saved
///    locally and committed, waiting on a connection;
/// 3. **the screen's own pending map** — tapped but not yet saved.
///
/// Ten screens each had their own copy of this merge and **every one of them
/// read 1 and 3 and skipped 2**. `submitHole` writes locally and only
/// refreshes the scorecard once the queue DRAINS, so on a course with poor
/// signal every hole already finished and advanced past was invisible: the
/// grid still drew them (it overlays the queue) and the hole gate still let
/// you on (it checks the queue by name), while anything asking "is this
/// round complete" saw nothing.
///
/// Precedence is chronological — server, then queued, then unsaved — so a
/// later edit always wins over an earlier one.
Map<int, int> effectiveScores(
  Scorecard? sc,
  int hole, {
  Map<int, Map<int, int>> queued = const {},
  Map<int, Map<int, int>> pending = const {},
  int? clearedSentinel,
}) {
  final saved = <int, int>{};
  final hd = sc?.holeData(hole);
  if (hd != null) {
    for (final s in hd.scores) {
      if (s.grossScore != null) saved[s.playerId] = s.grossScore!;
    }
  }
  final merged = <int, int>{
    ...saved,
    ...(queued[hole] ?? const {}),
    ...(pending[hole] ?? const {}),
  };
  if (clearedSentinel != null) {
    merged.removeWhere((_, v) => v == clearedSentinel);
  }
  return merged;
}
