import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';

// ── Human-readable labels for game keys ──────────────────────────────────────
const _kGameLabels = {
  'skins'        : 'Skins',
  'stableford'   : 'Stableford',
  'pink_ball'    : 'Pink Ball',
  'nassau'       : 'Nassau',
  'sixes'        : "Six's",
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

    // Staff users (is_staff=true on the Django User) get full admin access
    // regardless of whether they also have a linked player profile.
    final isAdmin = context.read<AuthProvider>().isStaff;

    final hasIrishRumble = round.activeGames.contains('irish_rumble');
    final hasLowNet      = round.activeGames.contains('low_net_round');
    final hasPinkBall    = round.activeGames.contains('pink_ball');
    final hasMatchPlay   = round.activeGames.contains('match_play');
    final hasSetupGames  = hasIrishRumble || hasLowNet || hasPinkBall || hasMatchPlay;

    return RefreshIndicator(
      onRefresh: () => rp.loadRound(widget.roundId),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          _RoundInfoCard(round: round),
          if (hasSetupGames && !isComplete && isAdmin) ...[
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
                  sixesActive:     fsGames.contains('sixes'),
                  sixesStarted:    rp.sixesIsStarted(fs.id),
                  roundActiveGames: round.activeGames,
                  onGamesChanged:  () => rp.loadRound(widget.roundId),
                  onEnterScores:   () {
                    context.read<RoundProvider>().loadScorecard(fs.id);
                    // Route priority: setup screens for games that need initial
                    // configuration; otherwise go straight to universal score entry.
                    // Note: match_play setup is checked BEFORE pink_ball so that
                    // a round combining both games still goes through bracket setup.
                    final String route;
                    if (fsGames.contains('three_person_match') &&
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
                      // Six's needs team / segment setup first.
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
                    Navigator.of(context).pushNamed(route, arguments: routeArgs);
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
            const SizedBox(width: 8),
            Text('\$${round.betUnit.formatBet()} / unit',
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
      'low_net_round':'Stroke Play',
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
  final bool         sixesActive;
  final bool         sixesStarted;
  final List<String> roundActiveGames;
  final VoidCallback onEnterScores;
  final VoidCallback onGamesChanged;

  const _FoursomeCard({
    required this.foursome,
    required this.myPlayerId,
    required this.isAdmin,
    required this.isComplete,
    required this.sixesActive,
    required this.sixesStarted,
    required this.roundActiveGames,
    required this.onEnterScores,
    required this.onGamesChanged,
  });

  // Games that make sense to toggle per-foursome (excludes round-level-only games)
  static const _perFoursomeGames = {
    'skins', 'sixes', 'nassau', 'match_play', 'points_531',
    'irish_rumble', 'pink_ball',
  };

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
    final fsGames = {...roundActiveGames, ...foursome.activeGames};
    final needsBracketSetup =
        (fsGames.contains('match_play') &&
            !foursome.configuredGames.contains('match_play')) ||
        (fsGames.contains('three_person_match') &&
            !foursome.configuredGames.contains('three_person_match'));

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
            if (isAdmin && !isComplete) ...[
              const Spacer(),
              IconButton(
                icon: Icon(
                  Icons.sports_golf,
                  size: 18,
                  color: hasOverride
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: 'Configure group games',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: () => _showGameSheet(context),
              ),
            ],
          ]),
          // Per-foursome game chips (only when override is active)
          if (hasOverride && effectiveGames.isNotEmpty) ...[
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
