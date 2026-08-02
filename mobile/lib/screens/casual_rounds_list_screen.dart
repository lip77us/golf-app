import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import '../ui_labels.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../sync/sync_service.dart';
import '../utils/route_observer.dart';
import '../utils/shared_round.dart';
import '../widgets/app_drawer.dart';
import '../widgets/error_view.dart';
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
    with RouteAware, WidgetsBindingObserver {
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
  /// Completed-tab watched-round filter. Default OFF ("Rounds I played") so
  /// watched rounds are hidden until the user opts in. Client-side over the
  /// already-loaded list. Active is deliberately unfiltered (no row shown).
  bool    _includeWatched = false;
  /// True once we know the account has at least one casual round (active OR
  /// completed). Gates the brand-new "Set up your first round" onboarding CTA so
  /// it doesn't reappear on the empty Active tab after a round is completed.
  bool    _hasAnyRound  = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// Foregrounding the app (warm launch from the home screen) does NOT re-run
  /// initState — the widget is still mounted from before — so without this the
  /// list would show whatever was loaded last time it was visible. Silently
  /// re-fetch on resume so a round that started while the app was backgrounded
  /// (e.g. a partner adding you to a casual game) shows up without a manual
  /// pull-to-refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(silent: true);
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
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Halved.deepPine),
        title: Text(kCasualRoundsLabel, style: Halved.appBarTitle()),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Halved.pine),
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
      // Persistent "New Casual Round" ghost link along the bottom — only on the
      // Active tab (no new rounds from the Completed tab).
      bottomNavigationBar: _showCompleted ? null : _buildNewRoundBar(),
      body: Column(
        children: [
          // ── Active / Completed toggle ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: HalvedSegmented<bool>(
              selected: _showCompleted,
              onChanged: _onToggle,
              segments: const [
                (value: false, label: 'Active',
                    icon: Icons.play_circle_outline),
                (value: true,  label: 'Completed',
                    icon: Icons.check_circle_outline),
              ],
            ),
          ),
          // ── List ──
          Expanded(child: _buildBody(myId)),
        ],
      ),
    );
  }

  /// Bottom ghost link that opens the new-casual-round wizard.
  Widget _buildNewRoundBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: TextButton.icon(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CasualRoundScreen()),
            );
            _load();
          },
          icon: const Icon(Icons.add, color: Halved.pine),
          label: Text('New Round',
              style: Halved.body(weight: FontWeight.w700, color: Halved.pine)),
        ),
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

    // In-progress: land on the round overview (hub), NOT straight into scoring.
    // The hub's foursome cards each have a prominent "Enter Scores" button, and
    // keeping the hub reachable after scoring starts is what lets you still
    // reach per-foursome actions that live there — "Link to a Skins pool",
    // "Set scorer", "Edit configuration". Jumping straight to the game screen
    // hid those once a hole was posted (see the multi-skins linking case).
    await nav.pushNamed('/round', arguments: round.id);

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

  /// Branded empty state — pin-in-hole mark in a sage badge, headline, and (on
  /// the Active tab) the bright-mint New Casual Round CTA.
  Widget _buildEmptyState() {
    final completed = _showCompleted;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 116, height: 116,
              decoration: BoxDecoration(
                color: Halved.pine.withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: completed
                  ? const Icon(Icons.check_circle_outline,
                      size: 52, color: Halved.pine)
                  : SvgPicture.asset('assets/icon/halved_mark.svg', height: 50),
            ),
            const SizedBox(height: 24),
            Text(
              completed ? 'No completed rounds yet.' : 'No rounds in progress.',
              textAlign: TextAlign.center,
              style: Halved.emptyTitle(),
            ),
            const SizedBox(height: 10),
            Text(
              completed
                  ? 'Completed rounds will appear here.'
                  : 'Tap the button below to start a new casual round.',
              textAlign: TextAlign.center,
              style: Halved.body(color: Halved.muted),
            ),
            if (!completed) ...[
              const SizedBox(height: 28),
              HalvedCtaButton(
                label: 'New Round',
                icon: Icons.sports_golf,
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CasualRoundScreen()),
                  );
                  _load();
                },
              ),
              // Onboarding wizard stays reachable for a truly empty account.
              if (!_hasAnyRound) ...[
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () async {
                    await Navigator.of(context).pushNamed('/onboarding');
                    _load();
                  },
                  child: Text('First time? Set up your first round',
                      style: Halved.body(
                          weight: FontWeight.w600, color: Halved.pine)),
                ),
              ],
            ],
          ],
        ),
      ),
    );
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

    bool tabOk(String s) =>
        _showCompleted ? s == 'complete' : s != 'complete';

    // Defensively filter by status client-side so a just-completed round can
    // never flash back into the Active list on a momentarily stale response.
    final rounds = (_rounds ?? []).where((r) => tabOk(r.status)).toList();
    final shared = _shared.where((r) => tabOk(r.status)).toList();
    // Dedupe: if I'm both a player and a watcher of the same round, it shows
    // once as PLAYED (playing supersedes watching — no eye, opens to scoring).
    final playedIds = <int>{
      for (final r in (_rounds ?? [])) r.id,
      for (final r in _shared) r.id,
    };
    final watched = _observing.where((r) {
      if (playedIds.contains(r.id)) return false;
      return tabOk(r.status);
    }).toList();

    if (rounds.isEmpty && shared.isEmpty && watched.isEmpty) {
      return _buildEmptyState();
    }

    String fmtDate(String iso) {
      final d = DateTime.tryParse(iso);
      return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
    }

    // Played = my own rounds + rounds a friend added me to as a player.
    // Watched = read-only follows (an eye replaces the money; no delete).
    final played = <_RoundItem>[
      for (final r in rounds) _ownItem(r, myId, fmtDate),
      for (final r in shared) _sharedItem(r, fmtDate),
    ];
    final watchedItems = [for (final r in watched) _watchedItem(r, fmtDate)];

    // Active is deliberately unfiltered — following a live round is the point
    // there. Completed hides watched rounds until "Include watched" is on.
    final showFilter     = _showCompleted;
    final includeWatched = !_showCompleted || _includeWatched;
    final items = <_RoundItem>[
      ...played,
      if (includeWatched) ...watchedItems,
    ]..sort((a, b) =>
        (b.sortDate ?? DateTime(0)).compareTo(a.sortDate ?? DateTime(0)));

    final list = items.isEmpty
        ? ListView(children: [
            const SizedBox(height: 72),
            Center(child: Text('No rounds you played.',
                style: Halved.body(color: Halved.muted))),
          ])
        : ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
            itemCount: items.length,
            itemBuilder: (_, i) => _RoundCard(item: items[i]),
          );
    final body = RefreshIndicator(onRefresh: _load, child: list);

    if (!showFilter) return body;

    final total = played.length + watchedItems.length;
    final shown = includeWatched ? total : played.length;
    return Column(children: [
      _WatchedFilterRow(
        includeWatched: _includeWatched,
        hasWatched:     watchedItems.isNotEmpty,
        total:          total,
        shown:          shown,
        onChanged:      (v) => setState(() => _includeWatched = v),
      ),
      Expanded(child: body),
    ]);
  }

  /// Split a round's games into the primary (bold) and the side games (muted),
  /// honouring the stored primary and the 18-Hole-Match Nassau relabel.
  (String, String) _gameLabels(
      List<String> activeGames, String? primaryGame, bool isEighteenHoleMatch) {
    final primary = resolvePrimary(primaryGame, activeGames);
    // No resolvable primary (empty / overlay-only round) → fall back to the
    // joined label (which itself defaults to "Stroke Play"), no side split.
    if (primary == null) {
      return (
        gamesDisplayLabel(activeGames,
            isEighteenHoleMatch: isEighteenHoleMatch),
        '',
      );
    }
    final primaryLabel = (primary == GameIds.nassau && isEighteenHoleMatch)
        ? gameDisplayName(GameIds.match18)
        : gameDisplayName(primary);
    final sides = activeGames.where((g) => g != primary).toList();
    final sideLabel =
        sides.isEmpty ? '' : '+ ${sides.map(gameDisplayName).join(', ')}';
    return (primaryLabel, sideLabel);
  }

  /// My own round — full data: me-first player list (with my gross on completed
  /// rounds), settlement money, and the delete control when I'm the creator.
  _RoundItem _ownItem(
      CasualRoundSummary r, int? myId, String Function(String) fmtDate) {
    final (primaryLabel, sideLabel) =
        _gameLabels(r.activeGames, r.primaryGame, r.isEighteenHoleMatch);

    // Find "me" so the row lists me first with my gross.
    CasualRoundPlayer? me;
    for (final p in r.players) {
      if (p.id == r.myPlayerId || (r.myPlayerId == null && p.id == myId)) {
        me = p;
        break;
      }
    }
    final others = [
      for (final p in r.players)
        if (p.id != me?.id) p.name,
    ];

    return _RoundItem(
      sortDate:     DateTime.tryParse(r.date),
      dateLabel:    fmtDate(r.date),
      courseName:   r.courseName,
      primaryLabel: primaryLabel,
      sideLabel:    sideLabel,
      isCompleted:  r.status == 'complete',
      currentHole:  r.currentHole,
      meName:       me?.name,
      meGross:      r.myGross,
      otherNames:   others,
      stake:        r.betUnit,
      netAmount:    r.myNet,
      onTap:        () async { await _openRound(r); _load(); },
      onDelete: (myId != null && r.createdByPlayerId == myId)
          ? () => _confirmDelete(r)
          : null,
    );
  }

  /// A round in another account I was added to as a PLAYER. No per-round money
  /// is computed cross-account; the group label gives context.
  _RoundItem _sharedItem(ScoringRound r, String Function(String) fmtDate) {
    final (primaryLabel, sideLabel) =
        _gameLabels(r.activeGames, null, r.isEighteenHoleMatch);
    return _RoundItem(
      sortDate:     DateTime.tryParse(r.date),
      dateLabel:    fmtDate(r.date),
      courseName:   r.courseName,
      primaryLabel: primaryLabel,
      sideLabel:    sideLabel,
      isCompleted:  r.status == 'complete',
      currentHole:  r.currentHole,
      contextLabel: r.groupLabel,
      onTap:        () async { await openSharedRound(context, r.id); _load(); },
    );
  }

  /// A round I only WATCH (read-only). The eye replaces the money; no delete.
  _RoundItem _watchedItem(SharedRoundSummary r, String Function(String) fmtDate) {
    final (primaryLabel, sideLabel) =
        _gameLabels(r.activeGames, null, r.isEighteenHoleMatch);
    return _RoundItem(
      sortDate:     DateTime.tryParse(r.date),
      dateLabel:    fmtDate(r.date),
      courseName:   r.courseName,
      primaryLabel: primaryLabel,
      sideLabel:    sideLabel,
      isCompleted:  r.status == 'complete',
      currentHole:  r.currentHole,
      contextLabel: r.groupLabel,
      isWatched:    true,
      onTap:        () async { await openWatchedRound(context, r); _load(); },
    );
  }
}

