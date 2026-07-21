/// screens/settings_screen.dart
///
/// The "Profile" page reachable from the app drawer.  Sections:
///   1. Your info   — edit name / short name / handicap index inline.
///   2. Home course — set/clear the course pinned atop the course picker.
///   3. Preferences — per-device score-entry toggles.
///   4. Delete Account (pinned to the bottom).
/// (Course management moved out to the drawer as a utility.)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/course_search_field.dart';
import '../widgets/halved_mark.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _nameCtrl  = TextEditingController();
  final _shortCtrl = TextEditingController();
  final _indexCtrl = TextEditingController();
  bool _saving = false;

  /// "Findable by name" — server-side, unlike the local preferences below it,
  /// so it is fetched rather than read from SettingsProvider. Null while
  /// loading, which keeps the switch from flashing the wrong state first.
  bool? _discoverable;

  @override
  void initState() {
    super.initState();
    final me = context.read<AuthProvider>().player;
    if (me != null) _syncControllers(me);
    _loadDiscoverable();
  }

  Future<void> _loadDiscoverable() async {
    try {
      final me = await context.read<AuthProvider>().client.me();
      if (!mounted) return;
      setState(() => _discoverable = me.discoverableByName);
    } catch (_) {
      // Leave it null; the row renders disabled rather than claiming a state
      // we could not confirm. A privacy switch showing the wrong value is
      // worse than one that admits it does not know.
    }
  }

  Future<void> _setDiscoverable(bool value) async {
    final previous = _discoverable;
    setState(() => _discoverable = value); // optimistic — the switch must move
    try {
      final saved =
          await context.read<AuthProvider>().client.setDiscoverableByName(value);
      if (!mounted) return;
      setState(() => _discoverable = saved);
    } catch (_) {
      if (!mounted) return;
      // Snap back: a privacy control that silently fails to save is the one
      // place a stale UI genuinely matters.
      setState(() => _discoverable = previous);
      _snack('Could not save that. Check your connection and try again.');
    }
  }

  void _syncControllers(PlayerProfile p) {
    _nameCtrl.text  = p.name;
    _shortCtrl.text = p.shortName;
    _indexCtrl.text = p.handicapIndex;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _shortCtrl.dispose();
    _indexCtrl.dispose();
    super.dispose();
  }

  bool _dirty(PlayerProfile me) =>
      _nameCtrl.text.trim() != me.name ||
      _shortCtrl.text.trim() != me.shortName ||
      _indexCtrl.text.trim() != me.handicapIndex;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _saveInfo() async {
    final auth = context.read<AuthProvider>();
    final me   = auth.player;
    if (me == null) return;

    final name  = _nameCtrl.text.trim();
    final short = _shortCtrl.text.trim();
    final index = _indexCtrl.text.trim();
    if (name.isEmpty) { _snack('Name can’t be empty.'); return; }
    final idx = double.tryParse(index);
    if (idx == null || idx < -10 || idx > 54) {
      _snack('Enter a valid handicap index (-10 to 54).');
      return;
    }

    setState(() => _saving = true);
    try {
      final updated = await auth.client.updatePlayer(
        me.id,
        name:          name  != me.name          ? name  : null,
        shortName:     short != me.shortName      ? short : null,
        handicapIndex: index != me.handicapIndex  ? index : null,
      );
      auth.applyPlayer(updated);
      _syncControllers(updated); // reflect any server normalization
      _snack('Profile saved.');
    } on ApiException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Could not save profile.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Choose (or clear) the golfer's home course via the shared one-box search.
  Future<void> _pickHomeCourse() async {
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

  /// Confirm and run permanent account deletion.  On success the auth gate
  /// in main.dart redirects to the login screen; on failure (e.g. the
  /// last-admin guard) the user stays logged in and sees the reason.
  Future<void> _confirmAndDelete() async {
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

  Widget _sectionHeader(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _infoSection(PlayerProfile me) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  me.displayShort,
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      if (me.isOnApp) ...[
                        const HalvedMark(size: 18),
                        const SizedBox(width: 6),
                        Text('On Halved',
                            style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ] else
                        Text('Your golfer profile',
                            style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                    ]),
                    if (me.phone.trim().isNotEmpty)
                      Text(me.phone,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _shortCtrl,
                  maxLength: 5,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Short name',
                    helperText: 'Compact scoreboards',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _indexCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Handicap index',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: (_saving || !_dirty(me)) ? null : _saveInfo,
              child: _saving
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final me       = context.watch<AuthProvider>().player;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                if (me != null) ...[
                  _sectionHeader('Your info'),
                  _infoSection(me),
                  _sectionHeader('Home course'),
                  ListTile(
                    leading: const Icon(Icons.flag_outlined),
                    title: Text(
                      me.homeCourseName.isNotEmpty
                          ? me.homeCourseName
                          : 'Not set',
                    ),
                    subtitle: Text(
                      me.homeCourseName.isNotEmpty
                          ? 'Pinned to the top of your course list'
                          : 'Pick your usual course to pin it atop the list',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickHomeCourse,
                  ),
                ],
                _sectionHeader('Privacy'),
                SwitchListTile(
                  title: const Text('Findable by name'),
                  subtitle: Text(
                    _discoverable == null
                        ? 'Checking…'
                        : _discoverable!
                            ? 'Other Halved golfers can find you by name when '
                              'they add players to a round. They see your name, '
                              'handicap and home-course city — never your phone '
                              'number.'
                            : 'You won’t appear in name searches. Someone who '
                              'already has your phone number can still add you '
                              'with it.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: _discoverable ?? true,
                  // Disabled until we know the real value — better than
                  // letting a tap act on a guess.
                  onChanged:
                      _discoverable == null ? null : (v) => _setDiscoverable(v),
                ),
                _sectionHeader('Preferences'),
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
              onTap: _confirmAndDelete,
            ),
          ),
        ],
      ),
    );
  }
}
