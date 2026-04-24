import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';

// ---------------------------------------------------------------------------
// Top-level helpers — identical to skins_screen.dart so we keep one source
// of truth per utility.
// ---------------------------------------------------------------------------

int _strokesOnHole(int effectiveHandicap, int strokeIndex) {
  if (effectiveHandicap <= 0) return 0;
  final full = effectiveHandicap ~/ 18;
  final rem  = effectiveHandicap %  18;
  return full + (strokeIndex <= rem ? 1 : 0);
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

class ScorecardScreen extends StatefulWidget {
  final int  foursomeId;
  /// When true the screen is a read-only viewer: no score pickers, no
  /// Save/Done button.  Navigation between holes still works.
  final bool readOnly;

  const ScorecardScreen({
    super.key,
    required this.foursomeId,
    this.readOnly = false,
  });

  @override
  State<ScorecardScreen> createState() => _ScorecardScreenState();
}

class _ScorecardScreenState extends State<ScorecardScreen> {
  // ── Hole selection ──────────────────────────────────────────────────────
  int  _selectedHole    = 1;
  bool _initialJumpDone = false;

  // ── Local (unsaved) score edits, hole → { playerId → gross } ───────────
  Map<int, Map<int, int>> _pending = {};

  // ── Helpers ─────────────────────────────────────────────────────────────

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
    });
  }

  List<Membership> _realPlayers(Scorecard sc, Round? round) {
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
    final sc      = rp.scorecard;
    if (sc == null) return;
    final players = _realPlayers(sc, rp.round);
    for (int h = 1; h <= 18; h++) {
      if (rp.localPendingByHole.containsKey(h)) continue;
      final hd = sc.holeData(h);
      if (hd == null ||
          !players.every((m) => hd.scoreFor(m.player.id)?.grossScore != null)) {
        setState(() => _selectedHole = h);
        return;
      }
    }
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

  bool _allScored(List<Membership> players, Map<int, int> scores) =>
      players.every((m) => scores.containsKey(m.player.id));

  int _hotSpotIdx(List<Membership> players, Map<int, int> scores) {
    for (int i = 0; i < players.length; i++) {
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
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

  /// Returns handicap strokes on a specific hole for a player.
  /// Prefers the server-calculated value; falls back to playing handicap.
  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null) return 0;
    final entry = h.scoreFor(m.player.id);
    if (entry != null) return entry.handicapStrokes;
    return _strokesOnHole(m.playingHandicap, h.strokeIndex);
  }

  _RunningTotal _running(int playerId, Scorecard sc) {
    final m = _realPlayers(sc, context.read<RoundProvider>().round)
        .where((x) => x.player.id == playerId)
        .firstOrNull;
    int gross = 0, parSum = 0, net = 0;
    for (final h in sc.holes) {
      final pendingGross = _pending[h.holeNumber]?[playerId]
          ?? context.read<RoundProvider>().localPendingByHole[h.holeNumber]?[playerId];
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

  Future<void> _editScore(
    BuildContext ctx,
    Membership player,
    int par,
    int hole,
    ScorecardHole? holeData,
  ) async {
    final current = (_pending[hole] ?? {})[player.player.id]
        ?? context.read<RoundProvider>().scorecard
            ?.holeData(hole)?.scoreFor(player.player.id)?.grossScore;
    final strokes = _strokesForHole(player, holeData);

    final score = await showModalBottomSheet<int>(
      context: ctx,
      useRootNavigator: true,
      builder: (_) => _ScorePickerSheet(
        playerName: player.player.name,
        par:        par,
        holeNumber: hole,
        strokes:    strokes,
        current:    current,
      ),
    );
    if (!mounted || score == null) return;
    setState(() {
      if (score == -1) {
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => {})[player.player.id] = score;
      }
    });
  }

  Future<void> _saveAndAdvance(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final edits = _pending[_selectedHole];
    if (edits == null || edits.isEmpty) {
      if (_selectedHole < 18) setState(() => _selectedHole++);
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
    setState(() {
      _pending.remove(_selectedHole);
      if (_selectedHole < 18) _selectedHole++;
    });
  }

  Future<void> _finishRound(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final rp   = context.read<RoundProvider>();
    final sync = context.read<SyncService>();

    // Save the current hole if it has unsaved edits
    final edits = _pending[_selectedHole];
    if (edits != null && edits.isNotEmpty) {
      final scores = edits.entries
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
        ));
        return;
      }
      setState(() => _pending.remove(_selectedHole));
    }

    await sync.waitUntilIdle();
    if (!mounted) return;

    final roundId = rp.round?.id;
    if (roundId != null) {
      Navigator.of(ctx).pushNamed('/leaderboard', arguments: roundId);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape) return _buildLandscapeScaffold(context, rp, sync);

    final sc         = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';

    // Auto-jump to first unscored hole on initial data arrival.
    if (!_initialJumpDone &&
        sc != null &&
        rp.activeFoursomeId == widget.foursomeId) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstUnplayed(context.read<RoundProvider>());
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Scorecard — Group ${sc?.groupNumber ?? ""}'),
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
          if (sc != null)
            IconButton(
              tooltip: 'Leaderboard',
              icon: const Icon(Icons.leaderboard_outlined),
              onPressed: rp.round == null
                  ? null
                  : () => Navigator.of(context)
                      .pushNamed('/leaderboard', arguments: rp.round!.id),
            ),
          if (sc != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => rp.loadScorecard(widget.foursomeId),
            ),
        ],
      ),
      body: Column(children: [
        _SyncBanner(sync: sync),
        Expanded(child: _buildPortraitBody(context, rp, sync, isComplete)),
      ]),
      bottomNavigationBar: (sc == null || rp.loadingScorecard)
          ? null
          : _buildBottomNav(context, rp, sc),
    );
  }

  Widget _buildPortraitBody(
    BuildContext ctx,
    RoundProvider rp,
    SyncService sync,
    bool isComplete,
  ) {
    if (rp.loadingScorecard) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.scorecard == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(rp.error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => rp.loadScorecard(widget.foursomeId),
            child: const Text('Retry'),
          ),
        ]),
      );
    }

    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final players  = _realPlayers(sc, rp.round);
    final scores   = _effectiveScores(sc, _selectedHole);
    // In read-only mode (or when the round is complete) never highlight a
    // "hot-spot" player — the inline picker is hidden entirely.
    final readOnly = widget.readOnly || isComplete;
    final hotSpot  = readOnly ? -1 : _hotSpotIdx(players, scores);
    final holeData = sc.holeData(_selectedHole);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (rp.error != null)
          _ErrorBanner(message: rp.error!, onDismiss: rp.clearError),

        // ── Hole strip ──────────────────────────────────────────────────
        _HoleStrip(
          scorecard:     sc,
          players:       players,
          pendingScores: {...rp.localPendingByHole, ..._pending},
          selectedHole:  _selectedHole,
          onTap:         (h) => setState(() => _selectedHole = h),
        ),
        const SizedBox(height: 12),

        // ── Hole score card (hole info + per-player entry) ────────────
        _HoleScoreCard(
          holeData:        holeData,
          holeNumber:      _selectedHole,
          players:         players,
          scorecard:       sc,
          scores:          scores,
          hotSpotIdx:      hotSpot,
          par:             holeData?.par ?? 4,
          strokesForHole:  (m) => _strokesForHole(m, holeData),
          running:         (pid) => _running(pid, sc),
          // Read-only: disable picker and edit sheet.
          onScoreSelected: readOnly ? null : (m, score) => _selectScore(m, score, _selectedHole),
          onEditTap:       readOnly ? null : (m) => _editScore(
              ctx, m, holeData?.par ?? 4, _selectedHole, holeData),
        ),
        const SizedBox(height: 80),
      ]),
    );
  }

  Widget _buildBottomNav(BuildContext ctx, RoundProvider rp, Scorecard sc) {
    final players    = _realPlayers(sc, rp.round);
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final readOnly   = widget.readOnly || isComplete;
    final par        = sc.holeData(_selectedHole)?.par ?? 4;

    final prevBtn = Expanded(
      child: OutlinedButton.icon(
        onPressed: _selectedHole > 1
            ? () => setState(() => _selectedHole--)
            : null,
        icon: const Icon(Icons.chevron_left, size: 20),
        label: Text('Hole ${_selectedHole - 1}'),
      ),
    );

    final nextBtn = Expanded(
      child: OutlinedButton.icon(
        onPressed: _selectedHole < 18
            ? () => setState(() => _selectedHole++)
            : null,
        icon: const Icon(Icons.chevron_right, size: 20),
        label: Text(_selectedHole < 18 ? 'Hole ${_selectedHole + 1}' : 'Hole 18'),
        iconAlignment: IconAlignment.end,
      ),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(children: [
          prevBtn,
          const SizedBox(width: 8),
          // Read-only: simple Next button, no Save/Done.
          if (readOnly)
            nextBtn
          else if (_selectedHole == 18)
            Expanded(
              child: FilledButton.icon(
                onPressed: rp.submitting
                    ? null
                    : () => _finishRound(ctx, players, par),
                icon: const Icon(Icons.emoji_events, size: 20),
                label: const Text('Done'),
              ),
            )
          else
            Expanded(
              child: FilledButton.icon(
                onPressed: (allDone && !rp.submitting)
                    ? () => _saveAndAdvance(ctx, players, par)
                    : null,
                icon: rp.submitting
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.chevron_right, size: 20),
                label: Text(rp.submitting ? 'Saving…' : 'Hole ${_selectedHole + 1}'),
                iconAlignment: IconAlignment.end,
              ),
            ),
        ]),
      ),
    );
  }

  // ── Landscape scaffold (full read-only grid) ──────────────────────────────

  Widget _buildLandscapeScaffold(
      BuildContext context, RoundProvider rp, SyncService sync) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: Text(
          'Scorecard — Group ${rp.scorecard?.groupNumber ?? ""}',
          style: const TextStyle(fontSize: 14),
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
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.cloud_upload_outlined, size: 20),
                  tooltip: sync.state == SyncState.syncing
                      ? 'Syncing…'
                      : 'Tap to sync ${sync.pendingCount} score(s)',
                  onPressed: sync.state == SyncState.syncing
                      ? null
                      : () => sync.recheck(),
                ),
              ),
            ),
          if (rp.scorecard != null)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => rp.loadScorecard(widget.foursomeId),
            ),
        ],
      ),
      body: Column(children: [
        _SyncBanner(sync: sync),
        if (rp.loadingScorecard)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (rp.scorecard case final sc?)
          Expanded(
            child: _LandscapeGrid(
              scorecard:     sc,
              players:       _realPlayers(sc, rp.round),
              pendingScores: rp.localPendingByHole,
              currentHole:   _selectedHole,
              totals:        sc.totals,
            ),
          ),
      ]),
    );
  }
}