// ---------------------------------------------------------------------------
// Watched-round filter (Completed tab only)
// ---------------------------------------------------------------------------

class _WatchedFilterRow extends StatelessWidget {
  final bool includeWatched;
  final bool hasWatched;
  final int  total;
  final int  shown;
  final ValueChanged<bool> onChanged;

  const _WatchedFilterRow({
    required this.includeWatched,
    required this.hasWatched,
    required this.total,
    required this.shown,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // "Include watched" is disabled when there's nothing to reveal, and the
    // count collapses to a plain total — a live control that changes nothing is
    // worse than a dead one, and the fraction must not imply hidden rounds when
    // none exist.
    final mineSelected = !includeWatched || !hasWatched;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(children: [
        _chip('Rounds I played', selected: mineSelected, enabled: true,
            onTap: () => onChanged(false)),
        const SizedBox(width: 8),
        _chip('Include watched',
            selected: includeWatched && hasWatched, enabled: hasWatched,
            onTap: hasWatched ? () => onChanged(true) : null),
        const Spacer(),
        Text(hasWatched ? '$shown of $total' : '$total rounds',
            style: Halved.body(color: Halved.muted).copyWith(fontSize: 11.5)),
      ]),
    );
  }

  Widget _chip(String label,
      {required bool selected, required bool enabled, VoidCallback? onTap}) {
    final base = selected ? Halved.pine : Halved.muted;
    return Opacity(
      opacity: enabled ? 1 : 0.42,
      child: Material(
        color: selected ? Halved.pine.withValues(alpha: 0.09) : Halved.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(
              color: selected ? Halved.pine : Halved.cardBorder, width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(label,
                style: Halved.body(color: base, weight: FontWeight.w600)
                    .copyWith(fontSize: 12)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card model + widget
// ---------------------------------------------------------------------------

/// A normalized row for the rounds list, covering my own rounds, rounds a
/// friend added me to as a player, and rounds I only watch.
class _RoundItem {
  final DateTime?    sortDate;
  final String       dateLabel;
  final String       courseName;
  final String       primaryLabel;   // primary game, bold
  final String       sideLabel;      // "+ Skins, Presses", muted (may be '')
  final bool         isCompleted;
  final int?         currentHole;    // 0 = not started, null = unknown (shared)
  /// My name + gross, for the me-first player line (own rounds only).
  final String?      meName;
  final int?         meGross;        // shown next to my name on completed rounds
  final List<String> otherNames;     // the rest of the group
  /// Context label for cross-account rounds when player names aren't available.
  final String?      contextLabel;
  final bool         isWatched;      // read-only follow → eye, no money/delete
  final double?      stake;          // shown in-play on active rounds
  final double?      netAmount;      // settlement on completed rounds (null=none)
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _RoundItem({
    required this.sortDate,
    required this.dateLabel,
    required this.courseName,
    required this.primaryLabel,
    this.sideLabel = '',
    required this.isCompleted,
    this.currentHole,
    this.meName,
    this.meGross,
    this.otherNames = const [],
    this.contextLabel,
    this.isWatched = false,
    this.stake,
    this.netAmount,
    required this.onTap,
    this.onDelete,
  });
}

class _RoundCard extends StatelessWidget {
  final _RoundItem item;
  const _RoundCard({required this.item});

  static const _danger = Color(0xFFC0392B);

  String _money(double v) {
    final a = v.abs();
    final s = a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
    return v < 0 ? '−\$$s' : '+\$$s';
  }

  String _stakeLabel(double v) =>
      '\$${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row1(context),
              const SizedBox(height: 7),
              _row2(context),
              const SizedBox(height: 7),
              _row3(context),
            ],
          ),
        ),
      ),
    );
  }

