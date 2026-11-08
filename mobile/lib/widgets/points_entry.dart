import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'tray_edit_header.dart';

/// The Points 5-3-1 dark tray — `~/Downloads/handoff-points-score-entry`.
///
/// It rises once all three scores are in and reports two things: how the
/// hole's nine points split, and where that leaves the round.
///
/// **It renders and computes nothing.** The 5-3-1 split, the tie rule, the
/// target and the money all arrive decided on [PointsHoleCard] — the handoff
/// carries an `alloc()` for its own browser reference, and a second one here
/// would be a second opinion about points, which in this game is the money.
///
/// **It IS the bottom bar while it is up**, like Sixes' and Rabbit's: the
/// screen's pager hides underneath, so the arrows here are the only ones on
/// screen. That is what lets the forward button say `Finish round ›` on the
/// last hole instead of leaving the group at a dead end.
class PointsHoleTray extends StatelessWidget {
  final PointsHoleCard card;

  /// Roster order → colour, so a golfer is the same colour in the awards,
  /// the standing and the card above. Sorting either list must not move it.
  final Map<int, Color> colours;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final int? nextHole;

  /// The result is on its way — what we hold predates the score just
  /// entered, so it is not drawn. Annandale's tray learnt this: a stale
  /// result after an edit is worse than none.
  final bool gettingResult;

  /// Saved on the phone, not yet at the server.
  final bool notSynced;

  /// `Edit scores` is open and waiting for a row to be tapped.
  final bool picking;

  const PointsHoleTray({
    super.key,
    required this.card,
    required this.colours,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.nextHole,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
  });

  Color _colour(int playerId) => colours[playerId] ?? Colors.white70;

  @override
  Widget build(BuildContext context) {
    final over = card.roundOver;
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
                : (over ? 'Round over' : 'All 3 scores in'),
            onEdit: onEdit,
            picking: picking,
          ),
          // **A hole saved on the phone but not yet at the server shows no
          // figures.** What we hold predates the score just entered, so the
          // points and the standing would be last hole's — the same rule
          // Sixes' tray follows, which folds `notSynced` into the same gate.
          if (!gettingResult && !notSynced) ...[
            const SizedBox(height: 10),
            if (over && card.winner != null) _Winner(
              winner: card.winner!,
              colour: _winnerColour(),
            ),
            if (!over) _Awards(card: card, colour: _colour),
            const SizedBox(height: 12),
            _Standing(card: card, colour: _colour, over: over),
          ],
          const SizedBox(height: 12),
          _Buttons(
            onPrev: onPrev,
            onNext: onNext,
            nextHole: nextHole,
            roundOver: over,
          ),
        ],
      ),
    );
  }

  Color _winnerColour() {
    final top = card.standing.isEmpty ? null : card.standing.first;
    return top == null ? Halved.brightMint : _colour(top.playerId);
  }
}

/// `HOLE 7 · NET TO POINTS` — the hole's own split, low net first.
class _Awards extends StatelessWidget {
  final PointsHoleCard card;
  final Color Function(int) colour;
  const _Awards({required this.card, required this.colour});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TrayLabel('Hole ${card.hole} · net to points',
            trailing: _stake(card.stake)),
        const SizedBox(height: 6),
        for (final r in card.pointsRows)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              // A tied row is tinted, because its points are not 5, 3 or 1
              // and nothing else on the row explains why.
              color: r.tied ? Colors.white.withValues(alpha: 0.06) : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                    color: colour(r.playerId), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(r.short,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              Text('net ${r.net}',
                  style: const TextStyle(color: _secondary, fontSize: 12.5)),
              if (r.tied) ...[
                const SizedBox(width: 6),
                const Text('tied',
                    style: TextStyle(color: _secondary, fontSize: 11.5,
                        fontStyle: FontStyle.italic)),
              ],
              const Spacer(),
              const Text('→',
                  style: TextStyle(color: _secondary, fontSize: 13)),
              const SizedBox(width: 8),
              Text(_pts(r.points),
                  style: TextStyle(
                      color: colour(r.playerId), fontSize: 22,
                      height: 1.0, fontWeight: FontWeight.w700)),
            ]),
          ),
      ],
    );
  }
}

