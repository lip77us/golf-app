import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// The Stableford board's order: place, golfer, points, and how far round.
///
/// **A points total means nothing without the holes behind it** — 21 points
/// thru 9 and 21 thru 16 are different rounds — so `thru N` rides beside
/// every total (Paul, 11 Nov 2026). Before this the tab was the scorecard
/// alone, and the order had to be read off its points column.
///
/// It renders the server's `results`, which arrive ranked: nothing here
/// sorts, and a shared rank reads `T2` because the server gave two golfers
/// the same one.
class StablefordStandings extends StatelessWidget {
  final List<Map<String, dynamic>> results;

  /// The round's holes, so a finished card reads `F` rather than `thru 18`.
  final int holesInRound;

  const StablefordStandings({
    super.key,
    required this.results,
    this.holesInRound = 18,
  });

  static String _money(num v) {
    final a = v.abs();
    final t = a == a.roundToDouble()
        ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
    return '${v < 0 ? '−' : ''}\$$t';
  }

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) return const SizedBox.shrink();
    final counts = <int, int>{};
    for (final r in results) {
      final rank = r['rank'] as int?;
      if (rank != null && (r['holes_played'] as int? ?? 0) > 0) {
        counts[rank] = (counts[rank] ?? 0) + 1;
      }
    }
    final anyMoney = results.any((r) {
      final p = r['payout'] as num?;
      return p != null && p != 0;
    });
    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Halved.cardBorder),
      ),
      child: Column(children: [
        for (var i = 0; i < results.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: Halved.cardBorder),
          _row(results[i], counts, anyMoney),
        ],
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r, Map<int, int> counts,
      bool anyMoney) {
    final played = r['holes_played'] as int? ?? 0;
    final rank = r['rank'] as int?;
    final started = played > 0 && rank != null;
    final place = !started
        ? '—'
        : '${(counts[rank] ?? 0) > 1 ? 'T' : ''}$rank';
    final pts = r['total_points'] as num? ?? 0;
    final payout = r['payout'] as num?;
    final thru = !started
        ? 'not started'
        : played >= holesInRound ? 'F' : 'thru $played';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(children: [
        SizedBox(
          width: 34,
          child: Text(place,
              style: const TextStyle(
                  color: Halved.deepPine, fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ),
        // One flexible child: the name yields, the figures never do.
        // The `NOT PAID` tag is INSIDE the flexible cell, so it takes its
        // room from the name rather than from the figures beside it.
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text('${r['player_name'] ?? ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Halved.deepPine, fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            if (r['excluded'] == true) ...[
              const SizedBox(width: 6),
              const Text('NOT PAID',
                  style: TextStyle(
                      color: Halved.muted, fontSize: 10, letterSpacing: 0.5,
                      fontWeight: FontWeight.w700)),
            ],
          ]),
        ),
        const SizedBox(width: 10),
        // The number in its own right-aligned cell and the unit in its own:
        // `1 pt` beside `36 pts` then lines up on the figures, not on the
        // letters.
        SizedBox(
          width: 34,
          child: Text(started ? '$pts' : '',
              textAlign: TextAlign.right, maxLines: 1,
              style: const TextStyle(
                  color: Halved.deepPine, fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 26,
          child: Text(!started ? '' : (pts == 1 ? 'pt' : 'pts'),
              maxLines: 1,
              style: const TextStyle(
                  color: Halved.muted, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          width: 76,
          child: Text(thru,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: Halved.muted, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ),
        // **A fixed column, drawn on every row or on none.** A money figure
        // on some rows and nothing on the others pushed the points and
        // `thru` left on exactly the rows that were paid, so the points did
        // not line up down the card (Paul, 11 Nov 2026).
        if (anyMoney)
          SizedBox(
            width: 66,
            child: Text(
                payout != null && payout != 0 ? _money(payout) : '',
                textAlign: TextAlign.right,
                maxLines: 1,
                style: TextStyle(
                    color: (payout ?? 0) > 0 ? Halved.pine : Halved.warning,
                    fontSize: 13, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}