// ===========================================================================
// Hole strip — scrollable row of all 18 holes; highlights current & scored
// ===========================================================================

class _HoleStrip extends StatelessWidget {
  final Scorecard  scorecard;
  final List<Membership> players;
  final Map<int, Map<int, int>> pendingScores;
  final int        selectedHole;
  final void Function(int) onTap;

  const _HoleStrip({
    required this.scorecard,
    required this.players,
    required this.pendingScores,
    required this.selectedHole,
    required this.onTap,
  });

  bool _holeComplete(int hole) {
    if (pendingScores.containsKey(hole)) return true;
    final hd = scorecard.holeData(hole);
    if (hd == null) return false;
    return players.every((m) => hd.scoreFor(m.player.id)?.grossScore != null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 18,
        itemBuilder: (_, i) {
          final hole    = i + 1;
          final isSel   = hole == selectedHole;
          final isDone  = _holeComplete(hole);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: GestureDetector(
              onTap: () => onTap(hole),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 32, height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSel
                      ? theme.colorScheme.primary
                      : isDone
                          ? theme.colorScheme.secondaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$hole',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: isSel
                        ? theme.colorScheme.onPrimary
                        : isDone
                            ? theme.colorScheme.onSecondaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ===========================================================================
// Hole score card — hole header + per-player rows with inline picker
// ===========================================================================

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?    holeData;
  final int               holeNumber;
  final List<Membership>  players;
  final Scorecard         scorecard;
  final Map<int, int>     scores;
  final int               hotSpotIdx;
  final int               par;
  final int Function(Membership)          strokesForHole;
  final _RunningTotal Function(int)       running;
  /// Null in read-only mode — tapping a player row does nothing.
  final void Function(Membership, int)?   onScoreSelected;
  /// Null in read-only mode — the edit-score sheet is never shown.
  final void Function(Membership)?        onEditTap;

  const _HoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.strokesForHole,
    required this.running,
    this.onScoreSelected,
    this.onEditTap,
  });

  static String _holeSubtitle(ScorecardHole? h, List<Membership> players) {
    if (h == null) return '';
    final parStr  = 'Par ${h.par}';
    final siStr   = 'SI: ${h.strokeIndex}';
    final yardStr = h.yards != null ? '  |  ${h.yards} yds.' : '';
    return '$parStr$yardStr  |  $siStr';
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Hole header ──
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
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
                _holeSubtitle(holeData, players),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ]),
          ),

