import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';
import 'tray_result_row.dart';

/// Mini Singles, a group of three — `handoff-mini-singles-three-score-entry`.
///
/// **A second mode of the four-man screen, not a new screen**: the same
/// keypad, rows, dark tray, Fourball-style hole line and result table. Nine
/// holes of points (5-3-1) decide who plays the finals over the back nine;
/// while 2nd is level points play on and the finals is scored from the 10th
/// against both. The card is the server's
/// (`three_person_hole_card`); nothing here decides a result.
///
/// Each golfer keeps his own colour for the round (the leaderboard's: pine,
/// clay, slate), by seat — which is also what tells the finals' two colours
/// apart from a points table's three.
const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

Color _light(int seat) => Halved.golfer(seat);
Color _dark(int seat) => Halved.onDarkFor(seat);

int _seat(MiniSinglesThreeCard c, int? pid) {
  final i = c.players.indexWhere((p) => p.playerId == pid);
  return i < 0 ? 0 : i;
}

/// The header over the golfers: `POINTS · HOLES 1–9 · 5-3-1` with the running
/// totals, or `FINALS · HOLES 10–18` with the two finalists.
class MiniSinglesThreeHeader extends StatelessWidget {
  final MiniSinglesThreeCard card;
  const MiniSinglesThreeHeader({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final String left;
    final Widget right;
    if (card.isFinals) {
      left = 'FINALS · HOLES 10–18';
      right = const SizedBox.shrink();
    } else {
      left = card.playOn
          ? 'POINTS · PLAYING ON'
          : 'POINTS · HOLES 1–9 · 5-3-1';
      right = Text(
          [for (final t in card.totals) '${t.key} ${t.value}'].join(' · '),
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Halved.deepPine, fontSize: 12.5,
              fontWeight: FontWeight.w700));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: Halved.surface, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Text(left,
              style: const TextStyle(
                  color: Halved.muted, fontSize: 10.5, letterSpacing: 0.7,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(child: Align(alignment: Alignment.centerRight, child: right)),
        ]),
      ),
    );
  }
}

/// The dark tray: the points table (or the finals), then the money.
///
/// **It IS the bottom bar while it is up**, like every other tray.
class MiniSinglesThreeTray extends StatelessWidget {
  final MiniSinglesThreeCard card;
  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool gettingResult;
  final bool notSynced;
  final bool picking;

  const MiniSinglesThreeTray({
    super.key,
    required this.card,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
  });

  @override
  Widget build(BuildContext context) {
    final hold = gettingResult || notSynced;
    final label = card.roundOver
        ? 'Round over'
        : 'Hole ${card.hole} · ${card.isFinals ? 'Finals' : 'Points'}';
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrayEditHeader(
            title: gettingResult
                ? 'Getting result…'
                : notSynced ? 'Saving…' : 'All 3 scores in',
            onEdit: onEdit,
            picking: picking,
          ),
          if (!hold)
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    TrayLabel(label,
                        trailing:
                            card.pot > 0 ? '\$${_amt(card.pot)} pot' : null),
                    const SizedBox(height: 6),
                    if (card.isFinals && card.finals != null) ...[
                      _FinalsLine(card: card, f: card.finals!),
                      const SizedBox(height: 6),
                      _FinalsStanding(card: card, f: card.finals!),
                    ] else ...[
                      _PointsCard(card: card),
                      if (card.finalsCards.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _FinalsDashed(card: card),
                      ],
                    ],
                    if (card.nextTitle != null) ...[
                      const SizedBox(height: 6),
                      _Next(card: card),
                    ],
                    if (card.winnerName != null) ...[
                      const SizedBox(height: 6),
                      _Winner(card: card),
                    ],
                    if (card.hasResult) ...[
                      const SizedBox(height: 6),
                      _Result(card: card),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          _Buttons(card: card, onPrev: onPrev, onNext: onNext),
        ],
      ),
    );
  }
}

Widget _box({required Widget child, EdgeInsets? padding}) => Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.fromLTRB(13, 10, 13, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );

const _head = TextStyle(
    color: _secondary, fontSize: 10.5, letterSpacing: 0.6,
    fontWeight: FontWeight.w700);

/// `POINTS · HOLE · TOTAL`: place, swatch, name, `net 3 +5`, total in a box.
class _PointsCard extends StatelessWidget {
  final MiniSinglesThreeCard card;
  const _PointsCard({required this.card});

