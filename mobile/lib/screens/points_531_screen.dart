/// screens/points_531_screen.dart
///
/// Score-entry and live-standings screen for the Points 5-3-1 casual
/// game.  Modeled on sixes_screen.dart but simplified: no teams, no
/// segments, and no pink-ball.  Exactly three real players rank on
/// each hole, awarding 5 / 3 / 1 with tie-splitting (sum is always 9
/// per fully-scored hole).
///
/// Layout:
///   • AppBar: "Points 5-3-1" title with Scorecard + Leaderboard shortcuts.
///   • Top card: Hole N header, one row per player showing their running
///     total (gross-vs-par and net-vs-par), a stroke-dot badge when the
///     player gets a handicap stroke on this hole, and a score box.  The
///     first player without a score on this hole becomes the hot-spot;
///     an inline score picker appears below their row so no tap is needed.
///   • Points strip:  Points 5-3-1 awards for this hole (once everyone's
///     scored) e.g. "5  3  1" or "4  4  1" next to each player's name.
///   • Summary grid: compact 18-hole matrix — one row per player, plus a
///     5-3-1 points row — showing at-a-glance progress through the round.
///   • Bottom nav:  ← Hole N-1  |  Hole N+1 →   (Done on hole 18)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../utils/match_handicap.dart';
import '../utils/round_complete.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/net_score_button.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/spots_capture.dart';

// ---------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------

class Points531Screen extends StatefulWidget {
  final int foursomeId;
  const Points531Screen({super.key, required this.foursomeId});

  @override
  State<Points531Screen> createState() => _Points531ScreenState();
}

