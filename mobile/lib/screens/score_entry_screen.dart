/// screens/score_entry_screen.dart
/// --------------------------------
/// Universal score-entry screen that handles all casual-game combinations.
///
/// Replaces the individual game play screens (nassau_screen.dart,
/// skins_screen.dart, sixes_screen.dart, points_531_screen.dart).
///
/// Layout (top → bottom):
///   • Nassau team banner   (Nassau only)
///   • Nassau presses strip (Nassau only)
///   • Scrollable body:
///       – Active hole card (player rows + inline picker + skins junk)
///       – Game status section (Nassau grid, Skins standings, etc.)
///   • Bottom bar:
///       – Nassau F9/B9/ALL status + optional Call Press
///       – Skins per-hole winner strip
///       – Hole ← Prev | Next → navigation / Done button

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';

// ---------------------------------------------------------------------------
// Handicap helpers (shared with nassau_screen.dart)
// ---------------------------------------------------------------------------

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
      // Apply the same net_percent scaling the backend uses:
      // so = round(diff * net_percent / 100)
      return (off * netPercent / 100.0).round();
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

/// Per-player, per-hole strokes for a Sixes Strokes-Off match.
///
/// Mirrors the backend algorithm in scoring/handicap.py (_sixes_so_plan).
/// Uses the current SixesSummary segment boundaries (which the backend updates
/// after each hole) so dying strokes and early-finish repositioning are handled
/// identically to the calculation.
///
/// Standard matches: the player receives
///     floor(SO/3) + (1 if match_idx < SO%3 else 0)
/// strokes, allocated to the hardest holes (lowest SI) in that segment's own
/// potential range.  If the segment ended early (next segment starts before
/// seg.endHole+1), any stroke planned on an unreached hole dies.
/// Extras: one stroke on any hole in the segment whose SI <= player's SO.
int _sixesSoStrokesOnHole({
  required int playerSo,
  required int holeNumber,
  required int strokeIndex,
  required SixesSummary summary,
  required Scorecard scorecard,
}) {
  if (playerSo <= 0) return 0;

  final segments = summary.segments;

  // Extra (tiebreak) segment: simple SI-threshold rule.
  for (final s in segments) {
    if (s.isExtra && holeNumber >= s.startHole && holeNumber <= s.endHole) {
      return strokeIndex <= playerSo ? 1 : 0;
    }
  }

  // Standard segment: find the segment this hole belongs to.
  // Iterate in reverse so that when an earlier match ends early and the next
  // segment's startHole shifts left, the later segment wins the overlap.
  final standard = segments.where((s) => !s.isExtra).toList();
  int? stdIdx;
  SixesSegment? seg;
  for (int i = standard.length - 1; i >= 0; i--) {
    final s = standard[i];
    if (holeNumber >= s.startHole && holeNumber <= s.endHole) {
      stdIdx = i;
      seg = s;
      break;
    }
  }
  if (seg == null || stdIdx == null) return 0;

  final base             = playerSo ~/ 3;
  final rem              = playerSo %  3;
  final strokesThisMatch = base + (stdIdx < rem ? 1 : 0);
  if (strokesThisMatch <= 0) return 0;

  // Actual last hole played: one before the next segment's start, or 18.
  final segListIdx = segments.indexOf(seg);
  int actualEnd = 18;
  for (int i = segListIdx + 1; i < segments.length; i++) {
    if (segments[i].startHole > seg.startHole) {
      actualEnd = segments[i].startHole - 1;
      break;
    }
  }

  // Rank holes in this segment's potential range hardest-first (lowest SI);
  // hole number is the deterministic tiebreak, matching the backend.
  final holes = [for (int h = seg.startHole; h <= seg.endHole; h++) h];
  holes.sort((a, b) {
    final aSi = scorecard.holeData(a)?.strokeIndex ?? 18;
    final bSi = scorecard.holeData(b)?.strokeIndex ?? 18;
    if (aSi != bSi) return aSi.compareTo(bSi);
    return a.compareTo(b);
  });
  final rank    = holes.indexOf(holeNumber);
  if (rank < 0) return 0;

  final segSize = holes.length;
  int planned;
  if (strokesThisMatch <= segSize) {
    planned = rank < strokesThisMatch ? 1 : 0;
  } else {
    // More strokes than holes: everyone gets 1, extras go to hardest holes.
    final extra = strokesThisMatch - segSize;
    planned = 1 + (rank < extra ? 1 : 0);
  }

  // Dying strokes: match ended before this hole.
  if (holeNumber > actualEnd) return 0;
  return planned;
}

String _signed(int v) => v > 0 ? '(+$v)' : '($v)';

