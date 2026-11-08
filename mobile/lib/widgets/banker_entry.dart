import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';

// Banker score entry — `~/Downloads/handoff-banker-score-entry`, which folds
// the betting into the score screen: the max and the bets on the tee, the
// doubles and the counter in the air, then the keypad and the tray.
//
// **Nothing here is a rule.** Which calls are open, what a bet reaches, who
// won each of the three one-on-ones, the chain under every line and who
// banks next all arrive decided on `BankerSummary` — `services/banker.py`
// owns the sequence precisely so it holds however the call arrives and not
// only when the UI behaves. This sends declarations and renders answers.
//
// Gold is the BANK, and only the bank. It is the one role colour in the
// game and it never means a result.

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

/// The ids tied for the bank, off the summary's untyped list.
///
/// `tie_candidates` is `[{player_id, short_name}]` and the Dart model keeps
/// it as raw maps, so this is the one place that reads a key out of it.
List<int> tieCandidateIds(BankerSummary s) => [
      for (final c in s.tieCandidates)
        if (c['player_id'] != null) (c['player_id'] as num).toInt(),
    ];

/// The max a banker can pick: the house rungs, clamped to the round's band.
///
/// **Not the exposure ladder**, which is the setup screen's argument about
/// what a round can cost. This is the three amounts the handoff draws, with
/// the round's own ceiling added when it is not one of them — so a group
/// playing to \$35 gets \$10, \$20, \$35 rather than a chip the server would
/// refuse.
List<double> maxChipsFor(BankerSummary s) {
  final out = <double>[
    for (final v in const [10.0, 20.0, 50.0])
      if (v >= s.minBet && v <= s.maxBet) v,
  ];
  if (!out.contains(s.maxBet) && s.maxBet >= s.minBet) out.add(s.maxBet);
  out.sort();
  return out;
}

/// Gold — the bank's colour, on a light card and on the dark tray.
const Color kBankGold     = Color(0xFFB7791F);
const Color kBankGoldInk  = Color(0xFF8A5A12);
const Color kBankGoldDark = Color(0xFFF2C14E);
const Color kBankCream    = Color(0xFFFDF8EC);

/// The money on the hole, above the golfers: the max and three bets before
/// the lock, the doubles and the counter after it.
///
/// **It closes itself.** Every control reads the server's own state —
/// `locked`, `countered`, each line's multiplier — and the first score shuts
/// the calls, which is the engine's rule and not this widget's.
class BankerBetsCard extends StatelessWidget {
  final BankerSummary summary;

  /// The golfers in card order, the banker included.
  final List<({int id, String first})> roster;

  /// True once anybody has a gross on this hole: the calls are closed.
  final bool scoreIn;

  final void Function(double max) onMax;
  final void Function(int playerId, double amount) onBet;
  final VoidCallback onLock;
  final void Function(int playerId, bool on) onDouble;
  final void Function(bool on) onCounter;
  final bool busy;

  const BankerBetsCard({
    super.key,
    required this.summary,
    required this.roster,
    required this.scoreIn,
    required this.onMax,
    required this.onBet,
    required this.onLock,
    required this.onDouble,
    required this.onCounter,
    this.busy = false,
  });

  BankerHoleState? get _hole => summary.current;

  String _firstOf(int id) =>
      roster.firstWhere((r) => r.id == id,
          orElse: () => (id: id, first: '')).first;

  @override
  Widget build(BuildContext context) {
    final h = _hole;
    if (h == null || h.bankerId == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: h.locked ? _locked(context, h) : _open(context, h),
    );
  }

