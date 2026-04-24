/// screens/sixes_screen.dart
///
/// Score-entry and live-standings screen for the Six's game.
///
/// Layout (matches wireframes):
///   • AppBar:      "Golf Gaming" centred title.
///   • Top card:    Hole N header (par / yds / SI) + player rows.
///                  Each row shows running (+X)G (+Y)N totals and a
///                  score box.  The "hot-spot" (first player without a
///                  score on this hole) has a shaded box AND an inline
///                  scrollable score picker that auto-appears below it —
///                  no tap required.  After picking, hot-spot advances.
///                  Tapping a previously entered score box opens a modal
///                  sheet to edit or clear it.
///   • Hole nav:    Scrollable chips for all 18 holes.
///   • Match grid:  One card per segment ("Match 1"…"Match 4") showing
///                  team abbreviations, positions, and live match status.
///                  Extra matches without players show "Select Players"
///                  in red — tapping it opens the setup screen.
///   • Bottom nav:  ← Hole N-1  |  Hole N+1 →
///                  "Hole N+1" enabled only when all 4 players scored;
///                  tapping it saves and advances.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/round_provider.dart';
import '../sync/sync_service.dart';
import '../widgets/net_score_button.dart';

// Top-level helper shared by _MatchGrid and _ExtraTeamPickerSheet.
String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
}

// ---------------------------------------------------------------------------
// Match-handicap helpers
// ---------------------------------------------------------------------------

/// Compute a player's *effective* playing handicap for the current Sixes
/// match, given the match's handicap mode and net percentage.
///
///   Net   : round(playingHandicap × netPercent / 100)
///   Gross : 0 (no strokes — raw scores used)
///   SO    : playingHandicap − lowestPlayingHandicap (low plays to 0).
///           `lowestPlayingHandicap` must be provided for this to work;
///           if null, we fall back to full net (keeps things safe until
///           Strokes-Off is wired all the way through).
///
/// Returns a non-negative integer.
int effectiveMatchHandicap({
  required String mode,
  required int    netPercent,
  required int    playingHandicap,
  int?            lowestPlayingHandicap,
}) {
  switch (mode) {
    case 'gross':
      return 0;
    case 'strokes_off':
      if (lowestPlayingHandicap == null) {
        // Fallback: behave like full net until SO is implemented end-to-end.
        return playingHandicap;
      }
      final off = playingHandicap - lowestPlayingHandicap;
      return off < 0 ? 0 : off;
    case 'net':
    default:
      if (netPercent == 100) return playingHandicap;
      return (playingHandicap * netPercent / 100.0).round();
  }
}

/// Per-hole stroke allocation for a given effective handicap and the hole's
/// stroke index (1 = hardest hole).  Matches the backend rule in
/// FoursomeMembership.handicap_strokes_on_hole and scoring/handicap.py.
int strokesOnHole(int effectiveHandicap, int strokeIndex) {
  if (effectiveHandicap <= 0) return 0;
  final full  = effectiveHandicap ~/ 18;
  final rem   = effectiveHandicap %  18;
  final extra = strokeIndex <= rem ? 1 : 0;
  return full + extra;
}

/// Per-player, per-hole strokes in a Sixes Strokes-Off match.
///
/// [playerSo] is the player's SO number (own playing handicap minus the
/// foursome's low playing handicap; never negative).  [summary] is the
/// current SixesSummary (used to know which segment a hole is in and where
/// the next segment starts, so we can handle dying strokes).  [scorecard]
/// is the scorecard (used to look up the stroke index of every hole in a
/// segment's potential range).
///
/// Standard matches: the player receives
///     floor(SO/3) + (1 if match_idx < SO%3 else 0)
/// strokes, allocated to the hardest holes in that SEGMENT'S OWN potential
/// range (seg.startHole..seg.endHole).  If the segment ended early (the
/// next segment starts before seg.endHole+1), any stroke planned past the
/// last actually-played hole dies.
/// Extras: the player gets a stroke on any hole in the extra whose SI
/// meets the course-wide SO threshold.
int sixesSoStrokesOnHole({
  required int playerSo,
  required int holeNumber,
  required int strokeIndex,
  required SixesSummary? summary,
  required Scorecard? scorecard,
}) {
  if (playerSo <= 0) return 0;
  if (scorecard == null) return 0;
  if (summary == null) return 0;

  // Segments come back from the server already ordered: standard segments
  // 1..3 first, then any extras.  We keep that list order throughout.
  final segments = summary.segments;

  // First: is this hole currently inside an extra (tiebreak) segment?  If
  // so we apply the simple SI-threshold rule.
  for (final s in segments) {
    if (s.isExtra &&
        holeNumber >= s.startHole &&
        holeNumber <= s.endHole) {
      return strokeIndex <= playerSo ? 1 : 0;
    }
  }

  // Otherwise the hole lives inside a standard segment.  Find that segment
  // AND its index among the standard (non-extra) segments — the index
  // drives the spread (floor(SO/3) + remainder for the first SO%3 matches).
  //
  // NOTE: when an earlier match ends early, the backend moves the NEXT
  // segment's startHole left (e.g. match 1 ends at hole 4 → seg2 becomes
  // 5-10) but leaves the earlier segment's endHole unchanged (seg1 stays
  // 1-6).  That means seg1 and seg2 overlap on holes 5 and 6.  We want
  // the LATER segment to own those overlap holes, so iterate in reverse
  // and take the first match.
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

  final base = playerSo ~/ 3;
  final rem  = playerSo %  3;
  final strokesThisMatch = base + (stdIdx < rem ? 1 : 0);
  if (strokesThisMatch <= 0) return 0;

  // Actual last hole played in this segment: one less than the next
  // segment's start (standard or extra), or 18 if this is the final one.
  // Segments are kept in the server's emitted order (1..3 standard, then
  // extras), so "next segment" = next in list with start > current start.
  final segListIdx = segments.indexOf(seg);
  int actualEnd = 18;
  for (int i = segListIdx + 1; i < segments.length; i++) {
    if (segments[i].startHole > seg.startHole) {
      actualEnd = segments[i].startHole - 1;
      break;
    }
  }

  // Rank this segment's own potential range hardest-first (lowest SI);
  // hole number is the deterministic tiebreak so it matches the backend.
  final holes = <int>[
    for (int h = seg.startHole; h <= seg.endHole; h++) h
  ];
  holes.sort((a, b) {
    final aSi = scorecard.holeData(a)?.strokeIndex ?? 18;
    final bSi = scorecard.holeData(b)?.strokeIndex ?? 18;
    if (aSi != bSi) return aSi.compareTo(bSi);
    return a.compareTo(b);
  });
  final rank = holes.indexOf(holeNumber);
  if (rank < 0) return 0;

  final segSize = holes.length;

  int plannedStrokes;
  if (strokesThisMatch <= segSize) {
    plannedStrokes = rank < strokesThisMatch ? 1 : 0;
  } else {
    // Rare: more strokes than holes → 1 everywhere + extras on hardest.
    final extraStrokes = strokesThisMatch - segSize;
    plannedStrokes = 1 + (rank < extraStrokes ? 1 : 0);
  }

  // Dying-strokes: if the match ended before this hole, the stroke dies.
  if (holeNumber > actualEnd) return 0;

  return plannedStrokes;
}

