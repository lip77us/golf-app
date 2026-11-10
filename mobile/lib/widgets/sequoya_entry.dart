import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'side_colour.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';

// Sequoya 3s score entry — `~/Downloads/handoff-sequoya-score-entry`.
//
// **Nothing here is a rule.** A match can carry three bets — the match, the
// auto press and one called by hand — each settling over its own holes, and
// the engine has all of it. Every chip, the standing line, the press offer
// and each golfer's money arrive composed on `SequoyaHoleCard`; this file
// lays them out.
//
// The sides are blue and orange (`side_colour.dart`), not the packet's pine
// and clay: the golfer rows above this tray have drawn a Sequoya side that
// way since the game shipped, and green is never a team in this app.

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

/// The dark tray: the hole, every bet in its match, and each golfer's money.
///
/// **It IS the bottom bar while it is up**, like every other tray: the
/// screen's pager hides underneath, so the arrows here are the only ones on
/// screen and the last hole's forward button finishes the round.
class SequoyaHoleTray extends StatelessWidget {
  final SequoyaHoleCard card;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// Call the press the card offers, for that side. The card decides whether
  /// there is one; this only says what to do when it is tapped.
  final void Function(int side)? onPress;

  final bool gettingResult;
  final bool notSynced;
  final bool picking;
  final bool pressing;

  const SequoyaHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.onPress,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
    this.pressing = false,
  });

  @override
  Widget build(BuildContext context) {
    final hold = gettingResult || notSynced;
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
                : 'All ${card.players.length} scores in',
            onEdit: onEdit,
            picking: picking,
          ),
          if (!hold)
            // **Bounded, and scrollable inside.** The last hole of a match
            // adds the partners-change card to a tray already carrying four
            // money rows, and the buttons below are the only pager.
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    TrayLabel(card.roundOver ? 'Round over' : card.label,
                        trailing: card.stakeLabel),
                    const SizedBox(height: 6),
                    _MatchCard(
                        card: card, onPress: onPress, pressing: pressing),
                    if (card.nextMatch != null) ...[
                      const SizedBox(height: 10),
                      TrayLabel('Next · partners change',
                          trailing: card.nextMatch!.repeats),
                      const SizedBox(height: 6),
                      _NextMatch(next: card.nextMatch!),
                    ],
                    if (card.money.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _Money(card: card),
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

/// Who won the hole, every bet it moved, and where the match stands.
class _MatchCard extends StatelessWidget {
  final SequoyaHoleCard card;
  final void Function(int side)? onPress;
  final bool pressing;
  const _MatchCard({required this.card, this.onPress, this.pressing = false});

  @override
  Widget build(BuildContext context) {
    final press = card.press;
    final leader = card.standingLeader;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Header(card: card),
        const SizedBox(height: 8),
        Wrap(
          spacing: 5, runSpacing: 5,
          children: [for (final c in card.bets) _Chip(chip: c)],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(height: 1, color: const Color(0x14FFFFFF)),
        ),
        Row(children: [
          // The standing yields; the tail (`1 to play`) and the Press button
          // are the two things on this line a reader acts on.
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: card.standing,
                    style: TextStyle(
                        color: leader == null
                            ? Colors.white
                            : sideColour(leader, onDark: true),
                        fontWeight: FontWeight.w700)),
                if (card.standingTail.isNotEmpty)
                  TextSpan(
                      text: ' · ${card.standingTail}',
                      style: const TextStyle(
                          color: _secondary, fontWeight: FontWeight.w600)),
              ]),
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
          if (press != null && onPress != null) ...[
            const SizedBox(width: 8),
            _PressButton(
                onPress: () => onPress!(press.side), busy: pressing),
          ],
        ]),
        if (press != null && onPress != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(press.note,
                style: const TextStyle(
                    color: _secondary, fontSize: 11.5, height: 1.35,
                    fontWeight: FontWeight.w500)),
          ),
      ]),
    );
  }
}

/// `Paul + Mike v Dave + Sam`, with the hole's result and the nets behind it.
class _Header extends StatelessWidget {
  final SequoyaHoleCard card;
  const _Header({required this.card});

  @override
  Widget build(BuildContext context) {
    final r = card.result;
    return LayoutBuilder(builder: (context, box) => Row(children: [
      // **Each name yields on its own.** One `Text.rich` ellipsises from the
      // right, which takes the SECOND side away entirely.
      //
      // `Expanded`, with the result capped rather than both `Flexible`: two
      // flexibles split the row evenly whatever either needs, which
      // ellipsises four names beside a chip with room to spare.
      Expanded(
        child: Row(children: [
          for (var i = 0; i < card.sides.length && i < 2; i++) ...[
            if (i == 1)
              const Text('  v  ',
                  style: TextStyle(color: _trayMuted, fontSize: 12,
                      fontWeight: FontWeight.w700)),
            Flexible(
              child: Text(card.sides[i].label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: sideColour(card.sides[i].side, onDark: true),
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ),
          ],
        ]),
      ),
      if (r != null) ...[
        const SizedBox(width: 8),
        Container(
          constraints: BoxConstraints(maxWidth: box.maxWidth * 0.55),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: r.winner == null
                ? Colors.white.withValues(alpha: 0.14)
                : sideColour(r.winner!, onDark: true),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: r.text,
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w800)),
              if (r.nets.isNotEmpty)
                TextSpan(
                    text: '  ${r.nets}',
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w600)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: r.winner == null ? Colors.white : Halved.deepPine),
          ),
        ),
      ],
    ]));
  }
}

