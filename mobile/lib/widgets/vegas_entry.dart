import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'side_colour.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';

// Las Vegas score entry — `~/Downloads/handoff-vegas-score-entry`.
//
// Two pieces: the side header that sits over each pair on the golfer card and
// fills in its number as the two scores land, and the dark tray that rises
// once all four are in.
//
// **Neither computes anything.** The numbers, the flip, the 9 cap, the carry
// and the money all arrive decided on `VegasHoleCard` — and the flip
// especially, because only the server knows whose birdie caused it.
//
// **The sides are BLUE and ORANGE, not the packet's pine and clay.**
// `docs/color-standard.md` is explicit: green, red and grey mean win, loss
// and neutral and are never a team; teams are blue and orange. The golfer
// rows under these headers have been drawing Vegas that way since the game
// shipped, and a header in a different colour from the rows it heads is
// worse than one in a different colour from the design.

/// The side colours — see `widgets/side_colour.dart`, which Fourball shares.
Color vegasSideColour(int side, {bool onDark = false}) =>
    sideColour(side, onDark: onDark);

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);
const Color _tag = Color(0xFFF2A86E);

/// `PAUL + DAVE` with the side's number — the live half of this game, because
/// what a golfer watches in Vegas is the number forming.
///
/// It shows the side's two nets as a number (`45`), which is what it is
/// before any rule touches it; the tray shows what the flip made of it. The
/// 9 cap IS in here, because capping is part of forming the number rather
/// than a rule applied to it — which is also the order the engine works in.
class VegasSideHeader extends StatelessWidget {
  final VegasHoleSide side;
  const VegasSideHeader({super.key, required this.side});

  @override
  Widget build(BuildContext context) {
    final colour = vegasSideColour(side.side);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
      child: Row(children: [
        Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
              color: colour, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(side.label.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w800,
                  letterSpacing: 0.5, color: colour)),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(6),
          ),
          // An em dash until both scores are in: a one-digit number would
          // read as a very good hole rather than as half a hole.
          child: Text(side.raw?.toString() ?? '–',
              style: const TextStyle(
                  color: Colors.white, fontSize: 12.5,
                  fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }
}

/// The dark tray: the two numbers, what the rules did to them, and where
/// that leaves the round.
///
/// **It IS the bottom bar while it is up**, like Points', Sixes', Wolf's and
/// Rabbit's: the screen's pager hides underneath, so the arrows here are the
/// only ones on screen — which is what lets the forward button say
/// `Finish round ›` on the last hole instead of leaving the group at a dead
/// end.
class VegasHoleTray extends StatelessWidget {
  final VegasHoleCard card;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// The result is on its way — what we hold predates the score just
  /// entered, so it is not drawn.
  final bool gettingResult;

  /// Saved on the phone, not yet at the server.
  final bool notSynced;

  /// `Edit scores` is open and waiting for a row to be tapped.
  final bool picking;

  const VegasHoleTray({
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
    final over = card.roundOver;
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
          // **Not `Round over` here.** The label directly below says exactly
          // that, 20pt away, and one fact stated twice in one corner is how
          // the two come to disagree.
          TrayEditHeader(
            title: gettingResult ? 'Getting result…' : 'All 4 scores in',
            onEdit: onEdit,
            picking: picking,
          ),
          if (!hold) ...[
            const SizedBox(height: 10),
            _Numbers(card: card, over: over),
            const SizedBox(height: 10),
            if (over && card.winnerBox != null) ...[
              _Winner(winner: card.winnerBox!),
              const SizedBox(height: 10),
            ],
            _Standing(card: card, over: over),
          ],
          const SizedBox(height: 12),
          _Buttons(card: card, onPrev: onPrev, onNext: onNext, over: over),
        ],
      ),
    );
  }
}

