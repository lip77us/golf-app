/// widgets/rabbit_entry.dart
/// -------------------------
/// The Rabbit score-entry surfaces (`~/Downloads/handoff-rabbit-score-entry`).
///
/// Built on the SAME keypad and tray vocabulary as 40 Balls and Sixes, which
/// is what the packet asks for — `FortyBallsKeypad`, `ScoreNotation`, the
/// stroke-dot cap and the dark tray shape.
///
/// **Colour here is identity, not a side.** Three golfers, three slots off
/// `Halved.golfer`, fixed by roster order — so a man is the same colour on
/// this screen, the board and the lock screen. That is the opposite of Sixes,
/// where the colour says which side you are on this match and changes at the
/// turn.
///
/// Everything drawn comes off `RabbitHoleCard`, which the server builds from
/// the engine: who holds the rabbit, the lead, which hole decided it and what
/// takes over are its answers. The prototype derives them in the browser
/// because it has no engine.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'forty_balls_keypad.dart';
import 'stroke_dots.dart';

/// Labels and secondary text on the tray: NEUTRAL white, no hue — a
/// green-grey reads as one golfer's colour.
const Color _dim = Color(0x8CFFFFFF);

/// The tray's own panel, a shade up from the tray.
const Color _panel = Color(0xFF14312A);

String _money(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

// ── 1 · the hole ─────────────────────────────────────────────────────────────

/// Hole and par, the yardage, and who has the rabbit going into it.
class RabbitHoleHeader extends StatelessWidget {
  final RabbitHoleCard card;

  const RabbitHoleHeader({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final r = card.rabbit;
    final holder = card.players
        .where((p) => p.playerId == r.holderId)
        .cast<RabbitHolePlayer?>()
        .firstWhere((_) => true, orElse: () => null);
    final colour =
        holder == null ? Halved.surface : Halved.golfer(holder.colourIndex);

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Halved.deepPine,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${card.hole}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    height: 1.1,
                    fontWeight: FontWeight.w700)),
            if (card.par != null)
              Text('Par ${card.par}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (card.yards != null)
                Text('${card.yards} yds',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Halved.deepPine)),
              Text(
                [
                  if (card.strokeIndex != null) 'SI ${card.strokeIndex}',
                  if (card.nine.isNotEmpty) card.nine,
                ].join(' · '),
                style: const TextStyle(fontSize: 13, color: Halved.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: colour,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                holder == null
                    ? 'Loose'
                    : '${holder.short} +${r.lead}',
                style: TextStyle(
                    color: holder == null ? Halved.deepPine : Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '\$${_money(r.stake)} riding · ${r.toPlay} to play',
              style: const TextStyle(fontSize: 12, color: Halved.muted),
            ),
          ],
        ),
      ]),
    );
  }
}

// ── 2 · the golfers ──────────────────────────────────────────────────────────

/// The three golfers, each in their own colour, with the holder tagged.
class RabbitPlayersCard extends StatelessWidget {
  final RabbitHoleCard card;
  final int? activePlayerId;
  final ValueChanged<int>? onTapPlayer;

  /// Net Style Entry — passed in rather than read here, because the setting
  /// governs the whole app and this widget must not be a second place that
  /// decides what it means.
  final bool netStyle;

  /// Drawn under a golfer's name — the combo-tee chip and the Spots button
  /// live on this row too, and they belong to the screen rather than here.
  final Widget Function(RabbitHolePlayer p)? rowExtras;

  /// **What the group has actually typed**, which is not what the card says.
  ///
  /// The card is SERVER state and only moves when a hole is posted — so with
  /// three of four scores in, nothing had been sent and the rows stayed empty
  /// while the scorer was looking at the numbers he had just entered (Paul,
  /// 30 Oct 2026). This is the screen's effective map: saved, queued and
  /// unsaved merged, which is the same thing every other entry screen draws.
  final Map<int, int>? scores;

  const RabbitPlayersCard({
    super.key,
    required this.card,
    required this.netStyle,
    this.activePlayerId,
    this.onTapPlayer,
    this.rowExtras,
    this.scores,
  });

