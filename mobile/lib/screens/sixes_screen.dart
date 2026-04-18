/// screens/sixes_screen.dart
///
/// Score-entry and live-standings screen for the Six's game.
///
/// Layout (matches wireframes):
///   • AppBar:      "Golf Gaming" centred title.
///   • Top card:    Hole N header (par / yds / SI) + player rows.
///                  Each row shows running (+X)G (+Y)N totals and a
///                  score box.  The "hot-spot" (first player without a
///                  score on this hole) has a shaded box AND an inline
///                  scrollable score picker that auto-appears below it —
///                  no tap required.  After picking, hot-spot advances.
///                  Tapping a previously entered score box opens a modal
///                  sheet to edit or clear it.
///   • Hole nav:    Scrollable chips for all 18 holes.
///   • Match grid:  One card per segment ("Match 1"…"Match 4") showing
///                  team abbreviations, positions, and live match status.
///                  Extra matches without players show "Select Players"
///                  in red — tapping it opens the setup screen.
///   • Bottom nav:  ← Hole N-1  |  Hole N+1 →
///                  "Hole N+1" enabled only when all 4 players scored;
///                  tapping it saves and advances.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';

// Top-level helper shared by _MatchGrid and _ExtraTeamPickerSheet.
String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
}

class SixesScreen extends StatefulWidget {
  final int foursomeId;
  const SixesScreen({super.key, required this.foursomeId});

  @override
  State<SixesScreen> createState() => _SixesScreenState();
}

class _SixesScreenState extends State<SixesScreen> {
  /// In-flight scores entered on the device but not yet submitted.
  /// Structure: hole → playerId → grossScore.
  final Map<int, Map<int, int>> _pending = {};

  int  _selectedHole   = 1;
  bool _pinkBallLost   = false;

  /// Tracks whether the sync queue had items during the previous build, so we
  /// can detect the pending→idle transition and re-load sixes standings once
  /// the server has processed the scores (i.e. calculate_sixes has run).
  bool _prevHadPending = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

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
      rp.loadSixes(widget.foursomeId);
      _jumpToFirstUnplayed(rp);
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  bool get _hasPinkBall {
    final rp = context.read<RoundProvider>();
    return rp.round?.activeGames.contains('pink_ball') ?? false;
  }

  /// Returns players in the order they were assigned to teams during setup.
  /// Reads team1.players then team2.players from the first sixes segment,
  /// matched back to Membership objects so we preserve handicap data.
  /// Falls back to foursome / scorecard order if summary is unavailable.
  List<Membership> _orderedPlayers(
    Scorecard sc,
    Round? round,
    SixesSummary? sixesSummary,
  ) {
    final allMembers = _rawPlayers(sc, round);

    // Try to derive order from sixes summary segment teams (respects drag order).
    if (sixesSummary != null && sixesSummary.segments.isNotEmpty) {
      final seg = sixesSummary.segments.first;
      if (seg.team1.hasPlayers && seg.team2.hasPlayers) {
        final orderedNames = [...seg.team1.players, ...seg.team2.players];
        final result = <Membership>[];
        for (final name in orderedNames) {
          final m = allMembers.where((m) => m.player.name == name).firstOrNull;
          if (m != null && !result.any((r) => r.player.id == m.player.id)) {
            result.add(m);
          }
        }
        // Append any unmatched members (safety net).
        for (final m in allMembers) {
          if (!result.any((r) => r.player.id == m.player.id)) result.add(m);
        }
        if (result.isNotEmpty) return result;
      }
    }
    return allMembers;
  }

