/// widgets/stroke_play_entry.dart
/// ------------------------------
/// The Stroke Play score-entry tray (`~/Downloads/handoff-stroke-play`).
///
/// Built on the SAME keypad and tray vocabulary as 40 Balls, Sixes, Rabbit,
/// Survivor and Annandale Friday — `FortyBallsKeypad`, `TrayEditHeader`, the
/// dark tray shape — which is the packet's own first instruction.
///
/// **What it reports is a PLACE**, which is the one thing a card holding one
/// foursome cannot work out for itself. Everything drawn here comes off
/// `StrokePlayHoleCard`: the places, the movement, the counted net and the
/// cap are the server's, ranked by the same engine as the board the row's
/// own pill opens.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import '../utils/stroke_play_board_model.dart' show strokeToPar;
import 'tray_edit_header.dart';

/// Labels and secondary text on the tray: NEUTRAL white, no hue.
const Color _dim = Color(0x8CFFFFFF);

/// The tray's own panel, a shade up from the tray — the same one Rabbit's
/// and Sixes' trays use.
const Color _panel = Color(0xFF14312A);

/// Amber, for a hole the cap took a stroke off. It appears nowhere else on
/// this tray, so it cannot be read as a state.
const Color _capAmber = Color(0xFFF2B84B);

// ── the score mark, on a dark tray ───────────────────────────────────────────

/// A score in scorecard notation, sized and coloured for a DARK tray.
///
/// The twin of `ScoreNotation`, which is built for a light card: there a
/// birdie is a white circle ringed in pine, and on this background that is
/// invisible. The packet gives its own dark variants — birdie bright mint,
/// eagle white — and this is them. Public rather than private because the
/// next tray that needs a score mark should find this one instead of writing
/// a third.
class TrayScoreMark extends StatelessWidget {
  final int score;

  /// Null par draws a plain digit: there is no shape without a baseline.
  final int? par;

  /// Moves the BASELINE, not the score — Net Style Entry, the rule the
  /// keypad and the score box both honour.
  final int strokes;

  /// The cap took a stroke off this hole, so it is outlined in amber.
  final bool capped;

  const TrayScoreMark({
    super.key,
    required this.score,
    required this.par,
    this.strokes = 0,
    this.capped = false,
  });

  @override
  Widget build(BuildContext context) {
    final d = par == null ? 0 : score - par! - strokes;
    final (Color fill, Color line, Color ink) = d <= -2
        ? (Colors.white, Colors.white, Halved.deepPine)
        : d == -1
            ? (Halved.brightMint, Halved.brightMint, Halved.deepPine)
            : d == 0
                ? (const Color(0xFFBFDCC6), const Color(0xFFBFDCC6),
                    Halved.deepPine)
                : d == 1
                    ? (const Color(0xFFFDF6EF), const Color(0xFFD9A27A),
                        Halved.clayInk)
                    : (const Color(0xFFFAEBDD), const Color(0xFFD9A27A),
                        const Color(0xFF7A3A06));
    final round = d <= -1;
    final doubled = d <= -2 || d >= 2;

    Widget box = Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: par == null ? const Color(0x1FFFFFFF) : fill,
        borderRadius: BorderRadius.circular(round ? 13 : 5),
        border: Border.all(
            color: par == null ? const Color(0x4DFFFFFF) : line, width: 1.5),
      ),
      alignment: Alignment.center,
      child: doubled
          ? Container(
              margin: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(round ? 10 : 3),
                border: Border.all(color: line, width: 1.2),
              ),
              alignment: Alignment.center,
              child: _digit(par == null ? Colors.white : ink),
            )
          : _digit(par == null ? Colors.white : ink),
    );

    if (!capped) return box;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(round ? 15 : 7),
        border: Border.all(color: _capAmber, width: 2),
      ),
      child: box,
    );
  }

  Widget _digit(Color ink) => Text('$score',
      style: TextStyle(
          color: ink, fontSize: 13, fontWeight: FontWeight.w700, height: 1));
}

// ── the tray ─────────────────────────────────────────────────────────────────

/// The hole just played, and where it left every golfer on the board.
class StrokePlayHoleTray extends StatelessWidget {
  final StrokePlayHoleCard card;
  final VoidCallback onEdit;

  /// **The tray carries the pager, and COVERS the screen's own** — the rule
  /// Sixes' tray settled: while this is up it IS the bottom bar, so a
  /// disabled forward button here would leave the round with no way on. On
  /// the last hole it is the Complete Round button.
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final int? nextHole;

  /// The result is on its way — what we hold for this hole predates the score
  /// just entered, so the board is not drawn.
  final bool gettingResult;

  /// Saved on the phone, not yet at the server.
  final bool notSynced;

  /// `Edit scores` pressed and no golfer chosen yet — see [TrayEditHeader].
  final bool picking;

