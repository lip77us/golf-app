import 'package:flutter/material.dart';

/// Read-only "most you can lose" line for **bounded native games** (Sixes,
/// Triple Cup, Nassau without presses) whose max liability is a fixed multiple
/// of the stake. These games can't escalate, so instead of an editable loss
/// cap we just show the worst case — the exposure is known up front.
///
/// Renders nothing until a positive stake is entered. Recomputes whenever the
/// parent rebuilds (the stake field's onChanged triggers setState).
class MaxLiabilityNote extends StatelessWidget {
  /// Current per-stake amount (e.g. the round bet unit being entered).
  final double bet;

  /// How many independent one-stake bets a player can lose (segments / pots).
  final int multiple;

  /// Short parenthetical explaining where the multiple comes from, e.g.
  /// '3 segments' or 'one cup payout'.
  final String detail;

  const MaxLiabilityNote({
    super.key,
    required this.bet,
    required this.multiple,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    if (bet <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final max = bet * multiple;
    final maxStr =
        max == max.roundToDouble() ? max.toStringAsFixed(0) : max.toStringAsFixed(2);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.shield_outlined,
            size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Most you can lose: \$$maxStr  ($detail).',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}
