/// utils/sixes_handicap.dart
/// -------------------------
/// Sixes-specific Strokes-Off allocation helper.
///
/// Sixes spreads a player's SO strokes across the three 6-hole matches:
///     floor(SO/3) + (1 if match_idx < SO%3 else 0)
/// per segment, allocated to the hardest holes in that segment's
/// potential range.  An "extra" tiebreak match collects any holes
/// freed up by an early finish; in extras one stroke is granted on
/// every hole whose SI <= player_so.
///
/// The function is intentionally pure — it consults the live
/// [SixesSummary] segment boundaries (which the backend updates after
/// each hole) so the dots stay in sync with the scoring engine.
///
/// Used by:
///   * score_entry_screen.dart — drives the per-hole stroke dots shown
///     next to each player's name on the live entry screen
///   * widgets/scorecard_grid.dart — drives the scorecard's stroke dots so
///     they agree with the entry screen rather than showing the naive
///     round-wide allocation.
///
/// Mirrors the backend algorithm in scoring/handicap.py (_sixes_so_plan).

import '../api/models.dart';

int sixesSoStrokesOnHole({
  required int playerSo,
  required int holeNumber,
  required int strokeIndex,
  required SixesSummary summary,
  required Scorecard scorecard,
  List<int> holesInPlay = const [],
}) {
  if (playerSo <= 0) return 0;

  final segments = summary.segments;

  // A segment's range is contiguous by POSITION in play order, so on a shotgun
  // it can wrap by hole NUMBER (e.g. start 16 → end 3). Resolve membership and
  // hole lists by position; fall back to the hole-number range when play order
  // isn't supplied (normal round → identical).
  final order = holesInPlay;
  int posOf(int h) => order.isEmpty ? (h - 1) : order.indexOf(h);

  bool inSeg(SixesSegment s) {
    if (order.isEmpty) {
      return holeNumber >= s.startHole && holeNumber <= s.endHole;
    }
    final sp = order.indexOf(s.startHole);
    final ep = order.indexOf(s.endHole);
    final hp = order.indexOf(holeNumber);
    if (sp < 0 || ep < 0 || hp < 0 || ep < sp) {
      return holeNumber >= s.startHole && holeNumber <= s.endHole;
    }
    return hp >= sp && hp <= ep;
  }

  List<int> segHoles(SixesSegment s) {
    if (order.isNotEmpty) {
      final sp = order.indexOf(s.startHole);
      final ep = order.indexOf(s.endHole);
      if (sp >= 0 && ep >= 0 && ep >= sp) return order.sublist(sp, ep + 1);
    }
    return [for (int h = s.startHole; h <= s.endHole; h++) h];
  }

  // Extra (tiebreak) segment: simple SI-threshold rule.  Doesn't fire
  // for High-Low (which has no extras by spec) but the loop is cheap.
  for (final s in segments) {
    if (s.isExtra && inSeg(s)) {
      return strokeIndex <= playerSo ? 1 : 0;
    }
  }

  // Standard segment: find the segment this hole belongs to.
  // Iterate in reverse so that when an earlier match ends early and the
  // next segment's start shifts left, the later segment wins the overlap.
  final standard = segments.where((s) => !s.isExtra).toList();
  int? stdIdx;
  SixesSegment? seg;
  for (int i = standard.length - 1; i >= 0; i--) {
    if (inSeg(standard[i])) {
      stdIdx = i;
      seg = standard[i];
      break;
    }
  }
  if (seg == null || stdIdx == null) return 0;

  final base             = playerSo ~/ 3;
  final rem              = playerSo %  3;
  final strokesThisMatch = base + (stdIdx < rem ? 1 : 0);
  if (strokesThisMatch <= 0) return 0;

  // Actual last hole played (by position): one before the next segment's
  // start, or the final hole. "Dying strokes" (holes after an early close-out)
  // get nothing.
  final segListIdx  = segments.indexOf(seg);
  final segStartPos = posOf(seg.startHole);
  int actualEndPos  = order.isEmpty ? 17 : (order.length - 1);
  for (int i = segListIdx + 1; i < segments.length; i++) {
    final nsp = posOf(segments[i].startHole);
    if (nsp > segStartPos) {
      actualEndPos = nsp - 1;
      break;
    }
  }

  // Rank holes in this segment's range hardest-first (lowest SI); hole number
  // is the deterministic tiebreak, matching the backend.
  final holes = segHoles(seg);
  holes.sort((a, b) {
    final aSi = scorecard.holeData(a)?.strokeIndex ?? 18;
    final bSi = scorecard.holeData(b)?.strokeIndex ?? 18;
    if (aSi != bSi) return aSi.compareTo(bSi);
    return a.compareTo(b);
  });
  final rank = holes.indexOf(holeNumber);
  if (rank < 0) return 0;

  final segSize = holes.length;
  int planned;
  if (strokesThisMatch <= segSize) {
    planned = rank < strokesThisMatch ? 1 : 0;
  } else {
    // More strokes than holes: everyone gets 1, extras go to hardest.
    final extra = strokesThisMatch - segSize;
    planned = 1 + (rank < extra ? 1 : 0);
  }

  // Dying strokes: match ended before this hole (by play position).
  if (posOf(holeNumber) > actualEndPos) return 0;
  return planned;
}
