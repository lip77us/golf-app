import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'tray_edit_header.dart';

// Wolf score entry — `~/Downloads/handoff-wolf-score-entry`.
//
// Two pieces: the call chips that sit above the scores, and the dark tray
// that rises once all four scores are in.
//
// **The call is not a gate.** The keypad is up from the moment the hole
// opens and the scorer can set the call on the tee, after the drives, or not
// at all — if the hole fills up without one, the tray asks for it before it
// settles. That is the whole change from the old flow, where a modal sheet
// had to be answered before a single score could be entered.
//
// **Neither widget computes anything.** Who won, what the call paid and
// where the round stands all arrive decided on `WolfHoleCard`: the
// `wolf_loses_ties` option hands a tied hole to the field and
// `non_wolf_bonus` doubles the field's clean win, and neither is visible in
// the nets these widgets also draw.

/// The Wolf's side is pine, the field is clay — on the light cards.
const Color kWolfSide = Halved.pine;
const Color kFieldSide = Halved.teamClay;

/// …and on the dark tray, where pine and clay are both too dark to read.
/// These are the same two [Halved.onDark] colours every other tray uses.
const Color kWolfOnDark = Halved.onDark1;
const Color kFieldOnDark = Halved.onDark2;

/// The Lone / Blind chip's outline — a lighter clay than the fill it takes
/// when selected, so an unselected chip is legible against white.
const Color _clayLine = Color(0xFFD9A27A);

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

Color sideColour(String? side, {bool onDark = false}) {
  if (side == 'wolf') return onDark ? kWolfOnDark : kWolfSide;
  if (side == 'field') return onDark ? kFieldOnDark : kFieldSide;
  return onDark ? _trayMuted : Halved.muted;
}

/// `Sam's call` — the three other golfers, then Lone and Blind.
///
/// Tapping the selected chip clears the call, which is why [onCall] carries
/// `'pending'`: the server's own word for no call, so nothing has to be
/// translated on the way.
class WolfCallCard extends StatelessWidget {
  final WolfHoleCard card;

  /// `'partner'` (with [partnerId]), `'lone'`, `'blind'` or `'pending'`.
  final void Function(String decision, {int? partnerId}) onCall;

  /// A call is in flight — every chip goes inert rather than queueing taps.
  final bool busy;

  /// Opens the tee-order sheet. Null hides the link.
  final VoidCallback? onTeeOrder;

  const WolfCallCard({
    super.key,
    required this.card,
    required this.onCall,
    this.busy = false,
    this.onTeeOrder,
  });

