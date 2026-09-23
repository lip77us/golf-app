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
import '../widgets/hole_grid_scorecard.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/net_score_button.dart' show scoreCellWithDots;
import '../utils/sequoya_standing.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/standing_ribbon.dart';
import '../widgets/spots_capture.dart';
import '../utils/match_handicap.dart';
import '../utils/play_order.dart';
import '../utils/round_complete.dart';
import '../widgets/combo_tee_chip.dart';

const Color _kBlue   = Color(0xFF1976D2);   // side 1 of match 1 — "Team A"
const Color _kOrange = Color(0xFFEF6C00);   // side 2

// `_fmtMoney` and `_dollars` went with `_MoneyCard`, which was their only
// reader. The standing row formats its own figure, in the same
// whole-dollars-unless-there-are-pennies shape.

/// How a bet reads on the banner. Never a multiplier, and never "DORMIE"
/// unless the lead EQUALS the holes left — 1 up with 2 to play is not it.
///
/// A close-out is read off the hole it CLOSED ON, not off `to_play`. In this
/// game the holes after a close-out are usually still played — the press is
/// running over them — so the match bet's margin keeps moving and `to_play`
/// falls to zero. Reading either would turn a 2 & 1 into "1 up".
String betState(SequoyaBet b) {
  if (b.result == 0) return 'Halved';
  if (b.result != null) {
    final closed = b.closedOn;
    if (closed != null) {
      final left = b.holes.length - b.holes.indexOf(closed) - 1;
      // The margin crosses the holes left by exactly one, so the winning
      // margin at the close-out is always `left + 1`.
      if (left > 0) return '${left + 1} & $left';
    }
    return '${b.margin.abs()} up · final';
  }
  if (b.margin == 0) return 'All square';
  if (b.margin.abs() == b.toPlay) return 'Dormie';
  return '${b.margin.abs()} up';
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

  /// The next golfer to score, in the order the screen draws them.
  int? _hotSpotId(List<int> displayOrder, Map<int, int> scores) {
    for (final pid in displayOrder) {
      if (!scores.containsKey(pid)) return pid;
    }
    return null;
  }

  /// player id → which side he is on FOR THIS MATCH. The rows stay in one
  /// order all round and the SIDE moves under them, which is the whole point:
  /// re-sorting four golfers every third hole means hunting for your own name
  /// on every fourth green.
  Map<int, int> _sideOf(SequoyaMatch match) => {
        for (final p in match.side1) p.playerId: 1,
        for (final p in match.side2) p.playerId: 2,
      };

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

  /// Take back a press called by mistake. Refused server-side once a hole it
  /// covers has been played — the tap was free, the bet is not.
  Future<void> _removePress(SequoyaMatch match) async {
    setState(() => _pressing = true);
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;
      final s = await client.postSequoyaThreesPressRemove(
          widget.foursomeId, matchIndex: match.index);
      if (!mounted) return;
      rp.setSequoyaThreesSummary(s);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Press taken back.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _pressing = false);
    }
  }

  // --- build -------------------------------------------------------------

  /// **It reuses `betState`, it does not restate it.** The six-match strip
  /// below already writes a Sequoya bet NEUTRALLY — `2 up`, never `2 down` —
  /// with the colour naming the leading side, which is the division Nassau had
  /// to be corrected into and which this screen had right already.
  ///
  /// The colour is safe here and is not safe in Sixes, although both re-draw
  /// their pairings: **this row always reports the match the screen is
  /// showing**, and the player rows under it are tinted side 1 blue and side 2
  /// orange for that same match. Sixes' problem is the hole AFTER a segment
  /// concludes, where the rows have re-drawn and the standing has not; a
  /// Sequoya match runs to its last hole even when it was decided early, so
  /// the two change together.
  StandingRibbon? _standingRibbon(RoundProvider rp) {
    final round = rp.round;
    if (round == null || !round.isCasual) return null;
    final me = context.read<AuthProvider>().player?.id;
    final standing = sequoyaStanding(
      rp.sequoyaThreesSummary, me,
      hole: _selectedHole,
      betState: betState,
    );
    if (standing == null) return null;
    return StandingRibbon(
      kind: StandingKind.result,
      standingLabel: standing.label,
      standing: standing.standing,
      standingColor: switch (standing.leader) {
        1 => _kBlue,
        2 => _kOrange,
        _ => null,
      },
      figure: standing.figure,
      onOpenLeaderboard: () => Navigator.of(context)
          .pushNamed('/leaderboard', arguments: round.id),
    );
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
        if (mounted) {
          context.read<RoundProvider>().loadSequoyaThrees(widget.foursomeId);
        }
      });
    }
    _prevHadPending = nowHasPending;

    final isCasualSingle = (rp.round?.isCasual ?? false) &&
        (rp.round?.foursomes.length ?? 1) == 1;
    final showExit = isCasualSingle && _hasAnyScore;

    final ribbon = _standingRibbon(rp);

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Sequoya 3s',
        // D2: the standing becomes the bar's second line, and the pill in it
        // replaces the leaderboard ICON below.
        bottom: ribbon,
        titleStyle: ribbon == null
            ? null
            : const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
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
          // The named pill in the ribbon is this, done properly — so the icon
          // stands down wherever the ribbon draws.
          if (ribbon == null)
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
              if (v == 'settle') {
                Navigator.of(context).pushNamed('/sequoya-threes-settlement',
                    arguments: widget.foursomeId);
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
                value: 'settle',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.receipt_long_outlined),
                  title: Text('Settle up'),
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
    // Roster order, the same order the scorecard grid draws — score entry and
    // the card must never disagree about who is who.
    final displayOrder = players.map((m) => m.player.id).toList();
    final hotSpotId = isComplete ? null : _hotSpotId(displayOrder, scores);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          // `_BetBanner` was here — `Match 3 · holes 7–9`, a bet count, and a
          // row per bet. **Removed 22 Sep 2026.** The standing row in the app
          // bar names the match and states it, in the screen's own `betState`
          // words and the screen's own side colour.
          //
          // **What went with it: the per-PRESS stake and state.** A match's
          // own bet is what the row reports; presses are extra and there can
          // be several. With the six-match strip gone too, the only press
          // affordance left on this screen is the control that CALLS one —
          // what is riding on the presses already called reads on the
          // leaderboard's Matches pane.
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
              onUndo: () => _removePress(match),
            ),
          _HoleHeader(holeNumber: _selectedHole, holeData: holeData),
          const SizedBox(height: 12),
          if (match == null)
            const InlineMessage(
              kind: InlineMessageKind.info,
              text: 'Set the game up to see this hole’s match.',
            )
          else
            _HoleScoreCard(
              players:    players,
              sideOf:     _sideOf(match),
              holeData:   holeData,
              scores:     scores,
              par:        par,
              summary:    summary,
              hotSpotId:  hotSpotId,
              editingPlayerId: _editingPlayerId,
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
          const SizedBox(height: 6),
          // The Sixes card. Above the match list on purpose: it answers what
          // was SHOT, which is the question the group asks while the hole is
          // still fresh; the match list answers what that did to the money.
          if (summary != null && summary.cardHoles.isNotEmpty) ...[
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: Theme.of(ctx).colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: HoleGridScorecard(
                  holes:        summary.cardHoles,
                  participants: summary.cardPlayers,
                  holesInPlay:  summary.cardHolesInPlay,
                  legend: 'blue / orange = the side that won the hole',
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // `_MatchStrip` (`THE SIX MATCHES`) and `_MoneyCard` were here.
          // **Removed 22 Sep 2026** — both are the leaderboard's, which
          // carries them as its two panes, Matches and Standings.
          //
          // The strip's tap-a-match-to-jump went with it; the hole nav at the
          // bottom is the way between matches now.
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

// `_BetBanner` was here — the match header and one row per bet. It came
// off with its call site on 22 Sep 2026; the standing row in the app bar
// names the match and states it. See the note at the call site for what
// went with it.

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
  final VoidCallback onUndo;

  const _PressOffer({
    required this.match, required this.hole, required this.busy,
    required this.holeScored,
    required this.mySide, required this.onCall, required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manual   = match.bets
        .where((b) => b.kind == 'manual_press').firstOrNull;
    final already  = manual != null;
    // Undoable only while NOTHING it covers has been played. The tap was
    // free; the bet is not, and a bet the group has played is a settlement
    // question rather than an undo. (`toPlay` counts the holes still to come,
    // so equal to its whole range means it has not started.)
    final removable = manual != null &&
        manual.isLive && manual.toPlay == manual.holes.length && !busy;
    final headBet  = match.bets.isEmpty ? null : match.bets.first;
    final trailing = (headBet == null || headBet.margin == 0)
        ? null
        : (headBet.margin > 0 ? 2 : 1);
    final start    = holeScored ? hole + 1 : hole;
    final roomLeft = start <= match.endHole;
    final mine     = mySide != null && mySide == trailing;
    final covers   = start == match.endHole
        ? 'hole $start' : 'holes $start–${match.endHole}';
    final down     = trailing == null
        ? ''
        : (trailing == 1 ? match.side1 : match.side2)
            .map((p) => p.shortName).join(' & ');

    // A live bet a press would merely REPEAT: level, with exactly the holes
    // the press would cover still to play. Two level bets over one set of
    // holes settle identically, which is a double rather than a press — and
    // that, not the mere existence of an auto press, is what a press is
    // refused for. A bet carrying a MARGIN is not a twin, which is why the
    // last hole of a match can be pressed after losing the first two.
    //
    // Which bet it is changes as the match runs: on the second hole it is the
    // auto press, on the last hole of a level match the match bet itself.
    final covered = match.endHole - start + 1;
    final twin = match.bets
        .where((b) => b.isLive && b.margin == 0 && b.toPlay == covered)
        .firstOrNull;
    final legal    = !already && twin == null && roomLeft
                     && trailing != null && !busy;

    // **No card unless there is something to do.** A press that cannot be
    // called is not an offer, and rendering one greyed out read as being asked
    // to press and then told no — on the second hole of every match whose first
    // hole was won, which is most of them. The states that used to print here
    // (an auto press already covering these holes, nothing decided yet, the
    // match all square, no holes left) all resolve on their own as the match
    // runs, and the banner above already lists every live bet.
    if (!legal && !already) return const SizedBox.shrink();

    final String title;
    final String body;
    if (already) {
      // A press in play is a STATE, not a refusal. "Press already called in
      // this match" read like an error for something the group had just
      // deliberately done.
      final who = manual.calledBy == null ? '' : 'Called by ${manual.calledBy}. ';
      title = 'Press in play on ${manual.holeRange}';
      body  = removable
          ? '${who}Nothing has been played on it yet, so a mis-tap can still '
            'be taken back.'
          : '${who}A bet the group has played cannot be taken back.';
    } else {
      // **The card names the side and wears its colour.** Amber said only
      // "something is on offer" — and being orange-ish, it read as the ORANGE
      // side's, which is a coin-flip lie. A press belongs to exactly one pair
      // and the card should be unmistakable about which.
      //
      // One phone scores the group, so the button is the trailing side's
      // rather than the holder's: the man who is UP in the match is usually
      // the one keeping the card.
      final lead = headBet!.margin.abs();
      final left = headBet.toPlay;
      final state = lead == left
          ? 'Dormie — down $lead with $left to play'
          : 'Down $lead with $left to play';
      title = '$down can press — covers $covers';
      body  = '$state. '
              '${mine ? 'Yours to call' : 'Tap to call it for them'}: a new bet '
              'at \$${match.bets.first.amount.toStringAsFixed(0)} per golfer '
              'over the holes left, settling on its own.';
    }

    // Blue or orange — the colour of whoever the card is ABOUT, so it can be
    // matched against the score rows without reading a word: the side that
    // may call a press, or the side whose press is already running.
    final owner = already ? manual.calledSide : trailing;
    final side  = owner == 2 ? _kOrange : _kBlue;
    // Colour it for a live press as well as for an offer — both belong to a
    // side. The other refusals belong to nobody, and stay grey.
    final owned = legal || (already && owner != null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: owned
            ? side.withOpacity(0.10)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: legal ? () => onCall(trailing) : null,
          child: Container(
            padding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
            decoration: BoxDecoration(
              border: Border.all(
                  color: owned ? side : theme.colorScheme.outlineVariant,
                  width: 1.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              // The same side bar the score rows carry.
              Container(
                width: 5, height: 40,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: owned ? side : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(3)),
                ),
              ),
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: owned ? side : theme.colorScheme.outlineVariant,
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
                          color: owned
                              ? side
                              : theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 1),
                  Text(body,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35)),
                ]),
              ),
              if (removable) ...[
                const SizedBox(width: 6),
                TextButton(
                  onPressed: onUndo,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('Take it back'),
                ),
              ],
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

/// The four golfers in ONE stable order, each row carrying the colour of the
/// side he is on for this match.
///
/// **The rows never re-sort.** The pairing rotates every third hole, and
/// re-grouping the card to match it means hunting for your own name on every
/// fourth green — Sixes doesn't do it either. The colour moves instead: a bar
/// down the left of each row, so partners are the two rows sharing a colour.
class _HoleScoreCard extends StatelessWidget {
  final List<Membership>  players;
  final Map<int, int>     sideOf;
  final ScorecardHole?    holeData;
  final Map<int, int>     scores;
  final int               par;
  final SequoyaThreesSummary? summary;
  final int?              hotSpotId;
  final int?              editingPlayerId;
  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership) onEditTap;
  final bool                 spotsActive;
  final int Function(int)    spotsCountFor;
  final void Function(int)   onSpotsAdd;
  final void Function(int)   onSpotsRemove;

  const _HoleScoreCard({
    required this.players, required this.sideOf, required this.holeData,
    required this.scores, required this.par, required this.summary,
    required this.hotSpotId, required this.editingPlayerId,
    required this.onScoreSelected, required this.onEditTap,
    required this.spotsActive, required this.spotsCountFor,
    required this.onSpotsAdd, required this.onSpotsRemove,
  });

  String get _mode       => summary?.handicapMode ?? 'net';
  int    get _netPercent => summary?.netPercent   ?? 100;

  Color _colourFor(int playerId) =>
      sideOf[playerId] == 2 ? _kOrange : _kBlue;

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

  /// `Paul & AB  v  Aldo & AP`, each pair in its own colour — the pairing
  /// stated once, in words, so the bars below have something to mean.
  Widget _pairingLine(ThemeData theme) {
    String names(int side) => players
        .where((m) => sideOf[m.player.id] == side)
        .map((m) => m.player.displayShort)
        .join(' & ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(children: [
        Expanded(
          child: Text(names(1),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: _kBlue)),
        ),
        Text('v', style: theme.textTheme.labelSmall),
        Expanded(
          child: Text(names(2),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: _kOrange)),
        ),
      ]),
    );
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
        _pairingLine(theme),
        const Divider(height: 1),
        for (final m in players) ..._rows(context, m),
      ]),
    );
  }

  List<Widget> _rows(BuildContext context, Membership m) {
    final pid     = m.player.id;
    final colour  = _colourFor(pid);
    final gross   = scores[pid];
    final isHot   = hotSpotId == pid;
    final editing = editingPlayerId == pid;
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
      spotsCount:    spotsActive ? spotsCountFor(pid) : 0,
      onSpotsAdd:    spotsActive ? () => onSpotsAdd(pid) : null,
      onSpotsRemove: spotsActive ? () => onSpotsRemove(pid) : null,
      comboTee: m.comboTeeOnHole(holeData?.holeNumber ?? 0),
    );
    if (!isHot && !editing) return [row];
    return [
      Container(
        margin: const EdgeInsets.fromLTRB(0, 4, 8, 4),
        decoration: BoxDecoration(
          color: colour.withOpacity(0.08),
          border: Border(
            top:    BorderSide(color: colour, width: 1.5),
            bottom: BorderSide(color: colour, width: 1.5),
            right:  BorderSide(color: colour, width: 1.5),
            left:   BorderSide(color: colour, width: 5.0),
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
  /// This golfer's tee for the hole being entered — combo sets only.
  final String?       comboTee;

  const _ScoreRow({
    required this.member, required this.gross, required this.strokes,
    required this.showHcap, required this.hcap, required this.isHot,
    required this.colour, this.onTap,
    this.spotsActive = false, this.spotsCount = 0,
    this.onSpotsAdd, this.onSpotsRemove, this.comboTee,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 9, 12, 9),
        child: Row(children: [
          // The side bar. Not a label — a label would have to be read, and
          // this only has to be matched against the row above or below.
          // Suppressed inside the active row's box, which is already ruled in
          // the same colour on all four sides.
          Container(
            width: 5, height: 34,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: isHot ? Colors.transparent : colour,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
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
                // Which tee he plays on THIS hole, combo sets only.
                ComboTeeChip(tee: comboTee),
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

// `_MatchStrip` was here — `THE SIX MATCHES`, one row each with its hole
// range, its sides and its state. It is the leaderboard's Matches pane.
//
// The standing row reuses this widget's `betState`, which is why that
// function is still here and is still the one definition of how a Sequoya
// bet is written.

// ===========================================================================
// Money — the four nets, in money order
// ===========================================================================

// `_MoneyCard` was here — the per-player running money. It is the
// leaderboard's Standings pane, and the reader's own figure now rides in
// the standing row at the top of this screen.