/// `HOLE 7 · THE NUMBERS` — one row a side, then what the hole was worth.
class _Numbers extends StatelessWidget {
  final VegasHoleCard card;
  final bool over;
  const _Numbers({required this.card, required this.over});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TrayLabel(over ? 'Round over' : 'Hole ${card.hole} · the numbers',
          // The note replaces the stake, because `×2 carried` is the thing a
          // reader needs on the one hole it is true of.
          trailing: card.note.isNotEmpty ? card.note : _stake(card.stake)),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [
          for (final s in card.sides) _row(s),
          if (card.winner != null) ...[
            Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4),
                color: Colors.white.withValues(alpha: 0.08)),
            _result(),
          ],
        ]),
      ),
    ]);
  }

  Widget _row(VegasHoleSide s) {
    final colour = vegasSideColour(s.side, onDark: true);
    // The losing side is dimmed rather than greyed: it is still that side's
    // colour, just not the one that won.
    final dim = s.result == 'lost' ? 0.62 : 1.0;
    return Opacity(
      opacity: dim,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        child: Row(children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: colour, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.label,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14,
                        fontWeight: FontWeight.w700)),
                if (s.nets.isNotEmpty)
                  Text('net ${s.nets.join(' · ')}',
                      style: const TextStyle(
                          color: _secondary, fontSize: 11.5,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          // The rules that moved the number, named on the side they held.
          if (s.capped) const _RuleTag('9 cap'),
          if (s.flipped) const _RuleTag('flipped'),
          const SizedBox(width: 8),
          // A flip shows what the number WAS, struck through, because the
          // swing is the point and `65` on its own is not checkable against
          // the two nets beside it.
          if (s.flipped && s.raw != null) ...[
            Text('${s.raw}',
                style: const TextStyle(
                    color: _trayMuted, fontSize: 15,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: _trayMuted)),
            const SizedBox(width: 6),
          ],
          Text(s.number?.toString() ?? '–',
              style: TextStyle(color: colour, fontSize: 28, height: 1.0,
                  fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Widget _result() {
    final tied = card.winner == 'halved';
    final win = card.sides.where((s) => s.result == 'won').firstOrNull;
    final colour = tied
        ? _tag
        : vegasSideColour(win?.side ?? 1, onDark: true);
    final left = tied
        ? (card.tieNote.isEmpty ? 'Tied' : 'Tied · ${card.tieNote}')
        : '${win?.label ?? ''} by';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      child: Row(children: [
        Expanded(
          child: Text(left,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 8),
        Text('${card.points} pts',
            style: TextStyle(color: colour, fontSize: 17,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _RuleTag extends StatelessWidget {
  final String text;
  const _RuleTag(this.text);

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _tag, width: 1),
        ),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: _tag, fontSize: 9,
                letterSpacing: 0.5, fontWeight: FontWeight.w800)),
      );
}

/// `EACH · NOW` / `FINAL, EACH` — two rows, one per side, leading side first.
class _Standing extends StatelessWidget {
  final VegasHoleCard card;
  final bool over;
  const _Standing({required this.card, required this.over});

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
              child: Text(over ? 'FINAL, EACH' : 'EACH · NOW',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
            const _Head('Hole', 44),
            const _Head('Pts', 52),
            const _Head('Money', 66),
          ]),
        ),
        for (final s in card.standing) _row(s),
      ]),
    );
  }

  Widget _row(VegasStandingRow s) {
    final colour = vegasSideColour(s.side, onDark: true);
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
              color: colour, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(s.label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        // **Shrunk to fit, never wrapped or clipped.** A Vegas figure has no
        // ceiling — a ×3 carried hole can pay three digits and a round can
        // finish past 200 — and a number that wraps inside a fixed-height
        // row is the one thing on this tray that must stay readable.
        _Figure(
          width: 44,
          child: Text(_signed(s.holePoints),
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: s.holePoints > 0
                      ? Halved.brightMint
                      : (s.holePoints < 0 ? Halved.onDark2 : _trayMuted),
                  fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        _Figure(
          width: 52,
          child: Text(_signed(s.points),
              textAlign: TextAlign.right,
              style: const TextStyle(color: _secondary, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ),
        _Figure(width: 66, child: _money(s.money)),
      ]),
    );
  }

  Widget _money(double m) {
    final text = m == 0 ? '\$0' : '${m > 0 ? '+' : '−'}\$${_amt(m.abs())}';
    if (m <= 0) {
      return Text(text,
          style: TextStyle(
              color: m == 0 ? _secondary : Colors.white,
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

/// A right-aligned column that SHRINKS its number rather than wrapping it.
class _Figure extends StatelessWidget {
  final double width;
  final Widget child;
  const _Figure({required this.width, required this.child});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: child,
        ),
      );
}

class _Head extends StatelessWidget {
  final String text;
  final double width;
  const _Head(this.text, this.width);

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Text(text.toUpperCase(),
            textAlign: TextAlign.right,
            style: const TextStyle(
                color: _secondary, fontSize: 10.5,
                letterSpacing: 0.4, fontWeight: FontWeight.w700)),
      );
}

/// `Paul + Dave win by 98 pts` — the round's own line, above the standing.
class _Winner extends StatelessWidget {
  final VegasRoundWinner winner;
  const _Winner({required this.winner});

  @override
  Widget build(BuildContext context) {
    final colour = vegasSideColour(winner.side, onDark: true);
    final m = winner.money;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: winner.level ? _trayMuted : colour,
                borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
                // **Level is not a win**, and naming a side that won nothing
                // would be the one false line on a card about money.
                winner.level
                    ? 'All square — nobody owes anybody'
                    : '${winner.label} win by ${winner.points} pts',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(m == 0 ? '\$0' : '${m > 0 ? '+' : '−'}\$${_amt(m.abs())}',
              style: TextStyle(color: winner.level ? _trayMuted : colour,
                  fontSize: 22, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 3),
        Text(
          winner.stake <= 0
              ? 'No stake'
              : 'each · ${_stake(winner.stake)}',
          style: const TextStyle(color: _secondary, fontSize: 12,
              fontWeight: FontWeight.w600),
        ),
      ]),
    );
  }
}

class _Buttons extends StatelessWidget {
  final VegasHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool over;
  const _Buttons({required this.card, required this.onPrev,
                  required this.onNext, required this.over});

  @override
  Widget build(BuildContext context) {
    final label = over || card.nextHole == null
        ? 'Finish round ›'
        : 'Hole ${card.nextHole} ›';
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


String _stake(double s) {
  if (s <= 0) return '';
  // Under a dollar reads in cents, which is how this game is played.
  if (s < 1) return '${(s * 100).round()}¢ a point';
  return '\$${_amt(s)} a point';
}

String _signed(int v) =>
    v == 0 ? '0' : '${v > 0 ? '+' : '−'}${v.abs()}';

String _amt(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}
