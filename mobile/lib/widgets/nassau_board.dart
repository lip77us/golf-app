import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/nassau_board_model.dart';

/// The Nassau board — ONE widget for every Nassau leaderboard.
///
/// 2v2, 1v1, Triple Nassau (one match at a time), cup tabs and group bets,
/// per `~/Downloads/handoff-nassau-leaderboard`. Everything reaches it through
/// `NassauBoardData`, which reads the server's statuses and money rather than
/// deriving them — see that file for why.
class NassauBoard extends StatelessWidget {
  const NassauBoard({super.key, required this.data});

  final NassauBoardData data;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.showSides) ...[
          _SidesCard(data: data),
          const SizedBox(height: 10),
        ],
        if (data.single)
          _NineCard(data: data, bet: data.overall, startIndex: 0, bothNines: true)
        else ...[
          _NineCard(data: data, bet: data.front, startIndex: 0,
              points: data.claremont?.front),
          const SizedBox(height: 10),
          _NineCard(data: data, bet: data.back, startIndex: 9,
              points: data.claremont?.back),
        ],
        const SizedBox(height: 10),
        _MoneyCard(data: data),
      ],
    );
  }
}

Color _sideColour(NassauBoardData d, int? side) => side == null
    ? Halved.muted
    : (d.sides[side].colour ?? Halved.golfer(d.sides[side].colourIndex));

String _money(double v) {
  final a = v.abs();
  final n = a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
  if (v == 0) return '\$0';
  return '${v > 0 ? '+' : '−'}\$$n';
}

String _plain(double v) =>
    v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

class _Swatch extends StatelessWidget {
  const _Swatch(this.colour, {this.size = 9});
  final Color colour;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
            color: colour, borderRadius: BorderRadius.circular(2.5)),
      );
}

// ── sides ───────────────────────────────────────────────────────────────────

class _SidesCard extends StatelessWidget {
  const _SidesCard({required this.data});
  final NassauBoardData data;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Halved.card,
          border: Border.all(color: Halved.cardBorder, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          _Swatch(_sideColour(data, 0)),
          Flexible(
            child: Text(data.sides[0].name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text('vs',
                style: TextStyle(fontSize: 12, color: Halved.muted)),
          ),
          _Swatch(_sideColour(data, 1)),
          Flexible(
            child: Text(data.sides[1].name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}

// ── a nine ──────────────────────────────────────────────────────────────────

class _NineCard extends StatelessWidget {
  const _NineCard({
    required this.data,
    required this.bet,
    required this.startIndex,
    this.points,
    this.bothNines = false,
  });

  final NassauBoardData data;
  final NassauBetView bet;
  final int startIndex;
  final NassauBetView? points;
  /// A single 18-hole match draws both nines under one header.
  final bool bothNines;

  @override
  Widget build(BuildContext context) {
    final leaderColour = _sideColour(data, bet.leader);
    // A closed nine takes the winner's colour as its border — the one place
    // the card itself says who took it, without a second line of text.
    final border = bet.done && bet.leader != null
        ? BorderSide(color: leaderColour, width: 2)
        : const BorderSide(color: Halved.cardBorder, width: 1.5);

    final presses = data.presses.where((p) =>
        bothNines || (p.from >= startIndex + 1 && p.from <= startIndex + 9));

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.fromBorderSide(border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(bet.label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700)),
          const Spacer(),
          _Status(data: data, bet: bet),
        ]),
        const SizedBox(height: 8),
        _Tiles(data: data, startIndex: startIndex),
        if (bothNines) ...[
          const SizedBox(height: 4),
          _Tiles(data: data, startIndex: 9),
        ],
        if (points != null) ...[
          const SizedBox(height: 9),
          Row(children: [
            const Text('Points',
                style: TextStyle(fontSize: 12.5, color: Halved.muted)),
            const Spacer(),
            _Status(data: data, bet: points!),
          ]),
        ],
        for (final p in presses) ...[
          const SizedBox(height: 8),
          _PressRow(data: data, press: p, startIndex: startIndex),
        ],
      ]),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.data, required this.bet});
  final NassauBoardData data;
  final NassauBetView bet;

  @override
  Widget build(BuildContext context) {
    final colour = _sideColour(data, bet.leader);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (bet.leader != null) _Swatch(colour, size: 8),
      Text(bet.headline,
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700,
              color: bet.leader == null ? Halved.muted : colour)),
      const SizedBox(width: 6),
      Text(bet.sub,
          style: TextStyle(
              fontSize: 11,
              color: bet.done && bet.leader != null ? colour : Halved.muted)),
    ]);
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.data, required this.startIndex});
  final NassauBoardData data;
  final int startIndex;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = startIndex; i < startIndex + 9; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == startIndex + 8 ? 0 : 3),
              child: _Tile(
                hole: i + 1,
                winner: i < data.holes.length
                    ? data.holes[i]
                    : NassauHoleWinner.notPlayed,
                data: data,
              ),
            ),
          ),
      ]);
}

