/// screens/player_list_screen.dart
/// Browseable, searchable player roster with add / edit actions.

import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/halved_brand.dart';
import '../utils/add_players.dart';
import '../utils/golfer_index.dart';
import '../widgets/golfer_avatar.dart';
import '../widgets/index_sheet.dart';
import '../widgets/new_golfer_sheet.dart';
import '../providers/auth_provider.dart';
import '../utils/golfer_invite.dart';
import '../widgets/error_view.dart';
import '../widgets/app_drawer.dart';
import 'player_form_screen.dart';

class PlayerListScreen extends StatefulWidget {
  const PlayerListScreen({super.key});

  @override
  State<PlayerListScreen> createState() => _PlayerListScreenState();
}

class _PlayerListScreenState extends State<PlayerListScreen> {
  List<PlayerProfile> _all     = [];
  bool    _loading = true;
  RosterLastImport? _lastImport;
  String? _error;
  bool    _networkError = false;
  String  _search = '';
  RoundCounts _counts = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getPlayers();
      if (mounted) setState(() { _all = data; });
      try {
        final c = await client.getRegulars();
        if (mounted) setState(() { _counts = c; });
      } catch (_) {/* no regulars yet */}
      // Best effort and deliberately AFTER the roster: this is a footnote
      // about where the list came from, and it must never be the reason the
      // list itself fails to draw.
      try {
        final imp = await client.getRosterLastImport();
        if (mounted) setState(() { _lastImport = imp; });
      } catch (_) {/* no line rather than an error */}
    } catch (e) {
      if (mounted) setState(() {
        _error = friendlyError(e);
        _networkError = isNetworkError(e);
      });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  /// Where this roster came from, and when.
  ///
  /// Shown HERE rather than behind a menu entry because this is the screen
  /// a handicap gets questioned on -- "that index is stale" is answered by
  /// the date the roster last came from Golf Genius.
  Widget _syncLine() {
    final imp = _lastImport;
    // Nothing at all until we know, and nothing ever for an account that has
    // never imported -- most have not, and a permanent "never synced" would
    // be a nag about a feature they do not use.
    if (imp == null || !imp.synced || imp.when == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(Icons.sync, size: 14,
               color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Synced from Golf Genius '
              '${DateFormat('MMM d').format(imp.when!)} · ${imp.changeSummary}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openForm({PlayerProfile? player}) async {
    // Non-admins get a read-only view; only admins can add/edit.  The
    // backend enforces this too, so this is just to avoid showing an
    // editable form that would fail to save with a 403.
    final isNew    = player == null;
    final readOnly = !context.read<AuthProvider>().isAdmin;

    // A NEW golfer goes through the New golfer sheet, the same one the Add
    // players screen opens, so the two cannot differ. Editing one still opens
    // the full form, which has the fields the sheet deliberately leaves out.
    if (isNew && !readOnly) {
      final result = await showNewGolferSheet(
        context,
        roster: _all,
        // Nowhere to seat him here, so the warning is only a warning.
        allowUseExisting: false,
      );
      if (result == null || !mounted) return;
      await _load();
      if (!mounted) return;
      final first = result.player.name.split(' ').first;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(addedToast(
                firstName: first,
                hasNumber: result.hasNumber,
                viaAccount: result.viaAccount,
                // There is no round here, so nothing is texted at Start
                // round — the golfer is only saved.
                inRound: false))));
      final fresh = _all.firstWhere((p) => p.id == result.player.id,
          orElse: () => result.player);
      await maybeOfferGolferSmsInvite(context, fresh);
      return;
    }

    final saved = await Navigator.of(context).push<PlayerProfile>(
      MaterialPageRoute(
        builder: (_) => PlayerFormScreen(player: player, readOnly: readOnly),
      ),
    );
    if (saved == null) return;
    // Reload so the roster (and the `is_on_app` flag) is fresh before we decide
    // whether to offer an invite — the create response doesn't compute it.
    await _load();
    // A newly-added golfer with a phone who isn't on Halved yet: offer to text
    // them a personalized invite (same one-tap flow as round setup).
    if (isNew && mounted) {
      final fresh = _all.firstWhere((p) => p.id == saved.id, orElse: () => saved);
      await maybeOfferGolferSmsInvite(context, fresh);
    }
  }

  Future<bool> _confirmDelete(PlayerProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove player?'),
        content: Text(
          'Remove ${p.name} from the player list?  Any rounds they\'ve '
          'already played stay intact, but new rounds won\'t include '
          'them.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _delete(PlayerProfile p) async {
    if (!await _confirmDelete(p)) return;
    try {
      await context.read<AuthProvider>().client.deletePlayer(p.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed ${p.name}.')),
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      // The API returns a friendly `detail` for the PROTECT case
      // ("X has played in rounds and can't be removed…") — show it.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyError(e)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _editIndex(PlayerProfile p) async {
    final auth = context.read<AuthProvider>();
    final me = auth.player;
    final r = await showIndexSheet(
      context,
      name: p.name,
      currentStored: p.handicapIndex,
      owner: p.isOnApp ? IndexOwner.halved : IndexOwner.guest,
      myIndex: me == null ? null : double.tryParse(me.handicapIndex),
      onEditDetails: () => _openForm(player: p),
    );
    if (r == null || !mounted) return;
    try {
      final updated =
          await auth.client.updatePlayer(p.id, handicapIndex: r.stored);
      if (!mounted) return;
      setState(() {
        _all = [for (final x in _all) x.id == updated.id ? updated : x];
      });
      final first = p.name.split(' ').first;
      final lbl = indexLabel(updated.handicapIndex);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(p.isOnApp
                ? '$first · index $lbl, kept until $first updates it'
                : '$first · index $lbl, saved')));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save that index.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        centerTitle: true,
        title: Text('My golfers',
            style: GoogleFonts.schibstedGrotesk(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Halved.deepPine)),
        actions: [
          Builder(
            builder: (btnContext) => IconButton(
              tooltip: 'Invite friends',
              icon: const Icon(Icons.person_add_alt_1_outlined),
              onPressed: () => shareInvite(
                btnContext.read<AuthProvider>(),
                ScaffoldMessenger.of(btnContext),
                origin: shareOriginFrom(btnContext),
              ),
            ),
          ),
        ],
      ),
      body: _buildList(isAdmin),
    );
  }

  Widget _buildList(bool isAdmin) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, isNetwork: _networkError, onRetry: _load);
    }
    final myId = context.watch<AuthProvider>().player?.id;
    final regulars = regularsOf(_all, _counts, meId: myId);
    final everyone = allGolfersOf(_all, _counts, meId: myId);
    final q = _search.trim();
    final shown =
        q.isEmpty ? everyone : searchYourGolfers(_all, q, meId: myId, counts: _counts);

    Widget label(String t, String trailing) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Row(children: [
            Expanded(
                child: Text(t.toUpperCase(),
                    style: Halved.body(
                        color: Halved.muted, weight: FontWeight.w800))),
            Text(trailing, style: Halved.body(color: Halved.muted)),
          ]),
        );

    Widget tile(PlayerProfile p) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _editIndex(p),
          child: Column(children: [
            const SizedBox(height: 2),
            GolferAvatar(
                name: p.name,
                onHalved: p.isOnApp,
                size: 44,
                index: p.handicapIndex,
                onIndexTap: () => _editIndex(p)),
            const SizedBox(height: 10),
            Text(p.name.split(' ').first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Halved.body(color: Halved.deepPine, weight: FontWeight.w600)
                    .copyWith(fontSize: 12)),
          ]),
        );

    final newTile = InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: isAdmin ? () => _openForm() : null,
      child: Column(children: [
        const SizedBox(height: 2),
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, color: Halved.deepPine),
          child: const Icon(Icons.add, color: Halved.brightMint),
        ),
        const SizedBox(height: 10),
        Text('New golfer',
            style: Halved.body(color: Halved.pine, weight: FontWeight.w700)
                .copyWith(fontSize: 12)),
      ]),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
      children: [
        _syncLine(),
        if (regulars.isNotEmpty || isAdmin) ...[
          label('Your regulars', 'tap a golfer to update the index'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE7EDE8))),
            child: GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 0.78,
              mainAxisSpacing: 8,
              children: [for (final p in regulars) tile(p), if (isAdmin) newTile],
            ),
          ),
        ],
        label('All your golfers', '${everyone.length} · most rounds first'),
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Halved.pine)),
          child: Row(children: [
            const Icon(Icons.search, color: Halved.muted),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Find one of your golfers'),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
                child: Text(q.isEmpty ? 'No golfers yet.' : 'No matches.',
                    style: Halved.body(color: Halved.muted))),
          )
        else
          Container(
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE7EDE8))),
            child: Column(children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: Color(0xFFE7EDE8)),
                InkWell(
                  onTap: () => _editIndex(shown[i]),
                  onLongPress: isAdmin ? () => _delete(shown[i]) : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                    child: Row(children: [
                      GolferAvatar(
                          name: shown[i].name,
                          onHalved: shown[i].isOnApp,
                          size: 36,
                          index: shown[i].handicapIndex,
                          onIndexTap: () => _editIndex(shown[i])),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(shown[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Halved.body(
                                          color: Halved.deepPine,
                                          weight: FontWeight.w700)
                                      .copyWith(fontSize: 16)),
                              Text(
                                  '${shown[i].isOnApp ? 'On Halved' : 'Not on Halved'}'
                                  ' · ${playedLabel(_counts[shown[i].id]?.rounds ?? 0)}',
                                  style: Halved.body(color: Halved.muted)),
                            ]),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Halved.pine)),
                        child: Text('Index',
                            style: Halved.body(
                                color: Halved.pine, weight: FontWeight.w700)),
                      ),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
      ],
    );
  }
}
