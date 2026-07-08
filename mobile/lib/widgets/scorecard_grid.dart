import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../utils/match_handicap.dart';
import '../utils/play_order.dart';
import '../utils/sixes_handicap.dart';
import 'net_score_button.dart' show scoreCellWithDots;
import 'score_mark.dart';

// ---------------------------------------------------------------------------
// ScorecardGrid — the full 18-hole, all-players stacked scorecard.
//
// This is the whole-group card, extracted verbatim from the old
// ScorecardScreen's landscape view so it can be reused as the
// rotate-to-landscape overlay (see round_landscape_scorecard.dart).  It is
// read-only: score entry lives on the game / score-entry screens.  All the
// stroke-dot + player-ordering logic mirrors score_entry_screen.dart so the
// three surfaces (entry, this card, the Stroke Play tab) agree on net/dots.
// ---------------------------------------------------------------------------

/// Mirror of score_entry_screen.dart's _effectiveHandicap.  Drops the
/// player's playing handicap into the right "effective" number for the
/// active handicap mode so the per-hole dot count matches what the game
/// services use for scoring.
int _effectiveHandicap({
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
      if (off <= 0) return 0;
      return (off * netPercent / 100.0).round();
    case 'net':
    default:
      if (netPercent == 100) return playingHandicap;
      return (playingHandicap * netPercent / 100.0).round();
  }
}

/// Short human label for the handicap mode driving the scorecard's dot
/// allocations.  Shown in the AppBar so players can tell at a glance
/// whether the dots reflect 100% net, 90% net, strokes-off, etc.
String _modeLabel(String mode, int netPercent) {
  switch (mode) {
    case 'gross':
      return 'Gross';
    case 'strokes_off':
      return netPercent == 100 ? 'Strokes Off' : 'Strokes Off $netPercent%';
    case 'net':
    default:
      return netPercent == 100 ? 'Net' : 'Net $netPercent%';
  }
}

class ScorecardGrid extends StatefulWidget {
  final int foursomeId;

  /// Whether to show a close (X) button that pops the route.  True when the
  /// grid is PUSHED as its own route (e.g. the multi-skins per-group card);
  /// false when it's shown inline by the rotate-to-landscape gate, where
  /// there's no route to pop — the user rotates back to portrait to dismiss.
  final bool showClose;

  const ScorecardGrid({
    super.key,
    required this.foursomeId,
    this.showClose = true,
  });

  @override
  State<ScorecardGrid> createState() => _ScorecardGridState();
}