  @override
  Widget build(BuildContext context) {
    final others = card.players.where((p) => !p.isWolf).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Halved.cardBorder, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            // **The name yields, not the prices.** `Flexible`, not
            // `Expanded`: the heading takes only what it needs and gives the
            // rest back, so a long first name ellipsises rather than pushing
            // `partner 1 · Lone 3 · Blind 6` off the card.
            Flexible(
              child: Text('${card.wolfFirst}’s call',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700,
                      color: Halved.deepPine)),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'partner ${card.teamValue} · Lone ${card.loneValue}'
                ' · Blind ${card.blindValue}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: Halved.muted),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            // A 3-player game has no partner to take, and the
            // `require_lone_or_blind` rule takes it away on the Wolf's last
            // turn — in both cases the chips are simply not offered, rather
            // than drawn and refused by the server.
            if (card.canPartner)
              for (final p in others)
                _Chip(
                  label: p.first,
                  selected: card.decision == 'partner' &&
                      card.partnerId == p.playerId,
                  onTap: busy
                      ? null
                      : () => _tap('partner', partnerId: p.playerId),
                ),
            if (card.canPartner)
              Container(width: 1.5, height: 26,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  color: Halved.cardBorder),
            _Chip(
              label: 'Lone',
              solo: true,
              selected: card.decision == 'lone',
              onTap: busy ? null : () => _tap('lone'),
            ),
            _Chip(
              label: 'Blind',
              solo: true,
              selected: card.decision == 'blind',
              onTap: busy ? null : () => _tap('blind'),
            ),
          ]),
          if (card.partnerLocked) ...[
            const SizedBox(height: 6),
            Text(
              '${card.wolfFirst}’s last turn — Lone or Blind only.',
              style: const TextStyle(fontSize: 11.5, color: Halved.clayInk,
                  fontWeight: FontWeight.w600),
            ),
          ],
          if (onTeeOrder != null) ...[
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onTeeOrder,
                style: TextButton.styleFrom(
                    minimumSize: const Size(44, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: Halved.muted,
                    textStyle: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                child: const Text('Tee order'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Tapping the chip that is already on clears the call.
  void _tap(String kind, {int? partnerId}) {
    final already = kind == 'partner'
        ? card.decision == 'partner' && card.partnerId == partnerId
        : card.decision == kind;
    if (already) {
      onCall('pending');
    } else {
      onCall(kind, partnerId: partnerId);
    }
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;

  /// Lone and Blind, which wear clay rather than pine — they are a different
  /// kind of call, not a different golfer.
  final bool solo;
  final VoidCallback? onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.solo = false,
  });

  @override
  Widget build(BuildContext context) {
    final line = solo ? _clayLine : Halved.cardBorder;
    final fill = selected
        ? (solo ? Halved.teamClay : Halved.deepPine)
        : Colors.white;
    final text = selected
        ? Colors.white
        : (solo ? Halved.clayInk : Halved.deepPine);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          height: 34,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(999),
            border: selected ? null : Border.all(color: line, width: 1.5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              widthFactor: 1,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600,
                      color: onTap == null ? text.withValues(alpha: 0.4) : text)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dark tray: it asks for the call when the hole has none, and settles
/// the hole when it has one.
///
/// **It IS the bottom bar while it is up**, like Points', Sixes' and
/// Rabbit's: the screen's pager hides underneath, so the arrows here are the
/// only ones on screen. That is what lets the forward button say
/// `Finish round ›` on the last hole instead of leaving the group at a dead
/// end, and `Hole 8 · Lee is Wolf ›` on every other one — which a generic
/// pager could not say.
class WolfHoleTray extends StatelessWidget {
  final WolfHoleCard card;

  final VoidCallback onEdit;
  final void Function(String decision, {int? partnerId}) onCall;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// The result is on its way — what we hold predates the score just
  /// entered, so it is not drawn. Annandale's tray learnt this: a stale
  /// result after an edit is worse than none.
  final bool gettingResult;

  /// Saved on the phone, not yet at the server.
  final bool notSynced;

  /// `Edit scores` is open and waiting for a row to be tapped.
  final bool picking;

  /// A call is in flight.
  final bool busy;

  const WolfHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    required this.onCall,
    this.onPrev,
    this.onNext,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final over = card.roundOver && !card.needsCall;
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
            // **Not `Round over` here.** The sides label directly below says
            // exactly that, 20pt away, and one fact stated twice in one
            // corner is how the two come to disagree (Survivor's tray, which
            // said its phase three times).
            title: gettingResult ? 'Getting result…' : 'All 4 scores in',
            onEdit: onEdit,
            picking: picking,
          ),
          // **A hole saved on the phone but not yet at the server shows no
          // figures.** What we hold predates the score just entered, so the
          // sides and the standing would be last hole's.
          if (!hold) ...[
            const SizedBox(height: 10),
            if (card.needsCall)
              _CallPrompt(card: card, onCall: onCall, busy: busy)
            else ...[
              _Sides(card: card, over: over),
              const SizedBox(height: 10),
              if (over && card.winner != null) ...[
                _Winner(winner: card.winner!),
                const SizedBox(height: 10),
              ],
              _Standing(card: card, over: over),
            ],
          ],
          const SizedBox(height: 12),
          _Buttons(card: card, onPrev: onPrev, onNext: onNext, over: over),
        ],
      ),
    );
  }
}

/// `HOLE 7 · SAM'S CALL` — the scores are in and nothing can settle until
/// somebody says what the Wolf did.
class _CallPrompt extends StatelessWidget {
  final WolfHoleCard card;
  final void Function(String decision, {int? partnerId}) onCall;
  final bool busy;
  const _CallPrompt({required this.card, required this.onCall,
                     required this.busy});

  @override
  Widget build(BuildContext context) {
    final others = card.players.where((p) => !p.isWolf).toList();
    final buttons = <Widget>[
      if (card.canPartner)
        for (final p in others)
          _DarkButton(
            label: p.first,
            note: 'partner · ${_pts(card.teamValue)} '
                '${card.teamValue == 1 ? 'pt' : 'pts'}',
            onTap: busy
                ? null
                : () => onCall('partner', partnerId: p.playerId),
          ),
      _DarkButton(
        label: 'Lone',
        note: '${_pts(card.loneValue)} pts',
        onTap: busy ? null : () => onCall('lone'),
      ),
      _DarkButton(
        label: 'Blind',
        note: '${_pts(card.blindValue)} pts',
        onTap: busy ? null : () => onCall('blind'),
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _TrayLabel('Hole ${card.hole} · ${card.wolfFirst}’s call',
          trailing: 'who did ${card.wolfFirst} take?'),
      const SizedBox(height: 6),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 2.0,
        children: buttons,
      ),
      const SizedBox(height: 6),
      const Text('Scores are in. The hole settles once the call is set.',
          style: TextStyle(color: _secondary, fontSize: 12,
              fontWeight: FontWeight.w600)),
    ]);
  }
}

class _DarkButton extends StatelessWidget {
  final String label;
  final String note;
  final VoidCallback? onTap;
  const _DarkButton({required this.label, required this.note,
                     required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16), width: 1.5),
            ),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14.5,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(note,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: _secondary, fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      );
}

