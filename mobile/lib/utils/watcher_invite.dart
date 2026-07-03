/// utils/watcher_invite.dart
/// "Invite a watcher" flow — invite a non-playing spectator to follow a round
/// or tournament in-app (read-only). Pick from My Golfers or enter a phone;
/// the person is recorded as a watcher (and added to your roster), then the
/// app-download link is shared so they can install and follow.

import 'package:flutter/material.dart';
import 'package:flutter_sms/flutter_sms.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../screens/player_form_screen.dart';
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

  /// Record the watcher, then open Messages pre-filled with a watch invite —
  /// the SAME halved.golf link for everyone (it opens the app for a Halved
  /// user, or the read-only web page otherwise), with a download link added
  /// only when the recipient isn't on Halved yet.  The user just taps Send and
  /// is returned to the app.
  Future<void> _invite({int? playerId, String? phone, String? name}) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final inviter =
        context.read<AuthProvider>().player?.name.trim() ?? '';
    final who = (name?.trim().isNotEmpty == true) ? name!.trim() : 'They';
    setState(() => _busy = true);
    try {
      final res      = await _post(playerId: playerId, phone: phone, name: name);
      final onApp    = res['is_on_app'] == true;
      final watchUrl = res['watch_url'] as String?;
      final dlUrl    = res['download_url'] as String?;
      final toPhone  = (res['phone'] as String?) ?? phone ?? '';
      navigator.pop(); // close the sheet

      final body = _watchInviteBody(
        inviter: inviter, onApp: onApp, watchUrl: watchUrl, downloadUrl: dlUrl);
      final sent = toPhone.isNotEmpty
          ? await _launchWatchSms(phone: toPhone, body: body)
          : false;
      if (!sent) {
        // Couldn't open Messages (simulator / no SMS) — surface the link so the
        // invite isn't lost. The watcher is already recorded server-side.
        messenger.showSnackBar(SnackBar(content: Text(
          watchUrl != null
              ? '$who added. Watch link: $watchUrl'
              : '$who was added as a watcher.')));
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

  /// Body of the watch-invite text.  One halved.golf link for everyone; a
  /// download link is appended only for a non-Halved recipient.
  String _watchInviteBody({
    required String inviter,
    required bool   onApp,
    String?         watchUrl,
    String?         downloadUrl,
  }) {
    final by = inviter.isNotEmpty ? inviter : 'A friend';
    final b  = StringBuffer(
        '$by invited you to observe an active Halved round.');
    if (watchUrl != null) {
      b.write(onApp ? ' Follow it live: $watchUrl' : ' Watch live: $watchUrl');
    }
    if (!onApp && downloadUrl != null) {
      b.write('  Get the Halved app: $downloadUrl');
    }
    return b.toString();
  }

  /// Open the native message composer pre-addressed to [phone] with [body].
  /// Returns false if the device can't send SMS or the composer failed.
  Future<bool> _launchWatchSms(
      {required String phone, required String body}) async {
    final cleaned = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    try {
      if (!await canSendSMS()) return false;
      await sendSMS(message: body, recipients: [cleaned]);
      return true;
    } catch (_) {
      return false;
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
                    'Pick who to invite — we’ll open a text with a link to '
                    'follow this round live (read-only). Just tap Send.',
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
