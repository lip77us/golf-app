/// screens/sequoya_threes_screen.dart
///
/// Play screen for Sequoya 3s
/// (docs/design-review/handoff-sequoya-threes/README.md, screen 2).
///
/// Six three-hole 2v2 matches, the pairing rotating every third hole. Pure
/// score entry — there is no per-hole decision beyond calling a press — so the
/// screen's real job is answering **who am I with, and what is live**.
///
/// The bet banner gives every live bet its OWN row. A match can carry three —
/// the match bet, the auto press and one called by hand — and each settles
/// over its own holes, so a single multiplier would be a lie: a press can be
/// halved while the match is won, or won by the side that lost the match.

import '../utils/handicap_rounding.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/error_view.dart' show friendlyError;
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/net_score_button.dart' show scoreCellWithDots;
import '../widgets/round_chat_button.dart';
import '../widgets/spots_capture.dart';
import '../utils/match_handicap.dart';
import '../utils/play_order.dart';
import '../utils/round_complete.dart';

const Color _kBlue   = Color(0xFF1976D2);   // side 1 of match 1 — "Team A"
const Color _kOrange = Color(0xFFEF6C00);   // side 2
const Color _kAmberBg     = Color(0xFFFDF3E7);
const Color _kAmberBorder = Color(0xFFE0C79C);
const Color _kAmberInk    = Color(0xFF8A5216);

String _fmtMoney(double v) {
  if (v == 0) return '—';
  final sign = v > 0 ? '+' : '−';
  return '$sign\$${v.abs().toStringAsFixed(2)}';
}

