import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/nine_totals.dart';
import '../utils/points_board_model.dart';

/// The Points 5-3-1 board — ONE widget for every Points leaderboard.
///
/// `~/Downloads/handoff-points-leaderboard`. Three cards: the hole just
/// played (or the round's result once it is over), where the points went hole
/// by hole, and the ledger. Everything reaches it through [PointsBoardData],
/// which reads the engine rather than replaying the round — see that file for
/// why the money in particular is never recomputed here.
///
/// **"Target" replaces "par" everywhere on this board**, which is the
/// packet's own rule and a real one: par is a number of strokes and this card
/// is counting points, so a golfer reading `+15` against par would be reading
/// it as fifteen shots.
class PointsBoard extends StatelessWidget {
  const PointsBoard({super.key, required this.data});

  final PointsBoardData data;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          data.roundOver ? _RoundOver(data: data) : _LastHole(data: data),
          const SizedBox(height: 10),
          _ByHole(data: data),
          const SizedBox(height: 10),
          _Ledger(data: data),
        ],
      );
}

Color _colour(PointsBoardData d, int playerId) {
  for (final g in d.golfers) {
    if (g.playerId == playerId) return Halved.golfer(g.colourIndex);
  }
  return Halved.muted;
}

Color _tint(PointsBoardData d, int playerId) {
  for (final g in d.golfers) {
    if (g.playerId == playerId) return Halved.golferTint(g.colourIndex);
  }
  return Halved.surface;
}

String _money(double v) {
  final a = v.abs();
  final n = a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
  if (v == 0) return '\$0';
  return '${v > 0 ? '+' : '−'}\$$n';
}

String _plain(double v) =>
    v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

Widget _swatch(Color c, {double size = 10}) => Container(
      width: size,
      height: size,
      decoration:
          BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
    );

// ── 1 · the hole just played ────────────────────────────────────────────

class _LastHole extends StatelessWidget {
  const _LastHole({required this.data});
  final PointsBoardData data;

  @override
  Widget build(BuildContext context) {
    final hole = data.lastHole;
    final next = data.nextHole;

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.deepPine, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: hole == null ? _notStarted(next) : _played(hole, next),
    );
  }

  Widget _heading(String left, String right, {bool live = true}) => Row(
        children: [
          if (live) ...[
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                  color: Halved.brightMint, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(left.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                    color: live ? Halved.pine : Halved.muted)),
          ),
          Text(right,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ],
      );

  /// Before the first tee. The card states the rule rather than drawing an
  /// empty hole — it is the one moment where what a golfer needs is what the
  /// game pays, not what anybody scored.
  Widget _notStarted(int? next) {
    final par = next == null ? null : data.parByHole[next];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading(
        next == null ? 'Points 5-3-1' : 'Hole $next${par == null ? '' : ' · par $par'}',
        'Not started',
      ),
      const SizedBox(height: 9),
      Text.rich(
        TextSpan(children: [
          const TextSpan(
              text: '5 for low, 3 for second, 1 for third · every hole pays '),
          TextSpan(
              text: '${data.pointsPerHole * 3}',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: Halved.deepPine)),
        ]),
        style: const TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: Halved.muted),
      ),
    ]);
  }

  Widget _played(PointsBoardHole hole, int? next) {
    final nextPar = next == null ? null : data.parByHole[next];
    // **The hole's total is summed, not asserted.** It is nine every time
    // under 5-3-1, and summing says so from the scores rather than from a
    // sentence that would keep reading `9` if the awards ever changed.
    final pays = hole.entries.fold<double>(0, (a, e) => a + e.points);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading(
        'Hole ${hole.hole}${hole.par == null ? '' : ' · par ${hole.par}'}',
        next == null
            ? 'Last hole'
            : 'Next: $next${nextPar == null ? '' : ' · par $nextPar'}',
      ),
      const SizedBox(height: 4),
      for (final e in hole.byNet) _row(e),
      const SizedBox(height: 9),
      Container(
        padding: const EdgeInsets.only(top: 9),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFEEF3EE))),
        ),
        child: Row(children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'The hole pays '),
                TextSpan(
                    text: formatPoints(pays),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Halved.deepPine)),
              ]),
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted),
            ),
          ),
          Text(
              data.holesLeft == 1
                  ? '1 hole left'
                  : '${data.holesLeft} holes left',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
      ),
    ]);
  }

  Widget _row(PointsBoardEntry e) => Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        constraints: const BoxConstraints(minHeight: 38),
        decoration: BoxDecoration(
          color: e.tied ? Halved.surface : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          _swatch(_colour(data, e.playerId)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(e.shortName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          if (e.tied) ...[
            const SizedBox(width: 7),
            const Text('tied',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Halved.muted)),
          ],
          const Spacer(),
          Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'net '),
              TextSpan(
                  text: '${e.net}',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Halved.deepPine)),
            ]),
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Halved.muted),
          ),
          const SizedBox(width: 10),
          const Text('→', style: TextStyle(color: Halved.muted)),
          const SizedBox(width: 10),
          Text(formatPoints(e.points),
              style: const TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w700, height: 1)),
          const SizedBox(width: 3),
          Text(e.points == 1 ? 'pt' : 'pts',
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
      );
}