  @override
  Widget build(BuildContext context) => _box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Expanded(child: Text('POINTS', style: _head)),
            SizedBox(width: 60, child: Text('HOLE', style: _head,
                textAlign: TextAlign.right)),
            SizedBox(width: 64, child: Text('TOTAL', style: _head,
                textAlign: TextAlign.right)),
          ]),
          for (final r in card.table) _row(r),
          if (card.line.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(card.line,
                  style: const TextStyle(
                      color: _secondary, fontSize: 13.5, height: 1.3)),
            ),
        ]),
      );

  Widget _row(M3TableRow r) {
    final c = _dark(_seat(card, r.playerId));
    return Container(
      height: 40,
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x14FFFFFF)))),
      child: Row(children: [
        SizedBox(
          width: 30,
          child: Text(r.place,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.w700)),
        ),
        Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 10),
        Expanded(
          child: Text(r.first,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.w700)),
        ),
        // Number and unit in separate fixed cells so the digits line up.
        SizedBox(
          width: 60,
          child: Text.rich(
            TextSpan(children: [
              if (r.net != null)
                TextSpan(
                    text: 'net ${r.net}  ',
                    style: const TextStyle(color: _secondary, fontSize: 12)),
              if (r.pts != null)
                TextSpan(
                    text: '+${r.pts}',
                    style: TextStyle(
                        color: c, fontSize: 15, fontWeight: FontWeight.w800)),
            ]),
            textAlign: TextAlign.right, maxLines: 1,
            overflow: TextOverflow.fade, softWrap: false,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          width: 52, height: 28, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: r.mint ? Halved.brightMint : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(r.total,
              style: TextStyle(
                  color: r.mint ? Halved.deepPine : Colors.white,
                  fontSize: 15, fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }
}

/// The finals scored from the 10th while points play on — dashed, because it
/// is a promise rather than a result.
class _FinalsDashed extends StatelessWidget {
  final MiniSinglesThreeCard card;
  const _FinalsDashed({required this.card});

  @override
  Widget build(BuildContext context) => CustomPaint(
        foregroundPainter: const DashedRRect(
            color: Color(0x40FFFFFF), width: 1.2, radius: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: const [
                  Text('FINALS', style: _head),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text('from the 10th, against either',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(color: _secondary, fontSize: 12)),
                  ),
                ]),
                for (final f in card.finalsCards)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(children: [
                      Expanded(
                        child: Text(f.names,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15,
                                fontWeight: FontWeight.w600)),
                      ),
                      Text(f.text,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15,
                              fontWeight: FontWeight.w800)),
                    ]),
                  ),
              ]),
        ),
      );
}

/// `FINALS Paul v Sam   net 5 v 5  [Halved]`.
class _FinalsLine extends StatelessWidget {
  final MiniSinglesThreeCard card;
  final M3Finals f;
  const _FinalsLine({required this.card, required this.f});

  @override
  Widget build(BuildContext context) {
    final w = f.winnerId == null ? null : (f.winnerId == f.aId ? 1 : 2);
    return _box(
      padding: const EdgeInsets.fromLTRB(13, 8, 13, 8),
      child: Row(children: [
        const Text('FINALS  ', style: _head),
        Expanded(
          child: TrayResultRow(
            name1: f.names[0],
            name2: f.names[1],
            colour1: _dark(_seat(card, f.aId)),
            colour2: _dark(_seat(card, f.bId)),
            decided: f.winnerId != null || f.halved,
            winner: w,
            reasonLabel: 'net',
            figure1: f.nets.isNotEmpty ? f.nets[0] : null,
            figure2: f.nets.length > 1 ? f.nets[1] : null,
          ),
        ),
      ]),
    );
  }
}

/// The finals standing and the 10–18 tiles; once it is over, one line.
class _FinalsStanding extends StatelessWidget {
  final MiniSinglesThreeCard card;
  final M3Finals f;
  const _FinalsStanding({required this.card, required this.f});

