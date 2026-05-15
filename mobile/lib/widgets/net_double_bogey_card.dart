import 'package:flutter/material.dart';

/// Shared round-level toggle for the USGA-style net-double-bogey cap.
/// Used by every casual-game setup screen alongside the handicap-mode
/// picker.  The flag lives on Round, so toggling here writes to the
/// round via RoundProvider — each game setup screen passes its own
/// onChanged that fires the persist.
class NetDoubleBogeyCard extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const NetDoubleBogeyCard({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
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
              ? 'Per-hole scores capped at net par + 2 for game scoring. '
                'Applies to Net and Strokes-Off modes only.'
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
