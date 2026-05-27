import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';

// ── Human-readable labels for game keys ──────────────────────────────────────
const _kGameLabels = {
  'skins'        : 'Skins',
  'multi_skins'  : 'Multi-Group Skins',
  'stableford'   : 'Stableford',
  'pink_ball'    : 'Pink Ball',
  'nassau'       : 'Nassau',
  'sixes'        : 'Sixes',
  'match_play'   : 'Match Play',
  'irish_rumble' : 'Irish Rumble',
  'scramble'     : 'Scramble',
  'low_net_round': 'Stroke Play',
  'points_531'   : 'Points 5-3-1',
};

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

    // Anyone with admin privileges in this app — Django staff OR
    // account admins — gets full edit access on the round screen,
    // regardless of whether they're a member of any foursome.
    final isAdmin = context.read<AuthProvider>().isAdmin;

    final hasIrishRumble = round.activeGames.contains('irish_rumble');
    final hasLowNet      = round.activeGames.contains('low_net_round');
    final hasPinkBall    = round.activeGames.contains('pink_ball');
    final hasMatchPlay   = round.activeGames.contains('match_play');
    final hasMultiSkins  = round.activeGames.contains('multi_skins');
    final hasSetupGames  = hasIrishRumble || hasLowNet || hasPinkBall || hasMatchPlay;

    return RefreshIndicator(
      onRefresh: () => rp.loadRound(widget.roundId),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          _RoundInfoCard(round: round),
          if (hasMultiSkins) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.attach_money),
                title: const Text('Multi-Group Skins'),
                subtitle: const Text('Round-level pool across all groups'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(
                  '/multi-skins', arguments: widget.roundId,
                ),
              ),
            ),
          ],
          if (hasSetupGames && !isComplete && isAdmin && !round.isCupRound) ...[
            const SizedBox(height: 16),
            Text('Game Setup',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _GameSetupCard(
              roundId:        widget.roundId,
              hasIrishRumble: hasIrishRumble,
              hasLowNet:      hasLowNet,
              hasPinkBall:    hasPinkBall,
              hasMatchPlay:   hasMatchPlay,
              foursomes:      round.foursomes,
            ),
          ],
          const SizedBox(height: 16),
          Text('Foursomes',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...round.foursomes.map((fs) {
                // Effective game list for this foursome: union of round-level
                // games (irish_rumble, pink_ball, stableford, stroke_play —
                // shared by all foursomes) and per-foursome games (match_play,
                // nassau, skins — specific to this foursome).
                final fsGames = {
                  ...round.activeGames,
                  ...fs.activeGames,
                }.toList();
                return _FoursomeCard(
                  foursome:        fs,
                  myPlayerId:      myId,
                  isAdmin:         isAdmin,
                  isComplete:      isComplete,
                  isCupRound:      round.isCupRound,
                  sixesActive:     fsGames.contains('sixes'),
                  sixesStarted:    rp.sixesIsStarted(fs.id),
                  roundActiveGames: round.activeGames,
                  allFoursomes:    round.foursomes,
                  roundId:         widget.roundId,
                  onGamesChanged:  () => rp.loadRound(widget.roundId),
                  onEnterScores:   () {
                    context.read<RoundProvider>().loadScorecard(fs.id);
                    // Route priority: setup screens for games that need initial
                    // configuration; otherwise go straight to universal score entry.
                    // Cup rounds are fully configured via CupRoundSetupScreen —
                    // skip all setup routing and go directly to score entry.
                    final String route;
                    if (round.isCupRound &&
                        fs.configuredGames.contains('quota_nassau')) {
                      // Quota Nassau cup foursomes use the dedicated gross-only
                      // entry screen — not the universal score entry.
                      route = '/quota-nassau';
                    } else if (round.isCupRound &&
                        fs.configuredGames.contains('nassau')) {
                      // Four Ball (Nassau) cup foursomes use the Nassau screen
                      // so phantom donor info, HC, and donor-score row are shown.
                      route = '/nassau';
                    } else if (round.isCupRound) {
                      route = '/score-entry';
                    } else if (fsGames.contains('three_person_match') &&
                        !fs.configuredGames.contains('three_person_match')) {
                      // Three-Person Match not yet configured — go to setup.
                      route = '/three-person-match-setup';
                    } else if (fsGames.contains('match_play') &&
                        !fs.configuredGames.contains('match_play') &&
                        !fs.configuredGames.contains('three_person_match')) {
                      // Match play bracket not yet configured — go to setup.
                      // Skip this gate for 3-player foursomes: they play
                      // Three-Person Match (5-3-1) instead of a bracket, so
                      // their three_person_match config satisfies the setup
                      // requirement even though match_play is round-wide.
                      route = '/match-play-setup';
                    } else if (fsGames.contains('pink_ball')) {
                      // Pink ball always gets its own dedicated screen.
                      // The pink ball screen loads and displays match play
                      // status when match play is also active.
                      route = '/pink-ball';
                    } else if (fsGames.contains('sixes') &&
                        !rp.sixesIsStarted(fs.id)) {
                      // Sixes needs team / segment setup first.
                      route = '/sixes-setup';
                    } else if (fsGames.contains('points_531') &&
                        !fs.configuredGames.contains('points_531')) {
                      // Points 531 needs handicap config.
                      route = '/points-531-setup';
                    } else if (fsGames.contains('nassau') &&
                        !fs.configuredGames.contains('nassau')) {
                      // Nassau needs team assignment + handicap config.
                      route = '/nassau-setup';
                    } else if (fsGames.contains('skins') &&
                        !fs.configuredGames.contains('skins')) {
                      // Skins needs handicap + carryover config.
                      route = '/skins-setup';
                    } else if (fsGames.contains('triple_cup') &&
                        !fs.configuredGames.contains('triple_cup')) {
                      // Triple Cup needs team assignment + handicap config.
                      route = '/triple-cup-setup';
                    } else {
                      // Everything configured (or no setup required) →
                      // universal score entry.
                      route = '/score-entry';
                    }
                    // Build richer arguments for match-play-setup so it can
                    // offer "copy to all" and "copy to peers" actions.
                    final Object routeArgs;
                    if (route == '/match-play-setup') {
                      final allIds = round.foursomes
                          .map((f) => f.id)
                          .toList();
                      final peerIds = round.foursomes
                          .where((f) =>
                              f.id != fs.id &&
                              f.realPlayers.length == fs.realPlayers.length)
                          .map((f) => f.id)
                          .toList();
                      routeArgs = {
                        'foursomeId'     : fs.id,
                        'allMatchPlayIds': allIds,
                        'peerIds'        : peerIds,
                      };
                    } else {
                      routeArgs = fs.id;
                    }
                    Navigator.of(context)
                        .pushNamed(route, arguments: routeArgs)
                        // Refresh the round on return so the foursome's
                        // hasAnyScore (and any other server-computed
                        // flag) reflects whatever happened during
                        // scoring — keeps "Edit Tee Boxes" from
                        // lingering on stale state.
                        .then((_) {
                      if (mounted) rp.loadRound(widget.roundId);
                    });
                  },
                );
              }),
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
            if (!round.isCupRound) ...[
              const SizedBox(width: 8),
              Text('\$${round.betUnit.formatBet()} / unit',
                  style: theme.textTheme.bodySmall),
            ],
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
      'nassau':        'Nassau',
      'quota_nassau':  'Four Ball Quota',
      'sixes':         'Sixes',
      'match_play':    'Match Play',
      'irish_rumble':  'Irish Rumble',
      'scramble':      'Scramble',
      'low_net_round': 'Stroke Play',
    };
    return labels[g] ?? g;
  }
}