// ── 1b · the round's result ─────────────────────────────────────────────

class _RoundOver extends StatelessWidget {
  const _RoundOver({required this.data});
  final PointsBoardData data;

  @override
  Widget build(BuildContext context) {
    final w = data.winner;
    final tied = data.winnerIsTied;
    final target = data.target;
    final diff = w == null ? 0.0 : w.points - target;

    // Every other golfer is at or below the average, so the leader can only
    // be level when all three are — which is the one case the packet's `+`
    // would print as `+0`.
    final figure = diff == 0 ? 'E' : '+${formatPoints(diff)}';

    final leaders = [
      for (final g in data.ledger)
        if (w != null && g.points == w.points) g,
    ];

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('ROUND OVER',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                    color: Halved.muted)),
          ),
          const Text('vs. Target',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
        const SizedBox(height: 8),
        if (w == null)
          const Text('No scores.',
              style: TextStyle(fontSize: 15, color: Halved.muted))
        else ...[
          Row(children: [
            if (!tied) ...[
              _swatch(_colour(data, w.playerId)),
              const SizedBox(width: 9),
            ],
            Expanded(
              child: Text(
                  tied
                      ? leaders.map((g) => g.shortName).join(' & ')
                      : w.shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            Text(figure,
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    height: 1,
                    color: diff == 0 ? Halved.deepPine : Halved.pine)),
          ]),
          const SizedBox(height: 3),
          Text(
            [
              '${formatPoints(w.points)} points',
              diff == 0
                  ? 'level with the target of $target'
                  : '${formatPoints(diff)} over target of $target',
              // **Silent when nothing was won**, rather than `wins $0`:
              // a pool can settle to nothing, and so can three golfers
              // level. The ledger below still states every figure.
              if (w.money > 0)
                tied
                    ? 'they win ${_money(w.money).replaceFirst('+', '')} each'
                    : 'wins ${_money(w.money).replaceFirst('+', '')}',
            ].join(' · '),
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Halved.muted),
          ),
        ],
      ]),
    );
  }
}

// ── 2 · points by hole ──────────────────────────────────────────────────

class _ByHole extends StatelessWidget {
  const _ByHole({required this.data});
  final PointsBoardData data;

  @override
  Widget build(BuildContext context) {
    // **Hole number inside each nine, not play order.** Out and In only mean
    // anything counted that way, and the skins board settled the same
    // question one board ago: play order for the walk, hole number for the
    // grid — a scorecard is a scorecard whatever order it was played in.
    final split = NineSplit.of([...data.holesInPlay]..sort());
    final next = data.nextHole;

    // **A nine draws once one of its holes is played, and the nine holding
    // the next hole always draws.** The reference hides the back nine until
    // hole 10, which assumes a round that starts at the 1st: off a shotgun
    // from the 10th the back nine is the one being played and the front is
    // the one that has not started.
    bool show(List<int> nine) {
      if (nine.isEmpty) return false;
      if (nine.any((h) => data.holes.containsKey(h))) return true;
      return next != null && nine.contains(next);
    }

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('POINTS BY HOLE',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                    color: Halved.muted)),
          ),
          const Text('5 · 3 · 1',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .4,
                  color: Halved.muted)),
        ]),
        if (show(split.front)) ...[
          const SizedBox(height: 10),
          _Nine(data: data, holes: split.front, label: 'Out', next: next),
        ],
        if (show(split.back)) ...[
          const SizedBox(height: 10),
          _Nine(data: data, holes: split.back, label: 'In', next: next),
        ],
        const SizedBox(height: 10),
        _key(),
      ]),
    );
  }

  Widget _key() => Container(
        padding: const EdgeInsets.only(top: 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFEEF3EE))),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 12, runSpacing: 6, children: [
            _keyItem(
                [for (final g in data.golfers) Halved.golfer(g.colourIndex)],
                'Low · 5'),
            _keyItem(
                [for (final g in data.golfers) Halved.golferTint(g.colourIndex)],
                'Second · 3'),
            _keyItem(const [Halved.surface], 'Third · 1'),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Each golfer’s own colour. A tie splits the places it covers: two '
            'tied for low take 4 each, two tied for second 2 each.',
            style: TextStyle(
                fontSize: 12, height: 1.4, color: Halved.muted),
          ),
        ]),
      );

  Widget _keyItem(List<Color> colours, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in colours) ...[
            Container(
              width: 9,
              height: 10,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 2),
          ],
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ],
      );
}

class _Nine extends StatelessWidget {
  const _Nine({
    required this.data,
    required this.holes,
    required this.label,
    required this.next,
  });

  final PointsBoardData data;
  final List<int> holes;
  final String label;
  final int? next;

