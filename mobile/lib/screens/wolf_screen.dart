/// screens/wolf_screen.dart
///
/// Play screen for the Wolf casual game.  Per hole it shows, top-to-bottom:
///   • Hole header (par / yards / SI) with a "set rotation" action.
///   • Wolf decision panel — who's the Wolf, the reverse-honors tee order
///     (worst on the previous hole tees first, Wolf last), and the Wolf's
///     choice: Take-as-partner on each non-Wolf row (4-player only), Lone
///     Wolf, or Blind Wolf.
///   • Score-entry rows (modeled on points_531_screen) ordered to match the
///     tee order, with an inline net-centred picker on the hot row.
///   • The hole's outcome once it's decided + scored.
///   • An 18-hole points grid.
///
/// The Wolf identity, tee order, decision, and results all come from the
/// server summary (services.wolf.wolf_summary), which is refreshed after
/// every score submission and decision.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_colors.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../utils/match_handicap.dart';
import '../utils/round_complete.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/icon_help_sheet.dart';
import '../widgets/inline_message.dart';
import '../widgets/net_score_button.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/spots_capture.dart';

/// Team accent color for a player's role on a hole. Per the color standard the
/// Wolf side (Wolf + partner) is team 1 (blue); the opponents are team 2
/// (orange). Null = no team yet.
Color? _wolfTeamColor(String? role) {
  switch (role) {
    case 'wolf':
    case 'partner':
      return GameColors.team1;
    case 'opponent':
      return GameColors.team2;
  }
  return null;
}