/// How a bet reads on the banner. Never a multiplier, and never "DORMIE"
/// unless the lead EQUALS the holes left — 1 up with 2 to play is not it.
///
/// A close-out is read off the hole it CLOSED ON, not off `to_play`. In this
/// game the holes after a close-out are usually still played — the press is
/// running over them — so the match bet's margin keeps moving and `to_play`
/// falls to zero. Reading either would turn a 2 & 1 into "1 up".
String betState(SequoyaBet b) {
  if (b.result == 0) return 'HALVED';
  if (b.result != null) {
    final closed = b.closedOn;
    if (closed != null) {
      final left = b.holes.length - b.holes.indexOf(closed) - 1;
      // The margin crosses the holes left by exactly one, so the winning
      // margin at the close-out is always `left + 1`.
      if (left > 0) return '${left + 1} & $left';
    }
    return '${b.margin.abs()} UP · FINAL';
  }
  if (b.margin == 0) return 'ALL SQUARE';
  if (b.margin.abs() == b.toPlay) return 'DORMIE';
  return '${b.margin.abs()} UP';
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class SequoyaThreesScreen extends StatefulWidget {
  final int foursomeId;
  const SequoyaThreesScreen({super.key, required this.foursomeId});

  @override
  State<SequoyaThreesScreen> createState() => _SequoyaThreesScreenState();
}

class _SequoyaThreesScreenState extends State<SequoyaThreesScreen>
    with SpotsCaptureMixin {
  final Map<int, Map<int, int>> _pending = {};
  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;
  int? _editingPlayerId;
  bool _pressing = false;

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
      rp.loadSequoyaThrees(widget.foursomeId);
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
    rp.loadSequoyaThrees(widget.foursomeId);
    if (rp.round?.activeGames.contains('spots') ?? false) {
      rp.loadSpots(widget.foursomeId);
    }
  }

  // --- roster ------------------------------------------------------------

  List<Membership> _realMembers(Round? round) {
    final fs = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  Membership? _memberFor(int playerId, List<Membership> players) =>
      players.where((m) => m.player.id == playerId).firstOrNull;

  // --- pending scores ----------------------------------------------------

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

  /// The next golfer to score, in the order the screen DRAWS them — side 1's
  /// pair then side 2's, not roster order. Following the roster made the hot
  /// spot jump across the card (Paul, then his opponent, then his partner).
  int? _hotSpotId(List<int> displayOrder, Map<int, int> scores) {
    for (final pid in displayOrder) {
      if (!scores.containsKey(pid)) return pid;
    }
    return null;
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

  void _handleScore(BuildContext ctx, Membership m, int score,
      List<Membership> players) {
    final sc = context.read<RoundProvider>().scorecard;
    final hole = _selectedHole;
    final wasAllScored =
        sc != null && _allScored(players, _effectiveScores(sc, hole));
    _selectScore(m, score, hole);
    if (sc == null || score <= 0) return;
    if (wasAllScored) {
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
      _saveAndAdvance(ctx, players);
    });
  }

  // --- navigation --------------------------------------------------------

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
    if (next != null) {
      setState(() { _selectedHole = next; _editingPlayerId = null; });
    }
  }

  void _retreat() {
    final prev = prevInOrder(
        _playOrder(context.read<RoundProvider>()), _selectedHole);
    if (prev != null) {
      setState(() { _selectedHole = prev; _editingPlayerId = null; });
    }
  }

  // --- saving ------------------------------------------------------------

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
    if (!ok) {
      _snack(ctx, rp.error ?? 'Failed to save hole.',
          () => _saveHole(ctx, hole, players));
      return;
    }
    setState(() { _pending.remove(hole); });
    rp.loadSequoyaThrees(widget.foursomeId);
  }

  Future<void> _saveAndAdvance(
      BuildContext ctx, List<Membership> players) async {
    final hole = _selectedHole;
    if (_pending[hole]?.isNotEmpty ?? false) {
      await _saveHole(ctx, hole, players);
      if (!mounted || _pending.containsKey(hole)) return;   // save failed
    }
    _advance();
  }

  Future<void> _finishRound(BuildContext ctx, List<Membership> players) async {
    final rp = context.read<RoundProvider>();
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
        foursomeId: widget.foursomeId,
        holeNumber: _selectedHole, scores: scores);
      if (!mounted) return;
      if (!ok) {
        _snack(ctx, rp.error ?? 'Failed to save hole.',
            () => _finishRound(ctx, players));
        return;
      }
      setState(() { _pending.remove(_selectedHole); });
    }
    await sync.waitUntilIdle();
    if (!mounted) return;
    if (roundId != null) {
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

  // --- presses -----------------------------------------------------------

  Future<void> _callPress(SequoyaMatch match, int side) async {
    setState(() => _pressing = true);
    try {
      final rp     = context.read<RoundProvider>();
      final me     = context.read<AuthProvider>().player?.id;
      final client = context.read<AuthProvider>().client;
      // Attribute the call only when the reader is ON the side pressing. One
      // phone scores the group, so the scorer routinely calls it for the pair
      // that is down — recording it under his name would be a lie.
      final onThatSide = me != null &&
          (side == 1 ? match.side1 : match.side2)
              .any((p) => p.playerId == me);
      final s = await client.postSequoyaThreesPress(
        widget.foursomeId,
        matchIndex : match.index,
        side       : side,
        currentHole: _selectedHole,
        calledById : onThatSide ? me : null,
      );
      if (!mounted) return;
      rp.setSequoyaThreesSummary(s);
      // The SERVER decides which holes the press covers, so the confirmation
      // reads them back off the bet it just created rather than restating
      // what the client assumed.
      final placed = s.matchForHole(_selectedHole)?.bets
          .where((b) => b.kind == 'manual_press').firstOrNull;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(placed == null
            ? 'Press on.'
            : 'Press on — ${placed.holeRange}.')));
    } catch (e) {
      if (!mounted) return;
      // The service owns the rules, so its refusal IS the message worth
      // showing — it names the rule that stopped the call.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _pressing = false);
    }
  }

  // --- build -------------------------------------------------------------

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
        if (mounted) {
          context.read<RoundProvider>().loadSequoyaThrees(widget.foursomeId);
        }
      });
    }
    _prevHadPending = nowHasPending;

    final isCasualSingle = (rp.round?.isCasual ?? false) &&
        (rp.round?.foursomes.length ?? 1) == 1;
    final showExit = isCasualSingle && _hasAnyScore;

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Sequoya 3s',
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
                      ? 'Syncing…'
                      : 'Tap to sync ${sync.pendingCount} score(s)',
                  onPressed: sync.state == SyncState.syncing
                      ? null : () => sync.recheck(),
                ),
              ),
            ),
          if (rp.round != null) RoundChatButton(roundId: rp.round!.id),
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null ? null
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: rp.round!.id),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'end') _finishRound(context, _realMembers(rp.round));
              if (v == 'help') _showRotationSheet(context);
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
                  title: Text('How the rotation works'),
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
            rp.loadSequoyaThrees(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }
    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final summary  = rp.sequoyaThreesSummary;
    final players  = _realMembers(rp.round);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final par      = holeData?.par ?? 4;
    final match    = summary?.matchForHole(_selectedHole);
    final displayOrder = match == null
        ? players.map((m) => m.player.id).toList()
        : [...match.side1, ...match.side2].map((s) => s.playerId).toList();
    final hotSpotId = isComplete ? null : _hotSpotId(displayOrder, scores);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (match != null) ...[
            _BetBanner(match: match),
            const SizedBox(height: 10),
          ],
          if (match != null && (summary?.manualPresses ?? false) && !isComplete)
            _PressOffer(
              match: match,
              hole:  _selectedHole,
              busy:  _pressing,
              // Whether the hole in play is already in the book decides which
              // hole a press would cover — see _PressOffer.
              holeScored: [...match.side1, ...match.side2]
                  .every((p) => scores.containsKey(p.playerId)),
              mySide: _mySide(match, context.read<AuthProvider>().player?.id),
              onCall: (side) => _callPress(match, side),
            ),
          _HoleHeader(holeNumber: _selectedHole, holeData: holeData),
          const SizedBox(height: 12),
          if (match == null)
            const InlineMessage(
              kind: InlineMessageKind.info,
              text: 'Set the game up to see this hole’s match.',
            )
          else ...[
            for (final pair in [
              (match.side1, _kBlue,   'Side 1'),
              (match.side2, _kOrange, 'Side 2'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PairCard(
                  label:      pair.$3,
                  colour:     pair.$2,
                  side:       pair.$1,
                  players:    players,
                  holeData:   holeData,
                  scores:     scores,
                  par:        par,
                  summary:    summary,
                  hotSpotId:  hotSpotId,
                  editingPlayerId: _editingPlayerId,
                  memberFor:  (pid) => _memberFor(pid, players),
                  onScoreSelected: (m, s) => _handleScore(ctx, m, s, players),
                  onEditTap: (m) => setState(() => _editingPlayerId =
                      _editingPlayerId == m.player.id ? null : m.player.id),
                  spotsActive:   spotsActive(rp),
                  spotsCountFor: (pid) =>
                      spotsCount(pid, _selectedHole, rp.spotsSummary),
                  onSpotsAdd: (pid) =>
                      adjustSpots(widget.foursomeId, pid, _selectedHole, 1),
                  onSpotsRemove: (pid) =>
                      adjustSpots(widget.foursomeId, pid, _selectedHole, -1),
                ),
              ),
          ],
          const SizedBox(height: 6),
          if (summary != null) ...[
            _MatchStrip(
              summary: summary,
              currentHole: _selectedHole,
              onTapMatch: (m) => setState(() {
                _selectedHole = m.startHole;
                _editingPlayerId = null;
              }),
            ),
            const SizedBox(height: 12),
            _MoneyCard(summary: summary),
          ],
          const SizedBox(height: 16),
        ]),
      ),
    );
  }

  /// Which side of [match] the signed-in golfer is on, or null when they are
  /// not playing (a scorer or a watcher) — the press offer is theirs to call
  /// only when they are actually in the match.
  int? _mySide(SequoyaMatch match, int? myPlayerId) {
    if (myPlayerId == null) return null;
    if (match.side1.any((s) => s.playerId == myPlayerId)) return 1;
    if (match.side2.any((s) => s.playerId == myPlayerId)) return 2;
    return null;
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
                    onPressed: rp.submitting
                        ? null : () => _finishRound(ctx, players),
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

  void _showRotationSheet(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Six matches, three holes each',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(
              'Four golfers split two-a-side in exactly three ways, so matches '
              '2 and 3 are the other two pairings and matches 4–6 repeat all '
              'three in the same order. You partner everyone else twice.\n\n'
              'A press is a NEW bet at the same amount, not a doubling. It runs '
              'over the holes left in that match and settles on its own — it '
              'can be halved while the match is won, or won by the side that '
              'lost the match. That is why each one gets its own row.',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 16),
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
}

