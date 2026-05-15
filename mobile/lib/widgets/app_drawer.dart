import 'package:flutter/material.dart';

import '../api/client.dart';
import '../config.dart';

/// Shared navigation drawer used by both Tournaments and Casual Rounds.
/// Each host screen passes the callbacks for the entries it wants active;
/// the entry for the screen the user is already on should pop the drawer
/// (since there's nothing to navigate to).
class AppDrawer extends StatelessWidget {
  final String? playerName;
  final VoidCallback onTournamentsTap;
  final VoidCallback onCasualRoundsTap;
  final VoidCallback onPlayersTap;
  final VoidCallback onLogout;

  const AppDrawer({
    super.key,
    required this.onTournamentsTap,
    required this.onCasualRoundsTap,
    required this.onPlayersTap,
    required this.onLogout,
    this.playerName,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(),
            margin: EdgeInsets.zero,
            padding: EdgeInsets.zero,
            child: Center(
              child: Image.asset(
                'assets/images/bandon_cup_logo.png',
                height: 148,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined),
            title: const Text('Tournaments'),
            onTap: onTournamentsTap,
          ),
          ListTile(
            leading: const Icon(Icons.sports_golf),
            title: const Text('Casual Rounds'),
            onTap: onCasualRoundsTap,
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Players'),
            onTap: onPlayersTap,
          ),
          const Spacer(),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              Navigator.of(context).pop();
              showAppAboutDialog(context);
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
    return AlertDialog(
      title: const Text('The Bandon Cup'),
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