String _fmtPoints(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

class _RunningTotal {
  final int grossVsPar;
  final int netVsPar;
  const _RunningTotal({required this.grossVsPar, required this.netVsPar});
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class ScoreEntryScreen extends StatefulWidget {
  final int foursomeId;
  const ScoreEntryScreen({super.key, required this.foursomeId});

  @override
  State<ScoreEntryScreen> createState() => _ScoreEntryScreenState();
}

class _ScoreEntryScreenState extends State<ScoreEntryScreen> {
  /// Unsubmitted score edits: hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  /// Unsubmitted skins-junk edits: hole → playerId → count.
  final Map<int, Map<int, int>> _pendingJunk = {};

  int  _selectedHole    = 1;
  bool _initialJumpDone = false;

  /// startHole of every Sixes extras segment we've already auto-opened the
  /// team picker for.  Prevents an infinite modal loop when the user cancels.
  final Set<int> _autoOpenedExtraStart = {};

  // Sync-drain watcher — detects when the pending queue empties so we can
  // reload game summaries immediately.  Uses a direct ChangeNotifier listener
  // rather than build()-time tracking because on localhost the entire
  // enqueue→drain cycle completes in <1 frame, causing the build-time
  // _prevHadPending check to miss the 0→1→0 transition.
  SyncService?   _syncRef;
  VoidCallback?  _syncWatcher;
  bool           _wasPending = false;

  // Periodic refresh for match play and three-person match — polls every 3 s.
  // Event-driven approaches (syncWatcher, waitUntilIdle) are unreliable because
  // the drain can complete before the listener fires or before the provider
  // notifies.  A 3-second poll is imperceptible to the user during scoring.
  Timer?         _matchPlayTimer;

  @override
  void initState() {
    super.initState();
    // Start the refresh timer immediately — timer callbacks fire on the main
    // isolate and context/mounted are safe to use inside them (guarded below).
    // Keeping this outside addPostFrameCallback avoids a class of bugs where
    // exceptions earlier in the callback silently prevent timer creation.
    _matchPlayTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final rp         = context.read<RoundProvider>();
      final games      = _activeGames(rp.round);
      final configured = _configuredGames(rp.round);
      final hasData    = rp.matchPlayData != null;
      if (games.contains('match_play') ||
          configured.contains('match_play') ||
          hasData) {
        rp.loadMatchPlay(widget.foursomeId);
      }
      // Three-person match also needs live updates during tiebreak / phase 2.
      if (games.contains('three_person_match') ||
          configured.contains('three_person_match') ||
          rp.threePersonMatchSummary != null) {
        rp.loadThreePersonMatch(widget.foursomeId);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rp   = context.read<RoundProvider>();
      final sync = context.read<SyncService>();

      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      } else {
        rp.refreshPendingOverlay();
      }
      _loadGameSummaries(rp);

      // Register a direct listener so we catch the pending→idle transition
      // even when it completes within a single frame.
      _syncRef    = sync;
      _wasPending = sync.hasPending;
      _syncWatcher = () {
        if (!mounted) return;
        final nowPending = sync.hasPending;
        if (_wasPending && !nowPending) {
          _loadGameSummaries(context.read<RoundProvider>());
        }
        _wasPending = nowPending;
      };
      sync.addListener(_syncWatcher!);
    });
  }

  @override
  void dispose() {
    _syncRef?.removeListener(_syncWatcher!);
    _matchPlayTimer?.cancel();
    super.dispose();
  }

  // ── Active games ────────────────────────────────────────────────────────────

  /// Returns the union of round-level and foursome-level active games.
  ///
  /// Round-level games (irish_rumble, pink_ball, stableford, stroke_play)
  /// apply to every foursome in the round.  Per-foursome games (match_play,
  /// nassau, skins, sixes) are additions stored on the foursome itself.
  /// Merging both lists ensures all games are visible in the score entry
  /// screen regardless of which level they were configured at.
  List<String> _activeGames(Round? round) {
    if (round == null) return [];
    final fs = round.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    final fsGames = fs?.activeGames ?? [];
    final rdGames = round.activeGames;
    // Union: always include round-level games; foursome-level adds on top.
    return {...rdGames, ...fsGames}.toList();
  }

  /// Games already configured for this foursome (bracket / game-model row exists).
  List<String> _configuredGames(Round? round) {
    if (round == null) return [];
    final fs = round.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    return fs?.configuredGames ?? [];
  }

  void _loadGameSummaries(RoundProvider rp) {
    final games      = _activeGames(rp.round);
    final configured = _configuredGames(rp.round);
    if (games.contains('nassau'))        rp.loadNassau(widget.foursomeId);
    if (games.contains('skins'))         rp.loadSkins(widget.foursomeId);
    if (games.contains('sixes'))         rp.loadSixes(widget.foursomeId);
    if (games.contains('points_531'))    rp.loadPoints531(widget.foursomeId);
    // Stroke Play stores handicap mode in its own config (not the round object).
    if (games.contains('low_net_round') && rp.round != null)
      rp.loadLowNetConfig(rp.round!.id);
    // Load match play if it's in the active game list OR if a bracket has
    // already been configured (handles cases where match_play is set at the
    // foursome level but the games list resolution missed it).
    // Load match play if configured, or if we already have data (refresh it).
    if (games.contains('match_play') ||
        configured.contains('match_play') ||
        rp.matchPlayData != null)
      rp.loadMatchPlay(widget.foursomeId);
    if (games.contains('three_person_match') || configured.contains('three_person_match'))
      rp.loadThreePersonMatch(widget.foursomeId);
    // Initialise phantom player if this foursome has one.  Idempotent —
    // the provider skips the network call if already done.
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs?.hasPhantom == true) rp.initPhantom(widget.foursomeId);
  }

  // ── Handicap mode for stroke-dot display ────────────────────────────────────

  /// Pick the handicap mode + net% from the most relevant active game summary.
  /// Priority: Stroke Play > Nassau > Skins > Sixes > Points 5-3-1 > Round defaults.
  ///
  /// Stroke Play (low_net_round) is checked first because it is mutually
  /// exclusive with the casual gambling games and stores its handicap mode in a
  /// separate config endpoint — NOT on the top-level round object.
  (String mode, int netPercent) _handicapParams(
    RoundProvider rp,
    List<String> games,
  ) {
    if (games.contains('low_net_round') && rp.lowNetConfig != null) {
      final mode = rp.lowNetConfig!['handicap_mode'] as String? ?? 'net';
      final pct  = rp.lowNetConfig!['net_percent']  as int?    ?? 100;
      return (mode, pct);
    }
    if (games.contains('nassau') && rp.nassauSummary != null) {
      return (rp.nassauSummary!.handicapMode, rp.nassauSummary!.netPercent);
    }
    if (games.contains('skins') && rp.skinsSummary != null) {
      return (rp.skinsSummary!.handicapMode, rp.skinsSummary!.netPercent);
    }
    if (games.contains('sixes') && rp.sixesSummary != null) {
      return (rp.sixesSummary!.handicapMode, rp.sixesSummary!.netPercent);
    }
    if (games.contains('points_531') && rp.points531Summary != null) {
      return (rp.points531Summary!.handicapMode, rp.points531Summary!.netPercent);
    }
    return (rp.round?.handicapMode ?? 'net', rp.round?.netPercent ?? 100);
  }

  // ── Sixes extra-match team helpers ──────────────────────────────────────────

  /// Returns the extras segment covering [hole] that still has no teams
  /// assigned, or null if teams are set / not an extras hole.
  SixesSegment? _unconfiguredExtraForHole(int hole, SixesSummary? summary) {
    if (summary == null) return null;
    for (final s in summary.segments.reversed) {
      if (!s.isExtra) continue;
      if (hole < s.startHole || hole > s.endHole) continue;
      if (s.team1.hasPlayers && s.team2.hasPlayers) return null;
      return s;
    }
    return null;
  }

  /// Opens the extra-match team picker sheet, then persists the result.
  Future<void> _showExtraTeamPicker(
    SixesSegment extraSeg,
    List<Membership> players,
  ) async {
    final result = await showModalBottomSheet<List<List<int>>>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => _ExtraTeamPickerSheet(members: players),
    );
    if (result == null || !mounted) return;
    final rp = context.read<RoundProvider>();
    final ok = await rp.setExtraTeams(widget.foursomeId, result[0], result[1]);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Failed to save extra match teams.'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  // ── Player ordering ─────────────────────────────────────────────────────────

  /// Real (non-phantom) players.  Nassau-ordered (T1 then T2) when available.
  List<Membership> _orderedPlayers(
    Scorecard sc,
    Round? round,
    NassauSummary? nas,
  ) {
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

    if (nas == null) return members;

    final ordered = <Membership>[];
    for (final id in [
      ...nas.team1.map((p) => p.playerId),
      ...nas.team2.map((p) => p.playerId),
    ]) {
      final m = members.where((m) => m.player.id == id).firstOrNull;
      if (m != null) ordered.add(m);
    }
    for (final m in members) {
      if (!ordered.any((o) => o.player.id == m.player.id)) ordered.add(m);
    }
    return ordered;
  }

  // ── Score helpers ────────────────────────────────────────────────────────────

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = _orderedPlayers(sc, rp.round, rp.nassauSummary)
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
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  void _adjustJunk(int playerId, int hole, int delta) {
    setState(() {
      final map = _pendingJunk.putIfAbsent(hole, () => {});
      final cur = map[playerId] ?? 0;
      final next = (cur + delta).clamp(0, 20);
      if (next == 0) {
        map.remove(playerId);
        if (map.isEmpty) _pendingJunk.remove(hole);
      } else {
        map[playerId] = next;
      }
    });
  }

  int _currentJunk(int playerId, int hole, SkinsSummary? skins) {
    if (_pendingJunk[hole]?.containsKey(playerId) == true) {
      return _pendingJunk[hole]![playerId]!;
    }
    // Fall back to last saved junk count from the skins summary.
    if (skins == null) return 0;
    final holeData = skins.holes.where((h) => h.hole == hole).firstOrNull;
    if (holeData == null) return 0;
    final entry = holeData.junk.where((j) => j.playerId == playerId).firstOrNull;
    return entry?.count ?? 0;
  }

  // ── Navigation ───────────────────────────────────────────────────────────────

  void _advance() {
    if (_selectedHole < 18) setState(() => _selectedHole++);
  }

  void _retreat() {
    if (_selectedHole > 1) setState(() => _selectedHole--);
  }

  // ── Save & advance ───────────────────────────────────────────────────────────

  Future<void> _saveAndAdvance(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final scoreEdits = _pending[_selectedHole];
    final junkEdits  = _pendingJunk[_selectedHole];

    if ((scoreEdits == null || scoreEdits.isEmpty) &&
        (junkEdits == null || junkEdits.isEmpty)) {
      _advance();
      return;
    }

    final rp = context.read<RoundProvider>();

    // Submit scores if any.
    if (scoreEdits != null && scoreEdits.isNotEmpty) {
      final scores = scoreEdits.entries
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
            onPressed: () => _saveAndAdvance(ctx, players, par),
          ),
        ));
        return;
      }
      setState(() { _pending.remove(_selectedHole); });
    }

    // Submit skins junk if any.
    if (junkEdits != null && junkEdits.isNotEmpty) {
      await _submitJunk(_selectedHole, junkEdits);
    }

    // Immediate reload (may be before sync drains — that's fine, gives quick
    // feedback for other games like Nassau/Skins that recalculate server-side).
    _loadGameSummaries(rp);

    // Definitive reload after sync drain — guarantees match play and other
    // tournament-level summaries reflect the just-submitted score.  Uses
    // waitUntilIdle() so it fires correctly whether the drain is instant
    // (localhost) or delayed (real network).
    context.read<SyncService>().waitUntilIdle().then((_) {
      if (mounted) _loadGameSummaries(context.read<RoundProvider>());
    });

    _advance();
  }

  Future<void> _submitJunk(int hole, Map<int, int> edits) async {
    final client  = context.read<AuthProvider>().client;
    final entries = edits.entries
        .map((e) => {'player_id': e.key, 'junk_count': e.value})
        .toList();
    try {
      await client.postSkinsJunk(
        widget.foursomeId,
        holeNumber:  hole,
        junkEntries: entries,
      );
      if (mounted) setState(() { _pendingJunk.remove(hole); });
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

    final scoreEdits = _pending[_selectedHole];
    final junkEdits  = _pendingJunk[_selectedHole];

    if (scoreEdits != null && scoreEdits.isNotEmpty) {
      final scores = scoreEdits.entries
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

    if (junkEdits != null && junkEdits.isNotEmpty) {
      await _submitJunk(_selectedHole, junkEdits);
    }

    await sync.waitUntilIdle();
    if (!mounted) return;
    _loadGameSummaries(rp);
    if (roundId != null) {
      Navigator.of(ctx).pushNamed('/leaderboard', arguments: roundId);
    }
  }

  // ── Nassau press ─────────────────────────────────────────────────────────────

  Future<void> _callPress(RoundProvider rp, int startHole) async {
    final ok = await rp.callNassauPress(
      widget.foursomeId,
      startHole: startHole,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Could not call press.'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  int _pressStartHole(NassauSummary nas) {
    final lastPlayed = nas.holes.isEmpty ? 0 : nas.holes.last.hole;
    return lastPlayed + 1;
  }

  // ── App bar title ────────────────────────────────────────────────────────────

  String _appBarTitle(List<String> games, NassauSummary? nas, SkinsSummary? sk) {
    final parts = <String>[];
    const labels = {
      'nassau'       : 'Nassau',
      'skins'        : 'Skins',
      'sixes'        : "Six's",
      'points_531'   : 'Points 5-3-1',
      'match_play'   : 'Match Play',
      'low_net_round': 'Stroke Play',
      'stableford'   : 'Stableford',
    };
    for (final g in games) {
      String label = labels[g] ?? g;
      if (g == 'nassau' && nas != null) {
        final modeStr = _modeLabel(nas.handicapMode, nas.netPercent);
        label = 'Nassau ($modeStr)';
      } else if (g == 'skins' && sk != null) {
        final modeStr = _modeLabel(sk.handicapMode, sk.netPercent);
        label = 'Skins ($modeStr)';
      }
      parts.add(label);
    }
    return parts.isEmpty ? 'Score Entry' : parts.join(' + ');
  }

  static String _modeLabel(String mode, int netPercent) {
    if (mode == 'gross')       return 'Gross';
    if (mode == 'strokes_off') return 'SO';
    return netPercent == 100 ? 'Net' : 'Net $netPercent%';
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp         = context.watch<RoundProvider>();
    final sync       = context.watch<SyncService>();
    final sc         = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';
    final games      = _activeGames(rp.round);
    // Gate summaries on the active game list so stale summaries from a prior
    // game in the same session never bleed into unrelated games.
    final nas        = games.contains('nassau') ? rp.nassauSummary : null;
    final skins      = games.contains('skins')  ? rp.skinsSummary  : null;

    // Jump to first unplayed hole once scorecard is loaded.
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
        title: Text(
          _appBarTitle(games, nas, skins),
          style: const TextStyle(fontSize: 15),
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
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: rp.round!.id),
          ),
        ],
      ),
      body: _buildBody(context, rp, sync, sc, nas, skins, games, isComplete),
      bottomNavigationBar:
          sc == null ? null : _buildBottomBar(context, rp, sc, nas, games),
    );
  }

  // ── Bottom bar ────────────────────────────────────────────────────────────────

  Widget _buildBottomBar(
    BuildContext ctx,
    RoundProvider rp,
    Scorecard sc,
    NassauSummary? nas,
    List<String> games,
  ) {
    final players    = _orderedPlayers(sc, rp.round, nas);
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final par        = sc.holeData(_selectedHole)?.par ?? 4;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Nassau match status bar
          if (nas != null)
            _MatchStatusBar(
              summary:    nas,
              onPress:    nas.canPress
                  ? () => _callPress(rp, _pressStartHole(nas))
                  : null,
              submitting: rp.submitting,
            ),
          // Hole navigation
          Padding(
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
        ],
      ),
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────────

  Widget _buildBody(
    BuildContext ctx,
    RoundProvider rp,
    SyncService sync,
    Scorecard? sc,
    NassauSummary? nas,
    SkinsSummary? skins,
    List<String> games,
    bool isComplete,
  ) {
    if (rp.loadingScorecard && sc == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && sc == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(rp.error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              rp.loadScorecard(widget.foursomeId);
              _loadGameSummaries(rp);
            },
            child: const Text('Retry'),
          ),
        ]),
      );
    }
    if (sc == null) return const SizedBox.shrink();

    final players  = _orderedPlayers(sc, rp.round, nas);
    final merged   = _mergePending(rp.localPendingByHole, _pending);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;
    final (hMode, hPct) = _handicapParams(rp, games);
    final allowJunk = games.contains('skins') && (skins?.allowJunk ?? false);

    // Sixes extra-match team gating: auto-open the picker the first time the
    // user navigates into an extras hole that has no teams assigned yet.
    final needsTeamsSeg = games.contains('sixes')
        ? _unconfiguredExtraForHole(_selectedHole, rp.sixesSummary)
        : null;
    if (needsTeamsSeg != null &&
        !_autoOpenedExtraStart.contains(needsTeamsSeg.startHole)) {
      _autoOpenedExtraStart.add(needsTeamsSeg.startHole);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showExtraTeamPicker(needsTeamsSeg, players);
      });
    }

    return Column(children: [
      // Nassau team banner
      if (nas != null) _TeamBanner(summary: nas),

      // Nassau presses strip
      if (nas != null && nas.presses.isNotEmpty)
        _PressesStrip(
          presses:     nas.presses,
          currentHole: _selectedHole,
        ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Active hole score card
              _HoleScoreCard(
                holeData:        holeData,
                holeNumber:      _selectedHole,
                players:         players,
                scorecard:       sc,
                merged:          merged,
                scores:          scores,
                hotSpotIdx:      hotSpot,
                par:             par,
                nassau:          nas,
                skins:           skins,
                // Only pass sixesSummary when Sixes is actually active — a
                // stale summary from a prior Sixes game must not bleed into
                // P531 or other games and trigger the wrong SO algorithm.
                sixesSummary:    games.contains('sixes')      ? rp.sixesSummary    : null,
                points531Summary: games.contains('points_531') ? rp.points531Summary : null,
                handicapMode:    hMode,
                netPercent:      hPct,
                allowJunk:       allowJunk,
                junkForPlayer:   (pid) => _currentJunk(pid, _selectedHole, skins),
                blockedExtraSeg: needsTeamsSeg,
                onOpenExtraTeamsPicker: needsTeamsSeg == null
                    ? null
                    : () => _showExtraTeamPicker(needsTeamsSeg, players),
                onScoreSelected: (m, score) =>
                    _selectScore(m, score, _selectedHole),
                onEditTap: (m) =>
                    _editScore(ctx, m, par, _selectedHole, players, hMode, hPct),
                onJunkAdd:    (pid) => _adjustJunk(pid, _selectedHole, 1),
                onJunkRemove: (pid) => _adjustJunk(pid, _selectedHole, -1),
                // Phantom player data (null when foursome has no phantom).
                phantomMembership: rp.round?.foursomes
                    .where((f) => f.id == widget.foursomeId)
                    .firstOrNull
                    ?.memberships
                    .where((m) => m.player.isPhantom)
                    .firstOrNull,
                phantomInit: rp.phantomInitFor(widget.foursomeId),
              ),
              const SizedBox(height: 12),

              // Game status cards
              _GameStatusSection(
                games:                   games,
                nassau:                  nas,
                skins:                   skins,
                sixesSummary:            games.contains('sixes')             ? rp.sixesSummary              : null,
                points531Summary:        games.contains('points_531')        ? rp.points531Summary           : null,
                matchPlayData:           rp.matchPlayData,
                threePersonMatchSummary: games.contains('three_person_match') ? rp.threePersonMatchSummary   : null,
                foursomeId:              widget.foursomeId,
                players:                 players,
                scorecard:               sc,
                currentHole:             _selectedHole,
                loadingNassau:           rp.loadingNassau,
                loadingSkins:            rp.loadingSkins,
                loadingPoints531:        rp.loadingPoints531,
                loadingMatchPlay:        rp.loadingMatchPlay,
                loadingThreePersonMatch: rp.loadingThreePersonMatch,
                onTapHole:               (h) => setState(() => _selectedHole = h),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    ]);
  }

  Future<void> _editScore(
    BuildContext ctx,
    Membership player,
    int par,
    int hole,
    List<Membership> players,
    String hMode,
    int hPct,
  ) async {
    final rp      = context.read<RoundProvider>();
    final sc      = rp.scorecard;
    final current = (_pending[hole] ?? {})[player.player.id]
        ?? sc?.holeData(hole)?.scoreFor(player.player.id)?.grossScore;

    final lowPlaying = hMode == 'strokes_off' && players.isNotEmpty
        ? players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b)
        : null;
    final effective = _effectiveHandicap(
      mode:                  hMode,
      netPercent:            hPct,
      playingHandicap:       player.playingHandicap,
      lowestPlayingHandicap: lowPlaying,
    );
    final holeEntry = sc?.holeData(hole)?.scoreFor(player.player.id);
    final si        = holeEntry?.strokeIndex ?? sc?.holeData(hole)?.strokeIndex ?? 18;

    // Sixes SO: use the exact per-segment algorithm so the modal picker
    // colors match the inline picker and the backend calculation.
    // Guard on games.contains('sixes') so a stale sixesSummary from a prior
    // Sixes game never bleeds into P531 or other strokes-off games.
    final int strokes;
    final games = _activeGames(rp.round);
    if (hMode == 'strokes_off' && games.contains('sixes') &&
        rp.sixesSummary != null && sc != null) {
      final so = effective; // _effectiveHandicap already computed SO = own - low
      strokes = _sixesSoStrokesOnHole(
        playerSo:    so,
        holeNumber:  hole,
        strokeIndex: si,
        summary:     rp.sixesSummary!,
        scorecard:   sc,
      );
    } else {
      strokes = _strokesOnHole(effective, si);
    }

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
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }
}

