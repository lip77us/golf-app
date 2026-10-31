import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/nine_totals.dart';
import '../utils/stroke_play_board_model.dart';
import 'forty_balls_keypad.dart' show ScoreNotation;

/// The Stroke Play board — ONE widget for every stroke play leaderboard.
///
/// Casual and tournament, per `~/Downloads/handoff-stroke-play-leaderboard`.
/// Everything reaches it through [StrokePlayBoardData]; see that file for
/// what is derived here and what is taken from the server.
class StrokePlayBoard extends StatefulWidget {
  const StrokePlayBoard({
    super.key,
    required this.data,
    this.selector,
    this.footer,
  });

  final StrokePlayBoardData data;
  /// The Gross / Net / Strokes-off control, when the caller offers one.
  ///
  /// Passed in rather than built here because WHICH modes exist is a fact
  /// about the round's games, not about this table — and a tournament states
  /// the basis in the meta line instead of offering a switch at all.
  final Widget? selector;
  final Widget? footer;

  @override
  State<StrokePlayBoard> createState() => _StrokePlayBoardState();
}

class _StrokePlayBoardState extends State<StrokePlayBoard> {
  /// **One row open at a time.** Several at once turns a ranked table into a
  /// stack of scorecards, which is what the landscape grid is for.
  int? _openPid;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final tinted = d.tintedRanks;
    final paid = d.paidRanks;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      children: [
        // **No meta line.** The settings strip above this board states the
        // rules the round is played under, and the selector states the mode
        // — the line restated both, and could disagree with them. The stake
        // and the pot moved into the ledger at the bottom, which is where
        // money is read.
        if (widget.selector != null) ...[
          widget.selector!,
          const SizedBox(height: 10),
        ],
        if (d.rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(child: Text('No scores yet.')),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(children: [
              _HeaderRow(data: d),
              for (final r in d.rows) ...[
                _Row(
                  data: d,
                  row: r,
                  tinted: tinted.contains(r.rank),
                  badged: paid.contains(r.rank),
                  open: r.playerId != null && _openPid == r.playerId,
                  onTap: !r.hasCard
                      ? null
                      : () => setState(() => _openPid =
                          _openPid == r.playerId ? null : r.playerId),
                ),
                if (r.playerId != null && _openPid == r.playerId)
                  _OpenCard(data: d, row: r),
              ],
            ]),
          ),
        if (d.hasPot && d.paidRows.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Ledger(data: d),
        ],
        if (widget.footer != null) ...[
          const SizedBox(height: 12),
          widget.footer!,
        ],
      ],
    );
  }
}


/// The light ledger that closes the board.
///
/// `Projected · prize` with the pool while anybody is still out, `Final,
/// prize` once they are all in — the distinction the Flights work made the
/// case for: *"a golfer thru 1 showing $48 in green was the single most
/// misleading thing on the live board."*
///
/// **It names the PRIZE rank, not the board rank.** An excluded golfer holds
/// a place and is skipped for the money, so the man behind him collects 2nd
/// while standing 3rd, and a ledger reading his board rank would be naming a
/// place somebody else holds.
class _Ledger extends StatelessWidget {
  const _Ledger({required this.data});
  final StrokePlayBoardData data;

