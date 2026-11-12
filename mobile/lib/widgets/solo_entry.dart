import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';
import 'tray_result_row.dart';

/// Solo games' score entry — `handoff-solo-score-entry`.
///
/// One golfer against par: Stroke Play, Nassau and Match Play, all net, all
/// for fun. The card is the server's (`solo_hole_card`); nothing here decides
/// a hole. **The golfer is mint and par is clay**, the two light colours of
/// the dark tray, so `Paul v Par` reads the way every other match line does.
const Color _secondary = Color(0xFFB9CCC3);

final Color _golfer = Halved.onDark1;
final Color _par = Halved.onDark2;

/// `SOLO` · `12 STROKES · SI 1–12`, over the one golfer row.
class SoloHeader extends StatelessWidget {
  final SoloHoleCard card;
  const SoloHeader({super.key, required this.card});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: Halved.surface, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Text('SOLO',
                style: TextStyle(
                    color: Halved.muted, fontSize: 10.5, letterSpacing: 0.7,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(
                [
                  '${card.strokesTotal} STROKES',
                  if (card.siRange.isNotEmpty) card.siRange,
                ].join(' · '),
                style: const TextStyle(
                    color: Halved.muted, fontSize: 10.5, letterSpacing: 0.7,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class SoloHoleTray extends StatelessWidget {
  final SoloHoleCard card;
  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool gettingResult;
  final bool notSynced;
  final bool picking;

  const SoloHoleTray({
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
            title: gettingResult
                ? 'Getting result…'
                : notSynced ? 'Saving…' : 'Score in',
            onEdit: onEdit,
            picking: picking,
            pickingHint: 'Tap your score above to change it',
          ),
          if (!hold)
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
                        card.roundOver
                            ? 'Round over'
                            : 'Hole ${card.hole} · ${card.title}',
                        trailing: 'vs par'),
                    const SizedBox(height: 6),
                    if (card.variant == 'stroke') _stroke() else ...[
                      if (card.afterLine.isNotEmpty)
                        _box(Text(card.afterLine,
                            style: const TextStyle(
                                color: _secondary, fontSize: 13.5)))
                      else
                        _versus(),
                      const SizedBox(height: 6),
                      if (card.variant == 'nassau') _nassau() else _match(),
                    ],
                    if (card.hasFinal) ...[
                      const SizedBox(height: 6),
                      _final(),
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

  Widget _box(Widget child, {EdgeInsets? padding}) => Container(
        width: double.infinity,
        padding: padding ?? const EdgeInsets.fromLTRB(13, 10, 13, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  /// `Paul v Par   net 3 v 3  [Halved]` — the hole line, as in Fourball.
  Widget _versus() {
    final w = card.result == 'won' ? 1 : card.result == 'lost' ? 2 : null;
    return _box(
      TrayResultRow(
        name1: card.first,
        name2: 'Par',
        colour1: _golfer,
        colour2: _par,
        decided: card.result != null,
        winner: w,
        reasonLabel: 'net',
        figure1: card.net,
        figure2: card.par,
      ),
      padding: const EdgeInsets.fromLTRB(13, 8, 13, 8),
    );
  }

  Widget _stroke() {
    final word = card.strokeWord;
    final bubbleFill = card.result == 'won'
        ? Halved.brightMint
        : card.result == 'lost'
            ? const Color(0x33F2A86E)
            : Colors.white.withValues(alpha: 0.14);
    final bubbleInk =
        card.result == 'won' ? Halved.deepPine : Colors.white;
    final fig = card.toPar < 0
        ? Halved.brightMint
        : card.toPar > 0 ? _par : Colors.white;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _box(
        padding: const EdgeInsets.fromLTRB(13, 8, 13, 8),
        Row(children: [
          Text(card.first,
              style: TextStyle(
                  color: _golfer, fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          Expanded(
            child: Text('gross ${card.gross ?? '–'} · net ${card.net ?? '–'}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: _secondary, fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          if (word.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                  color: bubbleFill,
                  borderRadius: BorderRadius.circular(999)),
              child: Text(word,
                  style: TextStyle(
                      color: bubbleInk, fontSize: 13,
                      fontWeight: FontWeight.w800)),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      _box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic, children: [
          Text(card.roundOver ? 'Net total' : 'Net to par',
              style: const TextStyle(
                  color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 14),
          Text(card.toParText,
              style: TextStyle(
                  color: fig, fontSize: 26, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 4),
        Text(
            'gross ${card.grossTotal} · net ${card.netTotal} · '
            'thru ${card.strokeThru}',
            style: const TextStyle(color: _secondary, fontSize: 13.5)),
      ])),
    ]);
  }

  Widget _nassau() => _box(
        Wrap(spacing: 5, runSpacing: 5, children: [
          for (final c in card.chips) _Chip(chip: c),
        ]),
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      );

  Widget _match() {
    final lead = card.matchLeader;
    final c = lead == 1 ? _golfer : lead == 2 ? _par : Colors.white;
    return _box(
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic, children: [
          if (lead != null)
            Container(
                width: 10, height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(3))),
          Expanded(
            child: Text(card.matchStanding,
                style: TextStyle(
                    color: c, fontSize: 22, fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
            card.overLine.isNotEmpty
                ? card.overLine
                : 'thru ${card.matchThru} · ${card.matchToPlay} to play',
            style: const TextStyle(color: _secondary, fontSize: 13.5)),
        const SizedBox(height: 8),
        for (final row in [
          card.tiles.take(9).toList(),
          card.tiles.skip(9).take(9).toList(),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              for (var i = 0; i < row.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(child: _tile(row[i])),
              ],
            ]),
          ),
      ]),
    );
  }

  Widget _tile(SoloTile t) {
    Color? fill;
    var fg = Colors.white;
    switch (t.state) {
      case 'w': fill = _golfer; fg = Halved.deepPine; break;
      case 'l': fill = _par; fg = Halved.deepPine; break;
      case 'h': fill = Colors.white.withValues(alpha: 0.16); break;
    }
    return Opacity(
      opacity: t.dimmed ? 0.4 : 1,
      child: Container(
        height: 30, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(7),
          border: fill == null
              ? Border.all(color: Colors.white.withValues(alpha: 0.25))
              : null,
        ),
        child: Text('${t.hole}',
            style: TextStyle(
                color: t.state == 'x' ? const Color(0xFF7F968C) : fg,
                fontSize: 12, fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _final() => _box(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('FINAL',
              style: TextStyle(
                  color: _secondary, fontSize: 10.5, letterSpacing: 0.6,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(card.finalCard.isNotEmpty ? card.finalCard : card.finalLine,
              style: const TextStyle(
                  color: Colors.white, fontSize: 20,
                  fontWeight: FontWeight.w800)),
          if (card.finalSub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(card.finalSub,
                  style: const TextStyle(color: _secondary, fontSize: 13.5)),
            ),
          if (card.finalNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(card.finalNote,
                  style: const TextStyle(color: _secondary, fontSize: 13.5)),
            ),
        ]),
      );
}

/// `Front Par 1 UP`, `Back starts 10` (dashed — a promise), `Overall AS`.
class _Chip extends StatelessWidget {
  final SoloChip chip;
  const _Chip({required this.chip});

  @override
  Widget build(BuildContext context) {
    final pending = chip.state == 'pending';
    final fin = chip.state == 'final';
    final lead = chip.leader == 1
        ? _golfer
        : chip.leader == 2 ? _par : Colors.white;
    final text = chip.text;
    final label = chip.label;
    final split = text.startsWith(label) ? label.length : 0;
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
              text: text.substring(0, split),
              style: TextStyle(
                  color: pending
                      ? _secondary
                      : Colors.white.withValues(alpha: 0.78))),
          TextSpan(
              text: text.substring(split),
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

class _Buttons extends StatelessWidget {
  final SoloHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Buttons({required this.card, this.onPrev, this.onNext});

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
