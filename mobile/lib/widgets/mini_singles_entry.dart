import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'side_colour.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';
import 'tray_result_row.dart';

/// Mini Singles Bracket score entry —
/// `~/Downloads/handoff-mini-singles-score-entry` (11 Nov 2026).
///
/// The keypad and the dark tray the other games share, over a bracket: two
/// semis on the front nine, the finals and 3rd place on the back. The tray
/// draws one block per match LIVE on the hole, the bracket ahead, and on 18
/// who won the group and what everybody is paid.
///
/// One tray for the casual Match Play foursome and for both tournament days.
///
/// **Nothing is decided here.** `MiniSinglesHoleCard` arrives with every
/// sentence written — a close-out, a semi that plays on, a halved finals and
/// where its trophy goes — and this file draws it.
///
/// **Blue and orange, not the packet's pine and clay**: the golfer rows on
/// this screen have drawn a match's two sides that way since the bracket
/// shipped (`side_colour.dart`), and a tray in different colours from the
/// rows it reports is worse than one in different colours from the design.

const Color _secondary = Color(0xFFB9CCC3);

class MiniSinglesHoleTray extends StatelessWidget {
  final MiniSinglesHoleCard card;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// The hole the forward button opens; null on the last one.
  final int? nextHole;

  final bool gettingResult;
  final bool notSynced;
  final bool picking;

  const MiniSinglesHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.nextHole,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
  });

  @override
  Widget build(BuildContext context) {
    final hold = gettingResult || notSynced;
    final maxH = MediaQuery.of(context).size.height * 0.72;
    final n = card.players.length;
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
            title: gettingResult ? 'Getting result…' : 'All $n scores in',
            onEdit: onEdit,
            picking: picking,
          ),
          if (!hold) ...[
            const SizedBox(height: 10),
            // The buttons sit OUTSIDE this box: they are the only pager on
            // screen while the tray is up, so the content scrolls and they
            // do not.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH - 130),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: _content(),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _buttons(),
        ],
      ),
    );
  }

  List<Widget> _content() => [
        TrayLabel(card.label, trailing: card.trailing),
        const SizedBox(height: 6),
        for (final b in card.blocks) ...[
          if (b.overLine.isNotEmpty) _over(b) else _block(b),
          const SizedBox(height: 8),
        ],
        if (card.nextTitle != null) ...[
          const SizedBox(height: 10),
          TrayLabel(card.nextLabel ?? 'Next'),
          const SizedBox(height: 6),
          _dashed(_NextBody(
              title: card.nextTitle!, body: card.nextBody ?? '')),
        ],
        if (card.winnerName != null) ...[
          const SizedBox(height: 2),
          _winner(),
        ],
        if (card.result.isNotEmpty) ...[
          const SizedBox(height: 8),
          _result(),
        ],
      ];

  static BoxDecoration get _panel => BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      );

  static const _tag = TextStyle(
      color: _secondary, fontSize: 10.5, letterSpacing: 1.0,
      fontWeight: FontWeight.w700);

  Widget _dashed(Widget child) => CustomPaint(
        painter: DashedRRect(
            color: Colors.white.withValues(alpha: 0.40),
            width: 1.2, radius: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: SizedBox(width: double.infinity, child: child),
        ),
      );

  /// A match that was over before this hole: one line, not a block.
  Widget _over(MiniSinglesBlock b) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: _panel,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(b.title.toUpperCase(), style: _tag),
          const SizedBox(width: 10),
          Expanded(
            child: Text(b.overLine,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      );

  /// One match live on this hole: the hole line, then the standing.
  ///
  /// Against a semi that is still level the opponent is `TBD` and the card
  /// is dashed — a real, scored match whose other name is not known yet.
  Widget _block(MiniSinglesBlock b) {
    final colour =
        b.leader == null ? Colors.white : sideColour(b.leader!, onDark: true);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(b.title.toUpperCase(), style: _tag),
        const SizedBox(height: 4),
        TrayResultRow(
          name1: b.names[0],
          name2: b.names[1],
          colour1: sideColour(1, onDark: true),
          colour2: sideColour(2, onDark: true),
          decided: b.played,
          winner: b.winner,
          reasonLabel: b.reasonLabel,
          figure1: b.figure1,
          figure2: b.figure2,
        ),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: b.leader == null
                    ? Colors.white.withValues(alpha: 0.45) : colour,
                borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          // One flexible child: the head yields, the margin never does.
          Flexible(
            child: Text(b.head,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Text(b.margin,
              style: TextStyle(color: colour, fontSize: 22, height: 1.0,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text(b.sub,
            style: const TextStyle(color: _secondary, fontSize: 12,
                height: 1.3, fontWeight: FontWeight.w600)),
        if (b.tiles.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            for (var i = 0; i < b.tiles.length; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(child: _tile(b.tiles[i])),
            ],
          ]),
        ],
      ],
    );
    if (b.tbd) return _dashed(body);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: _panel,
      child: body,
    );
  }

  Widget _tile(MiniSinglesTile t) {
    Color? fill;
    if (t.state == 'p1') {
      fill = sideColour(1, onDark: true);
    } else if (t.state == 'p2') {
      fill = sideColour(2, onDark: true);
    } else if (t.state == 'halved') {
      fill = Colors.white.withValues(alpha: 0.16);
    }
    final won = t.state == 'p1' || t.state == 'p2';
    return Opacity(
      opacity: t.state == 'dead' ? 0.35 : 1.0,
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
        child: Text('${t.hole}',
            style: TextStyle(
                color: won ? Halved.deepPine : Colors.white,
                fontSize: 10.5, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _winner() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: _panel,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text((card.winnerLabel ?? '').toUpperCase(), style: _tag),
          const SizedBox(height: 3),
          Text(card.winnerName ?? '',
              style: const TextStyle(
                  color: Halved.brightMint, fontSize: 20, height: 1.1,
                  fontWeight: FontWeight.w800)),
          if ((card.winnerLine ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(card.winnerLine!,
                style: const TextStyle(color: _secondary, fontSize: 12,
                    height: 1.3, fontWeight: FontWeight.w600)),
          ],
        ]),
      );

  /// `Result`, not Final — one row a golfer in place order.
  ///
  /// The row has fixed columns, so exactly one child is flexible and it is
  /// `Expanded`: a loose `Flexible` beside fixed columns is what moved a
  /// whole table on the Wolf tray.
  Widget _result() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        decoration: _panel,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(
            height: 24,
            child: Row(children: [
              Expanded(child: Text('RESULT', style: _tag)),
              SizedBox(width: 44, child: Text('PLACE', style: _tag)),
              SizedBox(
                width: 64,
                child: Text('MONEY',
                    textAlign: TextAlign.right, style: _tag),
              ),
            ]),
          ),
          for (final r in card.result)
            Container(
              height: 32,
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(r.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                SizedBox(
                  width: 44,
                  child: Text(r.place,
                      style: const TextStyle(color: _secondary,
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                SizedBox(
                  width: 64,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _amount(r),
                  ),
                ),
              ]),
            ),
          if (card.resultLine.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(card.resultLine,
                style: const TextStyle(color: _secondary, fontSize: 11.5,
                    height: 1.3, fontWeight: FontWeight.w500)),
          ],
        ]),
      );

  Widget _amount(MiniSinglesResultRow r) {
    if (r.tone != 'up') {
      return Text(r.amount,
          style: TextStyle(
              color: r.tone == 'level' ? _secondary : Colors.white,
              fontSize: 13, fontWeight: FontWeight.w700));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Halved.brightMint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(r.amount,
          style: const TextStyle(color: Halved.deepPine, fontSize: 13,
              fontWeight: FontWeight.w700)),
    );
  }

  /// What the forward button says: `Back nine · hole 10` at the turn, which
  /// a generic pager has no way to know.
  String get forwardLabel {
    if (nextHole == null) return 'Finish round ›';
    final b = card.nextButton;
    if (b != null && b.isNotEmpty) return '$b ›';
    return 'Hole $nextHole ›';
  }

  Widget _buttons() => Row(children: [
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
              child: Text(forwardLabel,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ]);
}

