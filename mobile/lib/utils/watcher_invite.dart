/// utils/watcher_invite.dart
/// "Invite a watcher" flow — invite a non-playing spectator to follow a round
/// or tournament in-app (read-only). Pick from My Golfers or enter a phone;
/// the person is recorded as a watcher (and added to your roster), then the
/// app-download link is shared so they can install and follow.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../screens/player_form_screen.dart';
import '../widgets/app_drawer.dart'; // shareInvite, shareOriginFrom
import '../widgets/halved_mark.dart';

/// Open the invite-a-watcher sheet for a round OR a tournament (exactly one id).
Future<void> inviteWatcher(BuildContext context,
    {int? roundId, int? tournamentId}) async {
  assert((roundId == null) != (tournamentId == null),
      'Pass exactly one of roundId / tournamentId');
  final auth = context.read<AuthProvider>();
  List<PlayerProfile> golfers = const [];
  try {
    // Candidates exclude anyone already playing in this round/tournament.
    golfers = roundId != null
        ? await auth.client.getRoundWatcherCandidates(roundId)
        : await auth.client.getTournamentWatcherCandidates(tournamentId!);
  } catch (_) {/* sheet still works for by-phone invites */}
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _WatcherInviteSheet(
      golfers: golfers, roundId: roundId, tournamentId: tournamentId),
  );
}

class _WatcherInviteSheet extends StatefulWidget {
  final List<PlayerProfile> golfers;
  final int? roundId;
  final int? tournamentId;

  const _WatcherInviteSheet({
    required this.golfers,
    required this.roundId,
    required this.tournamentId,
  });

  @override
  State<_WatcherInviteSheet> createState() => _WatcherInviteSheetState();
}

class _WatcherInviteSheetState extends State<_WatcherInviteSheet> {
  bool _busy = false;

  Future<Map<String, dynamic>> _post(
      {int? playerId, String? phone, String? name}) async {
    final c = context.read<AuthProvider>().client;
    if (widget.roundId != null) {
      return c.addRoundWatcher(widget.roundId!,
          playerId: playerId, phone: phone, name: name);
    }
    return c.addTournamentWatcher(widget.tournamentId!,
        playerId: playerId, phone: phone, name: name);
  }

  /// Record the watcher. If they're already on Halved, the server notifies them
  /// in-app (push) — no download pitch; otherwise share the app link so they
  /// can install and follow.
  Future<void> _invite({int? playerId, String? phone, String? name}) async {
    final auth      = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final origin    = shareOriginFrom(context);
    final navigator = Navigator.of(context);
    final who = (name?.trim().isNotEmpty == true) ? name! : 'Your watcher';
    setState(() => _busy = true);
    try {
      final res   = await _post(playerId: playerId, phone: phone, name: name);
      final onApp = res['is_on_app'] == true;
      navigator.pop(); // close the sheet
      if (onApp) {
        messenger.showSnackBar(SnackBar(
          content: Text("$who is on Halved — they'll be notified in the app."),
        ));
      } else {
        await shareInvite(auth, messenger, origin: origin, inviteeName: name);
        messenger.showSnackBar(SnackBar(
          content: Text('$who can now follow along — invite link shared.'),
        ));
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not invite watcher.')));
    }
  }

  Future<void> _tapGolfer(PlayerProfile p) async {
    if (p.phone.trim().isNotEmpty) {
      _invite(playerId: p.id, name: p.name);
      return;
    }
    // No phone → a watcher can't be matched. Offer to add one.
    final navigator = Navigator.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('Add ${p.name}’s number'),
        content: Text(
          'A watcher is matched by phone number. Add ${p.name}’s number so '
          'they connect when they open Halved.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dctx).pop('add'),
              child: const Text('Add number')),
        ],
      ),
    );
    if (choice != 'add') return;
    final updated = await navigator.push<PlayerProfile>(
      MaterialPageRoute(builder: (_) => PlayerFormScreen(player: p)),
    );
    if (updated != null && updated.phone.trim().isNotEmpty) {
      _invite(playerId: updated.id, name: updated.name);
    }
  }

  Future<void> _byPhone() async {
    final nameCtrl  = TextEditingController();
    final phoneCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Invite by phone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Invite')),
        ],
      ),
    );
    if (ok != true) return;
    final phone = phoneCtrl.text.trim();
    final name  = nameCtrl.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a name and phone number.')));
      }
      return;
    }
    _invite(phone: phone, name: name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Invite a watcher', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'They’ll follow the live leaderboard in the app '
                    '(read-only). We’ll share a link so they can install it.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            ListTile(
              leading: const Icon(Icons.dialpad),
              title: const Text('Invite by phone number'),
              onTap: _busy ? null : _byPhone,
            ),
            const Divider(height: 1),
            Flexible(
              child: widget.golfers.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No golfers in your list yet.',
                          textAlign: TextAlign.center),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.golfers.length,
                      itemBuilder: (_, i) {
                        final p = widget.golfers[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            child: Text(p.name.isNotEmpty
                                ? p.name[0].toUpperCase() : '?'),
                          ),
                          title: Row(children: [
                            Flexible(
                                child: Text(p.name,
                                    overflow: TextOverflow.ellipsis)),
                            if (p.isOnApp) ...[
                              const SizedBox(width: 8),
                              const HalvedMark(size: 18),
                            ],
                          ]),
                          subtitle: p.phone.trim().isEmpty
                              ? const Text('No phone yet')
                              : null,
                          onTap: _busy ? null : () => _tapGolfer(p),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
