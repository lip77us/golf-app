/// screens/player_list_screen.dart
/// Browseable, searchable player roster with add / edit actions.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
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
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PlayerFormScreen(player: player),
      ),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Players'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.person_add),
        label: const Text('Add Player'),
      ),
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

    final players = _filtered;
    if (players.isEmpty) {
      return Center(
        child: Text(
          _search.isEmpty ? 'No players yet. Tap + Add Player.' : 'No matches.',
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
        return ListTile(
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
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () => _openForm(player: p),
        );
      },
    );
  }
}