/// A bet, a press, or a press that has not started.
///
/// The three states are the design's, and the same three Nassau's tray
/// draws: a live bet is outlined, a press that has not reached its first
/// hole is DASHED (it is a promise, not a bet), and a finished bet is filled
/// and un-outlined because nothing more can happen to it.
class _Chip extends StatelessWidget {
  final SequoyaBetChip chip;
  const _Chip({required this.chip});

  @override
  Widget build(BuildContext context) {
    final stateColour = chip.leader == null
        ? Colors.white
        : sideColour(chip.leader!, onDark: true);
    final text = Text.rich(
      TextSpan(children: [
        TextSpan(
            text: chip.text,
            style: TextStyle(
                color: chip.isPending ? Colors.white : _secondary)),
        if (chip.state.isNotEmpty)
          TextSpan(
              text: ' ${chip.state}', style: TextStyle(color: stateColour)),
      ]),
      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
    );
    const pad = EdgeInsets.symmetric(horizontal: 8, vertical: 3);
    if (chip.isPending) {
      return CustomPaint(
        painter: DashedRRect(
            color: Colors.white.withValues(alpha: 0.45), width: 1, radius: 8),
        child: Padding(padding: pad, child: text),
      );
    }
    return Container(
      padding: pad,
      decoration: BoxDecoration(
        color: chip.isFinal ? Colors.white.withValues(alpha: 0.10) : null,
        borderRadius: BorderRadius.circular(8),
        border: chip.isFinal
            ? null
            : Border.all(color: Colors.white.withValues(alpha: 0.30)),
      ),
      child: text,
    );
  }
}

class _PressButton extends StatelessWidget {
  final VoidCallback onPress;
  final bool busy;
  const _PressButton({required this.onPress, required this.busy});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 30,
        child: FilledButton(
          onPressed: busy ? null : onPress,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Halved.deepPine,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(60, 30),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999)),
          ),
          child: busy
              ? const SizedBox(
                  width: 13, height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Halved.deepPine))
              : const Text('Press',
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w800)),
        ),
      );
}

/// `Match 4 from 10`, the new sides, and what the first hole opens.
///
/// Dashed, because it has not started — the same reading a pending press
/// chip gets one card up.
class _NextMatch extends StatelessWidget {
  final SequoyaNextMatch next;
  const _NextMatch({required this.next});

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: DashedRRect(
            color: Colors.white.withValues(alpha: 0.35), width: 1, radius: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: SizedBox(
            width: double.infinity,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Match ${next.index} from ${next.startHole}',
                  style: const TextStyle(color: Colors.white, fontSize: 13.5,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Row(children: [
                Flexible(
                  child: Text(next.side1,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: sideColour(1, onDark: true),
                          fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                const Text('  v  ',
                    style: TextStyle(color: _trayMuted, fontSize: 12,
                        fontWeight: FontWeight.w700)),
                Flexible(
                  child: Text(next.side2,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: sideColour(2, onDark: true),
                          fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ]),
              if (next.note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(next.note,
                      style: const TextStyle(color: _secondary, fontSize: 11.5,
                          fontWeight: FontWeight.w500)),
                ),
            ]),
          ),
        ),
      );
}

/// `EACH · NOW` / `FINAL, EACH` — one row per GOLFER, highest first.
///
/// Per golfer and never per side: the partners change every three holes, so
/// no two golfers share a figure for long. The swatch is his side in the
/// match on screen.
class _Money extends StatelessWidget {
  final SequoyaHoleCard card;
  const _Money({required this.card});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 3, 13, 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 24,
          child: Row(children: [
            Expanded(
              child: Text(card.roundOver ? 'FINAL, EACH' : 'EACH · NOW',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
            Text(card.roundOver ? 'MONEY' : 'THRU ${card.thru}',
                style: const TextStyle(
                    color: _secondary, fontSize: 10.5,
                    letterSpacing: 0.4, fontWeight: FontWeight.w700)),
          ]),
        ),
        for (final m in card.money) _row(m),
      ]),
    );
  }

  Widget _row(SequoyaMoneyRow m) {
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
              color: m.side == null
                  ? _trayMuted
                  : sideColour(m.side!, onDark: true),
              borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(m.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        _figure(m.amount),
      ]),
    );
  }

  Widget _figure(double v) {
    final text = v == 0 ? '\$0' : '${v > 0 ? '+' : '−'}\$${_amt(v.abs())}';
    if (v <= 0) {
      return Text(text,
          style: TextStyle(
              color: v == 0 ? _secondary : Colors.white,
              fontSize: 13, fontWeight: FontWeight.w700));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Halved.brightMint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(color: Halved.deepPine, fontSize: 13,
              fontWeight: FontWeight.w700)),
    );
  }
}

class _Buttons extends StatelessWidget {
  final SequoyaHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Buttons({required this.card, required this.onPrev,
                  required this.onNext});

  @override
  Widget build(BuildContext context) {
    // **The last hole's forward button finishes the round.** This tray takes
    // the screen's pager away while it is up, so there is nothing else left
    // to finish it with. The label is the server's otherwise, because only
    // it knows the next hole opens a new match.
    final label = card.nextLabel == null
        ? 'Finish round ›'
        : '${card.nextLabel} ›';
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
            child: Text(label,
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
