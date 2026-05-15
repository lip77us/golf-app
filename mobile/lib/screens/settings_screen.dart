/// screens/settings_screen.dart
///
/// Per-device preferences page reachable from the app drawer.  Currently
/// hosts only the Net Style Entry toggle; future per-device flags belong
/// here as well.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Net Style Entry'),
            subtitle: Text(
              settings.netStyleEntry
                  ? 'White square = net par (par + your strokes on the hole). '
                    'Matches the stroke dots on the scorecard.'
                  : 'White square = gross par. Score colors ignore your '
                    'handicap strokes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            value: settings.netStyleEntry,
            onChanged: (v) => settings.setNetStyleEntry(v),
          ),
        ],
      ),
    );
  }
}
