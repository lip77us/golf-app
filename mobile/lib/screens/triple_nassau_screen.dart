/// screens/triple_nassau_screen.dart
/// ----------------------------------
/// Play screen for Triple Nassau — three players, three simultaneous 1v1
/// Nassaus (a round-robin).  Pure gross score entry plus a live read-out of the
/// three matches:
///   • Roster banner — Paul v Dave v Sam (colour = identity).
///   • Score card — each player's gross, with TWO sets of handicap dots (one
///     per match they're in) and the net for the LEFT match (vs the lowest-
///     index player).
///   • This-hole outcomes — one hole, three pairwise results.
///   • 3×3 matrix — each match's Front 9 / Back 9 / Overall bet.
///   • Call Press — a per-match press sheet.
///
/// Scores post through the shared RoundProvider; the TripleNassauSummary is
/// refreshed after every save.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/round_chat_button.dart';
import '../utils/play_order.dart';
import '../utils/round_complete.dart';

const List<Color> _kNc = [Color(0xFF1976D2), Color(0xFFEF6C00), Color(0xFF7B3FA0)];
const Color _muted = Color(0xFF5C6B62);

String _fmtMoney(double v) {
  if (v == 0) return '\$0.00';
  return v > 0 ? '+\$${v.toStringAsFixed(2)}' : '−\$${v.abs().toStringAsFixed(2)}';
}

class TripleNassauScreen extends StatefulWidget {
  final int foursomeId;
  const TripleNassauScreen({super.key, required this.foursomeId});

  @override
  State<TripleNassauScreen> createState() => _TripleNassauScreenState();
}

