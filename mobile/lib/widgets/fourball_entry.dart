import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'side_colour.dart';
import 'tray_edit_header.dart';

// Fourball score entry — `~/Downloads/handoff-fourball-score-entry`, and
// **Singles Match**, which its own handoff asks for as "the Fourball score
// entry with one golfer a side". Same card, same tray; the server sends
// `kind` (`best ball` or `net`) and each side's `sub` line, so the two
// differ in what they SAY rather than in what draws them.
//
// Two pieces: the side header over each pair on the golfer card, carrying
// that side's best ball as the two scores land, and the dark tray.
//
// **Neither computes anything.** The best balls, the hole, the match state
// and the close-out all arrive decided on `FourballHoleCard` — the `&M` in
// `3&2` especially, because only the server knows the group's play order.

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

/// `PAUL + LARRY` with `BEST` and the side's best net.
///
/// **Hidden after a close-out**, which the caller decides: past that hole
/// there is no team score for a ball to be the best of, and a tag that kept
/// filling in would be reporting a match that is over.
class FourballSideHeader extends StatelessWidget {
  final FourballHoleSide side;
  const FourballSideHeader({super.key, required this.side});

  @override
  Widget build(BuildContext context) {
    final colour = sideColour(side.side);
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
        const Text('BEST',
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700,
                letterSpacing: 0.5, color: Halved.muted)),
        const SizedBox(width: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(side.best?.toString() ?? '–',
              style: const TextStyle(
                  color: Colors.white, fontSize: 12.5,
                  fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }
}

/// The dark tray: what the hole did to the match, and where that leaves it.
///
/// **It IS the bottom bar while it is up**, like Points', Sixes', Wolf's,
/// Rabbit's and Las Vegas': the screen's pager hides underneath, so the
/// arrows here are the only ones on screen.
class FourballHoleTray extends StatelessWidget {
  final FourballHoleCard card;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// Go straight to Round over from a hole being played on after the match
  /// is already decided. Null hides the link.
  final VoidCallback? onFinishNow;

  final bool gettingResult;
  final bool notSynced;
  final bool picking;

  const FourballHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.onFinishNow,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
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
            title: gettingResult ? 'Getting result…' : _title(),
            onEdit: onEdit,
            picking: picking,
          ),
          if (!hold) ...[
            const SizedBox(height: 10),
            if (card.countsForCard)
              _ForTheCard(card: card)
            else
              _BestBall(card: card),
            const SizedBox(height: 10),
            _MatchCard(card: card),
            if (card.money.isNotEmpty) ...[
              const SizedBox(height: 10),
              _Money(card: card),
            ],
          ],
          const SizedBox(height: 12),
          _Buttons(card: card, onPrev: onPrev, onNext: onNext,
                   onFinishNow: onFinishNow),
        ],
      ),
    );
  }

  /// **`3 of 4 scored` is not a failure state.** After a close-out a golfer
  /// can pick up, and the tray rises on what the group actually played.
  ///
  /// Two golfers read `Both scores in`, because `All 2 scores in` is not a
  /// sentence.
  String _title() {
    final n = card.players.length;
    if (card.scored < n) return '${card.scored} of $n scored';
    return n == 2 ? 'Both scores in' : 'All $n scores in';
  }
}

