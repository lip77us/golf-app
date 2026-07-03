import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../utils/match_handicap.dart';
import '../utils/sixes_handicap.dart';
import '../widgets/net_score_button.dart';
import '../widgets/score_mark.dart';

// ---------------------------------------------------------------------------
// Top-level helpers — identical to skins_screen.dart so we keep one source
// of truth per utility.
// ---------------------------------------------------------------------------

/// Mirror of score_entry_screen.dart's _effectiveHandicap.  Drops the
/// player's playing handicap into the right "effective" number for the
/// active handicap mode so the per-hole dot count matches what the
/// game services use for scoring.
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

String _toPar(int v) => v == 0 ? 'E' : (v > 0 ? '+$v' : '$v');

/// One dot color per player slot (up to 4 players) used in the hole-
/// strip stroke indicators.  A filled circle in the player's slot color
/// means "this player gets a stroke on this hole"; an outline-only
/// circle means "no stroke for this player on this hole."
const _kPlayerDotColors = [
  Color(0xFF1565C0), // blue
  Color(0xFFE65100), // deep orange
  Color(0xFF6A1B9A), // purple
  Color(0xFF00695C), // teal
];

/// Short human label for the handicap mode driving the scorecard's dot
/// allocations.  Shown in the AppBar so players can tell at a glance
/// whether the dots reflect 100% net, 90% net, strokes-off, etc.
String _modeLabel(String mode, int netPercent) {
  switch (mode) {
    case 'gross':
      return 'Gross';
    case 'strokes_off':
      return netPercent == 100
          ? 'Strokes Off'
          : 'Strokes Off $netPercent%';
    case 'net':
    default:
      return netPercent == 100 ? 'Net' : 'Net $netPercent%';
  }
}

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
      // The dot-counting logic in _strokesForHole consults lowNetConfig
      // when the round runs low_net (Stroke Play).  Load it on direct
      // entry so the strokes-off mode is honored without first visiting
      // the score-entry screen.
      final games = rp.round?.activeGames ?? const [];
      if ((games.contains('low_net_round') || games.contains('low_net')) &&
          rp.round != null &&
          rp.lowNetConfig == null) {
        rp.loadLowNetConfig(rp.round!.id);
      }
      // Cup Singles needs the bracket data so dots can be computed
      // per-pair (player's strokes vs their actual opponent, not vs
      // foursome-low).  Same direct-entry safeguard as lowNetConfig.
      if ((games.contains('singles_nassau') ||
              games.contains('singles_18')) &&
          rp.matchPlayData == null) {
        rp.loadMatchPlay(widget.foursomeId);
      }
      // Wolf carries its own handicap mode (e.g. strokes-off) on the game,
      // not the round — load it so the scorecard's stroke dots match the
      // Wolf screen instead of falling back to round-level net.
      if (games.contains('wolf') && rp.wolfSummary == null) {
        rp.loadWolf(widget.foursomeId);
      }
      if (games.contains('rabbit') && rp.rabbitSummary == null) {
        rp.loadRabbit(widget.foursomeId);
      }
      // Fourball carries its own handicap mode (often Strokes-Off) on the
      // game, not the round — load it so the scorecard's stroke dots match
      // the Fourball match instead of falling back to round-level net.
      if (games.contains('fourball') && rp.fourballSummary == null) {
        rp.loadFourball(widget.foursomeId);
      }
      // Triple Cup: load the summary so the scorecard's per-hole strokes come
      // from the backend's segment rules (alt-shot team average, fourball
      // donor low, singles per-pair) — matching the score-entry screen.
      if (games.contains('triple_cup') && rp.tripleCupSummary == null) {
        rp.loadTripleCup(widget.foursomeId);
      }
      // Nassau / Quota Nassau: load so the scorecard can group players by
      // team (matching the entry-screen order).
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
  ///   • Team games (Triple Cup, Nassau, Quota Nassau) → team blocks
  ///     (team 1 then team 2, membership order within each).
  ///   • Wolf → membership order (its entry order rotates per hole and
  ///     can't be shown statically — left alone on purpose).
  ///   • Everything else → longest tee first (hole-1 yardage), then
  ///     membership order for ties (matches Skins / Points 5-3-1).
  List<Membership> _orderForGame(List<Membership> members, Scorecard sc) {
    final rp    = context.read<RoundProvider>();
    final games = rp.round?.activeGames ?? const <String>[];

    // Build a player_id → team_number map for the active team game.
    Map<int, int>? teamOf;
    if (games.contains('triple_cup') && rp.tripleCupSummary != null) {
      teamOf = {};
      for (final m in rp.tripleCupSummary!.matches) {
        for (final p in m.players) {
          if (!p.isPhantom) teamOf!.putIfAbsent(p.playerId, () => p.teamNumber);
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
        teamOf!.putIfAbsent(mt.player1.playerId, () => 1);
        teamOf!.putIfAbsent(mt.player2.playerId, () => 2);
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

    // Non-team games: longest tee first, membership order for ties.
    final firstHole = sc.holeData(1);
    int yards(int pid) => firstHole?.scoreFor(pid)?.yards ?? 0;
    final idx = {
      for (var i = 0; i < members.length; i++) members[i].player.id: i,
    };
    return List<Membership>.of(members)
      ..sort((a, b) {
        final d = yards(b.player.id).compareTo(yards(a.player.id));
        return d != 0
            ? d
            : idx[a.player.id]!.compareTo(idx[b.player.id]!);
      });
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

  /// Mode + percentage that should drive stroke-dot display on the
  /// scorecard.  Mirrors score_entry_screen.dart's _handicapParams so the
  /// two views agree on what a player's strokes look like.  Priority:
  /// low_net config → nassau → skins → sixes → points_531 → round-level.
  (String mode, int netPercent) _handicapParams(RoundProvider rp) {
    final games = rp.round?.activeGames ?? const [];
    // Stroke dots follow the PRIMARY game's handicap; side games
    // (skins/stableford/stroke play) only drive it when they are the primary.
    final primary = primaryGameOf(games);
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
    // Fourball keeps its mode in its own summary (often Strokes-Off); without
    // this the scorecard fell back to the round's mode and showed full-net dots.
    if (games.contains('fourball') && rp.fourballSummary != null) {
      return (rp.fourballSummary!.handicapMode, rp.fourballSummary!.netPercent);
    }
    // Triple Cup keeps its mode in its own summary (often Strokes-Off); without
    // this the scorecard fell back to the round's mode and showed full-net dots.
    if (games.contains('triple_cup') && rp.tripleCupSummary != null) {
      return (rp.tripleCupSummary!.handicapMode,
              rp.tripleCupSummary!.netPercent);
    }
    return (rp.round?.handicapMode ?? 'net', rp.round?.netPercent ?? 100);
  }

  /// Effective handicap for a player under the active mode.  Used both
  /// to label the scorecard's per-player Hcp chip (matching the
  /// score-entry view) and as the input to per-hole stroke allocation.
  ///
  /// Cup Singles (singles_nassau / singles_18) gets its own branch:
  /// strokes are computed per-pair against the player's bracket
  /// opponent, not against the foursome low.  Mirrors score_entry's
  /// _editScore cup-singles logic so the two views agree.
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
  /// Falls back to foursome-low strokes-off when the bracket data
  /// hasn't loaded yet (mirrors score_entry's fallback so the dots
  /// don't disappear during the loading window).
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
    // Bracket data not yet loaded — fall back to foursome-low SO so the
    // dots still show something sensible.  Score entry uses the same
    // fallback (score_entry_screen.dart:1324).
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

  /// Returns handicap strokes on a specific hole for a player.  Always
  /// computes locally from the active handicap mode (net / gross /
  /// strokes-off) so the dots match what the game services actually use
  /// to score.  The server's persisted HoleScore.handicap_strokes is
  /// mode-blind (always full playing-handicap), so we deliberately don't
  /// trust it here.
  ///
  /// Special case: Sixes in Strokes-Off with the per_segment handicap
  /// allocation (the legacy default) spreads strokes across the 3
  /// matches.  The naive round-wide formula in [strokesOnHole] would
  /// hand the player extra dots on holes that the segment-aware
  /// allocator skips — making the scorecard disagree with the entry
  /// screen and the backend.  Route through the shared sixes helper to
  /// keep all three in lock-step.
  /// Triple Cup: the backend's authoritative per-segment strokes for
  /// [playerId] on [hole] — alt-shot shows the team's averaged value on BOTH
  /// partners, fourball uses the per-hole donor low, singles per-pair.  Null
  /// when not a TC round, the summary isn't loaded, or the hole isn't in a
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
    // Triple Cup: trust the backend's per-segment strokes so the scorecard
    // matches the score entry (esp. alt-shot, where both partners share the
    // team's averaged value rather than each computing strokes-off-low).
    final tcStrokes = _tripleCupStrokes(m.player.id, h.holeNumber, rp);
    if (tcStrokes != null) return tcStrokes;
    final effective = _effectiveHcapFor(m, rp);
    if (effective <= 0) return 0;
    // Per-player SI is preferred — falls back to the shared hole SI.
    final entry = h.scoreFor(m.player.id);
    final si    = entry?.strokeIndex ?? h.strokeIndex;

    // Sixes per-segment SO allocation — only fires when we're actually
    // playing Sixes in SO mode with the (default) per_segment knob.
    // For 'full_round' allocation the scorecard's round-wide formula is
    // already correct, so we fall through to the default branch below.
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
      );
    }

    return strokesOnHole(effective, si);
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
    if (score == -1) return;
    // Commit a past-hole correction immediately — no save+advance needed.
    final rp = context.read<RoundProvider>();
    final ok = await rp.submitHole(
      foursomeId: widget.foursomeId,
      holeNumber: hole,
      scores:     [{'player_id': player.player.id, 'gross_score': score}],
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Failed to save hole.'),
        backgroundColor: Theme.of(ctx).colorScheme.error,
      ));
      return;
    }
    setState(() {
      _pending[hole]?.remove(player.player.id);
      if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
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

    final (modeName, modePct) = _handicapParams(rp);
    final modeLabel           = _modeLabel(modeName, modePct);

    return Scaffold(
      appBar: AppBar(
        // Close (X), not a back arrow — the '<' was being tapped by mistake as
        // a "previous hole" control. X reads clearly as "leave the scorecard".
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close scorecard',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Scorecard — Group ${sc?.groupNumber ?? ""}'),
            Text(
              modeLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
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

        // ── Rotate-for-full-scorecard hint ──────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.screen_rotation_outlined,
                  size: 14,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'Rotate to landscape for the full 18-hole scorecard.',
                style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),

        // ── Hole strip ──────────────────────────────────────────────────
        _HoleStrip(
          scorecard:     sc,
          players:       players,
          pendingScores: {...rp.localPendingByHole, ..._pending},
          selectedHole:  _selectedHole,
          onTap:         (h) => setState(() => _selectedHole = h),
          strokesForHole: (m, hole) =>
              _strokesForHole(m, sc.holeData(hole)),
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
          effectiveHcap:   (m) => _effectiveHcapFor(m, rp),
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
    final (modeName, modePct) = _handicapParams(rp);
    final modeLabel           = _modeLabel(modeName, modePct);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        // Close (X) instead of a back arrow — avoids being mistaken for a
        // "previous hole" control.
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          tooltip: 'Close scorecard',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          'Scorecard — Group ${rp.scorecard?.groupNumber ?? ""}  ·  $modeLabel',
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
      // Inset the grid past the notch / home-indicator: in landscape those land
      // on the left/right edges and would otherwise clip the name and NET/STB
      // columns. SafeArea shrinks the scroll viewport, leaving the scroll-to-hole
      // math untouched (it reads the live viewport dimension).
      body: SafeArea(
        top: false,
        child: Column(children: [
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
              strokesForHole: _strokesForHole,
            ),
          ),
      ]),
      ),
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
  /// Returns the number of strokes [member] gets on [hole].  Used to
  /// paint per-player stroke dots beneath the hole number.
  final int Function(Membership member, int hole) strokesForHole;

  const _HoleStrip({
    required this.scorecard,
    required this.players,
    required this.pendingScores,
    required this.selectedHole,
    required this.onTap,
    required this.strokesForHole,
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
      height: 52,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 18,
        itemBuilder: (_, i) {
          final hole    = i + 1;
          final isSel   = hole == selectedHole;
          final isDone  = _holeComplete(hole);

          // Per-player stroke dots beneath the hole number — coloured
          // when that player gets a stroke, outline-only when they
          // don't.  Each player has a distinct slot colour from
          // _kPlayerDotColors so the dots are readable at a glance.
          final dots = players.asMap().entries.map((e) {
            final s = strokesForHole(e.value, hole);
            return Container(
              width: 5, height: 5,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: s > 0
                    ? _kPlayerDotColors[e.key % _kPlayerDotColors.length]
                    : Colors.transparent,
                border: s == 0
                    ? Border.all(
                        color: theme.colorScheme.outlineVariant, width: 0.5)
                    : null,
              ),
            );
          }).toList();

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: GestureDetector(
              onTap: () => onTap(hole),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
              AnimatedContainer(
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
              const SizedBox(height: 3),
              Row(mainAxisSize: MainAxisSize.min, children: dots),
                ],
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
  final int Function(Membership)          effectiveHcap;
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
    required this.effectiveHcap,
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

            // Empty box styling only — a scored cell renders a NetScoreButton
            // (golf colors: red net-under-par, circle/square, no red fill).
            final Color? boxBg;
            final Border boxBorder;
            if (isHot) {
              boxBg    = theme.colorScheme.primaryContainer.withOpacity(0.4);
              boxBorder = Border.all(
                  color: theme.colorScheme.primary, width: 2);
            } else {
              boxBg    = null;
              boxBorder = Border.all(color: theme.colorScheme.outline);
            }

            // Player row — matches sixes layout exactly.
            final playerRow = Container(
              decoration: BoxDecoration(
                color: isHot
                    ? theme.colorScheme.primaryContainer.withOpacity(0.08)
                    : null,
                border: Border(
                    top: BorderSide(
                        color: theme.colorScheme.outlineVariant)),
              ),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Row(children: [
                // Position + name + HCP chip
                Expanded(
                  child: Row(children: [
                    Text('${idx + 1})  ',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary)),
                    Flexible(
                      child: Text(
                        m.player.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isHot
                              ? theme.colorScheme.primary
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer
                            .withOpacity(0.6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: theme.colorScheme.outlineVariant),
                      ),
                      child: Text(
                        'Course ${m.playingHandicap}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme
                              .onSecondaryContainer,
                        ),
                      ),
                    ),
                  ]),
                ),

                // Running totals — Gross always; Net on a second row only when
                // the player receives strokes (skip for gross games / scratch).
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Gross ${_toPar(rt.grossVsPar)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary)),
                    if (effectiveHcap(m) > 0)
                      Text('Net ${_toPar(rt.netVsPar)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.secondary)),
                  ],
                ),
                const SizedBox(width: 8),

                // Score box
                GestureDetector(
                  onTap: hasScore && onEditTap != null
                      ? () => onEditTap!(m)
                      : null,
                  child: gross != null
                      // Scored: NetScoreButton (golf colors + circle/square).
                      ? scoreCellWithDots(
                          NetScoreButton(
                            score:    gross,
                            par:      par,
                            strokes:  strokes,
                            selected: false,
                            width:    40,
                            height:   36,
                          ),
                          strokes,
                          theme.colorScheme.primary,
                        )
                      // Empty: plain box, hot highlight when active.
                      : AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 40,
                          height: 36,
                          decoration: BoxDecoration(
                            color: boxBg,
                            border: boxBorder,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                ),
              ]),
            );

            // Inline picker — hot spot only, hidden in read-only mode.
            final picker = isHot && !hasScore && onScoreSelected != null
                ? _InlineScorePicker(
                    par:             par,
                    strokes:         strokes,
                    currentScore:    null,
                    onScoreSelected: (s) => onScoreSelected!(m, s),
                  )
                : const SizedBox.shrink();

            return [playerRow, picker];
          }),

          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ===========================================================================
