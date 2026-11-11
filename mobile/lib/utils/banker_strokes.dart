import '../api/models.dart';

/// The strokes a golfer gets on a Banker hole — the ONE figure a row or a
/// keypad can show for him.
///
/// **Banker's strokes are pairwise.** Every other game allocates once across
/// the foursome. Banker cannot: an opponent's only stroke relationship is
/// with the banker, and the banker holds three at once. So:
///
/// * an OPPONENT gets the stroke he receives in his own match, against the
///   banker — which is why a golfer who GIVES the banker shots shows none,
///   however high his own handicap;
/// * the BANKER gets his stroke off the LOW golfer, the one absolute figure
///   he has. If he IS the low golfer he never strokes: nobody gives the low
///   man anything.
///
/// Null when the summary cannot say — no plan, or no banker on the hole yet —
/// so a caller can fall back rather than draw a wrong zero.
///
/// **One function, because two callers disagreed.** The golfer's row has
/// used this rule since Banker shipped; the keypad under it fell through to
/// the ROUND's full-handicap allocation, so a banker read `1 stroke · par 3`
/// over a row showing no dot — and with Net Style Entry on, the keys were
/// coloured against a par he does not have (Paul, 10 Nov 2026: "why does
/// Tyler Law get 1 stroke on this hole?"). The same fallback Sixes, Skins and
/// Nassau each hit.
int? bankerStrokesOnHole(BankerSummary? s, int playerId, int hole) {
  if (s == null || s.strokePlan.isEmpty) return null;
  final row = s.holes
      .where((x) => x.hole == hole && x.bankerId != null)
      .firstOrNull;
  if (row == null) return null;

  // The reference is the banker for an opponent, and the lowest-index
  // golfer for the banker himself.
  var reference = row.bankerId!;
  if (playerId == row.bankerId) {
    final low = (List<BankerPlayerTotal>.from(s.players)
          ..sort((a, b) => a.handicapIndex.compareTo(b.handicapIndex)))
        .firstOrNull;
    if (low == null || low.playerId == playerId) return 0;
    reference = low.playerId;
  }
  final signed = _planStrokes(s.strokePlan, reference, playerId, hole);
  // Negative means the reference receives from him — he strokes nowhere.
  return signed > 0 ? signed : 0;
}

/// `plan[reference][player][hole]`, tolerant of string or int keys — the
/// plan arrives as JSON.
int _planStrokes(
    Map<String, dynamic> plan, int reference, int player, int hole) {
  final forRef = plan['$reference'];
  if (forRef is! Map) return 0;
  final forPlayer = forRef['$player'] ?? forRef[player];
  if (forPlayer is! Map) return 0;
  final v = forPlayer['$hole'] ?? forPlayer[hole];
  return v is int ? v : 0;
}