class SixesScreen extends StatefulWidget {
  final int foursomeId;
  const SixesScreen({super.key, required this.foursomeId});

  @override
  State<SixesScreen> createState() => _SixesScreenState();
}

class _SixesScreenState extends State<SixesScreen> {
  /// In-flight scores entered on the device but not yet submitted.
  /// Structure: hole → playerId → grossScore.
  final Map<int, Map<int, int>> _pending = {};

  int  _selectedHole   = 1;
  bool _pinkBallLost   = false;

  /// Tracks whether the sync queue had items during the previous build, so we
  /// can detect the pending→idle transition and re-load sixes standings once
  /// the server has processed the scores (i.e. calculate_sixes has run).
  bool _prevHadPending = false;

  /// startHole of every extras segment we've already auto-opened the team
  /// picker for.  Keyed by startHole (which is stable per extra while it
  /// exists) so we don't loop when the user cancels the picker.  The
  /// user can still manually reopen the picker via the inline "Set teams"
  /// prompt that replaces the score picker while teams are unset.
  final Set<int> _autoOpenedExtraStart = {};

  /// Guards the one-time "jump to first unplayed hole" so it only fires once
  /// after the scorecard for THIS foursome arrives in the provider.  Without
  /// this guard the jump either fires on a stale (previous game's) scorecard
  /// or fires before the scorecard has loaded at all.
  bool _initialJumpDone = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

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
      rp.loadSixes(widget.foursomeId);
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  bool get _hasPinkBall {
    final rp = context.read<RoundProvider>();
    return rp.round?.activeGames.contains('pink_ball') ?? false;
  }

  /// Returns players in the order they were assigned to teams during setup.
  /// Reads team1.players then team2.players from the first sixes segment,
  /// matched back to Membership objects so we preserve handicap data.
  /// Falls back to foursome / scorecard order if summary is unavailable.
  List<Membership> _orderedPlayers(
    Scorecard sc,
    Round? round,
    SixesSummary? sixesSummary,
  ) {
    final allMembers = _rawPlayers(sc, round);

    // Try to derive order from sixes summary segment teams (respects drag order).
    if (sixesSummary != null && sixesSummary.segments.isNotEmpty) {
      final seg = sixesSummary.segments.first;
      if (seg.team1.hasPlayers && seg.team2.hasPlayers) {
        final orderedNames = [...seg.team1.players, ...seg.team2.players];
        final result = <Membership>[];
        for (final name in orderedNames) {
          final m = allMembers.where((m) => m.player.name == name).firstOrNull;
          if (m != null && !result.any((r) => r.player.id == m.player.id)) {
            result.add(m);
          }
        }
        // Append any unmatched members (safety net).
        for (final m in allMembers) {
          if (!result.any((r) => r.player.id == m.player.id)) result.add(m);
        }
        if (result.isNotEmpty) return result;
      }
    }
    return allMembers;
  }

