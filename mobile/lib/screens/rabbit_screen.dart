/// screens/rabbit_screen.dart
///
/// Play screen for the Rabbit casual game.  Pure score entry (no per-hole
/// decisions) plus a live read-out of who holds the rabbit:
///   • Rabbit banner — current holder + lead (or "loose"), and which
///     segment is in play.
///   • Score-entry rows (modeled on points_531_screen) with an inline
///     net-centred picker; the current rabbit holder is flagged.
///   • Per-hole outcome line (who won the hole / what happened to the rabbit).
///   • Segment strip — holder + payout for each 6/9/18-hole segment.
///   • 18-hole grid — per-hole winner + rabbit holder/lead.
///
/// State comes from the server summary (services.rabbit.rabbit_summary),
/// refreshed after every score submission.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_message.dart';
import '../widgets/net_score_button.dart';

// ---------------------------------------------------------------------------
// Handicap helpers (same rules as points_531_screen)
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

String _fmtMoney(double v) {
  if (v == 0) return '—';
  final sign = v > 0 ? '+' : '−';
  return '$sign\$${v.abs().toStringAsFixed(2)}';
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class RabbitScreen extends StatefulWidget {
  final int foursomeId;
  const RabbitScreen({super.key, required this.foursomeId});

  @override
  State<RabbitScreen> createState() => _RabbitScreenState();
}

class _RabbitScreenState extends State<RabbitScreen> {
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
      rp.loadRabbit(widget.foursomeId);
    });
  }

  List<Membership> _realMembers(Round? round) {
    final fs = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
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
    if (sc == null || score <= 0 || wasAllScored) return;
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
        setState(() => _selectedHole = h);
        return;
      }
    }
    setState(() => _selectedHole = 18);
  }

  void _advance() { if (_selectedHole < 18) setState(() => _selectedHole++); }
  void _retreat() { if (_selectedHole > 1)  setState(() => _selectedHole--); }

  Future<void> _saveAndAdvance(BuildContext ctx, List<Membership> players) async {
    final edits = _pending[_selectedHole];
    if (edits == null || edits.isEmpty) { _advance(); return; }
    final scores = edits.entries
        .map((e) => {'player_id': e.key, 'gross_score': e.value})
        .toList();
    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
      foursomeId: widget.foursomeId, holeNumber: _selectedHole, scores: scores);
    if (!mounted) return;
    if (!ok) { _snack(ctx, rp.error ?? 'Failed to save hole.',
        () => _saveAndAdvance(ctx, players)); return; }
    setState(() { _pending.remove(_selectedHole); });
    rp.loadRabbit(widget.foursomeId);
    _advance();
  }

  Future<void> _finishRound(BuildContext ctx, List<Membership> players) async {
    final rp = context.read<RoundProvider>();
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
    rp.loadRabbit(widget.foursomeId);
    if (roundId != null) {
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
        if (mounted) context.read<RoundProvider>().loadRabbit(widget.foursomeId);
      });
    }
    _prevHadPending = nowHasPending;

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Rabbit',
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
          IconButton(
            tooltip: 'Full scorecard',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: sc == null ? null
                : () => Navigator.of(context).pushNamed('/scorecard',
                    arguments: {'foursomeId': widget.foursomeId, 'readOnly': true}),
          ),
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null ? null
                : () => Navigator.of(context).pushNamed(
                    '/leaderboard', arguments: rp.round!.id),
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
            rp.loadRabbit(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }
    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final summary  = rp.rabbitSummary;
    final players  = _realMembers(rp.round);
    final holeInfo = summary?.holeFor(_selectedHole);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;

    // Rabbit state for the SELECTED hole's segment (not the globally last
    // scored hole) — the segment resets, so on the first hole of a new
    // segment the rabbit is loose until someone catches it.
    int    rabSegment    = holeInfo?.segment ?? 1;
    int?   rabHolderId;
    String? rabHolderShort;
    int    rabLead = 0;
    if (summary != null) {
      for (int h = _selectedHole; h >= 1; h--) {
        final hi = summary.holeFor(h);
        if (hi == null) continue;
        if (hi.segment != rabSegment) break;   // crossed into the prior segment
        if (hi.isScored) {
          rabHolderId    = hi.holderId;
          rabHolderShort = hi.holderShort;
          rabLead        = hi.lead;
          break;
        }
      }
    }

    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (summary != null)
              _RabbitBanner(
                holderShort: rabHolderShort,
                lead:        rabLead,
                segment:     rabSegment,
                accumulate:  summary.accumulate,
                numSegments: summary.numSegments,
              ),
            const SizedBox(height: 12),
            _HoleHeader(holeNumber: _selectedHole, holeData: holeData),
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
              holderId:   rabHolderId,
              onScoreSelected: (m, s) => _handleScore(ctx, m, s, players),
            ),
            if (holeInfo != null && holeInfo.isScored) ...[
              const SizedBox(height: 10),
              _OutcomeLine(hole: holeInfo),
            ],
            const SizedBox(height: 12),
            if (summary != null && summary.numSegments > 1) ...[
              _SegmentStrip(summary: summary),
              const SizedBox(height: 12),
            ],
            if (summary != null)
              _RabbitGrid(
                summary: summary, players: players, scorecard: sc,
                currentHole: _selectedHole,
                onTapHole: (h) => setState(() => _selectedHole = h)),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    ]);
  }

  Widget _buildBottomNav(BuildContext ctx, RoundProvider rp, Scorecard sc) {
    final players = _realMembers(rp.round);
    final scores  = _effectiveScores(sc, _selectedHole);
    final allDone = _allScored(players, scores);
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
                    label: Text(rp.submitting ? 'Saving…' : 'Hole ${_selectedHole + 1}'),
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

class _RabbitBanner extends StatelessWidget {
  final String? holderShort;
  final int     lead;
  final int     segment;
  final bool    accumulate;
  final int     numSegments;
  const _RabbitBanner({
    required this.holderShort,
    required this.lead,
    required this.segment,
    required this.accumulate,
    required this.numSegments,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loose = holderShort == null;
    final color = loose ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(loose ? 0.06 : 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(children: [
        Icon(Icons.directions_run, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              loose
                  ? 'Rabbit is loose — up for grabs'
                  : 'Rabbit: $holderShort'
                    '${accumulate ? '  (+$lead)' : ''}',
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold, color: color),
            ),
            if (numSegments > 1)
              Text('Segment $segment of $numSegments',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Hole header
// ===========================================================================

class _HoleHeader extends StatelessWidget {
  final int holeNumber;
  final ScorecardHole? holeData;
  const _HoleHeader({required this.holeNumber, required this.holeData});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = holeData;
    final sub = h == null ? ''
        : 'Par ${h.par}'
          '${h.yards != null ? '  ·  ${h.yards} yds' : ''}'
          '  ·  SI ${h.strokeIndex}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text('Hole $holeNumber',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        if (sub.isNotEmpty) Text(sub, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

// ===========================================================================
// Score-entry card
// ===========================================================================

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, int>    scores;
  final int              hotSpotIdx;
  final int              par;
  final RabbitSummary?   summary;
  final RabbitHole?      holeInfo;
  final int?             holderId;   // rabbit holder for the selected segment
  final void Function(Membership, int) onScoreSelected;

  const _HoleScoreCard({
    required this.holeData,
    required this.players,
    required this.scorecard,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.summary,
    required this.holeInfo,
    required this.holderId,
    required this.onScoreSelected,
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
      return _strokesOnHole(eff, mySi);
    }
    final low = _lowPlaying;
    if (low == null) return 0;
    final so = m.playingHandicap - low;
    if (so <= 0) return 0;
    return _strokesOnHole(so, mySi);
  }

  bool _isHolder(int playerId) =>
      holderId != null && holderId == playerId;

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
          final strokes = _strokesForHole(m, holeData);
          return [
            _PlayerRow(
              member:   m,
              gross:    gross,
              isHot:    isHot,
              strokes:  strokes,
              showHcap: _mode != 'gross',
              hcap:     _effectiveMatchHandicap(
                mode: _mode, netPercent: _netPercent,
                playingHandicap: m.playingHandicap,
                lowestPlayingHandicap: _lowPlaying),
              isHolder: _isHolder(m.player.id),
            ),
            if (isHot)
              _InlinePicker(
                par: par, strokes: strokes, currentScore: gross,
                onScoreSelected: (s) => onScoreSelected(m, s)),
          ];
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
  final bool       isHolder;

  const _PlayerRow({
    required this.member,
    required this.gross,
    required this.isHot,
    required this.strokes,
    required this.showHcap,
    required this.hcap,
    required this.isHolder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final boxBg = isHot
        ? theme.colorScheme.primaryContainer.withOpacity(0.4) : Colors.transparent;
    final boxBorder = isHot
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: theme.colorScheme.outline);

    return Container(
      decoration: BoxDecoration(
        color: isHolder ? theme.colorScheme.primary.withOpacity(0.06) : null,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
          left: isHolder
              ? BorderSide(color: theme.colorScheme.primary, width: 4)
              : BorderSide.none,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        if (isHolder)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.directions_run, size: 16,
                color: theme.colorScheme.primary),
          ),
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text(member.player.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
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
        ),
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
    );
  }
}

// ---------------------------------------------------------------------------
// Inline score picker
// ---------------------------------------------------------------------------

class _InlinePicker extends StatefulWidget {
  final int  par;
  final int  strokes;
  final int? currentScore;
  final void Function(int) onScoreSelected;
  const _InlinePicker({
    required this.par, required this.strokes,
    required this.currentScore, required this.onScoreSelected});

  @override
  State<_InlinePicker> createState() => _InlinePickerState();
}

class _InlinePickerState extends State<_InlinePicker> {
  static const double _itemWidth = 52.0;
  static const double _itemMargin = 5.0;
  static const double _itemTotal = _itemWidth + _itemMargin * 2;
  late final ScrollController _ctrl;

  double _offsetFor(int par, int strokes) {
    final netPar = par + strokes;
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
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scores = List.generate(12, (i) => i + 1);
    return Container(
      height: 68,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.12),
        border: Border(
          top: BorderSide(color: theme.colorScheme.primary.withOpacity(0.2))),
      ),
      child: ListView.builder(
        controller: _ctrl,
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
                  height: 48, alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: theme.colorScheme.error.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(8)),
                  child: Text('Clear',
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            );
          }
          final s = scores[i];
          final sel = s == widget.currentScore;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
            child: NetScoreButton(
              score: s, par: widget.par, strokes: widget.strokes,
              selected: sel, width: _itemWidth, height: 48,
              onTap: () => widget.onScoreSelected(s)),
          );
        },
      ),
    );
  }
}

