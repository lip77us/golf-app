/// banker_entry_strip.dart
///
/// What surrounds the shared score-entry card on a Banker hole
/// (Downloads/handoff-banker/banker-play.html, frame 3).
///
/// **Entry itself is not a Banker screen.** It is the same four-row card and
/// inline picker every game in the app uses. What is Banker-specific is what
/// sits underneath it, and one rule: **no row resolves until all four scores
/// are in.**
///
/// Resolving one bet at a time would be technically possible and badly wrong.
/// Three of the four numbers are meaningless until the banker's is among them,
/// and a golfer watching his row flip to LOST and back as scores arrive will
/// not trust any of it. So the rows hold their stakes with the word
/// `unresolved`, and the strip says how many scores are still to come.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'hole_grid_scorecard.dart';

const _gold      = Color(0xFFB8860B);
const _goldLine  = Color(0xFFE4D3A8);
const _goldPanel = Color(0xFFFDF8EC);
const _blue      = Color(0xFF1A5490);
const _blueFill  = Color(0xFFF1F7FD);
const _blueLine  = Color(0xFFB8CFE8);
const _amber     = Color(0xFF8A5216);
const _amberFill = Color(0xFFFDF3E7);
const _amberLine = Color(0xFFE8D6BC);
final _owed      = Colors.red.shade700;
const _owedFill  = Color(0xFFFBECEA);

class BankerEntryStrip extends StatelessWidget {
  const BankerEntryStrip({
    super.key,
    required this.summary,
    required this.hole,
    required this.scoredCount,
    required this.fieldSize,
    this.pendingGross = const {},
  });

  final BankerSummary summary;
  final int hole;
  /// How many of the group have a gross score on this hole yet.
  final int scoredCount;
  final int fieldSize;
  /// Scores TYPED on this hole but not yet posted, by player id. The card
  /// fills in as the group calls their numbers rather than staying blank
  /// until the hole is posted — which is exactly when a reader wants to check
  /// what he just tapped against everyone else's.
  final Map<int, int?> pendingGross;

  @override
  Widget build(BuildContext context) {
    final h = summary.holes
        .where((x) => x.hole == hole && x.bankerId != null)
        .firstOrNull;
    if (h == null) return const SizedBox.shrink();

    final banker = summary.players
        .where((p) => p.playerId == h.bankerId).firstOrNull;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _bankerLine(banker, h),
      const SizedBox(height: 8),
      for (final l in h.lines) _betRow(l, h.resolved),
      const SizedBox(height: 14),
      // The SHARED grid every other game's entry screen draws — header
      // shading, a stroke-index row, a pinned label column. Its dots are the
      // pairwise ones: an opponent's own match, and the banker's off the low
      // golfer. No green: green means "won the hole" everywhere else, and a
      // Banker hole has three results rather than one winner.
      HoleGridScorecard(
        holes: _gridWithPending(),
        participants: summary.gridPlayers,
        legend: null,
      ),
      const SizedBox(height: 8),
    ]);
  }

  /// The server's grid with this hole's typed-but-unposted scores dropped in.
  ///
  /// Only the hole being entered is touched, and only where the server has no
  /// score of its own — a posted score always wins, so a stale local edit can
  /// never paint over what the round actually holds.
  List<Map<String, dynamic>> _gridWithPending() {
    if (pendingGross.isEmpty) return summary.grid;
    return summary.grid.map((row) {
      if (row['hole'] != hole) return row;
      final scores = ((row['scores'] as List?) ?? []).map((e) {
        final sc =
            Map<String, dynamic>.from((e as Map).cast<String, dynamic>());
        if (sc['gross'] == null && pendingGross.containsKey(sc['player_id'])) {
          sc['gross'] = pendingGross[sc['player_id']];
        }
        return sc;
      }).toList();
      return {...row, 'scores': scores};
    }).toList();
  }

  /// The whole card is read against the banker, so he is named above it rather
  /// than left to be found among four alphabetical rows.
  Widget _bankerLine(BankerPlayerTotal? banker, BankerHoleState h) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _goldPanel,
        border: Border.all(color: _goldLine),
        borderRadius: BorderRadius.circular(Halved.rChip),
      ),
      child: Row(children: [
        const Text('BANKING',
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700,
                letterSpacing: 0.5, color: _gold)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(banker?.name ?? '',
              style: const TextStyle(
                  fontSize: 14.5, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
        ),
        // His number, in the same shape the three bet rows below use — the
        // exposure while the hole is open, the result once it settles. The
        // count of scores still to come is already in the footer and does not
        // need saying twice.
        Text(
            h.resolved
                ? (h.bankerDelta == 0
                    ? '\$0'
                    : h.bankerDelta > 0
                        ? '+\$${h.bankerDelta.round()}'
                        : '−\$${h.bankerDelta.abs().round()}')
                : '\$${h.exposure.round()}',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700,
                color: !h.resolved
                    ? Halved.deepPine
                    : h.bankerDelta > 0
                        ? Halved.pine
                        : h.bankerDelta < 0 ? _owed : Halved.muted)),
      ]),
    );
  }

  Widget _betRow(BankerBetLine l, bool resolved) {
    // No UNRESOLVED tag. **This screen never resolves a bet** — the next one
    // does — so a word announcing that nothing has happened yet is noise on
    // every row until the moment they all change at once.
    final (tag, ink, fill) = switch (l.outcome) {
      'won'  => ('WON',  Halved.pine, const Color(0xFFEAF4EE)),
      'lost' => ('LOST', _owed, _owedFill),
      'tied' => ('TIED — NO ACTION', Halved.muted, const Color(0xFFF2F5F2)),
      _      => ('', Halved.muted, const Color(0xFFF2F5F2)),
    };
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder),
        borderRadius: BorderRadius.circular(Halved.rChip),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(l.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                // The stroke belongs to the MATCH, so it rides the bet row —
                // the banker holds a different one in each of the three.
                if (l.strokes != 0) ...[
                  const SizedBox(width: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE9F1EA),
                      borderRadius: BorderRadius.circular(Halved.rPill),
                    ),
                    child: Text(l.strokeNote,
                        style: const TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w600,
                            color: Halved.pine)),
                  ),
                ],
              ]),
              const SizedBox(height: 3),
              Wrap(spacing: 5, runSpacing: 5, children: [
                // The agreed bet, first — the multipliers beside it make the
                // big number on the right checkable without a sentence of
                // arithmetic under the row.
                _tag('\$${l.bet.round()} bet', Halved.deepPine,
                     const Color(0xFFEDF1EE), const Color(0xFFDDE5DF)),
                if (l.ownMultiplier > 1)
                  _tag('×${l.ownMultiplier}', _blue, _blueFill, _blueLine),
                if (l.countered)
                  _tag('×2 COUNTER', _amber, _amberFill, _amberLine),
                if (tag.isNotEmpty) _tag(tag, ink, fill, fill),
              ]),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text('\$${l.stake.round()}',
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700,
                color: Halved.deepPine)),
      ]),
    );
  }

  Widget _tag(String text, Color ink, Color fill, Color line) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(Halved.rPill),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.w700, color: ink)),
      );
}
