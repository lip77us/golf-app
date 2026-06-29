import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../utils/route_observer.dart';
import '../utils/shared_round.dart';
import '../widgets/app_drawer.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import 'casual_round_screen.dart';
import 'player_list_screen.dart';

/// Lists the authenticated player's casual rounds with a toggle between
/// Active (in_progress) and Completed views.
class CasualRoundsListScreen extends StatefulWidget {
  const CasualRoundsListScreen({super.key});

  @override
  State<CasualRoundsListScreen> createState() => _CasualRoundsListScreenState();
}

class _CasualRoundsListScreenState extends State<CasualRoundsListScreen>
    with RouteAware {
  List<CasualRoundSummary>? _rounds;
  /// Rounds in OTHER accounts a friend added me to as a player (any size).
  List<ScoringRound> _shared = [];
  /// Casual rounds in OTHER accounts I was invited to WATCH (read-only). Shown
  /// on this same list, flagged "Observing" so it's clear I'm watching, not
  /// playing. (Replaces the old standalone "Shared with me" screen.)
  List<SharedRoundSummary> _observing = [];
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;
  bool    _showCompleted = false;   // false = Active, true = Completed
  /// True once we know the account has at least one casual round (active OR
  /// completed). Gates the brand-new "Set up your first round" onboarding CTA so
  /// it doesn't reappear on the empty Active tab after a round is completed.
  bool    _hasAnyRound  = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// Returning to this screen (a round/score screen on top was popped) — the
  /// round's currentHole/status may have changed while away, which drives where
  /// a tap routes (hub vs straight to scoring).  Silently refresh so the next
  /// tap is consistent without a manual pull-to-refresh.
  @override
  void didPopNext() {
    _load(silent: true);
  }

  /// [silent] refreshes the data WITHOUT the full-screen spinner — used when
  /// returning to this screen (so the list silently reflects scores entered
  /// while away) instead of flashing a loader on every back-navigation.
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() { _loading = true; _error = null; });
    }
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getCasualRounds(
        status: _showCompleted ? 'complete' : 'in_progress',
      );
      // Rounds a friend/TD added me to as a player (cross-account), so they
      // show in my active list. Best-effort: a failure here must not break my
      // own rounds list.
      List<ScoringRound> shared = [];
      try {
        shared = (await client.getPlayingForMe())
            .where((r) => !r.isTournament)
            .toList();
      } catch (_) {/* ignore — show own rounds regardless */}

      // Casual rounds I was invited to WATCH (cross-account, read-only). Same
      // best-effort treatment; status filtering happens per-tab below.
      List<SharedRoundSummary> observing = [];
      try {
        observing = (await client.getSharedRounds())
            .where((r) => !r.isTournament)
            .toList();
      } catch (_) {/* ignore — observed rounds are non-critical */}

      // Does the account have ANY casual round? If the current tab is non-empty
      // we already know; if it's empty, check the other status before concluding
      // the account is brand-new (so the onboarding CTA only shows for a truly
      // empty account, not just an empty Active tab after completing a round).
      bool hasAny = data.isNotEmpty;
      if (!hasAny) {
        try {
          final other = await client.getCasualRounds(
            status: _showCompleted ? 'in_progress' : 'complete');
          hasAny = other.isNotEmpty;
        } catch (_) {
          hasAny = true; // unknown → don't show the "first round" CTA spuriously
        }
      }
      if (mounted) {
        setState(() {
          _rounds = data;
          _shared = shared;
          _observing = observing;
          _hasAnyRound = hasAny;
        });
      }
    } catch (e) {
      // A silent (background) refresh that fails leaves the existing list in
      // place rather than replacing it with a full-screen error.
      if (mounted && !silent) {
        setState(() {
          _error        = friendlyError(e);
          _networkError = isNetworkError(e);
        });
      }
    } finally {
      if (mounted && !silent) setState(() { _loading = false; });
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
      appBar: GolfAppBar(
        title: 'Casual Rounds',
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      drawer: AppDrawer(
        playerName: auth.player?.name,
        onTournamentsTap: () {
          // Tournaments is the route below us in the stack (splash pushed it
          // first).  Close the drawer, then pop back to it.
          Navigator.of(context).pop();
          Navigator.of(context)
              .popUntil((r) => r.settings.name == '/tournaments' || r.isFirst);
        },
        // Already on casual rounds — the entry just closes the drawer.
        onCasualRoundsTap: () => Navigator.of(context).pop(),
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

    // Completed rounds → round overview (shows leaderboard button etc.).
    // Not-yet-started rounds → also the overview, so the user can review and
    // edit the setup (tees, players, game config) instead of jumping straight
    // into scoring.  currentHole == 0 means no scores have been entered yet.
    if (round.status == 'complete' || fsId == null || round.currentHole == 0) {
      await nav.pushNamed('/round', arguments: round.id);
      return;
    }

    // Multi-group skins is a MULTI-foursome round: open the round overview so
    // the user picks their own group to score (avoids auto-jumping to the wrong
    // group) and the TD gets the per-foursome "Set scorer" menu there.
    if (round.activeGames.contains('multi_skins')) {
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
    } else if (round.activeGames.contains('vegas')) {
      route = '/vegas-setup';          // will redirect to /score-entry if already started
    } else if (round.activeGames.contains('fourball')) {
      route = '/fourball-setup';       // will redirect to /score-entry if already started
    } else if (round.activeGames.contains('nassau')) {
      route = '/nassau-setup';         // will redirect to /score-entry if already started
    } else if (round.activeGames.contains('wolf')) {
      route = '/wolf-setup';           // will redirect to /wolf if already started
    } else if (round.activeGames.contains('rabbit')) {
      route = '/rabbit-setup';         // will redirect to /rabbit if already started
    } else {
      route = '/score-entry';          // stroke play, stableford, or multi-game combo
    }
    await nav.pushNamed(route, arguments: fsId);

    // Immediately show a loading spinner so the stale "Not started" list is
    // hidden while we wait for any pending score syncs to flush.
    if (mounted) setState(() { _loading = true; });

    // Wait for any pending score syncs to drain so current_hole is accurate
    // before reloading the list from the server.
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
    final shared = _shared.where((r) {
      return _showCompleted ? r.status == 'complete' : r.status != 'complete';
    }).toList();
    // Dedupe: if I'm both a player and a watcher of the same round, show it once
    // as a PLAYED round (playing supersedes watching — no eyeball, opens to score
    // entry). Build the played-id set from the full lists, not the tab-filtered
    // ones, so the suppression holds regardless of tab.
    final playedIds = <int>{
      for (final r in (_rounds ?? [])) r.id,
      for (final r in _shared) r.id,
    };
    // Observed rounds follow the same tab rule: when the round completes it
    // drops off Active and shows under Completed, just like my own rounds.
    final observing = _observing.where((r) {
      if (playedIds.contains(r.id)) return false;
      return _showCompleted ? r.status == 'complete' : r.status != 'complete';
    }).toList();
    if (rounds.isEmpty && shared.isEmpty && observing.isEmpty) {
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
            // Onboarding CTA only for a truly empty account (no rounds at all) —
            // not just an empty Active tab when completed rounds exist.
            if (!_showCompleted && !_hasAnyRound) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.of(context).pushNamed('/onboarding');
                  _load();
                },
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Set up your first round'),
              ),
            ],
          ],
        ),
      );
    }

    // One date-sorted list mixing my own rounds and ones a friend started and
    // added me to — no sections; each card is flagged with who started it.
    String fmtDate(String iso) {
      final d = DateTime.tryParse(iso);
      return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
    }
    final items = <_RoundItem>[
      for (final r in rounds)
        _RoundItem(
          sortDate:       DateTime.tryParse(r.date),
          dateLabel:      fmtDate(r.date),
          courseName:     r.courseName,
          activeGames:    r.activeGames,
          isEighteenHoleMatch: r.isEighteenHoleMatch,
          isCompleted:    r.status == 'complete',
          currentHole:    r.currentHole,
          startedByMe:    true,
          startedByLabel: 'you',
          people:         r.players.map((p) => p.name).join(', '),
          onTap: () async { await _openRound(r); _load(); },
          onDelete: (myId != null && r.createdByPlayerId == myId)
              ? () => _confirmDelete(r)
              : null,
        ),
      for (final r in shared)
        _RoundItem(
          sortDate:       DateTime.tryParse(r.date),
          dateLabel:      fmtDate(r.date),
          courseName:     r.courseName,
          activeGames:    r.activeGames,
          isCompleted:    r.status == 'complete',
          currentHole:    null, // ScoringRound carries status, not hole progress
          startedByMe:    false,
          startedByLabel: r.groupLabel,
          people:         '',
          onTap: () async { await openSharedRound(context, r.id); _load(); },
          onDelete: null,
        ),
      for (final r in observing)
        _RoundItem(
          sortDate:       DateTime.tryParse(r.date),
          dateLabel:      fmtDate(r.date),
          courseName:     r.courseName,
          activeGames:    r.activeGames,
          isCompleted:    r.status == 'complete',
          currentHole:    null,
          startedByMe:    false,
          startedByLabel: r.groupLabel,
          people:         '',
          isObserving:    true,
          onTap: () async { await openWatchedRound(context, r); _load(); },
          onDelete: null,
        ),
    ]..sort((a, b) =>
        (b.sortDate ?? DateTime(0)).compareTo(a.sortDate ?? DateTime(0)));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        itemCount: items.length,
        itemBuilder: (_, i) => _RoundCard(item: items[i]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card widget
// ---------------------------------------------------------------------------

/// A normalized row for the casual list, covering both my own rounds and rounds
/// a friend started and added me to. [currentHole] is null for friend rounds
/// (the shared payload carries status, not hole progress).
class _RoundItem {
  final DateTime?    sortDate;
  final String       dateLabel;
  final String       courseName;
  final List<String> activeGames;
  /// True when this round's Nassau is really the "18-Hole Match" shortcut.
  final bool         isEighteenHoleMatch;
  final bool         isCompleted;
  final int?         currentHole;
  final bool         startedByMe;
  final String       startedByLabel; // "you", or the friend's name
  final String       people;         // player names (own rounds) or ''
  /// True when I'm only WATCHING this round (read-only), not playing in it.
  final bool         isObserving;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _RoundItem({
    required this.sortDate,
    required this.dateLabel,
    required this.courseName,
    required this.activeGames,
    this.isEighteenHoleMatch = false,
    required this.isCompleted,
    required this.currentHole,
    required this.startedByMe,
    required this.startedByLabel,
    required this.people,
    this.isObserving = false,
    required this.onTap,
    this.onDelete,
  });
}

class _RoundCard extends StatelessWidget {
  final _RoundItem item;
  const _RoundCard({required this.item});

  String _progressLabel() {
    if (item.isCompleted) return 'Complete';
    final h = item.currentHole;
    if (h == null) return 'In progress';     // friend round — no hole count
    if (h == 0)    return 'Not started';
    if (h == 18)   return 'Hole 18';
    return 'Through hole $h';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gameLabels = gamesDisplayLabel(item.activeGames,
        isEighteenHoleMatch: item.isEighteenHoleMatch);

    // The flag that replaced the section headers: who started this round, or —
    // for a round I'm only watching — that I'm observing it (not playing).
    final flagColor = item.isObserving
        ? theme.colorScheme.secondary
        : (item.startedByMe
            ? theme.colorScheme.primary
            : theme.colorScheme.tertiary);
    final flagText = item.isObserving
        ? 'Observing${item.startedByLabel.isEmpty ? '' : ' · ${item.startedByLabel}'}'
        : (item.startedByMe
            ? 'Started by you'
            : 'Started by ${item.startedByLabel}');
    final flagIcon = item.isObserving
        ? Icons.visibility_outlined
        : (item.startedByMe ? Icons.person_outline : Icons.group_outlined);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Course + date
                    Row(children: [
                      Expanded(
                        child: Text(
                          item.courseName,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        item.dateLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ]),
                    const SizedBox(height: 4),

                    // Games + progress
                    Row(children: [
                      if (gameLabels.isNotEmpty) ...[
                        Icon(Icons.casino_outlined,
                            size: 13, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(gameLabels,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.primary)),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Icon(
                        item.isCompleted
                            ? Icons.check_circle_outline
                            : Icons.flag_outlined,
                        size: 13,
                        color: item.isCompleted
                            ? Colors.green
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _progressLabel(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: item.isCompleted
                              ? Colors.green
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),

                    // Started-by flag (chip)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: flagColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(flagIcon, size: 12, color: flagColor),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            flagText,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: flagColor,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ]),
                    ),

                    // Players (own rounds only)
                    if (item.people.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(children: [
                        Icon(Icons.people_outline,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            item.people,
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),

              // Watching indicator — a clear eyeball so a round I only observe
              // is obviously distinct from one I play in (even one a friend
              // started). Observed rounds never have a delete button.
              if (item.isObserving)
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 6, left: 4),
                  child: Tooltip(
                    message: "You're watching this round",
                    child: Icon(Icons.visibility,
                        color: theme.colorScheme.secondary, size: 24),
                  ),
                ),

              // Delete icon — only shown to the round creator.
              if (item.onDelete != null)
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: theme.colorScheme.error),
                  tooltip: 'Delete round',
                  onPressed: item.onDelete,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