  @override
  Widget build(BuildContext context) {
    final r = card.rabbit;
    final n = card.players.length;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: double.infinity,
          color: const Color(0xFFF6F8F6),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Row(children: [
            Expanded(
              child: Text(
                (r.isExtra
                        ? 'Extra rabbit · holes ${r.startHole}–${r.endHole}'
                        : 'Rabbit ${r.index} · holes ${r.startHole}–${r.endHole}')
                    .toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: Halved.muted),
              ),
            ),
            Text('$n GOLFERS',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: Halved.muted)),
          ]),
        ),
        for (final p in card.players) _row(p),
      ]),
    );
  }

  /// The gross on screen: what has been typed, falling back to the card.
  int? _gross(RabbitHolePlayer p) {
    final typed = scores?[p.playerId];
    if (typed != null && typed > 0) return typed;
    // A 0 in the map is a CLEARED score, not a missing one.
    if (typed == 0) return null;
    return p.gross;
  }

  /// His net follows the gross on screen rather than the card's, or a typed
  /// score would sit above a stale net.
  int? _net(RabbitHolePlayer p) {
    final g = _gross(p);
    return g == null ? null : g - p.strokes;
  }

  Widget _row(RabbitHolePlayer p) {
    final active = p.playerId == activePlayerId;
    final colour = Halved.golfer(p.colourIndex);
    final extras = rowExtras?.call(p);
    return InkWell(
      onTap: onTapPlayer == null ? null : () => onTapPlayer!(p.playerId),
      child: Container(
        color: active ? const Color(0xFFE8F6EF) : null,
        child: IntrinsicHeight(
          child: Row(children: [
            Container(
              width: 4,
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: colour,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(p.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: Halved.deepPine)),
                      ),
                      const SizedBox(width: 6),
                      Text('CH ${p.courseHandicap}',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Halved.muted)),
                      if (p.isHolder) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: colour,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text('Rabbit +${card.rabbit.lead}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ]),
                    if (extras != null) extras,
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _netChip(p),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _scoreBox(p),
            ),
            const SizedBox(width: 12),
          ]),
        ),
      ),
    );
  }

  /// `net 4`, filling in that golfer's colour when he is the outright low.
  /// A tie lights none — which is the same rule that decides whether the
  /// rabbit moves at all.
  Widget _netChip(RabbitHolePlayer p) {
    final filled = p.isBest;
    final colour = Halved.golfer(p.colourIndex);
    return Container(
      width: 74,
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: filled ? colour : const Color(0xFFEDF1EE),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: 'net ',
            style: TextStyle(
                fontSize: 13,
                color: filled ? Colors.white70 : Halved.muted),
          ),
          TextSpan(
            text: _net(p)?.toString() ?? '–',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: filled ? Colors.white : Halved.deepPine),
          ),
        ]),
      ),
    );
  }

  Widget _scoreBox(RabbitHolePlayer p) {
    const w = 52.0, h = 52.0;
    final gross = _gross(p);
    final body = gross == null
        ? Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: Halved.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: p.playerId == activePlayerId
                    ? Halved.deepPine
                    : Halved.cardBorder,
                width: p.playerId == activePlayerId ? 2 : 1.2,
              ),
            ),
          )
        : ScoreNotation(
            score: gross,
            par: card.par ?? 4,
            strokes: netStyle ? p.strokes : 0,
            width: w,
            height: h,
            fontSize: 22,
          );

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [body, StrokeDotCap(strokes: p.strokes)],
      ),
    );
  }
}

// ── 3 · the tray ─────────────────────────────────────────────────────────────

/// What the hole did to the rabbit, once every score is in.
class RabbitHoleTray extends StatelessWidget {
  final RabbitHoleCard card;
  final VoidCallback onEdit;

  /// **The tray carries the pager and covers the screen's own.** Same call as
  /// Sixes: the forward button can name the next RABBIT, which a generic
  /// pager has no way to know.
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final int? nextHole;