// ===========================================================================
// Bet banner — one row per bet, never a multiplier
// ===========================================================================

class _BetBanner extends StatelessWidget {
  final SequoyaMatch match;
  const _BetBanner({required this.match});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = match.bets.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.08),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('MATCH ${match.index} OF 6  ·  '
                'HOLES ${match.startHole}–${match.endHole}',
                style: TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.bold,
                    letterSpacing: 0.4, color: theme.colorScheme.primary)),
          ),
          Text('\$${match.atRisk.toStringAsFixed(0)} a man · '
               '$n bet${n == 1 ? '' : 's'}',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 6),
        for (final b in match.bets)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.5),
            child: Row(children: [
              Expanded(
                child: Text('${b.label} · ${b.holeRange}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: b.isPress
                            ? FontWeight.normal : FontWeight.w600,
                        fontStyle: b.isPress
                            ? FontStyle.italic : FontStyle.normal)),
              ),
              Text('\$${b.amount.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                child: Text(betState(b),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold,
                      color: b.margin == 0
                          ? theme.colorScheme.onSurfaceVariant
                          : (b.margin > 0 ? _kBlue : _kOrange),
                    )),
              ),
            ]),
          ),
      ]),
    );
  }
}

// ===========================================================================
// The press offer — named by the hole it would cover
// ===========================================================================