// ===========================================================================
// Per-hole outcome line
// ===========================================================================

class _OutcomeLine extends StatelessWidget {
  final RabbitHole hole;
  const _OutcomeLine({required this.hole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String text;
    Color color = theme.colorScheme.onSurfaceVariant;
    switch (hole.event) {
      case 'grab':
        text = '${hole.holderShort} won the hole and caught the rabbit!';
        color = Colors.green.shade700;
      case 'extend':
        text = '${hole.holderShort} won the hole — rabbit lead +${hole.lead}.';
        color = Colors.green.shade700;
      case 'held':
        text = '${hole.holderShort} holds the rabbit (+${hole.lead}).';
        color = theme.colorScheme.primary;
      case 'beaten':
        text = 'Rabbit beaten — ${hole.holderShort} holds on at +${hole.lead}.';
        color = theme.colorScheme.error;
      case 'freed':
        text = 'Rabbit set loose — up for grabs!';
        color = theme.colorScheme.error;
      case 'tie':
      case 'none':
      default:
        text = 'No change'
            '${hole.winnerShort == null ? ' — hole tied.' : '.'}';
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
// Segment strip
// ===========================================================================

class _SegmentStrip extends StatelessWidget {
  final RabbitSummary summary;
  const _SegmentStrip({required this.summary});

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
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Segments',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          const SizedBox(height: 6),
          Column(children: [
            for (final s in summary.segments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(
                    width: 96,
                    child: Text('Holes ${s.startHole}–${s.endHole}',
                        style: theme.textTheme.bodySmall),
                  ),
                  Expanded(
                    child: Text(
                      s.holderShort == null
                          ? (s.complete ? 'Loose (push)' : 'Loose')
                          : 'Rabbit: ${s.holderShort}'
                            '${summary.accumulate ? ' (+${s.lead})' : ''}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: s.holderShort == null
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.primary),
                    ),
                  ),
                  if (s.complete && s.payout > 0)
                    Text('\$${s.payout.toStringAsFixed(2)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w600))
                  else if (!s.complete)
                    Text('in play',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
          ]),
        ]),
      ),
    );
  }
}

// ===========================================================================
// 18-hole grid — winner + rabbit holder per hole
// ===========================================================================

class _RabbitGrid extends StatelessWidget {
  final RabbitSummary    summary;
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int) onTapHole;

