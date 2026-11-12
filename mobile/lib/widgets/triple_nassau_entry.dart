import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import '../widgets/stroke_dots.dart';
import '../widgets/tray_edit_header.dart';
import '../widgets/tray_label.dart';
import '../widgets/tray_result_row.dart';

/// Triple Nassau's score entry — `handoff-triple-nassau-score-entry`.
///
/// Three golfers, three 1 v 1 Nassaus. The card is the server's
/// (`triple_nassau_hole_card`); nothing here decides a result, a bet or a
/// press. What the widgets own is the drawing.
///
/// **Colour is a SEAT, fixed for the whole group.** The lock screen makes the
/// reader blue on his own phone, but this screen is shared by the three of
/// them, so a golfer keeps his colour (the leaderboard's) for everybody.
const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

/// A golfer's colour on a light card, by seat.
Color tripleNassauColour(int seat) => Halved.golfer(seat);

/// The same seat on the dark tray.
Color tripleNassauOnDark(int seat) => Halved.onDarkFor(seat);

int _seatOf(TripleNassauHoleCard card, int? pid) {
  final i = card.players.indexWhere((p) => p.playerId == pid);
  return i < 0 ? 0 : i;
}

/// `Paul Lipkin  CH 4`, the pills under it and the score box with one dot a
/// match — **no net**, because a golfer's net is different in each match.
class TripleNassauPlayersCard extends StatelessWidget {
  final TripleNassauHoleCard card;

  /// Saved, queued and unsaved — the card's own `gross` is server state.
  final Map<int, int> scores;
  final int? activePlayerId;
  final ValueChanged<int> onTapPlayer;
  final Widget? Function(TripleNassauCardPlayer p)? rowExtras;

  const TripleNassauPlayersCard({
    super.key,
    required this.card,
    required this.scores,
    required this.onTapPlayer,
    this.activePlayerId,
    this.rowExtras,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD3DED6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: const Color(0xFFF4F7F4),
          child: const Row(children: [
            Expanded(
              child: Text('YOUR GROUP',
                  style: TextStyle(
                      color: Color(0xFF5C6B62), fontSize: 10.5,
                      letterSpacing: 0.8, fontWeight: FontWeight.w700)),
            ),
            Text('STROKES BY MATCH',
                style: TextStyle(
                    color: Color(0xFF5C6B62), fontSize: 10.5,
                    letterSpacing: 0.8, fontWeight: FontWeight.w700)),
          ]),
        ),
        for (final p in card.players) _row(p),
      ]),
    );
  }

  Widget _row(TripleNassauCardPlayer p) {
    final colour = tripleNassauColour(p.seat);
    final active = p.playerId == activePlayerId;
    final gross = scores[p.playerId];
    final extras = rowExtras?.call(p);
    return InkWell(
      onTap: () => onTapPlayer(p.playerId),
      child: Container(
        decoration: BoxDecoration(
          color: active ? Halved.brightMint.withValues(alpha: 0.12) : null,
          border: Border(
              left: BorderSide(color: colour, width: 4),
              top: const BorderSide(color: Color(0xFFEBF0EC))),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        child: Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    if (p.courseHandicap != null) ...[
                      const SizedBox(width: 6),
                      Text('CH ${p.courseHandicap}',
                          style: const TextStyle(
                              color: Color(0xFF5C6B62), fontSize: 12.5,
                              fontWeight: FontWeight.w700)),
                    ],
                  ]),
                  if (p.pills.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(spacing: 6, runSpacing: 4, children: [
                        for (final pill in p.pills) _pill(pill),
                      ]),
                    ),
                  if (extras != null) extras,
                ]),
          ),
          const SizedBox(width: 8),
          _box(p, gross, active),
        ]),
      ),
    );
  }

  Widget _pill(TripleNassauPill pill) {
    // In the OPPONENT's colour, so the pill says which match it is.
    final c = pill.vsId == null
        ? const Color(0xFF5C6B62)
        : tripleNassauColour(_seatOf(card, pill.vsId));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.40)),
      ),
      child: Text(pill.text,
          style: TextStyle(
              color: c, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }

  /// The score box with **a stroke dot per match**, each in the colour of
  /// the opponent it is against — so Sam can carry a pine and a clay dot on
  /// the same hole.
  Widget _box(TripleNassauCardPlayer p, int? gross, bool active) {
    return SizedBox(
      width: 56, height: 44,
      child: Stack(alignment: Alignment.center, children: [
        Container(
          width: 44, height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: active
                    ? Halved.deepPine
                    : const Color(0xFFD3DED6),
                width: active ? 2.5 : 1),
          ),
          child: gross == null
              ? null
              : Text('$gross',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800)),
        ),
        if (p.dots.isNotEmpty)
          Positioned(
            top: 0, right: 0,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final d in p.dots)
                Container(
                  width: kStrokeDot, height: kStrokeDot,
                  margin: const EdgeInsets.only(left: 2),
                  decoration: BoxDecoration(
                    color: d == null
                        ? const Color(0xFF5C6B62)
                        : tripleNassauColour(_seatOf(card, d)),
                    shape: BoxShape.circle,
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// The dark tray: three matches, then what each golfer is up or down.
///
/// **It IS the bottom bar while it is up**, like every other tray: the
/// screen's pager hides underneath, so these arrows are the only ones.
class TripleNassauHoleTray extends StatelessWidget {
  final TripleNassauHoleCard card;
  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// Call a manual press in that match, starting next hole. Null when the
  /// screen is not offering one.
  final void Function(TripleNassauCardMatch match)? onPress;
  final bool gettingResult;
  final bool picking;
  final bool pressing;

  const TripleNassauHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.onPress,
    this.gettingResult = false,
    this.picking = false,
    this.pressing = false,
  });

  @override
  Widget build(BuildContext context) {
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
          if (!gettingResult)
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    TrayLabel(card.roundOver
                        ? 'Round over'
                        : 'Hole ${card.hole} · ${card.title}'),
                    const SizedBox(height: 6),
                    for (final m in card.matches)
                      _MatchBlock(card: card, match: m,
                          onPress: onPress, pressing: pressing),
                    if (card.money.isNotEmpty) ...[
                      const SizedBox(height: 4),
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

class _MatchBlock extends StatelessWidget {
  final TripleNassauHoleCard card;
  final TripleNassauCardMatch match;
  final void Function(TripleNassauCardMatch match)? onPress;
  final bool pressing;
  const _MatchBlock({required this.card, required this.match,
                     this.onPress, required this.pressing});

  @override
  Widget build(BuildContext context) {
    final s1 = _seatOf(card, match.playerIds[0]);
    final s2 = _seatOf(card, match.playerIds[1]);
    final w = match.winnerId == null
        ? null
        : (match.winnerId == match.playerIds[0] ? 1 : 2);
    final showPress = onPress != null && match.pressStart != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // The hole line, as in Fourball: names, why, the result.
        TrayResultRow(
          name1: match.names[0],
          name2: match.names[1],
          colour1: tripleNassauOnDark(s1),
          colour2: tripleNassauOnDark(s2),
          decided: match.decided,
          winner: w,
          reasonLabel: 'net',
          figure1: match.nets.isNotEmpty ? match.nets[0] : null,
          figure2: match.nets.length > 1 ? match.nets[1] : null,
        ),
        const SizedBox(height: 7),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Wrap(spacing: 5, runSpacing: 5, children: [
              for (final c in match.chips) _Chip(card: card, chip: c),
            ]),
          ),
          if (showPress) ...[
            const SizedBox(width: 6),
            SizedBox(
              height: 30,
              child: FilledButton(
                onPressed: pressing ? null : () => onPress!(match),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Halved.deepPine,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(60, 30),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999)),
                ),
                child: const Text('Press',
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}

/// `Front 2 UP`, `P1 starts 4` (dashed — a promise, not a bet), `3&2`.
/// The margin is in the LEADER's own colour; level reads `AS`.
class _Chip extends StatelessWidget {
  final TripleNassauHoleCard card;
  final TripleNassauChip chip;
  const _Chip({required this.card, required this.chip});

  @override
  Widget build(BuildContext context) {
    final pending = chip.state == 'pending';
    final fin = chip.state == 'final';
    final lead = chip.leaderId == null
        ? Colors.white
        : tripleNassauOnDark(_seatOf(card, chip.leaderId));
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fin ? Colors.white.withValues(alpha: 0.10) : null,
        borderRadius: BorderRadius.circular(999),
        border: fin
            ? null
            : Border.all(
                color: Colors.white.withValues(alpha: pending ? 0.22 : 0.30)),
      ),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
              text: '${chip.label} ',
              style: TextStyle(
                  color: pending ? _secondary : Colors.white.withValues(alpha: 0.78))),
          TextSpan(
              text: chip.value,
              style: TextStyle(color: pending ? _secondary : lead)),
        ]),
        style: TextStyle(
            fontSize: 11.5,
            fontStyle: pending ? FontStyle.italic : FontStyle.normal,
            fontWeight: FontWeight.w700),
      ),
    );
    return pending ? Opacity(opacity: 0.85, child: box) : box;
  }
}

