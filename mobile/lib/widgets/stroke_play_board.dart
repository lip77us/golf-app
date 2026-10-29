import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/nine_totals.dart';
import '../utils/stroke_play_board_model.dart';

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
        _MetaLine(data: d),
        if (widget.selector != null) ...[
          const SizedBox(height: 10),
          widget.selector!,
        ],
        const SizedBox(height: 10),
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
        if (widget.footer != null) ...[
          const SizedBox(height: 12),
          widget.footer!,
        ],
      ],
    );
  }
}

/// `Net · single round` on the left, `Entry $40` or `No pot` on the right.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.data});
  final StrokePlayBoardData data;

  @override
  Widget build(BuildContext context) {
    final left = [
      data.basisLabel,
      if (data.countingLabel.isNotEmpty) data.countingLabel,
      if (data.stakeLabel.isNotEmpty) data.stakeLabel,
    ].join(' · ');
    const style = TextStyle(fontSize: 12, color: Halved.muted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        Flexible(child: Text(left, style: style, overflow: TextOverflow.ellipsis)),
        if (data.potLabel.isNotEmpty) ...[
          const SizedBox(width: 14),
          Text(data.potLabel, style: style),
        ],
      ]),
    );
  }
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

/// `E` for level, a sign otherwise, an em dash for nothing played.
String strokeToPar(int? v) {
  if (v == null) return '—';
  if (v == 0) return 'E';
  return v > 0 ? '+$v' : '$v';
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

    var gross = 0, net = 0, played = 0;
    for (final h in holes) {
      final g = h['gross'] as int?;
      if (g != null) { gross += g; played++; }
      net += (h['net_adj'] as int?) ?? (h['net'] as int?) ?? 0;
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
        const SizedBox(height: 8),
        const _Legend(),
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
    final netTotal =
        sum((m) => (m['net_adj'] as int?) ?? (m['net'] as int?));

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
                par: data.holePars[h],
                strokes: (byHole[h]?['handicap_strokes'] as int?)
                    ?? row.strokePlan[h] ?? 0)],
            scoreTotal == null ? '—' : '$scoreTotal'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        child: band('NET',
            [for (final h in holes) Text(
                '${(byHole[h]?['net_adj'] ?? byHole[h]?['net']) ?? '–'}',
                style: cell)],
            netTotal == null ? '—' : '$netTotal'),
      ),
    ]);
  }
}

/// Birdie a filled pine circle, eagle a double circle, bogey a square,
/// double+ a double square, and a small mint dot for a stroke received.
class _ScoreMark extends StatelessWidget {
  const _ScoreMark(
      {required this.gross, required this.par, required this.strokes});
  final int? gross;
  final int? par;
  final int strokes;

  @override
  Widget build(BuildContext context) {
    if (gross == null) {
      return const Text('–', style: TextStyle(fontSize: 11, color: Halved.muted));
    }
    final d = par == null ? 0 : gross! - par!;
    final text = Text('$gross',
        style: TextStyle(
            fontSize: 11,
            fontWeight: d <= -1 ? FontWeight.w700 : FontWeight.w500,
            color: d <= -1 ? Colors.white : Halved.deepPine));

    Widget mark;
    if (d <= -2) {
      mark = _Ring(double_: true, filled: true, child: text);
    } else if (d == -1) {
      mark = _Ring(filled: true, child: text);
    } else if (d == 1) {
      mark = _Ring(square: true, child: text);
    } else if (d >= 2) {
      mark = _Ring(square: true, double_: true, child: text);
    } else {
      mark = SizedBox(width: 20, height: 20, child: Center(child: text));
    }

    if (strokes <= 0) return mark;
    return Stack(clipBehavior: Clip.none, children: [
      mark,
      Positioned(
        top: -1,
        right: -1,
        child: Container(
          width: 5, height: 5,
          decoration: const BoxDecoration(
              color: Halved.brightMint, shape: BoxShape.circle),
        ),
      ),
    ]);
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.child,
    this.filled = false,
    this.square = false,
    // ignore: non_constant_identifier_names
    this.double_ = false,
  });
  final Widget child;
  final bool filled;
  final bool square;
  // ignore: non_constant_identifier_names
  final bool double_;

  @override
  Widget build(BuildContext context) {
    BoxDecoration deco(double inset) => BoxDecoration(
          color: filled ? Halved.pine : null,
          border: filled
              ? null
              : Border.all(color: Halved.deepPine, width: 1),
          borderRadius:
              square ? BorderRadius.circular(2) : BorderRadius.circular(99),
        );
    final inner = Container(
      width: 20, height: 20,
      alignment: Alignment.center,
      decoration: deco(0),
      child: child,
    );
    if (!double_) return inner;
    return Container(
      width: 24, height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: Halved.deepPine, width: 1),
        borderRadius:
            square ? BorderRadius.circular(3) : BorderRadius.circular(99),
      ),
      child: inner,
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

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
    Widget dot({bool filled = false, bool square = false}) => Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
            color: filled ? Halved.pine : null,
            border: filled ? null : Border.all(color: Halved.deepPine, width: 1),
            borderRadius:
                square ? BorderRadius.circular(2) : BorderRadius.circular(99),
          ),
        );
    return Wrap(spacing: 12, runSpacing: 4, children: [
      item(dot(filled: true), 'Birdie'),
      item(dot(square: true), 'Bogey'),
      item(dot(square: true), 'Double'),
      item(
          Container(
            width: 7, height: 7,
            decoration: const BoxDecoration(
                color: Halved.brightMint, shape: BoxShape.circle),
          ),
          'Stroke'),
    ]);
  }
}