  // ── On the tee ───────────────────────────────────────────────────────
  Widget _open(BuildContext context, BankerHoleState h) {
    final opponents = roster.where((r) => r.id != h.bankerId).toList();
    final max = h.maxBet ?? summary.maxBet;
    final placed = {for (final l in h.lines) l.playerId: l.bet};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Head(
        title: '${_firstOf(h.bankerId!)} banks',
        sub: 'sets the max, then the three bet',
      ),
      const SizedBox(height: 10),
      Row(children: [
        const SizedBox(
          width: 38,
          child: Text('Max',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                  color: Halved.muted)),
        ),
        for (final v in maxChipsFor(summary)) ...[
          _MaxChip(
            amount: v,
            on: max == v,
            onTap: busy ? null : () => onMax(v),
          ),
          const SizedBox(width: 6),
        ],
      ]),
      const SizedBox(height: 4),
      for (final o in opponents)
        _BetRow(
          first: o.first,
          amount: placed[o.id] ?? summary.minBet,
          min: summary.minBet,
          max: max,
          onChange: busy ? null : (v) => onBet(o.id, v),
        ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity, height: 44,
        child: FilledButton(
          onPressed: busy || h.lines.length < opponents.length ? null : onLock,
          style: FilledButton.styleFrom(
            backgroundColor: Halved.deepPine,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          // **Not "Paul tees off".** The app cannot know when anybody
          // swings, and naming one golfer asserts an order the format does
          // not have — the existing board's own note. The button names what
          // the lock DOES: nothing can come down again, only up.
          child: Text(
              h.lines.length < opponents.length
                  ? '${opponents.length - h.lines.length} '
                      '${opponents.length - h.lines.length == 1
                          ? 'bet' : 'bets'} to go'
                  : 'Lock the bets — increases only from here',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14.5, fontWeight: FontWeight.w700)),
        ),
      ),
    ]);
  }

  // ── In the air ───────────────────────────────────────────────────────
  Widget _locked(BuildContext context, BankerHoleState h) {
    final triples = h.isPar3 && summary.rules.par3Triples;
    final word    = triples ? 'Triple ×3' : 'Double ×2';
    final canCall = !scoreIn && !h.resolved;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: _Head(
            title: '${_firstOf(h.bankerId!)} banks'
                '${h.maxBet == null ? '' : ' · max \$${_amt(h.maxBet!)}'}',
          ),
        ),
        Text('at stake \$${_amt(h.exposure)}',
            style: const TextStyle(
                color: kBankGoldInk, fontSize: 12.5,
                fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 8),
      for (final l in h.lines)
        Opacity(
          opacity: canCall ? 1 : 0.55,
          child: _CallRow(
            first: _firstOf(l.playerId),
            bet: l.bet,
            on: l.ownMultiplier > 1,
            word: word,
            capped: h.cutOff.contains(l.playerId),
            onTap: canCall && summary.rules.playerDouble && !busy
                ? () => onDouble(l.playerId, l.ownMultiplier == 1)
                : null,
          ),
        ),
      if (summary.rules.counter) ...[
        const SizedBox(height: 4),
        Opacity(
          opacity: canCall ? 1 : 0.55,
          child: _CounterToggle(
            first: _firstOf(h.bankerId!),
            on: h.countered,
            onTap: canCall && !busy ? () => onCounter(!h.countered) : null,
          ),
        ),
      ],
      const SizedBox(height: 8),
      Text(
          canCall
              ? 'Calls stay open until the first score goes in.'
              : 'Calls are closed — the first score is in.',
          style: const TextStyle(
              color: Halved.muted, fontSize: 11.5,
              fontWeight: FontWeight.w600)),
    ]);
  }
}

class _Head extends StatelessWidget {
  final String title;
  final String? sub;
  const _Head({required this.title, this.sub});

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
              color: kBankGold, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(title,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w800,
                  color: Halved.deepPine)),
        ),
        if (sub != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(sub!,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Halved.muted, fontSize: 11.5,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ]);
}

class _MaxChip extends StatelessWidget {
  final double amount;
  final bool on;
  final VoidCallback? onTap;
  const _MaxChip({required this.amount, required this.on, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            decoration: BoxDecoration(
              color: on ? kBankGold : null,
              border: Border.all(color: on ? kBankGold : Halved.cardBorder),
              borderRadius: BorderRadius.circular(999),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text('\$${_amt(amount)}',
                style: TextStyle(
                    color: on ? Colors.white : Halved.deepPine,
                    fontSize: 13, fontWeight: FontWeight.w800)),
          ),
        ),
      );
}