          // ── Player rows ──
          ...players.asMap().entries.expand((entry) {
            final idx      = entry.key;
            final m        = entry.value;
            final pid      = m.player.id;
            final rt       = running(pid);
            final gross    = scores[pid];
            final isHot    = idx == hotSpotIdx;
            final hasScore = gross != null;
            final strokes  = strokesForHole(m);

            // Divider between players
            final divider = idx > 0
                ? const Divider(height: 1, indent: 0, endIndent: 0)
                : const SizedBox.shrink();

            // Player info row
            final playerRow = Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(children: [
                // Name + running total
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.player.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                      Text(
                        'Hcp ${m.playingHandicap}  •  '
                        'Gross ${_signed(rt.grossVsPar)}  '
                        'Net ${_signed(rt.netVsPar)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),

                // Score chip (when already scored)
                if (hasScore) ...[
                  GestureDetector(
                    // Tapping the chip opens the edit sheet; disabled read-only.
                    onTap: onEditTap != null ? () => onEditTap!(m) : null,
                    child: _ScoreChip(
                      gross:   gross!,
                      par:     par,
                      strokes: strokes,
                    ),
                  ),
                ] else if (!isHot) ...[
                  // Not hot, no score — subtle dash
                  Text('—',
                      style: TextStyle(
                          fontSize: 22,
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ]),
            );

            // Inline picker (hot spot only, disabled in read-only mode)
            final picker = isHot && !hasScore && onScoreSelected != null
                ? _InlineScorePicker(
                    par:             par,
                    strokes:         strokes,
                    currentScore:    null,
                    onScoreSelected: (s) => onScoreSelected!(m, s),
                  )
                : const SizedBox.shrink();

            return [divider, playerRow, picker];
          }),

          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ===========================================================================
// Score chip — coloured circle showing the gross score
// ===========================================================================

class _ScoreChip extends StatelessWidget {
  final int gross;
  final int par;
  final int strokes;

  const _ScoreChip({required this.gross, required this.par, required this.strokes});

  @override
  Widget build(BuildContext context) {
    final net  = gross - strokes;
    final diff = net - par;
    // Mirror the NetScoreButton fill colors exactly so the chip always
    // matches what the player tapped to enter the score.
    final Color bg;
    if (diff < 0)       bg = Colors.green.shade200;   // birdie or better
    else if (diff == 0) bg = Colors.grey.shade200;    // par (light bg for circle visibility)
    else                bg = Colors.red.shade200;     // bogey or worse

    return Container(
      width: 44, height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        '$gross',
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
      ),
    );
  }
}

// ===========================================================================
// Inline score picker — horizontal row of score buttons (hot player)
// ===========================================================================

class _InlineScorePicker extends StatefulWidget {
  final int    par;
  final int    strokes;
  final int?   currentScore;
  final void Function(int) onScoreSelected;

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
  late final ScrollController _ctrl;

  static const _itemWidth  = 46.0;
  static const _itemMargin = 3.0;

  @override
  void initState() {
    super.initState();
    // Scroll to roughly par position on open so common scores are visible.
    final offset = ((widget.par - 1) * (_itemWidth + _itemMargin * 2))
        .clamp(0.0, double.infinity);
    _ctrl = ScrollController(initialScrollOffset: offset);
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
      height: 66,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.12),
        border: Border(
          top: BorderSide(color: theme.colorScheme.primary.withOpacity(0.2)),
        ),
      ),
      child: ListView.builder(
        controller:      _ctrl,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        itemCount: scores.length +
            (widget.currentScore != null ? 1 : 0),
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
// Modal edit-score sheet (tap an already-scored player to edit)
// ===========================================================================

class _ScorePickerSheet extends StatelessWidget {
  final String playerName;
  final int    par;
  final int    holeNumber;
  final int    strokes;
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
// Sync status banner
// ===========================================================================

class _SyncBanner extends StatelessWidget {
  final SyncService sync;
  const _SyncBanner({required this.sync});

  @override
  Widget build(BuildContext context) {
    if (!sync.hasPending && sync.state == SyncState.idle) {
      return const SizedBox.shrink();
    }
    final Color  bg;
    final Color  fg;
    final IconData icon;
    final String message;

    if (sync.state == SyncState.syncing) {
      bg      = Colors.blue.shade700;
      fg      = Colors.white;
      icon    = Icons.sync;
      message = 'Syncing ${sync.pendingCount} score(s)…';
    } else {
      bg      = Colors.orange.shade700;
      fg      = Colors.white;
      icon    = Icons.cloud_upload_outlined;
      message = '${sync.pendingCount} score(s) waiting to sync — tap ↑ to retry';
    }

    return Container(
      width:   double.infinity,
      color:   bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Icon(icon, size: 16, color: fg),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: TextStyle(color: fg, fontSize: 13)),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Error banner
// ===========================================================================

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;
  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      color:   Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 16, color: Colors.orange),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
        IconButton(
          icon:        const Icon(Icons.close, size: 16),
          padding:     EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed:   onDismiss,
        ),
      ]),
    );
  }
}

// ===========================================================================
// Landscape grid — full 18-hole overview (rotate device to access)
// ===========================================================================

class _LandscapeGrid extends StatefulWidget {
  final Scorecard scorecard;
  final List<Membership> players;
  final Map<int, Map<int, int>> pendingScores;
  final int currentHole;
  final List<PlayerTotals> totals;