  static String _money(double v) => v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final paid = data.paidRows;
    final fin = data.allIn;
    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Text(fin ? 'Final, prize' : 'Projected · prize',
                  style: const TextStyle(
                      color: Color(0xFFB9CCC3), fontSize: 13)),
            ),
            if (data.purse > 0)
              Text('Pool \$${_money(data.purse)}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700)),
          ]),
        ),
        for (final r in paid) _line(r),
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
          child: Row(children: [
            Expanded(child: _foot(data.entryFee > 0
                ? 'Entry \$${_money(data.entryFee)}'
                : '${paid.length} paid')),
            _foot(fin
                ? 'All in'
                : '${data.onCourse} on course'),
          ]),
        ),
      ]),
    );
  }

  Widget _foot(String t) => Text(t,
      style: const TextStyle(color: Color(0xFFB9CCC3), fontSize: 12.5));

  Widget _line(StrokePlayRow r) => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (r.prizeRank != null) ...[
                const SizedBox(width: 6),
                Text('${r.prizeRank}',
                    style: const TextStyle(
                        fontSize: 12, color: Halved.muted)),
              ],
            ]),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: Halved.brightMint,
                borderRadius: BorderRadius.circular(8)),
            child: Text('+\$${_money(r.payout!)}',
                style: const TextStyle(
                    color: Halved.deepPine,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}

const double _rankW  = 34;
const double _numW   = 40;
const double _totW   = 46;
const double _moneyW = 52;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.data});
  final StrokePlayBoardData data;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
        fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: .5,
        color: Color(0xFFB9CCC3));
    Widget h(String t, double w) => SizedBox(
        width: w,
        child: Text(t, style: style, textAlign: TextAlign.center));
    // The column set is a question of how many rounds there are — see
    // `StrokeLayout`. Thru moves AFTER Tot on a multi-round board: with
    // several rounds the figure a reader wants first is the total, and thru
    // is a qualifier on the live round rather than on the whole event.
    final cols = <Widget>[
      switch (data.layout) {
        StrokeLayout.single => h('THRU', _numW),
        StrokeLayout.twoRounds => h(data.rounds[0].label, _numW),
        StrokeLayout.prevAndLive => h('PREV', _numW),
      },
      switch (data.layout) {
        StrokeLayout.single => h('GROSS', _numW),
        StrokeLayout.twoRounds => h(data.rounds[1].label, _numW),
        StrokeLayout.prevAndLive =>
          h(data.liveRound?.label ?? 'R', _numW),
      },
      h('TOT', _totW),
      if (data.layout != StrokeLayout.single) h('THRU', _numW),
      if (data.hasPot) h('PRIZE', _moneyW),
    ];

    return Container(
      color: Halved.deepPine,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(children: [
        h('#', _rankW),
        const Expanded(child: Text('PLAYER', style: style)),
        ...cols,
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.data,
    required this.row,
    required this.tinted,
    required this.badged,
    required this.open,
    required this.onTap,
  });

  final StrokePlayBoardData data;
  final StrokePlayRow row;
  final bool tinted;
  final bool badged;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tinted
          ? Halved.brightMint.withValues(alpha: .16)
          : Halved.card,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(
                bottom: BorderSide(color: Halved.cardBorder, width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(children: [
            SizedBox(
              width: _rankW,
              child: Center(child: _rank()),
            ),
            Expanded(
              child: Row(children: [
                Flexible(
                  child: Text(row.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w700)),
                ),
                if (row.handicapLabel.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(row.handicapLabel,
                      style: const TextStyle(
                          fontSize: 10.5, color: Halved.muted)),
                ],
                if (row.excluded) ...[
                  const SizedBox(width: 6),
                  const Text('NOT PAID',
                      style: TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w700,
                          letterSpacing: .4, color: Halved.muted)),
                ],
              ]),
            ),
            ..._scoreCols(),
            SizedBox(width: _totW, child: Center(child: _totBox())),
            if (data.layout != StrokeLayout.single)
              _plain(row.thruLabel, _numW),
            if (data.hasPot)
              SizedBox(
                width: _moneyW,
                child: Text(
                    (row.payout ?? 0) > 0
                        ? '\$${row.payout! % 1 == 0 ? row.payout!.toStringAsFixed(0) : row.payout!.toStringAsFixed(2)}'
                        : '',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700,
                        color: Halved.pine)),
              ),
          ]),
        ),
      ),
    );
  }

  /// The two columns before Tot, per the layout.
  List<Widget> _scoreCols() {
    switch (data.layout) {
      case StrokeLayout.single:
        return [
          _plain(row.thruLabel, _numW),
          _plain(row.grossTotal == null ? '—' : '${row.grossTotal}', _numW),
        ];
      case StrokeLayout.twoRounds:
        return [
          _roundCell(0),
          _roundCell(1),
        ];
      case StrokeLayout.prevAndLive:
        final live = data.liveRound?.index ?? data.rounds.length - 1;
        return [
          // `Prev` is the best counted rounds SO FAR, which is what makes
          // best-4-of-6 legible rather than a column of six.
          _roundText(row.prevToPar(live), counts: true),
          _roundCell(live),
        ];
    }
  }

  /// **Round columns are plain text**, not boxes: pine under, deep pine
  /// level, muted over. Only Tot is filled, because only one figure on the
  /// row should be findable without reading.
  Widget _roundCell(int i) {
    final v = i < row.roundToPar.length ? row.roundToPar[i] : null;
    return _roundText(v, counts: row.countsRound(i));
  }

  Widget _roundText(int? v, {required bool counts}) => SizedBox(
        width: _numW,
        child: Text(strokeToPar(v),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                // A round that does not count is STRUCK THROUGH rather than
                // hidden: the golfer played it, and hiding it invites the
                // question of where it went.
                decoration: counts ? null : TextDecoration.lineThrough,
                color: v == null
                    ? Halved.muted
                    : !counts
                        ? Halved.muted
                        : v < 0
                            ? Halved.pine
                            : v == 0
                                ? Halved.deepPine
                                : Halved.muted)),
      );

  /// A paid place gets a pine badge; everyone else reads as plain text.
  Widget _rank() {
    final label = row.rankLabel(data.rows);
    if (!badged) {
      return Text(label,
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: Halved.muted));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      constraints: const BoxConstraints(minWidth: 22),
      decoration: BoxDecoration(
          color: Halved.pine, borderRadius: BorderRadius.circular(11)),
      child: Text(label,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w700,
              color: Colors.white)),
    );
  }

  Widget _plain(String t, double w) => SizedBox(
        width: w,
        child: Text(t,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Halved.muted)),
      );

  /// **Tot is a filled box**: pine under par, deep pine level, grey over.
  /// It is the figure the board ranks on, so it is the one thing on the row
  /// that should be findable without reading.
  Widget _totBox() {
    final v = row.toPar;
    final fill = v == null
        ? Halved.cardBorder
        : v < 0
            ? Halved.pine
            : v == 0
                ? Halved.deepPine
                : Halved.muted;
    return Container(
      constraints: const BoxConstraints(minWidth: 36),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration:
          BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
      child: Text(strokeToPar(v),
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 13.5, fontWeight: FontWeight.w700,
              color: Colors.white)),
    );
  }
}