class _Money extends StatelessWidget {
  final TripleNassauHoleCard card;
  const _Money({required this.card});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(13, 3, 13, 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 26,
            child: Row(children: [
              Expanded(
                child: Text(card.roundOver ? 'FINAL, EACH' : 'EACH · NOW',
                    style: const TextStyle(
                        color: _secondary, fontSize: 10.5,
                        letterSpacing: 0.4, fontWeight: FontWeight.w700)),
              ),
              Text('thru ${card.thru}',
                  style: const TextStyle(
                      color: _secondary, fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
          for (final m in card.money) _row(m),
          if (card.pays.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in card.pays)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(l,
                            style: const TextStyle(
                                color: _secondary, fontSize: 13)),
                      ),
                  ]),
            ),
        ]),
      );

  Widget _row(TripleNassauMoney m) {
    final colour = tripleNassauOnDark(_seatOf(card, m.playerId));
    final v = m.amount;
    final text = v == 0 ? '\$0' : '${v > 0 ? '+' : '−'}\$${_amt(v.abs())}';
    return Container(
      height: 34,
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x14FFFFFF)))),
      child: Row(children: [
        Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: colour, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 8),
        Expanded(
          child: Text(m.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        if (v > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
                color: Halved.brightMint,
                borderRadius: BorderRadius.circular(6)),
            child: Text(text,
                style: const TextStyle(
                    color: Halved.deepPine, fontSize: 13,
                    fontWeight: FontWeight.w700)),
          )
        else
          Text(text,
              style: TextStyle(
                  color: v == 0 ? _secondary : Colors.white,
                  fontSize: 13, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _Buttons extends StatelessWidget {
  final TripleNassauHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Buttons({required this.card, this.onPrev, this.onNext});

  @override
  Widget build(BuildContext context) {
    // **The last hole's forward button is the way out** — this tray takes
    // the pager away while it is up.
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