  List<Membership> _rawPlayers(Scorecard sc, Round? round) {
    final foursome = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (foursome != null) return foursome.realPlayers;
    if (sc.holes.isEmpty) return [];
    return sc.holes.first.scores
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

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    for (int h = 1; h <= 18; h++) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      final allScored = hd.scores.every((s) => s.grossScore != null);
      if (!allScored && !rp.localPendingByHole.containsKey(h)) {
        setState(() => _selectedHole = h);
        return;
      }
    }
  }

  /// Effective scores for [hole]: server data merged with in-flight UI edits
  /// (UI wins).  Returns playerId → grossScore.
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

  /// Index (0-based) of the first player in [players] who has no score on
  /// [hole], or -1 if all scored.
  int _hotSpotIdx(List<Membership> players, Map<int, int> scores) {
    for (int i = 0; i < players.length; i++) {
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  bool _allScored(List<Membership> players, Map<int, int> scores) =>
      players.every((m) => scores.containsKey(m.player.id));

  /// Called by the inline picker when the hot-spot player's score is selected.
  void _selectScore(Membership player, int score, int hole) {
    setState(() {
      if (score == -1) {
        // Clear
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  /// Open the modal score-picker sheet for editing a previously entered score.
  Future<void> _editScore(
    BuildContext ctx,
    Membership player,
    int par,
    int hole,
  ) async {
    final sc      = context.read<RoundProvider>().scorecard;
    final current = (_pending[hole] ?? {})[player.player.id]
        ?? _scoreFromCard(sc, hole, player.player.id);
    // Per-player handicap strokes on this hole, as served by the scorecard.
    final strokes = sc?.holeData(hole)?.scoreFor(player.player.id)
            ?.handicapStrokes ?? 0;

    final score = await showModalBottomSheet<int>(
      context: ctx,
      useRootNavigator: true,
      builder: (_) => _ScorePickerSheet(
        playerName: player.player.name,
        par: par,
        holeNumber: hole,
        strokes: strokes,
        current: current,
      ),
    );
    if (!mounted) return;
    if (score == null) return;
    setState(() {
      if (score == -1) {
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  int? _scoreFromCard(Scorecard? sc, int hole, int playerId) {
    return sc?.holeData(hole)?.scoreFor(playerId)?.grossScore;
  }

  /// Save current hole and advance to next hole.
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
      foursomeId:   widget.foursomeId,
      holeNumber:   _selectedHole,
      scores:       scores,
      pinkBallLost: _pinkBallLost,
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

    setState(() {
      _pending.remove(_selectedHole);
      _pinkBallLost = false;
    });

    // Fire a load now — may return stale data if the sync is still in flight.
    // The drain-complete listener in build() will fire a second load once the
    // server has processed the scores and calculate_sixes has run.
    rp.loadSixes(widget.foursomeId);

    _advance();
  }

  /// Show the extra match team picker sheet, then POST the team assignment
  /// to the backend without touching any existing hole results.
  Future<void> _showExtraTeamPicker(
    SixesSegment extraSeg,
    List<Membership> players,
  ) async {
    final result = await showModalBottomSheet<List<List<int>>>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => _ExtraTeamPickerSheet(members: players),
    );
    if (result == null || !mounted) return;

    final rp = context.read<RoundProvider>();
    final ok = await rp.setExtraTeams(widget.foursomeId, result[0], result[1]);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Failed to save extra match teams.'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  void _advance() {
    if (_selectedHole < 18) setState(() => _selectedHole++);
  }

  void _retreat() {
    if (_selectedHole > 1) setState(() => _selectedHole--);
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final sc   = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';

    // Detect when the sync queue drains (pending → idle).  At that point the
    // server has run calculate_sixes, so we refresh the standings.
    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadSixes(widget.foursomeId);
      });
    }
    _prevHadPending = nowHasPending;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Golf Gaming'),
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
                      ? null : () => sync.recheck(),
                ),
              ),
            ),
          if (sc != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                rp.loadScorecard(widget.foursomeId);
                rp.loadSixes(widget.foursomeId);
              },
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
    final players    = _orderedPlayers(sc, rp.round, rp.sixesSummary);
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final par        = sc.holeData(_selectedHole)?.par ?? 4;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(children: [
          // ← Previous hole
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _selectedHole > 1 ? _retreat : null,
              icon: const Icon(Icons.chevron_left, size: 20),
              label: Text('Hole ${_selectedHole - 1}'),
            ),
          ),
          const SizedBox(width: 8),

          // Next hole / Done
          Expanded(
            child: _selectedHole == 18 || isComplete
                ? FilledButton.icon(
                    onPressed: () {
                      final roundId = rp.round?.id;
                      if (roundId != null) {
                        Navigator.of(ctx)
                            .pushNamed('/leaderboard', arguments: roundId);
                      }
                    },
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
        Text(rp.error!, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            rp.loadScorecard(widget.foursomeId);
            rp.loadSixes(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }

    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final players  = _orderedPlayers(sc, rp.round, rp.sixesSummary);
    final merged   = _mergePending(rp.localPendingByHole, _pending);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;

    return Column(children: [
      _SyncBanner(sync: sync),
      if (rp.error != null)
        _ErrorBanner(message: rp.error!, onDismiss: rp.clearError),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Hole info card with inline score picker ──
              _HoleScoreCard(
                holeData:   holeData,
                holeNumber: _selectedHole,
                players:    players,
                scorecard:  sc,
                merged:     merged,
                scores:     scores,
                hotSpotIdx: hotSpot,
                par:        par,
                hasPinkBall:   _hasPinkBall,
                pinkBallLost:  _pinkBallLost,
                onScoreSelected: (m, score) =>
                    _selectScore(m, score, _selectedHole),
                onEditTap: (m) =>
                    _editScore(ctx, m, par, _selectedHole),
                onPinkBallLostChanged: (v) =>
                    setState(() => _pinkBallLost = v),
              ),
              const SizedBox(height: 12),

              // ── Match grid ──
              if (rp.sixesSummary != null) ...[
                _MatchGrid(
                  summary:     rp.sixesSummary!,
                  members:     players,
                  currentHole: _selectedHole,
                  foursomeId:  widget.foursomeId,
                  onSelectExtraTeams: (extraSeg) =>
                      _showExtraTeamPicker(extraSeg, players),
                ),
                const SizedBox(height: 12),
              ] else if (rp.loadingSixes) ...[
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
    ]);
  }
}

// ===========================================================================
// Running total helper
// ===========================================================================

class _RunningTotal {
  final int grossVsPar;
  final int netVsPar;
  const _RunningTotal({required this.grossVsPar, required this.netVsPar});
}

String _signed(int v) => v > 0 ? '(+$v)' : '($v)';

// ===========================================================================
// Hole score card — hole header + player rows + inline score picker
// ===========================================================================

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final int              holeNumber;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, Map<int, int>> merged;   // all pending (db + ui)
  final Map<int, int>    scores;          // effective scores for this hole
  final int              hotSpotIdx;      // -1 = all done / read-only
  final int              par;
  final bool             hasPinkBall;
  final bool             pinkBallLost;
  final void Function(Membership, int) onScoreSelected; // inline picker
  final void Function(Membership)      onEditTap;       // modal for editing
  final void Function(bool)            onPinkBallLostChanged;

  const _HoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.merged,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.hasPinkBall,
    required this.pinkBallLost,
    required this.onScoreSelected,
    required this.onEditTap,
    required this.onPinkBallLostChanged,
  });

  _RunningTotal _running(int playerId) {
    int gross = 0, parSum = 0, net = 0;
    for (final h in scorecard.holes) {
      final pendingGross = merged[h.holeNumber]?[playerId];
      final saved        = h.scoreFor(playerId);
      final grossScore   = pendingGross ?? saved?.grossScore;
      if (grossScore == null) continue;
      gross  += grossScore;
      parSum += h.par;
      final netScore = (pendingGross == null) ? saved?.netScore : null;
      if (netScore != null) {
        net += netScore;
      } else {
        net += grossScore - (saved?.handicapStrokes ?? 0);
      }
    }
    return _RunningTotal(grossVsPar: gross - parSum, netVsPar: net - parSum);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ── Hole header ──
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Column(children: [
            Text(
              'Hole $holeNumber',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              holeData != null
                  ? 'Par ${holeData!.par}  |  '
                    '${holeData!.yards != null ? "${holeData!.yards} yds.  |  " : ""}'
                    'SI: ${holeData!.strokeIndex}'
                  : '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ]),
        ),

        // ── Player rows + inline picker ──
        ...players.asMap().entries.expand((entry) {
          final idx     = entry.key;
          final m       = entry.value;
          final rt      = _running(m.player.id);
          final gross   = scores[m.player.id];
          final isHot   = idx == hotSpotIdx;
          final hasScore = gross != null;

          return [
            _PlayerScoreRow(
              position:  idx + 1,
              member:    m,
              running:   rt,
              gross:     gross,
              isHot:     isHot,
              // Tapping a scored non-hot row lets the user edit it.
              onTap: hasScore && !isHot ? () => onEditTap(m) : null,
            ),
            // Inline score picker — auto-appears below the hot-spot row.
            if (isHot)
              _InlineScorePicker(
                par: par,
                // Per-player handicap strokes on this hole — drives the
                // net-centred coloring and shape decorations.
                strokes: holeData?.scoreFor(m.player.id)
                        ?.handicapStrokes ?? 0,
                currentScore: gross,
                onScoreSelected: (score) => onScoreSelected(m, score),
              ),
          ];
        }).toList(),

        // ── Pink ball toggle ──
        if (hasPinkBall) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              Checkbox(
                value: pinkBallLost,
                onChanged: (v) => onPinkBallLostChanged(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
              const Text('🔴 Pink ball lost on this hole'),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// One player row inside the hole card
// ---------------------------------------------------------------------------

class _PlayerScoreRow extends StatelessWidget {
  final int          position;
  final Membership   member;
  final _RunningTotal running;
  final int?         gross;     // null = not yet entered
  final bool         isHot;     // shaded "you're up" indicator
  final VoidCallback? onTap;

  const _PlayerScoreRow({
    required this.position,
    required this.member,
    required this.running,
    required this.gross,
    required this.isHot,
    this.onTap,
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
        // Position + name
        Expanded(
          child: Row(children: [
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
          ]),
        ),

        // Running totals: (+2)G (+1)N — Flexible so long names don't overflow
        Flexible(
          flex: 0,
          child: Text(
            '${_signed(running.grossVsPar)}G ${_signed(running.netVsPar)}N',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.secondary),
          ),
        ),
        const SizedBox(width: 8),

        // Score box
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
            alignment: Alignment.center,
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
                    : null,
          ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Inline score picker — appears below the hot-spot player row automatically
// ===========================================================================

class _InlineScorePicker extends StatefulWidget {
  final int  par;
  final int  strokes;       // handicap strokes this player gets on this hole
  final int? currentScore;
  final void Function(int) onScoreSelected; // -1 = clear

  const _InlineScorePicker({
    required this.par,
    required this.strokes,
    required this.currentScore,
    required this.onScoreSelected,
  });

  @override
  State<_InlineScorePicker> createState() => _InlineScorePickerState();
}

class _InlineScorePickerState extends State<_InlineScorePicker> {
  static const double _itemWidth  = 52.0;
  static const double _itemMargin = 5.0;
  static const double _itemTotal  = _itemWidth + _itemMargin * 2;

  late final ScrollController _ctrl;

  @override
  void initState() {
    super.initState();
    // Scroll so that (netPar-2) is at the left edge — centring the slider
    // on the player's net par rather than gross par.
    final netPar      = widget.par + widget.strokes;
    final startIdx    = (netPar - 3).clamp(0, 11); // 0-based index in [1..12]
    final initOffset  = (startIdx * _itemTotal).clamp(0.0, double.infinity);
    _ctrl = ScrollController(initialScrollOffset: initOffset);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final scores = List.generate(12, (i) => i + 1); // 1 … 12

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
        itemCount:       scores.length + (widget.currentScore != null ? 1 : 0),
        itemBuilder: (_, i) {
          // Last item = clear button (only when a score is selected)
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
                  child: Text(
                    'Clear',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            );
          }

          final s   = scores[i];
          final sel = s == widget.currentScore;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
            child: NetScoreButton(
              score: s,
              par: widget.par,
              strokes: widget.strokes,
              selected: sel,
              width: _itemWidth,
              height: 48,
              onTap: () => widget.onScoreSelected(s),
            ),
          );
        },
      ),
    );
  }
}

// ===========================================================================
// Modal score-picker sheet — used for editing already-entered scores
// ===========================================================================

class _ScorePickerSheet extends StatelessWidget {
  final String playerName;
  final int    par;
  final int    holeNumber;
  final int    strokes;     // handicap strokes this player gets on this hole
  final int?   current;

  const _ScorePickerSheet({
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
          // Handle
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),

          // Title
          Text(
            playerName,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          Text(
            strokes > 0
                ? 'Hole $holeNumber  •  Par $par  •  Net par $netPar'
                : 'Hole $holeNumber  •  Par $par',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // Horizontally scrollable score buttons — net-centred.
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
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: NetScoreButton(
                    score: s,
                    par: par,
                    strokes: strokes,
                    selected: sel,
                    width: 46,
                    height: 52,
                    onTap: () => Navigator.of(context).pop(s),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 12),

          // Clear / cancel
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
// Match grid
// ===========================================================================

class _MatchGrid extends StatelessWidget {
  final SixesSummary     summary;
  final List<Membership> members;
  final int              currentHole;
  final int              foursomeId;
  /// Called when the user taps "Select Players" on the extra match card.
  final void Function(SixesSegment)? onSelectExtraTeams;

  const _MatchGrid({
    required this.summary,
    required this.members,
    required this.currentHole,
    required this.foursomeId,
    this.onSelectExtraTeams,
  });

  int _position(String name) {
    final idx = members.indexWhere((m) => m.player.name == name);
    return idx >= 0 ? idx + 1 : 0;
  }

  String _teamLabel(SixesTeamInfo team) {
    if (!team.hasPlayers) return '??/??\n(?/?)';
    final abbr = team.players.map(_initials).join('/');
    final pos  = team.players
        .map((n) => _position(n))
        .map((p) => p > 0 ? '$p' : '?')
        .join('/');
    return '$abbr\n($pos)';
  }

  @override
  Widget build(BuildContext context) {
    final allSegs = summary.segments;
    if (allSegs.isEmpty) return const SizedBox.shrink();

    // Progressive reveal: Match N+1 appears only once Match N is finished.
    // Extra match is always shown once it exists (the card itself handles
    // the "coming up" vs "Select Players" state based on currentHole).
    final standardSegs = allSegs.where((s) => !s.isExtra).toList();
    final extraSegs    = allSegs.where((s) => s.isExtra).toList();

    final visible = <SixesSegment>[];
    for (final seg in standardSegs) {
      visible.add(seg);
      final done = seg.status == 'complete' || seg.status == 'halved';
      if (!done) break; // hide subsequent standard matches until this one ends
    }
    visible.addAll(extraSegs);

    // Identify P1 reliably: they are the ONLY player who appears in team1
    // of every standard segment (setup always puts P1 in team1_player_ids).
    //   Match 1 team1 = {P1, P2}
    //   Match 2 team1 = {P1, P3 or P4}
    //   Intersection  = {P1}
    // This is robust against Django's M2M return order (which is by player ID,
    // not insertion order — so members[0] would wrongly be P2 if P2's DB id
    // is lower than P1's).
    String p1Name = '';
    if (standardSegs.length >= 2) {
      var intersection = standardSegs[0].team1.players.toSet();
      for (final s in standardSegs.skip(1)) {
        intersection = intersection.intersection(s.team1.players.toSet());
      }
      if (intersection.isNotEmpty) p1Name = intersection.first;
    }
    // Fallback when <2 standard segments are visible (shouldn't happen).
    if (p1Name.isEmpty && members.isNotEmpty) {
      p1Name = members[0].player.name;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: visible.map((seg) {
          final matchNum = allSegs.indexOf(seg) + 1;

          // If P1 is in team2, swap so their team always renders on top.
          final p1InTeam2 = seg.team2.players.contains(p1Name);
          final topTeam    = p1InTeam2 ? seg.team2 : seg.team1;
          final bottomTeam = p1InTeam2 ? seg.team1 : seg.team2;

          return _SegmentCard(
            matchNumber:       matchNum,
            segment:           seg,
            team1Label:        _teamLabel(topTeam),
            team2Label:        _teamLabel(bottomTeam),
            teamsSwapped:      p1InTeam2,
            currentHole:       currentHole,
            foursomeId:        foursomeId,
            onSelectExtraTeams: seg.isExtra
                ? () => onSelectExtraTeams?.call(seg)
                : null,
          );
        }).toList(),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  final int           matchNumber;
  final SixesSegment  segment;
  final String        team1Label;   // always P1's team (top row)
  final String        team2Label;   // always P1's opponents (bottom row)
  /// True when the display order is reversed relative to Django team_number:
  /// team1Label holds Django team2's data, so margin signs are flipped.
  final bool          teamsSwapped;
  final int           currentHole;
  final int           foursomeId;
  /// Non-null only for the extra match card; tapping "Tap to pick teams" invokes it.
  final VoidCallback? onSelectExtraTeams;

  const _SegmentCard({
    required this.matchNumber,
    required this.segment,
    required this.team1Label,
    required this.team2Label,
    this.teamsSwapped = false,
    required this.currentHole,
    required this.foursomeId,
    this.onSelectExtraTeams,
  });

  Color _statusColor(BuildContext ctx) {
    switch (segment.status) {
      case 'complete':    return Colors.green.shade700;
      case 'halved':      return Colors.blue.shade700;
      case 'in_progress': return Theme.of(ctx).colorScheme.primary;
      default:            return Theme.of(ctx).colorScheme.onSurfaceVariant;
    }
  }

  /// Human-readable status, never blank.
  /// • '—' (no holes played yet) → 'Pending'
  /// • 'All Square thru N'      → 'AS thru N'
  String _statusLabel() {
    final raw = segment.statusDisplay;
    if (raw == '—') return 'Pending';
    return raw.replaceAll('All Square', 'AS');
  }

  @override
  Widget build(BuildContext context) {
    final theme        = Theme.of(context);
    final noTeams      = !segment.team1.hasPlayers || !segment.team2.hasPlayers;
    final statusTx     = _statusLabel();
    final statusColor  = _statusColor(context);
    // lastMargin is from Django's perspective: +N means team_number=1 leads.
    // If we swapped labels, flip the sign so the bold follows the right row.
    final rawMargin    = segment.holes.isNotEmpty ? segment.holes.last.margin : 0;
    final lastMargin   = teamsSwapped ? -rawMargin : rawMargin;
    final team1Leading = lastMargin > 0;
    final team2Leading = lastMargin < 0;

    return Card(
      margin: const EdgeInsets.only(right: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Container(
        width: 120,
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Match $matchNumber',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary),
            ),
            if (segment.isExtra)
              Text('(extra)',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.tertiary)),
            const SizedBox(height: 6),

            if (noTeams) ...[
              Text('??/?? (?/?)\nv.\n??/?? (?/?)',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              if (segment.isExtra && currentHole < segment.startHole)
                // Not there yet — show when the extra match begins.
                Text(
                  'Starts hole\n${segment.startHole}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.tertiary,
                    fontWeight: FontWeight.bold,
                  ),
                )
              else
                // Ready: let user pick teams via the bottom sheet.
                GestureDetector(
                  onTap: onSelectExtraTeams,
                  child: Text(
                    'Tap to pick\nteams',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colorScheme.error,
                    ),
                  ),
                ),
            ] else ...[
              Text(team1Label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight:
                        team1Leading ? FontWeight.bold : FontWeight.normal,
                  )),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('v.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              Text(team2Label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight:
                        team2Leading ? FontWeight.bold : FontWeight.normal,
                  )),
              const SizedBox(height: 8),
              Text(
                statusTx,
                style: theme.textTheme.labelMedium?.copyWith(
                    color: statusColor, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text('Holes ${segment.startHole}–${segment.endHole}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Extra match team picker — bottom sheet shown when user taps "Tap to pick teams"
// ===========================================================================

class _ExtraTeamPickerSheet extends StatefulWidget {
  final List<Membership> members; // all 4 players

  const _ExtraTeamPickerSheet({required this.members});

  @override
  State<_ExtraTeamPickerSheet> createState() => _ExtraTeamPickerSheetState();
}

class _ExtraTeamPickerSheetState extends State<_ExtraTeamPickerSheet> {
  /// Player IDs assigned to Team A.  Team B gets the remaining two.
  final Set<int> _teamAIds = {};

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final teamBIds = widget.members
        .where((m) => !_teamAIds.contains(m.player.id))
        .map((m) => m.player.id)
        .toList();
    final canConfirm = _teamAIds.length == 2;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),

            Text(
              'Extra Match Teams',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap two players to form Team A — the other two become Team B.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // Player tiles
            ...widget.members.map((m) {
              final inA    = _teamAIds.contains(m.player.id);
              final inB    = !inA && canConfirm;
              final color  = inA
                  ? theme.colorScheme.primary
                  : inB
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.surfaceContainerHighest;
              final label  = inA ? 'Team A' : (inB ? 'Team B' : '—');

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: inA || inB ? color : theme.colorScheme.outlineVariant),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color,
                    child: Text(
                      _initials(m.player.name),
                      style: TextStyle(
                        color: inA || inB ? Colors.white : theme.colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(m.player.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: inA || inB ? color : theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onTap: () {
                    setState(() {
                      if (inA) {
                        _teamAIds.remove(m.player.id);
                      } else if (_teamAIds.length < 2) {
                        _teamAIds.add(m.player.id);
                      }
                      // If team A is full (2 players), tapping a team-B player
                      // has no effect — they must deselect a team-A player first.
                    });
                  },
                ),
              );
            }),

            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: canConfirm
                    ? () => Navigator.of(context).pop([
                          _teamAIds.toList(),
                          teamBIds,
                        ])
                    : null,
                child: const Text(
                  'Confirm Teams',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Sync & error banners
// ===========================================================================

class _SyncBanner extends StatelessWidget {
  final SyncService sync;
  const _SyncBanner({required this.sync});

  @override
  Widget build(BuildContext context) {
    if (!sync.hasPending && sync.state == SyncState.idle) {
      return const SizedBox.shrink();
    }
    final bool syncing = sync.state == SyncState.syncing;
    return Container(
      width: double.infinity,
      color: syncing ? Colors.blue.shade700 : Colors.orange.shade700,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Icon(syncing ? Icons.sync : Icons.cloud_upload_outlined,
            size: 16, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            syncing
                ? 'Syncing ${sync.pendingCount} score(s)…'
                : '${sync.pendingCount} score(s) waiting to sync — tap ↑ to retry',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ]),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String   message;
  final VoidCallback onDismiss;
  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 16, color: Colors.orange),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: onDismiss,
        ),
      ]),
    );
  }
}