class _Tile extends StatelessWidget {
  const _Tile(
      {required this.hole, required this.winner, required this.data});
  final int hole;
  final NassauHoleWinner winner;
  final NassauBoardData data;

  @override
  Widget build(BuildContext context) {
    late final Color bg, fg;
    Border? border;
    switch (winner) {
      case NassauHoleWinner.side0:
        bg = _sideColour(data, 0); fg = Colors.white;
      case NassauHoleWinner.side1:
        bg = _sideColour(data, 1); fg = Colors.white;
      case NassauHoleWinner.halved:
        bg = Halved.surface; fg = Halved.muted;
      case NassauHoleWinner.notPlayed:
        bg = Colors.transparent; fg = Halved.cardBorder;
        border = Border.all(color: Halved.cardBorder, width: 1.2);
    }
    return Container(
      height: 26,
      decoration: BoxDecoration(
          color: bg, border: border, borderRadius: BorderRadius.circular(6)),
      alignment: Alignment.center,
      child: Text('$hole',
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

/// A press: a bar spanning the holes it covers, then its own status line.
class _PressRow extends StatelessWidget {
  const _PressRow(
      {required this.data, required this.press, required this.startIndex});
  final NassauBoardData data;
  final NassauPressView press;
  final int startIndex;

  @override
  Widget build(BuildContext context) {
    final colour = _sideColour(data, press.view.leader);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        for (var i = startIndex; i < startIndex + 9; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == startIndex + 8 ? 0 : 3),
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: (i + 1 >= press.from && i + 1 <= press.to)
                      ? colour
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 4),
      Row(children: [
        Text(press.label,
            style: const TextStyle(fontSize: 11.5, color: Halved.muted)),
        const Spacer(),
        Text('${press.view.headline} · ${press.view.sub}',
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700,
                color: press.view.leader == null ? Halved.muted : colour)),
      ]),
    ]);
  }
}

// ── money ───────────────────────────────────────────────────────────────────

class _MoneyCard extends StatelessWidget {
  const _MoneyCard({required this.data});
  final NassauBoardData data;

  @override
  Widget build(BuildContext context) {
    final o = data.overall;
    final amount = data.moneyForMe;
    final allDone = data.allDone;

    return Container(
      decoration: BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!data.single)
          _DarkRow(
            label: 'Overall · ${o.notStarted
                ? 'not started'
                : o.done ? 'Final' : 'thru ${o.holesPlayed}'}',
            value: o.headline,
            swatch: o.leader == null ? null : _sideColour(data, o.leader),
          ),
        if (data.claremont?.overall != null)
          _DarkRow(
            label: 'Points overall',
            value: data.claremont!.overall!.headline,
            swatch: data.claremont!.overall!.leader == null
                ? null
                : _sideColour(data, data.claremont!.overall!.leader),
          ),
        if (!data.noMoney) ...[
          const SizedBox(height: 10),
          Text(
            amount == 0
                ? 'All square${allDone ? '' : ' · now'}'
                : '${data.sides[data.me].name}'
                  '${allDone ? (amount > 0 ? ' won' : ' lost') : ''}'
                  ', each${allDone ? '' : ' · now'}',
            style: const TextStyle(fontSize: 12.5, color: Color(0xFFB9CCC3)),
          ),
          const SizedBox(height: 2),
          Text(_money(amount),
              style: TextStyle(
                  fontSize: 30, fontWeight: FontWeight.w700, height: 1.1,
                  color: amount == 0 ? Colors.white : Halved.brightMint)),
          const SizedBox(height: 10),
          Row(children: [
            _Term('Bet', data.stake),
            if (data.pressStake > 0) _Term('Press', data.pressStake),
            if (data.lossCap != null) _Term('Cap', data.lossCap!),
          ]),
        ],
      ]),
    );
  }
}

class _DarkRow extends StatelessWidget {
  const _DarkRow(
      {required this.label, required this.value, required this.swatch});
  final String label;
  final String value;
  final Color? swatch;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12.5, color: Color(0xFFB9CCC3))),
          const Spacer(),
          if (swatch != null) _Swatch(swatch!, size: 8),
          Text(value,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ]),
      );
}

class _Term extends StatelessWidget {
  const _Term(this.label, this.value);
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$label '),
            TextSpan(
                text: '\$${_plain(value)}',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ]),
          style: const TextStyle(fontSize: 11.5, color: Color(0xFFB9CCC3)),
        ),
      );
}
