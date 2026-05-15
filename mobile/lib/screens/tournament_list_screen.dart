import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/app_drawer.dart';
import '../widgets/error_view.dart';
import 'new_round_wizard.dart';
import 'player_list_screen.dart';
import 'tournament_low_net_setup_screen.dart';
import 'setup_round_players_screen.dart';
import 'tournament_leaderboard_screen.dart';
import 'ryder_cup_draft_screen.dart';
import 'ryder_cup_scoreboard_screen.dart';
import 'ryder_cup_round_setup_screen.dart';
import 'cup_round_setup_screen.dart';

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
  bool    _showCompleted = false;   // false = Active, true = Completed
  bool    _didAutoRedirect = false; // first-load redirect to casual rounds
                                    // when the user has no active tournaments

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// A tournament is "complete" when it has at least one round and every
  /// round's status is 'complete'.  Tournaments with no rounds yet, or any
  /// pending/in_progress round, are considered active.
  bool _isComplete(Tournament t) =>
      t.rounds.isNotEmpty && t.rounds.every((r) => r.status == 'complete');

  void _onToggle(bool showCompleted) {
    if (showCompleted == _showCompleted) return;
    setState(() { _showCompleted = showCompleted; });
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getTournaments();
      if (mounted) setState(() { _tournaments = data; });

      // First-load only: if the user has no active tournaments, drop them
      // straight onto the casual rounds list.  Use push (not replace) so the
      // back-arrow still brings them back here to see completed tournaments
      // or create a new one.
      if (!_didAutoRedirect && mounted) {
        _didAutoRedirect = true;
        final hasActive = data.any((t) => !_isComplete(t));
        if (!hasActive) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pushNamed('/casual-rounds');
          });
        }
      }
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
          if (auth.isStaff)
            IconButton(
              icon: const Icon(Icons.golf_course),
              tooltip: 'Manage Courses',
              onPressed: () => Navigator.of(context).pushNamed('/course-search'),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      drawer: AppDrawer(
        playerName: auth.player?.name,
        // Already on tournaments — the entry just closes the drawer.
        onTournamentsTap: () => Navigator.of(context).pop(),
        onCasualRoundsTap: () {
          Navigator.of(context).pop();
          Navigator.of(context)
              .pushNamed('/casual-rounds')
              .then((_) { if (mounted) _load(); });
        },
        onPlayersTap: () {
          Navigator.of(context).pop();
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const PlayerListScreen()))
              .then((_) { if (mounted) _load(); });
        },
        onSettingsTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/settings');
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
    final all      = _tournaments ?? [];
    final filtered = all.where(
      (t) => _showCompleted ? _isComplete(t) : !_isComplete(t),
    ).toList();

    return Column(children: [
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
      Expanded(
        child: filtered.isEmpty
            ? Center(child: Text(_showCompleted
                ? 'No completed tournaments.'
                : 'No active tournaments.'))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final t = filtered[i];
          return _TournamentCard(
            tournament       : t,
            isStaff          : context.read<AuthProvider>().isStaff,
            isComplete       : _isComplete(t),
            onRoundTap       : (roundId) =>
                Navigator.of(context).pushNamed('/round', arguments: roundId),
            onSetupRound     : (roundId) => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => SetupRoundPlayersScreen(roundId: roundId)))
                .then((_) { if (mounted) _load(); }),
            onViewLeaderboard: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TournamentLeaderboardScreen(
                    tournamentId  : t.id,
                    tournamentName: t.name,
                  ),
                )),
            onConfigureLowNet: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => TournamentLowNetSetupScreen(
                        tournamentId: t.id)))
                .then((_) { if (mounted) _load(); }),
            onOpenCupDraft: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RyderCupDraftScreen(
                  tournamentId  : t.id,
                  tournamentName: t.name,
                ))),
            onOpenCupScoreboard: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RyderCupScoreboardScreen(
                    tournamentId  : t.id,
                    tournamentName: t.name,
                  ),
                )),
            onSetupCupRound: (round) => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => CupRoundSetupScreen(
                      roundId         : round.id,
                      tournamentId    : t.id,
                      roundNumber     : round.roundNumber,
                      courseId        : round.courseId,
                      courseName      : round.courseName,
                      availableGames  : round.activeGames,
                      gamePointValues : round.gamePointValues,
                    )))
                .then((_) { if (mounted) _load(); }),
            onRecalculateCupPoints: (round) async {
              final client = context.read<AuthProvider>().client;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const AlertDialog(
                  content: Row(children: [
                    CircularProgressIndicator(),
                    SizedBox(width: 16),
                    Text('Recalculating…'),
                  ]),
                ),
              );
              try {
                await client.postRyderCupCalculate(round.id);
                if (!mounted) return;
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('R${round.roundNumber} cup points updated ✓'),
                  backgroundColor: Colors.green.shade700,
                ));
              } catch (e) {
                if (!mounted) return;
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Failed: $e'),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ));
              }
            },
            onDelete         : () => _deleteTournament(t),
          );
                  },
                ),
              ),
      ),
    ]);
  }
}

