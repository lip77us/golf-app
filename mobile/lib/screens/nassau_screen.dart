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
///   • Team banner (T1 vs T2 short names)
///   • Presses strip (active/completed presses)
///   • F9 / B9 / Overall match status chips + Call Press button

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';

// ---------------------------------------------------------------------------
// Handicap helpers (identical to points_531_screen.dart)
// ---------------------------------------------------------------------------

int _effectiveMatchHandicap({
  required String mode,
  required int    netPercent,
  required int    playingHandicap,
  int?            lowestPlayingHandicap,
}) {
  switch (mode) {
    case 'gross':
      return 0;
    case 'strokes_off':
      if (lowestPlayingHandicap == null) return playingHandicap;
      final off = playingHandicap - lowestPlayingHandicap;
      return off < 0 ? 0 : off;
    case 'net':
    default:
      if (netPercent == 100) return playingHandicap;
      return (playingHandicap * netPercent / 100.0).round();
  }
}

int _strokesOnHole(int effectiveHandicap, int strokeIndex) {
  if (effectiveHandicap <= 0) return 0;
  final full  = effectiveHandicap ~/ 18;
  final rem   = effectiveHandicap %  18;
  final extra = strokeIndex <= rem ? 1 : 0;
  return full + extra;
}

String _signed(int v) => v > 0 ? '(+$v)' : '($v)';