  static const double _labelW = 40;
  static const double _totalW = 30;

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          const SizedBox(width: _labelW),
          for (final h in holes)
            Expanded(
              child: Center(
                child: Text('$h',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: h == next ? Halved.deepPine : Halved.muted)),
              ),
            ),
          SizedBox(
            width: _totalW,
            child: Text(label,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Halved.muted)),
          ),
        ]),
        for (final g in data.golfers) ...[
          const SizedBox(height: 4),
          _row(g),
        ],
      ]);

  Widget _row(PointsBoardGolfer g) {
    double sub = 0;
    var any = false;
    for (final h in holes) {
      final hole = data.holes[h];
      if (hole != null && hole.has(g.playerId)) {
        any = true;
        sub += hole.pointsFor(g.playerId);
      }
    }

    return Row(children: [
      SizedBox(
        width: _labelW,
        child: Text(g.shortName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: Halved.muted)),
      ),
      for (final h in holes)
        Expanded(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1.5),
          child: _cell(g, h),
        )),
      SizedBox(
        width: _totalW,
        child: Text(any ? formatPoints(sub) : '',
            textAlign: TextAlign.right,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700)),
      ),
    ]);
  }

  Widget _cell(PointsBoardGolfer g, int hole) {
    final h = data.holes[hole];
    if (h == null || !h.has(g.playerId)) {
      // The hole in play is outlined; everything still to come is dashed, so
      // the two never read as the same empty cell.
      return Container(
        height: 28,
        decoration: BoxDecoration(
          color: hole == next ? Halved.card : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: hole == next
              ? Border.all(color: Halved.deepPine, width: 2)
              : Border.all(color: Halved.cardBorder, width: 1.5),
        ),
      );
    }

    final v = h.pointsFor(g.playerId);
    // **Four and two are the split prices, not rounding.** Two tied for low
    // take 4 each and two tied for second 2 each, so a 4 is a share of the
    // low place and belongs in the solid colour with the 5s.
    final Color bg;
    final Color fg;
    if (v >= 4) {
      bg = Halved.golfer(g.colourIndex);
      fg = Colors.white;
    } else if (v >= 2) {
      bg = Halved.golferTint(g.colourIndex);
      fg = Halved.deepPine;
    } else {
      bg = Halved.surface;
      fg = Halved.muted;
    }

    return Container(
      height: 28,
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(6)),
      alignment: Alignment.center,
      child: Text(formatPoints(v),
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

// ── 3 · the ledger ──────────────────────────────────────────────────────

class _Ledger extends StatelessWidget {
  const _Ledger({required this.data});
  final PointsBoardData data;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(children: [
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
          child: Row(children: [
            Expanded(
              child: Text(data.roundOver ? 'Final, each' : 'Each · now',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFB9CCC3))),
            ),
            const SizedBox(width: 12),
            // Plain, so it keeps the right edge. A bare `Flexible` here
            // defaults to flex 1 and makes the two halves SPLIT the row,
            // which parks the stake in the middle of the header — visible
            // on a device and invisible in a widget test, because nothing
            // overflows.
            Text('\$${_plain(data.stake)} a point',
                maxLines: 1,
                style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ]),
        ),
        Container(
          color: Halved.card,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(children: const [
            Expanded(child: _Head('PLAYER', align: TextAlign.left)),
            SizedBox(width: 36, child: _Head('PTS')),
            SizedBox(width: 66, child: _Head('V. TARGET')),
            SizedBox(width: 74, child: _Head('\$')),
          ]),
        ),
        for (final g in data.ledger) _row(g),
        Container(height: 6, color: Halved.card),
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
          child: Row(children: [
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Target '),
                  TextSpan(
                      text: '${data.target} pts',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xFFB9CCC3)),
              ),
            ),
            const SizedBox(width: 16),
            if (data.roundOver)
              const Text('Final',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFFB9CCC3)))
            else
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Left '),
                    TextSpan(
                        text: '${data.holesLeft} '
                            '${data.holesLeft == 1 ? 'hole' : 'holes'}',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, color: Color(0xFFB9CCC3)),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _row(PointsBoardGolfer g) {
    final d = data.toTarget(g);
    final up = g.money > 0.004;

    return Container(
      color: Halved.card,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Expanded(
          child: Row(children: [
            _swatch(Halved.golfer(g.colourIndex), size: 9),
            const SizedBox(width: 8),
            Flexible(
              child: Text(g.shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (g.surname.isNotEmpty) ...[
              const SizedBox(width: 5),
              Flexible(
                child: Text(g.surname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Halved.muted)),
              ),
            ],
          ]),
        ),
        SizedBox(
          width: 36,
          child: Text(formatPoints(g.points),
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ),
        SizedBox(
          width: 66,
          child: Text(
              d == 0
                  ? 'E'
                  : '${d > 0 ? '+' : '−'}${formatPoints(d.abs())}',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: d > 0
                      ? Halved.pine
                      : d < 0
                          ? Halved.clayInk
                          : Halved.deepPine)),
        ),
        SizedBox(
          width: 74,
          child: Align(
            alignment: Alignment.centerRight,
            child: up
                ? Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: Halved.brightMint,
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(_money(g.money),
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Halved.deepPine)),
                  )
                : Text(_money(g.money),
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head(this.label, {this.align = TextAlign.right});
  final String label;
  final TextAlign align;

  @override
  Widget build(BuildContext context) => Text(label,
      textAlign: align,
      style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: .4,
          color: Halved.muted));
}