// ---------------------------------------------------------------------------
// Game Setup card — surfaces Irish Rumble / Stroke Play config buttons
// ---------------------------------------------------------------------------

class _GameSetupCard extends StatelessWidget {
  final int            roundId;
  final bool           hasIrishRumble;
  final bool           hasLowNet;
  final bool           hasPinkBall;
  final bool           hasMatchPlay;
  final List<Foursome> foursomes;

  const _GameSetupCard({
    required this.roundId,
    required this.hasIrishRumble,
    required this.hasLowNet,
    required this.hasPinkBall,
    required this.hasMatchPlay,
    required this.foursomes,
  });

  @override
  Widget build(BuildContext context) {
    // For match play, only list foursomes that haven't been configured yet.
    // Exclude 3-player foursomes that play Three-Person Match (5-3-1) instead —
    // their three_person_match config satisfies setup even without a bracket.
    final pendingMatchPlay = hasMatchPlay
        ? foursomes.where((fs) =>
            !fs.configuredGames.contains('match_play') &&
            !fs.configuredGames.contains('three_person_match')
          ).toList()
        : <Foursome>[];

    final theme = Theme.of(context);
    // Spacer helpers: only add gaps between sections that are actually present
    final beforeLowNet   = hasIrishRumble;
    final beforePinkBall = hasIrishRumble || hasLowNet;
    final beforeMatchPlay = hasIrishRumble || hasLowNet || hasPinkBall;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasIrishRumble)
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .pushNamed('/irish-rumble-setup', arguments: roundId),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure Irish Rumble'),
              ),
            if (hasLowNet) ...[
              if (beforeLowNet) const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .pushNamed('/low-net-setup', arguments: roundId),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure Stroke Play'),
              ),
            ],
            if (hasPinkBall) ...[
              if (beforePinkBall) const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .pushNamed('/pink-ball-setup', arguments: roundId),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure Pink Ball'),
              ),
            ],
            if (hasMatchPlay) ...[
              if (beforeMatchPlay) const SizedBox(height: 8),
              // Section header
              Row(children: [
                const Icon(Icons.sports_golf, size: 16),
                const SizedBox(width: 6),
                Text('Match Play Brackets',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 4),
              if (pendingMatchPlay.isEmpty)
                // All foursomes configured
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Icon(Icons.check_circle_outline,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text('All brackets set up',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.primary)),
                  ]),
                )
              else ...[
                Text(
                  'Set up one bracket per group:',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                // One button per unconfigured foursome
                ...pendingMatchPlay.map((fs) {
                  final allIds = foursomes.map((f) => f.id).toList();
                  final peerIds = foursomes
                      .where((f) =>
                          f.id != fs.id &&
                          f.realPlayers.length == fs.realPlayers.length)
                      .map((f) => f.id)
                      .toList();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pushNamed(
                        '/match-play-setup',
                        arguments: {
                          'foursomeId'     : fs.id,
                          'allMatchPlayIds': allIds,
                          'peerIds'        : peerIds,
                        },
                      ),
                      icon:  const Icon(Icons.tune, size: 18),
                      label: Text('Set Up ${fs.label}'),
                    ),
                  );
                }),
              ],
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
  final Foursome     foursome;
  final int?         myPlayerId;
  /// True when the logged-in user is admin/staff (no linked player).
  /// Admins can enter scores for any foursome and see game-setup controls.
  final bool         isAdmin;
  final bool         isComplete;
  final bool         isCupRound;
  final bool         sixesActive;
  final bool         sixesStarted;
  final List<String> roundActiveGames;
  /// Round-wide foursome list so the TD move/swap actions can list
  /// other groups as targets.  Includes the current foursome — the
  /// menu filters it out at render time.
  final List<Foursome> allFoursomes;
  final int            roundId;
  final VoidCallback onEnterScores;
  final VoidCallback onGamesChanged;

  const _FoursomeCard({
    required this.foursome,
    required this.myPlayerId,
    required this.isAdmin,
    required this.isComplete,
    required this.isCupRound,
    required this.sixesActive,
    required this.sixesStarted,
    required this.roundActiveGames,
    required this.allFoursomes,
    required this.roundId,
    required this.onEnterScores,
    required this.onGamesChanged,
  });

  // Games that make sense to toggle per-foursome (excludes round-level-only games)
  static const _perFoursomeGames = {
    'skins', 'sixes', 'nassau', 'match_play', 'points_531',
    'irish_rumble', 'pink_ball',
  };

  /// TD-only "no-show" tool — pick a player from this foursome to
  /// remove.  Backend reconfigures any TC game on the foursome and
  /// rebalances the donor pool; the round is refreshed afterwards via
  /// the parent's onGamesChanged callback (it's a "refresh round"
  /// hook in practice).
  Future<void> _showRemovePlayerSheet(BuildContext context) async {
    final realPlayers = foursome.realPlayers;
    if (realPlayers.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cannot remove — foursome already at 1 player.'),
      ));
      return;
    }

    final picked = await showModalBottomSheet<Membership>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Remove from ${foursome.label}',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Tap a player to remove them from this foursome. '
                      'After removal the group plays as a '
                      '${realPlayers.length - 1}-player group; any Triple '
                      'Cup game adjusts automatically (phantom partner '
                      'for 2v1, F9 / B9 / Overall Nassau for 1v1).',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ...realPlayers.map((m) => ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      child: Text(
                        m.player.name.isNotEmpty
                            ? m.player.name[0].toUpperCase()
                            : '?',
                      ),
                    ),
                    title: Text(m.player.name),
                    subtitle: Text('Hcp ${m.playingHandicap}'),
                    onTap: () => Navigator.of(ctx).pop(m),
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (picked == null || !context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('Remove ${picked.player.name}?'),
        content: Text(
          '${picked.player.name} will be removed from ${foursome.label} '
          '(no-show). The group continues with '
          '${realPlayers.length - 1} players. Already-entered scores '
          'are not affected; this is intended for the tee box, before '
          'play starts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final client = context.read<AuthProvider>().client;
    try {
      await client.removeFoursomePlayer(foursome.id, picked.player.id);
      // Refresh round — reuses the same callback game-config changes use.
      onGamesChanged();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${picked.player.name} removed from ${foursome.label}.'),
        ));
      }
    } catch (e) {
      if (!context.mounted) return;
      // Backend sends {detail, errors[]} for the donor-pool violation
      // case.  Surface either the structured errors or the raw message.
      final raw = e.toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Could not remove: $raw'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  /// TD-only "rebalance" tool — pick a player from this foursome,
  /// then pick a target foursome to move them to.  Backend reconfigs
  /// both sides' TC games and revalidates the donor pool; pre-play
  /// only.  Surfaces the backend's error detail verbatim on failure.
  Future<void> _showMovePlayerSheet(BuildContext context) async {
    final realPlayers = foursome.realPlayers;
    if (realPlayers.isEmpty) return;

    final picked = await showModalBottomSheet<Membership>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Move player from ${foursome.label}',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Pick the player to move.  You\'ll choose the '
                      'destination group next.  Both groups\' Triple '
                      'Cup games (if any) will adjust automatically.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ...realPlayers.map((m) => ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      child: Text(
                        m.player.name.isNotEmpty
                            ? m.player.name[0].toUpperCase()
                            : '?',
                      ),
                    ),
                    title: Text(m.player.name),
                    subtitle: Text('Hcp ${m.playingHandicap}'),
                    onTap: () => Navigator.of(ctx).pop(m),
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (picked == null || !context.mounted) return;

    // Step 2: pick a target foursome (excluding the current one).
    final targets = allFoursomes
        .where((f) => f.id != foursome.id)
        .toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No other groups to move to.'),
      ));
      return;
    }

    final targetFs = await showModalBottomSheet<Foursome>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Move ${picked.player.name} to which group?',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const Divider(height: 1),
              ...targets.map((f) {
                final size = f.realPlayers.length;
                final full = size >= 4;
                return ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(f.label),
                  subtitle: Text(
                    full
                        ? '$size players · full'
                        : '$size player${size == 1 ? "" : "s"}',
                  ),
                  enabled: !full,
                  onTap: full ? null : () => Navigator.of(ctx).pop(f),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (targetFs == null || !context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('Move ${picked.player.name}?'),
        content: Text(
          '${picked.player.name} will move from ${foursome.label} to '
          '${targetFs.label}. ${foursome.label} will play with '
          '${foursome.realPlayers.length - 1} players; ${targetFs.label} '
          'with ${targetFs.realPlayers.length + 1}. Any Triple Cup '
          'games on either group adjust automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final client = context.read<AuthProvider>().client;
    try {
      await client.moveRoundPlayer(
        roundId,
        playerId       : picked.player.id,
        fromFoursomeId : foursome.id,
        toFoursomeId   : targetFs.id,
      );
      onGamesChanged();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${picked.player.name} moved to ${targetFs.label}.'),
        ));
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Could not move: ${e.toString()}'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  /// TD-only "shift the schedule" tool — swap this foursome's tee
  /// position (group_number + tee_time) with another's.  Useful when
  /// a group is late or a 3-some wants more donor variety.
  Future<void> _showSwapPositionSheet(BuildContext context) async {
    final others = allFoursomes
        .where((f) => f.id != foursome.id)
        .toList();
    if (others.isEmpty) return;

    final targetFs = await showModalBottomSheet<Foursome>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Swap ${foursome.label} with…',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Pick the group to swap tee positions with.  '
                      'Useful when one group is running late or when '
                      'a short-rostered group needs more donor variety.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ...others.map((f) => ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(f.label),
                    subtitle: Text(
                      f.teeTime != null
                          ? 'Tee time: ${f.teeTime}'
                          : 'No tee time set',
                    ),
                    onTap: () => Navigator.of(ctx).pop(f),
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (targetFs == null || !context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('Swap with ${targetFs.label}?'),
        content: Text(
          '${foursome.label} and ${targetFs.label} will trade tee '
          'positions (and tee times if assigned).  Rosters stay the '
          'same in each group.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Swap'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final client = context.read<AuthProvider>().client;
    try {
      await client.swapFoursomePosition(
        foursome.id,
        targetGroupNumber: targetFs.groupNumber,
      );
      onGamesChanged();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Swapped tee positions with ${targetFs.label}.'),
        ));
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Could not swap: ${e.toString()}'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  Future<void> _showGameSheet(BuildContext context) async {
    // Only offer games that are active at the round level and can be per-foursome
    final eligible = roundActiveGames
        .where((g) => _perFoursomeGames.contains(g))
        .toList();
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No per-group games to configure.')),
      );
      return;
    }

    // Current selection: foursome override if set, otherwise all round games
    final current = foursome.activeGames.isNotEmpty
        ? Set<String>.from(foursome.activeGames)
        : Set<String>.from(eligible);

    final selected = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GameSelectionSheet(
        foursomeLabel: foursome.label,
        eligibleGames: eligible,
        selected:      current,
      ),
    );

    if (selected == null || !context.mounted) return;

    // Empty list means "inherit round defaults" (all round games selected)
    final toSave = selected.length == eligible.length
        ? <String>[]   // identical to round — clear override
        : selected.toList();

    final client = context.read<AuthProvider>().client;
    try {
      await client.patchFoursomeActiveGames(foursome.id, activeGames: toSave);
      onGamesChanged();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMyGroup = myPlayerId != null &&
        foursome.containsPlayer(myPlayerId!);
    // Players can only edit scores for their own group.
    // Admins can edit any group. Everyone can view completed scorecards.
    final canEdit = isAdmin || isMyGroup;
    final theme = Theme.of(context);

    // Effective games shown for this foursome
    final effectiveGames = foursome.activeGames.isNotEmpty
        ? foursome.activeGames
        : roundActiveGames;
    final hasOverride = foursome.activeGames.isNotEmpty;

    // True when this foursome needs a bracket/setup step before score entry.
    // Cup rounds are fully configured via CupRoundSetupScreen — skip all
    // bracket-setup gates for cup foursomes.
    final fsGames = {...roundActiveGames, ...foursome.activeGames};
    final needsBracketSetup = !isCupRound && (
        (fsGames.contains('match_play') &&
            !foursome.configuredGames.contains('match_play')) ||
        (fsGames.contains('three_person_match') &&
            !foursome.configuredGames.contains('three_person_match')));

    // For cup rounds, show the game each foursome is playing (its activeGames).
    // For regular rounds, only show chips when there's a per-foursome override.
    final showGameChips = isCupRound
        ? effectiveGames.isNotEmpty
        : (hasOverride && effectiveGames.isNotEmpty);

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
            if (foursome.teeTime != null) ...[
              const SizedBox(width: 8),
              Icon(Icons.schedule,
                  size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 2),
              Text(foursome.teeTime!,
                  style: theme.textTheme.bodySmall),
            ],
            // TD action menu — consolidates the per-foursome admin
            // tools (configure games, remove player) behind a single
            // overflow icon so the card header stays uncluttered.
            // Visible only to admins on in-progress rounds.  Cup rounds
            // hide the "configure games" entry (games are fixed at
            // tournament setup) but keep "remove player" so the TD
            // can still handle no-shows at the tee box.
            if (isAdmin && !isComplete) ...[
              const Spacer(),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: 'Tournament director actions',
                padding: EdgeInsets.zero,
                onSelected: (action) {
                  switch (action) {
                    case 'configure_games':
                      _showGameSheet(context);
                      break;
                    case 'remove_player':
                      _showRemovePlayerSheet(context);
                      break;
                    case 'move_player':
                      _showMovePlayerSheet(context);
                      break;
                    case 'swap_position':
                      _showSwapPositionSheet(context);
                      break;
                  }
                },
                itemBuilder: (_) => [
                  if (!isCupRound)
                    PopupMenuItem(
                      value: 'configure_games',
                      child: Row(children: [
                        Icon(Icons.sports_golf, size: 18,
                            color: hasOverride
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 12),
                        const Flexible(child: Text('Configure group games')),
                      ]),
                    ),
                  // Short, scannable labels — verbose phrasings
                  // overflowed the popup width on iPhone-mini.
                  PopupMenuItem(
                    value: 'move_player',
                    child: Row(children: [
                      Icon(Icons.swap_horiz, size: 18,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      const Flexible(child: Text('Move player to group…')),
                    ]),
                  ),
                  if (allFoursomes.length > 1)
                    PopupMenuItem(
                      value: 'swap_position',
                      child: Row(children: [
                        Icon(Icons.schedule, size: 18,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        const Flexible(child: Text('Swap tee position…')),
                      ]),
                    ),
                  PopupMenuItem(
                    value: 'remove_player',
                    child: Row(children: [
                      Icon(Icons.person_remove_outlined, size: 18,
                          color: theme.colorScheme.error),
                      const SizedBox(width: 12),
                      const Flexible(child: Text('Remove no-show')),
                    ]),
                  ),
                ],
              ),
            ],
          ]),
          // Game chips: always shown for cup rounds; only when override active
          // for regular rounds.
          if (showGameChips) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 2,
              children: effectiveGames.map((g) => Chip(
                label: Text(_kGameLabels[g] ?? g,
                    style: const TextStyle(fontSize: 10)),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                backgroundColor:
                    theme.colorScheme.primaryContainer.withOpacity(0.5),
              )).toList(),
            ),
          ],
          const SizedBox(height: 8),
          ...foursome.realPlayers.map((m) {
            // In cup rounds, tint the player name + person icon with
            // the cup team colour so the TD can spot the team split
            // (and which player would be "the solo" in a 3-some) at
            // a glance.  Falls back to the default on-surface colour
            // for casual rounds.
            final teamColor = m.cupTeamColour != null
                ? resolveTripleCupTeamColor(
                    m.cupTeamColour, theme.colorScheme.onSurface)
                : null;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(Icons.person_outline, size: 16, color: teamColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    m.player.name,
                    overflow: TextOverflow.ellipsis,
                    style: teamColor != null
                        ? TextStyle(
                            color: teamColor, fontWeight: FontWeight.w600)
                        : null,
                  ),
                ),
                if (m.tee != null) ...[
                  Text(m.tee!.teeName,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 8),
                ],
                Text('Hcp ${m.playingHandicap}',
                    style: theme.textTheme.bodySmall),
              ]),
            );
          }),
          // Players who are not in this group and the round is still in
          // progress see no button at all — they have nothing to do here.
          if (canEdit || isComplete) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onEnterScores,
                icon: Icon(
                  isComplete
                      ? Icons.table_chart_outlined
                      : needsBracketSetup
                          ? Icons.tune
                          : Icons.edit_note,
                  size: 18,
                ),
                label: Text(
                  isComplete
                      ? 'View Scorecard'
                      : needsBracketSetup
                          ? 'Set Up Bracket →'
                          : (sixesActive && !sixesStarted)
                              ? 'Start Match'
                              : 'Enter Scores',
                ),
              ),
            ),
            // Confirm Tee Boxes — only meaningful before any hole is
            // scored.  Server-side the endpoint refuses tee changes
            // once scoring starts; we hide the button at the same
            // threshold so the user doesn't tap into a dead-end.
            if (canEdit && !isComplete && !foursome.hasAnyScore) ...[
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed(
                    '/confirm-tees',
                    arguments: foursome.id,
                  ),
                  icon: const Icon(Icons.golf_course_outlined, size: 18),
                  label: const Text('Edit Tee Boxes'),
                ),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}

// ── Bottom sheet for per-foursome game selection ──────────────────────────────

class _GameSelectionSheet extends StatefulWidget {
  final String       foursomeLabel;
  final List<String> eligibleGames;
  final Set<String>  selected;

  const _GameSelectionSheet({
    required this.foursomeLabel,
    required this.eligibleGames,
    required this.selected,
  });

  @override
  State<_GameSelectionSheet> createState() => _GameSelectionSheetState();
}

class _GameSelectionSheetState extends State<_GameSelectionSheet> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('${widget.foursomeLabel} — Games',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(null),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'Toggle which games this group is playing. '
            'Deselecting all reverts to the round defaults.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          ...widget.eligibleGames.map((g) => CheckboxListTile(
                title: Text(_kGameLabels[g] ?? g),
                value: _selected.contains(g),
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (v) => setState(() {
                  if (v == true) _selected.add(g); else _selected.remove(g);
                }),
              )),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(Set<String>.from(_selected)),
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}
