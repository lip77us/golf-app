/// screens/nassau_screen.dart
/// --------------------------
/// Score-entry and live match view for a Nassau game.
///
/// Entry pattern mirrors points_531_screen.dart:
///   • Shared _pending map + _selectedHole state (no PageController)
///   • Per-hole active card with inline score picker (hot-spot row)
///   • 18-hole summary grid with per-hole winner indicator
///   • Bottom hole-navigation bar (← Hole N-1 | Hole N+1 →)
/// Nassau-specific additions layered around the entry pattern:
///   • Team banner (Blue vs Orange colour dots + names)
///   • Presses strip (active/completed presses)
///   • F9 / B9 / Overall match status chips + Call Press button

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/spots_capture.dart';
import '../utils/match_handicap.dart';
import '../utils/nassau_team_style.dart';
import '../utils/round_complete.dart';

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class NassauScreen extends StatefulWidget {
  final int foursomeId;
  const NassauScreen({super.key, required this.foursomeId});

  @override
  State<NassauScreen> createState() => _NassauScreenState();
}

class _NassauScreenState extends State<NassauScreen> with SpotsCaptureMixin {
  /// Unsubmitted score edits for the current session.  hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;

  /// When set, tapping an already-scored player made THEM the active row so the
  /// inline picker edits their score in place (matching the casual score-entry
  /// form) instead of a modal sheet. Cleared once they pick a value or change
  /// holes.
  int? _editHotPid;

  // Polling timer used when a cross-foursome phantom is waiting for a donor
  // to score.  Refreshes the scorecard every 8 s so the phantom row updates
  // automatically without needing user interaction.
  Timer? _phantomPollTimer;

