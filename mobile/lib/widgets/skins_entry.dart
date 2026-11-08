import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';

// Skins score entry — `~/Downloads/handoff-skins-score-entry`.
//
// **Nothing here is a rule.** Who took the hole, what rode on it, whether a
// gross birdie stole it, what the skins are worth and what everybody is owed
// all arrive decided on `SkinsHoleCard`: the engine already accounts for the
// validation rules, junk, a mid-round withdrawal's segmented pool, pool mode
// and the loss cap, none of which the handoff's `stake × (golfers × won −
// total)` can see.
//
// A golfer's colour is his place in the ROSTER, which is what the board uses
// — he must not change colour the moment he wins a skin.

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

/// `2 skins · $30` with `1 carried from 6` under it — what this hole is
/// worth, in the slot the other games use for a side header.
///
/// Under a POOL it shows skins only: one pot is divided among however many
/// skins get won, so a per-skin figure would stop being true the moment the
/// next one is.
class SkinsHoleWorth extends StatelessWidget {
  final SkinsHoleCard card;
  const SkinsHoleWorth({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final s = card.riding == 1 ? 'skin' : 'skins';
    final worth = card.isPool || card.holeValue <= 0
        ? '${card.riding} $s'
        : '${card.riding} $s · \$${_amt(card.holeValue)}';
    final sub = card.carriedIn == 0
        ? 'none carried'
        : '${card.carriedIn} carried from ${card.carriedFrom ?? '?'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Halved.pine,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(worth,
              style: const TextStyle(
                  color: Colors.white, fontSize: 12.5,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(sub,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Halved.muted, fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// The dark tray: the nets that decided the hole, what happened to the skin,
/// and where everybody stands.
///
/// **It IS the bottom bar while it is up**, like every other tray: the
/// screen's pager hides underneath, so the arrows here are the only ones on
/// screen and the last hole's forward button is Complete Round.
class SkinsHoleTray extends StatelessWidget {
  final SkinsHoleCard card;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  final bool gettingResult;
  final bool notSynced;
  final bool picking;

  const SkinsHoleTray({
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
          if (!hold)
            ConstrainedBox(
              // **Bounded, and scrollable inside.** The cap leaves the
              // header above and the buttons below on screen — those
              // buttons are the ONLY pager while this tray is up — and
              // gives the content everything else. Two four-row blocks
              // plus a result line runs past a short phone whatever the
              // number is, so the tail scrolls.
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    TrayLabel(
                      card.roundOver
                          ? 'Round over'
                          : 'Hole ${card.hole} · Skins',
                      trailing: _riding(),
                    ),
                    const SizedBox(height: 6),
                    _Nets(card: card),
                    if (card.line.isNotEmpty) _Result(card: card),
                    const SizedBox(height: 10),
                    _Ledger(card: card),
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

  String _title() {
    final n = card.players.length;
    if (card.scored < n) return '${card.scored} of $n scored';
    return n == 2 ? 'Both scores in' : 'All $n scores in';
  }

  String _riding() {
    final s = card.riding == 1 ? 'skin' : 'skins';
    // **`a skin` is always singular**: the stake is the price of ONE,
    // however many are riding on this hole.
    if (!card.staked) return '${card.riding} $s riding';
    if (card.isPool) {
      return '${card.riding} riding · \$${_amt(card.stake)} ante';
    }
    return '${card.riding} riding · \$${_amt(card.stake)} a skin';
  }
}

/// One row a golfer, nets low to high, the winner's row lightly filled.
class _Nets extends StatelessWidget {
  final SkinsHoleCard card;
  const _Nets({required this.card});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
            children: [for (final p in card.players) _row(p)]),
      );

  Widget _row(SkinsHolePlayer p) {
    final colour = Halved.onDarkFor(p.rosterIndex ?? 0);
    final won = card.winnerId != null && p.playerId == card.winnerId;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: won
          ? BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
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
              Text(p.first,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14,
                      fontWeight: FontWeight.w700)),
              Text(
                  p.gross == null
                      ? 'no score'
                      : 'gross ${p.gross}${p.birdie ? ' · birdie' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _secondary, fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (won) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
                '${card.riding} ${card.riding == 1 ? 'skin' : 'skins'}',
                style: const TextStyle(
                    color: Halved.deepPine, fontSize: 11.5,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
        ],
        Text(p.net?.toString() ?? '–',
            style: TextStyle(
                color: p.net == null ? _trayMuted : colour,
                fontSize: 22, height: 1.0, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// What happened to the skin, and where it went if nowhere.
class _Result extends StatelessWidget {
  final SkinsHoleCard card;
  const _Result({required this.card});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.only(top: 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
        ),
        child: Row(children: [
          Expanded(
            child: Text(card.line,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
          if (card.ridesTo.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text(card.ridesTo,
                style: const TextStyle(
                    color: Halved.onDark2, fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ],
        ]),
      );
}

/// `EACH · NOW` — skins as ticks, then the money.
class _Ledger extends StatelessWidget {
  final SkinsHoleCard card;
  const _Ledger({required this.card});

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
            const Text('SKINS',
                style: TextStyle(
                    color: _secondary, fontSize: 10.5,
                    letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            const SizedBox(width: 12),
            // The money column's heading yields before the two above it:
            // `EACH · NOW` and `SKINS` name the columns, and this one is a
            // price the tray has already stated.
            Flexible(
              child: Text(card.staked && !card.isPool
                      ? '\$${_amt(card.stake)} A SKIN'
                      : 'MONEY',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        for (final e in card.ledger) _row(e),
        const SizedBox(height: 6),
        Text(_footer(),
            maxLines: 2,
            style: const TextStyle(color: _secondary, fontSize: 11,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }

  /// `Won 5 of 7 · 3 ride to 8` and `11 holes left`.
  String _footer() {
    final bits = <String>['Won ${card.skinsWon} of ${card.holesPlayed}'];
    if (card.ridesTo.isNotEmpty && card.ridesTo != 'no skin') {
      bits.add(card.ridesTo);
    }
    bits.add(card.roundOver
        ? 'round over'
        : '${card.holesLeft} ${card.holesLeft == 1 ? 'hole' : 'holes'} left');
    return bits.join(' · ');
  }

  Widget _row(SkinsLedgerRow e) {
    final colour = Halved.onDarkFor(e.rosterIndex ?? 0);
    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
              color: colour, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(e.first,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        Flexible(child: _Ticks(row: e, colour: colour)),
        const SizedBox(width: 10),
        _money(e.money),
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

/// One tick a skin, the ones won on THIS hole outlined rather than filled.
///
/// **Junk ticks are outlined too, and in the board's own way** — junk is a
/// share of the same pot, so the count beside the money has to include it or
/// the two stop reconciling.
class _Ticks extends StatelessWidget {
  final SkinsLedgerRow row;
  final Color colour;
  const _Ticks({required this.row, required this.colour});

  @override
  Widget build(BuildContext context) {
    if (row.totalSkins == 0) {
      return const Text('–',
          style: TextStyle(color: _trayMuted, fontSize: 13,
              fontWeight: FontWeight.w700));
    }
    final fresh = row.thisHole.clamp(0, row.skinsWon);
    final older = row.skinsWon - fresh;
    return Wrap(
      spacing: 3, runSpacing: 3,
      children: [
        for (var i = 0; i < older; i++) _tick(filled: true),
        for (var i = 0; i < fresh; i++) _tick(filled: false, fresh: true),
        for (var i = 0; i < row.junkSkins; i++) _tick(filled: false),
      ],
    );
  }

  Widget _tick({required bool filled, bool fresh = false}) => Container(
        width: 9, height: 9,
        decoration: BoxDecoration(
          color: filled ? colour : null,
          borderRadius: BorderRadius.circular(2),
          border: filled
              ? null
              : Border.all(
                  color: fresh ? Halved.brightMint : colour, width: 1.5),
        ),
      );
}

class _Buttons extends StatelessWidget {
  final SkinsHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Buttons({required this.card, required this.onPrev,
                  required this.onNext});

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
            child: Text(
                last ? 'Complete Round ›' : 'Hole ${card.nextHole} ›',
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
