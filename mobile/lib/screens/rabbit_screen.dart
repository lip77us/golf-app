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
import '../widgets/icon_help_sheet.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/spots_capture.dart';
import '../utils/match_handicap.dart';
import '../utils/round_complete.dart';

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

class _RabbitScreenState extends State<RabbitScreen> with SpotsCaptureMixin {
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
      rp.loadRabbit(widget.foursomeId);
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
    rp.loadRabbit(widget.foursomeId);
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

  void _advance() {
    if (_selectedHole < 18) setState(() { _selectedHole++; _editingPlayerId = null; });
  }
  void _retreat() {
    if (_selectedHole > 1)  setState(() { _selectedHole--; _editingPlayerId = null; });
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
    rp.loadRabbit(widget.foursomeId);
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
      for (int h = 1; h <= 18; h++) {
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
        if (mounted) context.read<RoundProvider>().loadRabbit(widget.foursomeId);
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
        title: 'Rabbit',
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
          IconButton(
            tooltip: 'Full scorecard',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: sc == null ? null
                : () => Navigator.of(context).pushNamed('/scorecard',
                    arguments: {'foursomeId': widget.foursomeId, 'readOnly': true}),
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
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
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
            _HoleHeader(holeNumber: _selectedHole, holeData: holeData,
                onHelp: () => _showRabbitLegend(context)),
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
            if (summary != null && summary.numSegments > 1) ...[
              _SegmentStrip(summary: summary),
              const SizedBox(height: 12),
            ],
            if (summary != null)
              _RabbitGrid(
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
  void _showRabbitLegend(BuildContext context) {
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
            Text('Rabbit row guide',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            row(Icon(Icons.directions_run, size: 20, color: theme.colorScheme.primary),
                'Rabbit holder',
                'The runner marks who currently holds the rabbit (their row is tinted with a colored left edge). Win a hole outright to grab it; lose one and it’s loose again.'),
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

int  _rabbitZeroSpots(int _) => 0;
void _rabbitNoopPid(int _) {}

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
    required this.holderId,
    required this.editingPlayerId,
    required this.onScoreSelected,
    required this.onEditTap,
    this.spotsActive   = false,
    this.spotsCountFor = _rabbitZeroSpots,
    this.onSpotsAdd    = _rabbitNoopPid,
    this.onSpotsRemove = _rabbitNoopPid,
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
          final isEditing = editingPlayerId == m.player.id;
          // A scored row that isn't the live hot-spot can be tapped to correct
          // it — that re-opens the inline picker (a completed hole has no
          // hot-spot, so without this there'd be no way to edit a past hole).
          final editable = gross != null && !isHot;
          final strokes = _strokesForHole(m, holeData);
          return [
            _PlayerRow(
              member:   m,
              gross:    gross,
              isHot:    isHot,
              strokes:  strokes,
              showHcap: _mode != 'gross',
              hcap:     effectiveMatchHandicap(
                mode: _mode, netPercent: _netPercent,
                playingHandicap: m.playingHandicap,
                lowestPlayingHandicap: _lowPlaying),
              isHolder: _isHolder(m.player.id),
              isEditing: isEditing,
              onTap: editable ? () => onEditTap(m) : null,
              spotsActive:   spotsActive,
              spotsCount:    spotsActive ? spotsCountFor(m.player.id) : 0,
              onSpotsAdd:    spotsActive ? () => onSpotsAdd(m.player.id) : null,
              onSpotsRemove: spotsActive ? () => onSpotsRemove(m.player.id) : null,
            ),
            if (isHot || isEditing)
              InlineScorePicker(
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
    required this.isHolder,
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
    final boxBg = (isHot || isEditing)
        ? theme.colorScheme.primaryContainer.withOpacity(0.4) : Colors.transparent;
    final boxBorder = (isHot || isEditing)
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: theme.colorScheme.outline);

    final row = Container(
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
        // consistent with the other score screens).
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

    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
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
              'Each segment worth \$${summary.entry.toStringAsFixed(2)} — '
              'its holder wins that from every opponent',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}