  // SyncService listener — fires every time the queue state changes.  We
  // watch for the pending-count drop to zero (the moment our just-saved
  // hole reaches the server) and reload the Nassau summary so the
  // F9/B9/ALL chips and presses strip reflect the latest match state
  // without the user having to navigate away and back.
  SyncService? _syncRef;
  VoidCallback? _syncWatcher;
  bool          _wasPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rp = context.read<RoundProvider>();
      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      } else {
        rp.refreshPendingOverlay();
      }
      rp.loadNassau(widget.foursomeId);
      if (rp.round?.activeGames.contains('spots') ?? false) {
        rp.loadSpots(widget.foursomeId);
      }

      // Register a direct listener so we catch the pending → idle
      // transition even when it completes within a single frame.
      final sync   = context.read<SyncService>();
      _syncRef     = sync;
      _wasPending  = sync.hasPending;
      _syncWatcher = () {
        if (!mounted) return;
        final nowPending = sync.hasPending;
        if (_wasPending && !nowPending) {
          context.read<RoundProvider>().loadNassau(widget.foursomeId);
        }
        _wasPending = nowPending;
      };
      sync.addListener(_syncWatcher!);
    });
  }

  @override
  void dispose() {
    _phantomPollTimer?.cancel();
    if (_syncWatcher != null) _syncRef?.removeListener(_syncWatcher!);
    disposeSpots();
    super.dispose();
  }

  Future<void> _refresh() async {
    final rp = context.read<RoundProvider>();
    await rp.loadScorecard(widget.foursomeId);
    rp.loadNassau(widget.foursomeId);
  }

  /// Start / stop the phantom polling timer based on whether a phantom is
  /// waiting to score the current hole.
  void _updatePhantomPolling(NassauSummary? nas, Map<int, int> scores,
      List<Membership> players) {
    final hasPhantom = nas?.phantom != null;
    final phantomWaiting = hasPhantom &&
        !scores.containsKey(nas!.phantom!.phantomPlayerId);

    if (phantomWaiting && _phantomPollTimer == null) {
      _phantomPollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
        if (!mounted) return;
        final rp = context.read<RoundProvider>();
        rp.loadScorecard(widget.foursomeId);
        rp.loadNassau(widget.foursomeId);
      });
    } else if (!phantomWaiting && _phantomPollTimer != null) {
      _phantomPollTimer!.cancel();
      _phantomPollTimer = null;
    }
  }

  // ── Player helpers ──────────────────────────────────────────────────────────

  /// Players ordered T1 first, T2 second per the nassau summary.
  /// Includes the cross-foursome phantom (if any) so its donor-status row
  /// is shown in the hole card and submission is blocked until it has a score.
  List<Membership> _orderedPlayers(
      Scorecard sc, Round? round, NassauSummary? nas) {
    final foursome = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;

    List<Membership> realMembers;
    Membership? phantomMember;

    if (foursome != null) {
      realMembers = foursome.memberships
          .where((m) => !m.player.isPhantom)
          .toList();
      // Include the cross-foursome phantom so its score entry blocks
      // "Save & Advance" until the donor has posted.
      // We check both nas.phantom (algorithm confirmed) AND whether the
      // scorecard already has a phantom score entry (cross-foursome path
      // in _build_scorecard appends it to h['scores'] always).
      final hasCrossPhantomEntry = sc.holes.isNotEmpty &&
          sc.holes.first.scores.any((s) =>
            foursome.memberships.any((m) => m.player.isPhantom && m.player.id == s.playerId));
      if (nas?.phantom != null || hasCrossPhantomEntry) {
        phantomMember = foursome.memberships
            .where((m) => m.player.isPhantom)
            .firstOrNull;
      }
    } else if (sc.holes.isEmpty) {
      return const [];
    } else {
      realMembers = sc.holes.first.scores
          .map((s) => Membership(
                id: s.playerId,
                player: PlayerProfile(
                  id: s.playerId,
                  name: s.playerName,
                  handicapIndex: '0',
                  isPhantom: false,
                  email: '',
                ),
                courseHandicap: 0,
                playingHandicap: s.handicapStrokes,
              ))
          .toList();
    }

    if (nas == null) return realMembers;

    final ordered = <Membership>[];
    for (final id in [
      ...nas.team1.map((p) => p.playerId),
      ...nas.team2.map((p) => p.playerId),
    ]) {
      final m = realMembers.where((m) => m.player.id == id).firstOrNull;
      if (m != null) ordered.add(m);
      // Phantom sits at the end of its team
      if (phantomMember != null && id == phantomMember.player.id) {
        ordered.add(phantomMember);
      }
    }
    // Include any real players not in a team (safety net) — never add phantom twice
    for (final m in realMembers) {
      if (!ordered.any((o) => o.player.id == m.player.id)) ordered.add(m);
    }
    if (phantomMember != null &&
        !ordered.any((o) => o.player.id == phantomMember!.player.id)) {
      ordered.add(phantomMember);
    }
    return ordered;
  }

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = _orderedPlayers(sc, rp.round, rp.nassauSummary)
        .map((m) => m.player.id)
        .toSet();
    for (int h = 1; h <= 18; h++) {
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
    // All 18 holes are complete — land on the last hole instead of hole 1.
    setState(() => _selectedHole = 18);
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

  int _hotSpotIdx(List<Membership> players, Map<int, int> scores) {
    for (int i = 0; i < players.length; i++) {
      // Phantom players are never a hot-spot — their score arrives automatically
      if (players[i].player.isPhantom) continue;
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  bool _allScored(List<Membership> players, Map<int, int> scores) =>
      players.every((m) => scores.containsKey(m.player.id));

  static Map<int, Map<int, int>> _mergePending(
    Map<int, Map<int, int>> dbPending,
    Map<int, Map<int, int>> uiEdits,
  ) {
    final result = <int, Map<int, int>>{};
    for (final e in dbPending.entries) result[e.key] = Map.from(e.value);
    for (final e in uiEdits.entries) {
      result[e.key] = {...(result[e.key] ?? {}), ...e.value};
    }
    return result;
  }

  void _selectScore(Membership player, int score, int hole) {
    setState(() {
      if (score == -1) {
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] =
            score;
      }
    });
  }

  void _advance() {
    if (_selectedHole < 18) setState(() { _selectedHole++; _editHotPid = null; });
  }

  void _retreat() {
    if (_selectedHole > 1) setState(() { _selectedHole--; _editHotPid = null; });
  }

  Future<void> _saveAndAdvance(
    BuildContext ctx,
    List<Membership> players,
    int par, {
    bool advance = true,
  }) async {
    final edits = _pending[_selectedHole];
    if (edits == null || edits.isEmpty) {
      if (advance) _advance();
      return;
    }
    final scores = edits.entries
        .map((e) => {'player_id': e.key, 'gross_score': e.value})
        .toList();

    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
      foursomeId: widget.foursomeId,
      holeNumber: _selectedHole,
      scores:     scores,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Failed to save hole.'),
        backgroundColor: Theme.of(ctx).colorScheme.error,
        action: SnackBarAction(
          label: 'Retry',
          textColor: Theme.of(ctx).colorScheme.onError,
          onPressed: () => _saveAndAdvance(ctx, players, par, advance: advance),
        ),
      ));
      return;
    }
    setState(() { _pending.remove(_selectedHole); });
    rp.loadNassau(widget.foursomeId);
    if (advance) _advance();
  }

  Future<void> _finishRound(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    if (!await confirmCompleteRound(ctx)) return;
    if (!mounted) return;
    final rp      = context.read<RoundProvider>();
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
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(rp.error ?? 'Failed to save hole.'),
          backgroundColor: Theme.of(ctx).colorScheme.error,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Theme.of(ctx).colorScheme.onError,
            onPressed: () => _finishRound(ctx, players, par),
          ),
        ));
        return;
      }
      setState(() { _pending.remove(_selectedHole); });
    }

    await sync.waitUntilIdle();
    if (!mounted) return;
    if (roundId != null) {
      // Mark the round complete so it leaves the active list (without this
      // "Done" only opened the leaderboard and the round stayed in_progress).
      final lb = await rp.completeRound(roundId);
      if (!mounted) return;
      if (lb == null) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(rp.error ?? 'Could not complete round.'),
          backgroundColor: Theme.of(ctx).colorScheme.error,
        ));
        return;
      }
      Navigator.of(ctx).pushReplacementNamed('/leaderboard', arguments: roundId);
    }
  }

  Future<void> _callPress(RoundProvider rp, int startHole) async {
    final ok = await rp.callNassauPress(
      widget.foursomeId,
      startHole: startHole,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(rp.error ?? 'Could not call press.'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  int _pressStartHole(NassauSummary nas) {
    final lastPlayed = nas.holes.isEmpty ? 0 : nas.holes.last.hole;
    return lastPlayed + 1;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp         = context.watch<RoundProvider>();
    final sync       = context.watch<SyncService>();
    final sc         = rp.scorecard;
    final nas        = rp.nassauSummary;
    final isComplete = rp.round?.status == 'complete';

    if (!_initialJumpDone &&
        sc != null &&
        rp.activeFoursomeId == widget.foursomeId) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstUnplayed(context.read<RoundProvider>());
      });
    }

    // After sync drains, reload nassau summary so margins/presses update.
    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadNassau(widget.foursomeId);
      });
    }
    _prevHadPending = nowHasPending;

    return Scaffold(
      appBar: GolfAppBar(
        // Close (X), not a back arrow — avoids being tapped as "previous hole".
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: nas != null
            ? 'Nassau — ${_modeLabel(nas.handicapMode, nas.netPercent)}'
            : 'Nassau',
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
                      ? null
                      : () => sync.recheck(),
                ),
              ),
            ),
          if (rp.round != null)
            RoundChatButton(roundId: rp.round!.id),
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null
                ? null
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: rp.round!.id),
          ),
        ],
      ),
      body: _buildBody(context, rp, sync, sc, nas, isComplete),
      bottomNavigationBar:
          sc == null ? null : _buildBottomBar(context, rp, sc, nas),
    );
  }

  Widget _buildBottomBar(
    BuildContext ctx,
    RoundProvider rp,
    Scorecard sc,
    NassauSummary? nas,
  ) {
    final players    = _orderedPlayers(sc, rp.round, nas);
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final par        = sc.holeData(_selectedHole)?.par ?? 4;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // F9 / B9 / Overall status + optional press button
          if (nas != null)
            _MatchStatusBar(
              summary:    nas,
              onPress:    nas.canPress
                  ? () => _callPress(rp, _pressStartHole(nas))
                  : null,
              submitting: rp.submitting,
            ),
          // Phantom waiting banner — shown when phantom blocks hole submission
          if (nas?.phantom != null && !allDone) ...[
            Builder(builder: (ctx2) {
              final realDone = _allScored(
                players.where((m) => !m.player.isPhantom).toList(),
                scores,
              );
              if (!realDone) return const SizedBox.shrink();
              final donorName = nas!.phantom!
                  .donorNameForHole(_selectedHole);
              return Container(
                width: double.infinity,
                color: Theme.of(ctx2).colorScheme.errorContainer,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                child: Row(children: [
                  Icon(Icons.hourglass_top,
                      size: 14,
                      color: Theme.of(ctx2)
                          .colorScheme
                          .onErrorContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Waiting for $donorName to post '
                      'hole $_selectedHole…',
                      style: Theme.of(ctx2)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                            color: Theme.of(ctx2)
                                .colorScheme
                                .onErrorContainer,
                          ),
                    ),
                  ),
                ]),
              );
            }),
          ],
          // Hole navigation
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectedHole > 1 ? _retreat : null,
                  icon: const Icon(Icons.chevron_left, size: 20),
                  label: Text(
                      _selectedHole > 1 ? 'Hole ${_selectedHole - 1}' : 'Previous'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _selectedHole == 18 || isComplete
                    ? FilledButton.icon(
                        onPressed: rp.submitting
                            ? null
                            : () => _finishRound(ctx, players, par),
                        icon: const Icon(Icons.emoji_events, size: 20),
                        label: const Text('Done'),
                      )
                    : FilledButton.icon(
                        onPressed: (allDone && !rp.submitting)
                            ? () => _saveAndAdvance(ctx, players, par)
                            : null,
                        icon: rp.submitting
                            ? const SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.chevron_right, size: 20),
                        label: Text(rp.submitting
                            ? 'Saving…'
                            : 'Hole ${_selectedHole + 1}'),
                        iconAlignment: IconAlignment.end,
                      ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext ctx,
    RoundProvider rp,
    SyncService sync,
    Scorecard? sc,
    NassauSummary? nas,
    bool isComplete,
  ) {
    if (rp.loadingScorecard && sc == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && sc == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(rp.error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              rp.loadScorecard(widget.foursomeId);
              rp.loadNassau(widget.foursomeId);
            },
            child: const Text('Retry'),
          ),
        ]),
      );
    }
    if (sc == null) return const SizedBox.shrink();

    final players  = _orderedPlayers(sc, rp.round, nas);
    final merged   = _mergePending(rp.localPendingByHole, _pending);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    int hotSpot    = isComplete ? -1 : _hotSpotIdx(players, scores);
    // Editing an already-scored player: make them the active row so the inline
    // picker targets them (mirrors the casual score-entry form).
    if (!isComplete && _editHotPid != null) {
      final idx = players.indexWhere((p) => p.player.id == _editHotPid);
      if (idx != -1) hotSpot = idx;
    }
    final par      = holeData?.par ?? 4;

    // Start / stop phantom polling based on whether the phantom has scored
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updatePhantomPolling(nas, scores, players);
    });

    return Column(children: [
      // Team banner (Blue vs Orange colour dots + names)
      if (nas != null) _TeamBanner(summary: nas),

      // Presses strip — show only presses for the current nine.
      // Front-nine presses are cleared once we reach hole 10.
      if (nas != null &&
          (nas.presses.isNotEmpty || nas.bottomPresses.isNotEmpty))
        _PressesStrip(
          presses:       nas.presses,
          bottomPresses: nas.bottomPresses,
          currentHole:   _selectedHole,
          t1Color:       nassauTeamColor(1),
          t2Color:       nassauTeamColor(2),
        ),

      Expanded(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Active hole card
              _NassauHoleScoreCard(
                holeData:        holeData,
                holeNumber:      _selectedHole,
                players:         players,
                scorecard:       sc,
                merged:          merged,
                scores:          scores,
                hotSpotIdx:      hotSpot,
                par:             par,
                nassau:          nas,
                phantomInfo:     nas?.phantom,
                spotsActive:     spotsActive(rp),
                spotsCountFor:   (pid) =>
                    spotsCount(pid, _selectedHole, rp.spotsSummary),
                onSpotsAdd:      (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, 1),
                onSpotsRemove:   (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, -1),
                onScoreSelected: (m, score) {
                  final hole = _selectedHole;
                  final wasAllScored = _allScored(
                      players, _effectiveScores(sc, hole));
                  final wasEditing = _editHotPid != null;
                  _selectScore(m, score, hole);
                  // Editing an existing score (inline): drop the one-shot edit
                  // override and commit the correction immediately, like the
                  // old edit sheet did — no save+advance needed.
                  if (wasEditing) {
                    setState(() => _editHotPid = null);
                    _saveAndAdvance(ctx, players, par, advance: false);
                    return;
                  }
                  // Auto-save+advance the moment the last player on the
                  // hole gets a positive score.  Gated by the Auto-advance
                  // setting; when off, stay on the hole so the scorer can
                  // verify the entries before pressing next.
                  final autoAdvance =
                      context.read<SettingsProvider>().autoAdvanceHole;
                  if (autoAdvance && score > 0 && !wasAllScored) {
                    final nowAllScored = _allScored(
                        players, _effectiveScores(sc, hole));
                    if (nowAllScored) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (_selectedHole != hole) return;
                        final rp = context.read<RoundProvider>();
                        if (rp.submitting) return;
                        _saveAndAdvance(ctx, players, par);
                      });
                    }
                  }
                },
                onEditTap: (m) => setState(() => _editHotPid = m.player.id),
              ),
              const SizedBox(height: 12),

              // 18-hole summary grid
              if (nas != null) ...[
                _NassauSummaryGrid(
                  nassau:      nas,
                  players:     players,
                  scorecard:   sc,
                  currentHole: _selectedHole,
                  onTapHole:   (h) =>
                      setState(() { _selectedHole = h; _editHotPid = null; }),
                ),
                const SizedBox(height: 8),
              ] else if (rp.loadingNassau) ...[
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ],

              // Phantom info strip — HC and per-donor rotation summary.
              // Placed here (outside the grid) matching the Quota Nassau layout.
              if (nas?.phantom != null) ...[
                _PhantomInfoStrip(
                  phantomInfo: nas!.phantom!,
                  players:     players,
                ),
                const SizedBox(height: 8),
              ],

              const SizedBox(height: 16),
            ],
            ),
          ),
        ),
      ),
    ]);
  }

  static String _modeLabel(String mode, int netPercent) {
    if (mode == 'gross') return 'Gross';
    if (mode == 'strokes_off') return 'SO';
    return netPercent == 100 ? 'Net' : 'Net $netPercent%';
  }
}

