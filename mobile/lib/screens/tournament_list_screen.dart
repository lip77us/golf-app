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

  Future<void> _deleteTournament(Tournament t) async {
    final hasInProgress = t.rounds.any((r) => r.status == 'in_progress');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Tournament?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delete "${t.name}" and all its rounds?'),
            if (hasInProgress) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'This tournament has rounds in progress. '
                      'All scores will be permanently lost.',
                      style: TextStyle(color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            const Text('This cannot be undone.',
                style: TextStyle(fontStyle: FontStyle.italic)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final client = context.read<AuthProvider>().client;
      await client.deleteTournament(t.id);
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not delete: ${friendlyError(e)}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
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
            ..pop()
            ..push(MaterialPageRoute(builder: (_) => const PlayerListScreen()));
        },
        onCasualRoundsTap: () {
          Navigator.of(context)
            ..pop()
            ..pushNamed('/casual-rounds');
        },
        onLogout: () => auth.logout(),
      ),
      body: _buildBody(),
      floatingActionButton: !auth.isStaff ? null :
        FloatingActionButton.extended(
          onPressed: () async {
            final created = await Navigator.of(context).push<bool>(
              MaterialPageRoute(builder: (_) => const NewRoundWizard()),
            );
            if (!mounted) return;
            if (created == true) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Round created! Tap it below to enter scores.'),
                  duration: Duration(seconds: 4),
                ),
              );
            }
            _load();
          },
          icon: const Icon(Icons.emoji_events),
          label: const Text('New Tournament'),
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
          isStaff: context.read<AuthProvider>().isStaff,
          onRoundTap: (roundId) =>
              Navigator.of(context).pushNamed('/round', arguments: roundId),
          onDelete: () => _deleteTournament(tournaments[i]),
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
  final VoidCallback onCasualRoundsTap;
  final VoidCallback onLogout;

  const _AppDrawer({
    required this.onPlayersTap,
    required this.onCasualRoundsTap,
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
  final bool isStaff;
  final void Function(int roundId) onRoundTap;
  final VoidCallback onDelete;

  const _TournamentCard({
    required this.tournament,
    required this.isStaff,
    required this.onRoundTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasInProgress =
        tournament.rounds.any((r) => r.status == 'in_progress');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header row: name + delete button
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tournament.name,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(tournament.startDate,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (isStaff)
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    color: hasInProgress
                        ? Colors.orange
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  tooltip: 'Delete tournament',
                  onPressed: onDelete,
                ),
            ],
          ),
          if (tournament.rounds.isNotEmpty) ...[
            const Divider(height: 20),
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