String _fmtPoints(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class WolfScreen extends StatefulWidget {
  final int foursomeId;
  const WolfScreen({super.key, required this.foursomeId});

  @override
  State<WolfScreen> createState() => _WolfScreenState();
}

class _WolfScreenState extends State<WolfScreen> with SpotsCaptureMixin {
  /// Unsubmitted score edits: hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;
  bool _decisionBusy    = false;
  // Set when the user taps an already-scored player to correct a past hole, so
  // the inline picker re-opens for that row (a completed hole has no hot-spot).
  int? _editingPlayerId;
  bool _sheetOpen       = false;
  bool _ready           = false;   // true once the initial hole-jump settled

  /// Holes for which the decision overlay has already auto-opened this
  /// session — so dismissing it doesn't immediately re-pop the same hole.
  final Set<int> _promptedHoles = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rp = context.read<RoundProvider>();
      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      } else {
        rp.refreshPendingOverlay();
      }
      rp.loadWolf(widget.foursomeId);
      if (rp.round?.activeGames.contains('spots') ?? false) {
        rp.loadSpots(widget.foursomeId);
      }
    });
  }

  @override
  void dispose() {
    disposeSpots();
    super.dispose();
  }

  Future<void> _refresh() async {
    final rp = context.read<RoundProvider>();
    await rp.loadScorecard(widget.foursomeId);
    rp.loadWolf(widget.foursomeId);
    if (rp.round?.activeGames.contains('spots') ?? false) {
      rp.loadSpots(widget.foursomeId);
    }
  }

  // ── Player ordering ───────────────────────────────────────────────────────

  /// Real (non-phantom) members for this foursome.
  List<Membership> _realMembers(Round? round) {
    final fs = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  /// Members ordered to match the hole's tee order (reverse honors, Wolf
  /// last) when the summary has it; falls back to membership order.
  List<Membership> _orderedPlayers(Round? round, WolfHole? hole) {
    final members = _realMembers(round);
    if (hole == null || hole.teeOrder.isEmpty) return members;
    final byId = {for (final m in members) m.player.id: m};
    final out = <Membership>[];
    for (final slot in hole.teeOrder) {
      final m = byId[slot.playerId];
      if (m != null) out.add(m);
    }
    for (final m in members) {
      if (!out.contains(m)) out.add(m);
    }
    return out;
  }

  // ── Score helpers ─────────────────────────────────────────────────────────

  Map<int, int> _effectiveScores(Scorecard sc, int hole) {
    final saved = <int, int>{};
    final hd = sc.holeData(hole);
    if (hd != null) {
      for (final s in hd.scores) {
        if (s.grossScore != null) saved[s.playerId] = s.grossScore!;
      }
    }
    return {...saved, ...(_pending[hole] ?? {})};
  }

  bool _anyScoreEntered(Scorecard sc, int hole) =>
      _effectiveScores(sc, hole).isNotEmpty;

  /// True once any score has been entered (saved or pending) — gates the
  /// app-bar Exit (✕) on a single-foursome casual round.
  bool get _hasAnyScore {
    if (_pending.isNotEmpty) return true;
    final rp = context.read<RoundProvider>();
    final sc = rp.scorecard;
    if (sc != null) {
      for (int h = 1; h <= 18; h++) {
        if (_effectiveScores(sc, h).isNotEmpty) return true;
      }
    }
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    return fs?.hasAnyScore ?? false;
  }

  int _hotSpotIdx(List<Membership> players, Map<int, int> scores) {
    for (int i = 0; i < players.length; i++) {
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  bool _allScored(List<Membership> players, Map<int, int> scores) =>
      players.every((m) => scores.containsKey(m.player.id));

  void _selectScore(Membership player, int score, int hole) {
    setState(() {
      if (score == -1) {
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  /// Record a score and, if the user's Auto-advance setting is on, save +
  /// move to the next hole once the last player's score completes it.
  void _handleScore(BuildContext ctx, Membership m, int score,
      List<Membership> players) {
    final sc = context.read<RoundProvider>().scorecard;
    final hole = _selectedHole;
    final wasAllScored =
        sc != null && _allScored(players, _effectiveScores(sc, hole));
    _selectScore(m, score, hole);
    if (sc == null || score <= 0) return;
    if (wasAllScored) {
      // Editing an already-complete (past) hole: there's no save+advance step
      // for a correction, so persist it immediately — otherwise the change is
      // lost the moment the user navigates to another hole.
      setState(() => _editingPlayerId = null);
      _saveHole(ctx, hole, players);
      return;
    }
    if (!context.read<SettingsProvider>().autoAdvanceHole) return;
    if (!_allScored(players, _effectiveScores(sc, hole))) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedHole != hole) return;
      final rp = context.read<RoundProvider>();
      if (rp.submitting) return;
      _saveAndAdvance(ctx, players);   // on hole 18 this saves + stays
    });
  }

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = _realMembers(rp.round).map((m) => m.player.id).toSet();
    for (int h = 1; h <= 18; h++) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      final allScored = hd.scores
          .where((s) => realIds.contains(s.playerId))
          .every((s) => s.grossScore != null);
      if (!allScored && !rp.localPendingByHole.containsKey(h)) {
        setState(() { _selectedHole = h; _ready = true; });
        return;
      }
    }
    setState(() { _selectedHole = 18; _ready = true; });
  }

  void _advance() {
    if (_selectedHole < 18) setState(() { _selectedHole++; _editingPlayerId = null; });
  }
  void _retreat() {
    if (_selectedHole > 1)  setState(() { _selectedHole--; _editingPlayerId = null; });
  }

  // ── Wolf decision ─────────────────────────────────────────────────────────

  Future<void> _setDecision(String decision, {int? partnerId}) async {
    if (_decisionBusy) return;
    setState(() => _decisionBusy = true);
    try {
      final client = context.read<AuthProvider>().client;
      final summary = await client.postWolfDecision(
        widget.foursomeId,
        holeNumber: _selectedHole,
        decision:   decision,
        partnerId:  partnerId,
      );
      if (!mounted) return;
      context.read<RoundProvider>().setWolfSummary(summary);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not save the Wolf decision: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      if (mounted) setState(() => _decisionBusy = false);
    }
  }

  /// Present the tee-order + partner/Lone/Blind overlay for [hole].  It
  /// dismisses as soon as a choice is made; the choice is then persisted.
  Future<void> _openDecisionSheet(int hole) async {
    if (_sheetOpen) return;
    final rp = context.read<RoundProvider>();
    final summary = rp.wolfSummary;
    final sc = rp.scorecard;
    if (summary == null || sc == null) return;
    final holeInfo = summary.holeFor(hole);
    if (holeInfo == null) return;

    _sheetOpen = true;
    final choice = await showModalBottomSheet<_WolfChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WolfDecisionSheet(
        hole:      holeInfo,
        summary:   summary,
        scorecard: sc,
        anyScored: _anyScoreEntered(sc, hole),
      ),
    );
    _sheetOpen = false;
    if (choice == null || !mounted) return;
    // Persist the choice for the hole the sheet was opened on (the user
    // may have changed _selectedHole, so target [hole] explicitly).
    final saved = _selectedHole;
    _selectedHole = hole;
    if (choice.kind == 'partner') {
      await _setDecision('partner', partnerId: choice.partnerId);
    } else {
      await _setDecision(choice.kind);
    }
    if (mounted) _selectedHole = saved;
  }

  Future<void> _promptRotation() async {
    final rp = context.read<RoundProvider>();
    final members = _realMembers(rp.round);
    if (members.isEmpty) return;
    final summary = rp.wolfSummary;
    // Seed from the current server order, then any missing members.
    final ids = members.map((m) => m.player.id).toList();
    final order = <int>[
      ...?summary?.wolfOrder.where(ids.contains),
    ];
    for (final id in ids) {
      if (!order.contains(id)) order.add(id);
    }
    // Positions whose hole has already been played are frozen — locking the
    // prefix up to the furthest played position so a past Wolf can't change.
    final locked = summary?.lockedPositions ?? const [];
    final lockedCount = locked.isEmpty
        ? 0
        : (locked.reduce((a, b) => a > b ? a : b) + 1).clamp(0, order.length);
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RotationSheet(
          order: order, members: members, lockedCount: lockedCount),
    );
    if (result == null || !mounted) return;
    try {
      final client = context.read<AuthProvider>().client;
      final updated = await client.postWolfOrder(
        widget.foursomeId, wolfOrder: result);
      if (!mounted) return;
      context.read<RoundProvider>().setWolfSummary(updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not update rotation: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  /// Persist whatever is pending for [hole] without changing the selected hole.
  /// Used by both the save+advance button and inline edits to past holes.
  Future<void> _saveHole(
      BuildContext ctx, int hole, List<Membership> players) async {
    final edits = _pending[hole];
    if (edits == null || edits.isEmpty) return;
    final scores = edits.entries
        .map((e) => {'player_id': e.key, 'gross_score': e.value})
        .toList();
    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
      foursomeId: widget.foursomeId,
      holeNumber: hole,
      scores:     scores,
    );
    if (!mounted) return;
    if (!ok) {
      _snack(ctx, rp.error ?? 'Failed to save hole.',
          () => _saveHole(ctx, hole, players));
      return;
    }
    setState(() { _pending.remove(hole); });
    rp.loadWolf(widget.foursomeId);
  }

  Future<void> _saveAndAdvance(
      BuildContext ctx, List<Membership> players) async {
    final hole = _selectedHole;
    if (_pending[hole]?.isNotEmpty ?? false) {
      await _saveHole(ctx, hole, players);
      if (!mounted || _pending.containsKey(hole)) return;   // save failed
    }
    _advance();
  }

  Future<void> _finishRound(BuildContext ctx, List<Membership> players) async {
    final rp      = context.read<RoundProvider>();
    // Soft gate: warn if finishing early (holes still unscored), consistent
    // with the other score screens.
    final sc = rp.scorecard;
    int unscored = 0;
    if (sc != null) {
      for (int h = 1; h <= 18; h++) {
        if (_effectiveScores(sc, h).isEmpty) unscored++;
      }
    }
    if (!await confirmCompleteRound(ctx, unscoredHoles: unscored)) return;
    if (!mounted) return;
    final sync    = context.read<SyncService>();
    final roundId = rp.round?.id;

    final pendingForHole = _pending[_selectedHole];
    if (pendingForHole != null && pendingForHole.isNotEmpty) {
      final scores = pendingForHole.entries
          .map((e) => {'player_id': e.key, 'gross_score': e.value})
          .toList();
      final ok = await rp.submitHole(
        foursomeId: widget.foursomeId,
        holeNumber: _selectedHole,
        scores:     scores,
      );
      if (!mounted) return;
      if (!ok) {
        _snack(ctx, rp.error ?? 'Failed to save hole.',
            () => _finishRound(ctx, players));
        return;
      }
      setState(() { _pending.remove(_selectedHole); });
    }

    await sync.waitUntilIdle();
    if (!mounted) return;
    if (roundId != null) {
      // Mark the round complete so it leaves the active list (without this
      // "Done" only opens the leaderboard and the round stays in_progress).
      final lb = await rp.completeRound(roundId);
      if (!mounted) return;
      if (lb == null) {
        _snack(ctx, rp.error ?? 'Could not complete round.',
            () => _finishRound(ctx, players));
        return;
      }
      Navigator.of(ctx).pushReplacementNamed('/leaderboard', arguments: roundId);
    }
  }

  /// Per-hole row legend ("?" in the hole header) — explains the Wolf-specific
  /// row markings, matching the legend the other score screens offer.
  void _showWolfLegend(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(Widget lead, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 28, child: Center(child: lead)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        );
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Wolf row guide',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            row(Icon(Icons.pets, size: 20, color: theme.colorScheme.primary),
                'The Wolf',
                'The paw marks who is the Wolf this hole — they tee off last and choose a partner, go Lone Wolf, or call Blind Wolf.'),
            row(Container(width: 16, height: 16,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(3))),
                'Team color',
                'The left stripe / tint groups the teams for this hole — the Wolf side vs. the others.'),
            row(Text('-8 •', style: theme.textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
                'Handicap',
                'The playing handicap used for this game; each dot is a stroke received on this hole.'),
            row(Container(width: 22, height: 20,
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(4)),
                  child: const Center(child: Text('4',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))),
                'Score box',
                'Tap a player’s box to enter their gross score. Tap an already-scored row to correct it.'),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Got it'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _snack(BuildContext ctx, String msg, VoidCallback retry) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Theme.of(ctx).colorScheme.error,
      action: SnackBarAction(
        label: 'Retry',
        textColor: Theme.of(ctx).colorScheme.onError,
        onPressed: retry,
      ),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final sc   = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';

    if (!_initialJumpDone &&
        sc != null &&
        rp.activeFoursomeId == widget.foursomeId) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstUnplayed(context.read<RoundProvider>());
      });
    }

    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadWolf(widget.foursomeId);
      });
    }
    _prevHadPending = nowHasPending;

    // On a single-foursome casual round, once a score is entered swap the back
    // arrow for an explicit ✕ Exit (back is easily mistaken for "previous hole")
    // that returns to the casual rounds list.
    final isCasualSingle = (rp.round?.isCasual ?? false) &&
        (rp.round?.foursomes.length ?? 1) == 1;
    final showExit = isCasualSingle && _hasAnyScore;

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Wolf',
        automaticallyImplyLeading: !showExit,
        leading: showExit
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Exit to rounds',
                onPressed: () => Navigator.of(context).popUntil(
                    (r) => r.settings.name == '/casual-rounds' || r.isFirst),
              )
            : null,
        actions: [
          if (sync.hasPending)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Badge(
                label: Text('${sync.pendingCount}'),
                child: IconButton(
                  icon: sync.state == SyncState.syncing
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.cloud_upload_outlined),
                  tooltip: sync.state == SyncState.syncing
                      ? 'Syncing…'
                      : 'Tap to sync ${sync.pendingCount} score(s)',
                  onPressed: sync.state == SyncState.syncing
                      ? null : () => sync.recheck(),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Refresh scores',
            icon: const Icon(Icons.refresh),
            onPressed: rp.round == null ? null : _refresh,
          ),
          if (rp.round != null)
            RoundChatButton(roundId: rp.round!.id),
          // Standard order: Leaderboard then Scorecard (scorecard rightmost).
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null
                ? null
                : () => Navigator.of(context).pushNamed(
                    '/leaderboard', arguments: rp.round!.id),
          ),
          IconButton(
            tooltip: 'Full scorecard',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: sc == null
                ? null
                : () => Navigator.of(context).pushNamed('/scorecard',
                    arguments: {'foursomeId': widget.foursomeId, 'readOnly': true}),
          ),
          // Overflow: low-frequency actions — set rotation, end the round
          // early (soft gate), and the icon-legend help.
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'rotation':
                  if (rp.wolfSummary != null) _promptRotation();
                  break;
                case 'end':
                  final holeInfo = rp.wolfSummary?.holeFor(_selectedHole);
                  _finishRound(
                      context, _orderedPlayers(rp.round, holeInfo));
                  break;
                case 'help':
                  showScoreEntryHelp(context);
                  break;
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'rotation',
                enabled: rp.wolfSummary != null,
                child: const ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.repeat),
                  title: Text('Set Wolf rotation'),
                ),
              ),
              if (!isComplete)
                const PopupMenuItem(
                  value: 'end',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.flag_outlined),
                    title: Text('End round'),
                  ),
                ),
              const PopupMenuItem(
                value: 'help',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.help_outline),
                  title: Text('What do these buttons do?'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(context, rp, sync, isComplete),
      bottomNavigationBar: sc == null ? null : _buildBottomNav(context, rp, sc),
    );
  }

  Widget _buildBody(
      BuildContext ctx, RoundProvider rp, SyncService sync, bool isComplete) {
    if (rp.loadingScorecard && rp.scorecard == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.scorecard == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        InlineMessage(kind: InlineMessageKind.error, text: rp.error!),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            rp.loadScorecard(widget.foursomeId);
            rp.loadWolf(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }

    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final summary  = rp.wolfSummary;
    final holeInfo = summary?.holeFor(_selectedHole);
    final players  = _orderedPlayers(rp.round, holeInfo);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;

    // Auto-present the decision overlay the first time we land on an
    // undecided hole (once per hole, so dismissing it doesn't re-pop).
    // Gated on _ready so it waits until the initial hole-jump has settled
    // (otherwise it could pop hole 1's sheet while resuming mid-round).
    if (_ready &&
        holeInfo != null &&
        !holeInfo.isDecided &&
        !isComplete &&
        !_decisionBusy &&
        !_anyScoreEntered(sc, _selectedHole) &&
        _promptedHoles.add(_selectedHole)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openDecisionSheet(_selectedHole);
      });
    }

    return Column(children: [
      Expanded(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Hole header ──
              _HoleHeader(holeNumber: _selectedHole, holeData: holeData,
                  players: players, onHelp: () => _showWolfLegend(context)),
              const SizedBox(height: 12),

              // ── Wolf decision panel ──
              if (summary != null && holeInfo != null)
                _WolfBar(
                  hole:    holeInfo,
                  summary: summary,
                  busy:    _decisionBusy,
                  onTap:   () => _openDecisionSheet(_selectedHole),
                )
              else if (rp.loadingWolf)
                const Center(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: CircularProgressIndicator(strokeWidth: 2))),
              const SizedBox(height: 12),

              // ── Score entry ──
              _HoleScoreCard(
                holeData:   holeData,
                holeNumber: _selectedHole,
                players:    players,
                scorecard:  sc,
                scores:     scores,
                hotSpotIdx: hotSpot,
                par:        par,
                summary:    summary,
                holeInfo:   holeInfo,
                decided:    holeInfo?.isDecided ?? false,
                editingPlayerId: _editingPlayerId,
                onTapDecide: () => _openDecisionSheet(_selectedHole),
                onScoreSelected: (m, s) => _handleScore(ctx, m, s, players),
                onEditTap: (m) => setState(() => _editingPlayerId =
                    _editingPlayerId == m.player.id ? null : m.player.id),
                spotsActive:   spotsActive(rp),
                spotsCountFor: (pid) =>
                    spotsCount(pid, _selectedHole, rp.spotsSummary),
                onSpotsAdd:    (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, 1),
                onSpotsRemove: (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, -1),
              ),
              if (holeInfo != null && holeInfo.isScored) ...[
                const SizedBox(height: 12),
                _WolfOutcomeLine(hole: holeInfo),
              ],
              const SizedBox(height: 12),

              // ── Points grid ──
              if (summary != null)
                _WolfGrid(
                  summary:     summary,
                  players:     _realMembers(rp.round),
                  scorecard:   sc,
                  currentHole: _selectedHole,
                  onTapHole:   (h) => setState(() {
                    _selectedHole = h; _editingPlayerId = null;
                  }),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        ),
      ),
    ]);
  }

  Widget _buildBottomNav(BuildContext ctx, RoundProvider rp, Scorecard sc) {
    final summary  = rp.wolfSummary;
    final holeInfo = summary?.holeFor(_selectedHole);
    final players  = _orderedPlayers(rp.round, holeInfo);
    final scores   = _effectiveScores(sc, _selectedHole);
    final allDone  = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _selectedHole > 1 ? _retreat : null,
              icon: const Icon(Icons.chevron_left, size: 20),
              label: Text('Hole ${_selectedHole - 1}'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _selectedHole == 18 || isComplete
                ? FilledButton.icon(
                    onPressed: rp.submitting
                        ? null : () => _finishRound(ctx, players),
                    icon: const Icon(Icons.emoji_events, size: 20),
                    label: const Text('Done'),
                  )
                : FilledButton.icon(
                    onPressed: (allDone && !rp.submitting)
                        ? () => _saveAndAdvance(ctx, players) : null,
                    icon: rp.submitting
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.chevron_right, size: 20),
                    label: Text(rp.submitting
                        ? 'Saving…' : 'Hole ${_selectedHole + 1}'),
                    iconAlignment: IconAlignment.end,
                  ),
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Hole header
// ===========================================================================

class _HoleHeader extends StatelessWidget {
  final int            holeNumber;
  final ScorecardHole? holeData;
  final List<Membership> players;
  /// Opens the per-hole row legend ("?"), matching the other score screens.
  final VoidCallback?  onHelp;
  const _HoleHeader({
    required this.holeNumber,
    required this.holeData,
    required this.players,
    this.onHelp,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = holeData;
    final sub = h == null
        ? ''
        : 'Par ${h.par}'
            '${h.yards != null ? '  ·  ${h.yards} yds' : ''}'
            '  ·  SI ${h.strokeIndex}';
    return Stack(
      children: [
        Container(
          width: double.infinity,
          // Horizontal padding keeps the centred title clear of the "?".
          padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(children: [
            Text('Hole $holeNumber',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (sub.isNotEmpty)
              Text(sub,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
          ]),
        ),
        if (onHelp != null)
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: 'What do these mean?',
              icon: Icon(Icons.help_outline,
                  size: 22, color: theme.colorScheme.primary),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: onHelp,
            ),
          ),
      ],
    );
  }
}

// ===========================================================================
// Wolf decision — slim bar (always visible) + overlay sheet (the picker)
// ===========================================================================

/// The choice returned by the decision overlay.
class _WolfChoice {
  final String kind;       // 'partner' | 'lone' | 'blind' | 'pending'
  final int?   partnerId;
  const _WolfChoice(this.kind, [this.partnerId]);
}

/// Slim, always-visible bar showing the Wolf and the current decision.
/// Tapping it opens the decision overlay.  Keeps the play screen compact
/// and visually consistent with the other score-entry screens.
class _WolfBar extends StatelessWidget {
  final WolfHole    hole;
  final WolfSummary summary;
  final bool        busy;
  final VoidCallback onTap;

  const _WolfBar({
    required this.hole,
    required this.summary,
    required this.busy,
    required this.onTap,
  });

  String _decisionLabel() {
    switch (hole.decision) {
      case 'lone':    return 'Lone Wolf ×${summary.loneWolfPoints}';
      case 'blind':   return 'Blind Wolf ×${summary.blindWolfPoints}';
      case 'partner': return 'Partner: ${hole.partnerShort ?? '?'}';
      default:        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final pending = !hole.isDecided;
    final bg = pending
        ? theme.colorScheme.primaryContainer.withOpacity(0.35)
        : theme.colorScheme.surfaceContainerHighest.withOpacity(0.5);
    final border = pending
        ? theme.colorScheme.primary.withOpacity(0.6)
        : theme.colorScheme.outline;

    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Row(children: [
          Icon(Icons.pets, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          // Left group flexes (and the Wolf name ellipsizes) first, so the
          // decision chip on the right always shows in full.
          Expanded(
            child: Row(children: [
              Text('Wolf: ', style: theme.textTheme.titleSmall),
              Flexible(
                child: Text(hole.wolfShort,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary)),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          if (pending) ...[
            Text('Choose play',
                style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold)),
            Icon(Icons.chevron_right, color: theme.colorScheme.primary),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withOpacity(0.6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_decisionLabel(),
                  style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSecondaryContainer)),
            ),
            const SizedBox(width: 6),
            Text('Change',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.primary)),
          ],
        ]),
      ),
    );
  }
}

/// The decision overlay: tee order + partner / Lone / Blind controls.
/// It pops a [_WolfChoice] the instant a choice is made, so it dismisses
/// itself — the caller persists the result.
class _WolfDecisionSheet extends StatelessWidget {
  final WolfHole    hole;
  final WolfSummary summary;
  final Scorecard   scorecard;
  final bool        anyScored;

  const _WolfDecisionSheet({
    required this.hole,
    required this.summary,
    required this.scorecard,
    required this.anyScored,
  });

  bool get _fourPlayer => summary.players.length == 4;

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final decision = hole.decision;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Icon(Icons.pets, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Hole ${hole.hole} — Wolf: ',
                    style: theme.textTheme.titleMedium),
                Flexible(
                  child: Text(hole.wolfShort,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                ),
                const Spacer(),
                if (decision != 'pending')
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pop(const _WolfChoice('pending')),
                    child: const Text('Reset'),
                  ),
              ]),
              const SizedBox(height: 2),
              Text(
                'Tee order — worst on the last hole tees first, Wolf last.'
                '${!_fourPlayer ? '  Go Lone or Blind.' : hole.partnerLocked ? '' : '  Take a partner, or go Lone / Blind.'}',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              if (hole.partnerLocked)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Icon(Icons.lock_outline, size: 16,
                        color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Last solo-required turn — ${hole.wolfShort} must go '
                        'Lone or Blind.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: 10),

              ...hole.teeOrder.map((s) => _teeRow(context, s, decision)),

              const Divider(height: 22),

              Row(children: [
                Expanded(
                  child: _choiceButton(context,
                    label: 'Lone Wolf  ×${summary.loneWolfPoints}',
                    selected: decision == 'lone',
                    onTap: () => Navigator.of(context)
                        .pop(const _WolfChoice('lone')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _choiceButton(context,
                    label: 'Blind Wolf  ×${summary.blindWolfPoints}',
                    selected: decision == 'blind',
                    onTap: (anyScored && decision != 'blind')
                        ? null
                        : () => Navigator.of(context)
                            .pop(const _WolfChoice('blind')),
                  ),
                ),
              ]),
              if (anyScored && decision != 'blind')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Blind Wolf must be set before any scores.',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _teeRow(BuildContext context, WolfTeeSlot slot, String decision) {
    final theme     = Theme.of(context);
    final isWolf    = slot.isWolf;
    final isPartner = decision == 'partner' && hole.partnerId == slot.playerId;
    final prevGross = scorecard.holeData(hole.hole - 1)
        ?.scoreFor(slot.playerId)?.grossScore;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 26,
          child: isWolf
              ? Icon(Icons.pets, size: 16, color: theme.colorScheme.primary)
              : Text('${slot.orderNum}.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.primary)),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text(slot.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isWolf || isPartner
                          ? FontWeight.bold : FontWeight.w500,
                      color: isWolf ? theme.colorScheme.primary : null)),
            ),
            if (isWolf) ...[
              const SizedBox(width: 6),
              Text('tees last',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
            if (prevGross != null) ...[
              const SizedBox(width: 6),
              Text('last: $prevGross',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
        ),
        // Take-as-partner (4-player only, non-Wolf rows, not locked) — pops
        // the sheet.  Hidden when the require-Lone/Blind rule locks this turn.
        if (_fourPlayer && !isWolf && !hole.partnerLocked)
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              backgroundColor: isPartner
                  ? theme.colorScheme.primaryContainer.withOpacity(0.5)
                  : null,
            ),
            onPressed: () => Navigator.of(context)
                .pop(_WolfChoice('partner', slot.playerId)),
            child: Text(isPartner ? 'Partner ✓' : 'Take as partner',
                style: const TextStyle(fontSize: 12)),
          ),
      ]),
    );
  }

  Widget _choiceButton(BuildContext context,
      {required String label, required bool selected, VoidCallback? onTap}) {
    return selected
        ? FilledButton(onPressed: onTap, child: Text(label,
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)))
        : OutlinedButton(onPressed: onTap, child: Text(label,
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)));
  }
}

