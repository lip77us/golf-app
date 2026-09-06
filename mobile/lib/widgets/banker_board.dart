/// banker_board.dart
///
/// Banker's leaderboard card (Downloads/handoff-banker/banker-leaderboard.html).
///
/// Eighteen holes, three bets a hole, two independent doublers — fifty-four
/// one-on-ones in a round, and no golfer alive can reconstruct them. **This
/// board exists so nobody has to.**
///
/// **It is the round, not your round.** One table: eighteen hole rows, four
/// golfer columns, every cell signed. Nothing is per-viewer and four phones
/// show the same screen — in a game where the whole foursome watched every bet
/// get called, hiding Dave's number from Sam would be inventing a privacy rule
/// the format does not have.
///
/// Lives in its own file rather than inside `leaderboard_screen.dart`, which is
/// ~11k lines of cards sharing near-identical blocks; that file's own notes
/// record how easily an edit lands on the wrong one.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';

const _gold      = Color(0xFFB8860B);
const _goldFill  = Color(0xFFFBF0D6);
const _goldLine  = Color(0xFFE4D3A8);
const _amber     = Color(0xFF8A5216);

class BankerGroupCard extends StatelessWidget {
  const BankerGroupCard({super.key, required this.group});

  final Map<String, dynamic> group;

  @override
  Widget build(BuildContext context) {
    final raw = group['summary'];
    if (raw is! Map) return const SizedBox.shrink();
    final s = BankerSummary.fromJson(raw.cast<String, dynamic>());
    if (s.players.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No Banker data yet.'),
      );
    }
    // Column order is the ROSTER's, not the money's: this is a table in hole
    // order, and sorting it by winnings would move a man's column out from
    // under the reader mid-round.
    final cols = List<BankerPlayerTotal>.from(s.players)
      ..sort((a, b) => a.playerId.compareTo(b.playerId));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Halved.rCard),
        side: const BorderSide(color: Halved.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(s),
          const SizedBox(height: 12),
          _ledger(s, cols),
          const SizedBox(height: 16),
          _swings(s),
          const SizedBox(height: 16),
          _card(s, cols),
        ]),
      ),
    );
  }

  // -- header ---------------------------------------------------------------

  Widget _header(BankerSummary s) {
    final played = s.holes.where((h) => h.resolved).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Band  ',
            style: TextStyle(fontSize: 13, color: Halved.muted)),
        Text('\$${s.minBet.round()}–\$${s.maxBet.round()}, '
             '${_modeLabel(s.handicapMode)}',
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700,
                color: Halved.deepPine)),
        const Spacer(),
        Text(played >= s.holes.length && s.holes.isNotEmpty
                ? 'Round complete'
                : 'Through $played',
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: Halved.muted)),
      ]),
      const SizedBox(height: 4),
      Row(children: [
        const Text('THE EIGHTEEN HOLES',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700,
                letterSpacing: 0.5, color: Halved.muted)),
        const Spacer(),
        // The count is the point of the board: nobody reconstructs
        // fifty-four one-on-ones from memory.
        Text('${_settled(s)} one-on-ones settled',
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600,
                color: Halved.muted)),
      ]),
    ]);
  }

  int _settled(BankerSummary s) => s.holes
      .where((h) => h.resolved)
      .fold(0, (n, h) => n + h.lines.length);

  String _modeLabel(String m) => switch (m) {
        'gross' => 'gross',
        'net'   => 'net',
        _       => 'strokes off',
      };

  // -- the money table ------------------------------------------------------

  /// What each hole PAID, not what was on it.
  ///
  /// An earlier pass marked multiplied bets with an outline and it made the
  /// table a puzzle: a golfer would find the loud cell and then have to work
  /// out whether the noise had cost him anything. The multipliers live in the
  /// play screen's chain, hole by hole, where they can be read in full.
  Widget _ledger(BankerSummary s, List<BankerPlayerTotal> cols) {
    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder),
        borderRadius: BorderRadius.circular(Halved.rChip),
      ),
      child: Column(children: [
        _headRow(cols),
        for (final h in s.holes)
          if (h.bankerId != null) _holeRow(h, cols),
        const Divider(height: 1),
        _totalRow('Net', cols, (p) => p.total, bold: true),
        _totalRow('AS BANKER', cols, (p) => p.banking, muted: true),
        _totalRow('AS A PLAYER', cols, (p) => p.betting, muted: true),
        _bankedRow(s, cols),
      ]),
    );
  }

  Widget _headRow(List<BankerPlayerTotal> cols) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        child: Row(children: [
          const SizedBox(
            width: 44,
            child: Text('Hole',
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600,
                    color: Halved.muted)),
          ),
          // Short names are capped at five characters and a group may use
          // initials, so the column header carries the FULL name.
          for (final p in cols)
            Expanded(
              child: Column(children: [
                Text(_given(p.name).toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w700,
                        color: Halved.deepPine)),
                Text(_family(p.name).toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w600,
                        color: Halved.muted)),
              ]),
            ),
        ]),
      );

  Widget _holeRow(BankerHoleState h, List<BankerPlayerTotal> cols) {
    final moves = _moves(h);
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF1F5F1))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(children: [
        SizedBox(
          width: 44,
          child: Row(children: [
            Text('${h.hole}',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700,
                    color: Halved.deepPine)),
            const SizedBox(width: 3),
            Text(h.par == null ? '' : 'p${h.par}',
                style: const TextStyle(fontSize: 11, color: Halved.muted)),
          ]),
        ),
        for (final p in cols)
          Expanded(
            child: Container(
              // Reading the gold down the table shows the rotation, and it is
              // the only marker the table needs.
              decoration: p.playerId == h.bankerId
                  ? BoxDecoration(
                      color: _goldFill,
                      borderRadius: BorderRadius.circular(6))
                  : null,
              padding: const EdgeInsets.symmetric(vertical: 4),
              alignment: Alignment.center,
              child: Text(_cell(moves[p.playerId], h.resolved),
                  style: TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700,
                      color: _tone(moves[p.playerId], h.resolved))),
            ),
          ),
      ]),
    );
  }

  /// Every bet was one-on-one, so a hole row sums to zero.
  Map<int, double> _moves(BankerHoleState h) {
    final out = <int, double>{};
    if (!h.resolved) return out;
    out[h.bankerId ?? -1] = h.bankerDelta;
    for (final l in h.lines) {
      out[l.playerId] = switch (l.outcome) {
        'won'  => l.amount,
        'lost' => -l.amount,
        _      => 0.0,
      };
    }
    return out;
  }

  /// A dash means nothing moved — either a tie, since a tie is no action, or,
  /// for the banker, a hole where the three bets cancelled.
  String _cell(double? v, bool resolved) {
    if (!resolved || v == null) return '·';
    if (v == 0) return '–';
    return v > 0 ? '+\$${v.round()}' : '−\$${v.abs().round()}';
  }

  Color _tone(double? v, bool resolved) {
    if (!resolved || v == null || v == 0) return Halved.muted;
    return v > 0 ? Halved.pine : _amber;
  }

  Widget _totalRow(String label, List<BankerPlayerTotal> cols,
      double Function(BankerPlayerTotal) pick,
      {bool bold = false, bool muted = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF1F5F1))),
      ),
      child: Row(children: [
        SizedBox(
          width: 44,
          child: Text(label,
              style: TextStyle(
                  fontSize: muted ? 10 : 12.5,
                  fontWeight: FontWeight.w700,
                  color: muted ? Halved.muted : Halved.deepPine)),
        ),
        for (final p in cols)
          Expanded(
            child: Text(_money(pick(p)),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: bold ? 15 : 12.5,
                    fontWeight: FontWeight.w700,
                    color: muted
                        ? Halved.muted
                        : pick(p) > 0
                            ? Halved.pine
                            : pick(p) < 0 ? _amber : Halved.muted)),
          ),
      ]),
    );
  }

  /// Holes banked is a FACT about the round rather than an achievement — the
  /// golfer who banked seven is as likely to have been beaten seven times as
  /// to have collected.
  Widget _bankedRow(BankerSummary s, List<BankerPlayerTotal> cols) {
    final counts = <int, int>{};
    for (final h in s.holes) {
      if (h.bankerId != null) {
        counts[h.bankerId!] = (counts[h.bankerId!] ?? 0) + 1;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF1F5F1))),
      ),
      child: Row(children: [
        const SizedBox(
          width: 44,
          child: Text('HOLES',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  color: Halved.muted)),
        ),
        for (final p in cols)
          Expanded(
            child: Text('${counts[p.playerId] ?? 0}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700,
                    color: _gold)),
          ),
      ]),
    );
  }

  // -- the biggest holes ----------------------------------------------------

  /// A Banker round is nearly always settled by two or three holes where a
  /// doubled bet met good shots. Everybody half-remembers them and nobody
  /// agrees on the number, so they are printed — and the figure is NAMED,
  /// because a column that silently alternates between the banker's net and
  /// one opponent's bet is unreadable.
  Widget _swings(BankerSummary s) {
    if (s.biggestSwings.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('THE HOLES THAT DECIDED IT',
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700,
              letterSpacing: 0.5, color: Halved.muted)),
      const SizedBox(height: 6),
      for (final w in s.biggestSwings)
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _goldPanelFor(w),
            border: Border.all(color: _goldLine),
            borderRadius: BorderRadius.circular(Halved.rChip),
          ),
          child: Row(children: [
            SizedBox(
              width: 34,
              child: Text('${w.hole}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700,
                      color: Halved.deepPine)),
            ),
            Expanded(
              child: Text('${w.banker} banked',
                  style: const TextStyle(
                      fontSize: 13, color: Halved.muted)),
            ),
            Text('${_money(w.topAmount)} ${w.topName}',
                style: TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w700,
                    color: w.topAmount > 0 ? Halved.pine : _amber)),
          ]),
        ),
    ]);
  }

  Color _goldPanelFor(BankerSwing w) => const Color(0xFFFDF8EC);

  // -- the net card ---------------------------------------------------------

  /// **Net, and with no stroke dot** — the one place Banker departs from every
  /// other card in the app. A hole here is three net comparisons against the
  /// banker, and gross would make the reader do the subtraction four times a
  /// row to check a single bet.
  ///
  /// Two marks carry the whole hole: **gold is the banker, a green box beat
  /// him.** Unmarked lost to him or tied him — and since a tie is no action,
  /// unmarked does not mean paid. The money table above says who paid.
  Widget _card(BankerSummary s, List<BankerPlayerTotal> cols) {
    final rows = (s.scorecard['rows'] as List? ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final holes = (s.scorecard['holes'] as List? ?? []).cast<int>();
    final played = holes
        .where((h) => rows.any((r) => (r['net'] as Map?)?['$h'] != null ||
                                      (r['net'] as Map?)?[h] != null))
        .toList();
    if (played.isEmpty) return const SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Text('THE CARD',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700,
                letterSpacing: 0.5, color: Halved.muted)),
        SizedBox(width: 8),
        Text('net · gold banked · green beat him',
            style: TextStyle(fontSize: 10.5, color: Halved.muted)),
      ]),
      const SizedBox(height: 6),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const SizedBox(width: 52),
            for (final h in played)
              SizedBox(
                width: 30,
                child: Text('$h',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w700,
                        color: Halved.muted)),
              ),
          ]),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                SizedBox(
                  width: 52,
                  child: Text('${r['short_name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                for (final h in played) _cardCell(r, h),
              ]),
            ),
        ]),
      ),
    ]);
  }

  Widget _cardCell(Map<String, dynamic> row, int hole) {
    final v      = _at(row['net'], hole);
    final banked = _at(row['banked'], hole) == true;
    final beat   = _at(row['beat'], hole) == true;
    return Container(
      width: 30,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 0.5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: banked ? _goldFill : null,
        border: beat
            ? Border.all(color: Halved.pine, width: 1.4)
            : banked
                ? Border.all(color: _goldLine)
                : null,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(v == null ? '' : '$v',
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: (banked || beat) ? FontWeight.w700 : FontWeight.w500,
              color: banked ? _gold
                            : beat ? Halved.pine : Halved.deepPine)),
    );
  }

  /// JSON object keys arrive as strings; a Dart map built locally keys on int.
  dynamic _at(dynamic map, int hole) {
    if (map is! Map) return null;
    return map['$hole'] ?? map[hole];
  }

  // -- small helpers --------------------------------------------------------

  String _money(double v) =>
      v == 0 ? '–' : (v > 0 ? '+\$${v.round()}' : '−\$${v.abs().round()}');

  String _given(String name) => name.trim().split(RegExp(r'\s+')).first;

  String _family(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.length > 1 ? parts.last : '';
  }
}