/// `HOLE 5 · BEST BALL` — one row a side, with whose ball counted.
class _BestBall extends StatelessWidget {
  final FourballHoleCard card;
  const _BestBall({required this.card});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _TrayLabel('Hole ${card.hole} · ${card.kind}',
          trailing: card.staked ? _stake(card.stake) : 'no stakes'),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [for (final s in card.sides) _row(s)]),
      ),
    ]);
  }

  Widget _row(FourballHoleSide s) {
    final colour = sideColour(s.side, onDark: true);
    return Opacity(
      opacity: s.result == 'lost' ? 0.62 : 1.0,
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
                if (s.sub.isNotEmpty)
                  Text(s.sub,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: _secondary, fontSize: 11.5,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (s.result != null)
            Text(s.result!,
                style: TextStyle(
                    color: s.result == 'won' ? colour : _trayMuted,
                    fontSize: s.result == 'won' ? 15 : 13,
                    fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          if (s.best != null)
            Text.rich(TextSpan(children: [
              const TextSpan(text: 'net '),
              TextSpan(text: '${s.best}',
                  style: TextStyle(color: colour, fontSize: 28, height: 1.0,
                      fontWeight: FontWeight.w700)),
            ]), style: const TextStyle(color: _secondary, fontSize: 12,
                    fontWeight: FontWeight.w600))
          else
            const Text('–',
                style: TextStyle(color: _trayMuted, fontSize: 28,
                    height: 1.0, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// `HOLE 17 · FOR THE CARD` — past the close-out there is no team score, so
/// the rows are golfers rather than sides.
class _ForTheCard extends StatelessWidget {
  final FourballHoleCard card;
  const _ForTheCard({required this.card});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _TrayLabel('Hole ${card.hole} · for the card',
          trailing: 'match over'),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [for (final p in card.players) _row(p)]),
      ),
    ]);
  }

  Widget _row(FourballHolePlayer p) {
    final colour = sideColour(p.side, onDark: true);
    final out = p.gross == null;
    return Opacity(
      opacity: out ? 0.5 : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        child: Row(children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: colour, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(p.name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: out ? _secondary : Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ),
          if (out)
            const Text('no score',
                style: TextStyle(color: _trayMuted, fontSize: 12.5,
                    fontWeight: FontWeight.w600))
          else ...[
            Text('${p.gross}',
                style: TextStyle(color: colour, fontSize: 20, height: 1.0,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('net ${p.net}',
                style: const TextStyle(color: _secondary, fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ]),
      ),
    );
  }
}

/// Where the match stands, and the nine being played.
class _MatchCard extends StatelessWidget {
  final FourballHoleCard card;
  const _MatchCard({required this.card});

  @override
  Widget build(BuildContext context) {
    final m = card.match;
    final colour = m.leader == null
        ? Colors.white
        : sideColour(m.leader!, onDark: true);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: colour, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(m.headline,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(m.figure,
              style: TextStyle(color: colour, fontSize: 24, height: 1.0,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 3),
        Text(m.line,
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _secondary, fontSize: 12,
                fontWeight: FontWeight.w600)),
        if (card.strip.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            for (final h in card.strip) ...[
              Expanded(child: _Tile(hole: h)),
              if (h != card.strip.last) const SizedBox(width: 4),
            ],
          ]),
        ],
      ]),
    );
  }
}

class _Tile extends StatelessWidget {
  final FourballStripHole hole;
  const _Tile({required this.hole});

  @override
  Widget build(BuildContext context) {
    Color? fill;
    if (hole.result == 'T1') {
      fill = sideColour(1, onDark: true);
    } else if (hole.result == 'T2') {
      fill = sideColour(2, onDark: true);
    } else if (hole.result != null) {
      // Halved — white at 16%, which is neither side.
      fill = Colors.white.withValues(alpha: 0.16);
    }
    final won = hole.result == 'T1' || hole.result == 'T2';
    return Opacity(
      // A hole the match cannot reach is still drawn, because the group is
      // still going to play it.
      opacity: hole.dead ? 0.35 : 1.0,
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
        child: Text('${hole.hole}',
            style: TextStyle(
                color: won ? Halved.deepPine : Colors.white,
                fontSize: 10.5, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// `EACH · NOW` / `FINAL, EACH` — two rows, the leading side first.
class _Money extends StatelessWidget {
  final FourballHoleCard card;
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
              child: Text(card.match.isFinal ? 'FINAL, EACH' : 'EACH · NOW',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
            const Text('MONEY',
                style: TextStyle(
                    color: _secondary, fontSize: 10.5,
                    letterSpacing: 0.4, fontWeight: FontWeight.w700)),
          ]),
        ),
        for (final m in card.money) _row(m),
      ]),
    );
  }

  Widget _row(FourballMoneyRow m) {
    final colour = sideColour(m.side, onDark: true);
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
          child: Text(m.label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        _money(m.amount),
      ]),
    );
  }

  Widget _money(double v) {
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
  final FourballHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onFinishNow;
  const _Buttons({required this.card, required this.onPrev,
                  required this.onNext, required this.onFinishNow});

  @override
  Widget build(BuildContext context) {
    final last = card.nextHole == null;
    // **`play on` is the honest word for it.** The match is over and the
    // group is still playing golf; the button says which of those it does.
    final label = last
        ? 'Finish round ›'
        : (card.closedOut
            ? 'Hole ${card.nextHole} · play on ›'
            : 'Hole ${card.nextHole} ›');
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
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
      ]),
      // The way out of a match that is already decided, without walking the
      // rest of the card.
      if (card.closedOut && !last && onFinishNow != null)
        TextButton(
          onPressed: onFinishNow,
          style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(44, 40)),
          child: const Text('Finish round now',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline)),
        ),
    ]);
  }
}

class _TrayLabel extends StatelessWidget {
  final String text;
  final String? trailing;
  const _TrayLabel(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) => Row(children: [
        Flexible(
          child: Text(text.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: _secondary, fontSize: 10.5,
                  letterSpacing: 1.0, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        if (trailing != null && trailing!.isNotEmpty)
          Flexible(
            child: Text(trailing!.toUpperCase(),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: _secondary, fontSize: 11.5,
                    letterSpacing: 0.4, fontWeight: FontWeight.w700)),
          ),
      ]);
}

String _stake(double s) => s <= 0 ? 'no stakes' : '\$${_amt(s)} a golfer';

String _amt(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}