class _Points531ScreenState extends State<Points531Screen>
    with SpotsCaptureMixin {
  /// Unsubmitted score edits for the current session.  Shape:
  /// hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;

  /// Tap an already-scored player → they become the active row so the inline
  /// picker edits their score in place (casual score-entry model), not a modal.
  int? _editHotPid;

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
      rp.loadPoints531(widget.foursomeId);
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

  /// Re-pull this screen's data (scorecard + Points 5-3-1 standings).
  /// Mirrors what initState loads; used by the AppBar refresh button and
  /// pull-to-refresh.
  Future<void> _refresh() async {
    final rp = context.read<RoundProvider>();
    await rp.loadScorecard(widget.foursomeId);
    rp.loadPoints531(widget.foursomeId);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Real (non-phantom) players for this foursome, ordered so that
  /// players on the LONGEST tee come first (longest tee = greatest
  /// yardage on hole 1).  Same-tee players end up adjacent, which lets
  /// the hole header dedupe par/yards/SI by tee instead of by player.
  /// Tiebreaker is the existing foursome-membership order so the
  /// display order is stable round-to-round.
  ///
  /// If a player's 1st-hole yardage is missing from the scorecard
  /// (unusual), we treat them as "shortest" (yardage 0) so they sink
  /// to the bottom.  If the whole scorecard is empty, we keep the
  /// original membership order.
  List<Membership> _realPlayers(Scorecard sc, Round? round) {
    final foursome = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;

    List<Membership> members;
    if (foursome != null) {
      members = foursome.memberships
          .where((m) => !m.player.isPhantom)
          .toList();
    } else if (sc.holes.isEmpty) {
      return const [];
    } else {
      members = sc.holes.first.scores
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

    // Longest-tee-first sort using hole 1's yardage per player.
    // Stable sort preserves membership order among ties.
    final firstHole = sc.holeData(1);
    int yardageFor(int playerId) =>
        firstHole?.scoreFor(playerId)?.yards ?? 0;
    members.sort((a, b) {
      final ay = yardageFor(a.player.id);
      final by = yardageFor(b.player.id);
      return by.compareTo(ay); // descending — longer tees first
    });

    return members;
  }

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    for (int h = 1; h <= 18; h++) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      // Only count REAL players here; a phantom's auto-score from setup
      // shouldn't gate our first-unplayed hunt.
      final realIds =
          _realPlayers(sc, rp.round).map((m) => m.player.id).toSet();
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
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  bool _allScored(List<Membership> players, Map<int, int> scores) =>
      players.every((m) => scores.containsKey(m.player.id));

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
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  /// Record a score and, if the user's Auto-advance setting is on, save +
  /// move to the next hole once the last player's score completes it.
  /// Skips clears (score == -1) and edits to an already-complete hole.
  void _handleScore(BuildContext ctx, Membership m, int score,
      List<Membership> players, int par) {
    final sc = context.read<RoundProvider>().scorecard;
    final hole = _selectedHole;
    final wasAllScored =
        sc != null && _allScored(players, _effectiveScores(sc, hole));
    _selectScore(m, score, hole);
    if (sc == null || score <= 0 || wasAllScored) return;
    if (!context.read<SettingsProvider>().autoAdvanceHole) return;
    if (!_allScored(players, _effectiveScores(sc, hole))) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedHole != hole) return;
      final rp = context.read<RoundProvider>();
      if (rp.submitting) return;
      _saveAndAdvance(ctx, players, par);   // on hole 18 this saves + stays
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
    rp.loadPoints531(widget.foursomeId);
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

    // Wait for the sync queue to drain so calculate_points_531 has
    // certainly run before we navigate to the leaderboard.
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final sc   = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';

    // Once the scorecard for THIS foursome arrives, jump to the first
    // unscored hole. Guard on activeFoursomeId so we don't act on a
    // stale scorecard that belongs to a different (e.g. previously
    // viewed) game.
    if (!_initialJumpDone &&
        sc != null &&
        rp.activeFoursomeId == widget.foursomeId) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstUnplayed(context.read<RoundProvider>());
      });
    }

    // After the sync queue drains, reload the Points 5-3-1 summary so the
    // per-hole point numbers and running totals pick up the server's
    // just-computed values.
    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadPoints531(widget.foursomeId);
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
        title: 'Points 5-3-1',
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
          if (rp.round != null)
            RoundChatButton(roundId: rp.round!.id),
          // Leaderboard shortcut — round-level summary across every game.
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null
                ? null
                : () => Navigator.of(context).pushNamed(
                      '/leaderboard',
                      arguments: rp.round!.id,
                    ),
          ),
        ],
      ),
      body: _buildBody(context, rp, sync, isComplete),
      bottomNavigationBar: sc == null ? null : _buildBottomNav(context, rp, sc),
    );
  }

  Widget _buildBottomNav(
    BuildContext ctx,
    RoundProvider rp,
    Scorecard sc,
  ) {
    final players    = _realPlayers(sc, rp.round);
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final par        = sc.holeData(_selectedHole)?.par ?? 4;

    return SafeArea(
      child: Padding(
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
    );
  }

  Widget _buildBody(
    BuildContext ctx,
    RoundProvider rp,
    SyncService sync,
    bool isComplete,
  ) {
    if (rp.loadingScorecard) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.scorecard == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        InlineMessage(kind: InlineMessageKind.error, text: rp.error!),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            rp.loadScorecard(widget.foursomeId);
            rp.loadPoints531(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }

    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final players  = _realPlayers(sc, rp.round);
    final merged   = _mergePending(rp.localPendingByHole, _pending);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    int hotSpot    = isComplete ? -1 : _hotSpotIdx(players, scores);
    if (!isComplete && _editHotPid != null) {
      final idx = players.indexWhere((p) => p.player.id == _editHotPid);
      if (idx != -1) hotSpot = idx;
    }
    final par      = holeData?.par ?? 4;

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
              // ── Active hole card ──
              _P531HoleScoreCard(
                holeData:    holeData,
                holeNumber:  _selectedHole,
                players:     players,
                scorecard:   sc,
                merged:      merged,
                scores:      scores,
                hotSpotIdx:  hotSpot,
                par:         par,
                summary:     rp.points531Summary,
                spotsActive:   spotsActive(rp),
                spotsCountFor: (pid) =>
                    spotsCount(pid, _selectedHole, rp.spotsSummary),
                onSpotsAdd:    (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, 1),
                onSpotsRemove: (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, -1),
                onScoreSelected: (m, score) {
                  if (_editHotPid != null) {
                    // Inline edit of an existing score: drop the one-shot
                    // override and commit the correction immediately.
                    setState(() => _editHotPid = null);
                    _selectScore(m, score, _selectedHole);
                    _saveAndAdvance(ctx, players, par, advance: false);
                  } else {
                    _handleScore(ctx, m, score, players, par);
                  }
                },
                onEditTap: (m) => setState(() => _editHotPid = m.player.id),
              ),
              const SizedBox(height: 12),

              // ── 18-hole summary grid ──
              if (rp.points531Summary != null) ...[
                _P531SummaryGrid(
                  summary:     rp.points531Summary!,
                  players:     players,
                  scorecard:   sc,
                  currentHole: _selectedHole,
                  onTapHole:   (h) =>
                      setState(() { _selectedHole = h; _editHotPid = null; }),
                ),
                const SizedBox(height: 12),
              ] else if (rp.loadingPoints531) ...[
                const Center(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )),
              ],

              const SizedBox(height: 16),
            ],
          ),
        ),
        ),
      ),
    ]);
  }
}

