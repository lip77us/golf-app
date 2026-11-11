import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'side_colour.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';
import 'tray_result_row.dart';

/// Triple Cup score entry — `handoff-triple-cup-score-entry` (11 Nov 2026).
///
/// The keypad and the dark tray the other games share, over a round cut in
/// thirds. What is new here is the tray's content: the hole, the match that
/// hole belongs to, and **the cup as of that hole**, which left the score
/// screen's body for this tray and for `TripleCupBoard`.
///
/// **Nothing is decided here.** `TripleCupHoleCard` arrives with every
/// sentence written — what a halved match is worth, when the cup can no
/// longer be lost, who pays whom — and this file draws it.

const Color _secondary = Color(0xFFB9CCC3);

/// A cup side's colour.
///
/// A casual cup is blue and orange, the app's two fixed sides. A team cup
/// wears the colours its teams were given at setup, lifted for the dark tray
/// — a team's own navy on deep pine is not a colour anybody can read.
Color tripleCupSideColour(String? name, int side, {bool onDark = false}) {
  if (name == null || name.trim().isEmpty) {
    return sideColour(side, onDark: onDark);
  }
  final base = resolveTripleCupTeamColor(
      name, side == 1 ? kTripleCupTeam1Color : kTripleCupTeam2Color);
  if (!onDark) return base;
  final hsl = HSLColor.fromColor(base);
  return hsl
      .withLightness(hsl.lightness < 0.70 ? 0.70 : hsl.lightness)
      .withSaturation(hsl.saturation > 0.75 ? 0.75 : hsl.saturation)
      .toColor();
}

/// The cup as a strip of point cells with a tick at the half-way line.
///
/// **Team 1 fills from the left and Team 2 from the right**, a half point is
/// half a cell, and what is still out stays uncoloured between them — so it
/// reads like a needle. It does not follow play order and it does not mark
/// the match in play. The lock screen's strip is the same rule.
class CupStrip extends StatelessWidget {
  final double team1;
  final double team2;
  final int cells;
  final Color colour1;
  final Color colour2;
  final Color empty;
  final Color tick;
  final double height;

  const CupStrip({
    super.key,
    required this.team1,
    required this.team2,
    required this.colour1,
    required this.colour2,
    this.cells = 4,
    this.empty = const Color(0x2BFFFFFF),
    this.tick = const Color(0xD9FFFFFF),
    this.height = 7,
  });

  /// How much of cell [i] each side fills — public so the rule is testable
  /// without measuring pixels.
  static (double, double) fills(double t1, double t2, int cells, int i) => (
        (t1 - i).clamp(0.0, 1.0),
        (t2 - (cells - 1 - i)).clamp(0.0, 1.0),
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height + 8,
      child: Stack(alignment: Alignment.center, children: [
        Row(children: [
          for (var i = 0; i < cells; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            Expanded(child: _cell(i)),
          ],
        ]),
        Container(
          width: 2, height: height + 8,
          decoration: BoxDecoration(
              color: tick, borderRadius: BorderRadius.circular(1)),
        ),
      ]),
    );
  }

  Widget _cell(int i) {
    final (a, b) = fills(team1, team2, cells, i);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: height,
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: empty),
          if (a > 0)
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: a,
              child: ColoredBox(color: colour1),
            ),
          if (b > 0)
            FractionallySizedBox(
              alignment: Alignment.centerRight,
              widthFactor: b,
              child: ColoredBox(color: colour2),
            ),
        ]),
      ),
    );
  }
}

/// The whole team cup as one continuous needle.
///
/// **Widths are shares of the points AVAILABLE, not of points scored**, so
/// the grey between them is genuinely what is still out and the tick
/// genuinely marks half the cup.
class CupNeedle extends StatelessWidget {
  final double team1;
  final double team2;
  final double total;
  final Color colour1;
  final Color colour2;
  final Color empty;
  final Color tick;
  final double height;

  const CupNeedle({
    super.key,
    required this.team1,
    required this.team2,
    required this.total,
    required this.colour1,
    required this.colour2,
    this.empty = const Color(0x2BFFFFFF),
    this.tick = const Color(0xD9FFFFFF),
    this.height = 7,
  });

