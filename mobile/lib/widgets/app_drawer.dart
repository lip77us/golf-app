import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
// Hide google_fonts' own `Config` — it collides with our app's Config.
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/client.dart';
import '../theme/halved_brand.dart';
import '../ui_labels.dart';
import '../config.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';

/// Shared navigation drawer used by both Tournaments and Casual Rounds.
/// Each host screen passes the callbacks for the entries it wants active;
/// the entry for the screen the user is already on should pop the drawer
/// (since there's nothing to navigate to).
class AppDrawer extends StatelessWidget {
  final String? playerName;
  final VoidCallback onTournamentsTap;
  final VoidCallback onCasualRoundsTap;
  final VoidCallback onPlayersTap;
  final VoidCallback onSettingsTap;
  final VoidCallback onLogout;

  const AppDrawer({
    super.key,
    required this.onTournamentsTap,
    required this.onCasualRoundsTap,
    required this.onPlayersTap,
    required this.onSettingsTap,
    required this.onLogout,
    this.playerName,
  });

  /// Whether to show the "Start your first round" onboarding entry. It ages off
  /// once the wizard has been completed on this device, OR 15 days after the
  /// account was opened (whichever first). A missing account-created date (older
  /// auth payload) falls back to the wizard-completed flag alone.
  bool _showFirstRoundEntry(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    if (settings.onboardingDone) return false;
    final createdAt = context.watch<AuthProvider>().account?.createdAt;
    if (createdAt != null &&
        DateTime.now().difference(createdAt).inDays >= 15) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // Plain Container instead of DrawerHeader — DrawerHeader
                // imposes a fixed height that's just short of the room
                // we need for the logo + signed-in-as block, which
                // produced an 18px overflow.  We pick our own padding
                // and draw the divider ourselves so the height grows
                // with the content.  Top padding adds MediaQuery's
                // safe-area inset so the logo doesn't ride into the
                // iPhone notch / Dynamic Island.
                Builder(builder: (ctx) {
                  final topInset = MediaQuery.of(ctx).padding.top;
                  return Container(
                    padding: EdgeInsets.fromLTRB(
                      16, topInset + 12, 16, 12,
                    ),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(
                        color: Halved.cardBorder,
                        width: 1,
                      )),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Brand mark + wordmark lockup.
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: SvgPicture.asset(
                                'assets/icon/halved_mark.svg',
                                width: 40,
                                height: 40,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Halved',
                              style: GoogleFonts.schibstedGrotesk(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Halved.deepPine,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // Who's logged in.  Player name plus the
                        // login username in parens — "Paul Lipkin
                        // (paul)" — so the user can tell which
                        // tenant/login this drawer is showing.
                        // Account name on a second line.
                        Builder(builder: (ctx) {
                          final auth     = ctx.watch<AuthProvider>();
                          final player   = auth.player?.name;
                          final username = auth.username;
                          final account  = auth.account?.name;
                          if (account == null) {
                            return const SizedBox.shrink();
                          }

                          final hasPlayer =
                              player != null && player.isNotEmpty;
                          final hasUser =
                              username != null && username.isNotEmpty;

                          // Show "Player (username)" when both exist;
                          // fall back to just the username when there's
                          // no linked player profile (admins, etc.).
                          final identityLine = hasPlayer
                              ? (hasUser ? '$player ($username)' : player)
                              : (hasUser ? username : null);

                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (identityLine != null)
                                Text(
                                  identityLine,
                                  style: Theme.of(ctx).textTheme.titleSmall
                                      ?.copyWith(
                                          fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              Text(
                                account,
                                style: Theme.of(ctx).textTheme.bodySmall
                                    ?.copyWith(
                                        color: Theme.of(ctx)
                                            .colorScheme.onSurfaceVariant),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                  );
                }),
                ListTile(
                  leading: const Icon(Icons.sports_golf),
                  title: const Text(kCasualRoundsLabel),
                  onTap: onCasualRoundsTap,
                ),
                ListTile(
                  leading: const Icon(Icons.emoji_events_outlined),
                  title: const Text('Tournaments'),
                  onTap: onTournamentsTap,
                ),
                // "Start your first round" is an onboarding nudge that ages off:
                // once the wizard has been completed on this device, or 15 days
                // after the account was opened (whichever comes first).
                if (_showFirstRoundEntry(context))
                  ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: const Text('Start your first round'),
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).pushNamed('/onboarding');
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.people_outline),
                  title: const Text('My Golfers'),
                  onTap: onPlayersTap,
                ),
                ListTile(
                  leading: const Icon(Icons.person_add_alt_1_outlined),
                  title: const Text('Invite Friends'),
                  onTap: () {
                    // Capture provider + messenger + share anchor BEFORE
                    // popping the drawer, so we don't touch a deactivated
                    // context after the await.
                    final auth      = context.read<AuthProvider>();
                    final messenger = ScaffoldMessenger.of(context);
                    final origin    = shareOriginFrom(context);
                    Navigator.of(context).pop();
                    shareInvite(auth, messenger, origin: origin);
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Profile'),
            onTap: onSettingsTap,
          ),
          // Course management is an admin utility (add/rename/remove courses,
          // tee priority) — kept out of the Profile page.
          if (context.watch<AuthProvider>().isAdmin)
            ListTile(
              leading: const Icon(Icons.golf_course),
              title: const Text('Manage Courses'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).pushNamed('/manage-courses');
              },
            ),
          ListTile(
            leading: const Icon(Icons.lightbulb_outline),
            title: const Text('Suggest a Game'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).pushNamed('/suggest-game');
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              Navigator.of(context).pop();
              showAppAboutDialog(context);
            },
          ),
          // Support staff only — read-only cross-account round lookup.
          if (context.watch<AuthProvider>().isSupport)
            ListTile(
              leading: const Icon(Icons.support_agent_outlined),
              title: const Text('Support: Open Round'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).pushNamed('/support-lookup');
              },
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign Out'),
            onTap: onLogout,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// The anchor rect from a tapped widget's render box, for the iOS share-sheet
/// popover (`sharePositionOrigin`). iOS *requires* a non-zero rect or it throws
/// "sharePositionOrigin: argument must be set". Compute this BEFORE popping the
/// drawer (while the widget is still laid out); null if unavailable.
Rect? shareOriginFrom(BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(Offset.zero) & box.size;
  }
  return null;
}

/// Fetches the caller's personal invite link and opens the native share sheet
/// so they can text it to friends from their own phone (TCPA / App Store safe).
/// Provider + messenger are passed in (captured before the drawer popped) to
/// avoid using a deactivated BuildContext across the await.  [origin] anchors
/// the iOS share popover (see [shareOriginFrom]).
Future<void> shareInvite(
  AuthProvider auth,
  ScaffoldMessengerState messenger, {
  Rect? origin,
  String? inviteeName,
}) async {
  try {
    final info = await auth.client.getInvite();
    final name = inviteeName?.trim() ?? '';
    final text = name.isEmpty
        ? info.shareText
        : '$name, join me on Halved — the easiest way to track our golf '
          'bets. ${info.url}';
    try {
      await Share.share(
        text,
        subject: 'Join me on Halved',
        // iOS needs a valid, non-zero anchor; fall back to a 1×1 rect if the
        // caller couldn't supply one (it's only the popover anchor on iPad —
        // iPhone shows a bottom sheet regardless).
        sharePositionOrigin: origin ?? const Rect.fromLTWH(0, 0, 1, 1),
      );
    } catch (e) {
      // The link was fetched fine; only the share sheet failed (e.g. the
      // native plugin isn't registered after a hot reload — cold-restart the
      // app). Surface the real error and the link so it's still usable.
      messenger.showSnackBar(
        SnackBar(content: Text('Share unavailable ($e). Link: ${info.url}')),
      );
    }
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not create your invite link: $e')),
    );
  }
}

/// Shows an About dialog that displays the local app version and fetches
/// the server version for comparison.
void showAppAboutDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => _AboutDialog(),
  );
}

class _AboutDialog extends StatefulWidget {
  @override
  State<_AboutDialog> createState() => _AboutDialogState();
}

class _AboutDialogState extends State<_AboutDialog> {
  String? _serverVersion;
  bool    _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchServerVersion();
  }

  Future<void> _fetchServerVersion() async {
    try {
      final data = await const ApiClient().getVersion();
      if (mounted) {
        setState(() {
          _serverVersion = data['server_version'] as String?;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return AlertDialog(
      title: const Text('Halved'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('App version: ',
                style: TextStyle(fontWeight: FontWeight.w500)),
            Text(Config.appVersion),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            const Text('Server version: ',
                style: TextStyle(fontWeight: FontWeight.w500)),
            if (_loading)
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(_serverVersion ?? '—'),
          ]),
          if (auth.account != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Text('Account: ',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              Flexible(child: Text(auth.account!.name,
                  overflow: TextOverflow.ellipsis)),
            ]),
          ],
          if (auth.player != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Text('Signed in as: ',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              Flexible(child: Text(auth.player!.name,
                  overflow: TextOverflow.ellipsis)),
            ]),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
