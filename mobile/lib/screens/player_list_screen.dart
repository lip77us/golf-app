/// screens/player_list_screen.dart
/// Browseable, searchable player roster with add / edit actions.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
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
  String? _error;
  bool    _networkError = false;
  String  _search = '';

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
    } catch (e) {
      if (mounted) setState(() {
        _error = friendlyError(e);
        _networkError = isNetworkError(e);
      });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  List<PlayerProfile> get _filtered {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((p) =>
      p.name.toLowerCase().contains(q) ||
      p.email.toLowerCase().contains(q)
    ).toList();
  }

  Future<void> _openForm({PlayerProfile? player}) async {
    // Non-admins get a read-only view; only admins can add/edit.  The
    // backend enforces this too, so this is just to avoid showing an
    // editable form that would fail to save with a 403.
    final readOnly = !context.read<AuthProvider>().isAdmin;
    final saved = await Navigator.of(context).push<PlayerProfile>(
      MaterialPageRoute(
        builder: (_) => PlayerFormScreen(player: player, readOnly: readOnly),
      ),
    );
    if (saved != null) _load();
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

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Golfers'),
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
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      // Only admins can add players; non-admins get a read-only roster.
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.person_add),
              label: const Text('Add Player'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SearchBar(
              hintText: 'Search players…',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, isNetwork: _networkError, onRetry: _load);
    }

    final isAdmin = context.watch<AuthProvider>().isAdmin;

    final players = _filtered;
    if (players.isEmpty) {
      return Center(
        child: Text(
          _search.isEmpty
              ? (isAdmin ? 'No players yet. Tap + Add Player.' : 'No players yet.')
              : 'No matches.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: players.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (_, i) {
        final p = players[i];
        final tile = ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            [
              'Hcp ${p.handicapIndex}',
              if (p.email.isNotEmpty) p.email,
            ].join('  ·  '),
            style: const TextStyle(fontSize: 13),
          ),
          // Admins get an explicit delete icon as well as swipe-to-
          // dismiss — discoverability beats hiding deletion behind
          // a swipe gesture.
          trailing: isAdmin
              ? IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error),
                  tooltip: 'Remove player',
                  onPressed: () => _delete(p),
                )
              : const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () => _openForm(player: p),
        );

        if (!isAdmin) return tile;
        // Swipe-to-delete for admins.  The confirmDismiss callback
        // wraps the existing confirm + API call so a successful
        // dismiss reuses the same code path as the trash button.
        return Dismissible(
          key: ValueKey('player-${p.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.error,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) async {
            if (!await _confirmDelete(p)) return false;
            try {
              await context.read<AuthProvider>().client.deletePlayer(p.id);
              if (!mounted) return false;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Removed ${p.name}.')),
              );
              return true;
            } on ApiException catch (e) {
              if (!mounted) return false;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(e.message),
                backgroundColor: Theme.of(context).colorScheme.error,
                duration: const Duration(seconds: 5),
              ));
              return false;
            } catch (e) {
              if (!mounted) return false;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(friendlyError(e)),
                backgroundColor: Theme.of(context).colorScheme.error,
              ));
              return false;
            }
          },
          onDismissed: (_) {
            // Local list update so the row animates out smoothly;
            // the next _load() (already triggered nowhere here, but
            // future actions will refresh) catches up the canonical
            // state from the server.
            setState(() => _all.removeWhere((x) => x.id == p.id));
          },
          child: tile,
        );
      },
    );
  }
}
