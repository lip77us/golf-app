/// screens/skins_screen.dart
///
/// Score-entry and live-standings screen for the Skins casual game.
/// Layout mirrors points_531_screen.dart exactly:
///   • AppBar: "Skins" title + Scorecard / Leaderboard shortcuts + sync badge.
///   • Top card: Hole N header (Par/Yds/SI per tee), one row per player
///     showing running gross/net vs par, handicap chip, score box with stroke
///     dots.  Hot-spot player gets the same inline picker as 5-3-1.
///     When allow_junk=true, each row also shows junk dots (●) next to the
///     score box — tap + / − to adjust.
///   • Hole outcome strip: winner / carry → / dead ✗ once all scored.
///   • 18-hole grid: compact skin outcomes per hole.
///   • Bottom nav: ← Hole N-1 | Hole N+1 → (Done on hole 18).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';

// ---------------------------------------------------------------------------
// Handicap helpers — identical to points_531_screen.dart
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
  return full + (strokeIndex <= rem ? 1 : 0);
}

String _signed(int v) => v > 0 ? '(+$v)' : '($v)';

// Running gross + net vs par for a player through holes already scored.
class _RunningTotal {
  final int grossVsPar;
  final int netVsPar;
  const _RunningTotal({required this.grossVsPar, required this.netVsPar});
}

// ---------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------

class SkinsScreen extends StatefulWidget {
  final int foursomeId;
  const SkinsScreen({super.key, required this.foursomeId});

  @override
  State<SkinsScreen> createState() => _SkinsScreenState();
}

class _SkinsScreenState extends State<SkinsScreen> {
  /// Unsubmitted score edits: hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  /// Unsubmitted junk edits: hole → playerId → count.
  final Map<int, Map<int, int>> _pendingJunk = {};