class _TripleNassauScreenState extends State<TripleNassauScreen> {
  final Map<int, Map<int, int>> _pending = {};
  int  _selectedHole    = 1;
  bool _prevHadPending  = false;
  bool _initialJumpDone = false;
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
      rp.loadTripleNassau(widget.foursomeId);
    });
  }

  Future<void> _refresh() async {
    final rp = context.read<RoundProvider>();
    await rp.loadScorecard(widget.foursomeId);
    rp.loadTripleNassau(widget.foursomeId);
  }

  // ── Roster (display order = summary player_order when available) ────────────

  List<Membership> _realMembers(RoundProvider rp) {
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId).firstOrNull;
    if (fs == null) return const [];
    final members = fs.memberships.where((m) => !m.player.isPhantom).toList();
    final order = rp.tripleNassauSummary?.players.map((p) => p.playerId).toList();
    if (order != null && order.length == members.length) {
      members.sort((a, b) =>
          order.indexOf(a.player.id).compareTo(order.indexOf(b.player.id)));
    }
    return members;
  }

  Color _colourFor(RoundProvider rp, int pid) {
    final players = rp.tripleNassauSummary?.players ?? const [];
    final i = players.indexWhere((p) => p.playerId == pid);
    if (i >= 0) return _kNc[i % 3];
    final m = _realMembers(rp);
    final j = m.indexWhere((x) => x.player.id == pid);
    return _kNc[(j < 0 ? 0 : j) % 3];
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

  bool get _hasAnyScore {
    if (_pending.isNotEmpty) return true;
    final rp = context.read<RoundProvider>();
    final sc = rp.scorecard;
    if (sc != null) {
      for (int h = 1; h <= 18; h++) {
        if (_effectiveScores(sc, h).isNotEmpty) return true;
      }
    }
    return false;
  }

  // ── Pairwise stroke maths (client-side; matches _build_pair_so_index) ───────

  int _pairStrokes(Membership higher, Membership lower, int si, String mode,
      int netPct) {
    if (mode == 'gross') return 0;
    final diff = higher.playingHandicap - lower.playingHandicap;
    if (diff <= 0) return 0;
    final so = (diff * netPct / 100).round();
    return (so ~/ 18) + (si <= (so % 18) ? 1 : 0);
  }

  // ── Score entry ────────────────────────────────────────────────────────────

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
    final rp = context.read<RoundProvider>();
    final sc = rp.scorecard;
    final hole = _selectedHole;
    final wasAll = sc != null && _allScored(players, _effectiveScores(sc, hole));
    _selectScore(m, score, hole);
    if (sc == null || score <= 0) return;
    if (wasAll) {
      setState(() => _editingPlayerId = null);
      _saveHole(ctx, hole, players);
      return;
    }
    if (!context.read<SettingsProvider>().autoAdvanceHole) return;
    if (!_allScored(players, _effectiveScores(sc, hole))) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedHole != hole) return;
      if (context.read<RoundProvider>().submitting) return;
      _saveAndAdvance(ctx, players);
    });
  }

  List<int> _playOrder(RoundProvider rp) => roundPlayOrder(rp.round, rp.scorecard);

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = _realMembers(rp).map((m) => m.player.id).toSet();
    for (final h in _playOrder(rp)) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      final done = hd.scores
          .where((s) => realIds.contains(s.playerId))
          .every((s) => s.grossScore != null);
      if (!done && !rp.localPendingByHole.containsKey(h)) {
        setState(() => _selectedHole = h);
        return;
      }
    }
    final order = _playOrder(rp);
    setState(() => _selectedHole = order.isEmpty ? 18 : order.last);
  }

  void _advance() {
    final n = nextInOrder(_playOrder(context.read<RoundProvider>()), _selectedHole);
    if (n != null) setState(() { _selectedHole = n; _editingPlayerId = null; });
  }

  void _retreat() {
    final p = prevInOrder(_playOrder(context.read<RoundProvider>()), _selectedHole);
    if (p != null) setState(() { _selectedHole = p; _editingPlayerId = null; });
  }

  Future<void> _saveHole(BuildContext ctx, int hole, List<Membership> players) async {
    final edits = _pending[hole];
    if (edits == null || edits.isEmpty) return;
    final scores = edits.entries
        .map((e) => {'player_id': e.key, 'gross_score': e.value}).toList();
    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
        foursomeId: widget.foursomeId, holeNumber: hole, scores: scores);
    if (!mounted) return;
    if (!ok) { _snack(ctx, rp.error ?? 'Failed to save hole.',
        () => _saveHole(ctx, hole, players)); return; }
    setState(() => _pending.remove(hole));
    rp.loadTripleNassau(widget.foursomeId);
  }

  Future<void> _saveAndAdvance(BuildContext ctx, List<Membership> players) async {
    final hole = _selectedHole;
    if (_pending[hole]?.isNotEmpty ?? false) {
      await _saveHole(ctx, hole, players);
      if (!mounted || _pending.containsKey(hole)) return;
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
    final pend = _pending[_selectedHole];
    if (pend != null && pend.isNotEmpty) {
      final scores = pend.entries
          .map((e) => {'player_id': e.key, 'gross_score': e.value}).toList();
      final ok = await rp.submitHole(
          foursomeId: widget.foursomeId, holeNumber: _selectedHole, scores: scores);
      if (!mounted) return;
      if (!ok) { _snack(ctx, rp.error ?? 'Failed to save hole.',
          () => _finishRound(ctx, players)); return; }
      setState(() => _pending.remove(_selectedHole));
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

  // ── Call Press ─────────────────────────────────────────────────────────────

  Future<void> _openPressSheet(
      BuildContext ctx, TripleNassauSummary s, List<Membership> members) async {
    await showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PressSheet(
        summary: s,
        selectedHole: _selectedHole,
        colourFor: (pid) => _colourFor(context.read<RoundProvider>(), pid),
        shortFor: (pid) => members
            .firstWhere((m) => m.player.id == pid,
                orElse: () => members.first)
            .player.shortName,
        onPress: (gameType, startHole) async {
          final rp = context.read<RoundProvider>();
          final client = context.read<AuthProvider>().client;
          try {
            final updated = await client.postTripleNassauPress(
                widget.foursomeId, gameType: gameType, startHole: startHole);
            rp.setTripleNassauSummary(updated);
            if (mounted) Navigator.of(ctx).pop();
          } catch (e) {
            if (mounted) {
              Navigator.of(ctx).pop();
              _snack(ctx, e.toString(), () {});
            }
          }
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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
    final nowPending = sync.hasPending;
    if (_prevHadPending && !nowPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadTripleNassau(widget.foursomeId);
      });
    }
    _prevHadPending = nowPending;

    final isCasualSingle = (rp.round?.isCasual ?? false) &&
        (rp.round?.foursomes.length ?? 1) == 1;
    final showExit = isCasualSingle && _hasAnyScore;

    final modeStr = rp.tripleNassauSummary == null
        ? '' : ' — ${_modeLabel(rp.tripleNassauSummary!)}';

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Triple Nassau$modeStr',
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
          if (rp.round != null) RoundChatButton(roundId: rp.round!.id),
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
      bottomNavigationBar: sc == null ? null : _buildBottomNav(context, rp),
    );
  }

  String _modeLabel(TripleNassauSummary s) {
    switch (s.handicapMode) {
      case 'gross': return 'Gross';
      case 'strokes_off':
        return s.netPercent == 100 ? 'SO Low' : 'SO Low ${s.netPercent}%';
      default:
        return s.netPercent == 100 ? 'Net' : 'Net ${s.netPercent}%';
    }
  }

  Widget _buildBody(BuildContext ctx, RoundProvider rp, bool isComplete) {
    if (rp.loadingScorecard && rp.scorecard == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final sc = rp.scorecard;
    if (sc == null) {
      if (rp.error != null) {
        return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          InlineMessage(kind: InlineMessageKind.error, text: rp.error!),
          const SizedBox(height: 8),
          FilledButton(onPressed: _refresh, child: const Text('Retry')),
        ]));
      }
      return const SizedBox.shrink();
    }

    final s        = rp.tripleNassauSummary;
    final players  = _realMembers(rp);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);

    // Lowest-index player = the group "best player"; the LEFT match is always
    // against them (so the left dot column is consistent for everyone).
    Membership? low;
    for (final m in players) {
      if (low == null || m.playingHandicap < low.playingHandicap) low = m;
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _rosterBanner(rp, players),
          const SizedBox(height: 10),
          _holeHeader(holeData),
          const SizedBox(height: 10),
          _scoreCard(ctx, rp, s, players, low, holeData, scores, hotSpot),
          if (s != null) ...[
            const SizedBox(height: 12),
            if (_pressableMatches(s).isNotEmpty && !isComplete) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => _openPressSheet(ctx, s, players),
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  label: const Text('Call Press'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _matrix(rp, s, players),
            const SizedBox(height: 12),
            _netPosition(rp, s),
          ],
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _rosterBanner(RoundProvider rp, List<Membership> players) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
          color: const Color(0xFFE1EAE2), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        for (var i = 0; i < players.length; i++) ...[
          if (i > 0) const Text(' v ',
              style: TextStyle(color: _muted, fontSize: 11)),
          _dot(_colourFor(rp, players[i].player.id)),
          const SizedBox(width: 4),
          Text(players[i].player.shortName, style: TextStyle(
              fontWeight: FontWeight.w700, fontSize: 13,
              color: _colourFor(rp, players[i].player.id))),
        ],
        const Spacer(),
        const Text('3 matches',
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: _muted)),
      ]),
    );
  }

  Widget _holeHeader(ScorecardHole? h) {
    final par = h?.par ?? 4;
    final si  = h?.strokeIndex;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
          color: const Color(0xFFE1EAE2), borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Text('Hole $_selectedHole', style: const TextStyle(
            fontWeight: FontWeight.w700, fontSize: 18)),
        Text('Par $par${si != null ? '  ·  SI $si' : ''}',
            style: const TextStyle(fontSize: 12, color: _muted)),
      ]),
    );
  }

  Widget _scoreCard(BuildContext ctx, RoundProvider rp, TripleNassauSummary? s,
      List<Membership> players, Membership? low, ScorecardHole? holeData,
      Map<int, int> scores, int hotSpot) {
    final theme = Theme.of(context);
    final mode  = s?.handicapMode ?? 'net';
    final netPct = s?.netPercent ?? 100;
    final si = holeData?.strokeIndex ?? 18;

    List<Widget> rows = [];
    for (var i = 0; i < players.length; i++) {
      final m = players[i];
      final pid = m.player.id;
      final gross = scores[pid];
      final isHot = i == hotSpot;
      final isEditing = _editingPlayerId == pid;

      // Left opponent = lowest-index player (or, for the low player, the next).
      final others = players.where((x) => x.player.id != pid).toList();
      Membership leftOpp = (low != null && low.player.id != pid)
          ? low
          : (others.isNotEmpty ? others.reduce((a, b) =>
              a.playingHandicap <= b.playingHandicap ? a : b) : m);
      Membership rightOpp = others.firstWhere(
          (x) => x.player.id != leftOpp.player.id,
          orElse: () => leftOpp);

      final leftStrokes  = _pairStrokes(m, leftOpp, si, mode, netPct);
      final rightStrokes = _pairStrokes(m, rightOpp, si, mode, netPct);
      final net = gross != null ? gross - leftStrokes : null;
      final colour = _colourFor(rp, pid);

      final row = InkWell(
        onTap: (gross != null && !isHot)
            ? () => setState(() => _editingPlayerId = isEditing ? null : pid)
            : null,
        child: Container(
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.06),
            border: Border(left: BorderSide(color: colour, width: 4)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Row(children: [
            Expanded(child: Text(m.player.shortName, style: TextStyle(
                fontWeight: FontWeight.w700, color: colour))),
            // Left dots (vs lowest-index) · box · right dots
            _dotsCol(leftStrokes, _colourFor(rp, leftOpp.player.id)),
            const SizedBox(width: 5),
            _scoreBox(gross, isHot, colour, net, mode),
            const SizedBox(width: 5),
            _dotsCol(rightStrokes, _colourFor(rp, rightOpp.player.id)),
          ]),
        ),
      );

      rows.add(row);
      if (isHot || isEditing) {
        rows.add(Container(
          color: colour.withValues(alpha: 0.05),
          padding: const EdgeInsets.only(bottom: 6),
          child: InlineScorePicker(
            par: holeData?.par ?? 4,
            strokes: leftStrokes,
            currentScore: gross,
            boxBorderColor: colour,
            onScoreSelected: (v) => _handleScore(ctx, m, v, players),
          ),
        ));
      }
    }

    return Column(children: [
      Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.colorScheme.outlineVariant)),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) rows[i],
        ]),
      ),
      if (mode != 'gross')
        const Padding(
          padding: EdgeInsets.only(top: 6, left: 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Dots + net = your match vs the lowest-index player '
                '(left); the right dots are your other match.',
                style: TextStyle(fontSize: 11, color: _muted, height: 1.4)),
          ),
        ),
    ]);
  }

  Widget _dotsCol(int n, Color c) {
    if (n <= 0) return const SizedBox(width: 10);
    return SizedBox(
      width: 10,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < n.clamp(0, 3); i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Container(width: 5, height: 5,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          ),
      ]),
    );
  }

  Widget _scoreBox(int? gross, bool isHot, Color colour, int? net, String mode) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 42, height: 36,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: isHot ? colour : const Color(0xFFD3DED6),
              width: isHot ? 2 : 1),
        ),
        alignment: Alignment.center,
        child: gross != null
            ? Text('$gross', style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 16))
            : Icon(Icons.arrow_drop_down, color: colour),
      ),
      if (net != null && mode != 'gross')
        Text('net $net', style: const TextStyle(
            fontSize: 9.5, color: _muted, fontWeight: FontWeight.w700)),
    ]);
  }

  // 3×3 matrix — rows = matches, cols = F9/B9/Overall.
  Widget _matrix(RoundProvider rp, TripleNassauSummary s, List<Membership> players) {
    final theme = Theme.of(context);
    String shortOf(int? pid) => players
        .firstWhere((m) => m.player.id == pid, orElse: () => players.first)
        .player.shortName;

    Widget cell(TripleNassauMatch m, NassauBetResult b) {
      final leaderLive = b.margin > 0 ? m.player1Id
                       : b.margin < 0 ? m.player2Id : null;
      final leaderDone = b.result == 'team1' ? m.player1Id
                       : b.result == 'team2' ? m.player2Id : null;
      final winColour = _colourFor(rp, (b.isComplete ? leaderDone : leaderLive) ?? 0);
      String txt; Color bg; Color fg; String sub = '';
      final solid = b.isComplete && b.result != 'halved';
      if (b.result == 'halved') {
        txt = 'AS'; bg = theme.colorScheme.surfaceContainerHighest; fg = _muted;
      } else if (solid) {
        if (b.decidedRemaining != null && b.decidedRemaining! > 0) {
          txt = '${b.decidedMargin}&${b.decidedRemaining}';
        } else { txt = b.margin.abs() == 0 ? 'wins' : '${b.margin.abs()}UP'; sub = 'Final'; }
        bg = winColour; fg = Colors.white;
      } else if (b.holesPlayed == 0) {
        txt = '—'; bg = theme.colorScheme.surfaceContainerHighest; fg = _muted;
      } else if (b.margin == 0) {
        txt = 'AS'; bg = theme.colorScheme.surfaceContainerHighest; fg = _muted;
        sub = 'thru ${b.holesPlayed}';
      } else {
        txt = '${b.margin.abs()}UP'; bg = winColour.withValues(alpha: 0.13);
        fg = winColour; sub = 'thru ${b.holesPlayed}';
      }
      return Expanded(child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7)),
        child: Column(children: [
          Text(txt, style: TextStyle(
              fontWeight: FontWeight.w800, fontSize: 12, color: fg)),
          if (sub.isNotEmpty)
            Text(sub, style: TextStyle(fontSize: 9,
                color: solid ? Colors.white70 : _muted)),
        ]),
      ));
    }

    Widget matchRow(TripleNassauMatch m) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        SizedBox(width: 74, child: Row(children: [
          _dot(_colourFor(rp, m.player1Id ?? 0)),
          const SizedBox(width: 2),
          Flexible(child: Text(shortOf(m.player1Id), overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 10.5))),
          const Text(' v ', style: TextStyle(color: _muted, fontSize: 9)),
          _dot(_colourFor(rp, m.player2Id ?? 0)),
          const SizedBox(width: 2),
          Flexible(child: Text(shortOf(m.player2Id), overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 10.5))),
        ])),
        cell(m, m.match.front9), cell(m, m.match.back9), cell(m, m.match.overall),
      ]),
    );

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: const Color(0xFFE1EAE2), borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Row(children: [
          const SizedBox(width: 74),
          for (final l in const ['F9', 'B9', 'ALL'])
            Expanded(child: Text(l, textAlign: TextAlign.center, style: const TextStyle(
                fontSize: 9, fontWeight: FontWeight.w700, color: _muted,
                letterSpacing: 0.4))),
        ]),
        for (final m in s.matches) matchRow(m),
      ]),
    );
  }

  Widget _netPosition(RoundProvider rp, TripleNassauSummary s) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Net position', style: TextStyle(
          fontWeight: FontWeight.w700, fontSize: 12.5, color: theme.colorScheme.primary)),
      for (final p in s.players)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            _dot(_colourFor(rp, p.playerId)),
            const SizedBox(width: 8),
            Text(p.shortName, style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(_fmtMoney(p.net), style: TextStyle(
                fontWeight: FontWeight.w800,
                color: p.net > 0 ? const Color(0xFF388E3C)
                     : p.net < 0 ? const Color(0xFFD32F2F) : _muted)),
          ]),
        ),
    ]);
  }

  // Matches where a manual press is currently allowed.
  List<TripleNassauMatch> _pressableMatches(TripleNassauSummary s) {
    if (s.pressMode != 'manual' && s.pressMode != 'both') return const [];
    final nineFront = _selectedHole <= 9;
    return s.matches.where((m) {
      final bet = nineFront ? m.match.front9 : m.match.back9;
      return !bet.isComplete && bet.margin != 0;   // someone is down
    }).toList();
  }

  Widget _dot(Color c) => Container(width: 10, height: 10,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle));

  Widget _buildBottomNav(BuildContext ctx, RoundProvider rp) {
    final sc = rp.scorecard!;
    final players = _realMembers(rp);
    final allDone = _allScored(players, _effectiveScores(sc, _selectedHole));
    final isComplete = rp.round?.status == 'complete';
    final order = _playOrder(rp);
    final prev = prevInOrder(order, _selectedHole);
    final next = nextInOrder(order, _selectedHole);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: prev != null ? _retreat : null,
            icon: const Icon(Icons.chevron_left, size: 20),
            label: Text(prev != null ? 'Hole $prev' : 'Hole'),
          )),
          const SizedBox(width: 8),
          Expanded(
            child: next == null || isComplete
                ? FilledButton.icon(
                    onPressed: rp.submitting ? null : () => _finishRound(ctx, players),
                    icon: const Icon(Icons.emoji_events, size: 20),
                    label: const Text('Done'))
                : FilledButton.icon(
                    onPressed: (allDone && !rp.submitting)
                        ? () => _saveAndAdvance(ctx, players) : null,
                    icon: rp.submitting
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.chevron_right, size: 20),
                    label: Text(rp.submitting ? 'Saving…' : 'Hole $next'),
                    iconAlignment: IconAlignment.end),
          ),
        ]),
      ),
    );
  }
}