  @override
  Widget build(BuildContext context) {
    final t = total <= 0 ? 1.0 : total;
    return SizedBox(
      height: height + 8,
      child: Stack(alignment: Alignment.center, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: height,
            child: Stack(fit: StackFit.expand, children: [
              ColoredBox(color: empty),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (team1 / t).clamp(0.0, 1.0),
                child: ColoredBox(color: colour1),
              ),
              FractionallySizedBox(
                alignment: Alignment.centerRight,
                widthFactor: (team2 / t).clamp(0.0, 1.0),
                child: ColoredBox(color: colour2),
              ),
            ]),
          ),
        ),
        Container(
          width: 2, height: height + 8,
          decoration: BoxDecoration(
              color: tick, borderRadius: BorderRadius.circular(1)),
        ),
      ]),
    );
  }
}

/// The dark tray: the hole, the match it belongs to, and the cup.
///
/// **It IS the bottom bar while it is up**, like every other tray: the
/// screen's pager hides underneath, so the arrows here are the only ones on
/// screen and on the last hole the forward button finishes the round.
class TripleCupHoleTray extends StatelessWidget {
  final TripleCupHoleCard card;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// The hole the forward button opens; null on the last one.
  final int? nextHole;

  final bool gettingResult;
  final bool notSynced;
  final bool picking;