// ===========================================================================
// Active-hole card
// ===========================================================================

class _P531HoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final int              holeNumber;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, Map<int, int>> merged;
  final Map<int, int>    scores;
  final int              hotSpotIdx;
  final int              par;
  final Points531Summary? summary;
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership)      onEditTap;
  // Spots add-on (captured in this dedicated entry screen).
  final bool                   spotsActive;
  final int  Function(int pid) spotsCountFor;
  final void Function(int pid) onSpotsAdd;
  final void Function(int pid) onSpotsRemove;

  const _P531HoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.merged,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.summary,
    required this.onScoreSelected,
    required this.onEditTap,
    this.spotsActive   = false,
    required this.spotsCountFor,
    required this.onSpotsAdd,
    required this.onSpotsRemove,
  });

  String get _mode        => summary?.handicapMode ?? 'net';
  int    get _netPercent  => summary?.netPercent   ?? 100;

  int? get _lowPlayingHandicap {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players
        .map((m) => m.playingHandicap)
        .reduce((a, b) => a < b ? a : b);
  }

  int _matchHcapFor(Membership m) => effectiveMatchHandicap(
        mode:                  _mode,
        netPercent:            _netPercent,
        playingHandicap:       m.playingHandicap,
        lowestPlayingHandicap: _lowPlayingHandicap,
      );

  /// Per-player strokes on a hole for THIS match's handicap mode.
  /// Drives stroke-dot display and the inline picker's net-par coloring.
  ///
  /// Rules:
  ///   • Gross → 0 (no strokes given at all)
  ///   • Net @ 100% → the server's handicap_strokes on this entry, which
  ///     already uses each player's own tee SI.  Perfect for mixed
  ///     men's/women's foursomes where hole SIs differ by tee.
  ///   • Net @ non-100% → recompute with effective = round(phcp × pct)
  ///     and THIS PLAYER's own SI (now carried in the entry).
  ///   • Strokes-Off → recompute with effective = phcp − lowPhcp, still
  ///     using this player's own SI.
  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null) return 0;
    if (_mode == 'gross') return 0;

    final entry = h.scoreFor(m.player.id);
    // Prefer the player's own SI from the entry; fall back to the
    // shared SI (first player's tee) only if the entry is missing.
    final mySi = entry?.strokeIndex ?? h.strokeIndex;

    if (_mode == 'net') {
      if (_netPercent == 100 && entry != null) {
        return entry.handicapStrokes;
      }
      // Custom percentage: re-derive with scaled handicap.
      final effective = (m.playingHandicap * _netPercent / 100.0).round();
      return strokesOnHole(effective, mySi);
    }

    // Strokes-Off.  Low player plays to 0; everyone else gets
    // (own_phcp − low_phcp) strokes allocated to their hardest holes
    // (i.e. lowest SI in their own tee).  Zero strokes when this
    // player IS the low player.
    if (_mode == 'strokes_off') {
      final low = _lowPlayingHandicap;
      if (low == null) return 0;
      final so = m.playingHandicap - low;
      if (so <= 0) return 0;
      return strokesOnHole(so, mySi);
    }

    // Unknown mode — be safe.
    return 0;
  }


  /// Per-player cumulative Points 5-3-1 total (from the server summary).
  double _pointsFor(int playerId) {
    final s = summary;
    if (s == null) return 0.0;
    final row = s.players
        .where((p) => p.playerId == playerId)
        .firstOrNull;
    return row?.points ?? 0.0;
  }

  /// Points awarded for the currently-selected hole, if that hole has
  /// been fully scored on the server side.  Map of playerId → points.
  Map<int, double> _holePoints() {
    final s = summary;
    if (s == null) return const {};
    final hole = s.holes
        .where((h) => h.hole == holeNumber)
        .firstOrNull;
    if (hole == null) return const {};
    return { for (final e in hole.entries) e.playerId: e.points };
  }

  /// Build the "Par X | Y yds. | SI: Z" sub-header.  Values are
  /// collected PER DISTINCT TEE rather than per player: if two golfers
  /// play the same tee, that tee's par / yards / SI is listed once,
  /// not twice.  When every tee agrees on a field a single value is
  /// shown; when they differ, values are slash-joined in the order
  /// the tees first appear in the (already-sorted) player list — which
  /// is longest-tee-first, so "White/Red" for a mixed men's + women's
  /// foursome reads as "longer tee / shorter tee".
  ///
  /// Why this also matters for par: on some courses the first hole is
  /// a par-5 from the women's tees and a par-4 from the men's tees
  /// (e.g. Tilden Park), so this needs to slash par, not just yards.
  ///
  /// Yardage is omitted entirely when no tee provides it.
  static String _buildHoleHeaderText(
    ScorecardHole hole,
    List<Membership> players,
  ) {
    // Walk players in order, collecting at most one (par, yards, SI)
    // triple per distinct tee id.  `m.tee?.id` is the canonical key;
    // for the exceedingly rare case where a real player has no tee we
    // key on a negative player id so they're not silently collapsed
    // into another teeless entry.
    final seenKeys      = <int>{};
    final parVals       = <int>[];
    final yardVals      = <int?>[];
    final siVals        = <int>[];
    for (final m in players) {
      final key = m.tee?.id ?? -m.player.id;
      if (!seenKeys.add(key)) continue;
      final e = hole.scoreFor(m.player.id);
      parVals.add(e?.par ?? hole.par);
      yardVals.add(e?.yards ?? hole.yards);
      siVals.add(e?.strokeIndex ?? hole.strokeIndex);
    }

    // Deduplicate values (preserving first-seen order) then join with '/'.
    // [4,4,4] → "4"   [4,4,5] → "4/5"   [380,320] → "380/320"
    // Set dedup handles nullable ints correctly (null == null in Dart).
    String _collapse<T>(List<T> values, String Function(T) fmt) {
      if (values.isEmpty) return '';
      final seen   = <T>{};
      final unique = values.where((v) => seen.add(v)).toList();
      if (unique.length == 1) return fmt(unique.first);
      return unique.map(fmt).join('/');
    }

    final parStr   = 'Par ${_collapse<int>(parVals, (v) => '$v')}';
    final siStr    = 'SI: ${_collapse<int>(siVals, (v) => '$v')}';

    final anyYards = yardVals.any((y) => y != null);
    final yardStr  = anyYards
        ? '${_collapse<int?>(yardVals, (v) => v == null ? '—' : '$v')} yds.'
        : null;

    return yardStr == null
        ? '$parStr  |  $siStr'
        : '$parStr  |  $yardStr  |  $siStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final awards = _holePoints();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Hole header ──
          //
          // Par / yds / SI are now sourced from EACH PLAYER's own tee
          // entry so mixed men's/women's foursomes get accurate numbers.
          // When every player's tee agrees on a field, we show a single
          // value.  When any differ, we show them slash-joined in the
          // SAME ORDER AS THE PLAYER LIST — e.g. "4 / 5" for par on a
          // hole that's par 4 for the first two golfers and par 5 for
          // the third.  No labels are needed: yardage differences make
          // it self-evident which tee is which, and per the user's
          // design spec the SI slash order mirrors the player order.
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
              Builder(builder: (_) {
                if (holeData == null) return const SizedBox.shrink();
                final header = _buildHoleHeaderText(holeData!, players);
                return Text(
                  header,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                );
              }),
            ]),
          ),

          // ── Player rows + inline picker ──
          ...players.asMap().entries.expand((entry) {
            final idx     = entry.key;
            final m       = entry.value;
            final gross   = scores[m.player.id];
            final isHot   = idx == hotSpotIdx;
            final hasScore = gross != null;

            final matchStrokes = _strokesForHole(m, holeData);

            // Handicap chip reads "gets N" (strokes this player receives).
            // The stroke-this-hole indicator now lives in the dot strip above
            // the score box, so no bullets here. Hidden for a 0-stroke player
            // and in gross mode (no strokes of any kind are given).
            String? hcapLabel;
            if (_mode == 'net' || _mode == 'strokes_off') {
              final h = _matchHcapFor(m);
              if (h > 0) hcapLabel = 'gets $h';
            }

            final pointsForThisHole = awards[m.player.id];
            final cumulativePoints  = _pointsFor(m.player.id);

            final row = _P531PlayerRow(
                position:       idx + 1,
                member:         m,
                gross:          gross,
                isHot:          isHot,
                matchHcapLabel: hcapLabel,
                // Pass strokes so the score-box corner can render a dot
                // for players receiving a stroke on the active hole.  In
                // Net mode this duplicates the chip's stroke dots, which
                // is fine; in SO mode it's the ONLY visual indicator.
                strokesOnThisHole: matchStrokes,
                // Tapping a scored non-hot row opens the edit picker.
                onTap: (hasScore && !isHot)
                    ? () => onEditTap(m)
                    : null,
                holePoints:      pointsForThisHole,
                cumulativePoints: cumulativePoints,
                spotsActive:   spotsActive,
                spotsCount:    spotsActive ? spotsCountFor(m.player.id) : 0,
                onSpotsAdd:    spotsActive ? () => onSpotsAdd(m.player.id) : null,
                onSpotsRemove:
                    spotsActive ? () => onSpotsRemove(m.player.id) : null,
              );
            if (isHot) {
              // Active player + picker share ONE bounding box (no teams in
              // Points, so it uses the brand pine). Flush-left bold bar, right
              // inset so the right line shows, faint wash fill.
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
                        par:           par,
                        strokes:       matchStrokes,
                        currentScore:  gross,
                        boxBorderColor: boxColor,
                        boxFillColor:   Colors.white,
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
// One player row — mirrors Sixes's _PlayerScoreRow with a points chip
// ---------------------------------------------------------------------------

class _P531PlayerRow extends StatelessWidget {
  final int          position;
  final Membership   member;
  final int?         gross;
  final bool         isHot;
  final String?      matchHcapLabel;
  final VoidCallback? onTap;

  /// Number of handicap strokes this player gets on the ACTIVE hole.
  /// Rendered as small dots in the top-right corner of the score box
  /// so the info stays visible even when the matchHcapLabel chip is
  /// hidden (SO / Gross modes).  Zero means no dot.
  final int          strokesOnThisHole;

  /// Points awarded to this player on the currently-selected hole, or
  /// null if the hole isn't fully scored yet.  When present we render
  /// a small pill next to the running totals so it's easy to see what
  /// the hole "paid out".
  final double?      holePoints;

  /// Cumulative Points 5-3-1 total for this player so far in the round.
  /// Always shown (0.0 until any hole is scored).
  final double       cumulativePoints;

  final bool          spotsActive;
  final int           spotsCount;
  final VoidCallback? onSpotsAdd;
  final VoidCallback? onSpotsRemove;

  const _P531PlayerRow({
    required this.position,
    required this.member,
    required this.gross,
    required this.isHot,
    this.matchHcapLabel,
    this.onTap,
    this.strokesOnThisHole = 0,
    required this.holePoints,
    required this.cumulativePoints,
    this.spotsActive = false,
    this.spotsCount = 0,
    this.onSpotsAdd,
    this.onSpotsRemove,
  });

  static String _fmtPoints(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color boxBg = isHot ? Colors.white : Colors.transparent;
    final boxBorder = isHot
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: theme.colorScheme.outline);

    return Container(
      decoration: BoxDecoration(
        // When active the row is transparent so the bounding box's wash shows
        // through and provides the frame; inactive rows keep the top divider.
        color: Colors.transparent,
        border: isHot
            ? const Border()
            : Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Name + match handicap chip
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
            Text('$position)  ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary)),
            Flexible(
              child: Text(
                member.player.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isHot ? theme.colorScheme.primary : null,
                ),
              ),
            ),
            if (matchHcapLabel != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
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

        // Running totals + points pills
        Flexible(
          flex: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                // "Hole: X" pill — only when the hole is fully scored.
                if (holePoints != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '+${_fmtPoints(holePoints!)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                // Cumulative total pill — always shown.
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: theme.colorScheme.outlineVariant),
                  ),
                  child: Text(
                    '${_fmtPoints(cumulativePoints)} pts',
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ],
          ),
        ),
        const SizedBox(width: 8),

        // Score box.  Stack so a stroke-dot indicator can sit in the
        // top-right corner without interfering with the score digit in
        // the centre.  The dot is the primary stroke indicator in SO
        // mode (where the handicap chip is hidden), and a redundant
        // reassurance in Net mode alongside the chip's dots.
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
                    ? Text(
                        '$gross',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      )
                    : isHot
                        ? Icon(
                            Icons.arrow_drop_down,
                            size: 20,
                            color: theme.colorScheme.primary,
                          )
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
// 18-hole summary grid — compact matrix of scores + per-hole 5-3-1 awards
// ===========================================================================

class _P531SummaryGrid extends StatefulWidget {
  final Points531Summary summary;
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int hole)? onTapHole;

  const _P531SummaryGrid({
    required this.summary,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
  });

  @override
  State<_P531SummaryGrid> createState() => _P531SummaryGridState();
}

class _P531SummaryGridState extends State<_P531SummaryGrid> {
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
  void didUpdateWidget(_P531SummaryGrid old) {
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

  /// Per-hole points awarded for this player (from server summary).
  /// Returns a map: hole → points.
  Map<int, double> _pointsByHole(int playerId) {
    final out = <int, double>{};
    for (final h in widget.summary.holes) {
      for (final e in h.entries) {
        if (e.playerId == playerId) {
          out[h.hole] = e.points;
          break;
        }
      }
    }
    return out;
  }

  /// Mode-aware stroke count for the summary grid dots.
  /// Mirrors `_P531HoleScoreCard._strokesForHole`:
  ///   • Gross → 0 (no dots)
  ///   • Net @ 100% → the server's entry.handicapStrokes (uses this
  ///     player's own tee SI already)
  ///   • Net @ non-100% → compute with effective = phcp × pct on the
  ///     player's own SI
  ///   • Strokes-Off → compute with effective = phcp − lowPhcp on the
  ///     player's own SI
  int _strokesOnHoleFor(Membership m, int holeNumber) {
    final summary   = widget.summary;
    final scorecard = widget.scorecard;
    final players   = widget.players;
    if (summary.handicapMode == 'gross') return 0;
    final hole = scorecard.holeData(holeNumber);
    if (hole == null) return 0;
    final entry = hole.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? hole.strokeIndex;

    if (summary.handicapMode == 'net') {
      if (summary.netPercent == 100 && entry != null) {
        return entry.handicapStrokes;
      }
      final effective = (m.playingHandicap * summary.netPercent / 100.0).round();
      return strokesOnHole(effective, mySi);
    }

    if (summary.handicapMode == 'strokes_off') {
      if (players.isEmpty) return 0;
      final low = players.map((p) => p.playingHandicap).reduce((a, b) => a < b ? a : b);
      final so  = m.playingHandicap - low;
      if (so <= 0) return 0;
      return strokesOnHole(so, mySi);
    }

    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final summary     = widget.summary;
    final players     = widget.players;
    final scorecard   = widget.scorecard;
    final currentHole = widget.currentHole;
    final onTapHole   = widget.onTapHole;

    const double labelColW = 56.0;
    const double cellW     = 34.0;
    const double rowH      = 28.0;

    final holeRange = List.generate(18, (i) => i + 1);

    // Helper: tappable hole column cell (common to every row).
    Widget holeCell(int h, {required Widget child, Color? bg, bool bold = false}) {
      final isCurrent = h == currentHole;
      return GestureDetector(
        onTap: onTapHole == null ? null : () => onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: cellW,
          height: rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? (isCurrent
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
                  // Header: hole numbers
                  Row(children: [
                    SizedBox(
                      width: labelColW,
                      height: rowH,
                      child: const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Hole',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    for (final h in holeRange) holeCell(h,
                        child: Text('$h',
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold))),
                  ]),
                  // Par row
                  Row(children: [
                    SizedBox(
                      width: labelColW,
                      height: rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Par',
                            style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic)),
                      ),
                    ),
                    for (final h in holeRange) holeCell(h,
                        child: Text(
                          '${scorecard.holeData(h)?.par ?? "-"}',
                          style: theme.textTheme.bodySmall,
                        )),
                  ]),
                  // Divider — visually separates the fixed course-info rows
                  // (Hole numbers + Par) from the player score / points
                  // rows below.  Full-width so it spans across every hole
                  // column plus the label column.
                  Container(
                    height: 1,
                    width: labelColW + cellW * holeRange.length,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // One row per player: score cell + stroke dot overlay + points-won below
                  for (final m in players) _PlayerGridRows(
                    member:      m,
                    scorecard:   scorecard,
                    holeRange:   holeRange,
                    currentHole: currentHole,
                    onTapHole:   onTapHole,
                    labelColW:   labelColW,
                    cellW:       cellW,
                    rowH:        rowH,
                    strokesOnHole: (h) => _strokesOnHoleFor(m, h),
                    pointsByHole:  _pointsByHole(m.player.id),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders two stacked rows for one player: the gross scores (with a
/// stroke dot when applicable) and the per-hole Points 5-3-1 award.
class _PlayerGridRows extends StatelessWidget {
  final Membership   member;
  final Scorecard    scorecard;
  final List<int>    holeRange;
  final int          currentHole;
  final void Function(int hole)? onTapHole;
  final double       labelColW;
  final double       cellW;
  final double       rowH;
  final int Function(int hole)    strokesOnHole;
  final Map<int, double>           pointsByHole;

  const _PlayerGridRows({
    required this.member,
    required this.scorecard,
    required this.holeRange,
    required this.currentHole,
    required this.onTapHole,
    required this.labelColW,
    required this.cellW,
    required this.rowH,
    required this.strokesOnHole,
    required this.pointsByHole,
  });

  static String _fmtPoints(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Score row (with stroke dot in top-right corner when applicable)
        Row(children: [
          SizedBox(
            width: labelColW, height: rowH,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(member.player.displayShort,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
          for (final h in holeRange) _cell(h, context, child: scoreCellWithDots(
            SizedBox(
              width:  cellW,
              height: rowH,
              child: Center(
                child: Builder(builder: (_) {
                  final saved = scorecard.holeData(h)?.scoreFor(member.player.id);
                  final gross = saved?.grossScore;
                  return Text(
                    gross == null ? '–' : '$gross',
                    style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: gross == null
                            ? theme.colorScheme.onSurfaceVariant
                            : null),
                  );
                }),
              ),
            ),
            strokesOnHole(h),
            theme.colorScheme.primary,
          )),
        ]),
        // Points awarded row (same player, labelled "pts")
        Row(children: [
          SizedBox(
            width: labelColW, height: rowH - 4,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(' pts',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic)),
            ),
          ),
          for (final h in holeRange) Container(
            width: cellW, height: rowH - 4,
            alignment: Alignment.center,
            child: Builder(builder: (_) {
              final pts = pointsByHole[h];
              if (pts == null) {
                return Text('·', style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant));
              }
              final isWinner = pts >= 5;
              return Text(
                _fmtPoints(pts),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: isWinner ? FontWeight.bold : FontWeight.w600,
                  color: isWinner
                      ? Colors.green.shade700
                      : theme.colorScheme.onSurface,
                ),
              );
            }),
          ),
        ]),
      ],
    );
  }
}
