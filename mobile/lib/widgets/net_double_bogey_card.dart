import 'package:flutter/material.dart';

/// Shared round-level toggle for the USGA-style net-double-bogey cap.
/// Used by every casual-game setup screen alongside the handicap-mode
/// picker.  The flag lives on Round, so toggling here writes to the
/// round via RoundProvider — each game setup screen passes its own
/// onChanged that fires the persist.
class NetDoubleBogeyCard extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  /// The setup screen's current handicap settings. The cap only makes sense at
  /// full Net (100%) — it gets weird with a reduced allowance or Strokes-Off —
  /// so the card hides entirely unless mode == 'net' and netPercent == 100.
  final String handicapMode;
  final int netPercent;

  const NetDoubleBogeyCard({
    super.key,
    required this.value,
    required this.onChanged,
    required this.handicapMode,
    required this.netPercent,
  });

  @override
  Widget build(BuildContext context) {
    if (handicapMode != 'net' || netPercent != 100) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: SwitchListTile(
        title: const Text('Net Double-Bogey Cap'),
        subtitle: Text(
          value
              ? 'Per-hole scores capped at net par + 2 — one blow-up hole '
                'can\'t wreck your round.'
              : 'No cap — raw net scores drive every game.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
