import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';

class RoundScreen extends StatefulWidget {
  final int roundId;
  const RoundScreen({super.key, required this.roundId});

  @override
  State<RoundScreen> createState() => _RoundScreenState();
}

class _RoundScreenState extends State<RoundScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RoundProvider>().loadRound(widget.roundId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rp      = context.watch<RoundProvider>();
    final auth    = context.read<AuthProvider>();
    final myId    = auth.player?.id;

    final round        = rp.round;
    final isComplete   = round?.status == 'complete';
    final isInProgress = round?.status == 'in_progress';

    return Scaffold(
      appBar: AppBar(
        title: round == null
            ? const Text('Round')
            : Text('Round ${round.roundNumber}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Leaderboard',
            onPressed: round == null
                ? null
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: round.id),
          ),
        ],
      ),
      // Persistent bottom bar — always visible regardless of scroll position
      bottomNavigationBar: round == null ? null : SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: isInProgress
              ? _CompleteRoundButton(
                  roundId: round.id,
                  submitting: rp.submitting,
                )
              : isComplete
                  ? FilledButton.icon(
                      onPressed: () => Navigator.of(context)
                          .pushNamed('/leaderboard', arguments: round.id),
                      icon: const Icon(Icons.emoji_events),
                      label: const Text('Final Results'),
                    )
                  : const SizedBox.shrink(),
        ),
      ),
      body: _buildBody(context, rp, myId),
    );
  }

  Widget _buildBody(BuildContext context, RoundProvider rp, int? myId) {
    if (rp.loadingRound) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null) {
      return ErrorView(
        message: rp.error!,
        onRetry: () => rp.loadRound(widget.roundId),
      );
    }
    final round = rp.round;
    if (round == null) return const SizedBox.shrink();

    final isComplete = round.status == 'complete';

    return RefreshIndicator(
      onRefresh: () => rp.loadRound(widget.roundId),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          _RoundInfoCard(round: round),
          const SizedBox(height: 16),
          Text('Foursomes',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...round.foursomes.map((fs) => _FoursomeCard(
                foursome:     fs,
                myPlayerId:   myId,
                isComplete:   isComplete,
                sixesActive:  round.activeGames.contains('sixes'),
                sixesStarted: rp.sixesIsStarted(fs.id),
                matchPlay18Active:  round.activeGames.contains('match_play_18'),
                matchPlay18Started: rp.matchPlay18IsStarted(fs.id),
                onEnterScores: () {
                  context.read<RoundProvider>().loadScorecard(fs.id);
                  // Route to the Six's setup screen (Match 1 team picker)
                  // when that game is active, otherwise use the standard
                  // scorecard.  SixesSetupScreen auto-redirects to /sixes
                  // if the match is already started.
                  String route = '/scorecard';
                  if (round.activeGames.contains('sixes')) {
                      route = '/sixes-setup';
                  } else if (round.activeGames.contains('match_play_18')) {
                      route = '/match-play-18-setup';
                  }
                  Navigator.of(context).pushNamed(route, arguments: fs.id);
                },
              )),
        ],
      ),
    );
  }
}

class _RoundInfoCard extends StatelessWidget {
  final Round round;
  const _RoundInfoCard({required this.round});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(round.course.name,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(round.date, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(children: [
            Chip(label: Text(round.status.replaceAll('_', ' ').toUpperCase(),
                style: const TextStyle(fontSize: 11))),
            const SizedBox(width: 8),
            Text('\$${round.betUnit.toStringAsFixed(2)} / unit',
                style: theme.textTheme.bodySmall),
          ]),
          if (round.activeGames.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: round.activeGames
                  .map((g) => Chip(
                        label: Text(_gameLabel(g),
                            style: const TextStyle(fontSize: 11)),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
          ],
        ]),
      ),
    );
  }

  String _gameLabel(String g) {
    const labels = {
      'skins':        'Skins',
      'stableford':   'Stableford',
      'pink_ball':    'Pink Ball',
      'nassau':       'Nassau',
      'sixes':        "Six's",
      'match_play':   'Match Play',
      'match_play_18':'18-Hole Match Play',
      'irish_rumble': 'Irish Rumble',
      'scramble':     'Scramble',
      'low_net_round':'Low Net',
    };
    return labels[g] ?? g;
  }
}

// ---------------------------------------------------------------------------
// Complete Round button with confirmation dialog
// ---------------------------------------------------------------------------

class _CompleteRoundButton extends StatelessWidget {
  final int roundId;
  final bool submitting;

  const _CompleteRoundButton({required this.roundId, required this.submitting});

  Future<void> _confirm(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Complete Round?'),
        content: const Text(
          'This will mark the round as finished and lock all scores. '
          'You can still view the final results afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Complete Round'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final rp = context.read<RoundProvider>();
    final lb = await rp.completeRound(roundId);
    if (!context.mounted) return;

    if (lb != null) {
      Navigator.of(context).pushNamed('/leaderboard', arguments: roundId);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(rp.error ?? 'Could not complete round.'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.tertiary,
          foregroundColor: Theme.of(context).colorScheme.onTertiary,
        ),
        onPressed: submitting ? null : () => _confirm(context),
        icon: submitting
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.flag_rounded),
        label: Text(submitting ? 'Completing…' : 'Complete Round'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Foursome card
// ---------------------------------------------------------------------------

class _FoursomeCard extends StatelessWidget {
  final Foursome foursome;
  final int?     myPlayerId;
  final bool     isComplete;
  final bool     sixesActive;
  final bool     sixesStarted;
  final bool     matchPlay18Active;
  final bool     matchPlay18Started;
  final VoidCallback onEnterScores;

  const _FoursomeCard({
    required this.foursome,
    required this.myPlayerId,
    required this.isComplete,
    required this.sixesActive,
    required this.sixesStarted,
    required this.matchPlay18Active,
    required this.matchPlay18Started,
    required this.onEnterScores,
  });

  @override
  Widget build(BuildContext context) {
    final isMyGroup = myPlayerId != null &&
        foursome.containsPlayer(myPlayerId!);
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isMyGroup
          ? theme.colorScheme.primaryContainer.withOpacity(0.3)
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(foursome.label,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (isMyGroup) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('My Group',
                    style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          ...foursome.realPlayers.map((m) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.person_outline, size: 16),
                  const SizedBox(width: 6),
                  Text(m.player.name),
                  const Spacer(),
                  Text('Hcp ${m.playingHandicap}',
                      style: theme.textTheme.bodySmall),
                ]),
              )),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onEnterScores,
              icon: Icon(
                isComplete ? Icons.table_chart_outlined : Icons.edit_note,
                size: 18,
              ),
              label: Text(
                isComplete
                    ? 'View Scorecard'
                    : ((sixesActive && !sixesStarted) || (matchPlay18Active && !matchPlay18Started))
                        ? 'Start Match'
                        : 'Enter Scores',
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