/// Compact one-line outcome shown under the score card once a hole is
/// decided + scored.
class _WolfOutcomeLine extends StatelessWidget {
  final WolfHole hole;
  const _WolfOutcomeLine({required this.hole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final side  = hole.winningSide;
    String text;
    Color color;
    if (side == 'tie') {
      text  = 'Halved — no points (push).';
      color = theme.colorScheme.onSurfaceVariant;
    } else if (side == 'wolf') {
      text  = 'Wolf wins the hole  ·  pot ${_fmtPoints(hole.pot)}';
      color = Colors.green.shade700;
    } else if (side == 'opponents') {
      text  = 'Wolf loses the hole  ·  pot ${_fmtPoints(hole.pot)}';
      color = theme.colorScheme.error;
    } else {
      return const SizedBox.shrink();
    }
    final parts = hole.entries
        .map((e) => '${e.shortName} ${e.points >= 0 ? '+' : ''}'
            '${_fmtPoints(e.points)}')
        .join('   ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600, color: color)),
        const SizedBox(height: 2),
        Text(parts, style: theme.textTheme.labelMedium),
      ]),
    );
  }
}

// ===========================================================================
// Score-entry card (modeled on points_531_screen's hole card)
// ===========================================================================

int  _wolfZeroSpots(int _) => 0;
void _wolfNoopPid(int _) {}

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final int              holeNumber;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, int>    scores;
  final int              hotSpotIdx;
  final int              par;
  final WolfSummary?     summary;
  final WolfHole?        holeInfo;
  final bool             decided;
  final int?             editingPlayerId;   // scored row tapped for correction
  final VoidCallback     onTapDecide;
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership) onEditTap;
  // Spots add-on (capture in this dedicated entry screen).
  final bool                   spotsActive;
  final int  Function(int pid) spotsCountFor;
  final void Function(int pid) onSpotsAdd;
  final void Function(int pid) onSpotsRemove;

  const _HoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.summary,
    required this.holeInfo,
    required this.decided,
    required this.editingPlayerId,
    required this.onTapDecide,
    required this.onScoreSelected,
    required this.onEditTap,
    this.spotsActive   = false,
    this.spotsCountFor = _wolfZeroSpots,
    this.onSpotsAdd    = _wolfNoopPid,
    this.onSpotsRemove = _wolfNoopPid,
  });

  String get _mode       => summary?.handicapMode ?? 'net';
  int    get _netPercent => summary?.netPercent   ?? 100;

  int? get _lowPlaying {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null || _mode == 'gross') return 0;
    final entry = h.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? h.strokeIndex;
    if (_mode == 'net') {
      if (_netPercent == 100 && entry != null) return entry.handicapStrokes;
      final eff = (m.playingHandicap * _netPercent / 100.0).round();
      return strokesOnHole(eff, mySi);
    }
    final low = _lowPlaying;
    if (low == null) return 0;
    final so = m.playingHandicap - low;
    if (so <= 0) return 0;
    return strokesOnHole(so, mySi);
  }

  Widget _legendDot(ThemeData theme, Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 10, height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant)),
    ]);
  }

  /// A player's team/role on this hole, derived from the decision so the
  /// colors show as soon as the teams are chosen (before any score is in).
  String? _roleFor(int playerId) {
    final h = holeInfo;
    if (h == null || !h.isDecided) return null;
    if (playerId == h.wolfId) return 'wolf';
    if (h.decision == 'partner' && playerId == h.partnerId) return 'partner';
    return 'opponent';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The inline picker is suppressed until the Wolf has chosen
    // partner / lone / blind — scoring a hole before the Wolf acts would
    // record points against an undefined hole.
    final effHot = decided ? hotSpotIdx : -1;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!decided)
            InkWell(
              onTap: onTapDecide,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withOpacity(0.35),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(8)),
                ),
                child: Row(children: [
                  Icon(Icons.touch_app_outlined, size: 18,
                      color: theme.colorScheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tap to set the Wolf’s play (partner, Lone, or Blind) '
                      'before entering scores.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18,
                      color: theme.colorScheme.onTertiaryContainer),
                ]),
              ),
            ),
          if (decided)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Row(children: [
                _legendDot(theme, GameColors.team1,
                    holeInfo?.decision == 'partner' ? 'Wolf + partner' : 'Wolf'),
                const SizedBox(width: 16),
                _legendDot(theme, GameColors.team2, 'Opponents'),
              ]),
            ),
          ...players.asMap().entries.expand((entry) {
            final idx = entry.key;
            final m   = entry.value;
            final gross = scores[m.player.id];
            final isHot = idx == effHot;
            final isEditing = editingPlayerId == m.player.id;
            // A scored row that isn't the live hot-spot can be tapped to fix
            // it — a completed hole has no hot-spot, so without this there'd be
            // no way to edit a past hole.
            final editable = gross != null && !isHot;
            final strokes = _strokesForHole(m, holeData);
            final role = _roleFor(m.player.id);

            return [
              _PlayerRow(
                member:    m,
                gross:     gross,
                isHot:     isHot,
                strokes:   strokes,
                showHcap:  _mode != 'gross',
                hcap:      effectiveMatchHandicap(
                  mode: _mode, netPercent: _netPercent,
                  playingHandicap: m.playingHandicap,
                  lowestPlayingHandicap: _lowPlaying),
                role:      role,
                dimmed:    !decided,
                isEditing: isEditing,
                onTap:     editable ? () => onEditTap(m) : null,
                spotsActive:  spotsActive,
                spotsCount:   spotsActive ? spotsCountFor(m.player.id) : 0,
                onSpotsAdd:   spotsActive ? () => onSpotsAdd(m.player.id) : null,
                onSpotsRemove:spotsActive ? () => onSpotsRemove(m.player.id) : null,
              ),
              if (isHot || isEditing)
                _InlinePicker(
                  par:          par,
                  strokes:      strokes,
                  currentScore: gross,
                  onScoreSelected: (s) => onScoreSelected(m, s),
                ),
            ];
          }),
        ],
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  final Membership member;
  final int?       gross;
  final bool       isHot;
  final int        strokes;
  final bool       showHcap;
  final int        hcap;
  final String?    role;   // wolf | partner | opponent
  final bool       dimmed; // greyed while awaiting the Wolf's decision
  final bool       isEditing;  // its inline picker is currently open
  final VoidCallback? onTap;
  final bool          spotsActive;
  final int           spotsCount;
  final VoidCallback? onSpotsAdd;
  final VoidCallback? onSpotsRemove;

  const _PlayerRow({
    required this.member,
    required this.gross,
    required this.isHot,
    required this.strokes,
    required this.showHcap,
    required this.hcap,
    required this.role,
    this.dimmed = false,
    this.isEditing = false,
    this.onTap,
    this.spotsActive = false,
    this.spotsCount = 0,
    this.onSpotsAdd,
    this.onSpotsRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final teamColor = _wolfTeamColor(role);
    final boxBg = (isHot || isEditing)
        ? theme.colorScheme.primaryContainer.withOpacity(0.4)
        : Colors.transparent;
    final boxBorder = (isHot || isEditing)
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: teamColor ?? theme.colorScheme.outline,
            width: teamColor != null ? 1.5 : 1);

    final inner = Opacity(
      opacity: dimmed ? 0.45 : 1.0,
      child: Container(
      decoration: BoxDecoration(
        // Team tint stays on (warm = Wolf side, cool = opponents) even on
        // the active row, so a player's team is never hidden — the
        // highlighted score box on the right is what marks the active input.
        color: teamColor?.withOpacity(0.07),
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
          left: teamColor != null
              ? BorderSide(color: teamColor, width: 4)
              : BorderSide.none,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        if (role == 'wolf')
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.pets, size: 16, color: theme.colorScheme.primary),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
            Flexible(
              child: Text(member.player.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (role == 'partner') ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('partner',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer)),
              ),
            ],
            if (showHcap) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  '-$hcap${strokes > 0 ? ' ${'•' * strokes.clamp(0, 2)}' : ''}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ],
              ]),
              if (spotsActive)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SpotsDots(
                    count:    spotsCount,
                    onAdd:    onSpotsAdd ?? () {},
                    onRemove: onSpotsRemove ?? () {},
                  ),
                ),
            ],
          ),
        ),
        // Tapping a scored row opens its inline editor (no pencil affordance —
        // consistent with the other score screens, where tapping the score is
        // the edit gesture).
        const SizedBox(width: 8),
        Container(
          width: 40, height: 36,
          decoration: BoxDecoration(
            color: boxBg, border: boxBorder,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: gross != null
                ? Text('$gross',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold))
                : const SizedBox.shrink(),
          ),
        ),
      ]),
    ));

    if (onTap == null) return inner;
    return InkWell(onTap: onTap, child: inner);
  }
}