/// `Dave  − $10 +` — his own bet, in $5 steps between the floor and the max.
class _BetRow extends StatelessWidget {
  final String first;
  final double amount;
  final double min;
  final double max;
  final void Function(double)? onChange;
  const _BetRow({required this.first, required this.amount, required this.min,
                 required this.max, this.onChange});

  static const double step = 5;

  @override
  Widget build(BuildContext context) {
    final down = amount - step >= min ? amount - step : null;
    final up   = amount + step <= max ? amount + step : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
          child: Text(first,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        _Step(icon: Icons.remove,
              onTap: onChange == null || down == null
                  ? null : () => onChange!(down)),
        SizedBox(
          width: 56,
          child: Text('\$${_amt(amount)}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ),
        _Step(icon: Icons.add,
              onTap: onChange == null || up == null
                  ? null : () => onChange!(up)),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _Step({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 44, height: 44,
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          style: IconButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                  color: onTap == null
                      ? Halved.cardBorder.withValues(alpha: 0.5)
                      : Halved.cardBorder),
            ),
          ),
        ),
      );
}

/// `Dave  $10  [Double ×2]` — clay, because a double is a CALL and not a
/// result; gold is the bank's and green and red are win and loss.
class _CallRow extends StatelessWidget {
  final String first;
  final double bet;
  final bool on;
  final String word;
  final bool capped;
  final VoidCallback? onTap;
  const _CallRow({required this.first, required this.bet, required this.on,
                  required this.word, required this.capped, this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
            child: Text(first,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          Text('\$${_amt(bet)}',
              style: const TextStyle(fontSize: 14.5,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          if (capped)
            const Text('capped',
                style: TextStyle(color: Halved.muted, fontSize: 12,
                    fontWeight: FontWeight.w700))
          else
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(999),
                child: Ink(
                  decoration: BoxDecoration(
                    color: on ? Halved.teamClay : null,
                    border: Border.all(color: Halved.teamClay),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  child: Text(word,
                      style: TextStyle(
                          color: on ? Colors.white : Halved.clayInk,
                          fontSize: 12.5, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
        ]),
      );
}

class _CounterToggle extends StatelessWidget {
  final String first;
  final bool on;
  final VoidCallback? onTap;
  const _CounterToggle({required this.first, required this.on, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            width: double.infinity,
            decoration: BoxDecoration(
              color: on ? kBankGold : null,
              border: Border.all(color: kBankGold),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
                on
                    ? '$first countered · every bet ×2'
                    : '$first counter-doubles · every bet ×2',
                textAlign: TextAlign.center,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: on ? Colors.white : kBankGoldInk,
                    fontSize: 13, fontWeight: FontWeight.w800)),
          ),
        ),
      );
}

/// The dark tray: the three one-on-ones, who banks next, and the standing.
class BankerHoleTray extends StatelessWidget {
  final BankerSummary summary;
  final List<({int id, String first})> roster;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;

  /// Open the next hole. Null while a tie is unanswered and nobody is
  /// picked — the engine refuses it, so the button must not offer it.
  final VoidCallback? onNext;

  /// Who the group picked on a tie, and why.
  final int? tiePick;
  final void Function(int playerId, String reason) onPickTie;

  final bool gettingResult;
  final bool notSynced;
  final bool picking;
  final bool roundOver;
  final int? nextHole;

  const BankerHoleTray({
    super.key,
    required this.summary,
    required this.roster,
    required this.onEdit,
    required this.onPickTie,
    this.onPrev,
    this.onNext,
    this.tiePick,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
    this.roundOver = false,
    this.nextHole,
  });

  String _firstOf(int id) =>
      roster.firstWhere((r) => r.id == id,
          orElse: () => (id: id, first: '')).first;

  @override
  Widget build(BuildContext context) {
    final h = summary.current;
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
                : 'All ${roster.length} scores in',
            onEdit: onEdit,
            picking: picking,
          ),
          if (!hold && h != null)
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    TrayLabel(
                      roundOver
                          ? 'Round over'
                          : 'Hole ${h.hole} · '
                              '${_firstOf(h.bankerId ?? 0)} banks',
                      trailing: h.bankerGross == null
                          ? null : 'banker ${h.bankerGross}',
                    ),
                    const SizedBox(height: 6),
                    _Bets(hole: h, bankerFirst: _firstOf(h.bankerId ?? 0)),
                    const SizedBox(height: 10),
                    _NextBanker(
                      summary: summary,
                      roster: roster,
                      tiePick: tiePick,
                      onPick: onPickTie,
                      nextHole: nextHole,
                    ),
                    const SizedBox(height: 10),
                    _Standing(summary: summary, roster: roster,
                              roundOver: roundOver),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          _Buttons(
            label: roundOver
                ? 'Finish round ›'
                : (onNext == null && summary.awaitingTie != null
                    ? 'Confirm the banker'
                    : 'Hole ${nextHole ?? ''} · '
                        '${_nextName()} banks ›'),
            onPrev: onPrev,
            onNext: onNext,
          ),
        ],
      ),
    );
  }

