/// utils/play_order.dart
///
/// The ordered sequence of hole numbers a group actually plays — starting at
/// the round's starting hole and wrapping around the course's hole count.
/// Mirrors the backend `services/hole_plan.play_order`. Used by the dedicated
/// play screens (Wolf, Rabbit, …) so their hole navigation follows play order
/// on a back-9 / 9-hole / shotgun round instead of assuming 1..18.
library;

import '../api/models.dart';

/// The universe (course hole count) implied by a loaded scorecard — the highest
/// hole number present, or 18 when unknown.
int courseHoleCount(Scorecard? sc) {
  if (sc == null || sc.holes.isEmpty) return 18;
  return sc.holes.map((h) => h.holeNumber).reduce((a, b) => a > b ? a : b);
}

/// Ordered holes this group plays. Defaults (start 1, num = universe) reduce to
/// 1..18. A back-9 is 10..18; a shotgun from 8 is 8..18,1..7.
List<int> roundPlayOrder(Round? round, Scorecard? sc) {
  final universe = courseHoleCount(sc);
  final start = (round?.startingHole ?? 1).clamp(1, universe);
  final n = (round?.numHoles ?? universe).clamp(1, universe);
  return [for (int i = 0; i < n; i++) ((start - 1 + i) % universe) + 1];
}

/// The hole after [hole] in [order], or null if it's the last one.
int? nextInOrder(List<int> order, int hole) {
  final i = order.indexOf(hole);
  return (i < 0 || i + 1 >= order.length) ? null : order[i + 1];
}

/// The hole before [hole] in [order], or null if it's the first one.
int? prevInOrder(List<int> order, int hole) {
  final i = order.indexOf(hole);
  return (i <= 0) ? null : order[i - 1];
}
