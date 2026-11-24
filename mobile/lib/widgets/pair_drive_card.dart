/// widgets/pair_drive_card.dart
/// ----------------------------
/// A two-man scramble match's drive requirement, on the hole card: whose tee
/// shot each pair took on THIS hole, and where its quota stands.
///
/// The same tap the Team Play pairs use, and the same arithmetic — the line
/// under each pair (`Paul 1 · Sam 0 — 1 owed, 8 free`) is the server's own
/// sentence, so the card cannot disagree with the tracker. It never blocks a
/// score: a pair may knowingly take the shortfall, and falling short costs
/// nothing.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';

class PairDriveCard extends StatelessWidget {
  final FourballHoleCard card;

  /// (side 1|2, golfer id or null to clear).
  final void Function(int side, int? playerId) onPick;

  const PairDriveCard({super.key, required this.card, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final drive = card.drive;
    if (drive == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFDCE5DD)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('WHOSE DRIVE · HOLE ${card.hole}',
            style: Halved.body(color: Halved.muted)
                .copyWith(fontSize: 11, fontWeight: FontWeight.w700,
                          letterSpacing: 1)),
        for (final s in drive.sides) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final id in s.playerIds)
              ChoiceChip(
                key: ValueKey('drive-${s.side}-$id'),
                label: Text(card.playerById(id)?.first.isNotEmpty == true
                    ? card.playerById(id)!.first
                    : card.playerById(id)?.name ?? ''),
                selected: s.picked == id,
                // Tapping the chosen golfer again clears it.
                onSelected: (_) => onPick(s.side, s.picked == id ? null : id),
              ),
          ]),
          if (s.line.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(s.line,
                  key: ValueKey('drive-line-${s.side}'),
                  style: TextStyle(
                      fontSize: 12.5,
                      color: s.warn ? const Color(0xFF9A5B00) : Halved.muted,
                      fontWeight: s.warn ? FontWeight.w600 : FontWeight.w400)),
            ),
        ],
      ]),
    );
  }
}
