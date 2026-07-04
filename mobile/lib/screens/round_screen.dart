import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/game_chip.dart';
import '../widgets/round_chat_button.dart';

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
    // Casual rounds are labelled by their game ("Round N" is a tournament
    // concept) and get an explicit Exit-to-home action instead of plain back.
    final isCasual     = (round?.isCasual ?? false) && !(round?.isCupRound ?? false);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isCasual,
        leading: isCasual
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Exit round',
                // Pop back to whatever launched the round (the casual list,
                // onboarding, etc.).  The hub sits directly above its
                // originating screen, so a single pop returns there — not the
                // app root (whose default view is the Tournament list).
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: round == null
            ? const Text('Round')
            : Text(isCasual
                ? _casualTitle(round.activeGames)
                : 'Round ${round.roundNumber}'),
        actions: [
          if (round != null)
            RoundChatButton(roundId: round.id, title: round.course.name),
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
                  allScored: round.allHolesScored,
                  holesRemaining: round.holesRemaining,
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

  /// Title for a casual round: the single game's name (e.g. "Skins"), or a
  /// generic label for multi-game combos / unknown games.
  String _casualTitle(List<String> games) {
    if (games.length == 1) {
      return gameMeta(games.first)?.displayName ?? 'Casual Round';
    }
    return 'Casual Round';
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
    // "Can manage" = TD/organizer of THIS round (own account + admin). A
    // cross-account designated scorer gets false, so TD config is hidden.
    final canManage = round.canManage;

    final hasIrishRumble = round.activeGames.contains('irish_rumble');
    final hasPinkBall    = round.activeGames.contains('pink_ball');
    final hasMatchPlay   = round.activeGames.contains('match_play');
    final hasMultiSkins  = round.activeGames.contains('multi_skins');
    // The round-level Mini Singles Bracket list is only useful for a
    // multi-foursome round (set up each group's bracket from one place).  On a
    // single-foursome round it duplicates the foursome card's own "Set Up
    // Bracket" / "Edit Configuration" actions and just pushes them off-screen,
    // so hide it there.
    final showMatchPlaySetup = hasMatchPlay && round.foursomes.length > 1;
    // Stroke Play (low net) and Stableford are round-level games whose scoring
    // config (handicap mode, points table, payout) is retroactive, so they're
    // only editable BEFORE the first score is posted anywhere in the round.
    // On a single-foursome (casual) round they show as bottom buttons on the
    // foursome card instead; the "Game Setup" card is reserved for
    // multi-foursome rounds.
    final roundHasAnyScore = round.foursomes.any((f) => f.hasAnyScore);
    final multiFoursome    = round.foursomes.length > 1;
    final showLowNet = round.activeGames.contains('low_net_round') &&
        !roundHasAnyScore && multiFoursome;
    final showStableford = round.activeGames.contains('stableford') &&
        !roundHasAnyScore && multiFoursome;
    final hasSetupGames  = hasIrishRumble || showLowNet || hasPinkBall ||
        showMatchPlaySetup || showStableford;

    return RefreshIndicator(
      onRefresh: () => rp.loadRound(widget.roundId),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          _RoundInfoCard(round: round),
          if (hasMultiSkins && canManage) ...[
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
          if (hasSetupGames && !isComplete && canManage && !round.isCupRound) ...[
            const SizedBox(height: 16),
            Text('Game Setup',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _GameSetupCard(
              roundId:        widget.roundId,
              hasIrishRumble: hasIrishRumble,
              showLowNet:     showLowNet,
              hasPinkBall:    hasPinkBall,
              hasMatchPlay:   showMatchPlaySetup,
              showStableford: showStableford,
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
                  canManage:       canManage,
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
                      // Legacy: rounds created with the old standalone
                      // three_person_match slug.  New rounds use match_play
                      // and auto-dispatch via the branch below.
                      route = '/three-person-match-setup';
                    } else if (fsGames.contains('match_play') &&
                        !fs.configuredGames.contains('match_play') &&
                        !fs.configuredGames.contains('three_person_match')) {
                      // Match Play is a single tournament-wide pick that
                      // auto-dispatches by foursome size: 3-player groups
                      // play Three-Person Match (Points 5-3-1 → 1v1 final);
                      // 4-player groups play the single-elimination bracket
                      // (semis 1–9, Final + 3rd-place 10–18).
                      final realCount = fs.realPlayers.length;
                      route = realCount == 3
                          ? '/three-person-match-setup'
                          : '/match-play-setup';
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
                    } else if (fsGames.contains('vegas') &&
                        !fs.configuredGames.contains('vegas')) {
                      // Vegas needs team assignment + options.
                      route = '/vegas-setup';
                    } else if (fsGames.contains('fourball') &&
                        !fs.configuredGames.contains('fourball')) {
                      // Fourball needs team assignment + handicap + stake.
                      route = '/fourball-setup';
                    } else if (fsGames.contains('skins') &&
                        primaryGameOf(fsGames) == 'skins' &&
                        !fs.configuredGames.contains('skins')) {
                      // Skins as the PRIMARY needs handicap + carryover config
                      // before scoring. As a side game it's configured from the
                      // hub and never gates Enter Scores.
                      route = '/skins-setup';
                    } else if (fsGames.contains('wolf') &&
                        !fs.configuredGames.contains('wolf')) {
                      // Wolf needs handicap + rotation + point config.
                      route = '/wolf-setup';
                    } else if (fsGames.contains('wolf')) {
                      // Configured Wolf owns its own per-hole decision +
                      // score-entry screen.
                      route = '/wolf';
                    } else if (fsGames.contains('rabbit') &&
                        !fs.configuredGames.contains('rabbit')) {
                      // Rabbit needs handicap + mode + segment config.
                      route = '/rabbit-setup';
                    } else if (fsGames.contains('rabbit')) {
                      // Configured Rabbit owns its own score-entry screen.
                      route = '/rabbit';
                    } else if (fsGames.contains('triple_cup') &&
                        !fs.configuredGames.contains('triple_cup')) {
                      // Triple Cup needs team assignment + handicap config.
                      route = '/triple-cup-setup';
                    } else if (fsGames.contains('triple_cup')) {
                      // Configured Triple Cup → straight to score entry (same as
                      // every other game).  The cup-standings home (/triple-cup)
                      // is reachable from the leaderboard, not the play flow.
                      route = '/score-entry';
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
                  .map((g) => GameChip(gameId: g))
                  .toList(),
            ),
          ],
        ]),
      ),
    );
  }

  String _gameLabel(String g) => gameDisplayName(g);
}