// ===========================================================================
// Active-hole card (mirrors _P531HoleScoreCard)
// ===========================================================================

class _NassauHoleScoreCard extends StatelessWidget {
  final ScorecardHole?          holeData;
  final int                     holeNumber;
  final List<Membership>        players;
  final Scorecard               scorecard;
  final Map<int, Map<int, int>> merged;
  final Map<int, int>           scores;
  final int                     hotSpotIdx;
  final int                     par;
  final NassauSummary?          nassau;
  final NassauPhantomInfo?      phantomInfo;
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership)      onEditTap;
  // Spots add-on (captured in this dedicated entry screen).
  final bool                    spotsActive;
  final int  Function(int pid)  spotsCountFor;
  final void Function(int pid)  onSpotsAdd;
  final void Function(int pid)  onSpotsRemove;

  const _NassauHoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.merged,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.nassau,
    this.phantomInfo,
    required this.onScoreSelected,
    required this.onEditTap,
    this.spotsActive   = false,
    required this.spotsCountFor,
    required this.onSpotsAdd,
    required this.onSpotsRemove,
  });

  String get _mode       => nassau?.handicapMode ?? 'net';
  int    get _netPercent => nassau?.netPercent   ?? 100;

  int? get _lowPlayingHandicap {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  int _matchHcapFor(Membership m) => effectiveMatchHandicap(
        mode:                  _mode,
        netPercent:            _netPercent,
        playingHandicap:       m.playingHandicap,
        lowestPlayingHandicap: _lowPlayingHandicap,
      );

  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null || _mode == 'gross') return 0;
    final entry = h.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? h.strokeIndex;

    if (_mode == 'net') {
      if (_netPercent == 100 && entry != null) return entry.handicapStrokes;
      final effective = (m.playingHandicap * _netPercent / 100.0).round();
      return strokesOnHole(effective, mySi);
    }

    if (_mode == 'strokes_off') {
      final low = _lowPlayingHandicap;
      if (low == null) return 0;
      final so = m.playingHandicap - low;
      if (so <= 0) return 0;
      return strokesOnHole(so, mySi);
    }

    return 0;
  }


  /// The player's 1-based team index (1 = Blue, 2 = Orange), or null.
  int? _teamOf(int playerId) {
    if (nassau == null) return null;
    if (nassau!.team1.any((p) => p.playerId == playerId)) return 1;
    if (nassau!.team2.any((p) => p.playerId == playerId)) return 2;
    return null;
  }

  static String _buildHoleHeaderText(
      ScorecardHole hole, List<Membership> players) {
    final seenKeys = <int>{};
    final parVals  = <int>[];
    final yardVals = <int?>[];
    final siVals   = <int>[];
    for (final m in players) {
      final key = m.tee?.id ?? -m.player.id;
      if (!seenKeys.add(key)) continue;
      final e = hole.scoreFor(m.player.id);
      parVals.add(e?.par   ?? hole.par);
      yardVals.add(e?.yards ?? hole.yards);
      siVals.add(e?.strokeIndex ?? hole.strokeIndex);
    }

    String collapse<T>(List<T> values, String Function(T) fmt) {
      if (values.isEmpty) return '';
      final seen   = <T>{};
      final unique = values.where((v) => seen.add(v)).toList();
      return unique.length == 1 ? fmt(unique.first) : unique.map(fmt).join('/');
    }

    final parStr   = 'Par ${collapse<int>(parVals, (v) => '$v')}';
    final siStr    = 'SI: ${collapse<int>(siVals,  (v) => '$v')}';
    final anyYards = yardVals.any((y) => y != null);
    final yardStr  = anyYards
        ? '${collapse<int?>(yardVals, (v) => v == null ? '—' : '$v')} yds.'
        : null;

    return yardStr == null
        ? '$parStr  |  $siStr'
        : '$parStr  |  $yardStr  |  $siStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final nassauHole = nassau?.holes
        .where((h) => h.hole == holeNumber)
        .firstOrNull;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hole header
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Column(children: [
              Text('Hole $holeNumber',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              if (holeData != null)
                Text(
                  _buildHoleHeaderText(holeData!, players),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
            ]),
          ),

          // Hole outcome banner (shown once hole is scored)
          if (nassauHole != null && nassauHole.winner != null)
            _HoleOutcomeBanner(hole: nassauHole, nassau: nassau!),

          // Player rows + inline picker
          ...players.asMap().entries.expand((entry) {
            final idx        = entry.key;
            final m          = entry.value;

            // Phantom player: show read-only donor-status row
            if (m.player.isPhantom && phantomInfo != null) {
              final donor     = phantomInfo!.donorForHole(holeNumber);
              final hasScore  = scores.containsKey(m.player.id);
              final gross     = scores[m.player.id];
              return [
                _PhantomDonorRow(
                  holeNumber:  holeNumber,
                  gross:       gross,
                  donorName:   donor?.playerName ?? 'Donor',
                  donorScored: donor?.hasScore ?? hasScore,
                  team:        _teamOf(m.player.id),
                ),
              ];
            }

            final gross      = scores[m.player.id];
            final isHot      = idx == hotSpotIdx;
            final hasScore   = gross != null;
            final matchStrok = _strokesForHole(m, holeData);

            // Handicap pill reads "gets N" (strokes this player receives).
            // The stroke-this-hole indicator now lives in the dot strip above
            // the score box, so no bullets here. Hidden for a 0-stroke player.
            String? hcapLabel;
            if (_mode == 'net' || _mode == 'strokes_off') {
              final h = _matchHcapFor(m);
              if (h > 0) hcapLabel = 'gets $h';
            }

            final team = _teamOf(m.player.id);
            final boxColor = team != null
                ? nassauTeamColor(team)
                : Theme.of(context).colorScheme.primary;
            final row = _NassauPlayerRow(
                member:              m,
                gross:               gross,
                isHot:               isHot,
                matchHcapLabel:      hcapLabel,
                strokesOnThisHole:   matchStrok,
                team:                team,
                onTap: (hasScore && !isHot) ? () => onEditTap(m) : null,
                spotsActive:   spotsActive,
                spotsCount:    spotsActive ? spotsCountFor(m.player.id) : 0,
                onSpotsAdd:    spotsActive ? () => onSpotsAdd(m.player.id) : null,
                onSpotsRemove:
                    spotsActive ? () => onSpotsRemove(m.player.id) : null,
              );
            if (isHot) {
              // Active player + picker share ONE team-coloured bounding box.
              // Flush-left bold bar, right inset so the right line shows.
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
                        par:             par,
                        strokes:         matchStrok,
                        currentScore:    gross,
                        boxBorderColor:  boxColor,
                        boxFillColor:    Colors.white,
                        onScoreSelected: (score) => onScoreSelected(m, score),
                      ),
                    ],
                  ),
                ),
              ];
            }
            return [row];
          }).toList(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hole outcome banner (within the hole card)
// ---------------------------------------------------------------------------

class _HoleOutcomeBanner extends StatelessWidget {
  final NassauHoleData hole;
  final NassauSummary  nassau;

  const _HoleOutcomeBanner({required this.hole, required this.nassau});

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final winner = hole.winner!;

    final Color bg;
    final Color fg;
    final String label;
    if (winner == 'halved') {
      bg    = Colors.grey.shade100;
      fg    = Colors.grey.shade700;
      label = 'Halved';
    } else if (winner == 'team1') {
      final c = nassauTeamColor(1);
      bg    = c.withOpacity(0.10);
      fg    = c;
      label = '${nassauWonByLabel(1, nassau.team1)} wins hole';
    } else {
      final c = nassauTeamColor(2);
      bg    = c.withOpacity(0.10);
      fg    = c;
      label = '${nassauWonByLabel(2, nassau.team2)} wins hole';
    }

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Icon(
          winner == 'halved' ? Icons.drag_handle : Icons.emoji_events,
          size: 14,
          color: fg,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Phantom donor status row (read-only, shown in place of score entry)
// ---------------------------------------------------------------------------

class _PhantomDonorRow extends StatelessWidget {
  final int     holeNumber;
  final int?    gross;          // phantom's gross score (null = not yet available)
  final String  donorName;     // player whose score the phantom is copying
  final bool    donorScored;   // whether the donor has posted their score
  final int?    team;          // 1 = Blue, 2 = Orange (null = unteamed)

  const _PhantomDonorRow({
    required this.holeNumber,
    required this.gross,
    required this.donorName,
    required this.donorScored,
    this.team,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasScore = gross != null;

    return Container(
      decoration: BoxDecoration(
        color: hasScore
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.errorContainer.withOpacity(0.15),
        border: Border(
          left: BorderSide(
            color: hasScore
                ? theme.colorScheme.outline.withOpacity(0.3)
                : theme.colorScheme.error.withOpacity(0.4),
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        // Phantom label
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'PHM',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: hasScore
              ? Text(
                  'Score from $donorName',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                )
              : Row(children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Waiting for $donorName…',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontStyle: FontStyle.italic,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
        ),
        if (team != null) ...[
          const SizedBox(width: 8),
          nassauTeamDot(team!),
        ],
        const SizedBox(width: 8),
        // Score chip
        Container(
          width: 36,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hasScore
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            hasScore ? '$gross' : '—',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: hasScore
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Player row (mirrors _P531PlayerRow, adds team badge)
// ---------------------------------------------------------------------------

class _NassauPlayerRow extends StatelessWidget {
  final Membership    member;
  final int?          gross;
  final bool          isHot;
  final String?       matchHcapLabel;
  final VoidCallback? onTap;
  final int           strokesOnThisHole;
  final int?          team; // 1 = Blue, 2 = Orange (null = unteamed)
  final bool          spotsActive;
  final int           spotsCount;
  final VoidCallback? onSpotsAdd;
  final VoidCallback? onSpotsRemove;

  const _NassauPlayerRow({
    required this.member,
    required this.gross,
    required this.isHot,
    this.matchHcapLabel,
    this.onTap,
    this.strokesOnThisHole = 0,
    this.team,
    this.spotsActive = false,
    this.spotsCount = 0,
    this.onSpotsAdd,
    this.onSpotsRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color activeColor =
        team != null ? nassauTeamColor(team!) : theme.colorScheme.primary;
    final Color boxBg = isHot ? Colors.white : Colors.transparent;
    final boxBorder = isHot
        ? Border.all(color: activeColor, width: 2)
        : Border.all(color: theme.colorScheme.outline);

    return Container(
      decoration: BoxDecoration(
        // Transparent when active so the surrounding bounding box's team wash
        // shows through; inactive rows keep the top divider only.
        color: isHot ? Colors.transparent : null,
        border: isHot
            ? const Border()
            : Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Name + handicap chip. Team identity is conveyed by the name colour
        // (blue = team 1, orange = team 2) — no separate dot needed.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
            Flexible(
              child: Text(
                member.player.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  // Tint the name with the player's team colour — the
                  // green score-box outline + row tint already mark the
                  // hot-spot player.
                  color: team != null ? nassauTeamColor(team!) : null,
                ),
              ),
            ),
            if (matchHcapLabel != null) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer
                      .withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  matchHcapLabel!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
            // Tee name next to the handicap index (or right after the
            // name when there's no chip — gross mode).  Same placement
            // as the universal score-entry screen.
            if (member.tee != null) ...[
              const SizedBox(width: 6),
              Text(member.tee!.teeName,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
              if (spotsActive)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SpotsDots(
                    count: spotsCount,
                    onAdd: onSpotsAdd ?? () {},
                    onRemove: onSpotsRemove ?? () {},
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // Score box with optional stroke dots
        GestureDetector(
          onTap: onTap,
          child: scoreCellWithDots(
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 40,
              height: 36,
              decoration: BoxDecoration(
                color: boxBg,
                border: boxBorder,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: gross != null
                    ? Text('$gross',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold))
                    : isHot
                        ? Icon(Icons.arrow_drop_down,
                            size: 20,
                            color: theme.colorScheme.primary)
                        : const SizedBox.shrink(),
              ),
            ),
            strokesOnThisHole,
            theme.colorScheme.primary,
          ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// 18-hole summary grid
// ===========================================================================

class _NassauSummaryGrid extends StatefulWidget {
  final NassauSummary      nassau;
  final List<Membership>   players;
  final Scorecard          scorecard;
  final int                currentHole;
  final void Function(int hole)? onTapHole;

  const _NassauSummaryGrid({
    required this.nassau,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
  });

  @override
  State<_NassauSummaryGrid> createState() => _NassauSummaryGridState();
}

class _NassauSummaryGridState extends State<_NassauSummaryGrid> {
  final ScrollController _scrollCtrl = ScrollController();

  static const double _labelColW = 56.0;
  static const double _cellW     = 34.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToHole(widget.currentHole));
  }

  @override
  void didUpdateWidget(_NassauSummaryGrid old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToHole(widget.currentHole));
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToHole(int hole) {
    if (!_scrollCtrl.hasClients) return;
    // Position current hole at slot 7 of ~10 visible (70% from left).
    final target = (_labelColW + (hole - 7) * _cellW)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  int _strokesOnHoleFor(Membership m, int h) {
    final nassau  = widget.nassau;
    final players = widget.players;
    final scorecard = widget.scorecard;
    if (nassau.handicapMode == 'gross') return 0;
    final hole  = scorecard.holeData(h);
    if (hole == null) return 0;
    final entry = hole.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? hole.strokeIndex;

    if (nassau.handicapMode == 'net') {
      if (nassau.netPercent == 100 && entry != null) {
        return entry.handicapStrokes;
      }
      final effective =
          (m.playingHandicap * nassau.netPercent / 100.0).round();
      return strokesOnHole(effective, mySi);
    }

    if (nassau.handicapMode == 'strokes_off') {
      if (players.isEmpty) return 0;
      final low = players
          .map((p) => p.playingHandicap)
          .reduce((a, b) => a < b ? a : b);
      final so = m.playingHandicap - low;
      if (so <= 0) return 0;
      return strokesOnHole(so, mySi);
    }

    return 0;
  }

  String? _winnerForHole(int h) =>
      widget.nassau.holes.where((x) => x.hole == h).firstOrNull?.winner;

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final nassau    = widget.nassau;
    final players   = widget.players;
    final scorecard = widget.scorecard;
    final currentHole = widget.currentHole;
    final t1Color = nassauTeamColor(1);
    final t2Color = nassauTeamColor(2);
    final onTapHole   = widget.onTapHole;

    const double labelColW = 56.0;
    const double cellW     = 34.0;
    const double rowH      = 28.0;

    final holeRange = List.generate(18, (i) => i + 1);

    Widget holeCell(int h, {required Widget child, Color? bg}) {
      final isCurrent = h == currentHole;
      return GestureDetector(
        onTap: onTapHole == null ? null : () => onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: cellW,
          height: rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ??
                (isCurrent
                    ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                    : null),
            border: isCurrent
                ? Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.6),
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
            Text('Round progress',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: _scrollCtrl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hole numbers header
                  Row(children: [
                    SizedBox(
                      width: labelColW, height: rowH,
                      child: const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Hole',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                    for (final h in holeRange)
                      holeCell(h,
                          child: Text('$h',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold))),
                  ]),
                  // Par row
                  Row(children: [
                    SizedBox(
                      width: labelColW, height: rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Par',
                            style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic)),
                      ),
                    ),
                    for (final h in holeRange)
                      holeCell(h,
                          child: Text(
                            '${scorecard.holeData(h)?.par ?? "-"}',
                            style: theme.textTheme.bodySmall,
                          )),
                  ]),
                  // Divider
                  Container(
                    height: 1,
                    width: labelColW + cellW * holeRange.length,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // Player score rows (real players + phantom)
                  for (final m in players)
                    _NassauGridPlayerRow(
                      member:        m,
                      scorecard:     scorecard,
                      holeRange:     holeRange,
                      currentHole:   currentHole,
                      onTapHole:     onTapHole,
                      labelColW:     labelColW,
                      cellW:         cellW,
                      rowH:          rowH,
                      strokesOnHole: (h) => _strokesOnHoleFor(m, h),
                      isPhantom:     m.player.isPhantom,
                    ),
                  // Hole winner row (top bet)
                  Row(children: [
                    SizedBox(
                      width: labelColW, height: rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          nassau.isClaremont ? 'Top' : 'Won by',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic)),
                      ),
                    ),
                    for (final h in holeRange)
                      Builder(builder: (_) {
                        final winner = _winnerForHole(h);
                        Color? bg;
                        Color? fg;
                        String label = '·';
                        if (winner == 'team1') {
                          bg    = t1Color.withOpacity(0.15);
                          fg    = t1Color;
                          label = nassauTeamInitials(nassau.team1);
                        } else if (winner == 'team2') {
                          bg    = t2Color.withOpacity(0.15);
                          fg    = t2Color;
                          label = nassauTeamInitials(nassau.team2);
                        } else if (winner == 'halved') {
                          bg    = Colors.grey.shade100;
                          fg    = Colors.grey.shade600;
                          label = '=';
                        }
                        return holeCell(h,
                            bg: bg,
                            child: Text(label,
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: fg ?? theme.colorScheme.onSurfaceVariant,
                                )));
                      }),
                  ]),

                  // ── Claremont bottom delta row ─────────────────────────
                  if (nassau.isClaremont)
                    Row(children: [
                      SizedBox(
                        width: labelColW, height: rowH,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('Bot',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontStyle: FontStyle.italic)),
                        ),
                      ),
                      for (final h in holeRange)
                        Builder(builder: (_) {
                          final hd = nassau.holes
                              .where((x) => x.hole == h)
                              .firstOrNull;
                          final delta = hd?.bottomDelta;
                          Color? bg;
                          Color? fg;
                          String lbl = '·';
                          if (delta != null) {
                            if (delta > 0) {
                              bg  = t1Color.withOpacity(0.15);
                              fg  = t1Color;
                              lbl = '+$delta';
                            } else if (delta < 0) {
                              bg  = t2Color.withOpacity(0.15);
                              fg  = t2Color;
                              lbl = '$delta';
                            } else {
                              bg  = Colors.grey.shade100;
                              fg  = Colors.grey.shade600;
                              lbl = '0';
                            }
                          }
                          return holeCell(h,
                              bg: bg,
                              child: Text(lbl,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: fg ?? theme.colorScheme.onSurfaceVariant,
                                  )));
                        }),
                    ]),
                ],
              ),
            ),
          // (Phantom info strip is rendered outside this grid in _buildBody)
        ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Phantom info strip — shows HC and hole-by-donor rotation
// ---------------------------------------------------------------------------

class _PhantomInfoStrip extends StatelessWidget {
  final NassauPhantomInfo phantomInfo;
  final List<Membership>  players;

  const _PhantomInfoStrip({
    required this.phantomInfo,
    required this.players,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // HC is avg course_handicap of donor players, computed server-side.
    // phantomPlayingHcp used to be stored as 0 (cross-foursome phantoms have no
    // real players in their own foursome), but is now correctly computed from donors.
    final hc = phantomInfo.phantomPlayingHcp > 0
        ? phantomInfo.phantomPlayingHcp
        : null;

    // Group holes by donor short name for a compact rotation summary; the SO
    // is per-donor (donor index − real low), so cache it alongside.
    final Map<String, List<int>> byDonor = {};
    final Map<String, int>       donorSo = {};
    for (int h = 1; h <= 18; h++) {
      final donor = phantomInfo.donorForHole(h);
      if (donor == null) continue;
      byDonor.putIfAbsent(donor.shortName, () => []).add(h);
      donorSo[donor.shortName] = donor.so;
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.colorScheme.secondaryContainer,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'PHANTOM',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (hc != null)
              Text(
                'Course HC: $hc (avg of donors)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ]),
          // Donor rotation
          if (byDonor.isNotEmpty) ...[
            const SizedBox(height: 6),
            ...byDonor.entries.map((e) {
              final name  = e.key;
              final holes = e.value;
              // Show scored/pending counts
              final scored  = holes.where((h) =>
                  phantomInfo.donorForHole(h)?.hasScore ?? false).length;
              final pending = holes.length - scored;
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(children: [
                  Container(
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: pending == 0
                          ? Colors.green.shade400
                          : theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if ((donorSo[name] ?? 0) > 0)
                          TextSpan(
                            text: '  SO ${donorSo[name]}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        TextSpan(
                          text: '  holes ${holes.join(', ')}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (pending > 0)
                          TextSpan(
                            text: '  ($pending pending)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ]),
                    ),
                  ),
                ]),
              );
            }),
          ],
        ],
      ),
    );
  }
}

/// Single player row in the summary grid.
class _NassauGridPlayerRow extends StatelessWidget {
  final Membership   member;
  final Scorecard    scorecard;
  final List<int>    holeRange;
  final int          currentHole;
  final void Function(int hole)? onTapHole;
  final double       labelColW;
  final double       cellW;
  final double       rowH;
  final int Function(int hole) strokesOnHole;
  final bool         isPhantom;

  const _NassauGridPlayerRow({
    required this.member,
    required this.scorecard,
    required this.holeRange,
    required this.currentHole,
    required this.onTapHole,
    required this.labelColW,
    required this.cellW,
    required this.rowH,
    required this.strokesOnHole,
    this.isPhantom = false,
  });

  Widget _cell(int h, BuildContext ctx, {required Widget child}) {
    final theme     = Theme.of(ctx);
    final isCurrent = h == currentHole;
    return GestureDetector(
      onTap: onTapHole == null ? null : () => onTapHole!(h),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: cellW, height: rowH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isCurrent
              ? theme.colorScheme.primaryContainer.withOpacity(0.35)
              : null,
          border: isCurrent
              ? Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.6),
                  width: 1.2)
              : null,
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Phantom rows are shown with a subdued style and "PHM hc:N" label
    final labelStyle = isPhantom
        ? theme.textTheme.bodySmall?.copyWith(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 10,
          )
        : theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600);

    final String label = isPhantom
        ? 'PHM hc:${member.playingHandicap}'
        : member.player.displayShort;

    return Row(children: [
      SizedBox(
        width: labelColW, height: rowH,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: labelStyle),
        ),
      ),
      for (final h in holeRange)
        _cell(h, context,
            child: SizedBox(
              width: cellW, height: rowH,
              child: Stack(children: [
                Center(
                  child: Builder(builder: (_) {
                    final saved = scorecard
                        .holeData(h)
                        ?.scoreFor(member.player.id);
                    final gross = saved?.grossScore;
                    final textColor = isPhantom
                        ? (gross == null
                            ? theme.colorScheme.outlineVariant
                            : theme.colorScheme.onSurfaceVariant)
                        : (gross == null
                            ? theme.colorScheme.onSurfaceVariant
                            : null);
                    return Text(
                      gross == null ? '–' : '$gross',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: isPhantom ? FontWeight.normal : FontWeight.w600,
                        fontStyle: isPhantom ? FontStyle.italic : FontStyle.normal,
                        color: textColor,
                        fontSize: isPhantom ? 10 : null,
                      ),
                    );
                  }),
                ),
                if (!isPhantom)
                  Positioned(
                    top: 2, right: 2,
                    child: Builder(builder: (_) {
                      final strokes = strokesOnHole(h);
                      if (strokes <= 0) return const SizedBox.shrink();
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(
                          strokes.clamp(0, 2),
                          (i) => Container(
                            width: 4, height: 4,
                            margin: const EdgeInsets.only(left: 1),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
              ]),
            )),
    ]);
  }
}

// ===========================================================================
// Nassau-specific bottom-bar widgets
// ===========================================================================

// ---------------------------------------------------------------------------
// Team banner
// ---------------------------------------------------------------------------

class _TeamBanner extends StatelessWidget {
  final NassauSummary summary;
  const _TeamBanner({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Team 1 (Blue) on the left, Team 2 (Orange) on the right.
    final leftLabel  = summary.team1.map((p) => p.name).join(' & ');
    final rightLabel = summary.team2.map((p) => p.name).join(' & ');
    final leftColor  = nassauTeamColor(1);
    final rightColor = nassauTeamColor(2);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        nassauTeamDot(1),
        const SizedBox(width: 6),
        Expanded(
          child: Text(leftLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: leftColor,
              ),
              overflow: TextOverflow.ellipsis),
        ),
        Text(' vs ',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Expanded(
          child: Text(rightLabel,
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: rightColor,
              ),
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 6),
        nassauTeamDot(2),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Presses strip
// ---------------------------------------------------------------------------

class _PressesStrip extends StatelessWidget {
  final List<NassauPressResult> presses;
  /// Claremont bottom-series presses (2 pts/hole); labelled "Bot".
  final List<NassauPressResult> bottomPresses;
  /// Current hole being viewed — used to filter which nine's presses to show.
  final int currentHole;
  final Color t1Color;
  final Color t2Color;
  const _PressesStrip({
    required this.presses,
    this.bottomPresses = const [],
    required this.currentHole,
    Color? t1Color,
    Color? t2Color,
  })  : t1Color = t1Color ?? kNassauTeam1Color,
        t2Color = t2Color ?? kNassauTeam2Color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Show only presses for the currently active nine.
    // Front-nine presses disappear once we move to hole 10+.
    final currentNine = currentHole <= 9 ? 'front' : 'back';
    // Combine the top series with the Claremont bottom series (tagged).
    final tagged = [
      for (final p in presses)       (press: p, isBottom: false),
      for (final p in bottomPresses) (press: p, isBottom: true),
    ];
    final visible =
        tagged.where((t) => t.press.nine == currentNine).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 32,
      color: theme.colorScheme.surface,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final p        = visible[i].press;
          final isBottom = visible[i].isBottom;
          // Sequential number within this nine + series, e.g. "F9 Press 1";
          // Claremont bottom presses get a "Bot" tag: "F9 Bot Press 1".
          int pressNo = 1;
          for (int k = 0; k < i; k++) {
            if (visible[k].isBottom == isBottom) pressNo++;
          }
          final ninePrefix = currentNine == 'front' ? 'F9' : 'B9';
          final label = '$ninePrefix ${isBottom ? 'Bot ' : ''}Press $pressNo';
          final result = p.result;
          final m      = p.margin ?? 0;
          final mAbs   = m.abs();
          Color  chipColor;
          String scoreText;
          if (result == 'team1') {
            chipColor = t1Color.withOpacity(0.15);
            scoreText = isBottom
                ? '$mAbs pts'
                : (p.holesRemaining > 0 ? '$mAbs&${p.holesRemaining}' : '${mAbs}UP');
          } else if (result == 'team2') {
            chipColor = t2Color.withOpacity(0.15);
            scoreText = isBottom
                ? '$mAbs pts'
                : (p.holesRemaining > 0 ? '$mAbs&${p.holesRemaining}' : '${mAbs}UP');
          } else if (result == 'halved') {
            chipColor = Colors.grey.shade200;
            scoreText = 'AS';
          } else {
            chipColor = theme.colorScheme.secondaryContainer;
            scoreText = '';
          }
          final chipText = scoreText.isEmpty ? label : '$label $scoreText';
          return Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: chipColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: theme.colorScheme.outline.withOpacity(0.3)),
              ),
              child: Text(
                chipText,
                style: theme.textTheme.labelSmall,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Match status bar (F9 / B9 / Overall chips + optional Call Press button)
// ---------------------------------------------------------------------------

class _MatchStatusBar extends StatelessWidget {
  final NassauSummary summary;
  final VoidCallback? onPress;
  final bool          submitting;

  const _MatchStatusBar({
    required this.summary,
    this.onPress,
    required this.submitting,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // ── Top (Nassau) row ───────────────────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _betChip(context, summary.isClaremont ? 'Top F9' : 'F9',  summary.front9),
            _betChip(context, summary.isClaremont ? 'Top B9' : 'B9',  summary.back9),
            _betChip(context, summary.isClaremont ? 'Top ALL' : 'ALL', summary.overall),
          ],
        ),
        // ── Bottom (Claremont) row ─────────────────────────────────────────
        if (summary.isClaremont &&
            summary.bottomFront9 != null &&
            summary.bottomBack9  != null &&
            summary.bottomOverall != null) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _bottomChip(context, 'Bot F9',  summary.bottomFront9!),
              _bottomChip(context, 'Bot B9',  summary.bottomBack9!),
              _bottomChip(context, 'Bot ALL', summary.bottomOverall!),
            ],
          ),
        ],
        if (onPress != null) ...[
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: submitting ? null : onPress,
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: const Text('Call Press'),
            ),
          ),
        ],
      ]),
    );
  }

  Color get _t1Color => nassauTeamColor(1);
  Color get _t2Color => nassauTeamColor(2);

  Widget _betChip(
    BuildContext context,
    String label,
    NassauBetResult bet,
  ) {
    final theme    = Theme.of(context);
    final result   = bet.result;
    final nineLen  = label == 'ALL' ? 18 : 9;
    final holesLeft = nineLen - bet.holesPlayed;
    final t1Leads  = bet.margin > 0;
    Color  bg;
    String subtitle;
    // Subtitle text colour follows the team that's leading / has won, so
    // F9 / B9 / ALL chips match the T1 / T2 colour convention used on the
    // golfer rows.  Null = neutral (AS, no holes played).
    Color? subtitleColor;

    if (result != null) {
      // Nine is fully resolved
      if (result == 'halved') {
        bg       = Colors.grey.shade200;
        subtitle = 'AS';
      } else {
        final winsT1 = result == 'team1';
        bg            = winsT1 ? _t1Color.withOpacity(0.15) : _t2Color.withOpacity(0.15);
        subtitleColor = winsT1 ? _t1Color : _t2Color;
        // Use frozen decided score if the nine ended early (e.g. "5&4").
        final dm = bet.decidedMargin;
        final dr = bet.decidedRemaining;
        if (dm != null && dr != null && dr > 0) {
          subtitle = '${dm.abs()}&$dr';
        } else {
          subtitle = 'wins';
        }
      }
    } else if (bet.holesPlayed == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = '—';
    } else if (bet.margin == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = 'AS';
    } else if (holesLeft >= 0 && bet.margin.abs() > holesLeft) {
      // Mathematically decided before the last hole — show "5&4" notation.
      bg            = t1Leads ? _t1Color.withOpacity(0.15) : _t2Color.withOpacity(0.15);
      subtitleColor = t1Leads ? _t1Color : _t2Color;
      subtitle      = '${bet.margin.abs()}&$holesLeft';
    } else {
      // In progress — colour by leader, no team label.
      bg            = t1Leads ? _t1Color.withOpacity(0.08) : _t2Color.withOpacity(0.08);
      subtitleColor = t1Leads ? _t1Color : _t2Color;
      subtitle      = '${bet.margin.abs()}UP';
    }

    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: subtitleColor,
            )),
      ]),
    );
  }

  /// Compact chip for Claremont bottom bets (margin in points).
  Widget _bottomChip(
    BuildContext context,
    String label,
    NassauBottomBetResult bet,
  ) {
    final theme   = Theme.of(context);
    final result  = bet.result;
    Color  bg;
    String subtitle;
    Color? subtitleColor;

    if (result != null) {
      if (result == 'halved') {
        bg       = Colors.grey.shade200;
        subtitle = 'AS';
      } else {
        final winsT1 = result == 'team1';
        bg            = winsT1 ? _t1Color.withOpacity(0.15) : _t2Color.withOpacity(0.15);
        subtitleColor = winsT1 ? _t1Color : _t2Color;
        subtitle      = 'wins';
      }
    } else if (bet.holesPlayed == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = '—';
    } else if (bet.margin == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = 'AS';
    } else {
      final t1Leads = bet.margin > 0;
      bg            = t1Leads ? _t1Color.withOpacity(0.08) : _t2Color.withOpacity(0.08);
      subtitleColor = t1Leads ? _t1Color : _t2Color;
      subtitle      = '${t1Leads ? '+' : ''}${bet.margin}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: subtitleColor,
            )),
      ]),
    );
  }
}