  String _nextName() {
    if (tiePick != null) return _firstOf(tiePick!);
    final id = summary.nextBankerId;
    return id == null ? '' : _firstOf(id);
  }
}

/// One row a bet, with the chain the SERVER composed underneath it.
class _Bets extends StatelessWidget {
  final BankerHoleState hole;
  final String bankerFirst;
  const _Bets({required this.hole, required this.bankerFirst});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [
          for (final l in hole.lines) _row(l),
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(7, 7, 7, 2),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
            ),
            child: Row(children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                    color: kBankGoldDark,
                    borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$bankerFirst on the hole',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5,
                        fontWeight: FontWeight.w700)),
              ),
              Text('${hole.bankerGross ?? '–'}',
                  style: const TextStyle(
                      color: kBankGoldDark, fontSize: 18, height: 1.0,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
      );

  Widget _row(BankerBetLine l) {
    final won  = l.outcome == 'won';
    final lost = l.outcome == 'lost';
    final colour = won
        ? Halved.brightMint
        : (lost ? Halved.onDark2 : _trayMuted);
    final verdict = won
        ? 'beat the banker'
        : (lost ? 'lost' : 'tied, no action');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14,
                        fontWeight: FontWeight.w700)),
                Text('net ${l.net ?? '–'} v ${l.bankerNet ?? '–'} · $verdict',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: _secondary, fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
              l.outcome == 'tied'
                  ? '\$0'
                  : '${won ? '+' : '−'}\$${_amt(l.amount)}',
              style: TextStyle(color: colour, fontSize: 17, height: 1.0,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 2),
        // **The chain is the server's string.** It already carries the
        // double, the counter, the birdie bonus and `· void` on a tie —
        // re-composing it here would be a second opinion about arithmetic
        // somebody is going to be paid on.
        Text(l.chain,
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _trayMuted, fontSize: 11,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Who banks the next hole — stated when it is outright, asked when it is a
/// tie, because that is the one thing a phone cannot settle.
class _NextBanker extends StatelessWidget {
  final BankerSummary summary;
  final List<({int id, String first})> roster;
  final int? tiePick;
  final void Function(int playerId, String reason) onPick;
  final int? nextHole;
  const _NextBanker({required this.summary, required this.roster,
                     required this.tiePick, required this.onPick,
                     required this.nextHole});

  String _firstOf(int id) =>
      roster.firstWhere((r) => r.id == id,
          orElse: () => (id: id, first: '')).first;

  @override
  Widget build(BuildContext context) {
    final h = summary.current;
    if (h == null || !h.resolved) return const SizedBox.shrink();

    if (summary.awaitingTie == null) {
      final id = summary.nextBankerId;
      if (id == null) return const SizedBox.shrink();
      final again = id == h.bankerId;
      return _box(Row(children: [
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: 'Low net ${h.lowNet ?? '–'}: '),
              TextSpan(text: _firstOf(id),
                  style: const TextStyle(
                      color: kBankGoldDark, fontWeight: FontWeight.w800)),
            ]),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13.5,
                fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
        Text(again ? 'banks again' : 'banks ${nextHole ?? ''}',
            style: const TextStyle(color: _secondary, fontSize: 12,
                fontWeight: FontWeight.w700)),
      ]));
    }

    return _box(Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
      Text('Tied low on net ${h.lowNet ?? '–'} · who holed out first?',
          maxLines: 2,
          style: const TextStyle(color: Colors.white, fontSize: 13.5,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final id in tieCandidateIds(summary))
          _TiePill(
            label: _firstOf(id),
            on: tiePick == id,
            onTap: () => onPick(id, 'holed-out-first'),
          ),
        TextButton(
          onPressed: () {
            final ids = [...tieCandidateIds(summary)];
            if (ids.isEmpty) return;
            // **Random, and the reason travels.** `drawn` reaches the
            // receipt, so a hole settled by chance says so months later.
            ids.shuffle();
            onPick(ids.first, 'drawn');
          },
          style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(44, 40)),
          child: const Text('Draw',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline)),
        ),
      ]),
    ]));
  }

  Widget _box(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );
}

