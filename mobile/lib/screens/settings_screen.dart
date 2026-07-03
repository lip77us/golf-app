/// screens/settings_screen.dart
///
/// The "Profile" page reachable from the app drawer.  Shows the signed-in
/// golfer's data (name / handicap / home course) up top, then per-device
/// preferences (score-entry toggles), course management, and account deletion.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/course_search_field.dart';
import '../widgets/halved_mark.dart';
import 'player_form_screen.dart';

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

  /// Edit the signed-in golfer's own profile (name / handicap / phone / sex)
  /// via the shared player form, then reflect the saved copy in the session.
  Future<void> _editProfile(BuildContext context) async {
    final auth = context.read<AuthProvider>();
    final me   = auth.player;
    if (me == null) return;
    final updated = await Navigator.of(context).push<PlayerProfile>(
      MaterialPageRoute(builder: (_) => PlayerFormScreen(player: me)),
    );
    if (updated != null) auth.applyPlayer(updated);
  }

  /// Choose (or clear) the golfer's home course.  Reuses the one-box course
  /// search so any account/catalog/API course can be set — the same picker
  /// used during round setup.
  Future<void> _pickHomeCourse(BuildContext context) async {
    final auth      = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final me        = auth.player;
    if (me == null) return;

    Future<void> apply({int? courseId, bool clear = false, String? label}) async {
      try {
        final updated = await auth.client.updatePlayer(
          me.id, homeCourseId: courseId, clearHomeCourse: clear);
        auth.applyPlayer(updated);
        messenger.showSnackBar(SnackBar(
          content: Text(clear
              ? 'Home course cleared'
              : 'Home course set to ${label ?? 'course'}')));
      } catch (_) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Could not update home course.')));
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        final t = Theme.of(sheetCtx);
        return Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 4,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Home course', style: t.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Your usual course. It’s pinned to the top of the course list '
                'when you start a round.',
                style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              CourseSearchField(
                selected: null,
                onSelected: (c) {
                  Navigator.of(sheetCtx).pop();
                  apply(courseId: c.id, label: c.name);
                },
              ),
              if (me.homeCourseId != null) ...[
                const SizedBox(height: 4),
                TextButton.icon(
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear home course'),
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    apply(clear: true);
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _golferHeader(BuildContext context, PlayerProfile p) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: CircleAvatar(
            radius: 24,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              p.displayShort,
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer),
            ),
          ),
          title: Row(children: [
            Flexible(
                child: Text(p.name,
                    style: theme.textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis)),
            if (p.isOnApp) ...[
              const SizedBox(width: 8),
              const HalvedMark(size: 18),
            ],
          ]),
          subtitle: Text(
            'Handicap index ${p.displayHandicap}'
            '${p.phone.trim().isNotEmpty ? '  ·  ${p.phone}' : ''}',
          ),
          trailing: TextButton.icon(
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit'),
            onPressed: () => _editProfile(context),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: const Text('Home course'),
          subtitle: Text(
            p.homeCourseName.isNotEmpty
                ? p.homeCourseName
                : 'Not set — pinned to the top of your course list',
            style: p.homeCourseName.isEmpty
                ? theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickHomeCourse(context),
        ),
        const Divider(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final auth     = context.watch<AuthProvider>();
    final isAdmin  = auth.isAdmin;
    final me       = auth.player;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
        children: [
          if (me != null) _golferHeader(context, me),
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
        ],
            ),
          ),
          // Pinned to the bottom of the screen, away from the everyday
          // preferences above so it's hard to hit by accident.
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: ListTile(
              leading:
                  Icon(Icons.delete_forever, color: theme.colorScheme.error),
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
          ),
        ],
      ),
    );
  }
}
