import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/shared_round.dart';
import '../widgets/app_drawer.dart';
import '../widgets/cup_tally.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/shared_round_card.dart';
import 'new_round_wizard.dart';
import 'player_list_screen.dart';
import 'tournament_low_net_setup_screen.dart';
import 'setup_round_players_screen.dart';
import 'tournament_leaderboard_screen.dart';
import 'ryder_cup_draft_screen.dart';
import 'ryder_cup_scoreboard_screen.dart';
import 'cup_round_setup_screen.dart';
import 'cup_tee_times_screen.dart';

class TournamentListScreen extends StatefulWidget {
  const TournamentListScreen({super.key});

  @override
  State<TournamentListScreen> createState() => _TournamentListScreenState();
}

class _TournamentListScreenState extends State<TournamentListScreen>
    with WidgetsBindingObserver {
  List<Tournament>? _tournaments;
  /// Tournament rounds in OTHER accounts a friend/TD added me to.
  List<ScoringRound> _shared = [];
  /// Tournaments in OTHER accounts I was invited to WATCH (read-only). Shown in
  /// an "Observing" section so it's clear I'm watching, not playing. (Replaces
  /// the old standalone "Shared with me" screen for tournaments.)
  List<SharedRoundSummary> _observing = [];
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;
  bool    _showCompleted = false;   // false = Active, true = Completed
  bool    _didAutoRedirect = false; // first-load redirect to casual rounds
                                    // when the user has no active tournaments

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Foregrounding the app (warm launch from the home screen) doesn't re-run
  /// initState — the widget is still mounted — so without this the list would
  /// show whatever was loaded last time it was visible. Silently re-fetch on
  /// resume so a tournament you were added to while the app was backgrounded
  /// appears without a manual pull-to-refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(silent: true);
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

  /// [silent] refreshes WITHOUT the full-screen spinner — used on app resume so
  /// foregrounding doesn't flash a loader over the existing list.
  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getTournaments();
      // Tournament rounds a friend/TD added me to (cross-account). Best-effort.
      List<ScoringRound> shared = [];
      try {
        shared = (await client.getPlayingForMe())
            .where((r) => r.isTournament)
            .toList();
      } catch (_) {/* ignore — show my own tournaments regardless */}

      // Tournaments I was invited to WATCH (cross-account, read-only).
      List<SharedRoundSummary> observing = [];
      try {
        observing = (await client.getSharedRounds())
            .where((r) => r.isTournament)
            .toList();
      } catch (_) {/* ignore — observed tournaments are non-critical */}
      if (mounted) {
        setState(() {
          _tournaments = data;
          _shared = shared;
          _observing = observing;
        });
      }

      // First-load only: if the user has no active tournaments, drop them
      // straight onto the casual rounds list.  Use push (not replace) so the
      // back-arrow still brings them back here to see completed tournaments
      // or create a new one.
      if (!_didAutoRedirect && mounted) {
        _didAutoRedirect = true;
        final hasActive = data.any((t) => !_isComplete(t)) ||
            shared.any((r) => r.status != 'complete');
        if (!hasActive) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // Don't auto-redirect to the casual-rounds hub if we've already
            // been navigated off the tournaments screen. On a cold launch from
            // a watch link, the deep-link handler pushes the round leaderboard
            // on top of us right around now; pushing casual-rounds here would
            // bury the leaderboard the user tapped in to see. isCurrent is
            // false once anything (the leaderboard) sits on top of /tournaments.
            if (ModalRoute.of(context)?.isCurrent != true) return;
            Navigator.of(context).pushNamed('/casual-rounds');
          });
        }
      }
    } catch (e) {
      // A silent (background) refresh that fails leaves the existing list in
      // place rather than replacing it with a full-screen error.
      if (mounted && !silent) setState(() { _error = friendlyError(e); _networkError = isNetworkError(e); });
    } finally {
      if (mounted && !silent) setState(() { _loading = false; });
    }
  }

  /// Cup tournaments don't have their own dedicated leaderboard screen
  /// any more — both the "Championship Leaderboard" and "Cup Scoreboard"
  /// buttons drop the user onto the latest non-pending round's
  /// LeaderboardScreen with the Cup tab pre-selected.  If no rounds have
  /// been created yet, fall through to the standings page so the user
  /// still has somewhere to land.
  void _openCupTab(BuildContext context, Tournament t) {
    final rounds = t.rounds.toList()
      ..sort((a, b) => a.roundNumber.compareTo(b.roundNumber));
    if (rounds.isEmpty) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RyderCupScoreboardScreen(
          tournamentId  : t.id,
          tournamentName: t.name,
        ),
      ));
      return;
    }
    final cupRound = rounds.lastWhere(
      (r) => r.status != 'pending',
      orElse: () => rounds.first,
    );
    Navigator.of(context).pushNamed(
      '/leaderboard',
      arguments: {
        'roundId'      : cupRound.id,
        'initialTabKey': '__bandon_cup__',
      },
    );
  }

  /// Dialog for swapping a round's cup game without rebuilding its
  /// foursomes.  Lets the user pick both the new game AND the
  /// per-segment point value — necessary because different games
  /// award different numbers of segments per foursome and the user
  /// often wants to scale up / down to keep the round total
  /// comparable (Singles Nassau has 6 segments/foursome, Singles 18
  /// has 2; if both should be worth the same total cup points,
  /// Singles 18's per-segment value needs to be 3× Singles Nassau's).
  ///
  /// Backend rejects irish_rumble / match_play targets — for those
  /// the user has to go through the full Set Up Cup Round wizard.
  Future<void> _showChangeCupGameSheet(
      RoundSummary round, Tournament t) async {
    final result = await showDialog<_CupGameChange>(
      context: context,
      builder: (_) => _ChangeCupGameDialog(roundNumber: round.roundNumber),
    );
    if (result == null) return;

    final client = context.read<AuthProvider>().client;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Changing game…'),
        ]),
      ),
    );
    try {
      final res = await client.postRyderCupChangeGame(
        round.id,
        gameType:   result.gameType,
        pointValue: result.pointValue,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      final changed = res['changed'] as int? ?? 0;
      final skipped = (res['skipped'] as List? ?? []).cast<int>();
      final msg = StringBuffer(
        'R${round.roundNumber} → ${_gameLabelFor(result.gameType)}'
        ' @ ${result.pointValue} pts/seg'
        ' · $changed foursome${changed == 1 ? '' : 's'} updated',
      );
      if (skipped.isNotEmpty) {
        msg.write('.  Skipped groups: ${skipped.join(", ")}');
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg.toString()),
        backgroundColor: Colors.green.shade700,
      ));
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  String _gameLabelFor(String code) {
    switch (code) {
      case 'nassau':         return 'Four Ball';
      case 'quota_nassau':   return 'Four Ball Quota';
      case 'singles_nassau': return 'Singles Nassau';
      case 'singles_18':     return 'Singles 18';
      default:               return code;
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
      floatingActionButton: !auth.isAdmin ? null :
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
    final shared = _shared.where((r) {
      return _showCompleted ? r.status == 'complete' : r.status != 'complete';
    }).toList();
    // Tournaments I'm only watching — move to Completed when the event finishes.
    final observing = _observing.where((r) {
      return _showCompleted ? r.status == 'complete' : r.status != 'complete';
    }).toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
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
        child: (filtered.isEmpty && shared.isEmpty && observing.isEmpty)
            ? Center(child: Text(_showCompleted
                ? 'No completed tournaments.'
                : 'No active tournaments.'))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (shared.isNotEmpty) ...[
                      _sectionHeader('Shared with you'),
                      for (final r in shared)
                        SharedRoundCard(
                          round: r,
                          onTap: () async {
                            await openSharedRound(context, r.id);
                            _load();
                          },
                        ),
                    ],
                    if (observing.isNotEmpty) ...[
                      _sectionHeader('Observing'),
                      for (final r in observing)
                        _observingTournamentCard(r),
                    ],
                    if ((shared.isNotEmpty || observing.isNotEmpty) &&
                        filtered.isNotEmpty)
                      _sectionHeader('Your tournaments'),
                    for (final t in filtered) _tournamentCard(t),
                  ],
                ),
              ),
      ),
    ]);
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
        ),
      );

  /// A tournament I'm only WATCHING (read-only). Tapping opens the read-only
  /// leaderboard, never the score-entry round screen.
  Widget _observingTournamentCard(SharedRoundSummary r) {
    final title = r.courseName.isEmpty ? r.groupLabel : r.courseName;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Halved.pine.withValues(alpha: 0.10),
          foregroundColor: Halved.pine,
          child: const Icon(Icons.visibility_outlined),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('Observing · ${r.groupLabel}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: r.status == 'in_progress'
            ? const HalvedLivePill()
            : const Icon(Icons.chevron_right, color: Halved.muted),
        onTap: () async {
          await openWatchedRound(context, r);
          _load();
        },
      ),
    );
  }

  Widget _tournamentCard(Tournament t) {
    return _TournamentCard(
            tournament       : t,
            isStaff          : context.read<AuthProvider>().isAdmin,
            isComplete       : _isComplete(t),
            onRoundTap       : (roundId) =>
                Navigator.of(context).pushNamed('/round', arguments: roundId),
            onSetupRound     : (roundId) => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => SetupRoundPlayersScreen(roundId: roundId)))
                .then((_) { if (mounted) _load(); }),
            // For Cup tournaments, both "Championship Leaderboard" and
            // "Cup Scoreboard" buttons land on the per-round Cup tab —
            // the standings page on its own is duplicative.  Local
            // closure picks the latest non-pending round; falls back to
            // round 1, then to RyderCupScoreboardScreen if no rounds at
            // all have been created.
            onViewLeaderboard: () {
              if (t.activeGames.contains('team_cup')) {
                _openCupTab(context, t);
              } else {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TournamentLeaderboardScreen(
                    tournamentId  : t.id,
                    tournamentName: t.name,
                  ),
                ));
              }
            },
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
            onOpenCupScoreboard: () => _openCupTab(context, t),
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
                      cupGroupCounts  : round.cupGroupCounts,
                    )))
                .then((_) { if (mounted) _load(); }),
            onEditTeeTimes: (round) => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) =>
                        CupTeeTimesScreen(roundId: round.id)))
                .then((_) { if (mounted) _load(); }),
            onChangeCupGame: (round) => _showChangeCupGameSheet(round, t),
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
  final void Function(RoundSummary round) onChangeCupGame;
  final void Function(RoundSummary round) onEditTeeTimes;
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
    required this.onChangeCupGame,
    required this.onEditTeeTimes,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasInProgress =
        tournament.rounds.any((r) => r.status == 'in_progress');
    final isCup = tournament.activeGames.contains('team_cup');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Header: name · (course ·) date · card menu ─────────────────────
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
                    // Course and date belong to the round line; on a cup the
                    // date prints once here rather than twice.
                    Text(
                      (isCup && tournament.rounds.isNotEmpty)
                          ? '${tournament.rounds.first.courseName} · ${tournament.startDate}'
                          : tournament.startDate,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              // Delete is a card-level action — for cups it lives in the ⋮ menu
              // so a destructive action isn't the loudest pixel on the card.
              if (isStaff && isCup)
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert,
                      color: hasInProgress
                          ? Colors.orange
                          : Theme.of(context).colorScheme.onSurfaceVariant),
                  tooltip: 'Tournament actions',
                  onSelected: (v) { if (v == 'delete') onDelete(); },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(children: const [
                        Icon(Icons.delete_outline),
                        SizedBox(width: 12),
                        Text('Delete tournament'),
                      ]),
                    ),
                  ],
                )
              else if (isStaff)
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

          if (isCup)
            ..._cupHub(context)
          else ...[
            // ── Non-cup tournaments ──────────────────────────────────────────
            if (tournament.rounds.isNotEmpty) ...[
              const Divider(height: 20),
              ...tournament.rounds.map((r) => r.status == 'pending' && isStaff
                  ? _PendingRoundTile(round: r, onSetup: () => onSetupRound(r.id))
                  : _RoundTile(round: r, onTap: () => onRoundTap(r.id))),
              // Tee times are not a cup thing — an individual tournament sends
              // groups off in an order too. The screen was always generic (it
              // just PATCHes foursome.tee_time); it was only ever REACHABLE
              // from the cup hub.
              if (isStaff && !isComplete)
                ...tournament.rounds
                    .where((r) => r.status != 'pending')
                    .map((r) => _ActionButton(
                          icon : Icons.schedule_outlined,
                          label: tournament.rounds.length > 1
                              ? 'R${r.roundNumber} · Edit tee times'
                              : 'Edit tee times',
                          onTap: () => onEditTeeTimes(r),
                        )),
            ],
            if (tournament.activeGames.isNotEmpty) ...[
              const Divider(height: 16),
              _ActionButton(
                icon : Icons.emoji_events_outlined,
                label: tournament.activeGames.contains('stableford_championship')
                    ? 'Stableford Championship Leaderboard'
                    : tournament.activeGames.contains('low_net')
                        ? 'Stroke Play Championship Leaderboard'
                        : 'Championship Leaderboard',
                onTap: onViewLeaderboard,
              ),
            ],
            if (isStaff && !isComplete &&
                tournament.activeGames.contains('low_net'))
              _ActionButton(
                icon : Icons.settings_outlined,
                label: 'Configure Stroke Play Championship',
                onTap: onConfigureLowNet,
              ),
          ],
        ]),
      ),
    );
  }

  RoundSummary? _firstRoundWhere(bool Function(RoundSummary) test) {
    for (final r in tournament.rounds) {
      if (test(r)) return r;
    }
    return null;
  }

  /// The cup-hub body: a state line, one adaptive primary action, two quiet nav
  /// buttons, and a collapsed round-setup disclosure (TD only).  Replaces the
  /// six equal-weight rows of the old card.
  List<Widget> _cupHub(BuildContext context) {
    final theme        = Theme.of(context);
    final rounds       = tournament.rounds;
    final inProgress   = _firstRoundWhere((r) => r.status == 'in_progress');
    final firstPending = _firstRoundWhere((r) => r.status == 'pending');
    final multiRound   = rounds.length > 1;

    // The card carries state — "which round, how far" without a tap.  (The live
    // team tally + clinch bar need a per-card standings fetch; deferred.)
    final String statusText;
    if (inProgress != null) {
      statusText = multiRound
          ? 'Round ${inProgress.roundNumber} in progress'
          : 'Round in progress';
    } else if (isComplete) {
      statusText = 'Cup complete';
    } else if (firstPending != null) {
      statusText = multiRound
          ? 'Round ${firstPending.roundNumber} — not started'
          : 'Not started';
    } else {
      statusText = 'Ready to draft';
    }

    // One primary action — always proposes the next thing.
    final IconData primaryIcon;
    final String   primaryLabel;
    final VoidCallback primaryTap;
    if (inProgress != null) {
      primaryIcon  = Icons.edit_note;
      primaryLabel = 'Enter Scores';
      primaryTap   = () => onRoundTap(inProgress.id);
    } else if (isComplete) {
      primaryIcon  = Icons.emoji_events_outlined;
      primaryLabel = 'View Result';
      primaryTap   = onOpenCupScoreboard;
    } else if (firstPending != null && isStaff) {
      primaryIcon  = Icons.tune_outlined;
      primaryLabel = multiRound
          ? 'Set Up Round ${firstPending.roundNumber}'
          : 'Set Up Cup Round';
      primaryTap   = () => onSetupCupRound(firstPending);
    } else {
      // No live round and (for a non-TD) nothing to set up → the scoreboard is
      // the useful landing.
      primaryIcon  = Icons.emoji_events_outlined;
      primaryLabel = 'View Leaderboard';
      primaryTap   = onOpenCupScoreboard;
    }

    return [
      // Live cup tally + clinch bar — "are we up, how close" without a tap.
      CupTallyLoader(
        tournamentId: tournament.id,
        padding: const EdgeInsets.only(top: 12, bottom: 4),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Icon(
          inProgress != null
              ? Icons.play_circle_outline
              : isComplete
                  ? Icons.emoji_events_outlined
                  : Icons.schedule,
          size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(statusText, style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: primaryTap,
          icon: Icon(primaryIcon, size: 18),
          label: Text(primaryLabel),
        ),
      ),
      const SizedBox(height: 8),
      // Navigation — Leaderboard and Scoreboard are one destination now.
      Row(children: [
        Expanded(child: OutlinedButton.icon(
          onPressed: onOpenCupScoreboard,
          icon: const Icon(Icons.emoji_events_outlined, size: 18),
          label: const Text('Leaderboard'),
        )),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(
          onPressed: onOpenCupDraft,
          icon: const Icon(Icons.groups_outlined, size: 18),
          label: const Text('Draft & Teams'),
        )),
      ]),
      // Round-scoped setup collapses into a disclosure — where a TD looks and a
      // player never does.
      if (isStaff && !isComplete) ...[
        const SizedBox(height: 4),
        Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(left: 8, bottom: 4),
            title: Text('Round setup', style: theme.textTheme.labelLarge),
            children: [
              if (tournament.activeGames.contains('low_net'))
                _ActionButton(
                  icon : Icons.settings_outlined,
                  label: 'Configure Stroke Play Championship',
                  onTap: onConfigureLowNet,
                ),
              ...rounds.expand((r) => [
                _ActionButton(
                  icon : Icons.tune_outlined,
                  label: multiRound
                      ? 'R${r.roundNumber} · Set up cup round'
                      : 'Set up cup round',
                  onTap: () => onSetupCupRound(r),
                ),
                // Live tee-time edit — only meaningful once the round's groups
                // exist (setup done), and pointless while it's still pending.
                if (r.status != 'pending')
                  _ActionButton(
                    icon : Icons.schedule_outlined,
                    label: multiRound
                        ? 'R${r.roundNumber} · Edit tee times'
                        : 'Edit tee times',
                    onTap: () => onEditTeeTimes(r),
                  ),
                _ActionButton(
                  icon : Icons.swap_horiz_outlined,
                  label: multiRound
                      ? 'R${r.roundNumber} · Change cup game'
                      : 'Change cup game',
                  onTap: () => onChangeCupGame(r),
                ),
                if (r.status != 'pending')
                  _ActionButton(
                    icon : Icons.calculate_outlined,
                    label: multiRound
                        ? 'R${r.roundNumber} · Recalculate cup points'
                        : 'Recalculate cup points',
                    onTap: () => onRecalculateCupPoints(r),
                  ),
              ]),
            ],
          ),
        ),
      ],
    ];
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