/// One golfer's hole-by-hole card, in place.
///
/// A tab per round, the live one selected, with a dot on it. One round
/// draws no tabs at all — a single tab is a label pretending to be a
/// control.
class _OpenCard extends StatefulWidget {
  const _OpenCard({required this.data, required this.row});
  final StrokePlayBoardData data;
  final StrokePlayRow row;

  @override
  State<_OpenCard> createState() => _OpenCardState();
}

class _OpenCardState extends State<_OpenCard> {
  int? _tab;

  StrokePlayBoardData get data => widget.data;
  StrokePlayRow get row => widget.row;

  @override
  Widget build(BuildContext context) {
    final multi = data.rounds.length > 1;
    final tab = _tab ?? data.liveRound?.index ?? 0;
    final List<Map<String, dynamic>> holes = multi
        ? (tab < row.roundHoles.length
            ? row.roundHoles[tab]
            : const <Map<String, dynamic>>[])
        : row.holes;
    final toPar = multi
        ? (tab < row.roundToPar.length ? row.roundToPar[tab] : null)
        : row.toPar;
    final byHole = <int, Map<String, dynamic>>{
      for (final h in holes) (h['hole'] as int?) ?? 0: h,
    };
    final inPlay = data.holesInPlay.isNotEmpty
        ? data.holesInPlay
        : [for (var h = 1; h <= 18; h++) h];
    // The shared split, so OUT and IN mean the same nine holes here as on
    // every other card — and a back-nine round draws IN alone.
    final split = NineSplit.of(inPlay);
    final nines = <({List<int> holes, String label})>[
      if (split.showOut) (holes: split.front, label: 'OUT'),
      if (split.showIn) (holes: split.back, label: 'IN'),
    ];

    var gross = 0, net = 0, played = 0, capped = 0;
    for (final h in holes) {
      final g = h['gross'] as int?;
      if (g != null) { gross += g; played++; }
      // The COUNTED net, so this line cannot disagree with the Tot box the
      // board ranks on — see `strokeHoleNet`.
      net += strokeHoleNet(h) ?? 0;
      if (strokeHoleCapped(h)) capped++;
    }
    final thru = multi
        ? (played == 0 ? '—' : played >= 18 ? 'F' : '$played')
        : row.thruLabel;

    return Container(
      color: Halved.card,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (multi) ...[
          _RoundTabs(
            rounds: data.rounds,
            selected: tab,
            onPick: (i) => setState(() => _tab = i),
          ),
          const SizedBox(height: 8),
        ],
        // `Gross 36 · Net 34 · To par −2 · Thru 9`.
        Text(
          [
            'Gross $gross',
            if (data.showNet) 'Net $net',
            'To par ${strokeToPar(toPar)}',
            'Thru $thru',
          ].join('  ·  '),
          style: const TextStyle(fontSize: 12, color: Halved.muted),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < nines.length; i++) ...[
          _NineGrid(
            data: data,
            row: row,
            byHole: byHole,
            holes: nines[i].holes,
            label: nines[i].label,
          ),
          if (i != nines.length - 1) const SizedBox(height: 8),
        ],
        if (capped > 0) ...[
          const SizedBox(height: 8),
          _CapNote(holes: capped),
        ],
        const SizedBox(height: 8),
        _Legend(anyCapped: capped > 0),
      ]),
    );
  }
}