/// The matches in play on this hole — one line each, under the hole header:
/// `SEMI 1   Paul v Lee   Paul 2 UP`.
///
/// **The tray only says this once the hole is in**, and the golfer rows are
/// in card order with opponents that change at the turn. So on the tee the
/// only way to find out who you were playing was the leaderboard (Paul, 11
/// Nov 2026). This is the same card the tray draws, read before the scores:
/// the standing is the match as it stood coming INTO the hole.
///
/// On a light card, so the sides are the light-ground blue and orange the
/// rows beneath wear.
class MiniSinglesMatches extends StatelessWidget {
  final MiniSinglesHoleCard card;
  const MiniSinglesMatches({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    if (card.blocks.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        decoration: BoxDecoration(
          color: Halved.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: [
          for (final b in card.blocks) _line(b),
        ]),
      ),
    );
  }

  Widget _line(MiniSinglesBlock b) {
    final over = b.overLine.isNotEmpty;
    // `Paul 2 UP`, `Paul wins 2&1`, or `AS` where nobody leads.
    final state = b.leader == null ? b.margin : '${b.head} ${b.margin}';
    final colour = b.leader == null ? Halved.muted : sideColour(b.leader!);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(
          width: 66,
          child: Text(b.title.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Halved.muted, fontSize: 10.5, letterSpacing: 0.6,
                  fontWeight: FontWeight.w700)),
        ),
        // One flexible child: the names yield, the standing never does.
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: b.names[0],
                  style: TextStyle(color: sideColour(1))),
              const TextSpan(
                  text: ' v ', style: TextStyle(color: Halved.muted)),
              TextSpan(
                  text: b.names[1],
                  style: TextStyle(
                      color: b.names[1] == 'TBD'
                          ? Halved.muted : sideColour(2))),
            ]),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        Text(state,
            style: TextStyle(
                color: over ? Halved.muted : colour,
                fontSize: 12.5, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _NextBody extends StatelessWidget {
  final String title;
  final String body;
  const _NextBody({required this.title, required this.body});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w700)),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(body,
                style: const TextStyle(color: _secondary, fontSize: 12,
                    height: 1.3, fontWeight: FontWeight.w500)),
          ],
        ],
      );
}
