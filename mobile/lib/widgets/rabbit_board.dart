import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/rabbit_board_model.dart';
import 'dashed_border.dart';

/// The Rabbit board — ONE widget for every Rabbit leaderboard.
///
/// `~/Downloads/handoff-rabbit-leaderboard`. Three cards: the rabbit in play
/// (or the round's summary once it is over), where every rabbit went hole by
/// hole, and the ledger. Everything reaches it through [RabbitBoardData],
/// which reads the engine rather than replaying the round.
class RabbitBoard extends StatelessWidget {
  const RabbitBoard({super.key, required this.data});

  final RabbitBoardData data;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          data.roundOver ? _RoundOver(data: data) : _LiveLeg(data: data),
          const SizedBox(height: 10),
          _ByHole(data: data),
          const SizedBox(height: 10),
          _Ledger(data: data),
        ],
      );
}

Color _colour(RabbitBoardData d, int? playerId) {
  final i = d.colourOf(playerId);
  return i < 0 ? Halved.muted : Halved.golfer(i);
}

String _money(double v) {
  final a = v.abs();
  final n = a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
  if (v == 0) return '\$0';
  return '${v > 0 ? '+' : '−'}\$$n';
}

String _plain(double v) =>
    v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

// ── 1 · the rabbit in play ──────────────────────────────────────────────

class _LiveLeg extends StatelessWidget {
  const _LiveLeg({required this.data});
  final RabbitBoardData data;

  @override
  Widget build(BuildContext context) {
    final leg = data.liveLeg;
    if (leg == null) return const SizedBox.shrink();
    final holder = data.currentHolderId;
    final colour = _colour(data, holder);
    final short = [
      for (final g in data.golfers)
        if (g.playerId == holder) g.shortName,
    ].firstOrNull;

    // "Can't be caught": the engine decides it, and says so by completing
    // the leg — a live leg is by definition still catchable.
    final heading = leg.isExtra
        ? 'EXTRA RABBIT · HOLES ${leg.range}'
        : 'RABBIT ${leg.index} OF ${data.rabbits.where((r) => !r.isExtra).length}'
          ' · HOLES ${leg.range}';

    final toPlay = leg.endHole - (data.nextHole ?? leg.endHole) + 1;

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.deepPine, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 6, height: 6,
            decoration: const BoxDecoration(
                color: Halved.brightMint, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text('LIVE · $heading',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 9.5, fontWeight: FontWeight.w700,
                    letterSpacing: .4, color: Halved.muted)),
          ),
          if (data.nextHole != null)
            Text(
                'Next: ${data.nextHole}'
                '${data.nextPar == null ? '' : ' · par ${data.nextPar}'}',
                style: const TextStyle(fontSize: 11, color: Halved.muted)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          if (holder != null) ...[
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                  color: colour, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(short ?? '—',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const Text('holds the rabbit',
                      style: TextStyle(fontSize: 11.5, color: Halved.muted)),
                ],
              ),
            ),
            Text('+${data.currentLead}',
                style: TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w700, height: 1,
                    color: colour)),
          ] else
            const Expanded(
              child: Text('Loose',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700,
                      color: Halved.muted)),
            ),
        ]),
        const SizedBox(height: 9),
        Text(
          [
            '\$${_plain(leg.value)} riding',
            if (leg.halfStake) 'half stake, one hole',
          ].join(' · '),
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600,
              color: Halved.deepPine),
        ),
        const SizedBox(height: 2),
        Text(
          [
            '${toPlay < 0 ? 0 : toPlay} to play',
            if (holder != null)
              data.accumulate
                  ? '${data.currentLead} ${data.currentLead == 1 ? 'loss' : 'losses'} set it loose'
                  : 'one loss sets it loose',
          ].join(' · '),
          style: const TextStyle(fontSize: 11.5, color: Halved.muted),
        ),
      ]),
    );
  }
}