class _ScorecardGridState extends State<ScorecardGrid> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rp = context.read<RoundProvider>();
      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      } else {
        rp.refreshPendingOverlay();
      }
      // The dot-counting logic in _strokesForHole consults lowNetConfig when
      // the round runs low_net (Stroke Play).  Load it on direct entry so the
      // strokes-off mode is honored without first visiting the score screen.
      final games = rp.round?.activeGames ?? const [];
      if ((games.contains('low_net_round') || games.contains('low_net')) &&
          rp.round != null &&
          rp.lowNetConfig == null) {
        rp.loadLowNetConfig(rp.round!.id);
      }
      // Cup Singles needs the bracket data so dots can be computed per-pair.
      if ((games.contains('singles_nassau') || games.contains('singles_18')) &&
          rp.matchPlayData == null) {
        rp.loadMatchPlay(widget.foursomeId);
      }
      // Games that carry their own handicap mode (often strokes-off) on the
      // game rather than the round — load so the dots match the game screen.
      if (games.contains('wolf') && rp.wolfSummary == null) {
        rp.loadWolf(widget.foursomeId);
      }
      if (games.contains('rabbit') && rp.rabbitSummary == null) {
        rp.loadRabbit(widget.foursomeId);
      }
      if (games.contains('fourball') && rp.fourballSummary == null) {
        rp.loadFourball(widget.foursomeId);
      }
      if (games.contains('triple_cup') && rp.tripleCupSummary == null) {
        rp.loadTripleCup(widget.foursomeId);
      }
      // Nassau / Quota Nassau: load so players group by team (entry order).
      if (games.contains('nassau') && rp.nassauSummary == null) {
        rp.loadNassau(widget.foursomeId);
      }
      if (games.contains('quota_nassau') && rp.quotaNassauSummary == null) {
        rp.loadQuotaNassau(widget.foursomeId);
      }
    });
  }

  List<Membership> _realPlayers(Scorecard sc, Round? round) {
    final foursome = round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    final List<Membership> members;
    if (foursome != null) {
      members = foursome.realPlayers;
    } else if (sc.holes.isEmpty) {
      return [];
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
    return _orderForGame(members, sc);
  }

  /// Order players so the scorecard matches the score-entry screens:
  ///   • Team games (Triple Cup, Nassau, Quota Nassau) → team blocks.
  ///   • Wolf → membership order (its entry order rotates per hole).
  ///   • Everything else → longest tee first, then membership order.
  List<Membership> _orderForGame(List<Membership> members, Scorecard sc) {
    final rp    = context.read<RoundProvider>();
    final games = rp.round?.activeGames ?? const <String>[];

    Map<int, int>? teamOf;
    if (games.contains('triple_cup') && rp.tripleCupSummary != null) {
      teamOf = {};
      for (final m in rp.tripleCupSummary!.matches) {
        for (final p in m.players) {
          if (!p.isPhantom) teamOf.putIfAbsent(p.playerId, () => p.teamNumber);
        }
      }
    } else if (games.contains('nassau') && rp.nassauSummary != null) {
      final n = rp.nassauSummary!;
      teamOf = {
        for (final p in n.team1) p.playerId: 1,
        for (final p in n.team2) p.playerId: 2,
      };
    } else if (games.contains('quota_nassau') && rp.quotaNassauSummary != null) {
      teamOf = {};
      for (final mt in rp.quotaNassauSummary!.matches) {
        teamOf.putIfAbsent(mt.player1.playerId, () => 1);
        teamOf.putIfAbsent(mt.player2.playerId, () => 2);
      }
    }

    if (teamOf != null && teamOf.isNotEmpty) {
      final ordered = <Membership>[];
      for (final t in [1, 2]) {
        for (final m in members) {
          if (teamOf[m.player.id] == t) ordered.add(m);
        }
      }
      for (final m in members) {
        if (!ordered.any((o) => o.player.id == m.player.id)) ordered.add(m);
      }
      return ordered;
    }

    if (games.contains('wolf')) return members;

    final firstHole = sc.holeData(1);
    int yards(int pid) => firstHole?.scoreFor(pid)?.yards ?? 0;
    final idx = {
      for (var i = 0; i < members.length; i++) members[i].player.id: i,
    };
    return List<Membership>.of(members)
      ..sort((a, b) {
        final d = yards(b.player.id).compareTo(yards(a.player.id));
        return d != 0 ? d : idx[a.player.id]!.compareTo(idx[b.player.id]!);
      });
  }

  /// First hole not yet scored by everyone — used to auto-scroll + highlight.
  /// Ordered holes actually in play (play order, wraparound). Empty list means
  /// a full 1-18 round — callers keep their unchanged 18-hole path.
  List<int> _holesInPlay(Scorecard sc, RoundProvider rp) {
    final universe = sc.holes.isEmpty
        ? 18
        : sc.holes.map((h) => h.holeNumber).reduce((a, b) => a > b ? a : b);
    final start = rp.round?.startingHole ?? 1;
    final n = (rp.round?.numHoles ?? universe).clamp(1, universe);
    if (n >= universe) return const [];
    return [for (int i = 0; i < n; i++) ((start - 1 + i) % universe) + 1];
  }

  int _firstUnplayedHole(Scorecard sc, List<Membership> players) {
    final rp = context.read<RoundProvider>();
    final order = _holesInPlay(sc, rp);
    final seq = order.isEmpty ? [for (int h = 1; h <= 18; h++) h] : order;
    for (final h in seq) {
      if (rp.localPendingByHole.containsKey(h)) continue;
      final hd = sc.holeData(h);
      if (hd == null ||
          !players.every((m) => hd.scoreFor(m.player.id)?.grossScore != null)) {
        return h;
      }
    }
    return seq.last;
  }

  /// Mode + percentage that should drive stroke-dot display.  Mirrors
  /// score_entry_screen.dart's _handicapParams.  Priority: low_net config →
  /// nassau → skins → sixes → points_531 → round-level.
  (String mode, int netPercent) _handicapParams(RoundProvider rp) {
    final games = rp.round?.activeGames ?? const [];
    final primary = resolvePrimary(rp.round?.primaryGame, games);
    if ((primary == 'low_net_round' || primary == 'low_net') &&
        rp.lowNetConfig != null) {
      final mode = rp.lowNetConfig!['handicap_mode'] as String? ?? 'net';
      final pct  = rp.lowNetConfig!['net_percent']  as int?    ?? 100;
      return (mode, pct);
    }
    if (games.contains('nassau') && rp.nassauSummary != null) {
      return (rp.nassauSummary!.handicapMode, rp.nassauSummary!.netPercent);
    }
    if (primary == 'skins' && rp.skinsSummary != null) {
      return (rp.skinsSummary!.handicapMode, rp.skinsSummary!.netPercent);
    }
    if (games.contains('sixes') && rp.sixesSummary != null) {
      return (rp.sixesSummary!.handicapMode, rp.sixesSummary!.netPercent);
    }
    if (games.contains('points_531') && rp.points531Summary != null) {
      return (rp.points531Summary!.handicapMode,
              rp.points531Summary!.netPercent);
    }
    if (games.contains('wolf') && rp.wolfSummary != null) {
      return (rp.wolfSummary!.handicapMode, rp.wolfSummary!.netPercent);
    }
    if (games.contains('rabbit') && rp.rabbitSummary != null) {
      return (rp.rabbitSummary!.handicapMode, rp.rabbitSummary!.netPercent);
    }
    if (games.contains('fourball') && rp.fourballSummary != null) {
      return (rp.fourballSummary!.handicapMode, rp.fourballSummary!.netPercent);
    }
    if (games.contains('triple_cup') && rp.tripleCupSummary != null) {
      return (rp.tripleCupSummary!.handicapMode,
              rp.tripleCupSummary!.netPercent);
    }
    return (rp.round?.handicapMode ?? 'net', rp.round?.netPercent ?? 100);
  }

  /// Effective handicap for a player under the active mode.  Cup Singles gets
  /// its own branch (strokes per-pair against the bracket opponent).
  int _effectiveHcapFor(Membership m, RoundProvider rp) {
    final games        = rp.round?.activeGames ?? const [];
    final isCupSingles = games.contains('singles_nassau') ||
                         games.contains('singles_18');
    if (isCupSingles) {
      return _cupSinglesEffectiveHcap(m, rp);
    }

    final (mode, pct) = _handicapParams(rp);
    int? lowestPlaying;
    if (mode == 'strokes_off') {
      final sc = rp.scorecard;
      if (sc != null) {
        final players = _realPlayers(sc, rp.round);
        if (players.isNotEmpty) {
          lowestPlaying = players
              .map((p) => p.playingHandicap)
              .reduce((a, b) => a < b ? a : b);
        }
      }
    }
    return _effectiveHandicap(
      mode:                  mode,
      netPercent:            pct,
      playingHandicap:       m.playingHandicap,
      lowestPlayingHandicap: lowestPlaying,
    );
  }

  /// Cup Singles effective handicap: max(0, playerHcp − opponentHcp).
  int _cupSinglesEffectiveHcap(Membership m, RoundProvider rp) {
    final mpData = rp.matchPlayData;
    if (mpData != null && mpData['bracket_type'] == 'cup_singles') {
      final matches = (mpData['matches'] as List?) ?? const [];
      for (final raw in matches) {
        final match = Map<String, dynamic>.from(raw as Map);
        final p1Id  = match['player1_id'] as int?;
        final p2Id  = match['player2_id'] as int?;
        int? opponentId;
        if (p1Id == m.player.id)      opponentId = p2Id;
        else if (p2Id == m.player.id) opponentId = p1Id;
        else continue;
        final sc = rp.scorecard;
        if (sc == null) return 0;
        final opp = _realPlayers(sc, rp.round)
            .where((x) => x.player.id == opponentId)
            .firstOrNull;
        if (opp != null) {
          final so = m.playingHandicap - opp.playingHandicap;
          return so > 0 ? so : 0;
        }
        break;
      }
    }
    final sc = rp.scorecard;
    if (sc == null) return 0;
    final players = _realPlayers(sc, rp.round);
    if (players.isEmpty) return 0;
    final low = players
        .map((p) => p.playingHandicap)
        .reduce((a, b) => a < b ? a : b);
    final so = m.playingHandicap - low;
    return so > 0 ? so : 0;
  }

  /// Triple Cup: the backend's authoritative per-segment strokes for
  /// [playerId] on [hole].  Null when not a TC round / not loaded / not in a
  /// match (falls through to the generic strokes-off-low path).
  int? _tripleCupStrokes(int playerId, int hole, RoundProvider rp) {
    final tc = rp.tripleCupSummary;
    if (tc == null) return null;
    for (final mt in tc.matches) {
      if (hole < mt.startHole || hole > mt.endHole) continue;
      for (final p in mt.players) {
        if (p.playerId == playerId) return p.strokesByHole[hole] ?? 0;
      }
    }
    return null;
  }

  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null) return 0;
    final rp = context.read<RoundProvider>();
    final tcStrokes = _tripleCupStrokes(m.player.id, h.holeNumber, rp);
    if (tcStrokes != null) return tcStrokes;
    final effective = _effectiveHcapFor(m, rp);
    if (effective <= 0) return 0;
    final entry = h.scoreFor(m.player.id);
    final si    = entry?.strokeIndex ?? h.strokeIndex;

    final (hcapMode, _) = _handicapParams(rp);
    final games = rp.round?.activeGames ?? const <String>[];
    if (hcapMode == 'strokes_off' &&
        games.contains('sixes') &&
        rp.sixesSummary != null &&
        rp.sixesSummary!.handicapAllocation == 'per_segment' &&
        rp.scorecard != null) {
      return sixesSoStrokesOnHole(
        playerSo:    effective,
        holeNumber:  h.holeNumber,
        strokeIndex: si,
        summary:     rp.sixesSummary!,
        scorecard:   rp.scorecard!,
        holesInPlay: roundPlayOrder(rp.round, rp.scorecard),
      );
    }

    return strokesOnHole(effective, si);
  }

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final (modeName, modePct) = _handicapParams(rp);
    final modeLabel           = _modeLabel(modeName, modePct);
    final sc                  = rp.scorecard;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        // Never auto-imply a back button: when shown inline by the rotate gate
        // this widget isn't its own route, so an implied back arrow would pop
        // the screen underneath.
        automaticallyImplyLeading: false,
        leading: widget.showClose
            ? IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Close scorecard',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: Text(
          'Scorecard — Group ${sc?.groupNumber ?? ""}  ·  $modeLabel',
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
          if (sc != null)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => rp.loadScorecard(widget.foursomeId),
            ),
        ],
      ),
      // Inset the grid past the notch / home-indicator: in landscape those land
      // on the left/right edges and would otherwise clip the name and NET/STBL
      // columns.  SafeArea shrinks the scroll viewport, leaving the
      // scroll-to-hole math untouched (it reads the live viewport dimension).
      body: SafeArea(
        top: false,
        child: Column(children: [
          _SyncBanner(sync: sync),
          if (rp.loadingScorecard && sc == null)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (sc == null)
            Expanded(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(rp.error ?? 'No scorecard available yet.'),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => rp.loadScorecard(widget.foursomeId),
                    child: const Text('Retry'),
                  ),
                ]),
              ),
            )
          else
            () {
              final players = _realPlayers(sc, rp.round);
              return Expanded(
                child: _LandscapeGrid(
                  scorecard:      sc,
                  players:        players,
                  pendingScores:  rp.localPendingByHole,
                  currentHole:    _firstUnplayedHole(sc, players),
                  totals:         sc.totals,
                  strokesForHole: _strokesForHole,
                  holesInPlay:    _holesInPlay(sc, rp),
                ),
              );
            }(),
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
        Expanded(child: Text(message, style: TextStyle(color: fg, fontSize: 13))),
      ]),
    );
  }
}

