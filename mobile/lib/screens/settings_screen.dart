/// screens/settings_screen.dart
///
/// Per-device preferences page reachable from the app drawer.  Currently
/// hosts only the Net Style Entry toggle; future per-device flags belong
/// here as well.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Confirm and run permanent account deletion.  On success the auth gate
  /// in main.dart redirects to the login screen; on failure (e.g. the
  /// last-admin guard) the user stays logged in and sees the reason.
  Future<void> _confirmAndDelete(BuildContext context) async {
    final auth      = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your login and signs you out. You will '
          'no longer be able to sign in with this account.\n\n'
          'Your past scores are kept anonymously as part of other players\' '
          'round history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await auth.deleteAccount();
      // Auth gate handles navigation to /login.
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not reach server. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final isAdmin  = context.watch<AuthProvider>().isAdmin;

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
          SwitchListTile(
            title: const Text('Auto-advance to next hole'),
            subtitle: Text(
              settings.autoAdvanceHole
                  ? 'After the last score is tapped, the hole saves and '
                    'jumps to the next hole automatically.'
                  : 'Stay on the current hole after the last score so you '
                    'can verify before pressing the next-hole button.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            value: settings.autoAdvanceHole,
            onChanged: (v) => settings.setAutoAdvanceHole(v),
          ),
          if (isAdmin) ...[
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.golf_course),
              title: const Text('Manage Courses'),
              subtitle: Text(
                'Edit tee priority, or rename and remove courses in your '
                'account. Adding a course happens during round setup.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pushNamed('/manage-courses'),
            ),
          ],
          const Divider(height: 32),
          ListTile(
            leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
            title: Text(
              'Delete Account',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: Text(
              'Permanently delete your login. Past scores are kept '
              'anonymously in other players\' round history.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => _confirmAndDelete(context),
          ),
        ],
      ),
    );
  }
}