  const _LandscapeGrid({
    required this.scorecard,
    required this.players,
    required this.pendingScores,
    required this.currentHole,
    required this.totals,
  });

  @override
  State<_LandscapeGrid> createState() => _LandscapeGridState();
}

class _LandscapeGridState extends State<_LandscapeGrid> {
  final ScrollController _scroll = ScrollController();

  static const double _nameW    = 80.0;
  static const double _summaryW = 34.0;
  static const double _colW     = 40.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToHole(widget.currentHole));
  }

  @override
  void didUpdateWidget(_LandscapeGrid old) {
    super.didUpdateWidget(old);
    if (widget.currentHole != old.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToHole(widget.currentHole));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToHole(int hole) {
    if (!_scroll.hasClients) return;
    final double holeLeft;
    if (hole <= 9) {
      holeLeft = _nameW + (hole - 1) * _colW;
    } else {
      holeLeft = _nameW + 9 * _colW + _summaryW + (hole - 10) * _colW;
    }
    final viewport = _scroll.position.viewportDimension;
    double offset  = holeLeft - viewport / 2 + _colW / 2;
    offset = offset.clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(offset,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller:      _scroll,
      scrollDirection: Axis.horizontal,
      child: _buildTable(context),
    );
  }

  Widget _buildTable(BuildContext context) {
    final theme = Theme.of(context);
    const hdrH  = 22.0;
    const rowH  = 38.0;

    final colWidths = <int, TableColumnWidth>{
      0:  FixedColumnWidth(_nameW),
      10: FixedColumnWidth(_summaryW),
      20: FixedColumnWidth(_summaryW),
      21: FixedColumnWidth(_summaryW),
      22: FixedColumnWidth(_summaryW),
      23: FixedColumnWidth(_summaryW),
    };
    for (int i = 1;  i <= 9;  i++) colWidths[i] = FixedColumnWidth(_colW);
    for (int i = 11; i <= 19; i++) colWidths[i] = FixedColumnWidth(_colW);

    return Table(
      defaultColumnWidth: FixedColumnWidth(_colW),
      columnWidths: colWidths,
      border: TableBorder.all(
          color: theme.colorScheme.outlineVariant, width: 0.5),
      children: [
        _holeHeaderRow(theme, hdrH),
        _parRow(theme, hdrH),
        ..._playerRows(theme, rowH),
      ],
    );
  }

  TableRow _holeHeaderRow(ThemeData theme, double h) {
    Color? selBg(int hole) => hole == widget.currentHole
        ? theme.colorScheme.primaryContainer
        : null;
    final sumBg = theme.colorScheme.surfaceContainerLow;
    return TableRow(
      decoration:
          BoxDecoration(color: theme.colorScheme.surfaceContainerHighest),
      children: [
        _cell('Hole', height: h, bold: true),
        for (int hole = 1; hole <= 9; hole++)
          _cell('$hole', height: h, bold: true, bg: selBg(hole)),
        _cell('OUT',  height: h, bold: true, italic: true, bg: sumBg),
        for (int hole = 10; hole <= 18; hole++)
          _cell('$hole', height: h, bold: true, bg: selBg(hole)),
        _cell('IN',   height: h, bold: true, italic: true, bg: sumBg),
        _cell('TOT',  height: h, bold: true, italic: true, bg: sumBg),
        _cell('NET',  height: h, bold: true, italic: true, bg: sumBg),
        _cell('STBL', height: h, bold: true, italic: true, bg: sumBg),
      ],
    );
  }

  TableRow _parRow(ThemeData theme, double h) {
    int parOut = 0, parIn = 0;
    for (int hole = 1;  hole <= 9;  hole++) {
      parOut += widget.scorecard.holeData(hole)?.par ?? 0;
    }
    for (int hole = 10; hole <= 18; hole++) {
      parIn  += widget.scorecard.holeData(hole)?.par ?? 0;
    }
    return TableRow(
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow),
      children: [
        _cell('Par', height: h, italic: true),
        for (int hole = 1;  hole <= 9;  hole++)
          _cell('${widget.scorecard.holeData(hole)?.par ?? '-'}', height: h),
        _cell('$parOut', height: h, bold: true),
        for (int hole = 10; hole <= 18; hole++)
          _cell('${widget.scorecard.holeData(hole)?.par ?? '-'}', height: h),
        _cell('$parIn',            height: h, bold: true),
        _cell('${parOut + parIn}', height: h, bold: true),
        _cell('—', height: h),
        _cell('—', height: h),
      ],
    );
  }

  List<TableRow> _playerRows(ThemeData theme, double h) {
    return widget.players.map((m) {
      int outGross = 0, inGross = 0;
      int outNetSum = 0, inNetSum = 0;
      bool hasOutGross = false, hasInGross = false;
      bool hasOutNet   = true,  hasInNet   = true;

      for (int hole = 1; hole <= 9; hole++) {
        final gross = widget.pendingScores[hole]?[m.player.id]
            ?? widget.scorecard.holeData(hole)?.scoreFor(m.player.id)?.grossScore;
        if (gross != null) { outGross += gross; hasOutGross = true; }
        final net = widget.scorecard.holeData(hole)?.scoreFor(m.player.id)?.netScore;
        if (net == null) hasOutNet = false; else outNetSum += net;
      }
      for (int hole = 10; hole <= 18; hole++) {
        final gross = widget.pendingScores[hole]?[m.player.id]
            ?? widget.scorecard.holeData(hole)?.scoreFor(m.player.id)?.grossScore;
        if (gross != null) { inGross += gross; hasInGross = true; }
        final net = widget.scorecard.holeData(hole)?.scoreFor(m.player.id)?.netScore;
        if (net == null) hasInNet = false; else inNetSum += net;
      }

      final bool hasNet = hasOutNet && hasInNet;
      final int  netTot = outNetSum + inNetSum;
      final stbl = widget.totals
          .where((t) => t.playerId == m.player.id)
          .firstOrNull
          ?.totalStableford;

      return TableRow(children: [
        TableCell(
          child: Container(
            height: h,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.centerLeft,
            child: Column(
              mainAxisAlignment:  MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.player.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
                Text('Hcp ${m.playingHandicap}',
                    style: const TextStyle(fontSize: 9)),
              ],
            ),
          ),
        ),
        for (int hole = 1; hole <= 9; hole++) _scoreCell(hole, m, h),
        _summaryCell(hasOutGross ? '$outGross' : '—', h),
        for (int hole = 10; hole <= 18; hole++) _scoreCell(hole, m, h),
        _summaryCell(hasInGross ? '$inGross' : '—', h),
        _summaryCell(
            (hasOutGross || hasInGross) ? '${outGross + inGross}' : '—', h),
        _summaryCell(hasNet ? '$netTot' : '—', h),
        _summaryCell(stbl != null ? '$stbl' : '—', h),
      ]);
    }).toList();
  }

  Widget _scoreCell(int hole, Membership m, double rowH) {
    final theme       = Theme.of(context);
    final saved       = widget.scorecard.holeData(hole)?.scoreFor(m.player.id);
    final pending     = widget.pendingScores[hole]?[m.player.id];
    final gross       = pending ?? saved?.grossScore;
    final net         = pending == null ? saved?.netScore : null;
    final par         = widget.scorecard.holeData(hole)?.par ?? 4;
    final isCurrent   = hole == widget.currentHole;
    final isLocalOnly = pending != null;

    Color? bg;
    if (isCurrent) bg = theme.colorScheme.primaryContainer.withOpacity(0.3);
    if (gross != null && net != null) {
      final diff = net - par;
      if (diff < 0)      bg = Colors.green.shade200;
      else if (diff > 0) bg = Colors.red.shade200;
    }
    if (isLocalOnly) bg = theme.colorScheme.tertiaryContainer.withOpacity(0.5);

    return TableCell(
      child: Container(
        height: rowH, color: bg, alignment: Alignment.center,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(gross != null ? '$gross' : '—',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          if (isLocalOnly)
            Icon(Icons.cloud_upload_outlined,
                size: 8, color: theme.colorScheme.tertiary),
        ]),
      ),
    );
  }

  Widget _summaryCell(String value, double rowH) {
    final theme = Theme.of(context);
    return TableCell(
      child: Container(
        height: rowH,
        color: theme.colorScheme.surfaceContainerLow,
        alignment: Alignment.center,
        child: Text(value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
      ),
    );
  }

  Widget _cell(String text,
      {required double height, bool bold = false, bool italic = false, Color? bg}) {
    return TableCell(
      child: Container(
        height: height, color: bg, alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            fontWeight: bold   ? FontWeight.bold  : null,
            fontStyle:  italic ? FontStyle.italic : null,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}
