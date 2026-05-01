import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/error_view.dart';
import 'casual_round_screen.dart';

/// Lists the authenticated player's casual rounds with a toggle between
/// Active (in_progress) and Completed views.
class CasualRoundsListScreen extends StatefulWidget {
  const CasualRoundsListScreen({super.key});

  @override
  State<CasualRoundsListScreen> createState() => _CasualRoundsListScreenState();
}

class _CasualRoundsListScreenState extends State<CasualRoundsListScreen> {
  List<CasualRoundSummary>? _rounds;
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;
  bool    _showCompleted = false;   // false = Active, true = Completed

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getCasualRounds(
        status: _showCompleted ? 'complete' : 'in_progress',
      );
      if (mounted) setState(() { _rounds = data; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error        = friendlyError(e);
          _networkError = isNetworkError(e);
        });
      }
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  void _onToggle(bool showCompleted) {
    if (showCompleted == _showCompleted) return;
    setState(() { _showCompleted = showCompleted; });
    _load();
  }

  Future<void> _confirmDelete(CasualRoundSummary round) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Round?'),
        content: Text(
          'Delete the ${round.courseName} round on ${round.date}? '
          'All scores will be permanently removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await context.read<AuthProvider>().client.deleteCasualRound(round.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final myId = auth.player?.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Casual Rounds'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      // Only show FAB on the Active tab — no new rounds on the Completed tab.
      floatingActionButton: _showCompleted ? null : FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CasualRoundScreen()),
          );
          _load();
        },
        icon: const Icon(Icons.sports_golf),
        label: const Text('New Casual Round'),
      ),
      body: Column(
        children: [
          // ── Active / Completed toggle ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Active'),
                  icon: Icon(Icons.play_circle_outline),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Completed'),
                  icon: Icon(Icons.check_circle_outline),
                ),
              ],
              selected: {_showCompleted},
              onSelectionChanged: (s) => _onToggle(s.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          // ── List ──
          Expanded(child: _buildBody(myId)),
        ],
      ),
    );
  }

  /// Navigate directly to the score-entry screen for an in-progress round,
  /// or to the round overview for a completed round.
  Future<void> _openRound(CasualRoundSummary round) async {
    final nav = Navigator.of(context);
    final fsId = round.foursomeId;

    // Completed rounds → round overview (shows leaderboard button etc.)
    if (round.status == 'complete' || fsId == null) {
      await nav.pushNamed('/round', arguments: round.id);
      return;
    }

    // In-progress: jump straight to the game screen.
    // Setup screens auto-redirect to the play screen if the game is already
    // started, so routing through them is safe and handles the
    // "started vs not started" case for free.

    // Load the full round so that rp.round is populated before the play screen
    // opens.  Game screens use rp.round for things like the leaderboard button
    // and bet-unit display; without this it stays null when coming from this
    // list (rather than through the normal round-setup flow).
    // ignore: use_build_context_synchronously
    context.read<RoundProvider>().loadRound(round.id);   // fire & forget

    final String route;
    if (round.activeGames.contains('sixes')) {
      route = '/sixes-setup';          // will redirect to /score-entry if already started
    } else if (round.activeGames.contains('points_531')) {
      route = '/points-531-setup';     // will redirect to /score-entry if already started
    } else if (round.activeGames.contains('skins')) {
      route = '/skins-setup';          // will redirect to /score-entry if already started
    } else if (round.activeGames.contains('nassau')) {
      route = '/nassau-setup';         // will redirect to /score-entry if already started
    } else {
      route = '/score-entry';          // stroke play, stableford, or multi-game combo
    }
    await nav.pushNamed(route, arguments: fsId);

    // After returning from the game screen, wait for any pending score syncs
    // to flush before reloading the list.  Without this the server hasn't
    // received the scores yet and current_hole still shows 0 / "Not started".
    if (mounted) {
      final sync = context.read<SyncService>();
      if (sync.hasPending) {
        await sync.waitUntilIdle();
      }
    }
  }

  Widget _buildBody(int? myId) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(
        message:   _error!,
        isNetwork: _networkError,
        onRetry:   _load,
      );
    }
    // Defensively filter by status client-side so that a round which was just
    // completed can never flash back into the Active list even if the server
    // response is momentarily stale.
    final rounds = (_rounds ?? []).where((r) {
      return _showCompleted ? r.status == 'complete' : r.status != 'complete';
    }).toList();
    if (rounds.isEmpty) {
      final emptyMsg = _showCompleted
          ? 'No completed rounds yet.'
          : 'No rounds in progress.';
      final hintMsg = _showCompleted
          ? 'Completed rounds will appear here.'
          : 'Tap + to start a new casual round.';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showCompleted
                  ? Icons.check_circle_outline
                  : Icons.sports_golf,
              size: 56,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(emptyMsg,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(hintMsg,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        itemCount: rounds.length,
        itemBuilder: (_, i) {
          final round = rounds[i];
          final isCreator = myId != null && round.createdByPlayerId == myId;
          return _CasualRoundCard(
            round:       round,
            isCompleted: _showCompleted,
            onTap: () async {
              await _openRound(round);
              _load();
            },
            onDelete: isCreator ? () => _confirmDelete(round) : null,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card widget
// ---------------------------------------------------------------------------

class _CasualRoundCard extends StatelessWidget {
  final CasualRoundSummary round;
  final bool           isCompleted;
  final VoidCallback   onTap;
  final VoidCallback?  onDelete;

  const _CasualRoundCard({
    required this.round,
    required this.isCompleted,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final holeLabel = isCompleted
        ? 'Complete'
        : round.currentHole == 0
            ? 'Not started'
            : round.currentHole == 18
                ? 'Hole 18'
                : 'Through hole ${round.currentHole}';

    final gameLabels = round.activeGames.map(_gameLabel).join(' • ');
    final playerNames = round.players.map((p) => p.name).join(', ');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Main content ──
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Course + date
                    Row(children: [
                      Expanded(
                        child: Text(
                          round.courseName,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        round.date,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ]),
                    const SizedBox(height: 4),

                    // Games + hole progress
                    Row(children: [
                      if (gameLabels.isNotEmpty) ...[
                        Icon(Icons.casino_outlined,
                            size: 13, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(gameLabels,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.primary)),
                        const SizedBox(width: 12),
                      ],
                      Icon(
                        isCompleted
                            ? Icons.check_circle_outline
                            : Icons.flag_outlined,
                        size: 13,
                        color: isCompleted
                            ? Colors.green
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        holeLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isCompleted
                              ? Colors.green
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),

                    // Players
                    Row(children: [
                      Icon(Icons.people_outline,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          playerNames.isEmpty ? '—' : playerNames,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),

              // ── Delete icon — only shown to the round creator ──
              if (onDelete != null)
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: theme.colorScheme.error),
                  tooltip: 'Delete round',
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _gameLabel(String g) {
    const labels = {
      'skins':      'Skins',
      'points_531': 'Points 5-3-1',
      'sixes':      "Six's",
      'nassau':     'Nassau',
    };
    return labels[g] ?? g;
  }
}