/// A tab per round, the live one carrying a dot.
class _RoundTabs extends StatelessWidget {
  const _RoundTabs(
      {required this.rounds, required this.selected, required this.onPick});
  final List<StrokeRoundCol> rounds;
  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final r in rounds)
            Material(
              color: r.index == selected ? Halved.pine : Halved.card,
              borderRadius: BorderRadius.circular(99),
              child: InkWell(
                onTap: () => onPick(r.index),
                borderRadius: BorderRadius.circular(99),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                        color: r.index == selected
                            ? Halved.pine
                            : Halved.cardBorder,
                        width: 1.2),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (r.live) ...[
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                            color: r.index == selected
                                ? Halved.brightMint
                                : Halved.pine,
                            shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(r.tabLabel,
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700,
                            color: r.index == selected
                                ? Colors.white
                                : Halved.deepPine)),
                  ]),
                ),
              ),
            ),
        ],
      );
}

/// Hole / Par / Score / Net, with the nine's own total.
class _NineGrid extends StatelessWidget {
  const _NineGrid({
    required this.data,
    required this.row,
    required this.byHole,
    required this.holes,
    required this.label,
  });

  final StrokePlayBoardData data;
  final StrokePlayRow row;
  final Map<int, Map<String, dynamic>> byHole;
  final List<int> holes;
  final String label;

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(
        fontSize: 9.5, fontWeight: FontWeight.w700, color: Color(0xFFB9CCC3));
    const cell = TextStyle(fontSize: 11, color: Halved.deepPine);

    int? sum(int? Function(Map<String, dynamic>) pick) {
      var any = false, total = 0;
      for (final h in holes) {
        final v = byHole[h] == null ? null : pick(byHole[h]!);
        if (v != null) { any = true; total += v; }
      }
      return any ? total : null;
    }

    final parTotal = holes.fold<int>(
        0, (a, h) => a + (data.holePars[h] ?? 0));
    final scoreTotal = sum((m) => m['gross'] as int?);
    final netTotal = sum(strokeHoleNet);