/// Result of the Change Cup Game dialog.
class _CupGameChange {
  final String gameType;
  /// Points per segment, sent as a string so the backend's
  /// Decimal parser doesn't lose precision on values like "0.5".
  final String pointValue;

  const _CupGameChange({required this.gameType, required this.pointValue});
}

/// Picks the new cup game AND the per-segment point value in one
/// step.  The selected game's segments-per-foursome count is shown
/// alongside a "to keep the round-total comparable" hint, so admins
/// can scale points up or down accordingly.
class _ChangeCupGameDialog extends StatefulWidget {
  final int roundNumber;
  const _ChangeCupGameDialog({required this.roundNumber});

  @override
  State<_ChangeCupGameDialog> createState() => _ChangeCupGameDialogState();
}

class _ChangeCupGameDialogState extends State<_ChangeCupGameDialog> {
  /// Per-game segments awarded per foursome — see
  /// services/cup_standings.GAME_MULTIPLIERS on the backend.  Used
  /// to compute the "equivalent" point value the user might want.
  static const _segments = <String, int>{
    'nassau':         3,
    'quota_nassau':   3,
    'singles_nassau': 6,
    'singles_18':     2,
  };
  static const _labels = <String, String>{
    'nassau':         'Four Ball (Nassau)',
    'quota_nassau':   'Four Ball Quota',
    'singles_nassau': 'Singles Nassau (1v1)',
    'singles_18':     'Singles 18 (1v1 overall)',
  };

