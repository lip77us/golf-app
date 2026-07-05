/// widgets/icon_help_sheet.dart
/// ----------------------------
/// A small bottom sheet that explains the action icons on a screen, plus the
/// content + helpers for the two screens that use it (score entry, leaderboard).
///
/// Used two ways:
///   • As an always-available "?" app-bar action (call `showScoreEntryHelp` /
///     `showLeaderboardHelp`).
///   • As a one-time onboarding nudge, auto-opened the first time a user lands
///     on the screen (call `maybeShowScoreEntryHelp` / `maybeShowLeaderboardHelp`
///     from a post-frame callback). The "seen" flag persists per device via
///     [SettingsProvider].

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';

/// One row in an icon-legend help sheet.
class IconHelpEntry {
  final IconData icon;
  final String title;
  final String body;
  const IconHelpEntry({
    required this.icon,
    required this.title,
    required this.body,
  });
}

/// Shows the icon-legend sheet. Returns when dismissed.
Future<void> showIconHelpSheet(
  BuildContext context, {
  required String title,
  required List<IconHelpEntry> entries,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              for (final e in entries) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Icon(e.icon,
                          size: 20,
                          color: theme.colorScheme.onPrimaryContainer),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.title,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(e.body,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Got it'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Opens [showIconHelpSheet] only the first time for [settingsKey], marking it
/// seen so it never auto-opens again. Safe to call from a post-frame callback.
Future<void> _maybeShowOnce(
  BuildContext context, {
  required String settingsKey,
  required String title,
  required List<IconHelpEntry> entries,
}) async {
  final settings = context.read<SettingsProvider>();
  if (settings.hasSeenHelp(settingsKey)) return;
  await settings.markHelpSeen(settingsKey);
  if (!context.mounted) return;
  await showIconHelpSheet(context, title: title, entries: entries);
}

// ── Per-screen content ──────────────────────────────────────────────────────

const String _kHelpScoreEntry = 'score_entry_icons';
const String _kHelpLeaderboard = 'leaderboard_icons';
const String _kHelpTitle = 'What do these buttons do?';

const List<IconHelpEntry> _scoreEntryHelp = [
  IconHelpEntry(
    icon: Icons.leaderboard_outlined,
    title: 'Leaderboard',
    body: "Live standings and who's up or down money so far.",
  ),
  IconHelpEntry(
    icon: Icons.screen_rotation_outlined,
    title: 'Full scorecard',
    body: "Rotate your phone to landscape to see the whole group's "
        '18-hole scorecard.',
  ),
];

const List<IconHelpEntry> _leaderboardHelp = [
  IconHelpEntry(
    icon: Icons.sms_outlined,
    title: 'Round chat',
    body: 'Message everyone in this round — all groups plus any watchers — and '
        'see live event updates (birdies, skins, lead changes). A red badge '
        'shows unread messages.',
  ),
  IconHelpEntry(
    icon: Icons.visibility_outlined,
    title: 'Invite a watcher',
    body: "Invite someone who isn't playing to follow this round in the app — "
        'read-only.',
  ),
  IconHelpEntry(
    icon: Icons.copy_outlined,
    title: 'Copy spectator link',
    body: 'Copy a public web link so anyone can watch the live scores in a '
        'browser — no app needed.',
  ),
];

Future<void> showScoreEntryHelp(BuildContext c) =>
    showIconHelpSheet(c, title: _kHelpTitle, entries: _scoreEntryHelp);

Future<void> maybeShowScoreEntryHelp(BuildContext c) => _maybeShowOnce(c,
    settingsKey: _kHelpScoreEntry, title: _kHelpTitle, entries: _scoreEntryHelp);

Future<void> showLeaderboardHelp(BuildContext c) =>
    showIconHelpSheet(c, title: _kHelpTitle, entries: _leaderboardHelp);

Future<void> maybeShowLeaderboardHelp(BuildContext c) => _maybeShowOnce(c,
    settingsKey: _kHelpLeaderboard,
    title: _kHelpTitle,
    entries: _leaderboardHelp);