  @override
  Widget build(BuildContext context) {
    if (f.overLine.isNotEmpty) {
      return _box(
          child: Text(f.overLine,
              style: const TextStyle(color: _secondary, fontSize: 13.5)));
    }
    final lead = f.leaderId;
    final c = lead == null ? Colors.white : _dark(_seat(card, lead));
    return _box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic, children: [
          if (lead != null) ...[
            Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 8),
            Text(f.leader,
                style: const TextStyle(
                    color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 14),
          ],
          Text(f.standing,
              style: TextStyle(
                  color: c, fontSize: 26, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 4),
        Text('thru ${f.thru} of 9 · ${f.toPlay} to play',
            style: const TextStyle(color: _secondary, fontSize: 13.5)),
        const SizedBox(height: 8),
        Row(children: [
          for (var i = 0; i < f.tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(child: _tile(f.tiles[i])),
          ],
        ]),
      ]),
    );
  }

  Widget _tile(M3Tile t) {
    final a = _dark(_seat(card, f.aId));
    final b = _dark(_seat(card, f.bId));
    Color? fill;
    Color fg = Colors.white;
    switch (t.state) {
      case 'a': fill = a; fg = Halved.deepPine; break;
      case 'b': fill = b; fg = Halved.deepPine; break;
      case 'h': fill = Colors.white.withValues(alpha: 0.18); break;
    }
    return Container(
      height: 30, alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(7),
        border: fill == null
            ? Border.all(color: Colors.white.withValues(alpha: 0.25))
            : null,
      ),
      child: FittedBox(
        child: Text('${t.hole}',
            style: TextStyle(
                color: t.state == 'x' ? _trayMuted : fg,
                fontSize: 12, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _Next extends StatelessWidget {
  final MiniSinglesThreeCard card;
  const _Next({required this.card});

  @override
  Widget build(BuildContext context) => _box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('NEXT · THE BACK NINE', style: _head),
          const SizedBox(height: 4),
          Text(card.nextTitle ?? '',
              style: const TextStyle(
                  color: Colors.white, fontSize: 15,
                  fontWeight: FontWeight.w700)),
        ]),
      );
}

class _Winner extends StatelessWidget {
  final MiniSinglesThreeCard card;
  const _Winner({required this.card});

  @override
  Widget build(BuildContext context) => _box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('GROUP WINNER', style: _head)),
            Text(card.winnerName ?? '',
                style: const TextStyle(
                    color: Halved.brightMint, fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ]),
          if ((card.winnerText ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(card.winnerText!,
                  style: const TextStyle(
                      color: _secondary, fontSize: 13.5, height: 1.3)),
            ),
        ]),
      );
}

/// `RESULT · THIS GROUP`, `PLACE`, `NET` — net of the entry.
class _Result extends StatelessWidget {
  final MiniSinglesThreeCard card;
  const _Result({required this.card});

  @override
  Widget build(BuildContext context) => _box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Expanded(child: Text('RESULT · THIS GROUP', style: _head)),
            SizedBox(width: 70, child: Text('PLACE', style: _head,
                textAlign: TextAlign.right)),
            SizedBox(width: 76, child: Text('NET', style: _head,
                textAlign: TextAlign.right)),
          ]),
          for (final r in card.result) _row(r),
        ]),
      );

  Widget _row(M3ResultRow r) {
    final v = r.net;
    return Container(
      height: 38,
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x14FFFFFF)))),
      child: Row(children: [
        Expanded(
          child: Text(r.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          width: 70,
          child: Text(r.place,
              textAlign: TextAlign.right,
              style: const TextStyle(color: _secondary, fontSize: 13.5)),
        ),
        SizedBox(
          width: 76,
          child: Align(
            alignment: Alignment.centerRight,
            child: v == null
                ? const SizedBox.shrink()
                : (v > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: Halved.brightMint,
                            borderRadius: BorderRadius.circular(6)),
                        child: Text('+\$${_amt(v)}',
                            style: const TextStyle(
                                color: Halved.deepPine, fontSize: 14,
                                fontWeight: FontWeight.w800)))
                    : Text(v == 0 ? '\$0' : '−\$${_amt(v.abs())}',
                        style: TextStyle(
                            color: v == 0 ? _secondary : Colors.white,
                            fontSize: 14, fontWeight: FontWeight.w700))),
          ),
        ),
      ]),
    );
  }
}

class _Buttons extends StatelessWidget {
  final MiniSinglesThreeCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Buttons({required this.card, this.onPrev, this.onNext});

  @override
  Widget build(BuildContext context) {
    final last = card.nextHole == null;
    return Row(children: [
      SizedBox(
        width: 50, height: 50,
        child: OutlinedButton(
          onPressed: onPrev,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
            foregroundColor: Colors.white,
          ),
          child: const Icon(Icons.chevron_left, size: 24),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Halved.deepPine,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(25)),
            ),
            child: Text(last ? 'Finish round ›' : 'Hole ${card.nextHole} ›',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    ]);
  }
}

String _amt(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}