  String _game  = 'nassau';
  final _pvCtrl = TextEditingController(text: '1.00');
  String? _err;

  @override
  void dispose() {
    _pvCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final segs = _segments[_game] ?? 0;
    final pv   = double.tryParse(_pvCtrl.text.trim()) ?? 0;
    final foursomeTotal = pv * segs;

    return AlertDialog(
      title: Text('Change R${widget.roundNumber} Cup Game'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Foursomes and team assignments stay put.  The '
              'per-foursome game model for this round is replaced.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            const Text('New cup game',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final entry in _labels.entries)
              RadioListTile<String>(
                value: entry.key,
                groupValue: _game,
                title: Text(entry.value),
                subtitle: Text(
                  '${_segments[entry.key]} segment'
                  '${_segments[entry.key] == 1 ? '' : 's'}/foursome',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onChanged: (v) => setState(() {
                  if (v != null) _game = v;
                }),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            const SizedBox(height: 8),
            GolfTextField(
              controller: _pvCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              label: 'Points per segment',
              errorText: _err,
              helper: foursomeTotal > 0
                  ? '$segs × ${pv.toStringAsFixed(2)} = '
                    '${foursomeTotal.toStringAsFixed(2)} cup pts per '
                    'foursome'
                  : null,
              onChanged: (_) => setState(() { _err = null; }),
            ),
            const SizedBox(height: 12),
            // Helper card with the scaling hint.  Pulled out so it's
            // obvious — different cup games hand out different point
            // counts per foursome, and re-rating point_value is the
            // lever to keep the round's contribution to the cup
            // total in line with the others.
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer
                    .withOpacity(0.45),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Per-foursome cup points by game',
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    'Four Ball: 3·pv  ·  4-Ball Quota: 3·pv  ·  '
                    'Singles Nassau: 6·pv  ·  Singles 18: 2·pv',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'To roughly match Singles Nassau\'s 6 pts/foursome '
                    '(at pv = 1.0), use pv ≈ 2.00 for Four Ball /'
                    ' Quota or 3.00 for Singles 18.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final v = _pvCtrl.text.trim();
            final d = double.tryParse(v);
            if (d == null || d <= 0) {
              setState(() => _err = 'Enter a positive number');
              return;
            }
            Navigator.of(context).pop(_CupGameChange(
              gameType:   _game,
              pointValue: v,
            ));
          },
          child: const Text('Change Game'),
        ),
      ],
    );
  }
}
