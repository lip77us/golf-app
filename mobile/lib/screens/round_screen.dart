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

    // Staff users (is_staff=true on the Django User) get full admin access
    // regardless of whether they also have a linked player profile.
    final isAdmin = context.read<AuthProvider>().isStaff;

    final hasIrishRumble = round.activeGames.contains('irish_rumble');
    final hasLowNet      = round.activeGames.contains('low_net_round');
    final hasPinkBall    = round.activeGames.contains('pink_ball');
    final hasSetupGames  = hasIrishRumble || hasLowNet || hasPinkBall;

    return RefreshIndicator(
      onRefresh: () => rp.loadRound(widget.roundId),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          _RoundInfoCard(round: round),
          if (hasSetupGames && !isComplete) ...[
            const SizedBox(height: 16),
            Text('Game Setup',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _GameSetupCard(
              roundId:         widget.roundId,
              hasIrishRumble:  hasIrishRumble,
              hasLowNet:       hasLowNet,
              hasPinkBall:     hasPinkBall,
            ),
          ],
          const SizedBox(height: 16),
          Text('Foursomes',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...round.foursomes.map((fs) => _FoursomeCard(
                foursome:     fs,
                myPlayerId:   myId,
                isAdmin:      isAdmin,
                isComplete:   isComplete,
                sixesActive:  round.activeGames.contains('sixes'),
                sixesStarted: rp.sixesIsStarted(fs.id),
                onEnterScores: () {
                  context.read<RoundProvider>().loadScorecard(fs.id);
                  // Route priority:
                  //   1. Sixes active → /sixes-setup (team picker).
                  //      SixesSetupScreen auto-redirects to /sixes if the
                  //      match is already started.
                  //   2. Points 5-3-1 active → /points-531-setup (handicap
                  //      mode picker).  No team-picking step because the
                  //      game is per-player.
                  //   3. Skins active → /skins-setup (handicap + carryover).
                  //      SkinsSetupScreen auto-redirects to /skins if the
                  //      game is already started.
                  //   4. Nassau active → /nassau-setup (team + handicap +
                  //      press config).  NassauSetupScreen auto-redirects to
                  //      /nassau if the game is already started.
                  //   5. Otherwise → the plain /scorecard.
                  //
                  // These games are mutually exclusive in the casual-round
                  // picker, so branches never collide in practice.
                  final String route;
                  if (round.activeGames.contains('pink_ball')) {
                    route = '/pink-ball';
                  } else if (round.activeGames.contains('sixes')) {
                    route = '/sixes-setup';
                  } else if (round.activeGames.contains('points_531')) {
                    route = '/points-531-setup';
                  } else if (round.activeGames.contains('skins')) {
                    route = '/skins-setup';
                  } else if (round.activeGames.contains('nassau')) {
                    route = '/nassau-setup';
                  } else {
                    route = '/scorecard';
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
      'irish_rumble': 'Irish Rumble',
      'scramble':     'Scramble',
      'low_net_round':'Low Net',
    };
    return labels[g] ?? g;
  }
}

// ---------------------------------------------------------------------------
// Game Setup card — surfaces Irish Rumble / Low Net config buttons
// ---------------------------------------------------------------------------

class _GameSetupCard extends StatelessWidget {
  final int  roundId;
  final bool hasIrishRumble;
  final bool hasLowNet;
  final bool hasPinkBall;

  const _GameSetupCard({
    required this.roundId,
    required this.hasIrishRumble,
    required this.hasLowNet,
    required this.hasPinkBall,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasIrishRumble) ...[
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .pushNamed('/irish-rumble-setup', arguments: roundId),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure Irish Rumble'),
              ),
              if (hasLowNet) const SizedBox(height: 8),
            ],
            if (hasLowNet)
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .pushNamed('/low-net-setup', arguments: roundId),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure Low Net'),
              ),
            if (hasPinkBall) ...[
              if (hasIrishRumble || hasLowNet) const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .pushNamed('/pink-ball-setup', arguments: roundId),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure Pink Ball'),
              ),
            ],
          ],
        ),
      ),
    );
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
  /// True when the logged-in user is admin/staff (no linked player).
  /// Admins can enter scores for any foursome and see game-setup controls.
  final bool     isAdmin;
  final bool     isComplete;
  final bool     sixesActive;
  final bool     sixesStarted;
  final VoidCallback onEnterScores;

  const _FoursomeCard({
    required this.foursome,
    required this.myPlayerId,
    required this.isAdmin,
    required this.isComplete,
    required this.sixesActive,
    required this.sixesStarted,
    required this.onEnterScores,
  });

  @override
  Widget build(BuildContext context) {
    final isMyGroup = myPlayerId != null &&
        foursome.containsPlayer(myPlayerId!);
    // Players can only edit scores for their own group.
    // Admins can edit any group. Everyone can view completed scorecards.
    final canEdit = isAdmin || isMyGroup;
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
          // Players who are not in this group and the round is still in
          // progress see no button at all — they have nothing to do here.
          if (canEdit || isComplete) ...[
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
                      : (sixesActive && !sixesStarted)
                          ? 'Start Match'
                          : 'Enter Scores',
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
