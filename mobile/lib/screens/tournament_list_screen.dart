import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import 'new_round_wizard.dart';
import 'player_list_screen.dart';

class TournamentListScreen extends StatefulWidget {
  const TournamentListScreen({super.key});

  @override
  State<TournamentListScreen> createState() => _TournamentListScreenState();
}

class _TournamentListScreenState extends State<TournamentListScreen> {
  List<Tournament>? _tournaments;
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getTournaments();
      if (mounted) setState(() { _tournaments = data; });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _networkError = isNetworkError(e); });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tournaments'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      drawer: _AppDrawer(
        playerName: auth.player?.name,
        onPlayersTap: () {
          Navigator.of(context)
            ..pop() // close drawer
            ..push(MaterialPageRoute(builder: (_) => const PlayerListScreen()));
        },
        onLogout: () => auth.logout(),
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const NewRoundWizard()),
          );
          _load(); // refresh list when wizard returns
        },
        icon: const Icon(Icons.add),
        label: const Text('New Round'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(
        message: _error!,
        isNetwork: _networkError,
        onRetry: _load,
      );
    }
    final tournaments = _tournaments ?? [];
    if (tournaments.isEmpty) {
      return const Center(child: Text('No tournaments found.'));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: tournaments.length,
        itemBuilder: (_, i) => _TournamentCard(
          tournament: tournaments[i],
          onRoundTap: (roundId) =>
              Navigator.of(context).pushNamed('/round', arguments: roundId),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// App Drawer
// ---------------------------------------------------------------------------

class _AppDrawer extends StatelessWidget {
  final String? playerName;
  final VoidCallback onPlayersTap;
  final VoidCallback onLogout;

  const _AppDrawer({
    required this.onPlayersTap,
    required this.onLogout,
    this.playerName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: theme.colorScheme.primary),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(Icons.golf_course,
                    size: 40, color: theme.colorScheme.onPrimary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Golf App',
                          style: theme.textTheme.titleLarge?.copyWith(
                              color: theme.colorScheme.onPrimary,
                              fontWeight: FontWeight.bold)),
                      if (playerName != null)
                        Text(playerName!,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onPrimary
                                    .withOpacity(0.85))),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined),
            title: const Text('Tournaments'),
            onTap: () => Navigator.of(context).pop(),
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Players'),
            onTap: onPlayersTap,
          ),
          const Spacer(),
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

class _TournamentCard extends StatelessWidget {
  final Tournament tournament;
  final void Function(int roundId) onRoundTap;

  const _TournamentCard({
    required this.tournament,
    required this.onRoundTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tournament.name,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(tournament.startDate,
              style: Theme.of(context).textTheme.bodySmall),
          if (tournament.rounds.isNotEmpty) ...[
            const Divider(height: 24),
            ...tournament.rounds.map((r) => _RoundTile(
                  round: r,
                  onTap: () => onRoundTap(r.id),
                )),
          ],
        ]),
      ),
    );
  }
}

class _RoundTile extends StatelessWidget {
  final RoundSummary round;
  final VoidCallback onTap;

  const _RoundTile({required this.round, required this.onTap});

  Color _statusColor(BuildContext context) {
    switch (round.status) {
      case 'in_progress': return Colors.green;
      case 'complete':    return Colors.grey;
      default:            return Theme.of(context).colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: _statusColor(context),
        child: Text('R${round.roundNumber}',
            style: const TextStyle(color: Colors.white, fontSize: 13)),
      ),
      title: Text(round.courseName),
      subtitle: Text(round.date),
      trailing: Chip(
        label: Text(round.statusLabel,
            style: const TextStyle(fontSize: 11)),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      onTap: onTap,
    );
  }
}
