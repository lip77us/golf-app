/// utils/match_handicap.dart
///
/// Pure handicap-stroke helpers shared by every scoring screen. Previously
/// each screen carried its own private `_effectiveMatchHandicap` /
/// `_strokesOnHole` copy; this is the single source of truth.

/// Compute a player's *effective* playing handicap for a match, given the
/// match's handicap mode and net percentage.
///
///   Net   : round(playingHandicap × netPercent / 100)
///   Gross : 0 (no strokes — raw scores used)
///   SO    : playingHandicap − lowestPlayingHandicap (low plays to 0).
///           `lowestPlayingHandicap` must be provided; if null we fall back to
///           full net (safe until Strokes-Off is wired end-to-end).
///
/// Returns a non-negative integer.
int effectiveMatchHandicap({
  required String mode,
  required int    netPercent,
  required int    playingHandicap,
  int?            lowestPlayingHandicap,
}) {
  switch (mode) {
    case 'gross':
      return 0;
    case 'strokes_off':
      if (lowestPlayingHandicap == null) return playingHandicap;
      final off = playingHandicap - lowestPlayingHandicap;
      return off < 0 ? 0 : off;
    case 'net':
    default:
      if (netPercent == 100) return playingHandicap;
      return (playingHandicap * netPercent / 100.0).round();
  }
}

/// Per-hole stroke allocation for a given effective handicap and the hole's
/// stroke index (1 = hardest hole). Matches the backend rule in
/// FoursomeMembership.handicap_strokes_on_hole and scoring/handicap.py.
int strokesOnHole(int effectiveHandicap, int strokeIndex) {
  if (effectiveHandicap <= 0) return 0;
  final full  = effectiveHandicap ~/ 18;
  final rem   = effectiveHandicap %  18;
  return full + (strokeIndex <= rem ? 1 : 0);
}

/// Partial-round-aware allocation (mirrors scoring.handicap.make_strokes_fn).
/// Full round (n >= universe): identical to [strokesOnHole]. Partial round:
/// SCALE the handicap to the holes played (round(hcp * n / universe)) and
/// RE-RANK by stroke index WITHIN them, so the entry-screen dots match the
/// leaderboard on a 9-hole / partial round. [siFor] returns a hole's stroke
/// index (per this player's tee).
int partialStrokesOnHole(
  int effectiveHandicap,
  int hole,
  List<int> holesInPlay,
  int universe,
  int Function(int hole) siFor,
) {
  final n = holesInPlay.length;
  if (n == 0 || n >= universe) {
    return strokesOnHole(effectiveHandicap, siFor(hole));
  }
  final hcpN = (effectiveHandicap * n / universe).round();
  if (hcpN <= 0) return 0;
  final ranked = [...holesInPlay]..sort((a, b) => siFor(a).compareTo(siFor(b)));
  final idx = ranked.indexOf(hole);          // 0 = hardest played
  if (idx < 0) return 0;
  return (hcpN ~/ n) + (idx < (hcpN % n) ? 1 : 0);
}