  // Row 1 — course (ellipsizes) + date, with the delete beneath the date.
  Widget _row1(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(item.courseName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Halved.body(color: Halved.deepPine, weight: FontWeight.w700)
                  .copyWith(fontSize: 16.5)),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(item.dateLabel,
                style: Halved.body(color: Halved.muted).copyWith(fontSize: 13)),
            if (item.onDelete != null)
              SizedBox(
                height: 26,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.delete_outline, size: 19, color: _danger),
                  tooltip: 'Delete round',
                  onPressed: item.onDelete,
                ),
              ),
          ],
        ),
      ],
    );
  }

  // Row 2 — primary game (bold) + side games (muted, ellipsizes) + state pill.
  Widget _row2(BuildContext context) {
    return Row(children: [
      Text(item.primaryLabel,
          style: Halved.body(color: Halved.deepPine, weight: FontWeight.w600)
              .copyWith(fontSize: 13.5)),
      if (item.sideLabel.isNotEmpty) ...[
        const SizedBox(width: 6),
        Flexible(
          child: Text(item.sideLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Halved.body(color: Halved.muted).copyWith(fontSize: 12.5)),
        ),
      ] else
        const Spacer(),
      const SizedBox(width: 10),
      _statePill(),
    ]);
  }

  Widget _statePill() {
    if (item.isCompleted) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_circle_outline, size: 14, color: Halved.mint),
        const SizedBox(width: 4),
        Text('Complete',
            style: Halved.body(color: Halved.mint, weight: FontWeight.w600)
                .copyWith(fontSize: 13)),
      ]);
    }
    // Active: pulsing dot when a hole has posted, static dot when not started.
    final started = item.currentHole == null || (item.currentHole ?? 0) > 0;
    final label = item.currentHole == null
        ? 'In progress'
        : (item.currentHole == 0 ? 'Not started' : 'Through ${item.currentHole}');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      started ? const _PulsingDot() : const _StaticDot(),
      const SizedBox(width: 6),
      Text(label,
          style: Halved.body(
                  color: started ? Halved.pine : Halved.muted,
                  weight: FontWeight.w600)
              .copyWith(fontSize: 13)),
    ]);
  }

  // Row 3 — players (me first, my gross on completed) + settlement / eye.
  Widget _row3(BuildContext context) {
    return Row(children: [
      Expanded(child: _players(context)),
      const SizedBox(width: 12),
      _result(context),
    ]);
  }

  Widget _players(BuildContext context) {
    final muted = Halved.body(color: Halved.muted).copyWith(fontSize: 13);
    if (item.meName != null) {
      final spans = <TextSpan>[
        TextSpan(text: item.meName,
            style: Halved.body(color: Halved.deepPine, weight: FontWeight.w600)
                .copyWith(fontSize: 13)),
        if (item.isCompleted && item.meGross != null)
          TextSpan(text: ' ${item.meGross}',
              style: Halved.body(color: Halved.deepPine, weight: FontWeight.w700)
                  .copyWith(fontSize: 13)),
        if (item.otherNames.isNotEmpty)
          TextSpan(text: ', ${item.otherNames.join(', ')}', style: muted),
      ];
      return RichText(maxLines: 1, overflow: TextOverflow.ellipsis,
          text: TextSpan(children: spans));
    }
    final text = item.otherNames.isNotEmpty
        ? item.otherNames.join(', ')
        : (item.contextLabel ?? '');
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted);
  }

  Widget _result(BuildContext context) {
    if (item.isWatched) {
      return const Tooltip(
        message: "You're watching this round",
        child: Icon(Icons.visibility, size: 18, color: Halved.mint),
      );
    }
    if (item.isCompleted) {
      if (item.netAmount == null) return const SizedBox.shrink();
      final down = item.netAmount! < 0;
      return Text(_money(item.netAmount!),
          style: Halved.body(color: down ? _danger : Halved.pine,
              weight: FontWeight.w700).copyWith(fontSize: 14.5));
    }
    // Active: skin-in-the-game stake, or an em dash when there's no stake.
    final stake = item.stake ?? 0;
    return Text(stake > 0 ? _stakeLabel(stake) : '—',
        style: Halved.body(color: Halved.muted, weight: FontWeight.w600)
            .copyWith(fontSize: 13.5));
  }
}

/// A pulsing mint dot — an in-progress round's live indicator.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          width: 7, height: 7,
          decoration: BoxDecoration(
            color: Halved.brightMint,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Halved.brightMint.withValues(alpha: 0.28 - 0.20 * t),
                blurRadius: 0,
                spreadRadius: 3 + 3 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A static muted dot — a round that hasn't teed off yet.
class _StaticDot extends StatelessWidget {
  const _StaticDot();
  @override
  Widget build(BuildContext context) => Container(
        width: 7, height: 7,
        decoration: const BoxDecoration(
            color: Color(0xFFB9C8BE), shape: BoxShape.circle),
      );
}