/// Amber, and lit only when a hand-called press is actually legal: no auto
/// press is running, a hole in the match has been decided, a hole is left to
/// cover, and this match carries no called press yet.
///
/// **An auto press rules a hand-called one out.** It already covers the rest
/// of the match, so a second bet over the same holes could only ever settle
/// the same way. In practice that means a called press exists only in a match
/// whose first hole was HALVED — which is exactly when a group wants one.
///
/// **A press is called on the tee, so it covers the hole being played.** That
/// is what makes the LAST hole of a match pressable — two down on the 9th tee
/// is the classic press, and a press that opened on the NEXT hole could never
/// be called there, because that hole belongs to the next match and a
/// different pairing. From a hole already in the book it starts on the next
/// one instead: nobody may press a result they have seen.
class _PressOffer extends StatelessWidget {
  final SequoyaMatch match;
  final int  hole;
  final bool busy;
  final bool holeScored;
  final int? mySide;
  final void Function(int side) onCall;

  const _PressOffer({
    required this.match, required this.hole, required this.busy,
    required this.holeScored, required this.mySide, required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final already  = match.bets.any((b) => b.kind == 'manual_press');
    final auto     = match.bets.where((b) => b.kind == 'auto_press').firstOrNull;
    final headBet  = match.bets.isEmpty ? null : match.bets.first;
    final trailing = (headBet == null || headBet.margin == 0)
        ? null
        : (headBet.margin > 0 ? 2 : 1);
    final start    = holeScored ? hole + 1 : hole;
    final roomLeft = start <= match.endHole;
    final mine     = mySide != null && mySide == trailing;
    final legal    = !already && auto == null && roomLeft
                     && trailing != null && !busy;
    final covers   = start == match.endHole
        ? 'hole $start' : 'holes $start–${match.endHole}';
    final down     = trailing == null
        ? ''
        : (trailing == 1 ? match.side1 : match.side2)
            .map((p) => p.shortName).join(' & ');

    final String title;
    final String body;
    if (already) {
      title = 'Press already called in this match';
      body  = 'One hand-called press per match.';
    } else if (auto != null) {
      // The auto press already covers the rest of the match, so a second bet
      // over the same holes could only ever settle the same way — a double,
      // not a press.
      title = 'The auto press has it';
      body  = 'It already covers ${auto.holeRange} at '
              '\$${auto.amount.toStringAsFixed(0)} a man. A hand-called press '
              'over the same holes would be a double, not a press.';
    } else if (!roomLeft) {
      title = 'Press';
      body  = 'No holes left in this match for a press to cover.';
    } else if (trailing == null) {
      title = 'Press';
      body  = hole == match.startHole && !holeScored
          ? 'Callable once a hole in this match has been decided — there is '
            'nothing to trail after on the first tee.'
          : 'The match is all square. Only the side that is DOWN may press.';
    } else if (mine) {
      title = 'Call your press — covers $covers';
      body  = 'A new bet at \$${match.bets.first.amount.toStringAsFixed(0)} a '
              'man over the holes left. It settles on its own.';
    } else {
      // One phone scores the group, so the button belongs to the TRAILING
      // side rather than to whoever is holding it. Gating it on the reader
      // put the press out of reach exactly when it was wanted: the man who is
      // UP in the match is usually the one keeping the card.
      title = 'Press for $down — covers $covers';
      body  = 'They are down, so the press is theirs. Tap to call it for '
              'them at \$${match.bets.first.amount.toStringAsFixed(0)} a man '
              'over the holes left.';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: legal ? _kAmberBg : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: legal ? () => onCall(trailing) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(
                  color: legal
                      ? _kAmberBorder : theme.colorScheme.outlineVariant,
                  width: 1.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: legal ? _kAmberInk : theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(5),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.trending_up,
                        size: 15, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold,
                          color: legal
                              ? _kAmberInk
                              : theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 1),
                  Text(body,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35)),
                ]),
              ),
            ]),
          ),
        ),
      ),
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
    final d = holeData;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text('Hole $holeNumber',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        if (d != null)
          Text('Par ${d.par}'
               '${d.yards != null ? '  ·  ${d.yards} yds' : ''}'
               '  ·  SI ${d.strokeIndex}',
              style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

// ===========================================================================
// One side of the match — its two golfers and their score boxes
// ===========================================================================

class _PairCard extends StatelessWidget {
  final String            label;
  final Color             colour;
  final List<SequoyaSide> side;
  final List<Membership>  players;
  final ScorecardHole?    holeData;
  final Map<int, int>     scores;
  final int               par;
  final SequoyaThreesSummary? summary;
  final int?              hotSpotId;
  final int?              editingPlayerId;
  final Membership? Function(int playerId) memberFor;
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership) onEditTap;
  final bool                 spotsActive;
  final int Function(int)    spotsCountFor;
  final void Function(int)   onSpotsAdd;
  final void Function(int)   onSpotsRemove;

  const _PairCard({
    required this.label, required this.colour, required this.side,
    required this.players, required this.holeData, required this.scores,
    required this.par, required this.summary, required this.hotSpotId,
    required this.editingPlayerId, required this.memberFor,
    required this.onScoreSelected, required this.onEditTap,
    required this.spotsActive, required this.spotsCountFor,
    required this.onSpotsAdd, required this.onSpotsRemove,
  });

  String get _mode       => summary?.handicapMode ?? 'net';
  int    get _netPercent => summary?.netPercent   ?? 100;

  int? get _lowPlaying {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  /// Sequoya allocates by the FULL course stroke index — never spread across
  /// the six matches — so this is a plain full-round allocation and matches
  /// what `services/sequoya_threes._net_by_hole` does.
  int _strokesForHole(Membership m) {
    final h = holeData;
    if (h == null || _mode == 'gross') return 0;
    final entry = h.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? h.strokeIndex;
    if (_mode == 'net') {
      if (_netPercent == 100 && entry != null) return entry.handicapStrokes;
      final eff = roundHalfUp(m.playingHandicap * _netPercent / 100.0);
      return strokesOnHole(eff, mySi);
    }
    final low = _lowPlaying;
    if (low == null) return 0;
    final so = roundHalfUp((m.playingHandicap - low) * _netPercent / 100.0);
    if (so <= 0) return 0;
    return strokesOnHole(so, mySi);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colour.withOpacity(0.10),
            border: Border(left: BorderSide(color: colour, width: 4)),
            borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(7), topRight: Radius.circular(7)),
          ),
          child: Text(
            '${label.toUpperCase()}  ·  '
            '${side.map((s) => s.shortName).join(' & ')}',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.bold,
                letterSpacing: 0.4, color: colour),
          ),
        ),
        for (final s in side) ..._rows(context, s),
      ]),
    );
  }

  List<Widget> _rows(BuildContext context, SequoyaSide s) {
    final m = memberFor(s.playerId);
    if (m == null) return const [];
    final gross   = scores[s.playerId];
    final isHot   = hotSpotId == s.playerId;
    final editing = editingPlayerId == s.playerId;
    final strokes = _strokesForHole(m);
    final row = _ScoreRow(
      member:   m,
      gross:    gross,
      strokes:  strokes,
      showHcap: _mode != 'gross',
      hcap: effectiveMatchHandicap(
          mode: _mode, netPercent: _netPercent,
          playingHandicap: m.playingHandicap,
          lowestPlayingHandicap: _lowPlaying),
      isHot:    isHot,
      colour:   colour,
      onTap: (gross != null && !isHot) ? () => onEditTap(m) : null,
      spotsActive:   spotsActive,
      spotsCount:    spotsActive ? spotsCountFor(s.playerId) : 0,
      onSpotsAdd:    spotsActive ? () => onSpotsAdd(s.playerId) : null,
      onSpotsRemove: spotsActive ? () => onSpotsRemove(s.playerId) : null,
    );
    if (!isHot && !editing) return [row];
    return [
      Container(
        margin: const EdgeInsets.fromLTRB(0, 6, 8, 6),
        decoration: BoxDecoration(
          color: colour.withOpacity(0.08),
          border: Border(
            top:    BorderSide(color: colour, width: 1.5),
            bottom: BorderSide(color: colour, width: 1.5),
            right:  BorderSide(color: colour, width: 1.5),
            left:   BorderSide(color: colour, width: 4.0),
          ),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          row,
          InlineScorePicker(
            par: par, strokes: strokes, currentScore: gross,
            boxBorderColor: colour,
            boxFillColor:   Colors.white,
            onScoreSelected: (v) => onScoreSelected(m, v),
          ),
        ]),
      ),
    ];
  }
}

