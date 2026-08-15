/// screens/survivor_screen.dart
///
/// Play screen for the Survivor casual game.  Pure score entry (no per-hole
/// decisions) plus a live read-out of the horse race:
///   • Survivor banner — which Survivor is running, whether this hole is an
///     elimination or a decider, and who is still alive.
///   • Score-entry rows (modeled on rabbit_screen) with an inline
///     net-centred picker; a player knocked out of the current Survivor is
///     dimmed and badged OUT.
///   • Per-hole outcome line (who went out / who took the Survivor).
///   • Survivors strip — range, winner and payout for each one.
///   • 18-hole grid — per-hole elimination / winner marks.
///
/// State comes from the server summary (services.survivor.survivor_summary),
/// refreshed after every score submission.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/icon_help_sheet.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/net_score_button.dart' show scoreCellWithDots;
import '../widgets/round_chat_button.dart';
import '../widgets/spots_capture.dart';
import '../utils/match_handicap.dart';
import '../utils/play_order.dart';
import '../utils/round_complete.dart';

/// Handicap strokes a player receives on a hole, read straight from the
/// Survivor summary.  The engine emits its own allocation for EVERY hole,
/// scored or not, so the dots show the whole plan up front and never snap
/// around as holes are entered — no client-side re-derivation.
int? _summaryStrokes(SurvivorHole? hole, int playerId) {
  if (hole == null) return null;
  for (final e in hole.entries) {
    if (e.playerId == playerId) return e.strokes.clamp(0, 9);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class SurvivorScreen extends StatefulWidget {
  final int foursomeId;
  const SurvivorScreen({super.key, required this.foursomeId});

  @override
  State<SurvivorScreen> createState() => _SurvivorScreenState();
}

class _SurvivorScreenState extends State<SurvivorScreen> with SpotsCaptureMixin {
  final Map<int, Map<int, int>> _pending = {};
  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;
  // When the user taps an already-scored player to correct a past hole, this
  // holds their id so the inline picker re-opens for that row (there's no
  // hot-spot on a completed hole).  Cleared on navigation and after saving.
  int? _editingPlayerId;

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
      rp.loadSurvivor(widget.foursomeId);
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
    rp.loadSurvivor(widget.foursomeId);
    if (rp.round?.activeGames.contains('spots') ?? false) {
      rp.loadSpots(widget.foursomeId);
    }
  }

  List<Membership> _realMembers(Round? round) {
    final fs = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    final members =
        fs.memberships.where((m) => !m.player.isPhantom).toList();
    // Longest-tee-first (hole-1 yardage), then membership order for ties —
    // matches the scorecard and the other non-team games.
    final sc = context.read<RoundProvider>().scorecard;
    if (sc != null) {
      final firstHole = sc.holeData(1);
      int yards(int pid) => firstHole?.scoreFor(pid)?.yards ?? 0;
      final idx = {
        for (var i = 0; i < members.length; i++) members[i].player.id: i,
      };
      members.sort((a, b) {
        final d = yards(b.player.id).compareTo(yards(a.player.id));
        return d != 0 ? d : idx[a.player.id]!.compareTo(idx[b.player.id]!);
      });
    }
    return members;
  }

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
  /// move to the next hole the moment the last player's score completes the
  /// hole.  Skips clears (score == -1) and edits to an already-complete hole.
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
      // lost the moment the user navigates to another hole.  Auto-advance
      // deliberately does not fire on an edit.
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

  /// Holes this group plays, in order (back-9 / 9-hole / shotgun aware).
  List<int> _playOrder(RoundProvider rp) =>
      roundPlayOrder(rp.round, rp.scorecard);

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = _realMembers(rp.round).map((m) => m.player.id).toSet();
    final order = _playOrder(rp);
    for (final h in order) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      final allScored = hd.scores
          .where((s) => realIds.contains(s.playerId))
          .every((s) => s.grossScore != null);
      if (!allScored && !rp.localPendingByHole.containsKey(h)) {
        setState(() => _selectedHole = h);
        return;
      }
    }
    setState(() => _selectedHole = order.isEmpty ? 18 : order.last);
  }

  void _advance() {
    final next = nextInOrder(
        _playOrder(context.read<RoundProvider>()), _selectedHole);
    if (next != null) setState(() { _selectedHole = next; _editingPlayerId = null; });
  }
  void _retreat() {
    final prev = prevInOrder(
        _playOrder(context.read<RoundProvider>()), _selectedHole);
    if (prev != null) setState(() { _selectedHole = prev; _editingPlayerId = null; });
  }

  /// Persist whatever is pending for [hole] without changing the selected hole.
  /// Used both by the save+advance button and by inline edits to past holes.
  Future<void> _saveHole(
      BuildContext ctx, int hole, List<Membership> players) async {
    final edits = _pending[hole];
    if (edits == null || edits.isEmpty) return;
    final scores = edits.entries
        .map((e) => {'player_id': e.key, 'gross_score': e.value})
        .toList();
    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
      foursomeId: widget.foursomeId, holeNumber: hole, scores: scores);
    if (!mounted) return;
    if (!ok) { _snack(ctx, rp.error ?? 'Failed to save hole.',
        () => _saveHole(ctx, hole, players)); return; }
    setState(() { _pending.remove(hole); });
    rp.loadSurvivor(widget.foursomeId);
  }

  Future<void> _saveAndAdvance(BuildContext ctx, List<Membership> players) async {
    final hole = _selectedHole;
    if (_pending[hole]?.isNotEmpty ?? false) {
      await _saveHole(ctx, hole, players);
      if (!mounted || _pending.containsKey(hole)) return;   // save failed
    }
    _advance();
  }

  Future<void> _finishRound(BuildContext ctx, List<Membership> players) async {
    final rp = context.read<RoundProvider>();
    // Soft gate: warn if finishing early (holes still unscored), consistent
    // with the other score screens.
    final sc = rp.scorecard;
    int unscored = 0;
    if (sc != null) {
      for (final h in _playOrder(rp)) {
        if (_effectiveScores(sc, h).isEmpty) unscored++;
      }
    }
    if (!await confirmCompleteRound(ctx, unscoredHoles: unscored)) return;
    if (!mounted) return;
    final sync = context.read<SyncService>();
    final roundId = rp.round?.id;
    final pendingForHole = _pending[_selectedHole];
    if (pendingForHole != null && pendingForHole.isNotEmpty) {
      final scores = pendingForHole.entries
          .map((e) => {'player_id': e.key, 'gross_score': e.value})
          .toList();
      final ok = await rp.submitHole(
        foursomeId: widget.foursomeId, holeNumber: _selectedHole, scores: scores);
      if (!mounted) return;
      if (!ok) { _snack(ctx, rp.error ?? 'Failed to save hole.',
          () => _finishRound(ctx, players)); return; }
      setState(() { _pending.remove(_selectedHole); });
    }
    await sync.waitUntilIdle();
    if (!mounted) return;
    if (roundId != null) {
      // Mark the round complete (locks scores, moves it to the Completed
      // list).  Without this the round stays in_progress and is stuck in the
      // active list even after "Done".
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

  void _snack(BuildContext ctx, String msg, VoidCallback retry) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Theme.of(ctx).colorScheme.error,
      action: SnackBarAction(label: 'Retry',
          textColor: Theme.of(ctx).colorScheme.onError, onPressed: retry),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final sc   = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';

    if (!_initialJumpDone && sc != null &&
        rp.activeFoursomeId == widget.foursomeId) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstUnplayed(context.read<RoundProvider>());
      });
    }
    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadSurvivor(widget.foursomeId);
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
        title: 'Survivor',
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: showExit ? 'Exit to rounds' : 'Close',
          onPressed: showExit
              ? () => Navigator.of(context).popUntil(
                  (r) => r.settings.name == '/casual-rounds' || r.isFirst)
              : () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (sync.hasPending)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Badge(
                label: Text('${sync.pendingCount}'),
                child: IconButton(
                  icon: sync.state == SyncState.syncing
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.cloud_upload_outlined),
                  tooltip: sync.state == SyncState.syncing
                      ? 'Syncing…' : 'Tap to sync ${sync.pendingCount} score(s)',
                  onPressed: sync.state == SyncState.syncing
                      ? null : () => sync.recheck(),
                ),
              ),
            ),
          if (rp.round != null)
            RoundChatButton(roundId: rp.round!.id),
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null ? null
                : () => Navigator.of(context).pushNamed(
                    '/leaderboard', arguments: rp.round!.id),
          ),
          // Overflow: end the round early (soft gate) + the icon-legend help.
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'end':
                  _finishRound(context, _realMembers(rp.round));
                  break;
                case 'help':
                  showScoreEntryHelp(context);
                  break;
              }
            },
            itemBuilder: (_) => [
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
      body: _buildBody(context, rp, isComplete),
      bottomNavigationBar: sc == null ? null : _buildBottomNav(context, rp, sc),
    );
  }

  Widget _buildBody(BuildContext ctx, RoundProvider rp, bool isComplete) {
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
            rp.loadSurvivor(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }
    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final summary  = rp.survivorSummary;
    final players  = _realMembers(rp.round);
    final holeInfo = summary?.holeFor(_selectedHole);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;

    // Survivor state for the SELECTED hole.  Who is alive going into a hole
    // is a property of that hole (a Survivor resets the roster), so read it
    // straight off the summary rather than tracking it here; an unscored hole
    // inherits the state of the last scored one before it in PLAY ORDER.
    int     svIndex   = holeInfo?.survivor ?? summary?.currentSurvivor ?? 1;
    Set<int> aliveIds = players.map((m) => m.player.id).toSet();
    int?    outId;
    if (summary != null) {
      final scored = holeInfo != null && holeInfo.isScored;
      if (scored) {
        aliveIds = holeInfo.entries
            .where((e) => e.isAlive).map((e) => e.playerId).toSet();
        outId = holeInfo.entries
            .where((e) => !e.isAlive)
            .map((e) => e.playerId).firstOrNull;
      } else {
        // Unscored: carry the state forward from the last scored hole that
        // belongs to the SAME Survivor — a new Survivor starts all-square.
        final order    = _playOrder(rp);
        final startIdx = order.indexOf(_selectedHole);
        for (int i = startIdx - 1; i >= 0; i--) {
          final hi = summary.holeFor(order[i]);
          if (hi == null || !hi.isScored) continue;
          if (hi.survivor != svIndex) break;   // previous Survivor — reset
          // The hole that settled this Survivor ends it; the next one is fresh.
          if (hi.winnerId != null || hi.event == 'split' ||
              hi.event == 'no_blood') {
            svIndex = svIndex + 1;
            break;
          }
          final stillIn = hi.entries
              .where((e) => e.isAlive && !e.isEliminated)
              .map((e) => e.playerId).toSet();
          if (stillIn.isNotEmpty && stillIn.length < aliveIds.length) {
            aliveIds = stillIn;
            outId = players.map((m) => m.player.id)
                .where((pid) => !stillIn.contains(pid)).firstOrNull;
          }
          break;
        }
      }
    }
    final isDecider = aliveIds.length == 2;

    return Column(children: [
      Expanded(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (summary != null)
              _SurvivorBanner(
                survivorIndex: svIndex,
                isDecider:     isDecider,
                aliveShorts:   players
                    .where((m) => aliveIds.contains(m.player.id))
                    .map((m) => m.player.displayShort)
                    .toList(),
                outShort: outId == null ? null : players
                    .where((m) => m.player.id == outId)
                    .map((m) => m.player.displayShort)
                    .firstOrNull,
                isLastHole: _selectedHole == _playOrder(rp).lastOrNull,
              ),
            const SizedBox(height: 12),
            _HoleHeader(holeNumber: _selectedHole, holeData: holeData,
                onHelp: () => _showSurvivorLegend(context)),
            const SizedBox(height: 12),
            _HoleScoreCard(
              holeData:   holeData,
              players:    players,
              scorecard:  sc,
              scores:     scores,
              hotSpotIdx: hotSpot,
              par:        par,
              summary:    summary,
              holeInfo:   holeInfo,
              aliveIds:   aliveIds,
              editingPlayerId: _editingPlayerId,
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
              const SizedBox(height: 10),
              _OutcomeLine(hole: holeInfo),
            ],
            const SizedBox(height: 12),
            if (summary != null && summary.survivors.isNotEmpty) ...[
              _SurvivorStrip(summary: summary),
              const SizedBox(height: 12),
            ],
            if (summary != null)
              _SurvivorGrid(
                summary: summary, players: players, scorecard: sc,
                currentHole: _selectedHole,
                onTapHole: (h) => setState(() {
                  _selectedHole = h; _editingPlayerId = null;
                })),
            const SizedBox(height: 16),
          ]),
        ),
        ),
      ),
    ]);
  }

  /// Per-hole row legend ("?" in the hole header) — explains the Rabbit row
  /// markings, matching the legend the other score screens offer.
  void _showSurvivorLegend(BuildContext context) {
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
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
            Text('Survivor row guide',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            row(Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(4)),
                  child: Text('OUT', style: theme.textTheme.labelSmall
                      ?.copyWith(fontSize: 9, fontWeight: FontWeight.bold))),
                'Knocked out',
                'This player had the worst score on an elimination hole, so they are out of the CURRENT Survivor — their row greys out and their score no longer counts. They are back in as soon as the next Survivor starts.'),
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

  Widget _buildBottomNav(BuildContext ctx, RoundProvider rp, Scorecard sc) {
    final players = _realMembers(rp.round);
    final scores  = _effectiveScores(sc, _selectedHole);
    final allDone = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final order   = _playOrder(rp);
    final prevHole = prevInOrder(order, _selectedHole);
    final nextHole = nextInOrder(order, _selectedHole);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: prevHole != null ? _retreat : null,
              icon: const Icon(Icons.chevron_left, size: 20),
              label: Text(prevHole != null ? 'Hole $prevHole' : 'Hole'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: nextHole == null || isComplete
                ? FilledButton.icon(
                    onPressed: rp.submitting ? null : () => _finishRound(ctx, players),
                    icon: const Icon(Icons.emoji_events, size: 20),
                    label: const Text('Done'),
                  )
                : FilledButton.icon(
                    onPressed: (allDone && !rp.submitting)
                        ? () => _saveAndAdvance(ctx, players) : null,
                    icon: rp.submitting
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.chevron_right, size: 20),
                    label: Text(rp.submitting ? 'Saving…' : 'Hole $nextHole'),
                    iconAlignment: IconAlignment.end,
                  ),
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Rabbit banner — who holds it + lead, and the active segment
// ===========================================================================

class _HoleHeader extends StatelessWidget {
  final int holeNumber;
  final ScorecardHole? holeData;
  /// Opens the per-hole row legend ("?"), matching the other score screens.
  final VoidCallback? onHelp;
  const _HoleHeader({
    required this.holeNumber,
    required this.holeData,
    this.onHelp,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = holeData;
    final sub = h == null ? ''
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
              Text(sub, textAlign: TextAlign.center,
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
// Score-entry card
// ===========================================================================

int  _survivorZeroSpots(int _) => 0;
void _survivorNoopPid(int _) {}

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, int>    scores;
  final int              hotSpotIdx;
  final int              par;
  final SurvivorSummary?   summary;
  final SurvivorHole?      holeInfo;
  /// Who is still alive in the current Survivor.  Anyone missing is OUT for
  /// the rest of it — their row dims and their score can't win the hole.
  final Set<int>         aliveIds;
  final int?             editingPlayerId;  // scored row the user tapped to fix
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership) onEditTap;
  final bool                   spotsActive;
  final int  Function(int pid) spotsCountFor;
  final void Function(int pid) onSpotsAdd;
  final void Function(int pid) onSpotsRemove;

  const _HoleScoreCard({
    required this.holeData,
    required this.players,
    required this.scorecard,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.summary,
    required this.holeInfo,
    required this.aliveIds,
    required this.editingPlayerId,
    required this.onScoreSelected,
    required this.onEditTap,
    this.spotsActive   = false,
    this.spotsCountFor = _survivorZeroSpots,
    this.onSpotsAdd    = _survivorNoopPid,
    this.onSpotsRemove = _survivorNoopPid,
  });

  String get _mode       => summary?.handicapMode ?? 'net';
  int    get _netPercent => summary?.netPercent   ?? 100;

  int? get _lowPlaying {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null || _mode == 'gross') return 0;
    // Prefer the engine's own allocation (gross − net) once the hole is scored,
    // so the dots match how the rabbit was actually decided.
    final fromSummary = _summaryStrokes(holeInfo, m.player.id);
    if (fromSummary != null) return fromSummary;
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

  bool _isOut(int playerId) => !aliveIds.contains(playerId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: players.asMap().entries.expand((entry) {
          final idx = entry.key;
          final m   = entry.value;
          final gross = scores[m.player.id];
          final isHot = idx == hotSpotIdx;
          final isEditing = editingPlayerId == m.player.id;
          // A scored row that isn't the live hot-spot can be tapped to correct
          // it — that re-opens the inline picker (a completed hole has no
          // hot-spot, so without this there'd be no way to edit a past hole).
          final editable = gross != null && !isHot;
          final strokes = _strokesForHole(m, holeData);
          final row = _PlayerRow(
              member:   m,
              gross:    gross,
              isHot:    isHot,
              strokes:  strokes,
              showHcap: _mode != 'gross',
              hcap:     effectiveMatchHandicap(
                mode: _mode, netPercent: _netPercent,
                playingHandicap: m.playingHandicap,
                lowestPlayingHandicap: _lowPlaying),
              isOut:    _isOut(m.player.id),
              isEditing: isEditing,
              onTap: editable ? () => onEditTap(m) : null,
              spotsActive:   spotsActive,
              spotsCount:    spotsActive ? spotsCountFor(m.player.id) : 0,
              onSpotsAdd:    spotsActive ? () => onSpotsAdd(m.player.id) : null,
              onSpotsRemove: spotsActive ? () => onSpotsRemove(m.player.id) : null,
            );
          if (isHot || isEditing) {
            // Active player + picker share ONE bounding box (no teams in
            // Rabbit → brand pine). Flush-left bold bar, right inset so the
            // right line shows, faint wash fill.
            final boxColor = Theme.of(context).colorScheme.primary;
            return [
              Container(
                margin: const EdgeInsets.fromLTRB(0, 6, 8, 6),
                decoration: BoxDecoration(
                  color: boxColor.withOpacity(0.10),
                  border: Border(
                    top:    BorderSide(color: boxColor, width: 1.5),
                    bottom: BorderSide(color: boxColor, width: 1.5),
                    right:  BorderSide(color: boxColor, width: 1.5),
                    left:   BorderSide(color: boxColor, width: 4.0),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    row,
                    InlineScorePicker(
                      par: par, strokes: strokes, currentScore: gross,
                      boxBorderColor: boxColor,
                      boxFillColor:   Colors.white,
                      onScoreSelected: (s) => onScoreSelected(m, s)),
                  ],
                ),
              ),
            ];
          }
          return [row];
        }).toList(),
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
  /// Knocked out of the CURRENT Survivor — dimmed, badged OUT, and its
  /// score is ignored by the decider.
  final bool       isOut;
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
    required this.isOut,
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
    final active = isHot || isEditing;
    final boxBg = active ? Colors.white : Colors.transparent;
    final boxBorder = active
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: theme.colorScheme.outline);

    final row = Container(
      decoration: BoxDecoration(
        // Active row is transparent so the bounding box's wash/frame shows;
        // an eliminated row keeps a grey wash so it reads as out of play.
        color: active
            ? Colors.transparent
            : (isOut ? theme.colorScheme.surfaceContainerHighest
                          .withOpacity(0.45) : null),
        border: active
            ? const Border()
            : Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
                left: BorderSide.none,
              ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        if (isOut)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant.withOpacity(0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('OUT',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9, fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
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
            if (showHcap && hcap > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  'gets $hcap',
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
        // consistent with the other score screens). Handicap stroke dots sit
        // in a strip above the box (shared scoreCellWithDots) so a net / SO
        // player can see where their strokes fall — matching the other screens.
        const SizedBox(width: 8),
        scoreCellWithDots(
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
          strokes,
          theme.colorScheme.primary,
        ),
      ]),
    );

    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}


// ===========================================================================
// Survivor banner
// ===========================================================================

class _SurvivorBanner extends StatelessWidget {
  final int          survivorIndex;
  /// Two left standing — this hole decides it.
  final bool         isDecider;
  final List<String> aliveShorts;
  final String?      outShort;
  /// No room on the last hole to eliminate AND decide, so it settles whatever
  /// is standing — worth saying out loud before they play it.
  final bool         isLastHole;

  const _SurvivorBanner({
    required this.survivorIndex,
    required this.isDecider,
    required this.aliveShorts,
    required this.outShort,
    required this.isLastHole,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isDecider ? Colors.green.shade700 : theme.colorScheme.primary;

    final String headline;
    final String detail;
    if (isLastHole) {
      headline = 'Survivor $survivorIndex — last hole';
      detail = isDecider
          ? 'Low score takes it. A tie splits ${outShort ?? 'the loser'}’s entry.'
          : 'Low ball wins outright. Any tie for low and nobody pays.';
    } else if (isDecider) {
      headline = 'Survivor $survivorIndex — decider';
      detail = '${aliveShorts.join(' v ')} for it'
          '${outShort == null ? '' : ' · $outShort is out'}'
          '. Low score wins; a tie carries to the next hole.';
    } else {
      headline = 'Survivor $survivorIndex — elimination';
      detail = 'Worst score goes out. If the two worst tie, nobody goes and '
               'the next hole eliminates instead.';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(isDecider ? Icons.sports_score : Icons.filter_alt_outlined,
              size: 18, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(headline,
                style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold, color: color)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(detail,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

// ===========================================================================
// Per-hole outcome line
// ===========================================================================

class _OutcomeLine extends StatelessWidget {
  final SurvivorHole hole;
  const _OutcomeLine({required this.hole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String text;
    Color color = theme.colorScheme.onSurfaceVariant;
    switch (hole.event) {
      case 'eliminated':
        text = '${hole.eliminatedShort} had the worst score — knocked out.';
        color = theme.colorScheme.error;
      case 'no_elimination':
        text = 'The two worst scores tied — nobody goes, everyone plays on.';
      case 'won':
        text = '${hole.winnerShort} wins Survivor ${hole.survivor ?? ''}'
               '${hole.role == 'final' ? ' on the last hole' : ''}!';
        color = Colors.green.shade700;
      case 'carried':
        text = 'Tied — the same two carry on to the next hole.';
        color = theme.colorScheme.primary;
      case 'split':
        text = 'Tied on the last hole — the two split '
               '${hole.eliminatedShort ?? 'the loser'}’s entry.';
        color = theme.colorScheme.primary;
      case 'no_blood':
        text = 'Tied for low on the last hole — no blood, nobody pays.';
      default:
        text = 'No change.';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600, color: color)),
    );
  }
}

// ===========================================================================
// Survivors strip
// ===========================================================================

class _SurvivorStrip extends StatelessWidget {
  final SurvivorSummary summary;
  const _SurvivorStrip({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Survivors',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          const SizedBox(height: 6),
          Column(children: [
            for (final s in summary.survivors)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(width: 92,
                    child: Text(s.rangeLabel,
                        style: theme.textTheme.bodySmall)),
                  Expanded(child: _result(theme, s)),
                  if (s.isLive)
                    Text('in play',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))
                  else if (s.payout > 0)
                    Text('\$${s.payout.toStringAsFixed(2)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w600)),
                ]),
              ),
          ]),
        ]),
      ),
    );
  }

  Widget _result(ThemeData theme, SurvivorLeg s) {
    if (s.isLive) {
      return Text(
        s.eliminatedShort == null
            ? 'Everyone still in'
            : '${s.eliminatedShort} out — decider',
        style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant),
      );
    }
    if (s.isNoBlood) {
      return Text('No blood',
          style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant));
    }
    if (s.isSplit) {
      return Text('Split · ${s.eliminatedShort ?? '?'} pays',
          style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600, color: theme.colorScheme.primary));
    }
    return Text(
      '${s.winnerShort} wins'
      '${s.eliminatedShort == null ? '' : ' · ${s.eliminatedShort} out'}',
      style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600, color: theme.colorScheme.primary),
    );
  }
}

