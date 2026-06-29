import 'package:flutter/material.dart';

/// Read-only note shown on a SIDE game's setup screen in place of the handicap
/// selector. Side games don't carry their own net config — the primary game
/// drives Strokes-Off / Net / Gross — so this just surfaces the inherited mode.
class InheritedHandicapNote extends StatelessWidget {
  final String mode;        // 'net' | 'gross' | 'strokes_off'
  final int    netPercent;
  const InheritedHandicapNote(
      {super.key, required this.mode, required this.netPercent});

  String get _label {
    switch (mode) {
      case 'gross':
        return 'Gross';
      case 'strokes_off':
        return netPercent == 100
            ? 'Strokes-Off Low'
            : 'Strokes-Off Low ($netPercent%)';
      default:
        return netPercent == 100 ? 'Net' : 'Net ($netPercent%)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: ListTile(
        leading: Icon(Icons.lock_outline, color: theme.colorScheme.onSurfaceVariant),
        title: Text('Handicap: $_label'),
        subtitle: const Text('Set by the main game — side games follow it.'),
      ),
    );
  }
}