/// `EACH · NOW` / `FINAL, EACH` — points, against target, and money.
class _Standing extends StatelessWidget {
  final PointsHoleCard card;
  final Color Function(int) colour;
  final bool over;
  const _Standing({required this.card, required this.colour,
                   required this.over});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TrayLabel(over ? 'Final, each' : 'Each · now',
            trailing: 'target ${card.target}'),
        const SizedBox(height: 6),
        const Row(children: [
          Spacer(),
          SizedBox(width: 54, child: Text('Pts', textAlign: TextAlign.right,
              style: TextStyle(color: _secondary, fontSize: 11))),
          SizedBox(width: 62, child: Text('v. target',
              textAlign: TextAlign.right,
              style: TextStyle(color: _secondary, fontSize: 11))),
          SizedBox(width: 62, child: Text('Money', textAlign: TextAlign.right,
              style: TextStyle(color: _secondary, fontSize: 11))),
        ]),
        for (final s in card.standing) _row(s),
      ],
    );
  }

  Widget _row(PointsStandingRow s) {
    final up = s.vTarget > 0;
    // `E` when level — the app says E everywhere else and `+0` reads as a
    // gain that is not one.
    final v = s.vTarget == 0
        ? 'E'
        : '${s.vTarget > 0 ? '+' : '−'}${_pts(s.vTarget.abs())}';
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
              color: colour(s.playerId), shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(s.short,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        SizedBox(width: 54, child: Text(_pts(s.points),
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white, fontSize: 15,
                fontWeight: FontWeight.w600))),
        SizedBox(width: 62, child: Text(v,
            textAlign: TextAlign.right,
            style: TextStyle(
                color: s.vTarget == 0
                    ? _secondary
                    : (up ? Halved.onDark1 : Halved.onDark2),
                fontSize: 16, fontWeight: FontWeight.w700))),
        SizedBox(width: 62, child: Align(
          alignment: Alignment.centerRight,
          child: _money(s.money),
        )),
      ]),
    );
  }

  Widget _money(double m) {
    final text = m == 0 ? '\$0' : '${m > 0 ? '+' : '−'}\$${_amt(m.abs())}';
    if (m <= 0) {
      return Text(text,
          style: TextStyle(
              color: m == 0 ? _secondary : Halved.onDark2,
              fontSize: 14, fontWeight: FontWeight.w700));
    }
    // A golfer who is up gets the highlight, which is what a reader looks
    // for first on a tray about money.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Halved.brightMint,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(text,
          style: const TextStyle(color: Halved.deepPine, fontSize: 14,
              fontWeight: FontWeight.w700)),
    );
  }
}

class _Winner extends StatelessWidget {
  final PointsRoundWinner winner;
  final Color colour;
  const _Winner({required this.winner, required this.colour});

  @override
  Widget build(BuildContext context) {
    final m = winner.money;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Flexible(
            child: Text('${winner.short} wins with ${_pts(winner.points)} pts',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(m == 0 ? '\$0' : '${m > 0 ? '+' : '−'}\$${_amt(m.abs())}',
              style: TextStyle(color: colour, fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 2),
        Text(
          'Target ${winner.target}'
          '${winner.settles.isEmpty ? '' : ' · settled ${winner.settles}'}',
          style: const TextStyle(color: _secondary, fontSize: 12),
        ),
      ]),
    );
  }
}

class _Buttons extends StatelessWidget {
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final int? nextHole;
  final bool roundOver;
  const _Buttons({required this.onPrev, required this.onNext,
                  required this.nextHole, required this.roundOver});

  @override
  Widget build(BuildContext context) {
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
            // **The last hole finishes the round.** This tray covers the
            // screen's pager, so a forward button that only advanced left the
            // 18th with no way out — reported on Rabbit, whose tray has the
            // identical shape.
            child: Text(
              roundOver || nextHole == null
                  ? 'Finish round ›'
                  : 'Hole $nextHole ›',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// **Points keeps its own.** `widgets/tray_label.dart` is the shared one,
/// taken from the three identical copies Wolf, Las Vegas and Fourball grew;
/// this one is a different packet, already shipped, and its trailing text is
/// deliberately not uppercased.
class _TrayLabel extends StatelessWidget {
  final String text;
  final String? trailing;
  const _TrayLabel(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) => Row(children: [
        // The LABEL yields, never the figure beside it: `$1 a point` and
        // `target 21` are facts a reader needs, and the heading above them
        // is one they can infer from the rows.
        Flexible(
          child: Text(text.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: _secondary, fontSize: 10.5,
                  letterSpacing: 1.4, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 10),
        if (trailing != null)
          Text(trailing!,
              style: const TextStyle(color: _secondary, fontSize: 11.5)),
      ]);
}

const Color _secondary = Color(0xFFB9CCC3);

String _stake(double s) =>
    s <= 0 ? '' : '\$${_amt(s)} a point';

/// Points are halves at most — a tied hole splits 5 and 3 into 4 and 4 — so
/// a whole number shows none and `4.5` shows one.
String _pts(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
}

String _amt(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}