/// The finish: one line per rabbit, and what it paid.
class _RoundOver extends StatelessWidget {
  const _RoundOver({required this.data});
  final RabbitBoardData data;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Halved.card,
          border: Border.all(color: Halved.cardBorder, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ROUND OVER',
              style: TextStyle(
                  fontSize: 9.5, fontWeight: FontWeight.w700,
                  letterSpacing: .4, color: Halved.muted)),
          const SizedBox(height: 6),
          for (final leg in data.rabbits) _legRow(leg),
        ]),
      );

  Widget _legRow(RabbitBoardLeg leg) {
    final colour = _colour(data, leg.holderId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(
          width: 62,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(leg.isExtra ? 'Extra' : 'Rabbit ${leg.index}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
              Text(leg.range,
                  style: const TextStyle(fontSize: 10, color: Halved.muted)),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: leg.loose
              ? const Text('Loose',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: Halved.muted))
              : Row(children: [
                  Container(
                    width: 9, height: 9,
                    decoration: BoxDecoration(
                        color: colour,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(leg.holderShort ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                ]),
        ),
        Text(
          leg.loose
              ? 'no winner'
              : leg.decidedOn != null
                  ? 'won on ${leg.decidedOn}'
                  : 'held to ${leg.endHole}',
          style: const TextStyle(fontSize: 11, color: Halved.muted),
        ),
        SizedBox(
          width: 52,
          child: Text(leg.loose ? '—' : _money(data.legWin(leg)),
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700,
                  color: leg.loose ? Halved.muted : Halved.pine)),
        ),
      ]),
    );
  }
}

// ── 2 · rabbit by hole ──────────────────────────────────────────────────

class _ByHole extends StatelessWidget {
  const _ByHole({required this.data});
  final RabbitBoardData data;

  @override
  Widget build(BuildContext context) {
    // **One column width for every row**, so the holes line up down the
    // card even though each rabbit covers a different stretch — which is
    // the whole point of the grid, and what rolling makes non-obvious.
    final first = data.holes.isEmpty ? 1 : data.holes.first.hole;
    final last = data.holes.isEmpty ? 18 : data.holes.last.hole;
    final span = (last - first + 1).clamp(1, 18);

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('RABBIT BY HOLE',
              style: TextStyle(
                  fontSize: 9.5, fontWeight: FontWeight.w700,
                  letterSpacing: .4, color: Halved.muted)),
          const Spacer(),
          Text(data.accumulate ? 'ACCUMULATE' : 'STOP AFTER ONE',
              style: const TextStyle(
                  fontSize: 9.5, fontWeight: FontWeight.w700,
                  letterSpacing: .4, color: Halved.muted)),
        ]),
        const SizedBox(height: 8),
        for (final leg in data.rabbits) ...[
          _legRow(leg, first, span),
          const SizedBox(height: 5),
        ],
        const SizedBox(height: 2),
        _Key(data: data),
      ]),
    );
  }

  Widget _legRow(RabbitBoardLeg leg, int first, int span) {
    final colour = _colour(data, leg.holderId);
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(
        width: 46,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(leg.label,
                style: const TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w700)),
            Text(
              leg.complete
                  ? (leg.loose
                      ? 'Loose'
                      : '${leg.holderShort ?? ''}'
                        '${leg.decidedOn != null ? '\nwon ${leg.decidedOn}' : ''}')
                  : 'Live',
              style: TextStyle(
                  fontSize: 8.5, height: 1.2,
                  color: leg.complete && !leg.loose ? colour : Halved.muted),
            ),
          ],
        ),
      ),
      const SizedBox(width: 4),
      Expanded(
        child: Row(children: [
          for (var i = 0; i < span; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == span - 1 ? 0 : 2),
                child: _cell(first + i, leg),
              ),
            ),
        ]),
      ),
    ]);
  }

  Widget _cell(int hole, RabbitBoardLeg leg) {
    if (hole < leg.startHole || hole > leg.endHole) {
      return const SizedBox(height: 26);
    }
    final h = data.holes.where((x) => x.hole == hole).firstOrNull;
    final isNext = hole == data.nextHole;

    if (h == null || !h.played) {
      if (isNext) {
        return Container(
          height: 26,
          decoration: BoxDecoration(
            border: Border.all(color: Halved.deepPine, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text('$hole',
              style: const TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
        );
      }
      return CustomPaint(
        painter: const DashedRRect(color: Halved.cardBorder, width: 1.2),
        child: SizedBox(
          height: 26,
          child: Center(
            child: Text('$hole',
                style: const TextStyle(
                    fontSize: 10, color: Halved.cardBorder)),
          ),
        ),
      );
    }

    // Filled in the colour of whoever HELD it after that hole — loose is
    // grey, which is the one state that is about nobody.
    final held = h.holderId;
    final bg = held == null ? Halved.surface : _colour(data, held);
    final fg = held == null ? Halved.muted : Colors.white;
    return Container(
      height: 26,
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$hole',
            style: TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.w700,
                color: fg, height: 1.1)),
        if (held != null && h.lead > 0)
          Text('+${h.lead}',
              style: TextStyle(
                  fontSize: 7.5, fontWeight: FontWeight.w600,
                  color: fg, height: 1.1)),
      ]),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.data});
  final RabbitBoardData data;

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String label, {bool outlined = false}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: outlined ? null : c,
                border: outlined ? Border.all(color: c, width: 1) : null,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(fontSize: 10, color: Halved.muted)),
          ],
        );
    return Wrap(spacing: 10, runSpacing: 4, children: [
      for (final g in data.golfers)
        item(Halved.golfer(g.colourIndex), g.shortName),
      item(Halved.muted, 'loose', outlined: true),
    ]);
  }
}