// ---------------------------------------------------------------------------
// Inline score picker (net-centred) — same behavior as points_531_screen
// ---------------------------------------------------------------------------

class _InlinePicker extends StatefulWidget {
  final int  par;
  final int  strokes;
  final int? currentScore;
  final void Function(int) onScoreSelected;

  const _InlinePicker({
    required this.par,
    required this.strokes,
    required this.currentScore,
    required this.onScoreSelected,
  });

  @override
  State<_InlinePicker> createState() => _InlinePickerState();
}

class _InlinePickerState extends State<_InlinePicker> {
  static const double _itemWidth  = 52.0;
  static const double _itemMargin = 5.0;
  static const double _itemTotal  = _itemWidth + _itemMargin * 2;

  late final ScrollController _ctrl;

  double _offsetFor(int par, int strokes) {
    final netPar   = par + strokes;
    final startIdx = (netPar - 3).clamp(0, 11);
    return (startIdx * _itemTotal).clamp(0.0, double.infinity);
  }

  @override
  void initState() {
    super.initState();
    _ctrl = ScrollController(
        initialScrollOffset: _offsetFor(widget.par, widget.strokes));
  }

  @override
  void didUpdateWidget(covariant _InlinePicker old) {
    super.didUpdateWidget(old);
    if (old.par != widget.par || old.strokes != widget.strokes) {
      final target = _offsetFor(widget.par, widget.strokes);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ctrl.hasClients) return;
        _ctrl.jumpTo(target.clamp(0.0, _ctrl.position.maxScrollExtent));
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final scores = List.generate(12, (i) => i + 1);

    return Container(
      height: 68,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.12),
        border: Border(
          top: BorderSide(color: theme.colorScheme.primary.withOpacity(0.2)),
        ),
      ),
      child: ListView.builder(
        controller:      _ctrl,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        itemCount: scores.length + (widget.currentScore != null ? 1 : 0),
        itemBuilder: (_, i) {
          if (widget.currentScore != null && i == scores.length) {
            return Padding(
              padding: const EdgeInsets.only(left: 12),
              child: GestureDetector(
                onTap: () => widget.onScoreSelected(-1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: theme.colorScheme.error.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Clear',
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            );
          }
          final s   = scores[i];
          final sel = s == widget.currentScore;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
            child: NetScoreButton(
              score: s, par: widget.par, strokes: widget.strokes,
              selected: sel, width: _itemWidth, height: 48,
              onTap: () => widget.onScoreSelected(s),
            ),
          );
        },
      ),
    );
  }
}