    Widget band(String name, List<Widget> cells, String total,
        {bool dark = false}) {
      return Row(children: [
        SizedBox(
          width: 42,
          child: Text(name,
              style: dark
                  ? head
                  : const TextStyle(
                      fontSize: 9.5, fontWeight: FontWeight.w700,
                      color: Halved.muted)),
        ),
        for (final c in cells) Expanded(child: Center(child: c)),
        SizedBox(
          width: 32,
          child: Text(total,
              textAlign: TextAlign.center,
              style: dark
                  ? head
                  : const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      ]);
    }

    Widget netCell(Map<String, dynamic>? h) {
      final v = h == null ? null : strokeHoleNet(h);
      final wasCapped = h != null && strokeHoleCapped(h);
      return Text(v == null ? '–' : '$v',
          style: wasCapped
              ? const TextStyle(
                  fontSize: 11, color: _capAmberInk,
                  fontWeight: FontWeight.w700)
              : cell);
    }

    return Column(children: [
      Container(
        color: Halved.deepPine,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: band(
          'HOLE',
          [for (final h in holes) Text('$h', style: head)],
          label,
          dark: true,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        child: band('PAR',
            [for (final h in holes)
              Text('${data.holePars[h] ?? '-'}', style: cell)],
            '$parTotal'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        child: band('SCORE',
            [for (final h in holes) _ScoreMark(
                gross: byHole[h]?['gross'] as int?,
                // The golfer's OWN par where the hole carries one: on mixed
                // tees a hole is a 4 for one man and a 5 for the next, and
                // the shape is coded against it.
                par: (byHole[h]?['par'] as int?) ?? data.holePars[h],
                strokes: (byHole[h]?['strokes'] as int?)
                    ?? row.strokePlan[h] ?? 0,
                capped: byHole[h] == null
                    ? false
                    : strokeHoleCapped(byHole[h]!))],
            scoreTotal == null ? '—' : '$scoreTotal'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        child: band('NET',
            [for (final h in holes) netCell(byHole[h])],
            netTotal == null ? '—' : '$netTotal'),
      ),
    ]);
  }
}

/// Amber, for a hole the net double bogey took a stroke off. It appears
/// nowhere else on this board, so it cannot be read as a state.
const Color _capAmber = Color(0xFFD98E04);
const Color _capAmberInk = Color(0xFF8A5216);

/// A score in scorecard notation, with a mint dot for a stroke received and
/// an amber outline when the cap took a stroke off.
///
/// **It is the SHARED `ScoreNotation`** — the same widget the keypad and the
/// score box draw, which is the packet's own instruction ("the hole-by-hole
/// card uses the score-entry shapes"). It used to be a mark of its own, with
/// par drawn as a bare digit and bogeys outlined in deep pine, so a hole read
/// one way during the round and another on the board afterwards.
class _ScoreMark extends StatelessWidget {
  const _ScoreMark({
    required this.gross,
    required this.par,
    required this.strokes,
    this.capped = false,
  });
  final int? gross;
  final int? par;
  final int strokes;
  final bool capped;

  @override
  Widget build(BuildContext context) {
    if (gross == null || par == null) {
      return const Text('–',
          style: TextStyle(fontSize: 11, color: Halved.muted));
    }
    Widget mark = ScoreNotation(
      score: gross!,
      par: par!,
      strokes: strokes,
      width: 24,
      height: 24,
      fontSize: 11.5,
      cornerRadius: 5,
    );

    if (capped) {
      mark = Container(
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _capAmber, width: 2),
        ),
        child: mark,
      );
    }

    if (strokes <= 0) return mark;
    return Stack(clipBehavior: Clip.none, children: [
      mark,
      Positioned(
        top: -2,
        right: -2,
        child: Container(
          width: 6, height: 6,
          decoration: BoxDecoration(
            color: Halved.brightMint,
            shape: BoxShape.circle,
            border: Border.all(color: Halved.deepPine, width: 0.8),
          ),
        ),
      ),
    ]);
  }
}

/// The cap, in words — the card keeps the score and the total counts the
/// ceiling, which is two facts about one number.
class _CapNote extends StatelessWidget {
  const _CapNote({required this.holes});
  final int holes;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFDF3E7),
          border: Border.all(color: const Color(0xFFE8D6BC)),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Text(
            holes == 1
                ? 'One hole counted a net double bogey. The card keeps the '
                    'score that was made.'
                : '$holes holes counted a net double bogey. The card keeps '
                    'the scores that were made.',
            style: const TextStyle(fontSize: 12, color: Color(0xFF5C4326))),
      );
}

class _Legend extends StatelessWidget {
  const _Legend({this.anyCapped = false});

  /// The cap key appears only when a hole on this card was capped — a legend
  /// entry for something that did not happen is a legend nobody reads.
  final bool anyCapped;

  @override
  Widget build(BuildContext context) {
    Widget item(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(fontSize: 10, color: Halved.muted)),
          ],
        );
    // Drawn with the real widget at a legend size, so the key cannot show a
    // shape the grid above it does not use. `fontSize: 0` is deliberate: a
    // key is a SHAPE, and a digit in it would read as a score — `4 Par` says
    // par is four, which it is not on fourteen of the holes above.
    Widget shape(int diff) => ScoreNotation(
          score: 4 + diff,
          par: 4,
          width: 16,
          height: 16,
          fontSize: 0,
          cornerRadius: 4,
        );
    return Wrap(spacing: 12, runSpacing: 4, children: [
      item(shape(-1), 'Birdie'),
      item(shape(0), 'Par'),
      item(shape(1), 'Bogey'),
      item(shape(2), 'Double+'),
      item(
          Container(
            width: 7, height: 7,
            decoration: const BoxDecoration(
                color: Halved.brightMint, shape: BoxShape.circle),
          ),
          'Stroke'),
      if (anyCapped)
        item(
            Container(
              width: 13, height: 13,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _capAmber, width: 2),
              ),
            ),
            'Capped at net double bogey'),
    ]);
  }
}