  List<Membership> _rawPlayers(Scorecard sc, Round? round) {
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
    final sc = rp.scorecard;
    if (sc == null) return;
    for (int h = 1; h <= 18; h++) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      final allScored = hd.scores.every((s) => s.grossScore != null);
      if (!allScored && !rp.localPendingByHole.containsKey(h)) {
        setState(() => _selectedHole = h);
        return;
      }
    }
    // All 18 holes are complete — land on the last hole instead of hole 1.
    setState(() => _selectedHole = 18);
  }

  /// Effective scores for [hole]: server data merged with in-flight UI edits
  /// (UI wins).  Returns playerId → grossScore.
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

  /// Index (0-based) of the first player in [players] who has no score on
  /// [hole], or -1 if all scored.
  int _hotSpotIdx(List<Membership> players, Map<int, int> scores) {
    for (int i = 0; i < players.length; i++) {
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  bool _allScored(List<Membership> players, Map<int, int> scores) =>
      players.every((m) => scores.containsKey(m.player.id));

  /// Called by the inline picker when the hot-spot player's score is selected.
  void _selectScore(Membership player, int score, int hole) {
    setState(() {
      if (score == -1) {
        // Clear
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  /// Open the modal score-picker sheet for editing a previously entered score.
  Future<void> _editScore(
    BuildContext ctx,
    Membership player,
    int par,
    int hole,
    List<Membership> players,   // foursome players, needed for SO low lookup
  ) async {
    final rp      = context.read<RoundProvider>();
    final sc      = rp.scorecard;
    final summary = rp.sixesSummary;
    final current = (_pending[hole] ?? {})[player.player.id]
        ?? _scoreFromCard(sc, hole, player.player.id);

    // Per-player match strokes on this hole — honors the match's handicap
    // mode and net_percent, so the picker colors match the score entry UI.
    final mode        = summary?.handicapMode ?? 'net';
    final netPercent  = summary?.netPercent   ?? 100;
    final lowPlaying  = mode == 'strokes_off' && players.isNotEmpty
        ? players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b)
        : null;
    final effective = effectiveMatchHandicap(
      mode:                  mode,
      netPercent:            netPercent,
      playingHandicap:       player.playingHandicap,
      lowestPlayingHandicap: lowPlaying,
    );
    final si = sc?.holeData(hole)?.strokeIndex ?? 18;
    // In SO mode the Sixes spreading rule determines per-hole strokes;
    // every other mode uses plain SI allocation against `effective`.
    final strokes = mode == 'strokes_off'
        ? sixesSoStrokesOnHole(
            playerSo:    effective,  // player_hcp - low
            holeNumber:  hole,
            strokeIndex: si,
            summary:     summary,
            scorecard:   sc,
          )
        : strokesOnHole(effective, si);

    final score = await showModalBottomSheet<int>(
      context: ctx,
      useRootNavigator: true,
      builder: (_) => _ScorePickerSheet(
        playerName: player.player.name,
        par: par,
        holeNumber: hole,
        strokes: strokes,
        current: current,
      ),
    );
    if (!mounted) return;
    if (score == null) return;
    setState(() {
      if (score == -1) {
        _pending[hole]?.remove(player.player.id);
        if (_pending[hole]?.isEmpty ?? false) _pending.remove(hole);
      } else {
        _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] = score;
      }
    });
  }

  int? _scoreFromCard(Scorecard? sc, int hole, int playerId) {
    return sc?.holeData(hole)?.scoreFor(playerId)?.grossScore;
  }

  /// Save current hole and advance to next hole.
  /// Hole 18 "Done" handler.  Submits any unsaved pending edits for the
  /// current hole first, waits long enough to let calculate_sixes process
  /// them on the server, then navigates to the leaderboard.  This is what
  /// rescues a one-hole extra match ("Match 5") from showing up pending on
  /// the leaderboard when the user taps Done without tapping Next first.
  Future<void> _finishRound(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final rp      = context.read<RoundProvider>();
    final sync    = context.read<SyncService>();
    final roundId = rp.round?.id;

    // If there are unsaved edits for this hole, save them before
    // navigating.  If the save fails we surface a snackbar and DON'T
    // navigate, so the user can retry.
    final pendingForHole = _pending[_selectedHole];
    if (pendingForHole != null && pendingForHole.isNotEmpty) {
      final scores = pendingForHole.entries
          .map((e) => {'player_id': e.key, 'gross_score': e.value})
          .toList();
      final ok = await rp.submitHole(
        foursomeId:   widget.foursomeId,
        holeNumber:   _selectedHole,
        scores:       scores,
        pinkBallLost: _pinkBallLost,
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
      setState(() {
        _pending.remove(_selectedHole);
        _pinkBallLost = false;
      });
    }

    // submitHole only QUEUES the score locally; the actual POST happens
    // in SyncService.drainQueue(), which is fired-and-forgotten by
    // enqueue().  Calling drainQueue() directly here would be a no-op
    // if a drain is already in flight (the `_draining` guard inside
    // SyncService returns immediately).  Use waitUntilIdle which polls
    // until the queue is fully drained AND the service is idle — the
    // only reliable way to know calculate_sixes has seen hole 18 before
    // we navigate to the leaderboard.  The 10 s timeout is a safety net
    // so a flaky network doesn't hang the UI.
    await sync.waitUntilIdle();
    if (!mounted) return;

    // Kick off a sixes reload so the leaderboard renders with the
    // just-computed standings.  Fire-and-forget.
    rp.loadSixes(widget.foursomeId);

    if (roundId != null) {
      Navigator.of(ctx).pushNamed('/leaderboard', arguments: roundId);
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
      foursomeId:   widget.foursomeId,
      holeNumber:   _selectedHole,
      scores:       scores,
      pinkBallLost: _pinkBallLost,
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
      _pinkBallLost = false;
    });

    // Fire a load now — may return stale data if the sync is still in flight.
    // The drain-complete listener in build() will fire a second load once the
    // server has processed the scores and calculate_sixes has run.
    rp.loadSixes(widget.foursomeId);

    _advance();
  }

  /// Show the extra match team picker sheet, then POST the team assignment
  /// to the backend without touching any existing hole results.
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

  void _advance() {
    if (_selectedHole < 18) setState(() => _selectedHole++);
  }

  void _retreat() {
    if (_selectedHole > 1) setState(() => _selectedHole--);
  }

  /// If [hole] falls inside an EXTRAS segment (is_extra=True) whose teams
  /// haven't been assigned yet, return that segment.  Otherwise null.
  ///
  /// We iterate segments in reverse so that if an earlier extras segment's
  /// (stale) range overlaps the hole, the LATER (and correct) extras
  /// segment wins — mirroring the server's segment_number ordering and
  /// the same reverse-iteration fix we already applied in
  /// sixesSoStrokesOnHole.  Standard (non-extras) segments always have
  /// teams from the initial Sixes setup, so they don't need this gate.
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp   = context.watch<RoundProvider>();
    final sync = context.watch<SyncService>();
    final sc   = rp.scorecard;
    final isComplete = rp.round?.status == 'complete';

    // Detect when the sync queue drains (pending → idle).  At that point the
    // server has run calculate_sixes, so we refresh the standings.
    final nowHasPending = sync.hasPending;
    if (_prevHadPending && !nowHasPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<RoundProvider>().loadSixes(widget.foursomeId);
      });
    }
    _prevHadPending = nowHasPending;

    // Once the scorecard for THIS foursome arrives, jump to the first
    // unscored hole.  Guard on activeFoursomeId so we don't act on a
    // stale scorecard that belongs to a different (e.g. previously
    // viewed) game.
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
        title: const Text('Golf Gaming'),
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
                      ? null : () => sync.recheck(),
                ),
              ),
            ),
          if (sc != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                rp.loadScorecard(widget.foursomeId);
                rp.loadSixes(widget.foursomeId);
              },
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
                : () => Navigator.of(context).pushNamed(
                      '/leaderboard',
                      arguments: rp.round!.id,
                    ),
          ),
        ],
      ),
      body: _buildBody(context, rp, sync, isComplete),
      bottomNavigationBar: sc == null ? null : _buildBottomNav(context, rp, sc),
    );
  }

  Widget _buildBottomNav(
    BuildContext ctx,
    RoundProvider rp,
    Scorecard sc,
  ) {
    final players    = _orderedPlayers(sc, rp.round, rp.sixesSummary);
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores);
    final isComplete = rp.round?.status == 'complete';
    final par        = sc.holeData(_selectedHole)?.par ?? 4;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(children: [
          // ← Previous hole
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _selectedHole > 1 ? _retreat : null,
              icon: const Icon(Icons.chevron_left, size: 20),
              label: Text('Hole ${_selectedHole - 1}'),
            ),
          ),
          const SizedBox(width: 8),

          // Next hole / Done
          Expanded(
            child: _selectedHole == 18 || isComplete
                ? FilledButton.icon(
                    // On hole 18 the usual "Next" button becomes Done.
                    // We MUST save any pending edits for hole 18 before
                    // navigating away, otherwise the scores sit
                    // unsubmitted in _pending and a one-hole extra (the
                    // infamous "Match 5") stays pending forever because
                    // calculate_sixes never sees the hole 18 score.
                    //
                    // If all four players already have scores locally but
                    // rp.submitting is still going, disable the button
                    // until the submission settles so we don't race.
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
    );
  }

  Widget _buildBody(
    BuildContext ctx,
    RoundProvider rp,
    SyncService sync,
    bool isComplete,
  ) {
    if (rp.loadingScorecard) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rp.error != null && rp.scorecard == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(rp.error!, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            rp.loadScorecard(widget.foursomeId);
            rp.loadSixes(widget.foursomeId);
          },
          child: const Text('Retry'),
        ),
      ]));
    }

    final sc = rp.scorecard;
    if (sc == null) return const SizedBox.shrink();

    final players  = _orderedPlayers(sc, rp.round, rp.sixesSummary);
    final merged   = _mergePending(rp.localPendingByHole, _pending);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;

    // Gate score entry when the current hole is inside an extras segment
    // whose teams haven't been assigned yet.  Two effects:
    //   1) The first time _selectedHole lands inside such a segment we
    //      auto-open the team picker (post-frame so we're not inside a
    //      build() call).  We mark startHole as "already offered" so a
    //      user who cancels isn't trapped in an infinite modal loop.
    //   2) _HoleScoreCard receives blockedForExtraTeams=true which swaps
    //      the inline score picker for a prominent "Set teams for Match N"
    //      prompt — manually reopening the picker if they dismissed it.
    final needsTeamsSeg = _unconfiguredExtraForHole(_selectedHole, rp.sixesSummary);
    if (needsTeamsSeg != null &&
        !_autoOpenedExtraStart.contains(needsTeamsSeg.startHole)) {
      _autoOpenedExtraStart.add(needsTeamsSeg.startHole);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showExtraTeamPicker(needsTeamsSeg, players);
      });
    }

    return Column(children: [
      _SyncBanner(sync: sync),
      if (rp.error != null)
        _ErrorBanner(message: rp.error!, onDismiss: rp.clearError),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Hole info card with inline score picker ──
              _HoleScoreCard(
                holeData:   holeData,
                holeNumber: _selectedHole,
                players:    players,
                scorecard:  sc,
                merged:     merged,
                scores:     scores,
                hotSpotIdx: hotSpot,
                par:        par,
                hasPinkBall:   _hasPinkBall,
                pinkBallLost:  _pinkBallLost,
                // Match handicap config drives per-player effective strokes
                // (used for score-picker coloring, running net total, and
                // the match-handicap label next to each golfer's name).
                sixesSummary: rp.sixesSummary,
                // When the current hole is inside an extras segment with
                // no teams, we disable score entry and show a prompt in
                // place of the inline picker.  The callback reopens the
                // picker for users who cancelled the auto-open.
                blockedExtraSeg: needsTeamsSeg,
                onOpenExtraTeamsPicker: needsTeamsSeg == null
                    ? null
                    : () => _showExtraTeamPicker(needsTeamsSeg, players),
                onScoreSelected: (m, score) =>
                    _selectScore(m, score, _selectedHole),
                onEditTap: (m) =>
                    _editScore(ctx, m, par, _selectedHole, players),
                onPinkBallLostChanged: (v) =>
                    setState(() => _pinkBallLost = v),
              ),
              const SizedBox(height: 12),

              // ── Match grid ──
              if (rp.sixesSummary != null) ...[
                _MatchGrid(
                  summary:     rp.sixesSummary!,
                  members:     players,
                  currentHole: _selectedHole,
                  foursomeId:  widget.foursomeId,
                  onSelectExtraTeams: (extraSeg) =>
                      _showExtraTeamPicker(extraSeg, players),
                ),
                const SizedBox(height: 12),
              ] else if (rp.loadingSixes) ...[
                const Center(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )),
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
// Running total helper
// ===========================================================================

class _RunningTotal {
  final int grossVsPar;
  final int netVsPar;
  const _RunningTotal({required this.grossVsPar, required this.netVsPar});
}

String _signed(int v) => v > 0 ? '(+$v)' : '($v)';

// ===========================================================================
// Hole score card — hole header + player rows + inline score picker
// ===========================================================================

class _HoleScoreCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final int              holeNumber;
  final List<Membership> players;
  final Scorecard        scorecard;
  final Map<int, Map<int, int>> merged;   // all pending (db + ui)
  final Map<int, int>    scores;          // effective scores for this hole
  final int              hotSpotIdx;      // -1 = all done / read-only
  final int              par;
  final bool             hasPinkBall;
  final bool             pinkBallLost;
  final void Function(Membership, int) onScoreSelected; // inline picker
  final void Function(Membership)      onEditTap;       // modal for editing
  final void Function(bool)            onPinkBallLostChanged;
  final SixesSummary?                  sixesSummary;    // nullable until loaded
  /// Non-null when the current hole falls inside an extras segment whose
  /// teams haven't been assigned yet.  When set, the inline score picker
  /// is replaced with a prompt asking the user to set teams first.
  final SixesSegment?                  blockedExtraSeg;
  /// Invoked when the user taps the inline "Set teams for Match N"
  /// button — reopens the extras team picker.  Non-null only when
  /// blockedExtraSeg is non-null.
  final VoidCallback?                  onOpenExtraTeamsPicker;

  const _HoleScoreCard({
    required this.holeData,
    required this.holeNumber,
    required this.players,
    required this.scorecard,
    required this.merged,
    required this.scores,
    required this.hotSpotIdx,
    required this.par,
    required this.hasPinkBall,
    required this.pinkBallLost,
    required this.onScoreSelected,
    required this.onEditTap,
    required this.onPinkBallLostChanged,
    required this.sixesSummary,
    this.blockedExtraSeg,
    this.onOpenExtraTeamsPicker,
  });

  /// Builds the "Par X  |  Y yds.  |  SI: Z" header text for a hole,
  /// deduplicating values across tees.  When all players share the same tee
  /// a single value is shown; when tees differ the values are slash-joined
  /// in the same order as [players].  Mirrors the logic in
  /// points_531_screen.dart and skins_screen.dart exactly.
  static String _buildHoleHeaderText(
    ScorecardHole hole,
    List<Membership> players,
  ) {
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

    String collapse<T>(List<T> vals, String Function(T) fmt) {
      if (vals.isEmpty) return '';
      final seen   = <T>{};
      final unique = vals.where((v) => seen.add(v)).toList();
      if (unique.length == 1) return fmt(unique.first);
      return unique.map(fmt).join('/');
    }

    final parStr  = 'Par ${collapse<int>(parVals, (v) => '$v')}';
    final siStr   = 'SI: ${collapse<int>(siVals, (v) => '$v')}';
    final anyYard = yardVals.any((y) => y != null);
    final yardStr = anyYard
        ? '${collapse<int?>(yardVals, (v) => v == null ? '—' : '$v')} yds.'
        : null;
    return yardStr == null
        ? '$parStr  |  $siStr'
        : '$parStr  |  $yardStr  |  $siStr';
  }

  /// Mode for this match ('net' default while summary is still loading).
  String get _mode        => sixesSummary?.handicapMode ?? 'net';
  int    get _netPercent  => sixesSummary?.netPercent   ?? 100;

  /// Lowest playing_handicap in the foursome — used for Strokes-Off mode.
  int? get _lowPlayingHandicap {
    if (_mode != 'strokes_off' || players.isEmpty) return null;
    return players
        .map((m) => m.playingHandicap)
        .reduce((a, b) => a < b ? a : b);
  }

  /// This player's effective handicap for the current match.
  /// (Example: playing_handicap=32 at 50% net → 16.)
  int _matchHandicapFor(Membership m) => effectiveMatchHandicap(
        mode:                  _mode,
        netPercent:            _netPercent,
        playingHandicap:       m.playingHandicap,
        lowestPlayingHandicap: _lowPlayingHandicap,
      );

  /// Per-player, per-hole strokes for the current match.  In Strokes-Off
  /// mode we use the Sixes-specific spreading rule; other modes use the
  /// simple SI allocation over the player's effective handicap.
  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null) return 0;
    if (_mode == 'strokes_off') {
      return sixesSoStrokesOnHole(
        playerSo:    _matchHandicapFor(m),  // already player_hcp - low
        holeNumber:  h.holeNumber,
        strokeIndex: h.strokeIndex,
        summary:     sixesSummary,
        scorecard:   scorecard,
      );
    }
    return strokesOnHole(_matchHandicapFor(m), h.strokeIndex);
  }

  _RunningTotal _running(int playerId) {
    // Find this member's record so we can derive effective strokes per hole
    // (the stored HoleScore.handicap_strokes reflects full 100% handicap and
    // would be wrong when net_percent ≠ 100 or mode == 'gross').
    final m = players
        .where((x) => x.player.id == playerId)
        .firstOrNull;

    int gross = 0, parSum = 0, net = 0;
    for (final h in scorecard.holes) {
      final pendingGross = merged[h.holeNumber]?[playerId];
      final saved        = h.scoreFor(playerId);
      final grossScore   = pendingGross ?? saved?.grossScore;
      if (grossScore == null) continue;
      gross  += grossScore;
      parSum += h.par;
      // Derive net using *match* strokes, not the stored HoleScore value,
      // so running totals track what the player is actually scoring in
      // this sixes match.
      final strokes = m == null ? 0 : _strokesForHole(m, h);
      net += grossScore - strokes;
    }
    return _RunningTotal(grossVsPar: gross - parSum, netVsPar: net - parSum);
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ── Hole header ──
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
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
              holeData != null
                  ? _buildHoleHeaderText(holeData!, players)
                  : '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ]),
        ),

        // ── Player rows + inline picker ──
        ...players.asMap().entries.expand((entry) {
          final idx     = entry.key;
          final m       = entry.value;
          final rt      = _running(m.player.id);
          final gross   = scores[m.player.id];
          final isHot   = idx == hotSpotIdx;
          final hasScore = gross != null;

          // Effective strokes for the picker coloring come from the match's
          // handicap mode/percent, not the stored full-handicap value — so
          // at 50% net a 20-hcp player's net par reflects 10 strokes, not 20.
          final matchStrokes = _strokesForHole(m, holeData);

          // Label shown next to the player name in Net/SO modes, e.g. "-16"
          // or "-16 •" (1 stroke on this hole) / "-16 ••" (2 strokes).  The
          // dots reflect strokes received on the CURRENTLY-displayed hole so
          // golfers know who gets a stroke here before the hole is played.
          // Gross mode hides the chip entirely since no strokes are given.
          final String? matchHcapLabel;
          if (_mode == 'gross') {
            matchHcapLabel = null;
          } else {
            final String dots =
                matchStrokes > 0 ? ' ${'•' * matchStrokes}' : '';
            matchHcapLabel = '-${_matchHandicapFor(m)}$dots';
          }

          return [
            _PlayerScoreRow(
              position:       idx + 1,
              member:         m,
              running:        rt,
              gross:          gross,
              isHot:          isHot,
              matchHcapLabel: matchHcapLabel,
              showNet:        _mode == 'net',
              // Tapping a scored non-hot row lets the user edit it.
              // Suppressed while teams are unset — we don't want the
              // edit modal popping up either.
              onTap: (hasScore && !isHot && blockedExtraSeg == null)
                  ? () => onEditTap(m)
                  : null,
            ),
            // Inline score picker (or the "set teams" gate that replaces
            // it) — only rendered under the hot-spot player's row so the
            // prompt doesn't repeat four times.
            if (isHot)
              blockedExtraSeg == null
                  ? _InlineScorePicker(
                      par: par,
                      // Per-player match strokes on this hole — drives the
                      // net-centred coloring and shape decorations.
                      strokes: matchStrokes,
                      currentScore: gross,
                      onScoreSelected: (score) => onScoreSelected(m, score),
                    )
                  : _SetTeamsPrompt(
                      matchNumber: (sixesSummary?.segments
                              .indexOf(blockedExtraSeg!) ?? -1) + 1,
                      onTap: onOpenExtraTeamsPicker,
                    ),
          ];
        }).toList(),

        // ── Pink ball toggle ──
        if (hasPinkBall) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              Checkbox(
                value: pinkBallLost,
                onChanged: (v) => onPinkBallLostChanged(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
              const Text('🔴 Pink ball lost on this hole'),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// One player row inside the hole card
// ---------------------------------------------------------------------------

class _PlayerScoreRow extends StatelessWidget {
  final int          position;
  final Membership   member;
  final _RunningTotal running;
  final int?         gross;     // null = not yet entered
  final bool         isHot;     // shaded "you're up" indicator
  final VoidCallback? onTap;

  /// Optional "-N" label shown next to the player name indicating the
  /// handicap this golfer is playing to in the current match.  Null in
  /// Gross mode (no strokes given, so nothing to show).
  final String?     matchHcapLabel;

  /// When true the running total shows both gross and net columns.
  /// Set to false in Gross and Strokes-Off modes so only the gross
  /// column is displayed (net total is meaningless there).
  final bool        showNet;

  const _PlayerScoreRow({
    required this.position,
    required this.member,
    required this.running,
    required this.gross,
    required this.isHot,
    this.matchHcapLabel,
    this.onTap,
    this.showNet = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color boxBg = isHot
        ? theme.colorScheme.primaryContainer.withOpacity(0.4)
        : Colors.transparent;

    final boxBorder = isHot
        ? Border.all(color: theme.colorScheme.primary, width: 2)
        : Border.all(color: theme.colorScheme.outline);

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
        // Position + name (+ optional match handicap chip)
        Expanded(
          child: Row(children: [
            Text('$position)  ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary)),
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
                  matchHcapLabel!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ]),
        ),

        // Running totals: (+2)G or (+2)G (+1)N depending on handicap mode.
        // Net column is hidden for Gross and Strokes-Off modes.
        Flexible(
          flex: 0,
          child: Text(
            showNet
                ? '${_signed(running.grossVsPar)}G ${_signed(running.netVsPar)}N'
                : '${_signed(running.grossVsPar)}G',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.secondary),
          ),
        ),
        const SizedBox(width: 8),

        // Score box
        GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 36,
            decoration: BoxDecoration(
              color: boxBg,
              border: boxBorder,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: gross != null
                ? Text(
                    '$gross',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  )
                : isHot
                    ? Icon(
                        Icons.arrow_drop_down,
                        size: 20,
                        color: theme.colorScheme.primary,
                      )
                    : null,
          ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Inline score picker — appears below the hot-spot player row automatically
// ===========================================================================

/// Inline gate that replaces the score picker when the current hole is
/// inside an extras segment whose teams haven't been set yet.  Tapping
/// the button reopens the team picker (useful if the user dismissed the
/// auto-opened picker on first arrival at this hole).
class _SetTeamsPrompt extends StatelessWidget {
  final int matchNumber;
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


class _InlineScorePicker extends StatefulWidget {
  final int  par;
  final int  strokes;       // handicap strokes this player gets on this hole
  final int? currentScore;
  final void Function(int) onScoreSelected; // -1 = clear

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
  static const double _itemWidth  = 52.0;
  static const double _itemMargin = 5.0;
  static const double _itemTotal  = _itemWidth + _itemMargin * 2;

  late final ScrollController _ctrl;

  /// Left-edge offset that centres the slider on this player's net par.
  double _offsetFor(int par, int strokes) {
    final netPar   = par + strokes;
    final startIdx = (netPar - 3).clamp(0, 11); // 0-based index in [1..12]
    return (startIdx * _itemTotal).clamp(0.0, double.infinity);
  }

  @override
  void initState() {
    super.initState();
    _ctrl = ScrollController(
        initialScrollOffset: _offsetFor(widget.par, widget.strokes));
  }

  @override
  void didUpdateWidget(covariant _InlineScorePicker old) {
    super.didUpdateWidget(old);
    // When Flutter reuses this State across hole changes (same widget type
    // at the same tree position), initState doesn't re-run — but par or
    // strokes may now be different.  Without this, the colors correctly
    // reflect the new net par while the scroll offset stays anchored to
    // the previous hole, which is exactly the "score 5 is white but in
    // position 4 instead of 3" bug on the first player of hole 5.
    if (old.par != widget.par || old.strokes != widget.strokes) {
      final target = _offsetFor(widget.par, widget.strokes);
      // jumpTo is fine here — the picker is only reflowed when the user
      // advances to a new hole, so there's no pleasant animation to
      // preserve.  Schedule post-frame so we don't fight a pending layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ctrl.hasClients) return;
        final maxExtent = _ctrl.position.maxScrollExtent;
        _ctrl.jumpTo(target.clamp(0.0, maxExtent));
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
    final scores = List.generate(12, (i) => i + 1); // 1 … 12

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
        itemCount:       scores.length + (widget.currentScore != null ? 1 : 0),
        itemBuilder: (_, i) {
          // Last item = clear button (only when a score is selected)
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
              score: s,
              par: widget.par,
              strokes: widget.strokes,
              selected: sel,
              width: _itemWidth,
              height: 48,
              onTap: () => widget.onScoreSelected(s),
            ),
          );
        },
      ),
    );
  }
}

// ===========================================================================
// Modal score-picker sheet — used for editing already-entered scores
// ===========================================================================

class _ScorePickerSheet extends StatelessWidget {
  final String playerName;
  final int    par;
  final int    holeNumber;
  final int    strokes;     // handicap strokes this player gets on this hole
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
          // Handle
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),

          // Title
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

          // Horizontally scrollable score buttons — net-centred.
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
                    score: s,
                    par: par,
                    strokes: strokes,
                    selected: sel,
                    width: 46,
                    height: 52,
                    onTap: () => Navigator.of(context).pop(s),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 12),

          // Clear / cancel
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
// Match grid
// ===========================================================================

class _MatchGrid extends StatelessWidget {
  final SixesSummary     summary;
  final List<Membership> members;
  final int              currentHole;
  final int              foursomeId;
  /// Called when the user taps "Select Players" on the extra match card.
  final void Function(SixesSegment)? onSelectExtraTeams;

  const _MatchGrid({
    required this.summary,
    required this.members,
    required this.currentHole,
    required this.foursomeId,
    this.onSelectExtraTeams,
  });

  int _position(String name) {
    final idx = members.indexWhere((m) => m.player.name == name);
    return idx >= 0 ? idx + 1 : 0;
  }

  /// Resolve a player-name string from the Sixes summary back to the
  /// PlayerProfile in the foursome members list so we can use its
  /// shortName.  Falls back to the legacy _initials() algorithm if the
  /// name doesn't match (e.g. a phantom whose display name has diverged).
  String _shortFor(String name) {
    final m = members.cast<Membership?>().firstWhere(
      (m) => m?.player.name == name,
      orElse: () => null,
    );
    return m?.player.displayShort ?? _initials(name);
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

    // Progressive reveal: Match N+1 appears only once Match N is finished.
    // Extra match is always shown once it exists (the card itself handles
    // the "coming up" vs "Select Players" state based on currentHole).
    final standardSegs = allSegs.where((s) => !s.isExtra).toList();
    final extraSegs    = allSegs.where((s) => s.isExtra).toList();

    final visible = <SixesSegment>[];
    for (final seg in standardSegs) {
      visible.add(seg);
      final done = seg.status == 'complete' || seg.status == 'halved';
      if (!done) break; // hide subsequent standard matches until this one ends
    }
    visible.addAll(extraSegs);

    // Identify P1 reliably: they are the ONLY player who appears in team1
    // of every standard segment (setup always puts P1 in team1_player_ids).
    //   Match 1 team1 = {P1, P2}
    //   Match 2 team1 = {P1, P3 or P4}
    //   Intersection  = {P1}
    // This is robust against Django's M2M return order (which is by player ID,
    // not insertion order — so members[0] would wrongly be P2 if P2's DB id
    // is lower than P1's).
    String p1Name = '';
    if (standardSegs.length >= 2) {
      var intersection = standardSegs[0].team1.players.toSet();
      for (final s in standardSegs.skip(1)) {
        intersection = intersection.intersection(s.team1.players.toSet());
      }
      if (intersection.isNotEmpty) p1Name = intersection.first;
    }
    // Fallback when <2 standard segments are visible (shouldn't happen).
    if (p1Name.isEmpty && members.isNotEmpty) {
      p1Name = members[0].player.name;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: visible.map((seg) {
          final matchNum = allSegs.indexOf(seg) + 1;

          // If P1 is in team2, swap so their team always renders on top.
          final p1InTeam2 = seg.team2.players.contains(p1Name);
          final topTeam    = p1InTeam2 ? seg.team2 : seg.team1;
          final bottomTeam = p1InTeam2 ? seg.team1 : seg.team2;

          return _SegmentCard(
            matchNumber:       matchNum,
            segment:           seg,
            team1Label:        _teamLabel(topTeam),
            team2Label:        _teamLabel(bottomTeam),
            teamsSwapped:      p1InTeam2,
            currentHole:       currentHole,
            foursomeId:        foursomeId,
            onSelectExtraTeams: seg.isExtra
                ? () => onSelectExtraTeams?.call(seg)
                : null,
          );
        }).toList(),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  final int           matchNumber;
  final SixesSegment  segment;
  final String        team1Label;   // always P1's team (top row)
  final String        team2Label;   // always P1's opponents (bottom row)
  /// True when the display order is reversed relative to Django team_number:
  /// team1Label holds Django team2's data, so margin signs are flipped.
  final bool          teamsSwapped;
  final int           currentHole;
  final int           foursomeId;
  /// Non-null only for the extra match card; tapping "Tap to pick teams" invokes it.
  final VoidCallback? onSelectExtraTeams;

  const _SegmentCard({
    required this.matchNumber,
    required this.segment,
    required this.team1Label,
    required this.team2Label,
    this.teamsSwapped = false,
    required this.currentHole,
    required this.foursomeId,
    this.onSelectExtraTeams,
  });

  Color _statusColor(BuildContext ctx) {
    switch (segment.status) {
      case 'complete':    return Colors.green.shade700;
      case 'halved':      return Colors.blue.shade700;
      case 'in_progress': return Theme.of(ctx).colorScheme.primary;
      default:            return Theme.of(ctx).colorScheme.onSurfaceVariant;
    }
  }

  /// Human-readable status, never blank.
  /// • '—' (no holes played yet) → 'Pending'
  /// • 'All Square thru N'      → 'AS thru N'
  String _statusLabel() {
    final raw = segment.statusDisplay;
    if (raw == '—') return 'Pending';
    return raw.replaceAll('All Square', 'AS');
  }

  @override
  Widget build(BuildContext context) {
    final theme        = Theme.of(context);
    final noTeams      = !segment.team1.hasPlayers || !segment.team2.hasPlayers;
    final statusTx     = _statusLabel();
    final statusColor  = _statusColor(context);
    // lastMargin is from Django's perspective: +N means team_number=1 leads.
    // If we swapped labels, flip the sign so the bold follows the right row.
    final rawMargin    = segment.holes.isNotEmpty ? segment.holes.last.margin : 0;
    final lastMargin   = teamsSwapped ? -rawMargin : rawMargin;
    final team1Leading = lastMargin > 0;
    final team2Leading = lastMargin < 0;

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
              Text('??/?? (?/?)\nv.\n??/?? (?/?)',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              if (segment.isExtra && currentHole < segment.startHole)
                // Not there yet — show when the extra match begins.
                Text(
                  'Starts hole\n${segment.startHole}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.tertiary,
                    fontWeight: FontWeight.bold,
                  ),
                )
              else
                // Ready: let user pick teams via the bottom sheet.
                GestureDetector(
                  onTap: onSelectExtraTeams,
                  child: Text(
                    'Tap to pick\nteams',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colorScheme.error,
                    ),
                  ),
                ),
            ] else ...[
              Text(team1Label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight:
                        team1Leading ? FontWeight.bold : FontWeight.normal,
                  )),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('v.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              Text(team2Label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight:
                        team2Leading ? FontWeight.bold : FontWeight.normal,
                  )),
              const SizedBox(height: 8),
              Text(
                statusTx,
                style: theme.textTheme.labelMedium?.copyWith(
                    color: statusColor, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Builder(builder: (_) {
                // For matches that ended early, the DB's end_hole is
                // still the POTENTIAL end (we don't retrim it during
                // repositioning — that would mess up other calculations
                // that key off the original range).  So "Holes 1–6" on a
                // match that ended at hole 4 is misleading on the match
                // card.  Use the last actually-played hole instead when
                // the segment is complete or halved.
                final lastPlayed = segment.holes.isNotEmpty
                    ? segment.holes.last.hole
                    : null;
                final decided = segment.status == 'complete'
                                || segment.status == 'halved';
                final displayEnd = (decided
                                    && lastPlayed != null
                                    && lastPlayed < segment.endHole)
                    ? lastPlayed
                    : segment.endHole;
                return Text('Holes ${segment.startHole}–$displayEnd',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant));
              }),
            ],
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Extra match team picker — bottom sheet shown when user taps "Tap to pick teams"
// ===========================================================================

class _ExtraTeamPickerSheet extends StatefulWidget {
  final List<Membership> members; // all 4 players

  const _ExtraTeamPickerSheet({required this.members});

  @override
  State<_ExtraTeamPickerSheet> createState() => _ExtraTeamPickerSheetState();
}

class _ExtraTeamPickerSheetState extends State<_ExtraTeamPickerSheet> {
  /// Player IDs assigned to Team A.  Team B gets the remaining two.
  final Set<int> _teamAIds = {};

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
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

            // Player tiles
            ...widget.members.map((m) {
              final inA    = _teamAIds.contains(m.player.id);
              final inB    = !inA && canConfirm;
              final color  = inA
                  ? theme.colorScheme.primary
                  : inB
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.surfaceContainerHighest;
              final label  = inA ? 'Team A' : (inB ? 'Team B' : '—');

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: inA || inB ? color : theme.colorScheme.outlineVariant),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color,
                    child: Text(
                      m.player.displayShort,
                      style: TextStyle(
                        color: inA || inB ? Colors.white : theme.colorScheme.onSurfaceVariant,
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
                      color: inA || inB ? color : theme.colorScheme.onSurfaceVariant,
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
                      // If team A is full (2 players), tapping a team-B player
                      // has no effect — they must deselect a team-A player first.
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

// ===========================================================================
// Sync & error banners
// ===========================================================================

class _SyncBanner extends StatelessWidget {
  final SyncService sync;
  const _SyncBanner({required this.sync});

  @override
  Widget build(BuildContext context) {
    if (!sync.hasPending && sync.state == SyncState.idle) {
      return const SizedBox.shrink();
    }
    final bool syncing = sync.state == SyncState.syncing;
    return Container(
      width: double.infinity,
      color: syncing ? Colors.blue.shade700 : Colors.orange.shade700,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Icon(syncing ? Icons.sync : Icons.cloud_upload_outlined,
            size: 16, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            syncing
                ? 'Syncing ${sync.pendingCount} score(s)…'
                : '${sync.pendingCount} score(s) waiting to sync — tap ↑ to retry',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ]),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String   message;
  final VoidCallback onDismiss;
  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 16, color: Colors.orange),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: onDismiss,
        ),
      ]),
    );
  }
}