// ===========================================================================
// 18-hole points grid
// ===========================================================================

class _WolfGrid extends StatelessWidget {
  final WolfSummary      summary;
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int) onTapHole;

  const _WolfGrid({
    required this.summary,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    required this.onTapHole,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const double labelColW = 60.0;
    const double cellW     = 34.0;
    const double rowH      = 26.0;
    final holeRange = List.generate(18, (i) => i + 1);

    // hole → playerId → points
    final pointsByHole = <int, Map<int, double>>{};
    final wolfByHole   = <int, int>{};
    for (final h in summary.holes) {
      wolfByHole[h.hole] = h.wolfId;
      for (final e in h.entries) {
        pointsByHole.putIfAbsent(h.hole, () => {})[e.playerId] = e.points;
      }
    }
    final totals = {for (final p in summary.players) p.playerId: p};

    Widget cell(int h, Widget child) {
      final isCur = h == currentHole;
      return GestureDetector(
        onTap: () => onTapHole(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: cellW, height: rowH, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isCur
                ? theme.colorScheme.primaryContainer.withOpacity(0.35) : null,
            border: isCur
                ? Border.all(color: theme.colorScheme.primary.withOpacity(0.6),
                    width: 1.2)
                : null,
          ),
          child: child,
        ),
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Wolf points',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hole-number header.
                  Row(children: [
                    SizedBox(width: labelColW, height: rowH,
                      child: const Align(alignment: Alignment.centerLeft,
                        child: Text('Hole',
                            style: TextStyle(fontSize: 11,
                                fontWeight: FontWeight.bold)))),
                    for (final h in holeRange)
                      cell(h, Text('$h',
                          style: const TextStyle(fontSize: 11,
                              fontWeight: FontWeight.bold))),
                  ]),
                  // Wolf row — who held the Wolf each hole.
                  Row(children: [
                    SizedBox(width: labelColW, height: rowH,
                      child: Align(alignment: Alignment.centerLeft,
                        child: Text('Wolf',
                            style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic)))),
                    for (final h in holeRange)
                      cell(h, Text(
                          (totals[wolfByHole[h]]?.shortName ?? '')
                              .characters.take(3).toString(),
                          style: const TextStyle(fontSize: 9))),
                  ]),
                  Container(
                    height: 1,
                    width: labelColW + cellW * holeRange.length,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // One row per player — per-hole points + running total.
                  for (final m in players)
                    Row(children: [
                      SizedBox(width: labelColW, height: rowH,
                        child: Align(alignment: Alignment.centerLeft,
                          child: Row(children: [
                            Flexible(child: Text(m.player.displayShort,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(fontWeight: FontWeight.w600))),
                          ]))),
                      for (final h in holeRange)
                        cell(h, Builder(builder: (_) {
                          final pts = pointsByHole[h]?[m.player.id];
                          if (pts == null) {
                            return Text('·', style: theme.textTheme.labelSmall
                                ?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant));
                          }
                          final pos = pts > 0;
                          return Text(
                            '${pos ? '+' : ''}${_fmtPoints(pts)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: pts == 0
                                    ? theme.colorScheme.onSurfaceVariant
                                    : pos
                                        ? Colors.green.shade700
                                        : theme.colorScheme.error),
                          );
                        })),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Standings line.
            Wrap(spacing: 12, runSpacing: 4, children: [
              for (final p in summary.players)
                Text('${p.shortName}: ${p.points >= 0 ? '+' : ''}'
                    '${_fmtPoints(p.points)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: p.points > 0
                            ? Colors.green.shade700
                            : p.points < 0
                                ? theme.colorScheme.error
                                : null)),
            ]),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Rotation bottom sheet — drag to re-set the Wolf order mid-round
// ===========================================================================

class _RotationSheet extends StatefulWidget {
  final List<int>        order;
  final List<Membership> members;
  /// First N positions are frozen (their hole has been played) — not draggable.
  final int              lockedCount;
  const _RotationSheet({
    required this.order,
    required this.members,
    this.lockedCount = 0,
  });

  @override
  State<_RotationSheet> createState() => _RotationSheetState();
}

class _RotationSheetState extends State<_RotationSheet> {
  late List<int> _order;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.order);
  }

  Membership? _memberOf(int id) {
    for (final m in widget.members) {
      if (m.player.id == id) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text('Wolf rotation',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
              widget.lockedCount > 0
                  ? 'Played holes are locked. Reorder only the later positions, '
                    'or reset the game to change an earlier Wolf.'
                  : 'Drag to set who is the Wolf, hole by hole.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: _order.length,
              onReorder: (a, b) {
                setState(() {
                  if (b > a) b -= 1;
                  // Never move into (or out of) the locked prefix.
                  if (a < widget.lockedCount) return;
                  if (b < widget.lockedCount) b = widget.lockedCount;
                  final id = _order.removeAt(a);
                  _order.insert(b, id);
                });
              },
              itemBuilder: (context, i) {
                final m = _memberOf(_order[i]);
                final locked = i < widget.lockedCount;
                return Container(
                  key: ValueKey(_order[i]),
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withOpacity(locked ? 0.25 : 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Text('${i + 1}',
                          style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(m?.player.name ?? 'Player',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: locked
                                ? theme.colorScheme.onSurfaceVariant
                                : null))),
                    locked
                        ? Icon(Icons.lock_outline, size: 18,
                            color: theme.colorScheme.onSurfaceVariant)
                        : ReorderableDragStartListener(
                            index: i,
                            child: Icon(Icons.drag_handle,
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                  ]),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_order),
              child: const Text('Save rotation'),
            ),
          ),
        ]),
      ),
    );
  }
}