/// The two sides, the Wolf's first: who was on it, its best net, and what it
/// did. All three are the server's.
class _Sides extends StatelessWidget {
  final WolfHoleCard card;
  final bool over;
  const _Sides({required this.card, required this.over});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _TrayLabel(
        over ? 'Round over' : 'Hole ${card.hole} · ${card.callLabel}',
        trailing: card.callValue,
      ),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [for (final s in card.sides) _row(s)],
        ),
      ),
    ]);
  }

  Widget _row(WolfHoleSide s) {
    final colour = sideColour(s.side, onDark: true);
    final won = s.result == 'won';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
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
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 8),
        if (s.best != null)
          Text.rich(TextSpan(children: [
            const TextSpan(text: 'best '),
            TextSpan(text: '${s.best}',
                style: const TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ]), style: const TextStyle(color: _secondary, fontSize: 12,
                  fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        SizedBox(
          width: 58,
          child: Text(s.result ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: won ? colour : _trayMuted,
                  fontSize: won ? 16 : 13,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// `EACH · NOW` / `FINAL, EACH` — this hole, the running total, the money.
class _Standing extends StatelessWidget {
  final WolfHoleCard card;
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
            const _Head('Money', 64),
          ]),
        ),
        for (final s in card.standing) _row(s),
      ]),
    );
  }

  Widget _row(WolfStandingRow s) {
    final colour = sideColour(s.side, onDark: true);
    final hole = s.holePoints;
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
        Flexible(
          child: Text(s.first,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        if (s.isWolf) ...[
          const SizedBox(width: 5),
          const Text('WOLF',
              style: TextStyle(color: _secondary, fontSize: 9.5,
                  letterSpacing: 0.4, fontWeight: FontWeight.w700)),
        ],
        const Spacer(),
        SizedBox(
          width: 44,
          child: Text(_signed(hole),
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: hole > 0
                      ? Halved.brightMint
                      : (hole < 0 ? kFieldOnDark : _trayMuted),
                  fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          width: 52,
          child: Text(_signed(s.points),
              textAlign: TextAlign.right,
              style: const TextStyle(color: _secondary, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          width: 64,
          child: Align(alignment: Alignment.centerRight,
              child: _money(s.money)),
        ),
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
    // A golfer who is up gets the highlight, which is what a reader looks for
    // first on a tray about money.
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

/// `Paul wins with +9 pts` — the round's own line, above the standing.
class _Winner extends StatelessWidget {
  final WolfRoundWinner winner;
  const _Winner({required this.winner});

  @override
  Widget build(BuildContext context) {
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
                // **Mint, not the side he happened to be on for the 18th.**
                // Sides are a property of ONE hole and change every hole, so
                // colouring a round winner by the last of them says nothing.
                // The reference's own markup does this; its prose says
                // otherwise, and its own screenshot follows the markup.
                color: Halved.brightMint,
                borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
                '${winner.first} wins with ${_signed(winner.points)} pts',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(m == 0 ? '\$0' : '${m > 0 ? '+' : '−'}\$${_amt(m.abs())}',
              style: const TextStyle(color: Halved.brightMint, fontSize: 22,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 3),
        Text(
          '${winner.stake <= 0 ? 'No stake' : '\$${_amt(winner.stake)} a point'}'
          ' · every hole sums to zero',
          style: const TextStyle(color: _secondary, fontSize: 12,
              fontWeight: FontWeight.w600),
        ),
      ]),
    );
  }
}

class _Buttons extends StatelessWidget {
  final WolfHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool over;
  const _Buttons({required this.card, required this.onPrev,
                  required this.onNext, required this.over});

  @override
  Widget build(BuildContext context) {
    final label = card.needsCall
        ? 'Pick ${card.wolfFirst}’s call'
        : (over || card.nextHole == null
            ? 'Finish round ›'
            : (card.nextWolfFirst.isEmpty
                ? 'Hole ${card.nextHole} ›'
                : 'Hole ${card.nextHole} · '
                    '${card.nextWolfFirst} is Wolf ›'));
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
            // **Nothing moves on until the call is set.** The hole cannot
            // settle without it, so advancing would leave a scored hole
            // behind that counts for nobody.
            onPressed: card.needsCall ? null : onNext,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Halved.deepPine,
              disabledBackgroundColor: Colors.white.withValues(alpha: 0.18),
              disabledForegroundColor: Colors.white.withValues(alpha: 0.55),
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

class _TrayLabel extends StatelessWidget {
  final String text;
  final String? trailing;
  const _TrayLabel(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) => Row(children: [
        // The LABEL yields, never the figure beside it.
        Flexible(
          child: Text(text.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: _secondary, fontSize: 10.5,
                  letterSpacing: 1.0, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        // **Uppercase, like the label beside it.** The design system puts
        // `text-transform: uppercase` on the whole row, so `25¢ A POINT` and
        // `1 PT EACH` are headings rather than values — and a row that was
        // half-capitalised read as two different kinds of thing.
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

/// Wolf points are halves at most — a 3-player Lone splits the pot in two —
/// so a whole number shows no decimal and 1.5 shows one.
String _pts(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
}

String _signed(num v) {
  final d = v.toDouble();
  if (d == 0) return '0';
  return '${d > 0 ? '+' : '−'}${_pts(d.abs())}';
}

String _amt(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}