  const TripleCupHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.nextHole,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
  });

  Color _c(int side) =>
      tripleCupSideColour(card.teamColours[side - 1], side, onDark: true);

  @override
  Widget build(BuildContext context) {
    final hold = gettingResult || notSynced;
    final maxH = MediaQuery.of(context).size.height * 0.72;
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
            title: gettingResult ? 'Getting result…' : _title(),
            onEdit: onEdit,
            picking: picking,
          ),
          if (!hold) ...[
            const SizedBox(height: 10),
            // The buttons sit OUTSIDE this box: they are the only pager on
            // screen while the tray is up, so the content scrolls and they
            // do not.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH - 130),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: _content(),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _buttons(),
        ],
      ),
    );
  }

  /// One ball a side is two scores, and `All 2 scores in` is not a sentence.
  String _title() {
    if (card.segment == 'foursomes') return 'Both balls in';
    final n = card.players.length;
    return n == 2 ? 'Both scores in' : 'All $n scores in';
  }

  List<Widget> _content() {
    final label = card.roundOver
        ? 'Round over'
        : 'Hole ${card.hole} · ${card.kind}';
    final trailing = card.span.isEmpty
        ? card.segmentLabel
        : '${card.segmentLabel} · ${card.span}';
    return [
      TrayLabel(label, trailing: trailing),
      const SizedBox(height: 6),
      for (final l in card.lines) ...[
        _holeLine(l),
        const SizedBox(height: 4),
        _matchCard(l),
        const SizedBox(height: 8),
      ],
      _cupCard(card.cup, strip: true),
      if (card.cupTotal != null) ...[
        const SizedBox(height: 8),
        _cupCard(card.cupTotal!, strip: false),
      ],
      if (card.next != null) ...[
        const SizedBox(height: 10),
        TrayLabel('Next · ${card.next!.label}', trailing: card.next!.span),
        const SizedBox(height: 6),
        _next(card.next!),
      ],
      if (card.money != null) ...[
        const SizedBox(height: 10),
        TrayLabel(card.money!.label, trailing: card.money!.stake),
        const SizedBox(height: 6),
        _money(card.money!),
      ],
    ];
  }

  BoxDecoration get _panel => BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      );

  /// The hole, in one line — the row the Nassau, Sixes and Fourball trays
  /// draw.
  Widget _holeLine(TripleCupLine l) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: _panel,
        child: TrayResultRow(
          name1: l.names[0],
          name2: l.names[1],
          colour1: _c(1),
          colour2: _c(2),
          decided: l.played,
          winner: l.winner,
          reasonLabel: l.reasonLabel,
          figure1: l.figure1,
          figure2: l.figure2,
        ),
      );

  /// The match, as of this hole.
  Widget _matchCard(TripleCupLine l) {
    final colour = l.leader == null ? Colors.white : _c(l.leader!);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: _panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: l.leader == null
                    ? Colors.white.withValues(alpha: 0.45) : colour,
                borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          // One flexible child: the head yields, the margin never does.
          Flexible(
            child: Text(l.head,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Text(l.margin,
              style: TextStyle(color: colour, fontSize: 24, height: 1.0,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text(l.sub,
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _secondary, fontSize: 12,
                fontWeight: FontWeight.w600)),
        if (card.showTiles && l.tiles.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            for (var i = 0; i < l.tiles.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(child: _tile(l.tiles[i])),
            ],
          ]),
        ],
      ]),
    );
  }

  Widget _tile(TripleCupTile t) {
    Color? fill;
    if (t.state == 't1') {
      fill = _c(1);
    } else if (t.state == 't2') {
      fill = _c(2);
    } else if (t.state == 'halved') {
      fill = Colors.white.withValues(alpha: 0.16);
    }
    final won = t.state == 't1' || t.state == 't2';
    return Opacity(
      opacity: t.state == 'dead' ? 0.35 : 1.0,
      child: Container(
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(6),
          border: fill == null
              ? Border.all(color: Colors.white.withValues(alpha: 0.22))
              : null,
        ),
        child: Text('${t.hole}',
            style: TextStyle(
                color: won ? Halved.deepPine : Colors.white,
                fontSize: 10.5, fontWeight: FontWeight.w700)),
      ),
    );
  }

  /// `THE CUP  1 – 0 of 4`, the strip, and the one line under it.
  Widget _cupCard(TripleCupScore s, {required bool strip}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: _panel,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(s.label.toUpperCase(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _secondary, fontSize: 10.5,
                      letterSpacing: 1.0, fontWeight: FontWeight.w700)),
            ),
            Text(s.team1,
                style: TextStyle(color: _c(1), fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text('–',
                  style: TextStyle(color: Colors.white, fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
            Text(s.team2,
                style: TextStyle(color: _c(2), fontSize: 13,
                    fontWeight: FontWeight.w700)),
            if (s.aside.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(s.aside,
                  style: const TextStyle(color: _secondary, fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ]),
          const SizedBox(height: 4),
          if (strip)
            CupStrip(
              team1: s.team1Points, team2: s.team2Points,
              cells: s.total.round().clamp(1, 12),
              colour1: _c(1), colour2: _c(2),
            )
          else
            CupNeedle(
              team1: s.team1Points, team2: s.team2Points, total: s.total,
              colour1: _c(1), colour2: _c(2),
            ),
          const SizedBox(height: 4),
          Text(s.line,
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _secondary, fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _next(TripleCupNext n) => CustomPaint(
        painter: DashedRRect(
            color: Colors.white.withValues(alpha: 0.40),
            width: 1.2, radius: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.title,
                    style: const TextStyle(color: Colors.white, fontSize: 14,
                        fontWeight: FontWeight.w700)),
                if (n.body.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(n.body,
                      style: const TextStyle(color: _secondary, fontSize: 12,
                          height: 1.3, fontWeight: FontWeight.w500)),
                ],
              ],
            ),
          ),
        ),
      );

  /// Winners take all: the winners and what each nets, then who pays. A
  /// halved cup says nothing changes hands rather than printing `$0`.
  Widget _money(TripleCupMoney m) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: _panel,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (m.winner != null)
            Row(children: [
              Flexible(
                child: Text(m.head,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _c(m.winner!), fontSize: 15,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Halved.brightMint,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(m.amount,
                    style: const TextStyle(color: Halved.deepPine,
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ]),
          if (m.winner != null) const SizedBox(height: 4),
          Text(m.line,
              style: TextStyle(
                  color: m.winner == null ? Colors.white : _secondary,
                  fontSize: m.winner == null ? 14 : 12,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  /// What the forward button says: the next SEGMENT where the hole ends one,
  /// which a generic pager has no way to know.
  String get forwardLabel {
    if (nextHole == null) {
      return card.tournament
          ? 'Finish round · cup leaderboard ›'
          : 'Finish round ›';
    }
    if (card.next != null && card.next!.button.isNotEmpty) {
      return '${card.next!.button} ›';
    }
    return 'Hole $nextHole ›';
  }

  Widget _buttons() => Row(children: [
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
              child: Text(forwardLabel,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ]);
}