class _ScoreRow extends StatelessWidget {
  final Membership member;
  final int?       gross;
  final int        strokes;
  final bool       showHcap;
  final int        hcap;
  final bool       isHot;
  final Color      colour;
  final VoidCallback? onTap;
  final bool          spotsActive;
  final int           spotsCount;
  final VoidCallback? onSpotsAdd;
  final VoidCallback? onSpotsRemove;

  const _ScoreRow({
    required this.member, required this.gross, required this.strokes,
    required this.showHcap, required this.hcap, required this.isHot,
    required this.colour, this.onTap,
    this.spotsActive = false, this.spotsCount = 0,
    this.onSpotsAdd, this.onSpotsRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(member.player.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (showHcap) ...[
                  const SizedBox(width: 8),
                  Text('$hcap',
                      style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurfaceVariant)),
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
            ]),
          ),
          const SizedBox(width: 8),
          // Stroke dots sit above the box, as on every other score screen, so
          // a net or strokes-off golfer can see where the strokes fall.
          scoreCellWithDots(
            Container(
              width: 40, height: 36,
              decoration: BoxDecoration(
                color: isHot ? colour.withOpacity(0.10) : null,
                border: Border.all(
                    color: isHot ? colour : theme.colorScheme.outline,
                    width: isHot ? 2 : 1),
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
            colour,
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// The six matches at a glance — where the rotation becomes visible
// ===========================================================================

class _MatchStrip extends StatelessWidget {
  final SequoyaThreesSummary summary;
  final int currentHole;
  final void Function(SequoyaMatch) onTapMatch;

  const _MatchStrip({
    required this.summary, required this.currentHole, required this.onTapMatch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text('THE SIX MATCHES',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.bold,
                  letterSpacing: 0.5, color: theme.colorScheme.primary)),
        ),
        for (final m in summary.matches)
          InkWell(
            onTap: () => onTapMatch(m),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              color: m.covers(currentHole)
                  ? theme.colorScheme.primary.withOpacity(0.06)
                  : null,
              child: Row(children: [
                SizedBox(
                  width: 52,
                  child: Text('${m.startHole}–${m.endHole}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: Text(
                    '${m.side1.map((s) => s.shortName).join(' & ')}'
                    '  v  '
                    '${m.side2.map((s) => s.shortName).join(' & ')}',
                    style: const TextStyle(fontSize: 12.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  m.bets.isEmpty ? '—' : betState(m.bets.first),
                  style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold,
                    color: m.bets.isEmpty || m.bets.first.margin == 0
                        ? theme.colorScheme.onSurfaceVariant
                        : (m.bets.first.margin > 0 ? _kBlue : _kOrange),
                  ),
                ),
                if (m.bets.length > 1) ...[
                  const SizedBox(width: 6),
                  Text('+${m.bets.length - 1}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ]),
            ),
          ),
      ]),
    );
  }
}

// ===========================================================================
// Money — the four nets, in money order
// ===========================================================================

class _MoneyCard extends StatelessWidget {
  final SequoyaThreesSummary summary;
  const _MoneyCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('MONEY',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.bold,
                  letterSpacing: 0.5, color: theme.colorScheme.primary)),
          const SizedBox(height: 6),
          for (final p in summary.players)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(
                  child: Text(p.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(p.recordLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(width: 14),
                SizedBox(
                  width: 74,
                  child: Text(_fmtMoney(p.money),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: p.money > 0
                            ? Colors.green.shade700
                            : p.money < 0
                                ? Colors.red.shade700
                                : theme.colorScheme.onSurfaceVariant,
                      )),
                ),
              ]),
            ),
          if (summary.transfers.isNotEmpty) ...[
            const Divider(height: 20),
            for (final t in summary.transfers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text(
                  '${t.fromName} pays ${t.toName} '
                  '\$${t.amount.toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            'Ceiling: \$${summary.exposureCeiling.toStringAsFixed(0)} a man — '
            'all six matches lost with every bet live.',
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}