  int  _selectedHole   = 1;
  bool _prevHadPending = false;
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
      rp.loadSkins(widget.foursomeId);
    });
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

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

    // Longest-tee-first sort using hole-1 yardage.
    final firstHole = sc.holeData(1);
    int yardageFor(int pid) => firstHole?.scoreFor(pid)?.yards ?? 0;
    members.sort((a, b) => yardageFor(b.player.id).compareTo(yardageFor(a.player.id)));
    return members;
  }

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    for (int h = 1; h <= 18; h++) {
      final hd      = sc.holeData(h);
      if (hd == null) continue;
      final realIds = _realPlayers(sc, rp.round).map((m) => m.player.id).toSet();
      final allOk   = hd.scores
          .where((s) => realIds.contains(s.playerId))
          .every((s) => s.grossScore != null);
      if (!allOk && !rp.localPendingByHole.containsKey(h)) {
        setState(() => _selectedHole = h);
        return;
      }
    }
    // All 18 holes are complete — land on the last hole instead of hole 1.
    setState(() => _selectedHole = 18);
  }

  Map<int, int> _effectiveScores(Scorecard sc, int hole) {
    final saved = <int, int>{};
    final hd    = sc.holeData(hole);
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
        _pending.putIfAbsent(hole, () => {})[player.player.id] = score;
      }
    });
  }

  void _adjustJunk(int playerId, int hole, int delta) {
    setState(() {
      final current = (_pendingJunk[hole] ?? {})[playerId] ?? 0;
      final next    = (current + delta).clamp(0, 20);
      _pendingJunk.putIfAbsent(hole, () => {})[playerId] = next;
    });
  }

  /// Open the edit-score modal for an already-scored player (non-hot row tap).
  Future<void> _editScore(
    BuildContext ctx,
    Membership player,
    int par,
    int hole,
    List<Membership> players,
  ) async {
    final rp      = context.read<RoundProvider>();
    final sc      = rp.scorecard;
    final summary = rp.skinsSummary;
    final current = (_pending[hole] ?? {})[player.player.id]
        ?? sc?.holeData(hole)?.scoreFor(player.player.id)?.grossScore;

    final mode       = summary?.handicapMode ?? 'net';
    final netPercent = summary?.netPercent   ?? 100;
    final lowPlaying = mode == 'strokes_off' && players.isNotEmpty
        ? players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b)
        : null;
    final effective = _effectiveMatchHandicap(
      mode:                  mode,
      netPercent:            netPercent,
      playingHandicap:       player.playingHandicap,
      lowestPlayingHandicap: lowPlaying,
    );
    final si      = sc?.holeData(hole)?.strokeIndex ?? 18;
    final strokes = _strokesOnHole(effective, si);

    final score = await showModalBottomSheet<int>(
      context: ctx,
      useRootNavigator: true,
      builder: (_) => _SkinsScorePickerSheet(
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
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
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
      await _saveJunkIfNeeded(ctx);
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
    await _saveJunkIfNeeded(ctx);
    if (!mounted) return;
    rp.loadSkins(widget.foursomeId);
    _advance();
  }

  Future<void> _saveJunkIfNeeded(BuildContext ctx) async {
    final summary = context.read<RoundProvider>().skinsSummary;
    if (summary == null || !summary.allowJunk) return;

    final junkEdits = _pendingJunk[_selectedHole];
    if (junkEdits == null || junkEdits.isEmpty) return;

    final entries = junkEdits.entries
        .map((e) => {'player_id': e.key, 'junk_count': e.value})
        .toList();

    try {
      final client = context.read<AuthProvider>().client;
      await client.postSkinsJunk(
        widget.foursomeId,
        holeNumber:  _selectedHole,
        junkEntries: entries,
      );
      setState(() { _pendingJunk.remove(_selectedHole); });
    } catch (_) {
      // Non-fatal — junk can be re-entered.
    }
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
    await _saveJunkIfNeeded(ctx);
    if (!mounted) return;

    await sync.waitUntilIdle();
    if (!mounted) return;
    rp.loadSkins(widget.foursomeId);
    if (roundId != null) {
      Navigator.of(ctx).pushNamed('/leaderboard', arguments: roundId);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp         = context.watch<RoundProvider>();
    final sync       = context.watch<SyncService>();
    final sc         = rp.scorecard;
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

    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadSkins(widget.foursomeId);
      });
    }
    _prevHadPending = nowHasPending;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Skins'),
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

  Widget _buildBottomNav(BuildContext ctx, RoundProvider rp, Scorecard sc) {
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
            rp.loadSkins(widget.foursomeId);
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
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;
    final summary  = rp.skinsSummary;

    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SkinsHoleScoreCard(
                holeData:        holeData,
                holeNumber:      _selectedHole,
                players:         players,
                scorecard:       sc,
                merged:          merged,
                scores:          scores,
                hotSpotIdx:      hotSpot,
                par:             par,
                summary:         summary,
                pendingJunk:     _pendingJunk[_selectedHole] ?? {},
                onScoreSelected: (m, score) =>
                    _selectScore(m, score, _selectedHole),
                onEditTap: (m) =>
                    _editScore(ctx, m, par, _selectedHole, players),
                onJunkChanged: (pid, delta) =>
                    _adjustJunk(pid, _selectedHole, delta),
              ),

              const SizedBox(height: 12),

              if (summary != null) ...[
                _SkinsSummaryGrid(
                  summary:     summary,
                  players:     players,
                  currentHole: _selectedHole,
                  onTapHole:   (h) => setState(() => _selectedHole = h),
                ),
                const SizedBox(height: 12),
              ] else if (rp.loadingSkins) ...[
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
// Active-hole card — mirrors _P531HoleScoreCard exactly
// ===========================================================================

class _SkinsHoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final int              holeNumber;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, Map<int, int>> merged;
  final Map<int, int>    scores;
  final int              hotSpotIdx;
  final int              par;
  final SkinsSummary?    summary;
  final Map<int, int>    pendingJunk; // playerId → count (local unsaved)
  final void Function(Membership, int)       onScoreSelected;
  final void Function(Membership)            onEditTap;
  final void Function(int playerId, int delta) onJunkChanged;

  const _SkinsHoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.merged,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.summary,
    required this.pendingJunk,
    required this.onScoreSelected,
    required this.onEditTap,
    required this.onJunkChanged,
  });

  String get _mode       => summary?.handicapMode ?? 'net';
  int    get _netPercent => summary?.netPercent   ?? 100;

  int? get _lowPlayingHandicap {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players
        .map((m) => m.playingHandicap)
        .reduce((a, b) => a < b ? a : b);
  }

  int _matchHcapFor(Membership m) => _effectiveMatchHandicap(
        mode:                  _mode,
        netPercent:            _netPercent,
        playingHandicap:       m.playingHandicap,
        lowestPlayingHandicap: _lowPlayingHandicap,
      );

  /// Per-player strokes on a hole — mirrors _P531HoleScoreCard._strokesForHole.
  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null) return 0;
    if (_mode == 'gross') return 0;

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

  /// Running gross + net vs par through all scored holes.
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

  /// Hole outcome for the selected hole (from server summary).
  SkinsHole? _holeOutcome() => summary?.holes
      .where((h) => h.hole == holeNumber)
      .firstOrNull;

  /// Build "Par X | Y yds. | SI: Z" — copied verbatim from _P531HoleScoreCard.
  static String _buildHoleHeaderText(
    ScorecardHole hole,
    List<Membership> players,
  ) {
    final seenKeys = <int>{};
    final parVals  = <int>[];
    final yardVals = <int?>[];
    final siVals   = <int>[];
    for (final m in players) {
      final key = m.tee?.id ?? -m.player.id;
      if (!seenKeys.add(key)) continue;
      final e = hole.scoreFor(m.player.id);
      parVals.add(e?.par ?? hole.par);
      yardVals.add(e?.yards ?? hole.yards);
      siVals.add(e?.strokeIndex ?? hole.strokeIndex);
    }

    String collapse<T>(List<T> values, String Function(T) fmt) {
      if (values.isEmpty) return '';
      final seen   = <T>{};
      final unique = values.where((v) => seen.add(v)).toList();
      if (unique.length == 1) return fmt(unique.first);
      return unique.map(fmt).join('/');
    }

    final parStr  = 'Par ${collapse<int>(parVals, (v) => '$v')}';
    final siStr   = 'SI: ${collapse<int>(siVals, (v) => '$v')}';
    final anyYards = yardVals.any((y) => y != null);
    final yardStr  = anyYards
        ? '${collapse<int?>(yardVals, (v) => v == null ? '—' : '$v')} yds.'
        : null;

    return yardStr == null ? '$parStr  |  $siStr' : '$parStr  |  $yardStr  |  $siStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final holeOutcome = _holeOutcome();
    final allowJunk  = summary?.allowJunk ?? false;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Hole header (gray bar) ──
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
                return Text(
                  _buildHoleHeaderText(holeData!, players),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                );
              }),
            ]),
          ),

          // ── Player rows + inline picker ──
          ...players.asMap().entries.expand((entry) {
            final idx          = entry.key;
            final m            = entry.value;
            final pid          = m.player.id;
            final rt           = _running(pid);
            final gross        = scores[pid];
            final isHot        = idx == hotSpotIdx;
            final hasScore     = gross != null;
            final matchStrokes = _strokesForHole(m, holeData);

            // Handicap chip label: "-N•" (dots = strokes on this hole).
            // Only show the chip when the player actually has strokes to give —
            // a "-0" label is meaningless and clutters the row.
            String? hcapLabel;
            if (_mode == 'net' || _mode == 'strokes_off') {
              final eff = _matchHcapFor(m);
              if (eff > 0) {
                final dots = matchStrokes > 0 ? ' ${'•' * matchStrokes}' : '';
                hcapLabel = '-$eff$dots';
              }
            }

            // Running skins total from server summary.
            final totalSkins = summary?.players
                    .where((p) => p.playerId == pid)
                    .firstOrNull
                    ?.totalSkins ?? 0;

            // Did this player win the currently-selected hole?
            final isHoleWinner = holeOutcome?.winnerId == pid;

            // Junk count for this player on this hole.
            final junkCount = pendingJunk[pid]
                ?? holeOutcome?.junk
                    .where((j) => j.playerId == pid)
                    .firstOrNull
                    ?.count
                ?? 0;

            return [
              _SkinsPlayerRow(
                position:          idx + 1,
                member:            m,
                running:           rt,
                gross:             gross,
                isHot:             isHot,
                matchHcapLabel:    hcapLabel,
                strokesOnThisHole: matchStrokes,
                showNetRunningTotal: _mode == 'net',
                totalSkins:        totalSkins,
                isHoleWinner:      isHoleWinner,
                allowJunk:         allowJunk,
                junkCount:         junkCount,
                onJunkAdd:    () => onJunkChanged(pid,  1),
                onJunkRemove: () => onJunkChanged(pid, -1),
                onTap: (hasScore && !isHot) ? () => onEditTap(m) : null,
              ),
              if (isHot)
                _InlinePicker(
                  par:             par,
                  strokes:         matchStrokes,
                  currentScore:    gross,
                  onScoreSelected: (score) => onScoreSelected(m, score),
                ),
            ];
          }).toList(),

          // ── Hole outcome strip ──
          if (holeOutcome != null) ...[
            Divider(
              height: 1,
              color: theme.colorScheme.outlineVariant,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: _HoleOutcomeStrip(outcome: holeOutcome),
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// Player row — mirrors _P531PlayerRow with skins-specific right column
// ===========================================================================

class _SkinsPlayerRow extends StatelessWidget {
  final int          position;
  final Membership   member;
  final _RunningTotal running;
  final int?         gross;
  final bool         isHot;
  final String?      matchHcapLabel;
  final VoidCallback? onTap;
  final int          strokesOnThisHole;
  final bool         showNetRunningTotal;

  /// Cumulative skins won by this player across the round.
  final int   totalSkins;

  /// True when this player won the currently-displayed hole.
  final bool  isHoleWinner;

  /// Whether to show the junk dot indicator + +/− controls.
  final bool        allowJunk;
  final int         junkCount;
  final VoidCallback onJunkAdd;
  final VoidCallback onJunkRemove;

  const _SkinsPlayerRow({
    required this.position,
    required this.member,
    required this.running,
    required this.gross,
    required this.isHot,
    this.matchHcapLabel,
    this.onTap,
    this.strokesOnThisHole = 0,
    this.showNetRunningTotal = true,
    required this.totalSkins,
    required this.isHoleWinner,
    required this.allowJunk,
    required this.junkCount,
    required this.onJunkAdd,
    required this.onJunkRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        // ── Name + handicap chip ──
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
            if (matchHcapLabel != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
        ),

        // ── Running totals + skins pills ──
        Flexible(
          flex: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                showNetRunningTotal
                    ? '${_signed(running.grossVsPar)}G ${_signed(running.netVsPar)}N'
                    : '${_signed(running.grossVsPar)}G',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.secondary),
              ),
              const SizedBox(height: 2),
              // Trophy icon when this player won the active hole.
              // Using Icon instead of an emoji Text to avoid font-fallback
              // rendering issues (emoji shows as '?' on some devices).
              if (isHoleWinner)
                Icon(Icons.emoji_events,
                    size: 16, color: Colors.amber.shade700),
            ],
          ),
        ),
        const SizedBox(width: 8),

        // ── Score box (with stroke dots) + junk dots ──
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Score box — identical to _P531PlayerRow.
            GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 40,
                height: 36,
                decoration: BoxDecoration(
                  color: isHot
                      ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                      : Colors.transparent,
                  border: boxBorder,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Stack(children: [
                  Center(
                    child: gross != null
                        ? Text(
                            '$gross',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          )
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
                          (_) => Container(
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

            // Junk dot indicator + controls (when allow_junk).
            if (allowJunk) ...[
              const SizedBox(height: 4),
              _JunkDots(
                count:      junkCount,
                onAdd:      onJunkAdd,
                onRemove:   onJunkRemove,
              ),
            ],
          ],
        ),
      ]),
    );
  }
}