// ===========================================================================
// Survivor by-hole grid
// ===========================================================================

class _SurvivorGrid extends StatelessWidget {
  final SurvivorSummary summary;
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int) onTapHole;

  const _SurvivorGrid({
    required this.summary, required this.players, required this.scorecard,
    required this.currentHole, required this.onTapHole});

  /// Handicap strokes for [m] on [hole] — the engine's own allocation, which
  /// is defined for unscored holes too, so the whole plan shows up front.
  int _strokesFor(Membership m, int hole) {
    final h = summary.holeFor(hole);
    if (h == null) return 0;
    for (final e in h.entries) {
      if (e.playerId == m.player.id) return e.strokes.clamp(0, 9);
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const double labelColW = 56.0;
    const double cellW = 34.0;
    const double rowH  = 32.0;
    final holeRange = summary.holes.isNotEmpty
        ? summary.holes.map((h) => h.hole).toList()
        : List.generate(18, (i) => i + 1);

    Widget headerCell(int h) {
      final info    = summary.holeFor(h);
      final isNow   = h == currentHole;
      // A hole that settled a Survivor gets a heavier frame — that's where the
      // money changed hands.
      final settled = info != null &&
          (info.winnerId != null || info.event == 'split' ||
           info.event == 'no_blood');
      return GestureDetector(
        onTap: () => onTapHole(h),
        child: Container(
          width: cellW, height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isNow
                ? theme.colorScheme.primary.withOpacity(0.14)
                : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: settled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: settled ? 2 : 1),
            ),
          ),
          child: Text('$h',
              style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: isNow ? FontWeight.bold : FontWeight.w500,
                  color: isNow ? theme.colorScheme.primary : null)),
        ),
      );
    }

    Widget cell(Membership m, int h) {
      final info = summary.holeFor(h);
      final entry = info?.entries
          .where((e) => e.playerId == m.player.id).firstOrNull;
      final gross = entry?.gross;
      final out   = entry != null && !entry.isAlive;
      final won   = entry?.isWinner ?? false;
      final knocked = entry?.isEliminated ?? false;

      Color? bg;
      Color? fg;
      if (won) {
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
      } else if (knocked) {
        bg = theme.colorScheme.errorContainer.withOpacity(0.45);
        fg = theme.colorScheme.error;
      } else if (out) {
        fg = theme.colorScheme.outline;
      }

      return GestureDetector(
        onTap: () => onTapHole(h),
        child: Container(
          width: cellW, height: rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(
              color: won ? Colors.green.shade400 : Colors.transparent),
            borderRadius: BorderRadius.circular(3),
          ),
          child: scoreCellWithDots(
            Text(gross?.toString() ?? '',
                style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: (won || knocked)
                        ? FontWeight.bold : FontWeight.w500,
                    color: fg)),
            _strokesFor(m, h),
            theme.colorScheme.primary,
          ),
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
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Survivor by hole',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('green = won it · red = knocked out',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
          ]),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const SizedBox(width: labelColW),
                for (final h in holeRange) headerCell(h),
              ]),
              for (final m in players)
                Row(children: [
                  SizedBox(
                    width: labelColW,
                    child: Text(m.player.displayShort,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  for (final h in holeRange) cell(m, h),
                ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