// ---------------------------------------------------------------------------
// Game Setup card — surfaces Irish Rumble / Stroke Play config buttons
// ---------------------------------------------------------------------------

class _GameSetupCard extends StatelessWidget {
  final int            roundId;
  final bool           hasIrishRumble;
  final bool           showLowNet;
  final bool           hasPinkBall;
  final bool           hasMatchPlay;
  final bool           showStableford;
  final List<Foursome> foursomes;

  const _GameSetupCard({
    required this.roundId,
    required this.hasIrishRumble,
    required this.showLowNet,
    required this.hasPinkBall,
    required this.hasMatchPlay,
    required this.showStableford,
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
    final beforeLowNet    = hasIrishRumble;
    final beforeStableford = hasIrishRumble || showLowNet;
    final beforePinkBall  = hasIrishRumble || showLowNet || showStableford;
    final beforeMatchPlay = hasIrishRumble || showLowNet || showStableford ||
        hasPinkBall;

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
            if (showLowNet) ...[
              if (beforeLowNet) const SizedBox(height: 8),
              OutlinedButton.icon(
                // returnToHub: pops back to this launch page on save.
                onPressed: () => Navigator.of(context).pushNamed(
                    '/low-net-setup',
                    arguments: {'id': roundId, 'returnToHub': true}),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Edit Stroke Play'),
              ),
            ],
            if (showStableford) ...[
              if (beforeStableford) const SizedBox(height: 8),
              OutlinedButton.icon(
                // returnToHub: pops back to this launch page on save.
                onPressed: () => Navigator.of(context).pushNamed(
                    '/stableford-setup',
                    arguments: {'id': roundId, 'returnToHub': true}),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Edit Stableford'),
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
                Text('Mini Singles Brackets',
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
                  // Match Play auto-dispatches by group size: 3-player
                  // foursomes get Three-Person Match (Points 5-3-1 →
                  // 1v1 final); 4-player foursomes get the single-elim
                  // bracket.  Route the Set Up button to whichever setup
                  // screen owns this group's variant.
                  final realCount = fs.realPlayers.length;
                  final isThreesome = realCount == 3;
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
                        isThreesome
                            ? '/three-person-match-setup'
                            : '/match-play-setup',
                        arguments: isThreesome
                            ? fs.id
                            : {
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
  /// True when every expected hole has a score — drives prominence + the
  /// "not all holes scored" warning in the confirm dialog.
  final bool allScored;
  /// Count of expected-but-unscored holes (for the warning copy).
  final int holesRemaining;

  const _CompleteRoundButton({
    required this.roundId,
    required this.submitting,
    this.allScored = true,
    this.holesRemaining = 0,
  });

  Future<void> _confirm(BuildContext context) async {
    final theme = Theme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(allScored ? 'Complete Round?' : 'Finish early?'),
        content: Text(
          allScored
              ? 'This will mark the round as finished and lock all scores. '
                'You can still view the final results afterwards.'
              : '${holesRemaining > 0 ? (holesRemaining == 1 ? '1 hole still has no score. ' : '$holesRemaining holes still have no score. ') : ''}'
                'Completing now will lock the round with any blank holes left '
                'blank. You can still view the results afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: allScored
                ? null
                : FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(allScored ? 'Complete Round' : 'Complete Anyway'),
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
    final theme = Theme.of(context);
    final icon = submitting
        ? SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2,
                color: allScored
                    ? theme.colorScheme.onTertiary
                    : theme.colorScheme.primary))
        : const Icon(Icons.flag_rounded);
    final label = Text(submitting ? 'Completing…' : 'Complete Round');

    // Fully scored → prominent filled button.  Otherwise keep it understated
    // (outlined) so it doesn't read as the expected next step mid-round.
    return SizedBox(
      width: double.infinity,
      child: allScored
          ? FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.tertiary,
                foregroundColor: theme.colorScheme.onTertiary,
              ),
              onPressed: submitting ? null : () => _confirm(context),
              icon: icon,
              label: label,
            )
          : OutlinedButton.icon(
              onPressed: submitting ? null : () => _confirm(context),
              icon: icon,
              label: label,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Foursome card
// ---------------------------------------------------------------------------

/// Maps a foursome's configured game to its setup screen for the launch
/// page's "Edit Configuration" action (opened in returnToHub edit mode, so it
/// pre-fills the saved settings and returns here on save).  Returns
/// (null, null) when no editable game is configured yet — extended per game
/// as each setup screen gains edit-mode support.
/// Round-level casual games (Stroke Play, Stableford) that support edit mode,
/// as (route, label) pairs.  On a single-foursome casual round these render as
/// bottom buttons on the foursome card so the hub matches the per-foursome
/// games (no separate "Game Setup" section).  Their setup screens take the
/// round id.
List<(String, String)> _roundLevelEditTargets(List<String> roundActiveGames) {
  final out = <(String, String)>[];
  if (roundActiveGames.contains('low_net_round')) {
    out.add(('/low-net-setup', 'Edit Stroke Play'));
  }
  if (roundActiveGames.contains('stableford')) {
    out.add(('/stableford-setup', 'Edit Stableford'));
  }
  return out;
}

(String?, Object?) _editConfigTarget(Set<String> fsGames, Foursome fs) {
  // Match play (Mini Singles Bracket) auto-dispatches by group size; route to
  // whichever variant is configured so the seeds/bracket can be re-edited
  // before scoring starts.
  if (fsGames.contains('match_play') ||
      fsGames.contains('three_person_match')) {
    if (fs.configuredGames.contains('three_person_match')) {
      return ('/three-person-match-setup', {'id': fs.id, 'returnToHub': true});
    }
    if (fs.configuredGames.contains('match_play')) {
      return ('/match-play-setup', {'id': fs.id, 'returnToHub': true});
    }
  }
  // Per-foursome casual games whose setup screen supports edit mode.  Keyed on
  // configured_games so the button only shows once a game actually exists.
  // (Round-level games — low net, stableford, multi-skins — and bracket games
  // — match play — are configured elsewhere and excluded here.)
  const routes = {
    'skins':      '/skins-setup',
    'nassau':     '/nassau-setup',
    'points_531': '/points-531-setup',
    'vegas':      '/vegas-setup',
    'fourball':   '/fourball-setup',
    'wolf':       '/wolf-setup',
    'rabbit':     '/rabbit-setup',
    'triple_cup': '/triple-cup-setup',
    'sixes':      '/sixes-setup',
  };
  // "Edit Configuration" targets the PRIMARY game only; side games get their
  // own buttons (see _sideGamePerFoursomeTargets).  Shown even before the game
  // is configured — the setup screen creates it on first save — so a game that
  // needs team assignment (e.g. 4-player Nassau / Vegas / Fourball, which isn't
  // auto-configured like a 1-v-1 Nassau) still gets a config affordance at the
  // hub instead of it being reachable only through "Enter Scores".
  final primary = primaryGameOf(fsGames);
  if (primary != null && routes.containsKey(primary)) {
    return (routes[primary]!, {'id': fs.id, 'returnToHub': true});
  }
  return (null, null);
}

/// Per-foursome SIDE games that need their own setup button on the foursome
/// card (the primary uses "Edit Configuration"; round-level side games like
/// Stableford use _roundLevelEditTargets). Skins is the only per-foursome side
/// game today. Shown whether or not it's been configured yet, since side-game
/// Skins no longer gets configured via Enter Scores.
List<(String, String)> _sideGamePerFoursomeTargets(Set<String> fsGames) {
  final out = <(String, String)>[];
  if (fsGames.contains('skins') && primaryGameOf(fsGames) != 'skins') {
    out.add(('/skins-setup', 'Edit Skins'));
  }
  // Spots is always a side game (capture add-on) — gets its own setup button.
  if (fsGames.contains('spots')) {
    out.add(('/spots-setup', 'Edit Spots'));
  }
  return out;
}

class _FoursomeCard extends StatelessWidget {
  final Foursome     foursome;
  final int?         myPlayerId;
  /// True when the logged-in user is admin/staff (no linked player).
  /// Admins can enter scores for any foursome and see game-setup controls.
  final bool         canManage;
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
    required this.canManage,
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
    'skins', 'sixes', 'nassau', 'match_play', 'points_531', 'wolf', 'rabbit',
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
                    subtitle: Text('Course ${m.playingHandicap}'),
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
                    subtitle: Text('Course ${m.playingHandicap}'),
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

  /// TD-only "rename group" tool — give this foursome a custom name (e.g. a
  /// team name) shown everywhere in place of "Group N".  Clearing the field
  /// resets it back to the default label.
  Future<void> _renameGroup(BuildContext context, Foursome fs) async {
    final ctrl = TextEditingController(text: fs.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 50,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Group name',
            hintText: 'Group ${fs.groupNumber}',
            helperText: 'Leave blank to reset to "Group ${fs.groupNumber}".',
          ),
          onSubmitted: (v) => Navigator.pop(dctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null || !context.mounted) return;
    try {
      final client = context.read<AuthProvider>().client;
      await client.setFoursomeName(fs.id, newName);
      onGamesChanged();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not rename group: $e')),
        );
      }
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
    final canEdit = canManage || isMyGroup || foursome.youScore;
    final theme = Theme.of(context);

    // Effective games shown for this foursome
    final effectiveGames = foursome.activeGames.isNotEmpty
        ? foursome.activeGames
        : roundActiveGames;
    final hasOverride = foursome.activeGames.isNotEmpty;

    // True when this foursome needs a bracket/setup step before score entry.
    // Cup rounds are fully configured via CupRoundSetupScreen — skip all
    // bracket-setup gates for cup foursomes.
    //
    // Match Play auto-dispatches: 3-player groups satisfy the match_play
    // requirement by configuring three_person_match instead, so treat
    // either model as "set up" when match_play is the round-wide pick.
    final fsGames = {...roundActiveGames, ...foursome.activeGames};
    final hasMatchPlayConfig =
        foursome.configuredGames.contains('match_play') ||
        foursome.configuredGames.contains('three_person_match');
    final needsBracketSetup = !isCupRound && (
        (fsGames.contains('match_play') && !hasMatchPlayConfig) ||
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
            // TD action menu — only "Configure group games" is exposed
            // today.  Roster-change actions (remove no-show, move player,
            // swap tee position) all leave stale state behind — game
            // chips, payouts, brackets, and phantom-membership
            // accounting don't recompute, and the corruption isn't
            // recoverable in place.  Until those flows re-derive every
            // dependent piece (round.active_games per foursome, payout
            // configs, bracket re-seedings) the TD's only path on a
            // roster change is to delete the round and create a fresh
            // one.  Cup rounds also hide "configure games" since games
            // are fixed at tournament setup — for them the menu is
            // empty and we hide the more-vert icon entirely.
            if (canManage && !isComplete && !isCupRound) ...[
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
                    case 'rename_group':
                      _renameGroup(context, foursome);
                      break;
                  }
                },
                itemBuilder: (_) => [
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
                  PopupMenuItem(
                    value: 'rename_group',
                    child: Row(children: [
                      Icon(Icons.edit_outlined, size: 18,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      const Flexible(child: Text('Rename group')),
                    ]),
                  ),
                ],
              ),
            ],
          ]),
          // Game chips: always shown for cup rounds; only when override active
          // for regular rounds.  Match Play auto-dispatches to Three-Person
          // Match for 3-player foursomes; drop the redundant 'match_play'
          // chip when 'three_person_match' is already present so the
          // 3-some card shows just "Three-Person Match".
          if (showGameChips) ...[
            const SizedBox(height: 6),
            Builder(builder: (_) {
              final chips = effectiveGames.toList();
              if (chips.contains('three_person_match') &&
                  chips.contains('match_play')) {
                chips.remove('match_play');
              }
              return Wrap(
                spacing: 4,
                runSpacing: 2,
                children: chips
                    .map((g) => GameChip(gameId: g, dense: true, filled: true))
                    .toList(),
              );
            }),
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
                Text('Course ${m.playingHandicap}',
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
              // Primary action on the group card → filled (dark-green / white):
              // clear hierarchy over the outlined "Edit …" buttons and high
              // contrast on the tinted card. (D-05)
              child: FilledButton.icon(
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
            // Edit Configuration — change game settings (handicap mode,
            // carryover, stake, …) before any hole is scored.  Hidden once
            // scoring starts (settings are locked), on cup rounds (configured
            // via the cup wizard), and for games whose setup screen lacks an
            // edit mode.
            if (canManage && !isComplete && !isCupRound &&
                !foursome.hasAnyScore) ...[
              Builder(builder: (context) {
                final (route, editArgs) = _editConfigTarget(
                  {...roundActiveGames, ...foursome.activeGames},
                  foursome,
                );
                if (route == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context)
                          .pushNamed(route, arguments: editArgs)
                          .then((_) {
                        onGamesChanged();
                      }),
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('Edit Configuration'),
                    ),
                  ),
                );
              }),
              // Per-foursome SIDE games (e.g. Skins running alongside a
              // primary): their own setup button, since they no longer get
              // configured through Enter Scores.  Setup takes the foursome id.
              for (final t in _sideGamePerFoursomeTargets(
                  {...roundActiveGames, ...foursome.activeGames}))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pushNamed(
                        t.$1,
                        arguments: {'id': foursome.id, 'returnToHub': true},
                      ).then((_) => onGamesChanged()),
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(t.$2),
                    ),
                  ),
                ),
              // Round-level casual games (Stroke Play, Stableford): on a
              // single-foursome casual round they appear here as bottom buttons
              // instead of a separate "Game Setup" section (that card is only
              // used for multi-foursome rounds).  Setup takes the round id.
              if (allFoursomes.length == 1)
                for (final t in _roundLevelEditTargets(roundActiveGames))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pushNamed(
                          t.$1,
                          arguments: {'id': roundId, 'returnToHub': true},
                        ).then((_) => onGamesChanged()),
                        icon: const Icon(Icons.tune, size: 18),
                        label: Text(t.$2),
                      ),
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
                title: Text(gameDisplayName(g)),
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