  const StrokePlayHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    required this.nextHole,
    this.onPrev,
    this.onNext,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
  });

  bool get _stale => gettingResult || notSynced;

  @override
  Widget build(BuildContext context) {
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
            card.isFinal ? 'ROUND OVER' : 'HOLE ${card.hole} · STROKE PLAY',
            // The field when it is bigger than this card, and otherwise the
            // basis — a `GROUP OF 4` beside four rows says nothing.
            card.field > card.group
                ? 'FIELD OF ${card.field}'
                : (card.showNet ? 'NET' : 'GROSS'),
          ),
          const SizedBox(height: 6),
          if (_stale)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                gettingResult
                    ? 'Getting result…'
                    : 'Saved. The places show once this hole syncs.',
                style: const TextStyle(color: _dim),
              ),
            )
          else
            _board(),
          if (!_stale && card.capNotes.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final n in card.capNotes) _capNote(n),
          ],
          if (!_stale && card.leader != null) ...[
            const SizedBox(height: 8),
            _leaderLine(card.leader!),
          ],
          const SizedBox(height: 12),
          _buttons(),
        ],
      ),
    );
  }

  static const double _posW = 56;
  static const double _holeW = 74;
  static const double _totW = 46;

  Widget _labelRow(String left, String right) => Row(children: [
        Expanded(
          child: Text(left,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: _dim,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .5)),
        ),
        const SizedBox(width: 8),
        Text(right,
            style: const TextStyle(
                color: _dim,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: .5)),
      ]);

  /// Pos · Player · Hole · Tot, one row per golfer on this card.
  Widget _board() {
    const head = TextStyle(
        color: _dim, fontSize: 10.5, fontWeight: FontWeight.w700,
        letterSpacing: .4);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x12FFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(11, 4, 11, 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(
          height: 24,
          child: Row(children: [
            SizedBox(width: _posW, child: Text('POS', style: head)),
            Expanded(child: Text('PLAYER', style: head)),
            SizedBox(
                width: _holeW,
                child: Text('HOLE', style: head, textAlign: TextAlign.right)),
            SizedBox(
                width: _totW,
                child: Text('TOT', style: head, textAlign: TextAlign.right)),
          ]),
        ),
        for (var i = 0; i < card.standing.length; i++)
          _row(card.standing[i], first: i == 0),
      ]),
    );
  }

  Widget _row(StrokePlayStandingRow r, {required bool first}) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        border: first
            ? null
            : const Border(top: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Row(children: [
        SizedBox(width: _posW, child: _pos(r)),
        Expanded(
          child: Text(r.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        SizedBox(width: _holeW, child: _hole(r)),
        SizedBox(width: _totW, child: Align(
            alignment: Alignment.centerRight, child: _tot(r.toPar))),
      ]),
    );
  }

  /// `2 ▲1` — the place, and the places gained on this hole.
  Widget _pos(StrokePlayStandingRow r) {
    final moved = r.moved;
    final (String glyph, Color ink) = moved == null
        ? ('', _dim)
        : moved > 0
            ? ('▲$moved', Halved.brightMint)
            : moved < 0
                ? ('▼${-moved}', const Color(0xFFF2A86E))
                : ('–', const Color(0xFF7F968C));
    // **Both facts shrink together** rather than one of them ellipsising: a
    // `T10 ▲3` is wider than a `1`, and an arrow cut in half says nothing
    // while a place cut in half is the wrong place.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic, children: [
        Text(r.placeText.isEmpty ? '—' : r.placeText,
            style: const TextStyle(
                color: Colors.white, fontSize: 16,
                fontWeight: FontWeight.w700)),
        if (glyph.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(glyph,
              style: TextStyle(
                  color: ink, fontSize: 10.5, fontWeight: FontWeight.w700)),
        ],
      ]),
    );
  }

  /// The gross in its shape, with the counted net beside it.
  Widget _hole(StrokePlayStandingRow r) {
    if (r.gross == null) {
      return const Align(
          alignment: Alignment.centerRight,
          child: Text('–', style: TextStyle(color: _dim)));
    }
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      TrayScoreMark(
          score: r.gross!,
          par: r.par,
          strokes: card.showNet ? r.strokes : 0,
          capped: r.capped),
      if (card.showNet && r.net != null) ...[
        const SizedBox(width: 6),
        Text('${r.net}',
            style: TextStyle(
                color: r.capped ? _capAmber : _dim,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
      ],
    ]);
  }

  /// The filled to-par box: mint under, white level, translucent over — the
  /// board's own three states, read on a dark tray.
  Widget _tot(int? v) {
    final (Color fill, Color ink) = v == null
        ? (const Color(0x24FFFFFF), Colors.white)
        : v < 0
            ? (Halved.brightMint, Halved.deepPine)
            : v == 0
                ? (Colors.white, Halved.deepPine)
                : (const Color(0x24FFFFFF), Colors.white);
    return Container(
      constraints: const BoxConstraints(minWidth: 42),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration:
          BoxDecoration(color: fill, borderRadius: BorderRadius.circular(7)),
      child: Text(strokeToPar(v),
          textAlign: TextAlign.center,
          style: TextStyle(
              color: ink, fontSize: 14.5, fontWeight: FontWeight.w700)),
    );
  }

  /// The server's own sentence. The cap is a rule, so the words are its.
  Widget _capNote(String note) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(note,
            style: const TextStyle(
                color: _dim, fontSize: 12, height: 1.4)),
      );

  Widget _leaderLine(StrokePlayLeader l) => Container(
        decoration: BoxDecoration(
            color: _panel, borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        child: Row(children: [
          const Text('Leader · ', style: TextStyle(color: _dim, fontSize: 12.5)),
          Expanded(
            child: Text(l.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(strokeToPar(l.toPar),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 5),
          Text(l.thru >= 18 ? 'final' : 'thru ${l.thru}',
              style: const TextStyle(color: _dim, fontSize: 12.5)),
        ]),
      );

  Widget _buttons() {
    // `Complete Round`, the same words the pager uses — this button is what
    // replaces it on the last hole.
    final label = nextHole == null ? 'Complete Round' : 'Hole $nextHole ›';
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
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
