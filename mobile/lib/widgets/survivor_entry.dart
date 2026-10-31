/// Survivor score entry — the hole header, the players card and the dark tray.
///
/// `~/Downloads/handoff-survivor-score-entry`. Built on the SAME keypad and
/// tray pieces as 40 Balls, Sixes and Rabbit (`FortyBallsKeypad`,
/// `TrayEditHeader`) rather than new ones, which is the packet's first
/// instruction and this repo's standing rule: one mark, one file.
///
/// Every sentence the tray says comes from the server, because every one of
/// them is a RULE — what a tie does, who pays whom, which Survivor takes
/// over. A client composing them would be a second copy of the engine's own
/// transitions, and the two would disagree the first time one was edited.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'forty_balls_keypad.dart';
import 'stroke_dots.dart';
import 'tray_edit_header.dart';

const Color _dim   = Color(0xB3FFFFFF);
const Color _panel = Color(0xFF14362B);

String _money(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// Hole, yards, stroke index — and what the hole is being played AS.
class SurvivorHoleHeader extends StatelessWidget {
  final SurvivorHoleCard card;

  const SurvivorHoleHeader({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
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
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFEDF1EE),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(card.phaseChip,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Halved.deepPine)),
          ),
          const SizedBox(height: 4),
          Text(card.phaseNote,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
      ]),
    );
  }
}

/// The three golfers, banded by who is still in and who is in Zombieville.
///
/// **Row order is the standing when the hole STARTS** and does not move when
/// somebody goes out or comes back on it — the tray says what happened, and
/// the rows reorder on the next hole, which is the one they describe. The
/// server sends them in that order; this draws them in it.
class SurvivorPlayersCard extends StatelessWidget {
  final SurvivorHoleCard card;
  final int? activePlayerId;
  final ValueChanged<int>? onTapPlayer;

  /// Net Style Entry — passed in rather than read here, because the setting
  /// governs the whole app and this widget must not be a second place that
  /// decides what it means.
  final bool netStyle;

  /// The combo-tee chip and the Spots button live on this row too, and they
  /// belong to the screen rather than here.
  final Widget Function(SurvivorCardPlayer p)? rowExtras;

  /// **What the group has actually typed**, which is not what the card says:
  /// the card is SERVER state and only moves when a hole is posted.
  final Map<int, int>? scores;