// Inline score picker — scrollable 1–12, opens with par-2 as first visible
// button so par is naturally the 3rd (par-2, par-1, par …).
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
  // Size each button so ~6 fit in view on a typical phone.
  static const _itemWidth  = 50.0;
  static const _itemMargin = 4.0;
  static const _itemTotal  = _itemWidth + _itemMargin * 2;

  late final ScrollController _ctrl;

  // Scroll so that net-par-2 is the first visible button (net par becomes 3rd).
  double _initialOffset() {
    final firstIdx = (widget.par + widget.strokes - 3).clamp(0, 9);
    return firstIdx * _itemTotal;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = ScrollController(initialScrollOffset: _initialOffset());
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
        itemCount: scores.length,
        itemBuilder: (_, i) {
          final s = scores[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
            child: NetScoreButton(
              score:    s,
              par:      widget.par,
              strokes:  widget.strokes,
              selected: s == widget.currentScore,
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

class _ScorePickerSheet extends StatefulWidget {
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
  State<_ScorePickerSheet> createState() => _ScorePickerSheetState();
}

class _ScorePickerSheetState extends State<_ScorePickerSheet> {
  static const _itemWidth  = 50.0;
  static const _itemMargin = 4.0;
  static const _itemTotal  = _itemWidth + _itemMargin * 2;

  late final ScrollController _ctrl;

  @override
  void initState() {
    super.initState();
    final firstIdx = (widget.par + widget.strokes - 3).clamp(0, 9);
    _ctrl = ScrollController(initialScrollOffset: firstIdx * _itemTotal);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final netPar = widget.par + widget.strokes;
    final scores = List.generate(12, (i) => i + 1);

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
            widget.playerName,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          Text(
            widget.strokes > 0
                ? 'Hole ${widget.holeNumber}  •  Par ${widget.par}  •  Net par $netPar'
                : 'Hole ${widget.holeNumber}  •  Par ${widget.par}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: ListView.builder(
              controller:      _ctrl,
              scrollDirection: Axis.horizontal,
              padding:         EdgeInsets.zero,
              itemCount:       scores.length,
              itemBuilder: (_, i) {
                final s = scores[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: _itemMargin),
                  child: NetScoreButton(
                    score:    s,
                    par:      widget.par,
                    strokes:  widget.strokes,
                    selected: s == widget.current,
                    width:    _itemWidth,
                    height:   52,
                    onTap:    () => Navigator.of(context).pop(s),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          if (widget.current != null)
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
  final int Function(Membership, ScorecardHole?) strokesForHole;

  const _LandscapeGrid({
    required this.scorecard,
    required this.players,
    required this.pendingScores,
    required this.currentHole,
    required this.totals,
    required this.strokesForHole,
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
                Text('Course ${m.playingHandicap}',
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
    final holeData    = widget.scorecard.holeData(hole);
    final saved       = holeData?.scoreFor(m.player.id);
    final pending     = widget.pendingScores[hole]?[m.player.id];
    final gross       = pending ?? saved?.grossScore;
    final par         = holeData?.par ?? 4;
    final isCurrent   = hole == widget.currentHole;
    final isLocalOnly = pending != null;
    final strokes     = widget.strokesForHole(m, holeData);

    // No red/green cell fill — the digit carries the golf color (red net
    // under par, black at/over) + circle/square via scoreMark below.
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