class _TournamentCard extends StatelessWidget {
  final Tournament tournament;
  final bool isStaff;
  /// True when every round is complete.  Hides staff configuration actions
  /// (setup, recalculate, etc.) so finished tournaments stay finished.
  final bool isComplete;
  final void Function(int roundId) onRoundTap;
  final void Function(int roundId) onSetupRound;
  final VoidCallback onViewLeaderboard;
  final VoidCallback onConfigureLowNet;
  final VoidCallback onOpenCupDraft;
  final VoidCallback onOpenCupScoreboard;
  final void Function(RoundSummary round) onSetupCupRound;
  final void Function(RoundSummary round) onRecalculateCupPoints;
  final VoidCallback onDelete;

  const _TournamentCard({
    required this.tournament,
    required this.isStaff,
    required this.isComplete,
    required this.onRoundTap,
    required this.onSetupRound,
    required this.onViewLeaderboard,
    required this.onConfigureLowNet,
    required this.onOpenCupDraft,
    required this.onOpenCupScoreboard,
    required this.onSetupCupRound,
    required this.onRecalculateCupPoints,
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
          // Non-cup tournaments: show round tiles (pending = setup button, else tap to score).
          // Cup tournaments: show in-progress round tiles so players can tap in to enter scores;
          //   pending rounds have no tile here (staff accesses them via "Set Up Cup Round" below).
          if (tournament.rounds.isNotEmpty) ...[
            if (!tournament.activeGames.contains('team_cup')) ...[
              const Divider(height: 20),
              ...tournament.rounds.map((r) => r.status == 'pending' && isStaff
                  ? _PendingRoundTile(
                      round   : r,
                      onSetup : () => onSetupRound(r.id),
                    )
                  : _RoundTile(
                      round: r,
                      onTap: () => onRoundTap(r.id),
                    )),
            ] else ...[
              // Cup tournament: show in_progress and complete rounds so players
              // can view scorecards and leaderboards from past rounds.
              // Pending rounds are accessed via the "Set Up Cup Round" button.
              if (tournament.rounds.any((r) => r.status != 'pending')) ...[
                const Divider(height: 20),
                ...tournament.rounds
                    .where((r) => r.status != 'pending')
                    .map((r) => _RoundTile(
                          round: r,
                          onTap: () => onRoundTap(r.id),
                        )),
              ],
            ],
          ],

          // ── Championship Leaderboard (always shown for multi-game tournaments)
          if (tournament.activeGames.isNotEmpty) ...[
            const Divider(height: 16),
            _ActionButton(
              icon : Icons.emoji_events_outlined,
              label: 'Championship Leaderboard',
              onTap: onViewLeaderboard,
            ),
          ],

          // ── Staff configure buttons ────────────────────────────────────
          // Hidden on completed tournaments — there's nothing left to configure.
          if (isStaff && !isComplete && tournament.activeGames.isNotEmpty) ...[
            if (tournament.activeGames.contains('low_net'))
              _ActionButton(
                icon : Icons.settings_outlined,
                label: 'Configure Stroke Play Championship',
                onTap: onConfigureLowNet,
              ),
          ],

          // ── Cup / Ryder Cup buttons (only for Cup Play tournaments) ────────
          if (tournament.activeGames.contains('team_cup')) ...[
            const Divider(height: 16),
            _ActionButton(
              icon : Icons.emoji_events_outlined,
              label: 'Cup Scoreboard',
              onTap: onOpenCupScoreboard,
            ),
            // Staff configuration actions — only while the tournament is
            // still active.  Completed cup tournaments expose the scoreboard
            // only, no setup or recalculate buttons.
            if (isStaff && !isComplete) ...[
              _ActionButton(
                icon : Icons.groups_outlined,
                label: 'Cup Draft & Teams',
                onTap: onOpenCupDraft,
              ),
              // Round setup + recalculate: show for all rounds so staff
              // can build foursomes and fix cup points after score corrections.
              ...tournament.rounds.expand((r) => [
                _ActionButton(
                  icon : Icons.tune_outlined,
                  label: 'R${r.roundNumber} · Set Up Cup Round',
                  onTap: () => onSetupCupRound(r),
                ),
                if (r.status != 'pending')
                  _ActionButton(
                    icon : Icons.calculate_outlined,
                    label: 'R${r.roundNumber} · Recalculate Cup Points',
                    onTap: () => onRecalculateCupPoints(r),
                  ),
              ]),
            ],
          ],
        ]),
      ),
    );
  }
}

/// Tile for a round that has not yet been configured (status = 'pending').
/// Shows a "Set Up" button instead of navigating to the round screen.
class _PendingRoundTile extends StatelessWidget {
  final RoundSummary round;
  final VoidCallback onSetup;

  const _PendingRoundTile({required this.round, required this.onSetup});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: Text('R${round.roundNumber}',
            style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
      ),
      title: Text(round.courseName),
      subtitle: Text(round.date),
      trailing: FilledButton.tonal(
        onPressed: onSetup,
        style: FilledButton.styleFrom(
          padding            : const EdgeInsets.symmetric(horizontal: 12),
          visualDensity      : VisualDensity.compact,
          tapTargetSize      : MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('Set Up', style: TextStyle(fontSize: 12)),
      ),
    );
  }
}

/// Small tappable action button shown at the bottom of a tournament card.
class _ActionButton extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap        : onTap,
      borderRadius : BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(children: [
          Icon(icon,
              size : 18,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  color     : Theme.of(context).colorScheme.primary,
                  fontSize  : 13,
                  fontWeight: FontWeight.w500)),
          const Spacer(),
          Icon(Icons.chevron_right,
              size : 18,
              color: Theme.of(context).colorScheme.primary),
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