  const SurvivorPlayersCard({
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
    final byId = {for (final p in card.players) p.playerId: p};
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final s in card.sections) ...[
          if (s.isZombieville)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: CustomPaint(
                size: Size(double.infinity, 1),
                painter: DashedRRect(
                    color: Halved.cardBorder, width: 1, radius: 0),
              ),
            ),
          _band(s),
          for (final pid in s.playerIds)
            if (byId[pid] != null) _row(byId[pid]!, s.isZombieville),
        ],
      ]),
    );
  }

  /// `DECIDER · PAUL V DAVE` and, right, what that section plays for.
  Widget _band(SurvivorCardSection s) => Container(
        width: double.infinity,
        color: const Color(0xFFF6F8F6),
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        child: Row(children: [
          Expanded(
            child: Text(s.title.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: Halved.muted)),
          ),
          const SizedBox(width: 8),
          Text(s.note.toUpperCase(),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: Halved.muted)),
        ]),
      );

  /// The gross on screen: what has been typed, falling back to the card.
  int? _gross(SurvivorCardPlayer p) {
    final typed = scores?[p.playerId];
    if (typed != null && typed > 0) return typed;
    // A 0 in the map is a CLEARED score, not a missing one.
    if (typed == 0) return null;
    return p.gross;
  }

  int? _net(SurvivorCardPlayer p) {
    final g = _gross(p);
    return g == null ? null : g - p.strokes;
  }

  Widget _row(SurvivorCardPlayer p, bool inZombieville) {
    final active = p.playerId == activePlayerId;
    final colour = Halved.golfer(p.colourIndex);
    final extras = rowExtras?.call(p);
    return InkWell(
      onTap: onTapPlayer == null ? null : () => onTapPlayer!(p.playerId),
      child: Container(
        color: active
            ? const Color(0xFFE8F6EF)
            : inZombieville
                ? const Color(0x0A000000)
                : null,
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
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: inZombieville
                                    ? Halved.muted
                                    : Halved.deepPine)),
                      ),
                      const SizedBox(width: 6),
                      Text('CH ${p.courseHandicap ?? 0}',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Halved.muted)),
                      if (p.isZombie) ...[
                        const SizedBox(width: 8),
                        _zombieTag(colour),
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

  /// **Dashed, in his own colour.** A Zombie is neither in nor out — the
  /// dash is what says the state is provisional, and the colour keeps him
  /// identifiable while his name is muted.
  Widget _zombieTag(Color colour) => CustomPaint(
        painter: DashedRRect(color: colour, width: 1.2, radius: 7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Text('Zombie',
              style: TextStyle(
                  color: colour,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ),
      );

  /// `net 4`, filling in that golfer's colour when the hole turned on him —
  /// the decider winner, or the Zombie who came back. A tie fills none,
  /// which is the same rule that decides whether anything moves.
  Widget _netChip(SurvivorCardPlayer p) {
    final filled = card.result?.chipPlayerId == p.playerId;
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

  Widget _scoreBox(SurvivorCardPlayer p) {
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

/// The dark tray: what the hole did to the Survivor, and the way on.
///
/// **It covers the pager while it is up**, like Sixes' and Rabbit's, because
/// its forward button can name the next SURVIVOR — which a generic pager has
/// no way to know. That means it also carries the way off the last hole.
class SurvivorHoleTray extends StatelessWidget {
  final SurvivorHoleCard card;
  final VoidCallback onEdit;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final int? nextHole;

  /// The result is on its way — what we hold predates the score just entered.
  final bool gettingResult;

  /// `Edit scores` pressed and no golfer chosen yet — see [TrayEditHeader].
  final bool picking;

  const SurvivorHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    required this.nextHole,
    this.onPrev,
    this.onNext,
    this.gettingResult = false,
    this.picking = false,
  });

  Color _colourOf(int? pid) {
    final p = card.playerOf(pid);
    return p == null ? Halved.brightMint : Halved.golfer(p.colourIndex);
  }

  @override
  Widget build(BuildContext context) {
    final r = gettingResult ? null : card.result;
    final sv = card.survivor;
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
          TrayEditHeader(
            title: 'All ${card.players.length} scores in',
            picking: picking,
            onEdit: onEdit,
          ),
          _labelRow(
            'HOLE ${card.hole} · SURVIVOR ${sv.index ?? ''}',
            '\$${_money(sv.pot)} POT',
          ),
          const SizedBox(height: 6),
          if (r == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('Getting result…',
                  style: TextStyle(color: _dim)),
            )
          else
            _holeCard(r),
          if (r != null && card.next != null) ...[
            const SizedBox(height: 8),
            _labelRow('NEXT', '\$${_money(card.next!.pot)} POT'),
            const SizedBox(height: 4),
            _nextCard(card.next!),
          ],
          const SizedBox(height: 12),
          _buttons(),
        ],
      ),
    );
  }

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

  Widget _holeCard(SurvivorHoleOutcome r) => Container(
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The chip gets the row's slack, not the label — three characters
            // and a number against a sentence (Rabbit, 30 Oct 2026).
            Row(children: [
              // **`Hole 10`, with no phase after it.** The phase was named
              // here as well, which made it the THIRD statement of the same
              // thing on one screen — the header chip and the section band
              // both carry it directly above — and the fourth is the line
              // below, which names the phase of the NEXT hole. On a
              // resurrection all four were `The Duel` (Paul, 31 Oct 2026).
              //
              // Dropping the backward-looking one is also what gives the
              // chip its room: `Jim low outright · net 4 v 5 v 6` was
              // ellipsised to `Jim low out…` by a label it did not need.
              // This is now exactly Rabbit's tray line, which is one less
              // shape to learn.
              Text('Hole ${card.hole}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
              const SizedBox(width: 10),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _resultChip(r),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _standing(r),
            if (r.lineLead.isNotEmpty || r.lineRest.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(children: [
                  if (r.lineLead.isNotEmpty)
                    TextSpan(
                        text: '${r.lineLead} ',
                        style: const TextStyle(
                            color: Halved.brightMint,
                            fontWeight: FontWeight.w700)),
                  TextSpan(
                      text: r.lineRest,
                      style: const TextStyle(color: _dim)),
                ]),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ],
        ),
      );

  /// In the colour of whoever the hole turned on, or neutral on a tie —
  /// which is the one outcome that is about nobody.
  Widget _resultChip(SurvivorHoleOutcome r) {
    final owned = r.chipPlayerId != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: owned ? _colourOf(r.chipPlayerId) : const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: Text(r.chip,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
        ),
        if (r.chipNets.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(r.chipNets,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ),
        ],
      ]),
    );
  }

  /// The standing after the hole, each name wearing its own colour, and the
  /// money or what the next hole is played as.
  Widget _standing(SurvivorHoleOutcome r) => Row(children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final s in r.standing) ...[
                if (s.playerId != null) ...[
                  Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: _colourOf(s.playerId),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
                Text(s.text,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
              ],
            ],
          ),
        ),
        if (r.standingRight != null) ...[
          const SizedBox(width: 8),
          Text(r.standingRight!,
              style: TextStyle(
                  color: r.rightIsMoney ? Halved.brightMint : _dim,
                  fontWeight: FontWeight.w700,
                  fontSize: r.rightIsMoney ? 26 : 13)),
        ],
      ]);

  Widget _nextCard(SurvivorNextLeg n) => CustomPaint(
        painter: const DashedRRect(color: Color(0x4DFFFFFF), width: 1),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(n.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
              const SizedBox(height: 2),
              Text(n.note, style: const TextStyle(color: _dim, fontSize: 13)),
            ],
          ),
        ),
      );

  Widget _buttons() {
    final n = card.result?.survivorEnded == true ? card.next : null;
    // `Complete Round`, the same words the pager uses — this button is what
    // replaces it on the last hole, so it should not be a different name for
    // the same action.
    final label = nextHole == null
        ? 'Complete Round'
        : n == null
            ? 'Hole $nextHole ›'
            : 'Survivor ${n.index} · hole $nextHole ›';
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