class _TiePill extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _TiePill({required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            decoration: BoxDecoration(
              color: on ? kBankGoldDark : null,
              border: Border.all(
                  color: on ? kBankGoldDark
                            : Colors.white.withValues(alpha: 0.35)),
              borderRadius: BorderRadius.circular(999),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(label,
                style: TextStyle(
                    color: on ? Halved.deepPine : Colors.white,
                    fontSize: 13, fontWeight: FontWeight.w800)),
          ),
        ),
      );
}

/// `EACH · NOW` — this hole, then the round, sorted by the round.
class _Standing extends StatelessWidget {
  final BankerSummary summary;
  final List<({int id, String first})> roster;
  final bool roundOver;
  const _Standing({required this.summary, required this.roster,
                   required this.roundOver});

  @override
  Widget build(BuildContext context) {
    final h = summary.current;
    final hole = h?.holeMoney ?? const <int, double>{};
    final rows = [...summary.players]
      ..sort((a, b) => b.total.compareTo(a.total));
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
              child: Text(roundOver ? 'FINAL, EACH' : 'EACH · NOW',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(
              width: 62,
              child: Text('HOLE', textAlign: TextAlign.right,
                  style: TextStyle(color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            const SizedBox(
              width: 68,
              child: Text('ROUND', textAlign: TextAlign.right,
                  style: TextStyle(color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        for (final p in rows)
          _row(p, hole[p.playerId] ?? 0, p.playerId == h?.bankerId),
      ]),
    );
  }

  Widget _row(BankerPlayerTotal p, double onHole, bool isBanker) => Container(
        height: 34,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
        ),
        child: Row(children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: isBanker ? kBankGoldDark : _trayMuted,
                borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(p.name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          SizedBox(
            width: 62,
            child: Text(_signed(onHole), textAlign: TextAlign.right,
                style: TextStyle(
                    color: onHole > 0
                        ? Halved.brightMint
                        : (onHole < 0 ? Halved.onDark2 : _secondary),
                    fontSize: 13, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 68, child: _round(p.total)),
        ]),
      );

  Widget _round(double v) {
    final text = _signed(v);
    if (v <= 0) {
      return Text(text, textAlign: TextAlign.right,
          style: TextStyle(
              color: v == 0 ? _secondary : Colors.white,
              fontSize: 13, fontWeight: FontWeight.w700));
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Halved.brightMint,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: const TextStyle(color: Halved.deepPine, fontSize: 13,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _Buttons extends StatelessWidget {
  final String label;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Buttons({required this.label, this.onPrev, this.onNext});

  @override
  Widget build(BuildContext context) => Row(children: [
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
                disabledBackgroundColor:
                    Colors.white.withValues(alpha: 0.35),
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

String _signed(double v) =>
    v == 0 ? '\$0' : '${v > 0 ? '+' : '−'}\$${_amt(v.abs())}';

String _amt(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}