  const _RabbitGrid({
    required this.summary, required this.players, required this.scorecard,
    required this.currentHole, required this.onTapHole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const double labelColW = 56.0;
    const double cellW = 34.0;
    const double rowH = 26.0;
    final holeRange = List.generate(18, (i) => i + 1);

    final holderByHole = <int, String?>{};
    final leadByHole   = <int, int>{};
    final winnerByHole = <int, int?>{};
    for (final h in summary.holes) {
      holderByHole[h.hole] = h.holderShort;
      leadByHole[h.hole]   = h.lead;
      winnerByHole[h.hole] = h.winnerId;
    }

    Widget cell(int h, Widget child) {
      final isCur = h == currentHole;
      return GestureDetector(
        onTap: () => onTapHole(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: cellW, height: rowH, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isCur ? theme.colorScheme.primaryContainer.withOpacity(0.35) : null,
            border: isCur
                ? Border.all(color: theme.colorScheme.primary.withOpacity(0.6), width: 1.2)
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Rabbit by hole',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SizedBox(width: labelColW, height: rowH,
                  child: const Align(alignment: Alignment.centerLeft,
                    child: Text('Hole', style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold)))),
                for (final h in holeRange)
                  cell(h, Text('$h', style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold))),
              ]),
              // Per-player gross rows.
              for (final m in players)
                Row(children: [
                  SizedBox(width: labelColW, height: rowH,
                    child: Align(alignment: Alignment.centerLeft,
                      child: Text(m.player.displayShort,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600)))),
                  for (final h in holeRange)
                    cell(h, Builder(builder: (_) {
                      final g = scorecard.holeData(h)?.scoreFor(m.player.id)?.grossScore;
                      final isWinner = winnerByHole[h] == m.player.id;
                      return Text(g == null ? '–' : '$g',
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
                              color: isWinner ? Colors.green.shade700
                                  : g == null ? theme.colorScheme.onSurfaceVariant
                                              : null));
                    })),
                ]),
              Container(height: 1, width: labelColW + cellW * holeRange.length,
                  color: theme.colorScheme.outlineVariant,
                  margin: const EdgeInsets.symmetric(vertical: 2)),
              // Rabbit holder row.
              Row(children: [
                SizedBox(width: labelColW, height: rowH,
                  child: Align(alignment: Alignment.centerLeft,
                    child: Text('Rabbit', style: theme.textTheme.bodySmall
                        ?.copyWith(fontStyle: FontStyle.italic)))),
                for (final h in holeRange)
                  cell(h, Builder(builder: (_) {
                    final hs = holderByHole[h];
                    if (hs == null) {
                      return Text('·', style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant));
                    }
                    final lead = leadByHole[h] ?? 0;
                    return Text(
                      summary.accumulate ? '$hs$lead' : hs,
                      overflow: TextOverflow.clip,
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 9, fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary));
                  })),
              ]),
            ]),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 4, children: [
            for (final p in summary.players)
              Text('${p.shortName}: ${_fmtMoney(p.money)}',
                  style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: p.money > 0 ? Colors.green.shade700
                          : p.money < 0 ? theme.colorScheme.error : null)),
          ]),
          if (summary.entry > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Pot \$${summary.pot.toStringAsFixed(2)} '
              '(3 × \$${summary.entry.toStringAsFixed(2)} entry)',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}