// ===========================================================================
// Landscape grid — full 18-hole overview (all players × all holes)
// ===========================================================================

class _LandscapeGrid extends StatefulWidget {
  final Scorecard scorecard;
  final List<Membership> players;
  final Map<int, Map<int, int>> pendingScores;
  final int currentHole;
  final List<PlayerTotals> totals;
  final int Function(Membership, ScorecardHole?) strokesForHole;
  /// Ordered holes in play (play order). Empty = full 1-18 round.
  final List<int> holesInPlay;

  const _LandscapeGrid({
    required this.scorecard,
    required this.players,
    required this.pendingScores,
    required this.currentHole,
    required this.totals,
    required this.strokesForHole,
    this.holesInPlay = const [],
  });

  @override
  State<_LandscapeGrid> createState() => _LandscapeGridState();
}

class _LandscapeGridState extends State<_LandscapeGrid> {
  final ScrollController _scroll = ScrollController();

  static const double _nameW    = 80.0;
  static const double _summaryW = 34.0;
  static const double _colW     = 40.0;

  // Holes to render, split by nine. On a full round these are 1-9 / 10-18; on a
  // partial / back-9 round only the played holes appear (display by number), so
  // there's no blank front-nine. An empty nine drops its OUT / IN subtotal.
  List<int> get _front => widget.holesInPlay.isEmpty
      ? [for (int h = 1; h <= 9; h++) h]
      : (widget.holesInPlay.where((h) => h <= 9).toList()..sort());
  List<int> get _back => widget.holesInPlay.isEmpty
      ? [for (int h = 10; h <= 18; h++) h]
      : (widget.holesInPlay.where((h) => h >= 10).toList()..sort());
  bool get _showOut => _front.isNotEmpty;
  bool get _showIn  => _back.isNotEmpty;

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
    final fi = _front.indexOf(hole);
    if (fi >= 0) {
      holeLeft = _nameW + fi * _colW;
    } else {
      final bi = _back.indexOf(hole);
      if (bi < 0) return;
      holeLeft = _nameW +
          _front.length * _colW +
          (_showOut ? _summaryW : 0) +
          bi * _colW;
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

    // Column widths, built to match the dynamic column layout: name, front
    // holes, [OUT], back holes, [IN], TOT, NET, STBL.
    final colWidths = <int, TableColumnWidth>{0: FixedColumnWidth(_nameW)};
    int idx = 1;
    for (final _ in _front) { colWidths[idx++] = FixedColumnWidth(_colW); }
    if (_showOut) colWidths[idx++] = FixedColumnWidth(_summaryW);
    for (final _ in _back) { colWidths[idx++] = FixedColumnWidth(_colW); }
    if (_showIn) colWidths[idx++] = FixedColumnWidth(_summaryW);
    colWidths[idx++] = FixedColumnWidth(_summaryW); // TOT
    colWidths[idx++] = FixedColumnWidth(_summaryW); // NET
    colWidths[idx++] = FixedColumnWidth(_summaryW); // STBL

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
        for (final hole in _front)
          _cell('$hole', height: h, bold: true, bg: selBg(hole)),
        if (_showOut)
          _cell('OUT',  height: h, bold: true, italic: true, bg: sumBg),
        for (final hole in _back)
          _cell('$hole', height: h, bold: true, bg: selBg(hole)),
        if (_showIn)
          _cell('IN',   height: h, bold: true, italic: true, bg: sumBg),
        _cell('TOT',  height: h, bold: true, italic: true, bg: sumBg),
        _cell('NET',  height: h, bold: true, italic: true, bg: sumBg),
        _cell('STBL', height: h, bold: true, italic: true, bg: sumBg),
      ],
    );
  }

  TableRow _parRow(ThemeData theme, double h) {
    int parOut = 0, parIn = 0;
    for (final hole in _front) {
      parOut += widget.scorecard.holeData(hole)?.par ?? 0;
    }
    for (final hole in _back) {
      parIn  += widget.scorecard.holeData(hole)?.par ?? 0;
    }
    return TableRow(
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow),
      children: [
        _cell('Par', height: h, italic: true),
        for (final hole in _front)
          _cell('${widget.scorecard.holeData(hole)?.par ?? '-'}', height: h),
        if (_showOut) _cell('$parOut', height: h, bold: true),
        for (final hole in _back)
          _cell('${widget.scorecard.holeData(hole)?.par ?? '-'}', height: h),
        if (_showIn) _cell('$parIn',   height: h, bold: true),
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
      // "all…" = every hole in the segment is scored — a subtotal shows only
      // once its whole segment is done (Out after the front 9, Tot after 18),
      // never a misleading partial.
      bool allOutGross = true, allInGross = true;
      bool hasOutNet   = true,  hasInNet   = true;

      for (final hole in _front) {
        final gross = widget.pendingScores[hole]?[m.player.id]
            ?? widget.scorecard.holeData(hole)?.scoreFor(m.player.id)?.grossScore;
        if (gross != null) { outGross += gross; } else { allOutGross = false; }
        final net = widget.scorecard.holeData(hole)?.scoreFor(m.player.id)?.netScore;
        if (net == null) hasOutNet = false; else outNetSum += net;
      }
      for (final hole in _back) {
        final gross = widget.pendingScores[hole]?[m.player.id]
            ?? widget.scorecard.holeData(hole)?.scoreFor(m.player.id)?.grossScore;
        if (gross != null) { inGross += gross; } else { allInGross = false; }
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
                Text('Course ${m.playingHandicap}',
                    style: const TextStyle(fontSize: 9)),
              ],
            ),
          ),
        ),
        for (final hole in _front) _scoreCell(hole, m, h),
        if (_showOut) _summaryCell(allOutGross ? '$outGross' : '—', h),
        for (final hole in _back) _scoreCell(hole, m, h),
        if (_showIn) _summaryCell(allInGross ? '$inGross' : '—', h),
        _summaryCell(
            (allOutGross && allInGross) ? '${outGross + inGross}' : '—', h),
        _summaryCell(hasNet ? '$netTot' : '—', h),
        _summaryCell(stbl != null ? '$stbl' : '—', h),
      ]);
    }).toList();
  }

  Widget _scoreCell(int hole, Membership m, double rowH) {
    final theme       = Theme.of(context);
    final holeData    = widget.scorecard.holeData(hole);
    final saved       = holeData?.scoreFor(m.player.id);
    final pending     = widget.pendingScores[hole]?[m.player.id];
    final gross       = pending ?? saved?.grossScore;
    final par         = holeData?.par ?? 4;
    final isCurrent   = hole == widget.currentHole;
    final isLocalOnly = pending != null;
    final strokes     = widget.strokesForHole(m, holeData);

    Color? bg;
    if (isCurrent) bg = theme.colorScheme.primaryContainer.withOpacity(0.3);
    if (isLocalOnly) bg = theme.colorScheme.tertiaryContainer.withOpacity(0.5);

    return TableCell(
      child: Container(
        height: rowH, color: bg,
        child: scoreCellWithDots(
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                gross != null
                    ? scoreMark(
                        text: '$gross',
                        diff: (gross - strokes) - par,
                        baseStyle: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                        theme: theme,
                      )
                    : const Text('—',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                if (isLocalOnly)
                  Icon(Icons.cloud_upload_outlined,
                      size: 8, color: theme.colorScheme.tertiary),
              ],
            ),
          ),
          strokes,
          theme.colorScheme.primary,
        ),
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