// ===========================================================================
// Active-hole score card
// ===========================================================================

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?          holeData;
  final int                     holeNumber;
  final List<Membership>        players;
  final Scorecard               scorecard;
  final Map<int, Map<int, int>> merged;
  final Map<int, int>           scores;
  final int                     hotSpotIdx;
  final int                     par;
  final NassauSummary?          nassau;
  final SkinsSummary?           skins;
  final SixesSummary?           sixesSummary;
  final Points531Summary?       points531Summary;
  final String                  handicapMode;
  final int                     netPercent;
  final bool                    allowJunk;
  final int  Function(int pid)  junkForPlayer;

  /// Non-null when the current hole is inside a Sixes extras segment that
  /// has no teams assigned yet.  Score entry is disabled until teams are set.
  final SixesSegment?           blockedExtraSeg;

  /// Callback that re-opens the extra-match team picker (for users who
  /// dismissed the auto-open modal without selecting teams).
  final VoidCallback?           onOpenExtraTeamsPicker;

  /// Phantom player membership — null when the foursome has no phantom.
  final Membership?         phantomMembership;
  /// Result of PhantomInitView — contains per-hole source player mapping.
  final PhantomInitResult?  phantomInit;

  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership)      onEditTap;
  final void Function(int pid)  onJunkAdd;
  final void Function(int pid)  onJunkRemove;

  const _HoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.merged,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.nassau,
    required this.skins,
    this.sixesSummary,
    this.points531Summary,
    required this.handicapMode,
    required this.netPercent,
    required this.allowJunk,
    required this.junkForPlayer,
    this.blockedExtraSeg,
    this.onOpenExtraTeamsPicker,
    required this.onScoreSelected,
    required this.onEditTap,
    required this.onJunkAdd,
    required this.onJunkRemove,
    this.phantomMembership,
    this.phantomInit,
  });

  int? get _lowPlayingHandicap {
    if (handicapMode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null || handicapMode == 'gross') return 0;
    final entry = h.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? h.strokeIndex;

    if (handicapMode == 'net') {
      if (netPercent == 100 && entry != null) return entry.handicapStrokes;
      final effective = (m.playingHandicap * netPercent / 100.0).round();
      return _strokesOnHole(effective, mySi);
    }
    if (handicapMode == 'strokes_off') {
      final low = _lowPlayingHandicap;
      if (low == null) return 0;
      final rawSo = m.playingHandicap - low;
      if (rawSo <= 0) return 0;
      // Apply the same net_percent scaling the backend uses.
      final so = (rawSo * netPercent / 100.0).round();
      if (so <= 0) return 0;
      // Sixes: use the exact per-segment allocation so colors match the
      // backend calculation exactly (segment boundaries, dying strokes, etc).
      if (sixesSummary != null) {
        return _sixesSoStrokesOnHole(
          playerSo:    so,
          holeNumber:  holeNumber,
          strokeIndex: mySi,
          summary:     sixesSummary!,
          scorecard:   scorecard,
        );
      }
      // Non-Sixes SO: 18-hole SI threshold.
      return _strokesOnHole(so, mySi);
    }
    return 0;
  }

  int _effectiveHcap(Membership m) => _effectiveHandicap(
        mode:                  handicapMode,
        netPercent:            netPercent,
        playingHandicap:       m.playingHandicap,
        lowestPlayingHandicap: _lowPlayingHandicap,
      );

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

  String? _teamLabelFor(int playerId) {
    if (nassau == null) return null;
    if (nassau!.team1.any((p) => p.playerId == playerId)) return 'T1';
    if (nassau!.team2.any((p) => p.playerId == playerId)) return 'T2';
    return null;
  }

  SkinsHole? _skinsHoleData(int hole) {
    if (skins == null) return null;
    return skins!.holes.where((h) => h.hole == hole).firstOrNull;
  }

  /// How many skins are on the line entering [hole].
  /// Walks backward through resolved holes: each consecutive trailing tie
  /// (isCarry = true, no winner) adds 1 to the pot.  Resets to 1 after a
  /// winner or a killed skin (no carryover).
  static int _currentCarryPot(SkinsSummary skins, int hole) {
    int pot = 1;
    // Walk holes 1..(hole-1) in order, reset/accumulate.
    for (int h = 1; h < hole; h++) {
      final hd = skins.holes.where((x) => x.hole == h).firstOrNull;
      if (hd == null) break; // not yet scored, pot stays
      if (hd.winnerId != null || hd.isDead) {
        pot = 1; // winner claimed or skin killed — reset
      } else if (hd.isCarry) {
        pot++; // tie with carryover — accumulate
      }
    }
    return pot;
  }

  /// Points awarded to each player on `holeNumber`, or empty map if not yet scored.
  Map<int, double> _p531HolePoints() {
    final s = points531Summary;
    if (s == null) return const {};
    final h = s.holes.where((h) => h.hole == holeNumber).firstOrNull;
    if (h == null) return const {};
    return { for (final e in h.entries) e.playerId: e.points };
  }

  /// Cumulative Points 5-3-1 total for a player (from server summary).
  double _p531CumulativeFor(int playerId) {
    final s = points531Summary;
    if (s == null) return 0.0;
    return s.players
        .where((p) => p.playerId == playerId)
        .firstOrNull
        ?.points ?? 0.0;
  }

  static String _buildHoleHeader(ScorecardHole hole, List<Membership> players) {
    final seenKeys = <int>{};
    final parVals  = <int>[];
    final yardVals = <int?>[];
    final siVals   = <int>[];
    for (final m in players) {
      final key = m.tee?.id ?? -m.player.id;
      if (!seenKeys.add(key)) continue;
      final e = hole.scoreFor(m.player.id);
      parVals.add(e?.par   ?? hole.par);
      yardVals.add(e?.yards ?? hole.yards);
      siVals.add(e?.strokeIndex ?? hole.strokeIndex);
    }

    String collapse<T>(List<T> values, String Function(T) fmt) {
      if (values.isEmpty) return '';
      final seen   = <T>{};
      final unique = values.where((v) => seen.add(v)).toList();
      return unique.length == 1 ? fmt(unique.first) : unique.map(fmt).join('/');
    }

    final parStr  = 'Par ${collapse<int>(parVals, (v) => '$v')}';
    final siStr   = 'SI: ${collapse<int>(siVals,  (v) => '$v')}';
    final anyYards = yardVals.any((y) => y != null);
    final yardStr = anyYards
        ? '${collapse<int?>(yardVals, (v) => v == null ? '—' : '$v')} yds.'
        : null;

    return yardStr == null ? '$parStr  |  $siStr' : '$parStr  |  $yardStr  |  $siStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Nassau hole result
    final nassauHole = nassau?.holes
        .where((h) => h.hole == holeNumber)
        .firstOrNull;

    // Skins hole outcome
    final skinsHole = _skinsHoleData(holeNumber);

    // Carry pot: how many skins are on the line for this hole.
    // Only meaningful when the hole hasn't been decided yet.
    final carryPot = (skins != null && skinsHole?.winnerId == null)
        ? _currentCarryPot(skins!, holeNumber)
        : 1;

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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Column(children: [
              Text('Hole $holeNumber',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              if (holeData != null)
                Text(
                  _buildHoleHeader(holeData!, players),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
            ]),
          ),

          // Nassau hole outcome banner
          if (nassauHole != null && nassauHole.winner != null)
            _NassauHoleOutcome(hole: nassauHole, nassau: nassau!),

          // Skins hole outcome banner
          if (skinsHole != null && skinsHole.winnerShort != null)
            _SkinsHoleOutcome(skinsHole: skinsHole),

          // Carry pot chip — shown when >1 skin is on the line and hole
          // is not yet decided.
          if (skins != null && skinsHole?.winnerId == null && carryPot > 1)
            _SkinsCarryChip(pot: carryPot),

          // Player rows + inline picker
          ...players.asMap().entries.expand((entry) {
            final idx        = entry.key;
            final m          = entry.value;
            final rt         = _running(m.player.id);
            final gross      = scores[m.player.id];
            final isHot      = idx == hotSpotIdx;
            final matchStrok = _strokesForHole(m, holeData);

            String? hcapLabel;
            if (handicapMode == 'net' || handicapMode == 'strokes_off') {
              final dots = matchStrok > 0 ? ' ${'•' * matchStrok}' : '';
              hcapLabel = '-${_effectiveHcap(m)}$dots';
            }

            final junkCount = allowJunk ? junkForPlayer(m.player.id) : 0;

            // Points 5-3-1: per-hole award and cumulative total.
            final p531Hole       = points531Summary != null
                ? _p531HolePoints()[m.player.id]
                : null;
            final p531Cumulative = points531Summary != null
                ? _p531CumulativeFor(m.player.id)
                : null;

            return [
              _PlayerRow(
                member:              m,
                running:             rt,
                gross:               gross,
                isHot:               isHot,
                par:                 par,
                matchHcapLabel:      hcapLabel,
                strokesOnThisHole:   matchStrok,
                showNetRunningTotal: handicapMode == 'net',
                teamLabel:           _teamLabelFor(m.player.id),
                allowJunk:           allowJunk,
                junkCount:           junkCount,
                p531HolePoints:      p531Hole,
                p531CumulativePoints: p531Cumulative,
                // Block taps while extra-match teams are unassigned.
                onTap: (gross != null && !isHot && blockedExtraSeg == null)
                    ? () => onEditTap(m)
                    : null,
                onJunkAdd:    allowJunk ? () => onJunkAdd(m.player.id)    : null,
                onJunkRemove: allowJunk ? () => onJunkRemove(m.player.id) : null,
              ),
              if (isHot)
                blockedExtraSeg == null
                  ? _InlinePicker(
                      par:             par,
                      strokes:         matchStrok,
                      currentScore:    gross,
                      onScoreSelected: (score) => onScoreSelected(m, score),
                    )
                  : _SetTeamsPrompt(
                      matchNumber: (sixesSummary?.segments
                              .indexOf(blockedExtraSeg!) ?? -1) + 1,
                      onTap: onOpenExtraTeamsPicker,
                    ),
            ];
          }).toList(),

          // Phantom player row — read-only, shown at the bottom when the
          // foursome has a phantom player.
          if (phantomMembership != null)
            _PhantomPlayerRow(
              phantom:     phantomMembership!,
              holeNumber:  holeNumber,
              scores:      scores,
              phantomInit: phantomInit,
              players:     players,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Phantom player row — read-only, always at the bottom of the hole card
// ---------------------------------------------------------------------------

class _PhantomPlayerRow extends StatelessWidget {
  final Membership        phantom;
  final int               holeNumber;
  final Map<int, int>     scores;        // real-player gross scores this hole
  final PhantomInitResult? phantomInit;
  final List<Membership>  players;       // real players (for name lookup)

  const _PhantomPlayerRow({
    required this.phantom,
    required this.holeNumber,
    required this.scores,
    required this.players,
    this.phantomInit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ghost = theme.colorScheme.onSurface.withOpacity(0.38);

    // Which real player is the source for this hole?
    final sourcePid   = phantomInit?.sourceByHole[holeNumber];
    final sourceScore = sourcePid != null ? scores[sourcePid] : null;
    final sourceName  = sourcePid != null
        ? players
            .where((m) => m.player.id == sourcePid)
            .firstOrNull
            ?.player
            .displayShort
        : null;

    final String subtitle;
    if (sourceName != null) {
      subtitle = 'Copies $sourceName this hole';
    } else if (phantomInit != null) {
      subtitle = 'Phantom player';
    } else {
      subtitle = 'Phantom (initialising…)';
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // Ghost icon
          Icon(Icons.person_outline, size: 18, color: ghost),
          const SizedBox(width: 8),
          // Name + source label
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  phantom.player.displayShort,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: ghost,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(color: ghost),
                ),
              ],
            ),
          ),
          // Score chip — shows source player's gross if available
          if (sourceScore != null)
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ghost.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: ghost.withOpacity(0.3)),
              ),
              child: Text(
                '$sourceScore',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: ghost,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: Text('—', style: theme.textTheme.bodySmall?.copyWith(color: ghost)),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Nassau hole outcome banner
// ---------------------------------------------------------------------------

class _NassauHoleOutcome extends StatelessWidget {
  final NassauHoleData hole;
  final NassauSummary  nassau;
  const _NassauHoleOutcome({required this.hole, required this.nassau});

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final winner = hole.winner!;
    final Color bg;
    final Color fg;
    final String label;
    if (winner == 'halved') {
      bg    = Colors.grey.shade100;
      fg    = Colors.grey.shade700;
      label = 'Nassau: Halved';
    } else if (winner == 'team1') {
      bg    = Colors.blue.shade50;
      fg    = Colors.blue.shade700;
      label = 'Nassau: T1 wins hole';
    } else {
      bg    = Colors.orange.shade50;
      fg    = Colors.orange.shade800;
      label = 'Nassau: T2 wins hole';
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        Icon(winner == 'halved' ? Icons.drag_handle : Icons.emoji_events,
            size: 14, color: fg),
        const SizedBox(width: 6),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Skins hole outcome banner
// ---------------------------------------------------------------------------

class _SkinsHoleOutcome extends StatelessWidget {
  final SkinsHole skinsHole;
  const _SkinsHoleOutcome({required this.skinsHole});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final winner  = skinsHole.winnerShort!;
    final carry   = skinsHole.isCarry;
    final val     = skinsHole.skinsValue;
    final label   = carry
        ? 'Skins: $winner wins ($val skin${val > 1 ? 's' : ''} incl. carry)'
        : 'Skins: $winner wins hole';
    return Container(
      color: Colors.green.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        Icon(Icons.sports_golf, size: 14, color: Colors.green.shade700),
        const SizedBox(width: 6),
        Text(label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: Colors.green.shade700,
            )),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Skins carry-pot chip
// ---------------------------------------------------------------------------

/// Amber banner shown on the active hole when >1 skin is on the line.
class _SkinsCarryChip extends StatelessWidget {
  final int pot;
  const _SkinsCarryChip({required this.pot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: Colors.amber.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        Icon(Icons.local_fire_department, size: 14, color: Colors.amber.shade800),
        const SizedBox(width: 6),
        Text(
          '$pot skins on the line',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: Colors.amber.shade900,
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Player row
// ---------------------------------------------------------------------------

class _PlayerRow extends StatelessWidget {
  final Membership    member;
  final _RunningTotal running;
  final int?          gross;
  final bool          isHot;
  final int           par;
  final String?       matchHcapLabel;
  final VoidCallback? onTap;
  final int           strokesOnThisHole;
  final bool          showNetRunningTotal;
  final String?       teamLabel;
  final bool          allowJunk;
  final int           junkCount;
  final VoidCallback? onJunkAdd;
  final VoidCallback? onJunkRemove;

  /// Points 5-3-1: points this player earned on the active hole (null = not yet scored).
  final double?       p531HolePoints;

  /// Points 5-3-1: cumulative points total for this player (null = not a P531 round).
  final double?       p531CumulativePoints;

  const _PlayerRow({
    required this.member,
    required this.running,
    required this.gross,
    required this.isHot,
    required this.par,
    this.matchHcapLabel,
    this.onTap,
    this.strokesOnThisHole = 0,
    this.showNetRunningTotal = true,
    this.teamLabel,
    this.allowJunk = false,
    this.junkCount = 0,
    this.onJunkAdd,
    this.onJunkRemove,
    this.p531HolePoints,
    this.p531CumulativePoints,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        // Team badge (T1 = blue, T2 = orange)
        if (teamLabel != null) ...[
          Container(
            width: 28,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: teamLabel == 'T1'
                  ? Colors.blue.shade100
                  : Colors.orange.shade100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              teamLabel!,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: teamLabel == 'T1'
                    ? Colors.blue.shade700
                    : Colors.orange.shade800,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],

        // Name + hcap chip
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
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
              // Skins junk controls below name
              if (allowJunk) ...[
                const SizedBox(height: 2),
                _JunkDots(
                  count:    junkCount,
                  onAdd:    onJunkAdd ?? () {},
                  onRemove: onJunkRemove ?? () {},
                ),
              ],
            ],
          ),
        ),

        // Running total + optional Points 5-3-1 pills
        if (p531CumulativePoints != null)
          Column(
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
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (p531HolePoints != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '+${_fmtPoints(p531HolePoints!)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Text(
                    '${_fmtPoints(p531CumulativePoints!)} pts',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ],
          )
        else
          Text(
            showNetRunningTotal
                ? '${_signed(running.grossVsPar)}G ${_signed(running.netVsPar)}N'
                : '${_signed(running.grossVsPar)}G',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.secondary),
          ),
        const SizedBox(width: 8),

        // Score box — shows a NetScoreButton-style result once a score is
        // entered, or a plain highlighted border while the player is hot.
        GestureDetector(
          onTap: onTap,
          child: gross != null
              // Score entered: use NetScoreButton for color + shape feedback.
              ? Stack(
                  clipBehavior: Clip.none,
                  children: [
                    NetScoreButton(
                      score:    gross!,
                      par:      par,
                      strokes:  strokesOnThisHole,
                      selected: false,
                      width:    40,
                      height:   36,
                    ),
                    if (strokesOnThisHole > 0)
                      Positioned(
                        top: 2, right: 2,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(
                            strokesOnThisHole.clamp(0, 2),
                            (i) => Container(
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
                  ],
                )
              // No score yet: plain box, highlighted border when hot.
              : AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isHot
                        ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                        : Colors.transparent,
                    border: isHot
                        ? Border.all(color: theme.colorScheme.primary, width: 2)
                        : Border.all(color: theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Junk dot indicator — identical to skins_screen.dart _JunkDots
// ---------------------------------------------------------------------------

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
    if (count == 0) {
      return GestureDetector(
        onTap: onAdd,
        child: Icon(Icons.add_circle_outline,
            size: 14, color: theme.colorScheme.onSurfaceVariant),
      );
    }
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

// ---------------------------------------------------------------------------
// Inline score picker (identical to nassau_screen.dart _InlinePicker)
// ---------------------------------------------------------------------------

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
          top: BorderSide(color: theme.colorScheme.primary.withOpacity(0.2)),
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
                  child: Text('Clear',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      )),
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

// ---------------------------------------------------------------------------
// Score picker sheet (modal bottom sheet for editing a saved score)
// ---------------------------------------------------------------------------

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
          Text(playerName,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
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
            )
          else
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Game status section — summary cards for each active game
// ===========================================================================

class _GameStatusSection extends StatelessWidget {
  final List<String>          games;
  final NassauSummary?        nassau;
  final SkinsSummary?         skins;
  final SixesSummary?         sixesSummary;
  final Points531Summary?     points531Summary;
  final Map<String, dynamic>?       matchPlayData;
  final ThreePersonMatchSummary?    threePersonMatchSummary;
  final int                         foursomeId;
  final List<Membership>            players;
  final Scorecard                   scorecard;
  final int                         currentHole;
  final bool                        loadingNassau;
  final bool                        loadingSkins;
  final bool                        loadingPoints531;
  final bool                        loadingMatchPlay;
  final bool                        loadingThreePersonMatch;
  final void Function(int hole)?    onTapHole;

  const _GameStatusSection({
    required this.games,
    required this.nassau,
    required this.skins,
    required this.sixesSummary,
    this.points531Summary,
    required this.matchPlayData,
    this.threePersonMatchSummary,
    required this.foursomeId,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    required this.loadingNassau,
    required this.loadingSkins,
    required this.loadingPoints531,
    required this.loadingMatchPlay,
    this.loadingThreePersonMatch = false,
    required this.onTapHole,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Nassau round progress grid
        if (games.contains('nassau')) ...[
          if (nassau != null)
            _NassauProgressGrid(
              nassau:      nassau!,
              players:     players,
              scorecard:   scorecard,
              currentHole: currentHole,
              onTapHole:   onTapHole,
            )
          else if (loadingNassau)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],

        // Skins standings
        if (games.contains('skins')) ...[
          if (skins != null)
            _SkinsStandingsCard(skins: skins!, currentHole: currentHole)
          else if (loadingSkins)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],

        // Sixes match grid
        if (games.contains('sixes') && sixesSummary != null) ...[
          _SixesMatchGrid(
            summary:     sixesSummary!,
            members:     players,
            currentHole: currentHole,
          ),
          const SizedBox(height: 12),
        ],

        // Points 5-3-1 summary grid
        if (games.contains('points_531')) ...[
          if (points531Summary != null)
            _P531SummaryGrid(
              summary:     points531Summary!,
              players:     players,
              scorecard:   scorecard,
              currentHole: currentHole,
              onTapHole:   onTapHole,
            )
          else if (loadingPoints531)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],

        // Match Play bracket status — show whenever data was loaded, even if
        // 'match_play' is missing from the games list (e.g. configured at the
        // foursome level while round-level active_games doesn't list it).
        if (games.contains('match_play') || matchPlayData != null || loadingMatchPlay) ...[
          if (matchPlayData != null)
            _MatchPlayStatusCard(
              data:       matchPlayData!,
              foursomeId: foursomeId,
            )
          else if (loadingMatchPlay)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],

        // Three-Person Match status card
        if (games.contains('three_person_match') ||
            threePersonMatchSummary != null ||
            loadingThreePersonMatch) ...[
          if (threePersonMatchSummary != null)
            _ThreePersonMatchStatusCard(
              summary:    threePersonMatchSummary!,
              foursomeId: foursomeId,
            )
          else if (loadingThreePersonMatch)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Nassau progress grid (adapted from nassau_screen.dart _NassauSummaryGrid)
// ---------------------------------------------------------------------------

class _NassauProgressGrid extends StatefulWidget {
  final NassauSummary    nassau;
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int hole)? onTapHole;

  const _NassauProgressGrid({
    required this.nassau,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
  });

  @override
  State<_NassauProgressGrid> createState() => _NassauProgressGridState();
}

class _NassauProgressGridState extends State<_NassauProgressGrid> {
  final ScrollController _scrollCtrl = ScrollController();

  static const double _labelColW = 56.0;
  static const double _cellW     = 34.0;
  static const double _rowH      = 28.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToHole(widget.currentHole));
  }

  @override
  void didUpdateWidget(_NassauProgressGrid old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToHole(widget.currentHole));
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToHole(int hole) {
    if (!_scrollCtrl.hasClients) return;
    final target = (_labelColW + (hole - 7) * _cellW)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  int _strokesOnHoleFor(Membership m, int h) {
    final nassau    = widget.nassau;
    final scorecard = widget.scorecard;
    if (nassau.handicapMode == 'gross') return 0;
    final hole = scorecard.holeData(h);
    if (hole == null) return 0;
    final entry = hole.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? hole.strokeIndex;

    if (nassau.handicapMode == 'net') {
      if (nassau.netPercent == 100 && entry != null) return entry.handicapStrokes;
      final effective = (m.playingHandicap * nassau.netPercent / 100.0).round();
      return _strokesOnHole(effective, mySi);
    }
    if (nassau.handicapMode == 'strokes_off') {
      if (widget.players.isEmpty) return 0;
      final low = widget.players
          .map((p) => p.playingHandicap)
          .reduce((a, b) => a < b ? a : b);
      final rawSo = m.playingHandicap - low;
      if (rawSo <= 0) return 0;
      final so = (rawSo * nassau.netPercent / 100.0).round();
      if (so <= 0) return 0;
      return _strokesOnHole(so, mySi);
    }
    return 0;
  }

  String? _winnerForHole(int h) =>
      widget.nassau.holes.where((x) => x.hole == h).firstOrNull?.winner;

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final nassau      = widget.nassau;
    final players     = widget.players;
    final scorecard   = widget.scorecard;
    final currentHole = widget.currentHole;
    final onTapHole   = widget.onTapHole;
    final holeRange   = List.generate(18, (i) => i + 1);

    Widget holeCell(int h, {required Widget child, Color? bg}) {
      final isCurrent = h == currentHole;
      return GestureDetector(
        onTap: onTapHole == null ? null : () => onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? (isCurrent
                ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                : null),
            border: isCurrent
                ? Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.6),
                    width: 1.2)
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Nassau progress',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: _scrollCtrl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hole numbers
                  Row(children: [
                    SizedBox(
                      width: _labelColW, height: _rowH,
                      child: const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Hole',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    for (final h in holeRange)
                      holeCell(h,
                          child: Text('$h',
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold))),
                  ]),
                  // Par row
                  Row(children: [
                    SizedBox(
                      width: _labelColW, height: _rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Par',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontStyle: FontStyle.italic)),
                      ),
                    ),
                    for (final h in holeRange)
                      holeCell(h,
                          child: Text(
                            '${scorecard.holeData(h)?.par ?? "-"}',
                            style: theme.textTheme.bodySmall,
                          )),
                  ]),
                  Container(
                    height: 1,
                    width: _labelColW + _cellW * holeRange.length,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // Player score rows — names tinted with team colour.
                  for (final m in players)
                    _GridPlayerRow(
                      member:        m,
                      scorecard:     scorecard,
                      holeRange:     holeRange,
                      currentHole:   currentHole,
                      onTapHole:     onTapHole,
                      labelColW:     _labelColW,
                      cellW:         _cellW,
                      rowH:          _rowH,
                      strokesOnHole: (h) => _strokesOnHoleFor(m, h),
                      nameColor: nassau.team1.any((p) => p.playerId == m.player.id)
                          ? Colors.blue.shade700
                          : nassau.team2.any((p) => p.playerId == m.player.id)
                              ? Colors.orange.shade800
                              : null,
                    ),
                  // Nassau hole winner row
                  Row(children: [
                    SizedBox(
                      width: _labelColW, height: _rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Won by',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic)),
                      ),
                    ),
                    for (final h in holeRange)
                      Builder(builder: (_) {
                        final winner = _winnerForHole(h);
                        Color? bg;
                        Color? fg;
                        String label = '·';
                        if (winner == 'team1') {
                          bg    = Colors.blue.shade100;
                          fg    = Colors.blue.shade700;
                          label = 'T1';
                        } else if (winner == 'team2') {
                          bg    = Colors.orange.shade100;
                          fg    = Colors.orange.shade800;
                          label = 'T2';
                        } else if (winner == 'halved') {
                          bg    = Colors.grey.shade100;
                          fg    = Colors.grey.shade600;
                          label = '=';
                        }
                        return holeCell(h,
                            bg: bg,
                            child: Text(label,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: fg ?? theme.colorScheme.onSurfaceVariant,
                                )));
                      }),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared player score row for the summary grid.
class _GridPlayerRow extends StatelessWidget {
  final Membership   member;
  final Scorecard    scorecard;
  final List<int>    holeRange;
  final int          currentHole;
  final void Function(int hole)? onTapHole;
  final double       labelColW;
  final double       cellW;
  final double       rowH;
  final int Function(int hole) strokesOnHole;

  /// Optional override color for the player name label.
  /// Used by Nassau to tint names with their team color (blue / orange).
  final Color?       nameColor;

  const _GridPlayerRow({
    required this.member,
    required this.scorecard,
    required this.holeRange,
    required this.currentHole,
    required this.onTapHole,
    required this.labelColW,
    required this.cellW,
    required this.rowH,
    required this.strokesOnHole,
    this.nameColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(children: [
      SizedBox(
        width: labelColW, height: rowH,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(member.player.displayShort,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: nameColor)),
        ),
      ),
      for (final h in holeRange)
        GestureDetector(
          onTap: onTapHole == null ? null : () => onTapHole!(h),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: cellW, height: rowH,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: h == currentHole
                  ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                  : null,
              border: h == currentHole
                  ? Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.6),
                      width: 1.2)
                  : null,
            ),
            child: Stack(children: [
              Center(
                child: Builder(builder: (_) {
                  final gross = scorecard.holeData(h)
                      ?.scoreFor(member.player.id)
                      ?.grossScore;
                  return Text(
                    gross == null ? '–' : '$gross',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: gross == null
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
                  );
                }),
              ),
              Positioned(
                top: 2, right: 2,
                child: Builder(builder: (_) {
                  final strokes = strokesOnHole(h);
                  if (strokes <= 0) return const SizedBox.shrink();
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                      strokes.clamp(0, 2),
                      (i) => Container(
                        width: 4, height: 4,
                        margin: const EdgeInsets.only(left: 1),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ]),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Skins standings card
// ---------------------------------------------------------------------------

class _SkinsStandingsCard extends StatelessWidget {
  final SkinsSummary skins;
  final int          currentHole;

  const _SkinsStandingsCard({
    required this.skins,
    required this.currentHole,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Sort by total_skins descending.
    final sorted = List.of(skins.players)
      ..sort((a, b) => b.totalSkins.compareTo(a.totalSkins));

    // Build a lookup from hole → SkinsHole for the strip.
    final holeMap = { for (final h in skins.holes) h.hole: h };

    // Count carry pot entering each hole so the strip can show accumulated value.
    // We pre-compute the pot for every hole for efficiency.
    final potByHole = <int, int>{};
    int runningPot = 1;
    for (int h = 1; h <= 18; h++) {
      potByHole[h] = runningPot;
      final hd = holeMap[h];
      if (hd == null) break; // not yet scored
      if (hd.winnerId != null || hd.isDead) {
        runningPot = 1;
      } else if (hd.isCarry) {
        runningPot++;
      }
    }

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
            // Header row
            Row(children: [
              Text('Skins standings',
                  style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
              const Spacer(),
              Text('Pool: \$${skins.pool.toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),

            const SizedBox(height: 8),

            // ── 18-hole strip ────────────────────────────────────────────────
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 18,
                separatorBuilder: (_, __) => const SizedBox(width: 4),
                itemBuilder: (_, idx) {
                  final h   = idx + 1;
                  final hd  = holeMap[h];
                  final pot = potByHole[h] ?? 1;
                  final isCurrent = h == currentHole;

                  // Decide cell appearance.
                  Color  bgColor;
                  Color  fgColor;
                  String topLabel;   // hole number
                  String botLabel;   // winner initials / pot / dot

                  if (hd == null) {
                    // Unplayed.
                    bgColor  = theme.colorScheme.surfaceContainerHighest;
                    fgColor  = theme.colorScheme.onSurfaceVariant;
                    topLabel = '$h';
                    botLabel = pot > 1 ? '$pot' : '·';
                    // If carry is accumulating into this unplayed hole, amber.
                    if (pot > 1) {
                      bgColor = Colors.amber.shade100;
                      fgColor = Colors.amber.shade900;
                    }
                  } else if (hd.winnerId != null) {
                    // Winner decided.
                    bgColor  = Colors.green.shade100;
                    fgColor  = Colors.green.shade900;
                    topLabel = '$h';
                    botLabel = hd.winnerShort ?? '?';
                    // If it was a carry win, show the pot value above initials.
                    if (hd.skinsValue > 1) botLabel = '${hd.winnerShort}×${hd.skinsValue}';
                  } else if (hd.isDead) {
                    // Killed (tied, no carryover).
                    bgColor  = Colors.grey.shade200;
                    fgColor  = Colors.grey.shade600;
                    topLabel = '$h';
                    botLabel = '✕';
                  } else {
                    // Tied with carryover — skin carrying forward.
                    bgColor  = Colors.amber.shade100;
                    fgColor  = Colors.amber.shade900;
                    topLabel = '$h';
                    botLabel = '→';
                  }

                  return Container(
                    width: 32,
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(6),
                      border: isCurrent
                          ? Border.all(
                              color: theme.colorScheme.primary,
                              width: 2,
                            )
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(topLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: fgColor,
                              fontSize: 9,
                            )),
                        const SizedBox(height: 1),
                        Text(
                          botLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: fgColor,
                            fontWeight: FontWeight.bold,
                            fontSize: botLabel.length > 3 ? 8 : 10,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 8),

            // ── Player standings rows ────────────────────────────────────────
            for (final p in sorted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Text(p.name,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (p.totalSkins > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${p.totalSkins} skin${p.totalSkins > 1 ? 's' : ''}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.green.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '\$${p.payout.toStringAsFixed(2)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.green.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ] else
                    Text('—',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Nassau-specific status widgets (reused from nassau_screen.dart)
// ===========================================================================

class _TeamBanner extends StatelessWidget {
  final NassauSummary summary;
  const _TeamBanner({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t1 = summary.team1.map((p) => p.name).join(' & ');
    final t2 = summary.team2.map((p) => p.name).join(' & ');

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(
          child: Text(t1,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.blue.shade700,
              ),
              overflow: TextOverflow.ellipsis),
        ),
        Text(' vs ',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Expanded(
          child: Text(t2,
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.orange.shade800,
              ),
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

class _PressesStrip extends StatelessWidget {
  final List<NassauPressResult> presses;
  final int currentHole;
  const _PressesStrip({required this.presses, required this.currentHole});

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final currentNine = currentHole <= 9 ? 'front' : 'back';
    final visible     = presses.where((p) => p.nine == currentNine).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 32,
      color: theme.colorScheme.surface,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final p      = visible[i];
          final label  = '${p.startHole}–${p.endHole}';
          final result = p.result;
          final m      = p.margin ?? 0;
          final mAbs   = m.abs();
          Color  chipColor;
          String scoreText;
          if (result == 'team1') {
            chipColor = Colors.blue.shade100;
            scoreText = p.holesRemaining > 0
                ? '$mAbs&${p.holesRemaining}'
                : '${mAbs}UP';
          } else if (result == 'team2') {
            chipColor = Colors.orange.shade100;
            scoreText = p.holesRemaining > 0
                ? '$mAbs&${p.holesRemaining}'
                : '${mAbs}UP';
          } else if (result == 'halved') {
            chipColor = Colors.grey.shade200;
            scoreText = 'AS';
          } else {
            chipColor = theme.colorScheme.secondaryContainer;
            scoreText = '';
          }
          final chipText = scoreText.isEmpty ? label : '$label $scoreText';
          return Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: chipColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: theme.colorScheme.outline.withOpacity(0.3)),
              ),
              child: Text(chipText, style: theme.textTheme.labelSmall),
            ),
          );
        },
      ),
    );
  }
}

class _MatchStatusBar extends StatelessWidget {
  final NassauSummary summary;
  final VoidCallback? onPress;
  final bool          submitting;

  const _MatchStatusBar({
    required this.summary,
    this.onPress,
    required this.submitting,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _betChip(context, 'F9',  summary.front9),
            _betChip(context, 'B9',  summary.back9),
            _betChip(context, 'ALL', summary.overall),
          ],
        ),
        if (onPress != null) ...[
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: submitting ? null : onPress,
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: const Text('Call Press'),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _betChip(BuildContext context, String label, NassauBetResult bet) {
    final theme    = Theme.of(context);
    final result   = bet.result;
    final nineLen  = label == 'ALL' ? 18 : 9;
    final holesLeft = nineLen - bet.holesPlayed;
    final t1Leads  = bet.margin > 0;
    Color  bg;
    String subtitle;

    if (result != null) {
      if (result == 'halved') {
        bg       = Colors.grey.shade200;
        subtitle = 'AS';
      } else {
        bg = result == 'team1' ? Colors.blue.shade100 : Colors.orange.shade100;
        final dm = bet.decidedMargin;
        final dr = bet.decidedRemaining;
        if (dm != null && dr != null && dr > 0) {
          subtitle = '${dm.abs()}&$dr';
        } else {
          subtitle = 'wins';
        }
      }
    } else if (bet.holesPlayed == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = '—';
    } else if (bet.margin == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = 'AS';
    } else if (holesLeft >= 0 && bet.margin.abs() > holesLeft) {
      bg       = t1Leads ? Colors.blue.shade100 : Colors.orange.shade100;
      subtitle = '${bet.margin.abs()}&$holesLeft';
    } else {
      bg       = t1Leads ? Colors.blue.shade50 : Colors.orange.shade50;
      subtitle = '${bet.margin.abs()}UP';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(subtitle,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Sixes match grid (ported from sixes_screen.dart _MatchGrid / _SegmentCard)
// ---------------------------------------------------------------------------

String _sixesInitials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
}

class _SixesMatchGrid extends StatelessWidget {
  final SixesSummary     summary;
  final List<Membership> members;
  final int              currentHole;

  const _SixesMatchGrid({
    required this.summary,
    required this.members,
    required this.currentHole,
  });

  int _position(String name) {
    final idx = members.indexWhere((m) => m.player.name == name);
    return idx >= 0 ? idx + 1 : 0;
  }

  String _shortFor(String name) {
    final m = members.cast<Membership?>().firstWhere(
      (m) => m?.player.name == name,
      orElse: () => null,
    );
    return m?.player.displayShort ?? _sixesInitials(name);
  }

  String _teamLabel(SixesTeamInfo team) {
    if (!team.hasPlayers) return '??/??\n(?/?)';
    final abbr = team.players.map(_shortFor).join('/');
    final pos  = team.players
        .map((n) => _position(n))
        .map((p) => p > 0 ? '$p' : '?')
        .join('/');
    return '$abbr\n($pos)';
  }

  @override
  Widget build(BuildContext context) {
    final allSegs = summary.segments;
    if (allSegs.isEmpty) return const SizedBox.shrink();

    final standardSegs = allSegs.where((s) => !s.isExtra).toList();
    final extraSegs    = allSegs.where((s) => s.isExtra).toList();

    // Progressive reveal: next match shows only once the current one is done.
    final visible = <SixesSegment>[];
    for (final seg in standardSegs) {
      visible.add(seg);
      final done = seg.status == 'complete' || seg.status == 'halved';
      if (!done) break;
    }
    visible.addAll(extraSegs);

    // P1 = player who appears in team1 of every standard segment.
    String p1Name = '';
    if (standardSegs.length >= 2) {
      var intersection = standardSegs[0].team1.players.toSet();
      for (final s in standardSegs.skip(1)) {
        intersection = intersection.intersection(s.team1.players.toSet());
      }
      if (intersection.isNotEmpty) p1Name = intersection.first;
    }
    if (p1Name.isEmpty && members.isNotEmpty) {
      p1Name = members[0].player.name;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: visible.map((seg) {
          final matchNum   = allSegs.indexOf(seg) + 1;
          final p1InTeam2  = seg.team2.players.contains(p1Name);
          final topTeam    = p1InTeam2 ? seg.team2 : seg.team1;
          final bottomTeam = p1InTeam2 ? seg.team1 : seg.team2;
          return _SixesSegmentCard(
            matchNumber:  matchNum,
            segment:      seg,
            team1Label:   _teamLabel(topTeam),
            team2Label:   _teamLabel(bottomTeam),
            teamsSwapped: p1InTeam2,
            currentHole:  currentHole,
          );
        }).toList(),
      ),
    );
  }
}

class _SixesSegmentCard extends StatelessWidget {
  final int           matchNumber;
  final SixesSegment  segment;
  final String        team1Label;
  final String        team2Label;
  final bool          teamsSwapped;
  final int           currentHole;

  const _SixesSegmentCard({
    required this.matchNumber,
    required this.segment,
    required this.team1Label,
    required this.team2Label,
    this.teamsSwapped = false,
    required this.currentHole,
  });

  Color _statusColor(BuildContext ctx) {
    switch (segment.status) {
      case 'complete':    return Colors.green.shade700;
      case 'halved':      return Colors.blue.shade700;
      case 'in_progress': return Theme.of(ctx).colorScheme.primary;
      default:            return Theme.of(ctx).colorScheme.onSurfaceVariant;
    }
  }

  String _statusLabel() {
    final raw = segment.statusDisplay;
    if (raw == '—') return 'Pending';
    return raw.replaceAll('All Square', 'AS');
  }

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final noTeams     = !segment.team1.hasPlayers || !segment.team2.hasPlayers;
    final statusColor = _statusColor(context);
    final rawMargin   = segment.holes.isNotEmpty ? segment.holes.last.margin : 0;
    final lastMargin  = teamsSwapped ? -rawMargin : rawMargin;
    final t1Leading   = lastMargin > 0;
    final t2Leading   = lastMargin < 0;

    final lastPlayed = segment.holes.isNotEmpty ? segment.holes.last.hole : null;
    final decided    = segment.status == 'complete' || segment.status == 'halved';
    final displayEnd = (decided && lastPlayed != null && lastPlayed < segment.endHole)
        ? lastPlayed
        : segment.endHole;

    return Card(
      margin: const EdgeInsets.only(right: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Container(
        width: 120,
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Match $matchNumber',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary),
            ),
            if (segment.isExtra)
              Text('(extra)',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.tertiary)),
            const SizedBox(height: 6),

            if (noTeams) ...[
              Text('Teams TBD',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ] else ...[
              Text(team1Label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: t1Leading ? FontWeight.bold : FontWeight.normal,
                  )),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('v.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              Text(team2Label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: t2Leading ? FontWeight.bold : FontWeight.normal,
                  )),
              const SizedBox(height: 6),
              Text(
                _statusLabel(),
                style: theme.textTheme.labelMedium?.copyWith(
                    color: statusColor, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                'Holes ${segment.startHole}–$displayEnd',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Match Play status card (compact bracket snapshot for score entry screen)
// ---------------------------------------------------------------------------

class _MatchPlayStatusCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final int                  foursomeId;

  const _MatchPlayStatusCard({
    required this.data,
    required this.foursomeId,
  });

  List<Map<String, dynamic>> _matchesForRound(int round) =>
      (data['matches'] as List? ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .where((m) => (m['round'] as int) == round)
          .toList();

  /// Human-readable one-liner for a single match (mirrors match_play_screen.dart).
  String _matchSummary(Map<String, dynamic> match) {
    final status           = match['status']           as String;
    final result           = match['result']           as String?;
    final holes            = (match['holes']           as List? ?? []);
    final p1               = match['player1']          as String;
    final winnerName       = match['winner_name']      as String?;
    final finishedOn       = match['finished_hole']    as int?;
    final tieBreak         = match['tie_break']        as String?;
    final round            = match['round']            as int;
    final playersTbd       = match['players_tbd']       as bool? ?? false;
    final playersTentative = match['players_tentative'] as bool? ?? false;

    // Back-9 match: no semi winner confirmed yet (e.g. both tied after F9).
    if (playersTbd) return 'Awaiting semi results';
    // Back-9 match: one semi confirmed, other still in sudden death.
    if (playersTentative && status != 'complete') return 'Tracking live — SD';

    if (status == 'pending' && holes.isEmpty) return 'Waiting for scores';

    if (status == 'complete') {
      if (result == 'halved') return 'Halved';
      if (winnerName == null) return 'Complete';
      if (tieBreak == 'sudden_death')  return '$winnerName wins (SD)';
      if (tieBreak == 'last_hole_won') return '$winnerName wins (last hole)';
      if (finishedOn != null) {
        final scheduledEnd = round == 1 ? 9 : 18;
        final remaining    = scheduledEnd - finishedOn;
        final h = holes.cast<Map<String, dynamic>>().firstWhere(
              (h) => h['hole'] == finishedOn,
              orElse: () => <String, dynamic>{});
        final margin = ((h['margin'] as int?) ?? 0).abs();
        if (remaining > 0) return '$winnerName ${margin}&$remaining';
        if (margin > 0)    return '$winnerName wins $margin Up';
      }
      return '$winnerName wins';
    }

    // in_progress
    if (holes.isEmpty) return 'In progress';
    final last        = holes.last as Map<String, dynamic>;
    final lastHoleNum = last['hole']   as int? ?? 0;
    final margin      = last['margin'] as int? ?? 0;
    // SD in progress for a round-1 semi
    if (round == 1 && lastHoleNum > 9) {
      if (margin == 0) return 'All Square — SD thru $lastHoleNum';
      final leader = margin > 0 ? p1 : match['player2'] as String;
      return '$leader leads — SD thru $lastHoleNum';
    }
    if (margin == 0) return 'All Square thru $lastHoleNum';
    final leader = margin > 0 ? p1 : match['player2'] as String;
    return '$leader ${margin.abs()} Up thru $lastHoleNum';
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final status = data['status'] as String? ?? 'pending';
    final winner = data['winner'] as String?;
    final r1     = _matchesForRound(1);
    final r2     = _matchesForRound(2);

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).pushNamed(
          '/match-play-setup',
          arguments: foursomeId,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(children: [
                Icon(Icons.sports_tennis,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('Match Play',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                // Overall status chip
                _StatusChip(status: status, winner: winner, theme: theme),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant),
              ]),

              if (r1.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Semis (F9)',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                for (final m in r1)
                  _MatchRow(match: m, summary: _matchSummary(m), theme: theme),
              ],

              if (r2.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Final & 3rd (B9)',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                for (final m in r2)
                  _MatchRow(match: m, summary: _matchSummary(m), theme: theme),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  final Map<String, dynamic> match;
  final String               summary;
  final ThemeData            theme;

  const _MatchRow({
    required this.match,
    required this.summary,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final p1     = match['player1'] as String? ?? '?';
    final p2     = match['player2'] as String? ?? '?';
    final label  = match['label']   as String? ?? 'Match';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        // Match label badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer)),
        ),
        const SizedBox(width: 8),
        // Players
        Expanded(
          child: Text(
            '$p1 vs $p2',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        // Score summary
        Text(summary,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Three-Person Match status card
// ---------------------------------------------------------------------------

class _ThreePersonMatchStatusCard extends StatelessWidget {
  final ThreePersonMatchSummary summary;
  final int                     foursomeId;

  const _ThreePersonMatchStatusCard({
    required this.summary,
    required this.foursomeId,
  });

  /// Builds the hole-by-hole SD results for display during a tiebreak.
  ///
  /// The tiebreak block stores scores in three columns:
  ///   leader_net  → standings[0] if no leader yet; phase1_leader once found
  ///   tb_a_net    → standings[1] if no leader yet; phase1_tied_a once found
  ///   tb_b_net    → standings[2] if no leader yet; phase1_tied_b once found
  ///
  /// Column headers come from [summary.players] (standings order) when no
  /// leader is found, or from the tiebreak name fields once the leader is set.
  List<Widget> _buildTiebreakHoles(ThemeData theme) {
    final tb = summary.tiebreak;
    if (tb == null) return [];

    final holes       = tb['holes']       as List? ?? [];
    final leaderFound = tb['leader_found'] == true;
    final leaderName  = tb['leader_name'] as String?;
    final tiedAName   = tb['tied_a_name'] as String?;
    final tiedBName   = tb['tied_b_name'] as String?;

    // Column header names.
    // Before leader is found: use standings order from summary.players.
    // After leader is found: use tiebreak name fields.
    final col0 = leaderFound ? (leaderName ?? '?')
        : (summary.players.isNotEmpty ? summary.players[0].shortName : '?');
    final col1 = leaderFound ? (tiedAName  ?? '?')
        : (summary.players.length > 1 ? summary.players[1].shortName : '?');
    final col2 = leaderFound ? (tiedBName  ?? '?')
        : (summary.players.length > 2 ? summary.players[2].shortName : '?');

    // Helper: a score cell that bolds the winner (lowest score on that hole).
    Widget scoreCell(int? score, int? minScore) {
      final isWinner = score != null && minScore != null && score == minScore;
      return Expanded(
        child: Text(
          score?.toString() ?? '—',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
            color: isWinner
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface,
          ),
        ),
      );
    }

    final labelStyle = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final widgets = <Widget>[const SizedBox(height: 8)];

    // If no holes played yet, show a prompt.
    if (holes.isEmpty) {
      widgets.add(
        Text(
          'Keep scoring — SD starts on hole 10.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.orange.shade800, fontStyle: FontStyle.italic),
        ),
      );
      return widgets;
    }

    // Column header row.
    widgets.add(Row(children: [
      SizedBox(width: 52, child: Text('SD Hole', style: labelStyle)),
      Expanded(child: Text(col0, textAlign: TextAlign.center, style: labelStyle)),
      Expanded(child: Text(col1, textAlign: TextAlign.center, style: labelStyle)),
      Expanded(child: Text(col2, textAlign: TextAlign.center, style: labelStyle)),
      const SizedBox(width: 4),
    ]));

    // One row per SD hole played.
    for (final h in holes) {
      final holeNum   = h['hole']       as int?  ?? 0;
      final col0Score = h['leader_net'] as int?;
      final col1Score = h['tb_a_net']   as int?;
      final col2Score = h['tb_b_net']   as int?;

      final allScores = [col0Score, col1Score, col2Score].whereType<int>();
      final minScore  = allScores.isNotEmpty
          ? allScores.reduce((a, b) => a < b ? a : b)
          : null;

      // Show "(tie)" if all three scores are equal.
      final allTied = col0Score != null && col0Score == col1Score && col0Score == col2Score;
      final twoWayTie = minScore != null && [col0Score, col1Score, col2Score]
          .where((s) => s == minScore).length > 1;
      final holeSuffix = allTied ? ' (all tied)' : twoWayTie ? ' (tied)' : '';

      widgets.add(Row(children: [
        SizedBox(
          width: 52,
          child: Text(
            'H$holeNum$holeSuffix',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        scoreCell(col0Score, minScore),
        scoreCell(col1Score, minScore),
        scoreCell(col2Score, minScore),
        const SizedBox(width: 4),
      ]));
    }

    // Footer line.
    final footerText = leaderFound
        ? '$leaderName leads — $tiedAName vs $tiedBName in SD'
        : 'SD continues — keep scoring hole by hole';
    widgets.add(Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        footerText,
        style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.orange.shade700, fontStyle: FontStyle.italic),
      ),
    ));

    return widgets;
  }

  /// One-line status description for the current game state.
  String get _statusLine {
    switch (summary.status) {
      case 'pending':
        return 'Waiting for scores';
      case 'in_progress':
        final scored = summary.holesScored;
        return '$scored/9 holes scored';
      case 'tiebreak':
        final tb = summary.tiebreak;
        if (tb != null && tb['leader_found'] == true) {
          final leaderName = tb['leader_name'] as String? ?? 'Player';
          final aName = tb['tied_a_name'] as String? ?? '?';
          final bName = tb['tied_b_name'] as String? ?? '?';
          return '$leaderName leads — $aName vs $bName SD';
        }
        return 'Sudden death — all tied';
      case 'phase2':
        return 'Back 9 — match play';
      case 'complete':
        return 'Final standings';
      default:
        return summary.status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final status   = summary.status;
    final complete = status == 'complete';

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).pushNamed(
          '/three-person-match-setup',
          arguments: foursomeId,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────────────────────────
              Row(children: [
                Icon(Icons.people_alt_outlined,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('Three-Person Match',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                _StatusChip(
                    status: status,
                    winner: null,
                    theme:  theme),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              ]),

              const SizedBox(height: 8),

              // ── Section label ────────────────────────────────────────────
              Text(
                complete
                    ? 'Final Standings'
                    : (status == 'phase2' || status == 'tiebreak')
                        ? '5-3-1 Phase 1 (holes 1–9)'
                        : '5-3-1 Points',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),

              // ── Player standings ─────────────────────────────────────────
              if (summary.players.isNotEmpty)
                for (final p in summary.players) ...[
                  Row(children: [
                    _PlaceBadge(place: p.phase1Place, theme: theme),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(p.name,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.w500)),
                    ),
                    Text(
                      '${p.phase1Points.toStringAsFixed(1)} pts',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (complete && p.money > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        '\$${p.money.toStringAsFixed(0)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:      theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 2),
                ]
              else ...[
                Text(
                  _statusLine,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],

              // ── Progress footer (while in progress) ─────────────────────
              if (!complete && summary.players.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  _statusLine,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],

              // ── Tiebreak SD holes ─────────────────────────────────────────
              if (status == 'tiebreak') ..._buildTiebreakHoles(theme),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaceBadge extends StatelessWidget {
  final int       place;
  final ThemeData theme;
  const _PlaceBadge({required this.place, required this.theme});

  @override
  Widget build(BuildContext context) {
    final labels = {1: '1st', 2: '2nd', 3: '3rd'};
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: place == 1
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        labels[place] ?? '$place',
        style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: place == 1
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSecondaryContainer),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sixes extra-match team picker (ported from sixes_screen.dart)
// ---------------------------------------------------------------------------

/// Inline banner that replaces the score picker when a Sixes extras hole
/// has no teams assigned yet.  Shows a "Set teams" button to reopen the
/// modal for users who dismissed the auto-open.
class _SetTeamsPrompt extends StatelessWidget {
  final int          matchNumber;
  final VoidCallback? onTap;

  const _SetTeamsPrompt({required this.matchNumber, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withOpacity(0.35),
        border: Border(
          top: BorderSide(color: theme.colorScheme.tertiary.withOpacity(0.4)),
        ),
      ),
      child: Row(children: [
        Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.tertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Set teams for Match $matchNumber before entering scores.',
            style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonalIcon(
          onPressed: onTap,
          icon: const Icon(Icons.groups, size: 18),
          label: const Text('Set teams'),
        ),
      ]),
    );
  }
}

/// Modal bottom sheet for assigning two teams for a Sixes extra match.
/// Tap two players → Team A; the other two become Team B automatically.
class _ExtraTeamPickerSheet extends StatefulWidget {
  final List<Membership> members;
  const _ExtraTeamPickerSheet({required this.members});

  @override
  State<_ExtraTeamPickerSheet> createState() => _ExtraTeamPickerSheetState();
}

class _ExtraTeamPickerSheetState extends State<_ExtraTeamPickerSheet> {
  final Set<int> _teamAIds = {};

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final teamBIds = widget.members
        .where((m) => !_teamAIds.contains(m.player.id))
        .map((m) => m.player.id)
        .toList();
    final canConfirm = _teamAIds.length == 2;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),

            Text(
              'Extra Match Teams',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap two players to form Team A — the other two become Team B.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            ...widget.members.map((m) {
              final inA   = _teamAIds.contains(m.player.id);
              final inB   = !inA && canConfirm;
              final color = inA
                  ? theme.colorScheme.primary
                  : inB
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.surfaceContainerHighest;
              final label = inA ? 'Team A' : (inB ? 'Team B' : '—');

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                      color: inA || inB
                          ? color
                          : theme.colorScheme.outlineVariant),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color,
                    child: Text(
                      m.player.displayShort,
                      style: TextStyle(
                        color: inA || inB
                            ? Colors.white
                            : theme.colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(m.player.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: inA || inB
                          ? color
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onTap: () {
                    setState(() {
                      if (inA) {
                        _teamAIds.remove(m.player.id);
                      } else if (_teamAIds.length < 2) {
                        _teamAIds.add(m.player.id);
                      }
                    });
                  },
                ),
              );
            }),

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: canConfirm
                    ? () => Navigator.of(context).pop([
                          _teamAIds.toList(),
                          teamBIds,
                        ])
                    : null,
                child: const Text(
                  'Confirm Teams',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Points 5-3-1 — 18-hole summary grid (ported from points_531_screen.dart)
// ---------------------------------------------------------------------------

class _P531SummaryGrid extends StatefulWidget {
  final Points531Summary         summary;
  final List<Membership>         players;
  final Scorecard                scorecard;
  final int                      currentHole;
  final void Function(int hole)? onTapHole;

  const _P531SummaryGrid({
    required this.summary,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
  });

  @override
  State<_P531SummaryGrid> createState() => _P531SummaryGridState();
}

class _P531SummaryGridState extends State<_P531SummaryGrid> {
  final ScrollController _scrollCtrl = ScrollController();

  static const double _labelColW = 56.0;
  static const double _cellW     = 34.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToHole(widget.currentHole));
  }

  @override
  void didUpdateWidget(_P531SummaryGrid old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToHole(widget.currentHole));
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToHole(int hole) {
    if (!_scrollCtrl.hasClients) return;
    final target = (_labelColW + (hole - 7) * _cellW)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Map<int, double> _pointsByHole(int playerId) {
    final out = <int, double>{};
    for (final h in widget.summary.holes) {
      for (final e in h.entries) {
        if (e.playerId == playerId) {
          out[h.hole] = e.points;
          break;
        }
      }
    }
    return out;
  }

  int _strokesOnHoleFor(Membership m, int holeNumber) {
    final summary   = widget.summary;
    final scorecard = widget.scorecard;
    final players   = widget.players;
    if (summary.handicapMode == 'gross') return 0;
    final hole = scorecard.holeData(holeNumber);
    if (hole == null) return 0;
    final entry = hole.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? hole.strokeIndex;

    if (summary.handicapMode == 'net') {
      if (summary.netPercent == 100 && entry != null) {
        return entry.handicapStrokes;
      }
      final effective = (m.playingHandicap * summary.netPercent / 100.0).round();
      return _strokesOnHole(effective, mySi);
    }
    if (summary.handicapMode == 'strokes_off') {
      if (players.isEmpty) return 0;
      final low   = players.map((p) => p.playingHandicap).reduce((a, b) => a < b ? a : b);
      final rawSo = m.playingHandicap - low;
      if (rawSo <= 0) return 0;
      final so = (rawSo * summary.netPercent / 100.0).round();
      if (so <= 0) return 0;
      return _strokesOnHole(so, mySi);
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final summary     = widget.summary;
    final players     = widget.players;
    final scorecard   = widget.scorecard;
    final currentHole = widget.currentHole;
    final onTapHole   = widget.onTapHole;

    const double labelColW = 56.0;
    const double cellW     = 34.0;
    const double rowH      = 28.0;

    final holeRange = List.generate(18, (i) => i + 1);

    Widget holeCell(int h, {required Widget child, Color? bg}) {
      final isCurrent = h == currentHole;
      return GestureDetector(
        onTap: onTapHole == null ? null : () => onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: cellW,
          height: rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? (isCurrent
                ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                : null),
            border: isCurrent
                ? Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.6),
                    width: 1.2)
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
              controller: _scrollCtrl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: hole numbers
                  Row(children: [
                    SizedBox(
                      width: labelColW,
                      height: rowH,
                      child: const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Hole',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    for (final h in holeRange) holeCell(h,
                        child: Text('$h',
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold))),
                  ]),
                  // Par row
                  Row(children: [
                    SizedBox(
                      width: labelColW,
                      height: rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Par',
                            style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic)),
                      ),
                    ),
                    for (final h in holeRange) holeCell(h,
                        child: Text(
                          '${scorecard.holeData(h)?.par ?? "-"}',
                          style: theme.textTheme.bodySmall,
                        )),
                  ]),
                  Container(
                    height: 1,
                    width: labelColW + cellW * holeRange.length,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // One double-row per player: scores + points awarded
                  for (final m in players) _P531PlayerGridRows(
                    member:        m,
                    scorecard:     scorecard,
                    holeRange:     holeRange,
                    currentHole:   currentHole,
                    onTapHole:     onTapHole,
                    labelColW:     labelColW,
                    cellW:         cellW,
                    rowH:          rowH,
                    strokesOnHole: (h) => _strokesOnHoleFor(m, h),
                    pointsByHole:  _pointsByHole(m.player.id),
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

class _P531PlayerGridRows extends StatelessWidget {
  final Membership   member;
  final Scorecard    scorecard;
  final List<int>    holeRange;
  final int          currentHole;
  final void Function(int hole)? onTapHole;
  final double       labelColW;
  final double       cellW;
  final double       rowH;
  final int Function(int hole)    strokesOnHole;
  final Map<int, double>          pointsByHole;

  const _P531PlayerGridRows({
    required this.member,
    required this.scorecard,
    required this.holeRange,
    required this.currentHole,
    required this.onTapHole,
    required this.labelColW,
    required this.cellW,
    required this.rowH,
    required this.strokesOnHole,
    required this.pointsByHole,
  });

  Widget _cell(int h, BuildContext ctx, {required Widget child}) {
    final theme     = Theme.of(ctx);
    final isCurrent = h == currentHole;
    return GestureDetector(
      onTap: onTapHole == null ? null : () => onTapHole!(h),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: cellW, height: rowH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isCurrent
              ? theme.colorScheme.primaryContainer.withOpacity(0.35)
              : null,
          border: isCurrent
              ? Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.6),
                  width: 1.2)
              : null,
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Score row with stroke-dot overlay
        Row(children: [
          SizedBox(
            width: labelColW, height: rowH,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(member.player.displayShort,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
          for (final h in holeRange) _cell(h, context, child: SizedBox(
            width: cellW,
            height: rowH,
            child: Stack(children: [
              Center(
                child: Builder(builder: (_) {
                  final saved = scorecard.holeData(h)?.scoreFor(member.player.id);
                  final gross = saved?.grossScore;
                  return Text(
                    gross == null ? '–' : '$gross',
                    style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: gross == null
                            ? theme.colorScheme.onSurfaceVariant
                            : null),
                  );
                }),
              ),
              Positioned(
                top: 2, right: 2,
                child: Builder(builder: (_) {
                  final strokes = strokesOnHole(h);
                  if (strokes <= 0) return const SizedBox.shrink();
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(strokes.clamp(0, 2), (i) => Container(
                      width: 4, height: 4,
                      margin: const EdgeInsets.only(left: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    )),
                  );
                }),
              ),
            ]),
          )),
        ]),
        // Points awarded row
        Row(children: [
          SizedBox(
            width: labelColW, height: rowH - 4,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(' pts',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic)),
            ),
          ),
          for (final h in holeRange) Container(
            width: cellW, height: rowH - 4,
            alignment: Alignment.center,
            child: Builder(builder: (_) {
              final pts = pointsByHole[h];
              if (pts == null) {
                return Text('·', style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant));
              }
              final isWinner = pts >= 5;
              return Text(
                _fmtPoints(pts),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: isWinner ? FontWeight.bold : FontWeight.w600,
                  color: isWinner
                      ? Colors.green.shade700
                      : theme.colorScheme.onSurface,
                ),
              );
            }),
          ),
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _StatusChip extends StatelessWidget {
  final String    status;
  final String?   winner;
  final ThemeData theme;

  const _StatusChip({
    required this.status,
    required this.winner,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final Color  bg;
    final Color  fg;
    final String label;

    switch (status) {
      case 'complete':
        bg    = Colors.green.shade100;
        fg    = Colors.green.shade800;
        label = winner != null ? '$winner wins' : 'Final';
      case 'in_progress':
        bg    = theme.colorScheme.primaryContainer;
        fg    = theme.colorScheme.onPrimaryContainer;
        label = 'In progress';
      case 'tiebreak':
        bg    = Colors.orange.shade100;
        fg    = Colors.orange.shade800;
        label = 'Tiebreak';
      case 'phase2':
        bg    = theme.colorScheme.tertiaryContainer;
        fg    = theme.colorScheme.onTertiaryContainer;
        label = 'Back 9';
      default:
        bg    = theme.colorScheme.surfaceContainerHighest;
        fg    = theme.colorScheme.onSurfaceVariant;
        label = 'Pending';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall?.copyWith(color: fg)),
    );
  }
}
