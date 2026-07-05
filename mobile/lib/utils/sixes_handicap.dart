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
}) {
  if (playerSo <= 0) return 0;

  final segments = summary.segments;

  // Extra (tiebreak) segment: simple SI-threshold rule.  Doesn't fire
  // for High-Low (which has no extras by spec) but the loop is cheap.
  for (final s in segments) {
    if (s.isExtra && holeNumber >= s.startHole && holeNumber <= s.endHole) {
      return strokeIndex <= playerSo ? 1 : 0;
    }
  }

  // Standard segment: find the segment this hole belongs to.
  // Iterate in reverse so that when an earlier match ends early and the
  // next segment's startHole shifts left, the later segment wins the
  // overlap.
  final standard = segments.where((s) => !s.isExtra).toList();
  int? stdIdx;
  SixesSegment? seg;
  for (int i = standard.length - 1; i >= 0; i--) {
    final s = standard[i];
    if (holeNumber >= s.startHole && holeNumber <= s.endHole) {
      stdIdx = i;
      seg = s;
      break;
    }
  }
  if (seg == null || stdIdx == null) return 0;

  final base             = playerSo ~/ 3;
  final rem              = playerSo %  3;
  final strokesThisMatch = base + (stdIdx < rem ? 1 : 0);
  if (strokesThisMatch <= 0) return 0;

  // Actual last hole played: one before the next segment's start, or 18.
  final segListIdx = segments.indexOf(seg);
  int actualEnd = 18;
  for (int i = segListIdx + 1; i < segments.length; i++) {
    if (segments[i].startHole > seg.startHole) {
      actualEnd = segments[i].startHole - 1;
      break;
    }
  }

  // Rank holes in this segment's potential range hardest-first
  // (lowest SI); hole number is the deterministic tiebreak, matching
  // the backend.
  final holes = [for (int h = seg.startHole; h <= seg.endHole; h++) h];
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

  // Dying strokes: match ended before this hole.
  if (holeNumber > actualEnd) return 0;
  return planned;
}