class _RunningTotal {
  final int grossVsPar;
  final int netVsPar;
  const _RunningTotal({required this.grossVsPar, required this.netVsPar});
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class NassauScreen extends StatefulWidget {
  final int foursomeId;
  const NassauScreen({super.key, required this.foursomeId});

  @override
  State<NassauScreen> createState() => _NassauScreenState();
}

class _NassauScreenState extends State<NassauScreen> {
  /// Unsubmitted score edits for the current session.  hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;

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
      rp.loadNassau(widget.foursomeId);
    });
  }

  // ── Player helpers ──────────────────────────────────────────────────────────

  /// Real (non-phantom) players ordered T1 first, T2 second per the nassau
  /// summary.  Falls back to natural membership order when summary not yet loaded.
  List<Membership> _orderedPlayers(
      Scorecard sc, Round? round, NassauSummary? nas) {
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

    if (nas == null) return members;

    final ordered = <Membership>[];
    for (final id in [
      ...nas.team1.map((p) => p.playerId),
      ...nas.team2.map((p) => p.playerId),
    ]) {
      final m = members.where((m) => m.player.id == id).firstOrNull;
      if (m != null) ordered.add(m);
    }
    // Include any players not assigned to a team (safety net).
    for (final m in members) {
      if (!ordered.any((o) => o.player.id == m.player.id)) ordered.add(m);
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

  Future<void> _editScore(
    BuildContext ctx,
    Membership player,
    int par,
    int hole,
    List<Membership> players,
    NassauSummary? nas,
  ) async {
    final rp      = context.read<RoundProvider>();
    final sc      = rp.scorecard;
    final current = (_pending[hole] ?? {})[player.player.id]
        ?? sc?.holeData(hole)?.scoreFor(player.player.id)?.grossScore;

    final mode       = nas?.handicapMode ?? 'net';
    final netPercent = nas?.netPercent   ?? 100;
    final lowPlaying = mode == 'strokes_off' && players.isNotEmpty
        ? players
            .map((m) => m.playingHandicap)
            .reduce((a, b) => a < b ? a : b)
        : null;
    final effective = _effectiveMatchHandicap(
      mode:                  mode,
      netPercent:            netPercent,
      playingHandicap:       player.playingHandicap,
      lowestPlayingHandicap: lowPlaying,
    );
    // Use this player's own tee SI, not the shared first-player SI.
    final holeEntry = sc?.holeData(hole)?.scoreFor(player.player.id);
    final si        = holeEntry?.strokeIndex ?? sc?.holeData(hole)?.strokeIndex ?? 18;
    final strokes   = _strokesOnHole(effective, si);

    final score = await showModalBottomSheet<int>(
      context: ctx,
      useRootNavigator: true,
      builder: (_) => _NassauScorePickerSheet(
        playerName: player.player.name,
        par:        par,
        holeNumber: hole,
        strokes:    strokes,
        current:    current,
      ),
    );
    if (!mounted) return;
    if (score == null) return;
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
    if (_selectedHole < 18) setState(() => _selectedHole++);
  }

  void _retreat() {
    if (_selectedHole > 1) setState(() => _selectedHole--);
  }

  Future<void> _saveAndAdvance(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final edits = _pending[_selectedHole];
    if (edits == null || edits.isEmpty) {
      _advance();
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
          onPressed: () => _saveAndAdvance(ctx, players, par),
        ),
      ));
      return;
    }
    setState(() { _pending.remove(_selectedHole); });
    rp.loadNassau(widget.foursomeId);
    _advance();
  }

  Future<void> _finishRound(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
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
    rp.loadNassau(widget.foursomeId);
    if (roundId != null) {
      Navigator.of(ctx).pushNamed('/leaderboard', arguments: roundId);
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
      appBar: AppBar(
        title: Text(nas != null
            ? 'Nassau — ${_modeLabel(nas.handicapMode, nas.netPercent)}'
            : 'Nassau'),
        centerTitle: true,
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
          IconButton(
            tooltip: 'Full scorecard',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: sc == null
                ? null
                : () => Navigator.of(context).pushNamed('/scorecard',
                    arguments: {'foursomeId': widget.foursomeId, 'readOnly': true}),
          ),
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
          // Hole navigation
          Padding(
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
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;

    return Column(children: [
      // Team banner (T1 vs T2 names)
      if (nas != null) _TeamBanner(summary: nas),

      // Presses strip — show only presses for the current nine.
      // Front-nine presses are cleared once we reach hole 10.
      if (nas != null && nas.presses.isNotEmpty)
        _PressesStrip(
          presses:     nas.presses,
          currentHole: _selectedHole,
        ),

      Expanded(
        child: SingleChildScrollView(
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
                onScoreSelected: (m, score) =>
                    _selectScore(m, score, _selectedHole),
                onEditTap: (m) =>
                    _editScore(ctx, m, par, _selectedHole, players, nas),
              ),
              const SizedBox(height: 12),

              // 18-hole summary grid
              if (nas != null) ...[
                _NassauSummaryGrid(
                  nassau:      nas,
                  players:     players,
                  scorecard:   sc,
                  currentHole: _selectedHole,
                  onTapHole:   (h) => setState(() => _selectedHole = h),
                ),
                const SizedBox(height: 12),
              ] else if (rp.loadingNassau) ...[
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ],

              const SizedBox(height: 16),
            ],
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
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership)      onEditTap;

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
    required this.onScoreSelected,
    required this.onEditTap,
  });

  String get _mode       => nassau?.handicapMode ?? 'net';
  int    get _netPercent => nassau?.netPercent   ?? 100;

  int? get _lowPlayingHandicap {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  int _matchHcapFor(Membership m) => _effectiveMatchHandicap(
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
      return _strokesOnHole(effective, mySi);
    }

    if (_mode == 'strokes_off') {
      final low = _lowPlayingHandicap;
      if (low == null) return 0;
      final so = m.playingHandicap - low;
      if (so <= 0) return 0;
      return _strokesOnHole(so, mySi);
    }

    return 0;
  }

  _RunningTotal _running(int playerId) {
    final m = players.where((x) => x.player.id == playerId).firstOrNull;

    int gross = 0, parSum = 0, net = 0;
    for (final h in scorecard.holes) {
      final pendingGross = merged[h.holeNumber]?[playerId];
      final saved        = h.scoreFor(playerId);
      final grossScore   = pendingGross ?? saved?.grossScore;
      if (grossScore == null) continue;
      gross  += grossScore;
      parSum += h.par;
      final strokes = m == null ? 0 : _strokesForHole(m, h);
      net += grossScore - strokes;
    }
    return _RunningTotal(grossVsPar: gross - parSum, netVsPar: net - parSum);
  }

  String? _teamLabelFor(int playerId) {
    if (nassau == null) return null;
    if (nassau!.team1.any((p) => p.playerId == playerId)) return 'T1';
    if (nassau!.team2.any((p) => p.playerId == playerId)) return 'T2';
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
            final rt         = _running(m.player.id);
            final gross      = scores[m.player.id];
            final isHot      = idx == hotSpotIdx;
            final hasScore   = gross != null;
            final matchStrok = _strokesForHole(m, holeData);

            String? hcapLabel;
            if (_mode == 'net' || _mode == 'strokes_off') {
              final dots = matchStrok > 0 ? ' ${'•' * matchStrok}' : '';
              hcapLabel = '-${_matchHcapFor(m)}$dots';
            }

            return [
              _NassauPlayerRow(
                member:              m,
                running:             rt,
                gross:               gross,
                isHot:               isHot,
                matchHcapLabel:      hcapLabel,
                strokesOnThisHole:   matchStrok,
                showNetRunningTotal: _mode == 'net',
                teamLabel:           _teamLabelFor(m.player.id),
                onTap: (hasScore && !isHot) ? () => onEditTap(m) : null,
              ),
              if (isHot)
                _InlinePicker(
                  par:             par,
                  strokes:         matchStrok,
                  currentScore:    gross,
                  onScoreSelected: (score) => onScoreSelected(m, score),
                ),
            ];
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
      bg    = Colors.blue.shade50;
      fg    = Colors.blue.shade700;
      label = 'T1 wins hole';
    } else {
      bg    = Colors.orange.shade50;
      fg    = Colors.orange.shade800;
      label = 'T2 wins hole';
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
// Player row (mirrors _P531PlayerRow, adds team badge)
// ---------------------------------------------------------------------------

class _NassauPlayerRow extends StatelessWidget {
  final Membership    member;
  final _RunningTotal running;
  final int?          gross;
  final bool          isHot;
  final String?       matchHcapLabel;
  final VoidCallback? onTap;
  final int           strokesOnThisHole;
  final bool          showNetRunningTotal;
  final String?       teamLabel;

  const _NassauPlayerRow({
    required this.member,
    required this.running,
    required this.gross,
    required this.isHot,
    this.matchHcapLabel,
    this.onTap,
    this.strokesOnThisHole = 0,
    this.showNetRunningTotal = true,
    this.teamLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color boxBg = isHot
        ? theme.colorScheme.primaryContainer.withOpacity(0.4)
        : Colors.transparent;
    final boxBorder = isHot
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: theme.colorScheme.outline);

    return Container(
      decoration: BoxDecoration(
        color: isHot
            ? theme.colorScheme.primaryContainer.withOpacity(0.08)
            : null,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Team badge (T1 = blue, T2 = orange)
        if (teamLabel != null) ...[
          Container(
            width: 28,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: teamLabel == 'T1'
                  ? Colors.blue.shade100
                  : Colors.orange.shade100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              teamLabel!,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: teamLabel == 'T1'
                    ? Colors.blue.shade700
                    : Colors.orange.shade800,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],

        // Name + handicap chip
        Expanded(
          child: Row(children: [
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
          ]),
        ),

        // Running total
        Text(
          showNetRunningTotal
              ? '${_signed(running.grossVsPar)}G ${_signed(running.netVsPar)}N'
              : '${_signed(running.grossVsPar)}G',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.secondary),
        ),
        const SizedBox(width: 8),

        // Score box with optional stroke dots
        GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 36,
            decoration: BoxDecoration(
              color: boxBg,
              border: boxBorder,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Stack(children: [
              Center(
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
              if (strokesOnThisHole > 0)
                Positioned(
                  top: 2, right: 2,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                      strokesOnThisHole.clamp(0, 2),
                      (i) => Container(
                        width: 4, height: 4,
                        margin: const EdgeInsets.only(left: 1),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline score picker (identical to points_531_screen.dart)
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
          top: BorderSide(
              color: theme.colorScheme.primary.withOpacity(0.2)),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10),
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
                        fontWeight: FontWeight.bold,
                      )),
                ),
              ),
            );
          }
          final s   = scores[i];
          final sel = s == widget.currentScore;
          return Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: _itemMargin),
            child: NetScoreButton(
              score:    s,
              par:      widget.par,
              strokes:  widget.strokes,
              selected: sel,
              width:    _itemWidth,
              height:   48,
              onTap:    () => widget.onScoreSelected(s),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Modal score picker sheet
// ---------------------------------------------------------------------------

class _NassauScorePickerSheet extends StatelessWidget {
  final String playerName;
  final int    par;
  final int    holeNumber;
  final int    strokes;
  final int?   current;

  const _NassauScorePickerSheet({
    required this.playerName,
    required this.par,
    required this.holeNumber,
    required this.strokes,
    this.current,
  });

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final scores = List.generate(12, (i) => i + 1);
    final netPar = par + strokes;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Text(playerName,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          Text(
            strokes > 0
                ? 'Hole $holeNumber  •  Par $par  •  Net par $netPar'
                : 'Hole $holeNumber  •  Par $par',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: scores.length,
              itemBuilder: (_, i) {
                final s   = scores[i];
                final sel = s == current;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4),
                  child: NetScoreButton(
                    score:    s,
                    par:      par,
                    strokes:  strokes,
                    selected: sel,
                    width:    46,
                    height:   52,
                    onTap:    () => Navigator.of(context).pop(s),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          if (current != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(-1),
              child: const Text('Clear score'),
            )
          else
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// 18-hole summary grid
// ===========================================================================

class _NassauSummaryGrid extends StatefulWidget {
  final NassauSummary    nassau;
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
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
      return _strokesOnHole(effective, mySi);
    }

    if (nassau.handicapMode == 'strokes_off') {
      if (players.isEmpty) return 0;
      final low = players
          .map((p) => p.playingHandicap)
          .reduce((a, b) => a < b ? a : b);
      final so = m.playingHandicap - low;
      if (so <= 0) return 0;
      return _strokesOnHole(so, mySi);
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
                  // Player score rows
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
                    ),
                  // Hole winner row
                  Row(children: [
                    SizedBox(
                      width: labelColW, height: rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Won by',
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
                          bg    = Colors.blue.shade100;
                          fg    = Colors.blue.shade700;
                          label = 'T1';
                        } else if (winner == 'team2') {
                          bg    = Colors.orange.shade100;
                          fg    = Colors.orange.shade800;
                          label = 'T2';
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
                ],
              ),
            ),
          ],
        ),
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

    return Row(children: [
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
                    return Text(
                      gross == null ? '–' : '$gross',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: gross == null
                            ? theme.colorScheme.onSurfaceVariant
                            : null,
                      ),
                    );
                  }),
                ),
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
    final t1 = summary.team1.map((p) => p.name).join(' & ');
    final t2 = summary.team2.map((p) => p.name).join(' & ');

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(
          child: Text(t1,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.blue.shade700,
              ),
              overflow: TextOverflow.ellipsis),
        ),
        Text(' vs ',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Expanded(
          child: Text(t2,
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.orange.shade800,
              ),
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Presses strip
// ---------------------------------------------------------------------------

class _PressesStrip extends StatelessWidget {
  final List<NassauPressResult> presses;
  /// Current hole being viewed — used to filter which nine's presses to show.
  final int currentHole;
  const _PressesStrip({required this.presses, required this.currentHole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Show only presses for the currently active nine.
    // Front-nine presses disappear once we move to hole 10+.
    final currentNine = currentHole <= 9 ? 'front' : 'back';
    final visible = presses.where((p) => p.nine == currentNine).toList();
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
          final p      = visible[i];
          // No F/B prefix — the nine is already implied by which screen
          // section we're in, and the hole range makes it clear.
          final label  = '${p.startHole}–${p.endHole}';
          final result = p.result;
          final m      = p.margin ?? 0;
          final mAbs   = m.abs();
          Color  chipColor;
          String scoreText;
          if (result == 'team1') {
            chipColor = Colors.blue.shade100;
            scoreText = p.holesRemaining > 0
                ? '$mAbs&${p.holesRemaining}'
                : '${mAbs}UP';
          } else if (result == 'team2') {
            chipColor = Colors.orange.shade100;
            scoreText = p.holesRemaining > 0
                ? '$mAbs&${p.holesRemaining}'
                : '${mAbs}UP';
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _betChip(context, 'F9',  summary.front9),
            _betChip(context, 'B9',  summary.back9),
            _betChip(context, 'ALL', summary.overall),
          ],
        ),
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

    if (result != null) {
      // Nine is fully resolved
      if (result == 'halved') {
        bg       = Colors.grey.shade200;
        subtitle = 'AS';
      } else {
        bg = result == 'team1' ? Colors.blue.shade100 : Colors.orange.shade100;
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
      bg       = t1Leads ? Colors.blue.shade100 : Colors.orange.shade100;
      subtitle = '${bet.margin.abs()}&$holesLeft';
    } else {
      // In progress — colour by leader, no team label.
      bg       = t1Leads ? Colors.blue.shade50 : Colors.orange.shade50;
      subtitle = '${bet.margin.abs()}UP';
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
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ]),
    );
  }
}
