/// widgets/combo_tee_chip.dart
///
/// `White` — which tee this golfer plays on the hole in front of him, on a
/// COMBO set only.
///
/// **A neutral outline, not a filled chip.** Tee names ARE colours, so a
/// coloured chip reading "White" asks the eye to reconcile two at once, and a
/// white chip on a white row is invisible. The filled treatment beside it is
/// the app's voice for something happening TO you — strokes, bets, doubles —
/// and a tee box is a fact about the hole.
///
/// Name only: no colour swatch and no yardage, which is on the card already.
///
/// **It is a widget rather than a block of markup on one screen** because
/// twelve screens draw a golfer's name beside his score box, and the first
/// version of this went onto exactly one of them — the generic score-entry
/// screen — so a Sequoya 3s round showed nothing at all. Reported from a round
/// at Metropolitan on 12 Sep 2026. The lesson is the same one the scorecard
/// grids taught: the games with their OWN play screen are the ones that get
/// missed.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';

class ComboTeeChip extends StatelessWidget {
  /// Already resolved for the hole — null or empty draws nothing, which is
  /// both "not on a combo" and "the course data could not resolve it". From
  /// the reader's side those are the same thing: he reads the card.
  final String? tee;

  const ComboTeeChip({super.key, required this.tee});

  /// The common way to build one: hand over the membership and the hole.
  factory ComboTeeChip.forHole(Membership m, int hole) =>
      ComboTeeChip(tee: m.comboTeeOnHole(hole));

  @override
  Widget build(BuildContext context) {
    final name = tee;
    if (name == null || name.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outline),
        ),
        child: Text(
          name,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