// ===========================================================================
// Junk dot indicator — shows filled circles for junk count + +/− buttons
// ===========================================================================

class _JunkDots extends StatelessWidget {
  final int          count;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _JunkDots({
    required this.count,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // When count is 0 show only the + button — no dash, no label.
    if (count == 0) {
      return GestureDetector(
        onTap: onAdd,
        child: Icon(Icons.add_circle_outline,
            size: 14, color: theme.colorScheme.onSurfaceVariant),
      );
    }

    // count > 0: show  −  N junk  +
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onRemove,
          child: Icon(Icons.remove_circle_outline,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 4),
        Text(
          '$count junk',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.tertiary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onAdd,
          child: Icon(Icons.add_circle_outline,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

// ===========================================================================
// Inline score picker — copied verbatim from points_531_screen.dart
// ===========================================================================

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
        final maxExtent = _ctrl.position.maxScrollExtent;
        _ctrl.jumpTo(target.clamp(0.0, maxExtent));
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

// ===========================================================================
// Modal edit-score sheet — copied from _P531ScorePickerSheet
// ===========================================================================

class _SkinsScorePickerSheet extends StatelessWidget {
  final String playerName;
  final int    par;
  final int    holeNumber;
  final int    strokes;
  final int?   current;

  const _SkinsScorePickerSheet({
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
            ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Hole outcome strip
// ===========================================================================

class _HoleOutcomeStrip extends StatelessWidget {
  final SkinsHole outcome;
  const _HoleOutcomeStrip({required this.outcome});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget content;
    if (outcome.winnerId != null) {
      final v = outcome.skinsValue;
      content = Row(children: [
        Icon(Icons.emoji_events, size: 16, color: Colors.amber.shade700),
        const SizedBox(width: 6),
        Text(
          '${outcome.winnerShort} wins $v skin${v == 1 ? '' : 's'}',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: Colors.amber.shade800,
          ),
        ),
      ]);
    } else if (outcome.isCarry) {
      content = Row(children: [
        Icon(Icons.arrow_forward, size: 16,
            color: theme.colorScheme.secondary),
        const SizedBox(width: 6),
        Text(
          'Carry → ${outcome.skinsValue} skin${outcome.skinsValue == 1 ? '' : 's'} at stake',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.secondary,
              fontWeight: FontWeight.w600),
        ),
      ]);
    } else {
      content = Row(children: [
        Icon(Icons.block, size: 16,
            color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text('Tied — skin voided',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
      ]);
    }

    if (outcome.junk.isNotEmpty) {
      final junkStr = outcome.junk
          .map((j) => '${j.shortName} ×${j.count}')
          .join(', ');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          content,
          const SizedBox(height: 4),
          Text('Junk: $junkStr',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                  fontWeight: FontWeight.w600)),
        ],
      );
    }

    return content;
  }
}

// ===========================================================================
// 18-hole summary grid
// ===========================================================================

class _SkinsSummaryGrid extends StatefulWidget {
  final SkinsSummary       summary;
  final List<Membership>   players;
  final int                currentHole;
  final void Function(int) onTapHole;

  const _SkinsSummaryGrid({
    required this.summary,
    required this.players,
    required this.currentHole,
    required this.onTapHole,
  });

  @override
  State<_SkinsSummaryGrid> createState() => _SkinsSummaryGridState();
}

class _SkinsSummaryGridState extends State<_SkinsSummaryGrid> {
  final ScrollController _scrollCtrl = ScrollController();

  // Each cell is 26px wide + 1px margin each side = 28px.
  // Name column = 44px, leading-total column = 36px.
  static const double _cellWidth  = 28.0;
  static const double _nameWidth  = 44.0;
  static const double _totalWidth = 36.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHole(widget.currentHole));
  }

  @override
  void didUpdateWidget(_SkinsSummaryGrid old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHole(widget.currentHole));
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToHole(int hole) {
    if (!_scrollCtrl.hasClients) return;
    // Position the current hole at 70% from the left (position 7 of ~10 visible).
    // target = left edge of hole-7's cell, so hole lands at the 7th slot.
    final target = (_nameWidth + _totalWidth + (hole - 7) * _cellWidth)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final holesByNum = {for (final h in widget.summary.holes) h.hole: h};
    final summary    = widget.summary;
    final players    = widget.players;
    final currentHole = widget.currentHole;
    final onTapHole   = widget.onTapHole;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Skins Scoring',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 8),
            SingleChildScrollView(
              controller: _scrollCtrl,
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row: hole numbers
                  Row(children: [
                    const SizedBox(width: 44),
                    // Leading totals header spacer
                    const SizedBox(width: 36),
                    ...List.generate(18, (i) {
                      final h         = i + 1;
                      final isCurrent = h == currentHole;
                      return GestureDetector(
                        onTap: () => onTapHole(h),
                        child: _GridCell(
                          text:      '$h',
                          bold:      isCurrent,
                          highlight: isCurrent,
                          small:     true,
                        ),
                      );
                    }),
                    // Trailing totals header spacer
                    const SizedBox(width: 36),
                  ]),

                  // Player rows
                  ...players.map((m) {
                    final pid   = m.player.id;
                    final total = summary.players
                            .where((p) => p.playerId == pid)
                            .firstOrNull
                            ?.totalSkins ?? 0;

                    Widget totalWidget = SizedBox(
                      width: 36,
                      child: Text(
                        '$total',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: total > 0 ? Colors.amber.shade800 : null,
                        ),
                      ),
                    );

                    return Row(children: [
                      SizedBox(
                        width: 44,
                        child: Text(m.player.displayShort,
                            style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                      ),
                      // Leading total
                      totalWidget,
                      ...List.generate(18, (i) {
                        final h          = i + 1;
                        final outcome    = holesByNum[h];
                        final isWinner   = outcome?.winnerId == pid;
                        final isCurrent  = h == currentHole;
                        String cellText  = '';
                        Color? cellColor;
                        if (outcome != null) {
                          if (isWinner) {
                            cellText  = '${outcome.skinsValue}';
                            cellColor = Colors.amber.shade200;
                          } else if (outcome.isCarry) {
                            cellText  = '→';
                            cellColor = theme.colorScheme.secondaryContainer;
                          } else if (!outcome.isCarry && outcome.winnerId == null) {
                            cellText = '✗';
                          }
                        }
                        // Saved junk count for this player on this hole.
                        final junk = outcome?.junk
                            .where((j) => j.playerId == pid)
                            .firstOrNull
                            ?.count ?? 0;
                        return GestureDetector(
                          onTap: () => onTapHole(h),
                          child: _GridCell(
                            text:      cellText,
                            bold:      isWinner,
                            highlight: isCurrent,
                            bgColor:   cellColor,
                            junkDots:  junk,
                          ),
                        );
                      }),
                      // Trailing total
                      totalWidget,
                    ]);
                  }),

                  // Pool legend + skin value
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      () {
                        final pool  = summary.pool;
                        final total = summary.totalSkins;
                        final poolStr = '\$${pool.toStringAsFixed(2)}';
                        if (total == 0) {
                          return 'Pool $poolStr  •  Skin value: $poolStr';
                        }
                        final value = pool / total;
                        return 'Pool $poolStr  •  ${total} skin${total == 1 ? '' : 's'} won  •  Skin value: \$${value.toStringAsFixed(2)}';
                      }(),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
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

// ---------------------------------------------------------------------------
// Grid cell helper
// ---------------------------------------------------------------------------

class _GridCell extends StatelessWidget {
  final String  text;
  final bool    bold;
  final bool    highlight;
  final Color?  bgColor;
  final bool    small;
  /// Junk skins to render as filled dots in the bottom-right corner.
  /// Shown up to 3 dots; for 4+ shows a small number instead.
  final int     junkDots;

  const _GridCell({
    required this.text,
    this.bold      = false,
    this.highlight = false,
    this.bgColor,
    this.small     = false,
    this.junkDots  = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 26, height: 26,
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primary.withOpacity(0.15)
            : bgColor,
        borderRadius: BorderRadius.circular(4),
        border: highlight
            ? Border.all(color: theme.colorScheme.primary, width: 1.5)
            : null,
      ),
      child: Stack(children: [
        Align(
          alignment: Alignment.center,
          child: Text(
            text,
            style: (small
                    ? theme.textTheme.labelSmall
                    : theme.textTheme.bodySmall)
                ?.copyWith(
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              color:      highlight ? theme.colorScheme.primary : null,
            ),
          ),
        ),
        // Junk dots — bottom-right corner; slightly bigger than stroke dots.
        if (junkDots > 0)
          Positioned(
            bottom: 1, right: 1,
            child: junkDots <= 3
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(junkDots, (_) => Container(
                      width: 5, height: 5,
                      margin: const EdgeInsets.only(left: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiary,
                        shape: BoxShape.circle,
                      ),
                    )),
                  )
                : Text(
                    '$junkDots',
                    style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
          ),
      ]),
    );
  }
}
