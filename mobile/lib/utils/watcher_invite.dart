/// utils/watcher_invite.dart
/// "Invite a watcher" flow — invite a non-playing spectator to follow a round
/// or tournament in-app (read-only). Pick from My Golfers or enter a phone;
/// the person is recorded as a watcher (and added to your roster), then ONE
/// watch link is texted to them — it opens the round in Halved for a Halved
/// user and the read-only web watch page for anyone else.

import 'package:flutter/material.dart';
import 'package:halved_sms/halved_sms.dart';
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

  final TextEditingController _searchCtrl = TextEditingController();
  String _search    = '';
  /// Show only golfers who have signed up. A watcher who is on Halved opens
  /// the link in the app and follows live; anyone else lands on the read-only
  /// web page — so "who already has it" is a real distinction when you are
  /// deciding who to rail you, not just a badge.
  bool   _onAppOnly = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Roster search, matching My Golfers: name or phone, case-insensitive.
  ///
  /// Without this the sheet listed every eligible golfer in the account and
  /// nothing else. An account that imported a Golf Genius roster has a couple
  /// of hundred, so picking one meant scrolling past everybody.
  List<PlayerProfile> get _filtered {
    final q = _search.trim().toLowerCase();
    return widget.golfers.where((p) {
      if (_onAppOnly && !p.isOnApp) return false;
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q)
          || p.phone.toLowerCase().contains(q);
    }).toList();
  }

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
  /// the SAME halved.golf link for everyone, because the recipient decides
  /// what it is: a Halved user has the app associated with the domain, so it
  /// opens the round in-app; anyone else lands on the read-only web watch
  /// page.  The user just taps Send and is returned to the app.
  Future<void> _invite(
      {int? playerId, String? phone, String? name, PlayerProfile? player}) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final who = (name?.trim().isNotEmpty == true) ? name!.trim() : 'They';
    setState(() => _busy = true);
    try {
      final res        = await _post(playerId: playerId, phone: phone, name: name);
      final onApp      = res['is_on_app'] == true;
      final watchUrl   = res['watch_url'] as String?;
      final dlUrl      = res['download_url'] as String?;
      var   toPhone    = (res['phone'] as String?) ?? phone ?? '';
      final rosterName = (res['roster_name'] as String?)?.trim();
      final rosterNew  = res['roster_created'] == true;
      navigator.pop(); // close the sheet

      final body = _watchInviteBody(watchUrl: watchUrl, downloadUrl: dlUrl);

      // They ARE a watcher at this point — the server matched them. An empty
      // phone here means we found them by name and never learned their number,
      // so the text is the only part we can't do. Say so and offer to collect
      // one rather than dropping the text silently.
      if (toPhone.isEmpty && player != null && mounted) {
        toPhone = await _askForNumber(player, onApp: onApp) ?? '';
      }

      final sent = (toPhone.isNotEmpty && body.isNotEmpty)
          ? await _launchWatchSms(phone: toPhone, body: body)
          : false;

      // Always confirm what happened to My Golfers — including a phone match
      // against an existing golfer saved under a DIFFERENT name (we don't
      // rename it), which would otherwise be invisible and confusing.
      final typed = name?.trim() ?? '';
      String roster;
      if (rosterName == null || rosterName.isEmpty) {
        roster = '$who added to My Golfers';
      } else if (rosterNew) {
        roster = '$rosterName added to My Golfers';
      } else if (typed.isNotEmpty &&
                 rosterName.toLowerCase() != typed.toLowerCase()) {
        roster = 'Already in My Golfers as “$rosterName”';
      } else {
        roster = '$rosterName is in My Golfers';
      }
      final tail = sent
          ? ' · text opened'
          : (watchUrl != null ? ' · link: $watchUrl' : '');
      messenger.showSnackBar(SnackBar(content: Text('$roster$tail')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not invite watcher.')));
    }
  }

  /// We added them as a watcher but hold no number we're allowed to show, so
  /// we can't open a pre-addressed text.  Explain that, and let the inviter
  /// supply a number or skip the text.  Returns the number to text, or null to
  /// send nothing — either way the watcher stands.
  ///
  /// A number entered here is saved to the golfer, which also makes it the
  /// visible one from then on (the owner clearly knows it now).
  Future<String?> _askForNumber(PlayerProfile p, {required bool onApp}) async {
    final ctrl = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('No number for ${p.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              onApp
                  ? '${p.name} is watching the round and will see it in '
                    'Halved. You found them by name, so we don’t have a '
                    'number to text them at.'
                  : '${p.name} is watching the round, but we don’t have a '
                    'number to text them at.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Their number (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('Skip the text')),
          FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Text them')),
        ],
      ),
    );
    final typed = ctrl.text.trim();
    if (send != true || typed.isEmpty || !mounted) return null;
    // Persist it so the next invite doesn't have to ask again.
    try {
      await context.read<AuthProvider>().client.updatePlayer(p.id, phone: typed);
    } catch (_) {
      // Saving is a convenience — still let them send this one.
    }
    return typed;
  }

  /// Body of the watch-invite text: JUST the link.
  ///
  /// This lands with people who have often never heard of Halved, which makes
  /// it one of the few places the app talks to a stranger. It goes into an
  /// editable composer, so it is a first draft the sender can rewrite — which
  /// is also why it states nothing we haven't checked.
  ///
  /// No sentence above the link. The preview card the link unfurls into
  /// already names the sender, the game and the course and renders a Watch
  /// live button, so a line like "Come rail me — I'm playing Survivor at Metro
  /// GL" is the same information twice, in smaller type, next to the picture
  /// that says it better.
  ///
  /// One link for everyone, and the RECIPIENT decides what it opens: a Halved
  /// user has the app associated with the domain, so it opens the round in
  /// Halved; anyone else lands on the read-only web watch page. That page
  /// carries its own "Get the app" CTA, which is why we no longer append a
  /// download URL for someone who isn't on Halved — a second link in a
  /// two-line text only competes with the one that matters.
  ///
  /// [downloadUrl] survives as a fallback for the case where the server sent
  /// no watch link at all (a tournament with no rounds yet); with neither, the
  /// body is empty and the caller skips the text rather than sending nothing.
  String _watchInviteBody({String? watchUrl, String? downloadUrl}) =>
      watchUrl ?? downloadUrl ?? '';

  /// Open the native message composer pre-addressed to [phone] with [body].
  /// Returns false if the device can't send SMS or the composer failed.
  Future<bool> _launchWatchSms(
      {required String phone, required String body}) async {
    final cleaned = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (!await canSendSms()) return false;
    return sendSms(message: body, recipients: [cleaned]);
  }

  Future<void> _tapGolfer(PlayerProfile p) async {
    // A golfer on Halved can always be matched server-side — either we hold
    // their number, or they came from a name search and the server holds it
    // for us. Either way the invite goes through; whether we can also TEXT
    // them is decided afterwards, from the phone the response echoes back.
    if (p.phone.trim().isNotEmpty || p.isOnApp) {
      _invite(playerId: p.id, name: p.name, player: p);
      return;
    }
    // Genuinely no number anywhere → a watcher can't be matched at all.
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
      _invite(playerId: updated.id, name: updated.name, player: updated);
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
                    'Pick who to invite — we’ll open a text with the watch '
                    'link. A Halved golfer opens it in the app; anyone else '
                    'watches on the web. Read-only either way — just tap Send.',
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

            // Search + the on-Halved filter. Only worth drawing when there is
            // a list long enough to get lost in — on a four-golfer roster the
            // controls would take more room than the thing they filter.
            if (widget.golfers.length > 5)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _search = v),
                      textInputAction: TextInputAction.search,
                      // The keyboard covers the list it is filtering, and
                      // results are already live as you type, so the search
                      // key just means "done typing".
                      onSubmitted: (_) => FocusScope.of(context).unfocus(),
                      decoration: InputDecoration(
                        hintText: 'name or phone',
                        prefixIcon: const Icon(Icons.search),
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                tooltip: 'Clear',
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _search = '');
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      FilterChip(
                        selected: _onAppOnly,
                        onSelected: (v) => setState(() => _onAppOnly = v),
                        avatar: const HalvedMark(size: 16),
                        label: const Text('On Halved'),
                      ),
                      const Spacer(),
                      Text(
                        '${_filtered.length} of ${widget.golfers.length}',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ]),
                  ],
                ),
              ),

            Flexible(
              child: widget.golfers.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No golfers in your list yet.',
                          textAlign: TextAlign.center),
                    )
                  : _filtered.isEmpty
                  // Distinct from an empty roster, and it says which filter is
                  // hiding them — "nobody" and "nobody matching" send you
                  // looking in different places.
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _onAppOnly
                            ? 'No golfers on Halved match that. Invite by phone '
                              'number, or turn off the On Halved filter.'
                            : 'No golfers match that. Invite by phone number '
                              'instead.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemBuilder: (_, i) {
                        final p = _filtered[i];
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