// ── 3 · the ledger ──────────────────────────────────────────────────────

class _Ledger extends StatelessWidget {
  const _Ledger({required this.data});
  final RabbitBoardData data;

  @override
  Widget build(BuildContext context) {
    final legs = data.rabbits;
    // With four rabbit columns there is no room for a surname.
    final firstNamesOnly = legs.length > 3;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(children: [
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
          child: Row(children: [
            Text(data.roundOver ? 'Final, each' : 'Each · now',
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFFB9CCC3))),
            const Spacer(),
            Text('\$${_plain(data.stake)} a rabbit',
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ]),
        ),
        Container(
          color: Halved.card,
          padding: const EdgeInsets.fromLTRB(16, 9, 16, 4),
          child: Row(children: [
            const Expanded(
              child: Text('PLAYER',
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      letterSpacing: .4, color: Halved.muted)),
            ),
            for (final l in legs)
              SizedBox(
                width: 24,
                child: Text(l.isExtra ? 'Ex' : 'R${l.index}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w700,
                        color: Halved.muted)),
              ),
            const SizedBox(
              width: 58,
              child: Text('\$',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      color: Halved.muted)),
            ),
          ]),
        ),
        for (final g in data.golfers)
          _row(g, legs, firstNamesOnly: firstNamesOnly),
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(children: [
            Text('Settled ${data.settled} of ${legs.length}',
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFFB9CCC3))),
            const Spacer(),
            Text(
                data.roundOver
                    ? 'Final'
                    : 'Left ${data.holesLeft} '
                      '${data.holesLeft == 1 ? 'hole' : 'holes'}',
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFFB9CCC3))),
          ]),
        ),
      ]),
    );
  }

  Widget _row(RabbitBoardGolfer g, List<RabbitBoardLeg> legs,
      {required bool firstNamesOnly}) {
    final up = g.money > 0;
    return Container(
      color: Halved.card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(children: [
        Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
              color: Halved.golfer(g.colourIndex),
              borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text(g.shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
            if (!firstNamesOnly && g.surname.isNotEmpty) ...[
              const SizedBox(width: 5),
              Text(g.surname,
                  style: const TextStyle(fontSize: 11, color: Halved.muted)),
            ],
          ]),
        ),
        for (final l in legs)
          SizedBox(width: 24, child: Center(child: _mark(l, g.playerId))),
        SizedBox(
          width: 58,
          child: up
              ? Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: Halved.brightMint,
                        borderRadius: BorderRadius.circular(7)),
                    child: Text(_money(g.money),
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700,
                            color: Halved.deepPine)),
                  ),
                )
              : Text(_money(g.money),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  /// `+` held it, `−` another golfer held it, `=` loose, `·` not started.
  /// Filled once the rabbit is settled, outlined while it is still live.
  Widget _mark(RabbitBoardLeg leg, int playerId) {
    final started = data.holes
        .any((h) => h.hole >= leg.startHole && h.hole <= leg.endHole && h.played);
    if (!started) {
      return const Text('·',
          style: TextStyle(fontSize: 13, color: Halved.cardBorder));
    }
    final held = leg.holderId == playerId;
    final loose = leg.holderId == null;
    final glyph = held ? '+' : (loose ? '=' : '−');
    final colour =
        held ? Halved.pine : (loose ? Halved.muted : Halved.muted);
    final filled = leg.complete;
    return Container(
      width: 17, height: 17,
      decoration: BoxDecoration(
        color: filled ? colour : null,
        border: filled ? null : Border.all(color: colour, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: Text(glyph,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, height: 1,
              color: filled ? Colors.white : colour)),
    );
  }
}