// ── Call Press sheet ─────────────────────────────────────────────────────────

class _PressSheet extends StatelessWidget {
  final TripleNassauSummary summary;
  final int selectedHole;
  final Color Function(int) colourFor;
  final String Function(int) shortFor;
  final Future<void> Function(String gameType, int startHole) onPress;

  const _PressSheet({
    required this.summary,
    required this.selectedHole,
    required this.colourFor,
    required this.shortFor,
    required this.onPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final front = selectedHole <= 9;
    final nineLabel = front ? 'Front 9' : 'Back 9';
    final end = front ? 9 : 18;

    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Call Press', style: theme.textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 3),
        const Text('A press starts a fresh bet over the remaining holes of the '
            'current nine. It applies to one match only — pick which.',
            style: TextStyle(fontSize: 12.5, color: _muted, height: 1.5)),
        const SizedBox(height: 12),
        for (final m in summary.matches)
          _option(context, m, front, nineLabel, end),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _option(BuildContext context, TripleNassauMatch m, bool front,
      String nineLabel, int end) {
    final bet = front ? m.match.front9 : m.match.back9;
    final canManual = summary.pressMode == 'manual' || summary.pressMode == 'both';
    final eligible = canManual && !bet.isComplete && bet.margin != 0;
    final leaderId = bet.margin > 0 ? m.player1Id : m.player2Id;
    final downId   = bet.margin > 0 ? m.player2Id : m.player1Id;

    String why;
    if (!canManual) {
      why = 'Manual presses aren’t enabled for this game.';
    } else if (bet.isComplete) {
      why = 'This nine is settled.';
    } else if (bet.margin == 0) {
      why = 'Nobody is down — only the player behind can press.';
    } else {
      why = '${shortFor(downId ?? 0)} is ${bet.margin.abs()} down '
            'with ${end - selectedHole + 1} holes left.';
    }

    return Opacity(
      opacity: eligible ? 1 : 0.55,
      child: Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: eligible ? const Color(0xFF0F6E56) : const Color(0xFFE1E7E2),
              width: eligible ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _dot(colourFor(m.player1Id ?? 0)),
            const SizedBox(width: 4),
            Text(shortFor(m.player1Id ?? 0), style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 14)),
            const Text('  v  ', style: TextStyle(color: _muted, fontSize: 11)),
            _dot(colourFor(m.player2Id ?? 0)),
            const SizedBox(width: 4),
            Text(shortFor(m.player2Id ?? 0), style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 14)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: const Color(0x1A0F6E56),
                  borderRadius: BorderRadius.circular(999)),
              child: Text(nineLabel, style: const TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF0F6E56))),
            ),
          ]),
          const SizedBox(height: 5),
          if (eligible)
            Text('${shortFor(leaderId ?? 0)} ${bet.margin.abs()} UP · '
                '${shortFor(downId ?? 0)} may press',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          Text(why, style: const TextStyle(fontSize: 11.5, color: _muted, height: 1.4)),
          if (eligible) ...[
            const SizedBox(height: 5),
            Text('Press · \$${summary.pressUnit.toStringAsFixed(2)} · '
                'holes $selectedHole–$end',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700,
                    color: Color(0xFF0F6E56))),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => onPress(m.gameType, selectedHole),
                child: Text('Press ${shortFor(m.player1Id ?? 0)} · '
                    '${shortFor(m.player2Id ?? 0)}'),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _dot(Color c) => Container(width: 10, height: 10,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle));
}