  /// The result is on its way — what we hold predates the score just entered.
  final bool gettingResult;

  /// Saved on the phone, not yet at the server.
  final bool notSynced;

  const RabbitHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    required this.nextHole,
    this.onPrev,
    this.onNext,
    this.gettingResult = false,
    this.notSynced = false,
  });

  Color _colourOf(int? pid) {
    for (final p in card.players) {
      if (p.playerId == pid) return Halved.golfer(p.colourIndex);
    }
    return Halved.brightMint;
  }

  @override
  Widget build(BuildContext context) {
    final r = (gettingResult || notSynced) ? null : card.result;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Text('All ${card.players.length} scores in',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: onEdit,
              style: TextButton.styleFrom(
                  foregroundColor: Halved.brightMint,
                  minimumSize: const Size(44, 40)),
              child: const Text('Edit scores'),
            ),
          ]),
          _labelRow(
            card.rabbit.isExtra
                ? 'HOLE ${card.hole} · EXTRA RABBIT'
                : 'HOLE ${card.hole} · RABBIT ${card.rabbit.index} OF '
                    '${card.rabbit.of}',
            '\$${_money(card.rabbit.stake)} RIDING',
          ),
          const SizedBox(height: 6),
          if (r == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                gettingResult
                    ? 'Getting result…'
                    : 'Saved. The result shows once this hole syncs.',
                style: const TextStyle(color: _dim),
              ),
            )
          else
            _holeCard(r),
          if (r != null && r.legEnded && card.next != null) ...[
            const SizedBox(height: 8),
            _labelRow('NEXT', _nextRiding(card.next!)),
            const SizedBox(height: 4),
            _nextCard(card.next!, r),
          ],
          const SizedBox(height: 12),
          _buttons(r),
        ],
      ),
    );
  }

  String _nextRiding(RabbitNextLeg n) =>
      '\$${_money(n.stake)} RIDING${n.halfStake ? ' · HALF STAKE' : ''}';

  Widget _labelRow(String left, String right) => Row(children: [
        Expanded(
          child: Text(left,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: _dim,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
        ),
        Text(right,
            style: const TextStyle(
                color: _dim,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      ]);

  Widget _holeCard(RabbitHoleOutcome r) {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // **The chip gets the room, not the label.** `Hole 4` was
          // `Expanded` beside a `Flexible` chip, and both default to flex 1 —
          // so they split the row evenly, leaving two words of white space on
          // the left and `No outright ...` ellipsised on the right (Paul, 30
          // Oct 2026). The label is three characters and a number; it takes
          // its natural width and the chip takes everything else.
          Row(children: [
            Text('Hole ${card.hole}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16)),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _winnerChip(r),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          _rabbitLine(r),
          if (r.line.isNotEmpty || r.legEnded) ...[
            const SizedBox(height: 4),
            _whatHappened(r),
          ],
        ],
      ),
    );
  }

  /// "Paul wins hole 10 · net 4 v 5" in his colour, or a neutral
  /// "No outright winner" — which is the hole where nothing moves.
  Widget _winnerChip(RabbitHoleOutcome r) {
    final won = !r.noWinner;
    final fill =
        won ? _colourOf(r.winnerId) : const Color(0x33FFFFFF);
    final ink = won ? Colors.white : Colors.white;
    final nets = (r.bestNet == null || r.runnerNet == null)
        ? ''
        : 'net ${r.bestNet} v ${r.runnerNet}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: Text(
              won
                  ? '${r.winnerShort} wins hole ${card.hole}'
                  : 'No outright winner',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: ink, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        if (nets.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(nets,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: ink.withValues(alpha: 0.75), fontSize: 11)),
          ),
        ],
      ]),
    );
  }

  /// Where the rabbit sits after the hole: held, loose, or won.
  Widget _rabbitLine(RabbitHoleOutcome r) {
    final won = r.legOutcome == 'won';
    final colour = _colourOf(r.holderId);
    return Row(children: [
      if (!r.loose) ...[
        Container(
          width: 10,
          height: 10,
          decoration:
              BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Text(
          r.loose
              ? 'Loose'
              : won
                  ? '${r.holderShort} wins '
                      '${card.rabbit.isExtra ? 'the extra rabbit' : 'rabbit ${card.rabbit.index}'}'
                  : '${r.holderShort} holds the rabbit',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        won ? 'Won' : (r.loose ? '' : '+${r.lead}'),
        style: TextStyle(
            color: won ? Halved.brightMint : colour,
            fontWeight: FontWeight.w700,
            fontSize: won ? 22 : 20),
      ),
    ]);
  }

  /// The third line: what happened, and what is at risk — or, once the rabbit
  /// has ended, where the money went.
  Widget _whatHappened(RabbitHoleOutcome r) {
    final stake = _money(card.rabbit.stake);
    String head = '';
    String tail = r.line;
    if (r.legOutcome == 'won') {
      head = r.heldToEnd ? 'Held to ${card.hole}' : 'Won on ${card.hole}';
      final money = ' · \$$stake from each, +\$${_money(card.payout)}';
      tail = r.line.isEmpty ? money : ' · ${r.line}$money';
    } else if (r.legOutcome == 'loose') {
      head = 'Loose at ${card.hole}';
      final n = card.next;
      tail = n == null
          ? ' · nobody held it'
          : ' · \$$stake carries into '
              '${n.isExtra ? 'the extra rabbit' : 'rabbit ${n.index}'}';
    } else {
      tail = r.line;
    }
    return Text.rich(
      TextSpan(children: [
        if (head.isNotEmpty)
          TextSpan(
              text: head,
              style: const TextStyle(
                  color: Halved.brightMint,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
        TextSpan(
            text: tail,
            style: const TextStyle(color: _dim, fontSize: 13)),
      ]),
    );
  }

  Widget _nextCard(RabbitNextLeg n, RabbitHoleOutcome r) {
    final title = n.isExtra
        ? 'Extra rabbit · holes ${n.startHole}–${n.endHole}'
        : 'Rabbit ${n.index} from ${n.startHole} · '
            'holes ${n.startHole}–${n.endHole}';
    // Counted, never `end − start + 1`: a shotgun leg wraps the turn, where
    // the last hole has the smaller number.
    final len = n.holes;
    // **A rabbit decided on its own last hole did not end early** — it ran
    // its full window and the next one starts where it always would have
    // (Paul, 30 Oct 2026). Only a leg whose tail was handed on cut anything.
    final why = n.isExtra
        ? 'The holes left after the last rabbit play as an extra'
            '${n.halfStake ? ' — one hole, so half the stake.' : '.'}'
        : r.endedEarly
            ? 'Rabbit ${card.rabbit.index} ended early, so rabbit ${n.index} '
                'starts on ${n.startHole} and runs $len holes.'
            : 'Rabbit ${card.rabbit.index} ran all '
                '${card.rabbit.holes} holes, so rabbit ${n.index} takes the '
                'next $len.';
    return CustomPaint(
      painter: const DashedRRect(color: Color(0x4DFFFFFF), width: 1),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14)),
            const SizedBox(height: 2),
            Text(why, style: const TextStyle(color: _dim, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buttons(RabbitHoleOutcome? r) {
    final n = (r != null && r.legEnded) ? card.next : null;
    final label = nextHole == null
        ? 'Done'
        : n == null
            ? 'Hole $nextHole ›'
            : n.isExtra
                ? 'Extra rabbit · hole $nextHole ›'
                : 'Rabbit ${n.index} · hole $nextHole ›';
    return Row(children: [
      SizedBox(
        width: 48,
        height: 48,
        child: OutlinedButton(
          onPressed: onPrev,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            side: const BorderSide(color: Color(0x4DFFFFFF)),
            foregroundColor: Colors.white,
          ),
          child: const Text('‹', style: TextStyle(fontSize: 20)),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Halved.deepPine,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ),
      ),
    ]);
  }
}
