/// screens/quota_nassau_screen.dart
/// ----------------------------------
/// Score-entry screen for Four Ball Quota (Nassau).
///
/// Gross Stableford only — no handicap net scoring.
/// Players grouped into PAIRS (team1 / team2).
/// UI mirrors nassau_screen.dart exactly:
///   • hotSpotIdx auto-advances between players (no tap to open picker)
///   • Inline gross picker: par=white, eagles left in green, bogeys right in red
///   • 18-hole summary grid: 2 header rows, T1 rows, T1 pts row, T2 rows, T2 pts row
///   • Footer: combined Stableford pts vs quota for each team

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';

// Gross Stableford: eagle=4, birdie=3, par=2, bogey=1, dbl+=0
int _gsf(int gross, int par) => (2 + par - gross).clamp(0, 99);

/// Map a colour name string to a Color for team display.
Color _qnTeamColor(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case 'red':    return Colors.red.shade700;
    case 'green':  return Colors.green.shade700;
    case 'gold':
    case 'yellow': return Colors.amber.shade700;
    case 'blue':
    default:       return Colors.blue.shade700;
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class QuotaNassauScreen extends StatefulWidget {
  final int foursomeId;
  const QuotaNassauScreen({super.key, required this.foursomeId});

  @override
  State<QuotaNassauScreen> createState() => _QuotaNassauScreenState();
}

class _QuotaNassauScreenState extends State<QuotaNassauScreen> {
  final Map<int, Map<int, int>> _pending = {};
  int  _selectedHole    = 1;
  bool _initialJumpDone = false;
  bool _prevHadPending  = false;
  /// Override which player's picker is open (null = auto by hotSpotIdx).
  int? _hotPlayerOverride;

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
      rp.loadQuotaNassau(widget.foursomeId);
    });
  }

  // ── Player helpers ─────────────────────────────────────────────────────────

  /// Returns players ordered: T1 first (player1 from each match), T2 second.
  /// For cross-foursome phantoms the phantom membership is appended at the end
  /// so it appears in the score grid but has no entry picker.
  List<Membership> _orderedPlayers(
      Foursome foursome, QuotaNassauSummary? summary) {
    // All players including phantom for ordering against match pairings
    final allMembers = foursome.memberships;
    final members    = foursome.realPlayers;
    if (summary == null || summary.matches.isEmpty) return members;

    final ordered = <Membership>[];
    // Interleave by match pair: T1 player then T2 player for each match.
    // This ensures phantom's direct opponent (T1 of phantom's match) is
    // immediately above the phantom row.
    for (final m in summary.matches) {
      final mem1 = allMembers
          .where((x) => x.player.id == m.player1.playerId)
          .firstOrNull;
      if (mem1 != null && !ordered.any((o) => o.player.id == mem1.player.id)) {
        ordered.add(mem1);
      }
      final mem2 = allMembers
          .where((x) => x.player.id == m.player2.playerId)
          .firstOrNull;
      if (mem2 != null && !ordered.any((o) => o.player.id == mem2.player.id)) {
        ordered.add(mem2);
      }
    }
    // Any real players not yet in the list
    for (final mem in members) {
      if (!ordered.any((o) => o.player.id == mem.player.id)) {
        ordered.add(mem);
      }
    }
    return ordered;
  }

  /// playerId → individual 18-hole quota
  Map<int, int> _quotaMap(QuotaNassauSummary? summary) {
    if (summary == null) return {};
    final map = <int, int>{};
    for (final m in summary.matches) {
      map[m.player1.playerId] = m.player1.quota;
      map[m.player2.playerId] = m.player2.quota;
    }
    return map;
  }

  /// 'T1' for player1 in any match, 'T2' for player2.
  String? _teamLabel(int playerId, QuotaNassauSummary? summary) {
    if (summary == null) return null;
    for (final m in summary.matches) {
      if (m.player1.playerId == playerId) return 'T1';
      if (m.player2.playerId == playerId) return 'T2';
    }
    return null;
  }

  void _jumpToFirstUnplayed(RoundProvider rp, List<Membership> players) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = players
        .where((m) => !m.player.isPhantom)
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
    if (_hotPlayerOverride != null) {
      final idx =
          players.indexWhere((m) => m.player.id == _hotPlayerOverride);
      if (idx >= 0 && !players[idx].player.isPhantom) return idx;
    }
    for (int i = 0; i < players.length; i++) {
      if (players[i].player.isPhantom) continue; // phantom score comes via propagation
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  bool _allScored(List<Membership> players, Map<int, int> scores,
      {NassauPhantomInfo? phantomInfo, int? hole}) {
    for (final m in players) {
      if (m.player.isPhantom) {
        // Cross-foursome phantom: block until the assigned donor has scored.
        if (phantomInfo != null && hole != null) {
          final donor = phantomInfo.donorForHole(hole);
          if (donor != null && !donor.hasScore) return false;
        }
        continue; // phantom score arrives via propagation — never entered here
      }
      if (!scores.containsKey(m.player.id)) return false;
    }
    return true;
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
      _hotPlayerOverride = null; // auto-advance after selection
      if (score == -1) {
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] =
            score;
      }
    });
  }

  void _tapScoredPlayer(int playerId) {
    setState(() => _hotPlayerOverride = playerId);
  }

  void _advance() {
    if (_selectedHole < 18) {
      setState(() {
        _selectedHole++;
        _hotPlayerOverride = null;
      });
    }
  }

  void _retreat() {
    if (_selectedHole > 1) {
      setState(() {
        _selectedHole--;
        _hotPlayerOverride = null;
      });
    }
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
      scores: scores,
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
    setState(() => _pending.remove(_selectedHole));
    rp.loadQuotaNassau(widget.foursomeId);
    _advance();
  }

  Future<void> _finishRound(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final rp     = context.read<RoundProvider>();
    final sync   = context.read<SyncService>();
    final roundId = rp.round?.id;

    final pendingForHole = _pending[_selectedHole];
    if (pendingForHole != null && pendingForHole.isNotEmpty) {
      final scores = pendingForHole.entries
          .map((e) => {'player_id': e.key, 'gross_score': e.value})
          .toList();
      final ok = await rp.submitHole(
        foursomeId: widget.foursomeId,
        holeNumber: _selectedHole,
        scores: scores,
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
      setState(() => _pending.remove(_selectedHole));
    }

    await sync.waitUntilIdle();
    if (!mounted) return;
    rp.loadQuotaNassau(widget.foursomeId);
    if (roundId != null) {
      Navigator.of(ctx).pushReplacementNamed('/leaderboard', arguments: roundId);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp      = context.watch<RoundProvider>();
    final sync    = context.watch<SyncService>();
    final sc      = rp.scorecard;
    final summary = rp.quotaNassauSummary;
    final round   = rp.round;
    final isComplete = round?.status == 'complete';

    final foursome = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;

    if (foursome == null || (rp.loadingScorecard && sc == null)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Four Ball Quota')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final players = _orderedPlayers(foursome, summary);

    if (!_initialJumpDone && sc != null) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _jumpToFirstUnplayed(context.read<RoundProvider>(), players);
        }
      });
    }

    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<RoundProvider>().loadQuotaNassau(widget.foursomeId);
        }
      });
    }
    _prevHadPending = nowHasPending;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Four Ball Quota'),
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
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: round == null
                ? null
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: round.id),
          ),
          IconButton(
            tooltip: 'Full scorecard',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: sc == null
                ? null
                : () => Navigator.of(context).pushNamed('/scorecard',
                    arguments: {
                      'foursomeId': widget.foursomeId,
                      'readOnly': true
                    }),
          ),
        ],
      ),
      body: sc == null
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(
              context, rp, sc, summary, foursome, players, isComplete),
      bottomNavigationBar: sc == null
          ? null
          : _buildBottomBar(context, rp, sc, players, summary?.phantom),
    );
  }

  Widget _buildBottomBar(
    BuildContext ctx,
    RoundProvider rp,
    Scorecard sc,
    List<Membership> players,
    NassauPhantomInfo? phantomInfo,
  ) {
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores,
        phantomInfo: phantomInfo, hole: _selectedHole);
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
                    label: Text(
                        rp.submitting ? 'Saving…' : 'Hole ${_selectedHole + 1}'),
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
    Scorecard sc,
    QuotaNassauSummary? summary,
    Foursome foursome,
    List<Membership> players,
    bool isComplete,
  ) {
    final merged   = _mergePending(rp.localPendingByHole, _pending);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;
    final quotaMap = _quotaMap(summary);

    return Column(children: [
      _QNTeamBanner(summary: summary),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _QNHoleScoreCard(
                holeData:        holeData,
                holeNumber:      _selectedHole,
                players:         players,
                scores:          scores,
                hotSpotIdx:      hotSpot,
                par:             par,
                quotaMap:        quotaMap,
                summary:         summary,
                onScoreSelected: (m, score) =>
                    _selectScore(m, score, _selectedHole),
                onReTapPlayer:   (m) => _tapScoredPlayer(m.player.id),
              ),
              const SizedBox(height: 12),

              if (players.isNotEmpty)
                _QNSummaryGrid(
                  players:     players,
                  scorecard:   sc,
                  merged:      merged,
                  summary:     summary,
                  quotaMap:    quotaMap,
                  currentHole: _selectedHole,
                  onTapHole:   (h) => setState(() {
                    _selectedHole      = h;
                    _hotPlayerOverride = null;
                  }),
                ),

              // Phantom info strip
              if (summary?.phantom != null) ...[
                const SizedBox(height: 4),
                _QNPhantomInfoStrip(
                  phantomInfo: summary!.phantom!,
                  players:     players,
                  quotaMap:    quotaMap,
                ),
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
// Phantom info strip (cross-foursome phantom for Quota Nassau)
// ===========================================================================

class _QNPhantomInfoStrip extends StatelessWidget {
  final NassauPhantomInfo phantomInfo;
  final List<Membership>  players;
  final Map<int, int>     quotaMap;

  const _QNPhantomInfoStrip({
    required this.phantomInfo,
    required this.players,
    required this.quotaMap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Derive course HC from quota: course_hc = 36 - quota.
    // The stored phantomPlayingHcp is often 0 for phantoms, so use quotaMap.
    final phantomQuota = quotaMap[phantomInfo.phantomPlayerId];
    final hc = phantomQuota != null
        ? 36 - phantomQuota
        : (phantomInfo.phantomPlayingHcp > 0
            ? phantomInfo.phantomPlayingHcp
            : null);

    // Group holes by donor name
    final Map<String, List<int>> byDonor = {};
    for (int h = 1; h <= 18; h++) {
      final donor = phantomInfo.donorForHole(h);
      if (donor == null) continue;
      byDonor.putIfAbsent(donor.playerName, () => []).add(h);
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.colorScheme.secondaryContainer),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('PHANTOM',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  )),
            ),
            const SizedBox(width: 8),
            if (hc != null)
              Text('Course HC: \$hc (avg of team)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  )),
          ]),
          if (byDonor.isNotEmpty) ...[
            const SizedBox(height: 6),
            ...byDonor.entries.map((e) {
              final name    = e.key;
              final holes   = e.value;
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
                    child: Text(
                      "$name — holes ${holes.join(', ')} "
                      "($scored scored${pending > 0 ? ', $pending pending' : ''})",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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

// ===========================================================================
// Team banner
// ===========================================================================

class _QNTeamBanner extends StatelessWidget {
  final QuotaNassauSummary? summary;
  const _QNTeamBanner({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t1Label = summary == null || summary!.matches.isEmpty
        ? 'Team 1'
        : summary!.matches.map((m) => m.player1.shortName).join(' & ');
    final t2Label = summary == null || summary!.matches.isEmpty
        ? 'Team 2'
        : summary!.matches.map((m) => m.player2.shortName).join(' & ');

    final t1Color  = _qnTeamColor(summary?.team1Colour);
    final t2Color  = _qnTeamColor(summary?.team2Colour);
    final t1IsRed  = t1Color.red >= t1Color.blue;
    final leftColor  = t1IsRed ? t1Color : t2Color;
    final rightColor = t1IsRed ? t2Color : t1Color;
    final leftLabel  = t1IsRed ? t1Label : t2Label;
    final rightLabel = t1IsRed ? t2Label : t1Label;

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
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
      ]),
    );
  }
}

// ===========================================================================
// Active hole card
// ===========================================================================

class _QNHoleScoreCard extends StatelessWidget {
  final ScorecardHole?                 holeData;
  final int                            holeNumber;
  final List<Membership>               players;
  final Map<int, int>                  scores;
  final int                            hotSpotIdx;
  final int                            par;
  final Map<int, int>                  quotaMap;
  final QuotaNassauSummary?            summary;
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership)      onReTapPlayer;

  const _QNHoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.quotaMap,
    required this.summary,
    required this.onScoreSelected,
    required this.onReTapPlayer,
  });

  Color get _t1Color => _qnTeamColor(summary?.team1Colour);
  Color get _t2Color => _qnTeamColor(summary?.team2Colour);

  String? _teamLabel(int playerId) {
    if (summary == null) return null;
    for (final m in summary!.matches) {
      if (m.player1.playerId == playerId) return 'T1';
      if (m.player2.playerId == playerId) return 'T2';
    }
    return null;
  }

  static String _holeHeaderText(ScorecardHole hole, List<Membership> players) {
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
      return unique.length == 1 ? fmt(unique.first) : unique.map(fmt).join('/');
    }
    final parStr   = 'Par ${collapse<int>(parVals, (v) => '$v')}';
    final siStr    = 'SI: ${collapse<int>(siVals, (v) => '$v')}';
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
                  _holeHeaderText(holeData!, players),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
            ]),
          ),

          // Player rows + inline picker (auto-shown for hotspot)
          ...players.asMap().entries.expand((entry) {
            final idx      = entry.key;
            final m        = entry.value;
            final gross    = scores[m.player.id];
            final isHot    = idx == hotSpotIdx;
            final quota    = quotaMap[m.player.id];
            final teamLbl  = _teamLabel(m.player.id);
            final playerPar =
                holeData?.scoreFor(m.player.id)?.par ?? par;

            return [
              _QNPlayerRow(
                member:    m,
                gross:     gross,
                isHot:     isHot,
                quota:     quota,
                teamLabel: teamLbl,
                par:       playerPar,
                t1Color:   _t1Color,
                t2Color:   _t2Color,
                onTap: gross != null && !isHot
                    ? () => onReTapPlayer(m)
                    : null,
              ),
              if (isHot && !m.player.isPhantom)
                _QNInlinePicker(
                  par:             playerPar,
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

// ===========================================================================
// Player row
// ===========================================================================

class _QNPlayerRow extends StatelessWidget {
  final Membership    member;
  final int?          gross;
  final bool          isHot;
  final int?          quota;
  final String?       teamLabel;
  final int           par;
  final VoidCallback? onTap;
  final Color         t1Color;
  final Color         t2Color;

  const _QNPlayerRow({
    required this.member,
    required this.gross,
    required this.isHot,
    required this.par,
    this.quota,
    this.teamLabel,
    this.onTap,
    Color? t1Color,
    Color? t2Color,
  })  : t1Color = t1Color ?? const Color(0xFF1976D2),
        t2Color = t2Color ?? const Color(0xFFD32F2F);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pts   = gross != null ? _gsf(gross!, par) : null;

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
        // Team badge
        if (teamLabel != null) ...[
          Container(
            width: 28,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: (teamLabel == 'T1' ? t1Color : t2Color).withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              teamLabel!,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: teamLabel == 'T1' ? t1Color : t2Color,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],

        // Name + quota sublabel
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                member.player.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isHot ? theme.colorScheme.primary : null,
                ),
              ),
              if (quota != null)
                Text(
                  // Show F9 / B9 / 18 quota: e.g. "12/12/24"
                  'Quota ${quota! ~/ 2}/${quota! - quota! ~/ 2}/$quota',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),

        // Stableford pts badge
        if (pts != null) ...[
          _QNPtsBadge(pts: pts),
          const SizedBox(width: 8),
        ] else
          const SizedBox(width: 60),

        // Score box
        GestureDetector(
          onTap: onTap,
          child: gross != null
              ? NetScoreButton(
                  score:    gross!,
                  par:      par,
                  strokes:  0, // gross only — par = white
                  selected: isHot,
                  width:    42,
                  height:   38,
                )
              : Container(
                  width: 42, height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isHot
                        ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                    border: isHot
                        ? Border.all(
                            color: theme.colorScheme.primary, width: 2)
                        : Border.all(color: theme.colorScheme.outline),
                  ),
                  child: isHot
                      ? Icon(Icons.arrow_drop_down,
                          size: 20, color: theme.colorScheme.primary)
                      : Text('—',
                          style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold)),
                ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Stableford pts badge
// ===========================================================================

class _QNPtsBadge extends StatelessWidget {
  final int pts;
  const _QNPtsBadge({required this.pts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Single neutral color — quota target isn't par, so score-relative
    // tinting (green/gold/red) would be misleading here.
    final color = theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      alignment: Alignment.center,
      child: Text('$pts pt${pts == 1 ? '' : 's'}',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

// ===========================================================================
// Inline score picker — gross only (strokes=0), auto-shown for hotspot player
// ===========================================================================

class _QNInlinePicker extends StatefulWidget {
  final int  par;
  final int? currentScore;
  final void Function(int) onScoreSelected;

  const _QNInlinePicker({
    required this.par,
    required this.currentScore,
    required this.onScoreSelected,
  });

  @override
  State<_QNInlinePicker> createState() => _QNInlinePickerState();
}

class _QNInlinePickerState extends State<_QNInlinePicker> {
  static const double _itemW  = 52.0;
  static const double _margin = 5.0;
  static const double _total  = _itemW + _margin * 2;

  late final ScrollController _ctrl;

  double _offsetFor(int par) {
    final startIdx = (par - 3).clamp(0, 11);
    return (startIdx * _total).clamp(0.0, double.infinity);
  }

  @override
  void initState() {
    super.initState();
    _ctrl = ScrollController(initialScrollOffset: _offsetFor(widget.par));
  }

  @override
  void didUpdateWidget(covariant _QNInlinePicker old) {
    super.didUpdateWidget(old);
    if (old.par != widget.par) {
      final target = _offsetFor(widget.par);
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
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color:
                            theme.colorScheme.error.withOpacity(0.4)),
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
            padding: const EdgeInsets.symmetric(horizontal: _margin),
            child: NetScoreButton(
              score:    s,
              par:      widget.par,
              strokes:  0, // gross: par = white
              selected: sel,
              width:    _itemW,
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
// 18-hole summary grid
//
// Layout (matches user's Nassau progress sheet):
//   Row 1: Hole numbers
//   Row 2: Par
//   ── divider ──
//   T1 player 1 gross scores (blue)
//   T1 player 2 gross scores (blue)
//   T1 combined Stableford pts per hole (blue, colour-coded bg)
//   ── divider ──
//   T2 player 1 gross scores (red)
//   T2 player 2 gross scores (red)
//   T2 combined Stableford pts per hole (red, colour-coded bg)
//   ── divider ──
//   Footer: team totals vs quota
// ===========================================================================

class _QNSummaryGrid extends StatefulWidget {
  final List<Membership>        players;
  final Scorecard               scorecard;
  final Map<int, Map<int, int>> merged;
  final QuotaNassauSummary?     summary;
  final Map<int, int>           quotaMap;
  final int                     currentHole;
  final void Function(int)      onTapHole;

  const _QNSummaryGrid({
    required this.players,
    required this.scorecard,
    required this.merged,
    required this.summary,
    required this.quotaMap,
    required this.currentHole,
    required this.onTapHole,
  });

  @override
  State<_QNSummaryGrid> createState() => _QNSummaryGridState();
}

class _QNSummaryGridState extends State<_QNSummaryGrid> {
  final ScrollController _ctrl = ScrollController();

  static const double _labelW = 64.0;
  static const double _cellW  = 30.0;
  static const double _rowH   = 26.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToHole(widget.currentHole));
  }

  @override
  void didUpdateWidget(_QNSummaryGrid old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToHole(widget.currentHole));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _scrollToHole(int hole) {
    if (!_ctrl.hasClients) return;
    final target = (_labelW + (hole - 7) * _cellW)
        .clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.animateTo(target,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  int? _grossFor(int playerId, int hole) =>
      widget.merged[hole]?[playerId] ??
      widget.scorecard.holeData(hole)?.scoreFor(playerId)?.grossScore;

  // Quota Nassau uses GROSS Stableford (no handicap adjustment).
  // Always use the hole's raw par — never the player's net par.
  int _parFor(int playerId, int hole) =>
      widget.scorecard.holeData(hole)?.par ?? 4;

  /// Net-to-par for a single player on a hole.
  /// Returns null if the player has no gross score yet.
  /// net-to-par = grossScore − handicapStrokes − grossPar
  int? _playerNetToPar(int playerId, int hole) {
    final g = _grossFor(playerId, hole);
    if (g == null) return null;
    final grossPar = widget.scorecard.holeData(hole)?.par ?? 4;
    final hcpStrokes =
        widget.scorecard.holeData(hole)?.scoreFor(playerId)?.handicapStrokes ?? 0;
    return g - hcpStrokes - grossPar;
  }

  /// Sum of net-to-par across all players on the team for all scored holes.
  /// Holes where any player is missing a score are skipped for that player.
  int _teamNetScore(List<Membership> members, List<int> holes) {
    int total = 0;
    for (final h in holes) {
      for (final m in members) {
        final n = _playerNetToPar(m.player.id, h);
        if (n != null) total += n;
      }
    }
    return total;
  }

  /// Format a net-to-par total as "+N", "-N", or "E".
  static String _fmtNet(int n) {
    if (n == 0) return 'E';
    return n > 0 ? '+$n' : '$n';
  }

  /// Combined stableford for a list of players on a hole.
  /// Returns null if no player on that hole has a score yet.
  int? _teamSf(List<Membership> members, int hole) {
    int total     = 0;
    bool anyScore = false;
    for (final m in members) {
      final g = _grossFor(m.player.id, hole);
      if (g != null) {
        total += _gsf(g, _parFor(m.player.id, hole));
        anyScore = true;
      }
    }
    return anyScore ? total : null;
  }

  (List<Membership>, List<Membership>) _splitTeams() {
    if (widget.summary == null || widget.summary!.matches.isEmpty) {
      final mid = widget.players.length ~/ 2;
      return (
        widget.players.take(mid).toList(),
        widget.players.skip(mid).toList(),
      );
    }
    final t1Ids =
        widget.summary!.matches.map((m) => m.player1.playerId).toSet();
    final t2Ids =
        widget.summary!.matches.map((m) => m.player2.playerId).toSet();
    return (
      widget.players.where((m) => t1Ids.contains(m.player.id)).toList(),
      widget.players.where((m) => t2Ids.contains(m.player.id)).toList(),
    );
  }

  // No background tinting on grid score cells — quota target varies per hole
  // so par-based colors (green/gold/red) would be misleading.
  Color? _sfBg(int? pts) => null;

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final holeRange = List.generate(18, (i) => i + 1);
    final (t1, t2)  = _splitTeams();

    // Team colors from summary.
    final t1Color = _qnTeamColor(widget.summary?.team1Colour);
    final t2Color = _qnTeamColor(widget.summary?.team2Colour);

    // ── helpers ──────────────────────────────────────────────────────────────

    Widget labelCell(String text,
        {Color? color, FontWeight fw = FontWeight.normal}) =>
        SizedBox(
          width: _labelW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, fontWeight: fw, color: color)),
          ),
        );

    Widget holeCell(int h, Widget child, {Color? bg}) {
      final isCur = h == widget.currentHole;
      return GestureDetector(
        onTap: () => widget.onTapHole(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ??
                (isCur
                    ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                    : null),
            border: isCur
                ? Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.6),
                    width: 1.2)
                : null,
          ),
          child: child,
        ),
      );
    }

    Widget txt(String s,
        {Color? fg, FontWeight fw = FontWeight.normal, double fs = 10}) =>
        Text(s,
            style: TextStyle(fontSize: fs, fontWeight: fw, color: fg));

    Widget divider() => Container(
          height: 1,
          width: _labelW + _cellW * 18,
          color: theme.colorScheme.outlineVariant,
          margin: const EdgeInsets.symmetric(vertical: 3),
        );

    // Gross score row for a player
    Widget playerRow(Membership m, Color teamColor) => Row(children: [
          labelCell(m.player.displayShort,
              color: teamColor, fw: FontWeight.w600),
          ...holeRange.map((h) {
            final g = _grossFor(m.player.id, h);
            return holeCell(
              h,
              txt(
                g == null ? '–' : '$g',
                fg: g == null ? theme.colorScheme.outlineVariant : null,
                fw: g != null ? FontWeight.w600 : FontWeight.normal,
              ),
            );
          }),
        ]);

    // Combined Stableford pts row for a team
    Widget ptsRow(List<Membership> members, Color teamColor, String label) =>
        Row(children: [
          labelCell(label, color: teamColor, fw: FontWeight.bold),
          ...holeRange.map((h) {
            final sf = _teamSf(members, h);
            return holeCell(
              h,
              txt(
                sf == null ? '·' : '$sf',
                fg: sf == null
                    ? theme.colorScheme.outlineVariant
                    : teamColor.withOpacity(0.9),
                fw: sf != null ? FontWeight.bold : FontWeight.normal,
              ),
              bg: _sfBg(sf),
            );
          }),
        ]);

    // ── Footer totals ─────────────────────────────────────────────────────────
    // Compute F9 stpl, B9 stpl, and All stpl for each team.
    int t1F9 = 0, t1B9 = 0, t2F9 = 0, t2B9 = 0, holesThru = 0;
    final List<int> scoredHoles = [];
    for (final h in holeRange) {
      final sf1 = _teamSf(t1, h);
      final sf2 = _teamSf(t2, h);
      if (h <= 9) {
        if (sf1 != null) { t1F9 += sf1; holesThru++; scoredHoles.add(h); }
        if (sf2 != null)   t2F9 += sf2;
      } else {
        if (sf1 != null) { t1B9 += sf1; holesThru++; scoredHoles.add(h); }
        if (sf2 != null)   t2B9 += sf2;
      }
    }
    final t1Total = t1F9 + t1B9;
    final t2Total = t2F9 + t2B9;

    // Team net = sum of (grossScore − handicapStrokes − grossPar) for each player
    // on each team across all scored holes.
    final t1Net = _teamNetScore(t1, scoredHoles);
    final t2Net = _teamNetScore(t2, scoredHoles);

    // Quota per segment: sum each team's 18-hole quotas first, then split.
    // Splitting at the team level avoids rounding errors from odd individual quotas.
    int t1AllQ = 0, t2AllQ = 0;
    for (final m in (widget.summary?.matches ?? <QuotaNassauMatchSummary>[])) {
      t1AllQ += m.player1.quota;
      t2AllQ += m.player2.quota;
    }
    final int t1F9Q = t1AllQ ~/ 2;
    final int t1B9Q = t1AllQ - t1F9Q;
    final int t2F9Q = t2AllQ ~/ 2;
    final int t2B9Q = t2AllQ - t2F9Q;

    // Show split format (F9/B9/All) once front 9 is complete (9+ holes scored).
    final showSplit = holesThru >= 9;

    String vsQ(int pts, int q) {
      final d = pts - q;
      if (d == 0) return 'E';
      return d > 0 ? '+$d' : '$d';
    }
    Color vsQColor(int pts, int q) =>
        pts >= q ? Colors.green.shade700 : theme.colorScheme.error;

    // ── Card ──────────────────────────────────────────────────────────────────
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
              controller: _ctrl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: hole numbers
                  Row(children: [
                    labelCell('Hole', fw: FontWeight.bold),
                    ...holeRange.map((h) => holeCell(h,
                        txt('$h', fw: FontWeight.bold))),
                  ]),
                  // Header: par
                  Row(children: [
                    labelCell('Par',
                        color: theme.colorScheme.onSurfaceVariant),
                    ...holeRange.map((h) => holeCell(h,
                        txt(
                          '${widget.scorecard.holeData(h)?.par ?? '—'}',
                          fg: theme.colorScheme.onSurfaceVariant,
                        ))),
                  ]),

                  divider(),

                  // ── Team 1 ─────────────────────────────────────────────────
                  ...t1.map((m) => playerRow(m, t1Color)),
                  ptsRow(t1, t1Color, 'T1 stpl'),

                  divider(),

                  // ── Team 2 ─────────────────────────────────────────────────
                  ...t2.map((m) => playerRow(m, t2Color)),
                  ptsRow(t2, t2Color, 'T2 stpl'),
                ],
              ),
            ),

            // ── Footer: running totals vs quota ───────────────────────────────
            if (t1AllQ > 0 || t2AllQ > 0) ...[
              divider(),
              Row(children: [
                Expanded(
                  child: _QNFooterBlock(
                    color:      t1Color,
                    total:      t1Total,
                    f9:         t1F9,
                    b9:         t1B9,
                    quotaF9:    t1F9Q,
                    quotaB9:    t1B9Q,
                    quotaAll:   t1AllQ,
                    showSplit:  showSplit,
                    vsQ:        vsQ,
                    vsQColor:   vsQColor,
                    theme:      theme,
                  ),
                ),
                Container(
                    width: 1, height: 48,
                    color: theme.colorScheme.outlineVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: _QNFooterBlock(
                    color:      t2Color,
                    total:      t2Total,
                    f9:         t2F9,
                    b9:         t2B9,
                    quotaF9:    t2F9Q,
                    quotaB9:    t2B9Q,
                    quotaAll:   t2AllQ,
                    showSplit:  showSplit,
                    vsQ:        vsQ,
                    vsQColor:   vsQColor,
                    theme:      theme,
                  ),
                ),
              ]),
              if (holesThru > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Text(
                        'Thru $holesThru hole${holesThru == 1 ? '' : 's'}',
                        style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic),
                      ),
                      const SizedBox(width: 8),
                      // T1 net
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: t1Color.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _fmtNet(t1Net),
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: t1Color),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('net',
                          style: TextStyle(
                              fontSize: 9,
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(width: 8),
                      // T2 net
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: t2Color.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _fmtNet(t2Net),
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: t2Color),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('net',
                          style: TextStyle(
                              fontSize: 9,
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Footer block: single stpl total before F9 done; F9/B9/All split after.
// ===========================================================================

class _QNFooterBlock extends StatelessWidget {
  final Color   color;
  final int     total, f9, b9;
  final int     quotaF9, quotaB9, quotaAll;
  final bool    showSplit;
  final String  Function(int, int) vsQ;
  final Color   Function(int, int) vsQColor;
  final ThemeData theme;

  const _QNFooterBlock({
    required this.color,
    required this.total,
    required this.f9,
    required this.b9,
    required this.quotaF9,
    required this.quotaB9,
    required this.quotaAll,
    required this.showSplit,
    required this.vsQ,
    required this.vsQColor,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    if (!showSplit) {
      // Before F9 complete — single running stpl total
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$total stpl',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          Text(
            'Quota $quotaF9/$quotaB9/$quotaAll  (${vsQ(total, quotaAll)})',
            style: TextStyle(
                fontSize: 11, color: vsQColor(total, quotaAll)),
          ),
        ],
      );
    }

    // F9 done — show  "F9 / B9 / All stpl"  +  diff line
    final f9Str  = vsQ(f9,    quotaF9);
    final b9Str  = vsQ(b9,    quotaB9);
    final allStr = vsQ(total, quotaAll);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // e.g. "13 / 3 / 16 stpl"
        RichText(text: TextSpan(
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.bold, color: color),
          children: [
            TextSpan(text: '$f9'),
            TextSpan(text: ' / ',
                style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.normal,
                    fontSize: 12)),
            TextSpan(text: '$b9'),
            TextSpan(text: ' / ',
                style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.normal,
                    fontSize: 12)),
            TextSpan(text: '$total stpl'),
          ],
        )),
        const SizedBox(height: 1),
        // e.g. "Quota 12/12/24"
        Text('Quota $quotaF9/$quotaB9/$quotaAll',
            style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 1),
        // e.g. "+1 / -9 / -8"
        RichText(text: TextSpan(
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          children: [
            TextSpan(text: f9Str,
                style: TextStyle(color: vsQColor(f9, quotaF9))),
            TextSpan(text: ' / ',
                style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.normal)),
            TextSpan(text: b9Str,
                style: TextStyle(color: vsQColor(b9, quotaB9))),
            TextSpan(text: ' / ',
                style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.normal)),
            TextSpan(text: allStr,
                style: TextStyle(color: vsQColor(total, quotaAll))),
          ],
        )),
      ],
    );
  }
}
