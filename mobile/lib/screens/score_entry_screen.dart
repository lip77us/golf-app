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
import '../game_catalog.dart';
import '../game_colors.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../providers/settings_provider.dart';
import '../sync/sync_service.dart';
import '../utils/match_handicap.dart';
import '../utils/nassau_team_style.dart';
import '../utils/round_complete.dart';
import '../utils/golf_colors.dart';
import '../widgets/score_mark.dart';
import '../widgets/borrowed_fourth.dart';
import '../widgets/halved_mark.dart';
import '../widgets/spots_capture.dart';
import '../widgets/icon_help_sheet.dart';
import '../widgets/inline_message.dart';
import '../widgets/inline_score_picker.dart';
import '../widgets/net_score_button.dart';
import '../widgets/round_chat_button.dart';
import '../widgets/team_splitter_4.dart';

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

String _fmtPoints(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class ScoreEntryScreen extends StatefulWidget {
  final int foursomeId;
  const ScoreEntryScreen({super.key, required this.foursomeId});

  @override
  State<ScoreEntryScreen> createState() => _ScoreEntryScreenState();
}

class _ScoreEntryScreenState extends State<ScoreEntryScreen>
    with SpotsCaptureMixin {
  /// Unsubmitted score edits: hole → playerId → gross.
  final Map<int, Map<int, int>> _pending = {};

  /// Unsubmitted skins-junk edits: hole → playerId → count.
  final Map<int, Map<int, int>> _pendingJunk = {};

  int  _selectedHole    = 1;
  bool _initialJumpDone = false;

  /// startHole of every Sixes extras segment we've already auto-opened the
  /// team picker for.  Prevents an infinite modal loop when the user cancels.
  final Set<int> _autoOpenedExtraStart = {};

  /// Triple Cup match IDs we've already shown the foursomes tee-off
  /// prompt for — keeps the modal from re-opening every rebuild when
  /// the user dismisses without picking.  Cleared when teams update.
  final Set<int> _teeOffPromptShown = {};

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
      final hasCupSinglesGames = games.contains('singles_18') ||
          games.contains('singles_nassau') ||
          configured.contains('singles_18') ||
          configured.contains('singles_nassau');
      // Match Play auto-dispatches by foursome size — 3-player groups
      // run Three-Person Match instead of a bracket, so /match-play/
      // would 404 in a loop here.  Skip the match-play poll when this
      // foursome has 3 real players; the TPM poll below handles them.
      final fs = rp.round?.foursomes
          .where((f) => f.id == widget.foursomeId)
          .firstOrNull;
      final isThreesome = fs?.realPlayers.length == 3;
      if (!isThreesome &&
          (games.contains('match_play') ||
              configured.contains('match_play') ||
              hasData ||
              hasCupSinglesGames)) {
        rp.loadMatchPlay(widget.foursomeId);
      }
      // Three-person match also needs live updates during tiebreak / phase 2.
      // Match Play on a 3-player foursome means this group is a TPM, so
      // poll TPM for them too.
      if (games.contains('three_person_match') ||
          configured.contains('three_person_match') ||
          rp.threePersonMatchSummary != null ||
          (isThreesome && games.contains('match_play'))) {
        rp.loadThreePersonMatch(widget.foursomeId);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rp   = context.read<RoundProvider>();
      final sync = context.read<SyncService>();

      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        // loadScorecard clears the per-game summaries for the previous
        // foursome, so the game-summary loads must run AFTER it resolves —
        // otherwise on first entry they race the clear and the screen paints
        // with no summary (wrong handicap mode, no status strip), only
        // correcting on the second entry once the scorecard is cached.
        rp.loadScorecard(widget.foursomeId).whenComplete(() {
          if (mounted) _loadGameSummaries(context.read<RoundProvider>());
        });
      } else {
        rp.refreshPendingOverlay();
        _loadGameSummaries(rp);
      }

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

      // First time on this screen: explain the Leaderboard / Scorecard icons.
      maybeShowScoreEntryHelp(context);
    });
  }

  @override
  void dispose() {
    _syncRef?.removeListener(_syncWatcher!);
    _matchPlayTimer?.cancel();
    disposeSpots();
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
    // Cup rounds: each foursome plays only its assigned game(s).
    // Use the foursome's own game list exclusively when it has one,
    // rather than unioning with the round-level list (which would mix
    // Irish Rumble + Match Play when only one applies to this group).
    if (round.isCupRound && fsGames.isNotEmpty) {
      return fsGames.toList();
    }
    // Regular rounds: union of round-level and foursome-level games.
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
    // Collected so we can rebuild once they resolve — see the whenComplete at
    // the end of this method.
    final futures = <Future<void>>[];
    // Per-foursome summary loads gate on active_games (set at round
    // creation) OR configured_games (set after the per-game setup row
    // exists) OR a previously-loaded summary.  The active_games branch
    // is the key one for first paint after a fresh setup: loadScorecard
    // clears the summary when the foursome ID changes, and the mobile's
    // cached round object doesn't pick up configured_games until the
    // round is re-fetched, so without active_games as a fallback the
    // handicap chip falls back to round-level 'net' for the rest of the
    // session.
    if (games.contains('nassau') ||
        configured.contains('nassau') ||
        rp.nassauSummary != null) {
      futures.add(rp.loadNassau(widget.foursomeId));
    }
    if (games.contains('skins') ||
        configured.contains('skins') ||
        rp.skinsSummary != null) {
      futures.add(rp.loadSkins(widget.foursomeId));
    }
    if (games.contains('spots') ||
        configured.contains('spots') ||
        rp.spotsSummary != null) {
      futures.add(rp.loadSpots(widget.foursomeId));
    }
    // Multi-Group Skins is round-scoped (no foursome configured_games
    // entry), so gate purely on the round's active_games list.
    if (games.contains('multi_skins') && rp.round != null) {
      futures.add(rp.loadMultiSkins(rp.round!.id));
    }
    if (games.contains('sixes') ||
        configured.contains('sixes') ||
        rp.sixesSummary != null) {
      futures.add(rp.loadSixes(widget.foursomeId));
    }
    if (games.contains('triple_cup') ||
        configured.contains('triple_cup') ||
        rp.tripleCupSummary != null) {
      futures.add(rp.loadTripleCup(widget.foursomeId));
    }
    if (games.contains('points_531') ||
        configured.contains('points_531') ||
        rp.points531Summary != null) {
      futures.add(rp.loadPoints531(widget.foursomeId));
    }
    if (games.contains('vegas') ||
        configured.contains('vegas') ||
        rp.vegasSummary != null) {
      futures.add(rp.loadVegas(widget.foursomeId));
    }
    if (games.contains('fourball') ||
        configured.contains('fourball') ||
        rp.fourballSummary != null) {
      futures.add(rp.loadFourball(widget.foursomeId));
    }
    // Stableford is round-scoped; refresh the authoritative per-hole points.
    if (games.contains('stableford') && rp.round != null) {
      futures.add(rp.loadStableford(rp.round!.id));
    }
    // Stroke Play stores handicap mode in its own config (not the round object).
    // Both casual ('low_net_round') and championship ('low_net') use the same endpoint.
    if ((games.contains('low_net_round') || games.contains('low_net')) &&
        rp.round != null)
      futures.add(rp.loadLowNetConfig(rp.round!.id));
    // Load match play if it's in the active game list OR if a bracket has
    // already been configured (handles cases where match_play is set at the
    // foursome level but the games list resolution missed it).
    // Load match play if configured, or if we already have data (refresh it).
    // Cup singles rounds use 'singles_18' / 'singles_nassau' instead of
    // 'match_play', so treat those as equivalent triggers.
    final _hasCupSingles = games.contains('singles_18') ||
        games.contains('singles_nassau') ||
        configured.contains('singles_18') ||
        configured.contains('singles_nassau');
    // Same auto-dispatch as the polling timer above: 3-player groups
    // play Three-Person Match, not a bracket, so /match-play/ 404s for
    // them.  Skip the load and route to TPM instead.
    final _fsHere = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    final _isThreesome = _fsHere?.realPlayers.length == 3;
    if (!_isThreesome &&
        (games.contains('match_play') ||
            configured.contains('match_play') ||
            rp.matchPlayData != null ||
            _hasCupSingles))
      futures.add(rp.loadMatchPlay(widget.foursomeId));
    if (games.contains('three_person_match') ||
        configured.contains('three_person_match') ||
        (_isThreesome && games.contains('match_play')))
      futures.add(rp.loadThreePersonMatch(widget.foursomeId));
    // Initialise phantom player if this foursome has one.  Idempotent —
    // the provider skips the network call if already done.
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs?.hasPhantom == true) rp.initPhantom(widget.foursomeId);

    // This screen reads game summaries via context.read (it doesn't watch the
    // provider), so it won't repaint when these async loads finish notifying.
    // Rebuild once they resolve — otherwise the first entry after a restart
    // shows the wrong handicap mode (full vs SO) and no per-game status strip,
    // and it's only correct on the second entry (when the summary is cached).
    if (futures.isNotEmpty) {
      Future.wait(futures).whenComplete(() {
        if (mounted) setState(() {});
      });
    }
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
    // The stroke-dot display follows the PRIMARY game's handicap. Side games
    // (skins / stableford / stroke play) only drive it when they ARE the
    // primary; otherwise they compute their own net server-side.
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
    if (games.contains('triple_cup') && rp.tripleCupSummary != null) {
      return (rp.tripleCupSummary!.handicapMode,
              rp.tripleCupSummary!.netPercent);
    }
    if (games.contains('points_531') && rp.points531Summary != null) {
      return (rp.points531Summary!.handicapMode, rp.points531Summary!.netPercent);
    }
    if (games.contains('vegas') && rp.vegasSummary != null) {
      return (rp.vegasSummary!.handicapMode, rp.vegasSummary!.netPercent);
    }
    if (games.contains('fourball') && rp.fourballSummary != null) {
      return (rp.fourballSummary!.handicapMode, rp.fourballSummary!.netPercent);
    }
    // Three-Person Match has its own per-game handicap mode (the user
    // picks it on the TPM setup screen).  Take precedence over Match
    // Play's read below: a 3-some with match_play in active_games auto-
    // dispatches to TPM, and the TPM summary is the authoritative mode
    // for that foursome.
    if (rp.threePersonMatchSummary != null) {
      return (
        rp.threePersonMatchSummary!.handicapMode,
        rp.threePersonMatchSummary!.netPercent,
      );
    }
    // Match Play stores its handicap mode on the bracket (per-foursome),
    // not on the round.  Read it off the loaded matchPlayData so the
    // score-entry display reflects the bracket's mode — e.g. a casual
    // round defaults to round-level Net but a Match-Play bracket set to
    // Strokes-Off Low should drive the per-player bubble + stroke calc
    // for that foursome.
    if (games.contains('match_play') && rp.matchPlayData != null) {
      final h = rp.matchPlayData!['handicap'] as Map?;
      if (h != null) {
        return (
          h['mode']        as String? ?? 'net',
          h['net_percent'] as int?    ?? 100,
        );
      }
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

  /// Real (non-phantom) players.  Nassau-ordered (T2/red then T1/blue) when available.
  List<Membership> _orderedPlayers(
    Scorecard sc,
    Round? round,
    NassauSummary? nas, {
    TripleCupSummary? tripleCup,
    FourballSummary? fourball,
  }) {
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

    // Triple Cup: Red (team_number 1) on top, Blue on the bottom.
    if (tripleCup != null && tripleCup.matches.isNotEmpty) {
      // Build a stable player_id → team_number map from any match
      // (every match in the game uses the same team assignment).
      final teamOf = <int, int>{};
      for (final m in tripleCup.matches) {
        for (final p in m.players) {
          if (p.isPhantom) continue;
          teamOf.putIfAbsent(p.playerId, () => p.teamNumber);
        }
      }
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

    // Fourball: group teammates together — Team 1 on top, Team 2 below.
    if (fourball != null &&
        (fourball.team1.hasPlayers || fourball.team2.hasPlayers)) {
      final ordered = <Membership>[];
      for (final id in [
        ...fourball.team1.playerIds,
        ...fourball.team2.playerIds,
      ]) {
        final m = members.where((m) => m.player.id == id).firstOrNull;
        if (m != null) ordered.add(m);
      }
      for (final m in members) {
        if (!ordered.any((o) => o.player.id == m.player.id)) ordered.add(m);
      }
      return ordered;
    }

    if (nas == null) return members;

    final ordered = <Membership>[];
    // T1 first, T2 second — stable team order (the orange/blue row colors show
    // the teams, not the order).  Was T2/"most red" first, a leftover from
    // before cup teams had pickable colors.
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

  /// If the user is on a foursomes hole AND the team hasn't picked
  /// who tees off first yet, open the picker modal.  No-op when the
  /// pick already exists (casual flow sets it at setup) or when we've
  /// already prompted for this match this session.
  void _maybePromptTripleCupTeeOff(RoundProvider rp, List<String> games) {
    if (!games.contains('triple_cup')) return;
    final tc = rp.tripleCupSummary;
    if (tc == null) return;
    for (final m in tc.matches) {
      if (m.segment != 'foursomes') continue;
      if (_selectedHole < m.startHole || _selectedHole > m.endHole) continue;
      // Need a pick for each side that actually has 2 real players
      // (skip the solo side of 2v1).
      bool needsT1 = m.players
              .where((p) => p.teamNumber == 1 && !p.isPhantom)
              .length >= 2 && m.team1FirstTeeId == null;
      bool needsT2 = m.players
              .where((p) => p.teamNumber == 2 && !p.isPhantom)
              .length >= 2 && m.team2FirstTeeId == null;
      if (!needsT1 && !needsT2) return;
      if (_teeOffPromptShown.contains(m.matchNumber)) return;
      _teeOffPromptShown.add(m.matchNumber);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showTripleCupTeeOffPicker(m);
      });
      return;
    }
  }

  Future<void> _showTripleCupTeeOffPicker(TripleCupMatch match) async {
    List<TripleCupMatchPlayer> teamPlayers(int t) => match.players
        .where((p) => p.teamNumber == t && !p.isPhantom)
        .toList();
    int? pickT1 = match.team1FirstTeeId;
    int? pickT2 = match.team2FirstTeeId;
    // Cup team names + colours pulled from the live TC summary so
    // the modal reads as "Tilden Green tees off?" instead of the
    // generic "Red".  Falls back to Red/Blue for casual rounds.
    final tcSummary = context.read<RoundProvider>().tripleCupSummary;
    final t1Label   = tcSummary?.team1Name ?? 'Blue';
    final t2Label   = tcSummary?.team2Name ?? 'Orange';
    final t1Color   = tcSummary?.team1Color ?? kTripleCupTeam1Color;
    final t2Color   = tcSummary?.team2Color ?? kTripleCupTeam2Color;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setStateDlg) {
        final theme = Theme.of(ctx);
        final t1 = teamPlayers(1);
        final t2 = teamPlayers(2);
        final ready =
            (t1.length < 2 || pickT1 != null) &&
            (t2.length < 2 || pickT2 != null);

        Widget pickerRow(String label, Color color,
            List<TripleCupMatchPlayer> team, int? selected,
            void Function(int) onPick) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Cup team names ("Tilden Green") can be longer than
                // "Red" / "Blue"; put the label on its own line so
                // wider names don't squeeze the picker.
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
                const SizedBox(height: 4),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: team
                      .map((p) => ButtonSegment<int>(
                            value: p.playerId,
                            label: Text(p.shortName.isEmpty
                                ? p.name
                                : p.shortName),
                          ))
                      .toList(),
                  selected: selected == null ? <int>{} : {selected},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (s) =>
                      s.isEmpty ? null : onPick(s.first),
                  style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          );
        }

        return AlertDialog(
          title: const Text('Foursomes tee-off'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Who tees off hole ${match.startHole} for each team?  '
                'Partners alternate through the 6 alt-shot holes.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if (t1.length >= 2)
                pickerRow(t1Label, t1Color, t1, pickT1,
                    (id) => setStateDlg(() => pickT1 = id)),
              if (t2.length >= 2)
                pickerRow(t2Label, t2Color, t2, pickT2,
                    (id) => setStateDlg(() => pickT2 = id)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: ready
                  ? () async {
                      final rp = context.read<RoundProvider>();
                      await rp.setTripleCupFoursomesTeeOff(
                        widget.foursomeId,
                        team1FirstTee: pickT1,
                        team2FirstTee: pickT2,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    }
                  : null,
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );
  }

  // ── Score helpers ────────────────────────────────────────────────────────────

  /// Pull the latest scorecard + game summaries from the server and re-land on
  /// the first unplayed hole. Lets a cross-account scorer who fell behind the
  /// owner see the just-entered holes and jump to the hole actually in play.
  /// Used by the app-bar refresh button and pull-to-refresh.
  Future<void> _refresh() async {
    final rp = context.read<RoundProvider>();
    await rp.loadScorecard(widget.foursomeId);
    if (!mounted) return;
    final fresh = context.read<RoundProvider>();
    _loadGameSummaries(fresh);
    _jumpToFirstUnplayed(fresh);
  }

  /// The holes this foursome plays, IN PLAY ORDER — starting at the round's
  /// starting hole and wrapping around the course size. Reduces to 1..18 for a
  /// normal round. Mirrors services/hole_plan.play_order. (Per-group shotgun
  /// starts are a later slice; casual rounds use the round-level start.)
  List<int> _playOrderFor(RoundProvider rp) {
    final r  = rp.round;
    final sc = rp.scorecard;
    final universe = (sc == null || sc.holes.isEmpty)
        ? 18
        : sc.holes.map((h) => h.holeNumber).reduce((a, b) => a > b ? a : b);
    final start = r?.startingHole ?? 1;
    final n = (r?.numHoles ?? universe).clamp(1, universe);
    return [for (int i = 0; i < n; i++) ((start - 1 + i) % universe) + 1];
  }

  /// The hole after [_selectedHole] in play order, or null if it's the last one.
  int? _nextHoleInOrder(RoundProvider rp) {
    final order = _playOrderFor(rp);
    final i = order.indexOf(_selectedHole);
    return (i < 0 || i + 1 >= order.length) ? null : order[i + 1];
  }

  /// The hole before [_selectedHole] in play order, or null if it's the first.
  int? _prevHoleInOrder(RoundProvider rp) {
    final order = _playOrderFor(rp);
    final i = order.indexOf(_selectedHole);
    return (i <= 0) ? null : order[i - 1];
  }

  /// True when [hole] is at the frontier of play — no LATER hole in play order
  /// has any score. Only the trailing hole may be cleared, so clearing can
  /// never punch a gap into the middle of the round (no-gaps model). Earlier
  /// holes are corrected by overwriting the value instead.
  bool _isTrailingHole(int hole) {
    final rp = context.read<RoundProvider>();
    final sc = rp.scorecard;
    if (sc == null) return true;
    final order = _playOrderFor(rp);
    final idx = order.indexOf(hole);
    if (idx < 0) return true;
    for (int i = idx + 1; i < order.length; i++) {
      if (_effectiveScores(sc, order[i]).isNotEmpty) return false;
    }
    return true;
  }

  void _jumpToFirstUnplayed(RoundProvider rp) {
    final sc = rp.scorecard;
    if (sc == null) return;
    final realIds = _orderedPlayers(sc, rp.round, rp.nassauSummary)
        .map((m) => m.player.id)
        .toSet();
    final order = _playOrderFor(rp);
    for (final h in order) {
      final hd = sc.holeData(h);
      if (hd == null) continue;
      final allScored = hd.scores
          .where((s) => realIds.contains(s.playerId))
          .where((s) => !_isInactiveAltShotPlayerAt(s.playerId, h))
          .every((s) => s.grossScore != null);
      if (!allScored && !rp.localPendingByHole.containsKey(h)) {
        setState(() => _selectedHole = h);
        return;
      }
    }
    setState(() => _selectedHole = order.isNotEmpty ? order.last : 18);
  }

  /// True iff *playerId* is the dimmed alt-shot partner on *hole*
  /// in a Triple Cup foursomes match.  Used by both the in-flight
  /// hot-spot check and the initial "jump to first unplayed" so the
  /// inactive partner never blocks a hole from counting as complete.
  bool _isInactiveAltShotPlayerAt(int playerId, int hole) {
    final tc = context.read<RoundProvider>().tripleCupSummary;
    if (tc == null) return false;
    for (final m in tc.matches) {
      if (m.segment != 'foursomes') continue;
      if (hole < m.startHole || hole > m.endHole) continue;
      final entry = m.players.firstWhere(
        (p) => p.playerId == playerId && !p.isPhantom,
        orElse: () => const TripleCupMatchPlayer(
            playerId: -1, name: '', shortName: '', teamNumber: 0),
      );
      if (entry.teamNumber == 0) return false;
      final active = m.activePlayerId(entry.teamNumber, hole);
      if (active == null) return false;
      return active != playerId;
    }
    return false;
  }

  /// Sentinel stored in [_pending] for a CLEARED score (the trailing-only Clear
  /// via the edit sheet). Dropped from effective scores so the cell reads blank,
  /// and mapped to a null gross on save so the server deletes the row.
  static const int _kClearedScore = -1;

  Map<int, int> _effectiveScores(Scorecard sc, int hole) {
    final saved = <int, int>{};
    final hd = sc.holeData(hole);
    if (hd != null) {
      for (final s in hd.scores) {
        if (s.grossScore != null) saved[s.playerId] = s.grossScore!;
      }
    }
    final merged = {...saved, ...(_pending[hole] ?? {})};
    merged.removeWhere((_, v) => v == _kClearedScore);   // cleared → blank
    return merged;
  }

  int _hotSpotIdx(List<Membership> players, Map<int, int> scores) {
    for (int i = 0; i < players.length; i++) {
      if (_isInactiveAltShotPlayer(players[i].player.id)) continue;
      if (players[i].isWithdrawnOnHole(_selectedHole)) continue;
      if (!scores.containsKey(players[i].player.id)) return i;
    }
    return -1;
  }

  /// Holes the group abandoned at a mid-round withdrawal — voided for
  /// everyone, so no score is expected on them.
  Set<int> _killedHoles(List<Membership> players) {
    final out = <int>{};
    for (final m in players) {
      if (m.withdrewAfterHole != null &&
          m.withdrewKilledNextHole &&
          m.withdrewAfterHole! + 1 <= 18) {
        out.add(m.withdrewAfterHole! + 1);
      }
    }
    return out;
  }

  /// True iff every "real" player has a score at *hole*, treating the
  /// dimmed alt-shot partner on that hole as not-required.  *hole* is
  /// the hole being validated — must NOT be assumed to be _selectedHole
  /// because _allHolesScored iterates 1–18.
  ///
  /// Mid-round withdrawals relax this: a player who withdrew before *hole*
  /// isn't required, and a hole abandoned at a withdrawal needs no score.
  bool _allScored(List<Membership> players, Map<int, int> scores, int hole) {
    if (_killedHoles(players).contains(hole)) return true;
    return players.every((m) =>
        m.isWithdrawnOnHole(hole) ||
        _isInactiveAltShotPlayerAt(m.player.id, hole) ||
        scores.containsKey(m.player.id));
  }

  /// True iff the given player is the dimmed partner on the current
  /// hole of a Triple Cup foursomes (alt-shot) match.  Used to skip
  /// them in hot-spot and all-scored computations.
  bool _isInactiveAltShotPlayer(int playerId) {
    final tc = context.read<RoundProvider>().tripleCupSummary;
    if (tc == null) return false;
    final hole = _selectedHole;
    for (final m in tc.matches) {
      if (m.segment != 'foursomes') continue;
      if (hole < m.startHole || hole > m.endHole) continue;
      final onTeam = m.players.firstWhere(
        (p) => p.playerId == playerId && !p.isPhantom,
        orElse: () => const TripleCupMatchPlayer(
            playerId: -1, name: '', shortName: '', teamNumber: 0),
      );
      if (onTeam.teamNumber == 0) return false;
      final active = m.activePlayerId(onTeam.teamNumber, hole);
      if (active == null) return false;
      return active != playerId;
    }
    return false;
  }

  /// Number of holes (1–18) not yet fully scored — used by the soft-gate
  /// "Finish early?" warning when completing before the 18th.
  int _unscoredHoleCount(Scorecard sc, List<Membership> players) {
    final rp = context.read<RoundProvider>();
    int n = 0;
    for (final h in _playOrderFor(rp)) {
      if (!_allScored(players, _effectiveScores(sc, h), h)) n++;
    }
    return n;
  }

  /// True once any score has been entered (saved or pending) — gates the
  /// app-bar Exit (✕) on casual rounds: before any score, the back arrow
  /// returns to the launch page (to edit config/tees); after, ✕ exits.
  bool get _hasAnyScore {
    if (_pending.isNotEmpty || _pendingJunk.isNotEmpty) return true;
    final rp = context.read<RoundProvider>();
    // Saved scores in the loaded scorecard — reflects a just-saved hole even
    // before the round detail (foursome.hasAnyScore) reloads.
    final sc = rp.scorecard;
    if (sc != null) {
      for (final h in _playOrderFor(rp)) {
        if (_effectiveScores(sc, h).isNotEmpty) return true;
      }
    }
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    return fs?.hasAnyScore ?? false;
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
    final n = _nextHoleInOrder(context.read<RoundProvider>());
    if (n != null) setState(() => _selectedHole = n);
  }

  void _retreat() {
    final p = _prevHoleInOrder(context.read<RoundProvider>());
    if (p != null) setState(() => _selectedHole = p);
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
          .map((e) => <String, int?>{
                'player_id': e.key,
                // Cleared sentinel → null gross so the server deletes the row.
                'gross_score': e.value == _kClearedScore ? null : e.value,
              })
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

  /// Save pending scores/junk for the current hole without navigating.
  /// Used by the auto-advance trigger on hole 18 (where there's no next
  /// hole to jump to) and by the "Save scores" button on hole 18.
  Future<bool> _saveCurrentHole(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final rp = context.read<RoundProvider>();

    final scoreEdits = _pending[_selectedHole];
    final junkEdits  = _pendingJunk[_selectedHole];

    if ((scoreEdits == null || scoreEdits.isEmpty) &&
        (junkEdits == null || junkEdits.isEmpty)) {
      return true;
    }

    if (scoreEdits != null && scoreEdits.isNotEmpty) {
      final scores = scoreEdits.entries
          .map((e) => <String, int?>{
                'player_id': e.key,
                // Cleared sentinel → null gross so the server deletes the row.
                'gross_score': e.value == _kClearedScore ? null : e.value,
              })
          .toList();
      final ok = await rp.submitHole(
        foursomeId: widget.foursomeId,
        holeNumber: _selectedHole,
        scores:     scores,
      );
      if (!mounted) return false;
      if (!ok) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(rp.error ?? 'Failed to save hole.'),
          backgroundColor: Theme.of(ctx).colorScheme.error,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Theme.of(ctx).colorScheme.onError,
            onPressed: () => _saveCurrentHole(ctx, players, par),
          ),
        ));
        return false;
      }
      setState(() { _pending.remove(_selectedHole); });
    }

    if (junkEdits != null && junkEdits.isNotEmpty) {
      await _submitJunk(_selectedHole, junkEdits);
    }

    _loadGameSummaries(rp);
    context.read<SyncService>().waitUntilIdle().then((_) {
      if (mounted) _loadGameSummaries(context.read<RoundProvider>());
    });
    return true;
  }

  /// Explicit "Complete Round" action: confirm, save any pending edits,
  /// mark the round complete via the API, then navigate to the leaderboard.
  Future<void> _completeRound(
    BuildContext ctx,
    List<Membership> players,
    int par,
  ) async {
    final rp      = context.read<RoundProvider>();
    final roundId = rp.round?.id;
    if (roundId == null) return;

    // Multi-foursome cup rounds: a single group's "Complete Round" no
    // longer locks the whole round — the backend only flips status
    // when EVERY foursome has 18 holes scored.  The confirm dialog
    // copy reflects that so the user doesn't fear locking out their
    // playing partners.
    final foursomeCount = rp.round?.foursomes.length ?? 1;
    final isMultiGroup = foursomeCount > 1;

    // Soft gate: if holes are still blank (finishing early — e.g. a match
    // decided before the 18th), warn but allow.  0 unscored → normal copy.
    final sc = rp.scorecard;
    final unscored = sc == null ? 0 : _unscoredHoleCount(sc, players);

    if (!await confirmCompleteRound(
      ctx,
      isMultiGroup: isMultiGroup,
      unscoredHoles: unscored,
    )) return;
    if (!mounted) return;

    // Save any still-pending current-hole edits first.
    final saved = await _saveCurrentHole(ctx, players, par);
    if (!mounted || !saved) return;

    await context.read<SyncService>().waitUntilIdle();
    if (!mounted) return;

    final lb = await rp.completeRound(roundId);
    if (!mounted) return;

    if (lb == null) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Could not complete round.'),
        backgroundColor: Theme.of(ctx).colorScheme.error,
      ));
      return;
    }

    // Backend leaves status == 'in_progress' until every foursome has
    // 18 holes scored.  Surface the "waiting on other groups" state
    // so the user doesn't expect Final Results.
    if (isMultiGroup && lb.status != 'complete') {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
        duration: Duration(seconds: 4),
        content: Text(
          'Your group is finished. The round will close once every '
          'other group also completes.',
        ),
      ));
    }

    Navigator.of(ctx).pushNamed('/leaderboard', arguments: roundId);
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

  // ── Mid-round withdrawal ──────────────────────────────────────────────

  /// Highest hole this player has a posted gross score on (0 if none).
  int _lastScoredHole(int playerId) {
    final sc = context.read<RoundProvider>().scorecard;
    if (sc == null) return 0;
    for (int h = 18; h >= 1; h--) {
      if ((sc.holeData(h)?.scoreFor(playerId)?.grossScore) != null) return h;
    }
    return 0;
  }

  /// Long-press a player row → manage their mid-round withdrawal.
  Future<void> _showWithdrawSheet(
      RoundProvider rp, Membership m, List<String> games) async {
    if (m.player.isPhantom) return;
    final theme = Theme.of(context);

    // Already out → offer to reinstate (undo a mistaken WD).
    if (m.withdrewAfterHole != null) {
      final undo = await showModalBottomSheet<bool>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.undo),
              title: Text('Reinstate ${m.player.name}'),
              subtitle: Text(
                  'They withdrew after hole ${m.withdrewAfterHole}. '
                  'Bring them back into the round.'),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ]),
        ),
      );
      if (undo == true) await _doReinstate(rp, m);
      return;
    }

    final isSixes = games.contains('sixes');
    int afterHole = _lastScoredHole(m.player.id).clamp(0, 17);
    bool killNext = false;
    String sixesAction = 'void';

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final nextHole = afterHole + 1;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Withdraw ${m.player.name}',
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  "Their scores stand and the rest of the group keeps playing. "
                  "They won't be scored on the remaining holes.",
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                // Last hole completed stepper.
                Row(children: [
                  Expanded(
                    child: Text('Last hole completed',
                        style: theme.textTheme.bodyLarge),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: afterHole > 0
                        ? () => setSheet(() => afterHole--)
                        : null,
                  ),
                  Text(afterHole == 0 ? 'None' : '$afterHole',
                      style: theme.textTheme.titleMedium),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: afterHole < 17
                        ? () => setSheet(() => afterHole++)
                        : null,
                  ),
                ]),
                if (nextHole <= 18)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Group abandoned hole $nextHole'),
                    subtitle: const Text(
                        'Void that hole for everyone (nobody scores it).'),
                    value: killNext,
                    onChanged: (v) => setSheet(() => killNext = v),
                  ),
                if (isSixes) ...[
                  const Divider(height: 24),
                  Text('Sixes matches', style: theme.textTheme.titleSmall),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Void the affected matches'),
                    subtitle: const Text('0 points, excluded from the result.'),
                    value: 'void',
                    groupValue: sixesAction,
                    onChanged: (v) => setSheet(() => sixesAction = v!),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Partner plays solo'),
                    subtitle: const Text('Their teammate plays on alone.'),
                    value: 'solo',
                    groupValue: sixesAction,
                    onChanged: (v) => setSheet(() => sixesAction = v!),
                  ),
                ],
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Withdraw'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        );
      }),
    );

    if (confirmed == true) {
      await _doWithdraw(rp, m, afterHole, killNext,
          isSixes ? sixesAction : null);
    }
  }

  Future<void> _doWithdraw(RoundProvider rp, Membership m, int afterHole,
      bool killNext, String? sixesAction) async {
    final client = context.read<AuthProvider>().client;
    try {
      await client.withdrawPlayer(
        widget.foursomeId, m.player.id, afterHole,
        killNextHole: killNext, sixesAction: sixesAction,
      );
      final roundId = rp.round?.id;
      if (roundId != null) await rp.loadRound(roundId);
      if (!mounted) return;
      _loadGameSummaries(context.read<RoundProvider>());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${m.player.name} withdrew after hole $afterHole.'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not withdraw player: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  Future<void> _doReinstate(RoundProvider rp, Membership m) async {
    final client = context.read<AuthProvider>().client;
    try {
      await client.reinstatePlayer(widget.foursomeId, m.player.id);
      final roundId = rp.round?.id;
      if (roundId != null) await rp.loadRound(roundId);
      if (!mounted) return;
      _loadGameSummaries(context.read<RoundProvider>());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${m.player.name} is back in the round.'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not reinstate player: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  // ── App bar title ────────────────────────────────────────────────────────────

  String _appBarTitle(List<String> games, NassauSummary? nas, SkinsSummary? sk) {
    final parts = <String>[];
    for (final g in games) {
      String label = gameDisplayName(g);
      if (g == 'nassau' && nas != null) {
        final modeStr = _modeLabel(nas.handicapMode, nas.netPercent);
        final base = nas.isEighteenHoleMatch ? 'Singles Match' : label;
        label = '$base ($modeStr)';
      } else if (g == 'skins' && sk != null) {
        final modeStr = _modeLabel(sk.handicapMode, sk.netPercent);
        label = '$label ($modeStr)';
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

    // Jump to first unplayed hole once scorecard is loaded.  When
    // Triple Cup is active, also wait for the TC summary — the jump
    // needs to know who the dimmed alt-shot partner is on each
    // foursomes hole, and without that info every 7–12 hole looks
    // "incomplete" and the jump misfires to hole 7.
    final waitForTc = games.contains('triple_cup') &&
        rp.tripleCupSummary == null;
    if (!_initialJumpDone &&
        sc != null &&
        rp.activeFoursomeId == widget.foursomeId &&
        !waitForTc) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstUnplayed(context.read<RoundProvider>());
      });
    }

    // On a single-foursome casual round, once any score is entered the launch
    // page (hub) is no longer reachable and the app-bar arrow is easily
    // mistaken for "previous hole" (which is the bottom-left button).  Swap it
    // for an explicit ✕ Exit that returns to the casual rounds list.  Before
    // any score, keep the back arrow so the hub (config/tee edits) stays one
    // tap away.
    final isCasualSingle = (rp.round?.isCasual ?? false) &&
        (rp.round?.foursomes.length ?? 1) == 1;
    final showExit = isCasualSingle && _hasAnyScore;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: showExit ? 'Exit to rounds' : 'Close',
          onPressed: showExit
              ? () => Navigator.of(context).popUntil(
                  (r) => r.settings.name == '/casual-rounds' || r.isFirst)
              : () => Navigator.of(context).maybePop(),
        ),
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
          // Pull the latest scores (e.g. when another scorer is ahead of you)
          // and re-land on the current hole.  (Refresh is a fallback — scores
          // auto-sync — so it lives in the ⋯ overflow, not the toolbar.)
          // Chat lives here because the scorer lives on this screen; the badge
          // is the (push-less) notification that a message arrived.
          if (rp.round != null)
            RoundChatButton(roundId: rp.round!.id),
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null
                ? null
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: rp.round!.id),
          ),
          // Overflow: low-frequency actions — finishing the round early (soft
          // gate) and the icon-legend help sheet.
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'refresh':
                  if (rp.round != null) _refresh();
                  break;
                case 'finish':
                  if (sc == null) return;
                  final players = _orderedPlayers(
                    sc, rp.round, nas,
                    tripleCup: games.contains('triple_cup')
                        ? rp.tripleCupSummary
                        : null,
                    fourball: games.contains('fourball')
                        ? rp.fourballSummary
                        : null,
                  );
                  final par = sc.holeData(_selectedHole)?.par ?? 4;
                  _completeRound(context, players, par);
                  break;
                case 'help':
                  showScoreEntryHelp(context);
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh scores'),
                ),
              ),
              if (!isComplete && sc != null)
                const PopupMenuItem(
                  value: 'finish',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.flag_outlined),
                    title: Text('Finish round'),
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
      body: () {
        // Triple Cup: when the user lands on a foursomes hole and the
        // team hasn't decided who tees off yet (cup convention —
        // matches set in advance, tee-off picked at hole 7), pop the
        // prompt.  Casual rounds already pick at setup so this is a
        // no-op there.  Guarded by [_teeOffPromptShown] to avoid
        // reopening every rebuild after the user dismisses.
        _maybePromptTripleCupTeeOff(rp, games);
        return _buildBody(context, rp, sync, sc, nas, skins, games, isComplete);
      }(),
      bottomNavigationBar:
          sc == null ? null : _buildBottomBar(context, rp, sc, nas, games),
    );
  }

  /// Irish Rumble "best N of M count this hole" banner, shown at the top of the
  /// entry body (matching the Pink Ball carrier banner).
  Widget _irBallsBanner(BuildContext ctx, RoundProvider rp) {
    final irN = rp.round?.irBallsForHole(_selectedHole);
    if (irN == null) return const SizedBox.shrink();
    final theme = Theme.of(ctx);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withOpacity(0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      // Matches the Pink Ball carrier banner's wording + icon.
      child: Row(children: [
        Icon(Icons.filter_none, size: 16,
            color: theme.colorScheme.onSecondaryContainer),
        const SizedBox(width: 8),
        Text(
          '$irN ${irN == 1 ? 'ball counts' : 'balls count'} for Irish Rumble',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer),
        ),
      ]),
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
    final players    = _orderedPlayers(sc, rp.round, nas,
        tripleCup: games.contains('triple_cup') ? rp.tripleCupSummary : null,
        fourball: games.contains('fourball') ? rp.fourballSummary : null);
    final scores     = _effectiveScores(sc, _selectedHole);
    final allDone    = _allScored(players, scores, _selectedHole);
    final isComplete = rp.round?.status == 'complete';
    final par        = sc.holeData(_selectedHole)?.par ?? 4;
    final mpData     = rp.matchPlayData;

    // Don't show the Match Play status bar for THIS foursome when:
    //   • the current foursome has 3 real players (they play TPM, not a
    //     bracket — rendering the strip would show some other foursome's
    //     players from the round-shared rp.matchPlayData), OR
    //   • the loaded mpData is for a different foursome (foursome_id
    //     mismatch — also leftover state from a previous tap-through).
    final fsHere = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    final isThreesome = fsHere?.realPlayers.length == 3;
    final mpFoursomeId = (mpData?['foursome_id'] as int?);
    final mpForThisFoursome = mpData != null &&
        !isThreesome &&
        (mpFoursomeId == null || mpFoursomeId == widget.foursomeId);

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
          // Match Play running totals bar (bracket) OR cup singles status.
          // Skipped for 3-player foursomes (they play TPM via the auto-
          // dispatch, not a bracket) and for foursomes whose loaded mpData
          // belongs to another group — otherwise the bar shows another
          // foursome's players, which is what produced the "3-some bottom
          // shows the 4-some's players" bug.
          if (mpForThisFoursome &&
              (games.contains('match_play') ||
               games.contains('singles_18') ||
               games.contains('singles_nassau')))
            mpData!['bracket_type'] == 'cup_singles'
                ? _CupSinglesStatusBar(data: mpData)
                : _MatchPlayStatusBar(data: mpData),
          // (Irish Rumble balls-counted banner + borrowed-4th row moved to the
          // TOP of the entry body — see _buildBody — to match the Pink Ball
          // screen; they no longer live in this footer.)
          // Hole navigation / completion.  (Finishing the round early lives in
          // the app-bar overflow menu — it's a rare action and doesn't earn a
          // permanent slot down here.)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(children: [
              Expanded(
                child: Builder(builder: (_) {
                  final prev = _prevHoleInOrder(rp);
                  return OutlinedButton.icon(
                    onPressed: prev != null ? _retreat : null,
                    icon: const Icon(Icons.chevron_left, size: 20),
                    label: Text(prev != null ? 'Hole $prev' : 'Previous'),
                  );
                }),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildPrimaryActionButton(
                  ctx, rp, sc, players, par, allDone, isComplete,
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  /// The right-hand primary action button.  Behavior depends on hole and
  /// round status:
  ///   • Round complete            → "View Leaderboard"
  ///   • Hole 1–17, current hole done → "Hole N+1" (manual advance)
  ///   • Hole 1–17, not done        → "Hole N+1" disabled
  ///   • Hole 18, current hole pending → "Save scores" (saves, stays)
  ///   • Hole 18, all 18 holes done   → "Complete Round" (confirm + complete)
  ///   • Hole 18, missing earlier holes → "Complete Round" disabled
  Widget _buildPrimaryActionButton(
    BuildContext ctx,
    RoundProvider rp,
    Scorecard sc,
    List<Membership> players,
    int par,
    bool allDone,
    bool isComplete,
  ) {
    if (isComplete) {
      final roundId = rp.round?.id;
      return FilledButton.icon(
        onPressed: roundId == null
            ? null
            : () => Navigator.of(ctx)
                .pushNamed('/leaderboard', arguments: roundId),
        icon: const Icon(Icons.emoji_events, size: 20),
        label: const Text('View Leaderboard'),
      );
    }

    final nextHole = _nextHoleInOrder(rp);
    if (nextHole != null) {
      return FilledButton.icon(
        onPressed: (allDone && !rp.submitting)
            ? () => _saveAndAdvance(ctx, players, par)
            : null,
        icon: rp.submitting
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.chevron_right, size: 20),
        label: Text(rp.submitting ? 'Saving…' : 'Hole $nextHole'),
        iconAlignment: IconAlignment.end,
      );
    }

    // Last hole in play order.
    final pendingHere = (_pending[_selectedHole]?.isNotEmpty ?? false) ||
                       (_pendingJunk[_selectedHole]?.isNotEmpty ?? false);

    if (pendingHere) {
      return FilledButton.icon(
        onPressed: (allDone && !rp.submitting)
            ? () => _saveCurrentHole(ctx, players, par)
            : null,
        icon: rp.submitting
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.save_outlined, size: 20),
        label: Text(rp.submitting ? 'Saving…' : 'Save scores'),
      );
    }

    // Complete Round is a primary terminal action — use the default
    // brand-green FilledButton style, not the tertiary teal override that
    // made this button look one-off (D-01 in the May 2026 design audit).
    // Soft gate: always enabled (when not submitting); _completeRound warns
    // via the "Finish early?" dialog if any holes are still blank.
    return FilledButton.icon(
      onPressed: rp.submitting ? null : () => _completeRound(ctx, players, par),
      icon: rp.submitting
          ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.flag_rounded, size: 20),
      label: Text(rp.submitting ? 'Completing…' : 'Complete Round'),
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
          InlineMessage(kind: InlineMessageKind.error, text: rp.error!),
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

    final players  = _orderedPlayers(sc, rp.round, nas,
        tripleCup: games.contains('triple_cup') ? rp.tripleCupSummary : null,
        fourball: games.contains('fourball') ? rp.fourballSummary : null);
    final merged   = _mergePending(rp.localPendingByHole, _pending);
    final holeData = sc.holeData(_selectedHole);
    final scores   = _effectiveScores(sc, _selectedHole);
    final hotSpot  = isComplete ? -1 : _hotSpotIdx(players, scores);
    final par      = holeData?.par ?? 4;
    final (hMode, hPct) = _handicapParams(rp, games);
    // Junk is a score-entry modifier, so it's only available when Skins is the
    // PRIMARY. As a side game, Skins computes from gross/net only (no junk).
    final allowJunk = resolvePrimary(rp.round?.primaryGame, games) == 'skins' &&
        (skins?.allowJunk ?? false);

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

      // Nassau presses strip (top + bottom combined)
      if (nas != null &&
          (nas.presses.isNotEmpty || nas.bottomPresses.isNotEmpty))
        _PressesStrip(
          presses:       nas.presses,
          bottomPresses: nas.bottomPresses,
          currentHole:   _selectedHole,
        ),

      Expanded(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Irish Rumble balls-counted banner — at the top, matching the
              // Pink Ball screen (was previously a footer strip).
              if (games.contains('irish_rumble')) _irBallsBanner(ctx, rp),
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
                vegasSummary:    games.contains('vegas')      ? rp.vegasSummary    : null,
                fourballSummary: games.contains('fourball')   ? rp.fourballSummary : null,
                tripleCupSummary: games.contains('triple_cup') ? rp.tripleCupSummary : null,
                points531Summary: games.contains('points_531') ? rp.points531Summary : null,
                // Gate on match play / cup singles being active so stale
                // bracket data can't tint a non-match-play (e.g. stroke-play)
                // round's player rows.
                matchPlayData:   (games.contains('match_play') ||
                        games.contains('singles_nassau') ||
                        games.contains('singles_18'))
                    ? rp.matchPlayData : null,
                isCupSingles:    games.contains('singles_nassau') || games.contains('singles_18'),
                hasThreePersonMatch:
                    games.contains('match_play') && rp.threePersonMatchSummary != null,
                handicapMode:    hMode,
                netPercent:      hPct,
                allowJunk:       allowJunk,
                junkForPlayer:   (pid) => _currentJunk(pid, _selectedHole, skins),
                blockedExtraSeg: needsTeamsSeg,
                onOpenExtraTeamsPicker: needsTeamsSeg == null
                    ? null
                    : () => _showExtraTeamPicker(needsTeamsSeg, players),
                onScoreSelected: (m, score) {
                  final hole = _selectedHole;
                  final wasAllScored = _allScored(
                    players, _effectiveScores(sc, hole), hole);
                  _selectScore(m, score, hole);
                  // Auto-save+advance the moment the last player on the hole
                  // gets a positive score.  Skip when clearing (score == -1)
                  // and when the hole was already complete (user is editing).
                  // Gated by the Auto-advance setting — when off, the user
                  // stays on the hole to verify and presses next manually.
                  final autoAdvance =
                      context.read<SettingsProvider>().autoAdvanceHole;
                  if (autoAdvance && score > 0 && !wasAllScored) {
                    final nowAllScored = _allScored(
                      players, _effectiveScores(sc, hole), hole);
                    if (nowAllScored) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (_selectedHole != hole) return;
                        final rp = context.read<RoundProvider>();
                        if (rp.submitting) return;
                        if (hole < 18) {
                          _saveAndAdvance(ctx, players, par);
                        } else {
                          _saveCurrentHole(ctx, players, par);
                        }
                      });
                    }
                  }
                },
                onEditTap: (m) =>
                    _editScore(ctx, m, par, _selectedHole, players, hMode, hPct),
                onJunkAdd:    (pid) => _adjustJunk(pid, _selectedHole, 1),
                onJunkRemove: (pid) => _adjustJunk(pid, _selectedHole, -1),
                // Spots add-on: an inline ⊖ N spots ⊕ under each player name
                // (the capturesInScoreEntry carve-out). Shown once configured.
                spotsActive: spotsActive(rp),
                spotsCountFor: (pid) =>
                    spotsCount(pid, _selectedHole, rp.spotsSummary),
                onSpotsAdd:    (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, 1),
                onSpotsRemove: (pid) =>
                    adjustSpots(widget.foursomeId, pid, _selectedHole, -1),
                // Long-press a player to record / undo a mid-round withdrawal.
                // Disabled once the round is final.
                onWithdrawTap: isComplete
                    ? null
                    : (m) => _showWithdrawSheet(rp, m, games),
                // Phantom player data (null when foursome has no phantom).
                phantomMembership: rp.round?.foursomes
                    .where((f) => f.id == widget.foursomeId)
                    .firstOrNull
                    ?.memberships
                    .where((m) => m.player.isPhantom)
                    .firstOrNull,
                phantomInit: rp.phantomInitFor(widget.foursomeId),
                // Borrowed-4th (leveled threesome) rendered INSIDE the card as
                // a 4th player row, when this foursome carries a phantom.
                bottomRow: (() {
                  if (!games.contains('irish_rumble')) return null;
                  final fs = rp.round?.foursomes
                      .where((f) => f.id == widget.foursomeId).firstOrNull;
                  final rid = rp.round?.id;
                  if (fs == null || rid == null || fs.hasPhantom != true) {
                    return null;
                  }
                  return BorrowedFourthRow(
                    roundId:     rid,
                    foursomeId:  fs.id,
                    currentHole: _selectedHole,
                  );
                })(),
              ),

              // Stableford running-points band — only when Stableford is the
              // primary (as a side game it shows on the leaderboard, not here).
              if (resolvePrimary(rp.round?.primaryGame, games) == 'stableford' &&
                  rp.stablefordResult != null)
                _StablefordStrip(
                  result:      rp.stablefordResult!,
                  currentHole: _selectedHole,
                ),
              const SizedBox(height: 12),

              // Game status cards
              _GameStatusSection(
                games:                   games,
                primaryGame:             resolvePrimary(rp.round?.primaryGame, games),
                nassau:                  nas,
                skins:                   skins,
                multiSkins:              games.contains('multi_skins')       ? rp.multiSkinsSummary         : null,
                sixesSummary:            games.contains('sixes')             ? rp.sixesSummary              : null,
                vegasSummary:            games.contains('vegas')             ? rp.vegasSummary              : null,
                fourballSummary:         games.contains('fourball')          ? rp.fourballSummary           : null,
                tripleCupSummary:        games.contains('triple_cup')        ? rp.tripleCupSummary          : null,
                points531Summary:        games.contains('points_531')        ? rp.points531Summary           : null,
                // Gate on match play / cup singles being active so stale
                // bracket data can't tint a non-match-play round's rows.
                matchPlayData:           (games.contains('match_play') ||
                        games.contains('singles_nassau') ||
                        games.contains('singles_18'))
                    ? rp.matchPlayData : null,
                threePersonMatchSummary: games.contains('three_person_match') ? rp.threePersonMatchSummary   : null,
                foursomeId:              widget.foursomeId,
                roundId:                 rp.round?.id,
                players:                 players,
                scorecard:               sc,
                currentHole:             _selectedHole,
                loadingNassau:           rp.loadingNassau,
                loadingSkins:            rp.loadingSkins,
                loadingMultiSkins:       rp.loadingMultiSkins,
                loadingSixes:            rp.loadingSixes,
                loadingTripleCup:        rp.loadingTripleCup,
                loadingPoints531:        rp.loadingPoints531,
                loadingVegas:            rp.loadingVegas,
                loadingMatchPlay:        rp.loadingMatchPlay,
                loadingThreePersonMatch: rp.loadingThreePersonMatch,
                onTapHole:               (h) => setState(() => _selectedHole = h),
                irBallsConfig:           games.contains('irish_rumble')
                    ? (rp.round?.irBallsConfig ?? const [])
                    : const [],
                irHandicapMode:          rp.round?.handicapMode ?? 'net',
                strokePlayHandicapMode:
                    rp.lowNetConfig?['handicap_mode'] as String? ?? 'net',
                strokePlayNetPercent:
                    rp.lowNetConfig?['net_percent']   as int?    ?? 100,
                stablefordResult:
                    games.contains('stableford') ? rp.stablefordResult : null,
              ),

              const SizedBox(height: 16),
            ],
          ),
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

    final holeEntry = sc?.holeData(hole)?.scoreFor(player.player.id);
    final si        = holeEntry?.strokeIndex ?? sc?.holeData(hole)?.strokeIndex ?? 18;

    final int strokes;
    final mpData   = rp.matchPlayData;
    final games    = _activeGames(rp.round);
    final isCupSng = games.contains('singles_nassau') || games.contains('singles_18');

    // Cup singles: match-play handicap per pairing (lower = 0, higher = diff).
    if (isCupSng) {
      int so = 0;
      if (mpData != null && mpData['bracket_type'] == 'cup_singles') {
        // Exact per-match differential from loaded bracket data.
        final matches = (mpData['matches'] as List?) ?? [];
        for (final raw in matches) {
          final match = Map<String, dynamic>.from(raw as Map);
          final p1Id  = match['player1_id'] as int?;
          final p2Id  = match['player2_id'] as int?;
          int? opponentId;
          if (p1Id == player.player.id)      opponentId = p2Id;
          else if (p2Id == player.player.id) opponentId = p1Id;
          else continue;
          final opp = players.where((x) => x.player.id == opponentId).firstOrNull;
          if (opp != null) so = player.playingHandicap - opp.playingHandicap;
          break;
        }
      } else if (players.isNotEmpty) {
        // Fallback before matchPlayData loads: strokes off foursome low.
        final low = players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
        so = player.playingHandicap - low;
      }
      strokes = so > 0 ? strokesOnHole(so, si) : 0;
    } else {
      final lowPlaying = hMode == 'strokes_off' && players.isNotEmpty
          ? players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b)
          : null;
      final effective = _effectiveHandicap(
        mode:                  hMode,
        netPercent:            hPct,
        playingHandicap:       player.playingHandicap,
        lowestPlayingHandicap: lowPlaying,
      );
      // Sixes SO: use the exact per-segment algorithm so the modal picker
      // colors match the inline picker and the backend calculation.
      final games = _activeGames(rp.round);
      if (hMode == 'strokes_off' && games.contains('sixes') &&
          rp.sixesSummary != null && sc != null) {
        strokes = _sixesSoStrokesOnHole(
          playerSo:    effective,
          holeNumber:  hole,
          strokeIndex: si,
          summary:     rp.sixesSummary!,
          scorecard:   sc,
        );
      } else {
        strokes = strokesOnHole(effective, si);
      }
    }

    // Clear is offered only on the trailing hole, so it never leaves a gap.
    final canClear = _isTrailingHole(hole);
    final score = await showModalBottomSheet<int>(
      context: ctx,
      useRootNavigator: true,
      builder: (_) => _ScorePickerSheet(
        playerName: player.player.name,
        par:        par,
        holeNumber: hole,
        strokes:    strokes,
        current:    current,
        canClear:   canClear,
      ),
    );
    if (!mounted || score == null) return;
    setState(() {
      // -1 = clear → store the sentinel: the cell blanks and the save sends a
      // null gross so the server deletes the row (persisted, survives reload).
      _pending.putIfAbsent(hole, () => <int, int>{})[player.player.id] =
          score == -1 ? _kClearedScore : score;
    });
    // Commit immediately (save without advancing) — for both an edit and a clear.
    await _saveCurrentHole(ctx, players, par);
  }
}

// ===========================================================================
// Active-hole score card
// ===========================================================================

// Const-default callbacks for the optional Spots controls.
int  _zeroSpots(int _) => 0;
void _noopPid(int _) {}

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
  final VegasSummary?           vegasSummary;
  final FourballSummary?        fourballSummary;
  final TripleCupSummary?       tripleCupSummary;
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

  /// Cup singles bracket data — used to color player names by team.
  final Map<String, dynamic>?   matchPlayData;

  /// True when this foursome is playing cup singles (singles_nassau or
  /// singles_18).  Set from the active-games list so match-play handicap
  /// activates immediately, even before matchPlayData has loaded.
  final bool                    isCupSingles;

  /// True when this foursome is playing the 3-player variant of Mini Singles
  /// Bracket (Three-Person Match) — drives the legend's bracket help text.
  final bool                    hasThreePersonMatch;

  final void Function(Membership, int) onScoreSelected;
  final void Function(Membership)      onEditTap;
  final void Function(int pid)  onJunkAdd;
  final void Function(int pid)  onJunkRemove;

  /// Spots capture add-on: an inline ⊖ N spots ⊕ control under each player
  /// name (like junk, but always shows the minus — spots can go negative).
  final bool                    spotsActive;
  final int  Function(int pid)  spotsCountFor;
  final void Function(int pid)  onSpotsAdd;
  final void Function(int pid)  onSpotsRemove;

  /// Long-press a player row to manage a mid-round withdrawal.  Null when
  /// the viewer can't manage the foursome (not TD / not the scorer).
  final void Function(Membership)?     onWithdrawTap;

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
    this.vegasSummary,
    this.fourballSummary,
    this.tripleCupSummary,
    this.points531Summary,
    this.matchPlayData,
    this.isCupSingles = false,
    this.hasThreePersonMatch = false,
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
    this.spotsActive   = false,
    this.spotsCountFor = _zeroSpots,
    this.onSpotsAdd    = _noopPid,
    this.onSpotsRemove = _noopPid,
    this.onWithdrawTap,
    this.phantomMembership,
    this.phantomInit,
    this.bottomRow,
  });

  /// Optional widget rendered as the last row INSIDE the card (e.g. the Irish
  /// Rumble borrowed-4th row).
  final Widget? bottomRow;

  int? get _lowPlayingHandicap {
    if (handicapMode != 'strokes_off' || players.isEmpty) return null;
    return players.map((m) => m.playingHandicap).reduce((a, b) => a < b ? a : b);
  }

  /// True when the phantom row should render on *hole*.
  ///
  ///   • Triple Cup 2v1 → only on the fourball segment, where the
  ///     phantom partners the solo.  Foursomes (alt-shot) and singles
  ///     don't use the phantom, so hiding the row prevents "Waiting
  ///     for Glenn…" from misleading users on holes 7-18.
  ///   • Non-TC phantoms (e.g. Points 5-3-1 intra-foursome rotation)
  ///     run on every hole, so we default to true when there's no TC
  ///     summary attached.
  bool _phantomBelongsOnHole(int hole) {
    final tc = tripleCupSummary;
    if (tc != null) {
      // Triple Cup 2v1: the phantom is the solo's fourball partner only;
      // hide the row on foursomes / singles segments.
      for (final m in tc.matches) {
        if (m.segment != 'fourball') continue;
        return hole >= m.startHole && hole <= m.endHole;
      }
      return false; // TC has no fourball match → no phantom anywhere
    }
    // Non-TC: the phantom membership exists structurally (every foursome
    // has 4 memberships) but only Points 5-3-1 actually rotates/displays
    // a phantom row.  For other active games (Match Play, Stroke Play,
    // Nassau, Skins, Sixes, etc.) the phantom is dead weight and the
    // "Copies X this hole" row just confuses the score entry.
    return points531Summary != null;
  }

  /// Per-hole name colour for [m] when a match-play single-elim bracket
  /// is active — returns the same green/blue convention the
  /// MatchPlayDetailView uses for player1 / player2 of the relevant
  /// match (semi on holes 1–9, final / 3rd on holes 10–18).  Falls back
  /// to the cup-singles / Triple Cup map (or null) so the legacy paths
  /// keep working untouched.
  // Calmed team red / slate (matches GolfTokens.teamRed / teamBlue and the
  // MatchPlayDetailView swatches).  Per the May 2026 design audit (D-04),
  // team identity uses the calmer palette so loud reds stay reserved for
  // errors and destructive actions.
  static final _kMatchPlayP1Color = GameColors.team1; // blue
  static final _kMatchPlayP2Color = GameColors.team2; // orange

  Color? _nameColorFor(Membership m, int hole) {
    // Match Play single-elim: per-match green/blue based on player1
    // vs player2 slot in the match covering [hole].
    final mp = matchPlayData;
    if (mp != null && mp['bracket_type'] == 'single_elim') {
      final matches = (mp['matches'] as List?) ?? [];
      final targetRound = hole <= 9 ? 1 : 2;
      for (final raw in matches) {
        final match = Map<String, dynamic>.from(raw as Map);
        if ((match['round'] as int? ?? 0) != targetRound) continue;
        if (targetRound == 2 && match['players_tbd'] == true) continue;
        if (match['player1_id'] == m.player.id) return _kMatchPlayP1Color;
        if (match['player2_id'] == m.player.id) return _kMatchPlayP2Color;
      }
    }
    // Casual Nassau (1-v-1 match or 2-v-2 best-ball): tint each side blue
    // (team 1) / red (team 2) so the names, the T1/T2 badges, AND the header
    // banner all share the same two team colours. Cup colours win when present.
    final cup = _cupSinglesColors[m.player.id];
    if (cup != null) return cup;
    final n = nassau;
    if (n != null) {
      if (n.team1.any((p) => p.playerId == m.player.id)) return GameColors.team1;
      if (n.team2.any((p) => p.playerId == m.player.id)) return GameColors.team2;
    }
    // Sixes: tint by the current segment's team (partners rotate every 6 holes),
    // so it's clear who's paired this segment — matching the Match grid colours.
    final sx = sixesSummary;
    if (sx != null) {
      final seg = _sixesSegmentForHole(sx, hole);
      if (seg != null) {
        if (seg.team1.playerIds.contains(m.player.id)) return GameColors.team1;
        if (seg.team2.playerIds.contains(m.player.id)) return GameColors.team2;
      }
    }
    // Las Vegas: fixed 2v2 teams → blue (team 1) / orange (team 2).
    final vg = vegasSummary;
    if (vg != null) {
      final t = vg.teamOf(m.player.id);
      if (t == 1) return GameColors.team1;
      if (t == 2) return GameColors.team2;
    }
    // Fourball: fixed 2v2 teams → blue (team 1) / orange (team 2).
    final fb = fourballSummary;
    if (fb != null) {
      final t = fb.teamOf(m.player.id);
      if (t == 1) return GameColors.team1;
      if (t == 2) return GameColors.team2;
    }
    return null;
  }

  /// The Sixes segment that owns [hole] — extras own overlapping holes, and a
  /// later (shifted) standard segment wins, mirroring the strokes logic.
  SixesSegment? _sixesSegmentForHole(SixesSummary sx, int hole) {
    for (final s in sx.segments) {
      if (s.isExtra && hole >= s.startHole && hole <= s.endHole) return s;
    }
    for (final s in sx.segments.where((s) => !s.isExtra).toList().reversed) {
      if (hole >= s.startHole && hole <= s.endHole) return s;
    }
    return null;
  }

  /// Returns a playerId → team color map for the active games that
  /// pin players to a side: cup singles brackets and Triple Cup.  Cup
  /// singles wins when both are active (legacy precedence).
  Map<int, Color> get _cupSinglesColors {
    final result = <int, Color>{};

    // Triple Cup: map every player to their team's accent colour.
    // In cup mode the summary carries the configured TournamentTeam
    // colour; in casual mode it falls back to red/blue.  Players
    // appear on every match they're in, but team assignment is
    // stable across matches so we take the first occurrence.
    if (tripleCupSummary != null) {
      final t1 = tripleCupSummary!.team1Color;
      final t2 = tripleCupSummary!.team2Color;
      for (final m in tripleCupSummary!.matches) {
        for (final p in m.players) {
          if (p.isPhantom) continue;
          result.putIfAbsent(
            p.playerId,
            () => p.teamNumber == 1 ? t1 : t2,
          );
        }
      }
    }

    // Cup singles brackets (existing behavior) — overrides Triple Cup
    // when both happen to apply, which they shouldn't in practice.
    final mp = matchPlayData;
    if (mp != null && mp['bracket_type'] == 'cup_singles') {
      Color tc(String? raw) {
        switch ((raw ?? '').toLowerCase().trim()) {
          case 'red':    return const Color(0xFFB71C1C);
          case 'blue':   return const Color(0xFF0D47A1);
          case 'green':  return const Color(0xFF1B5E20);
          case 'gold':
          case 'yellow': return const Color(0xFFF57F17);
          case 'orange': return const Color(0xFFE65100);
          case 'purple': return const Color(0xFF4A148C);
          default:       return const Color(0xFF455A64);
        }
      }
      final t1Color = tc(mp['team1_colour'] as String?);
      final t2Color = tc(mp['team2_colour'] as String?);
      for (final m in (mp['matches'] as List? ?? [])) {
        final mm  = Map<String, dynamic>.from(m as Map);
        final p1  = mm['player1_id'] as int?;
        final p2  = mm['player2_id'] as int?;
        if (p1 != null) result[p1] = t1Color;
        if (p2 != null) result[p2] = t2Color;
      }
    }

    return result;
  }

  /// The overall match-play handicap differential for [m] in cup singles:
  /// 0 if [m] is the lower handicap, (m.hcp - opponent.hcp) if higher.
  /// Used for the label next to the player name ("-0", "-3", etc.).
  int _cupSinglesHandicapFor(Membership m) {
    // Prefer exact per-match differential from loaded bracket data.
    final matches = (matchPlayData?['matches'] as List?) ?? [];
    for (final raw in matches) {
      final match = Map<String, dynamic>.from(raw as Map);
      final p1Id  = match['player1_id'] as int?;
      final p2Id  = match['player2_id'] as int?;
      int? opponentId;
      if (p1Id == m.player.id)      opponentId = p2Id;
      else if (p2Id == m.player.id) opponentId = p1Id;
      else continue;
      final opp = players.where((x) => x.player.id == opponentId).firstOrNull;
      if (opp == null) return 0;
      return (m.playingHandicap - opp.playingHandicap).clamp(0, 99);
    }
    // Fallback before matchPlayData loads: strokes off foursome low.
    if (players.isEmpty) return 0;
    final low = players.map((x) => x.playingHandicap).reduce((a, b) => a < b ? a : b);
    return (m.playingHandicap - low).clamp(0, 99);
  }

  /// Cup singles match-play handicap: lower of the two paired players gets 0
  /// strokes; higher gets (own_hcp - opponent_hcp) strokes allocated by SI.
  int _cupSinglesStrokesFor(Membership m, int si) {
    final matches = (matchPlayData?['matches'] as List?) ?? [];
    for (final raw in matches) {
      final match = Map<String, dynamic>.from(raw as Map);
      final p1Id  = match['player1_id'] as int?;
      final p2Id  = match['player2_id'] as int?;
      int? opponentId;
      if (p1Id == m.player.id)      opponentId = p2Id;
      else if (p2Id == m.player.id) opponentId = p1Id;
      else continue;
      final opp = players.where((x) => x.player.id == opponentId).firstOrNull;
      if (opp == null) return 0;
      final so = m.playingHandicap - opp.playingHandicap;
      if (so <= 0) return 0;
      return strokesOnHole(so, si);
    }
    return 0;
  }

  int _strokesForHole(Membership m, ScorecardHole? h) {
    if (h == null || handicapMode == 'gross') return 0;
    final entry = h.scoreFor(m.player.id);
    final mySi  = entry?.strokeIndex ?? h.strokeIndex;

    // Triple Cup: pull the exact segment-specific stroke count from
    // the summary the backend already computed (team-vs-team SO on
    // foursomes, per-pair SO on certain singles, Sixes-spread on
    // fourball, etc.).  Falls through to the legacy paths when the
    // current hole isn't in any TC match — keeps things safe before
    // the summary loads.
    if (tripleCupSummary != null) {
      final tcStrokes = _tripleCupExpectedStrokes(m.player.id, h.holeNumber);
      if (tcStrokes != null) return tcStrokes;
    }

    // Cup singles: match-play handicap (lower of the pair = 0, higher = diff).
    // isCupSingles is set from the games list so this fires even before
    // matchPlayData has loaded.  When matchPlayData is available we can compute
    // the exact per-match differential; otherwise fall back to strokes-off-low
    // across all four players (better than full net).
    if (isCupSingles) {
      if (matchPlayData?['bracket_type'] == 'cup_singles') {
        return _cupSinglesStrokesFor(m, mySi);
      }
      // Fallback: strokes off the lowest handicap in the foursome.
      final low = players.map((x) => x.playingHandicap).reduce((a, b) => a < b ? a : b);
      final so  = m.playingHandicap - low;
      return so > 0 ? strokesOnHole(so, mySi) : 0;
    }

    if (handicapMode == 'net') {
      if (netPercent == 100 && entry != null) return entry.handicapStrokes;
      final effective = (m.playingHandicap * netPercent / 100.0).round();
      return strokesOnHole(effective, mySi);
    }
    if (handicapMode == 'strokes_off') {
      // Match Play single-elim brackets compute SO vs the per-match
      // opponent rather than the foursome-wide low.  Returns null when
      // no opponent is known (back-9 tentative, etc.) — fall through to
      // the foursome-low fallback in that case.
      if (matchPlayData?['bracket_type'] == 'single_elim') {
        final mpStrokes =
            _matchPlayStrokesOnHole(m.player.id, h.holeNumber, mySi);
        if (mpStrokes != null) return mpStrokes;
      }
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
      return strokesOnHole(so, mySi);
    }
    return 0;
  }

  int _effectiveHcap(Membership m) => _effectiveHandicap(
        mode:                  handicapMode,
        netPercent:            netPercent,
        playingHandicap:       m.playingHandicap,
        lowestPlayingHandicap: _lowPlayingHandicap,
      );

  // ── Match Play (single_elim) per-opponent SO helpers ────────────────────
  // For regular match-play brackets in Strokes-Off-Low mode we show each
  // player's strokes relative to their actual head-to-head opponent — not
  // the foursome-wide low.  Round 1 (holes 1–9) uses the semi opponent;
  // round 2 (holes 10–18) uses the final / 3rd-place opponent once it's
  // confirmed.  Returns null when no opponent is known yet (back-9 still
  // tentative, no bracket, etc.) so callers can fall back to the previous
  // behaviour.

  int? _matchPlayOpponentHcap(int playerId, int hole) {
    final mpData = matchPlayData;
    if (mpData == null) return null;
    if (mpData['bracket_type'] != 'single_elim') return null;
    final matches     = (mpData['matches'] as List?) ?? [];
    final targetRound = hole <= 9 ? 1 : 2;
    for (final raw in matches) {
      final match = Map<String, dynamic>.from(raw as Map);
      if ((match['round'] as int? ?? 0) != targetRound) continue;
      // Skip back-9 matches whose players aren't confirmed yet — the
      // bubble would otherwise jump around as the semis play out.
      if (targetRound == 2 && match['players_tbd'] == true) continue;
      final p1Id = match['player1_id'] as int?;
      final p2Id = match['player2_id'] as int?;
      int? oppId;
      if (p1Id == playerId)      oppId = p2Id;
      else if (p2Id == playerId) oppId = p1Id;
      else continue;
      if (oppId == null) return null;
      final opp = players.where((x) => x.player.id == oppId).firstOrNull;
      return opp?.playingHandicap;
    }
    return null;
  }

  int? _matchPlaySo(int playerId, int hole) {
    final p = players.where((x) => x.player.id == playerId).firstOrNull;
    if (p == null) return null;
    final oppHcap = _matchPlayOpponentHcap(playerId, hole);
    if (oppHcap == null) return null;
    final diff = p.playingHandicap - oppHcap;
    return diff > 0 ? diff : 0;
  }

  int? _matchPlayStrokesOnHole(int playerId, int hole, int si) {
    final so = _matchPlaySo(playerId, hole);
    if (so == null) return null;
    if (so == 0) return 0;
    final scaled = (so * netPercent / 100.0).round();
    if (scaled <= 0) return 0;
    return strokesOnHole(scaled, si);
  }

  /// Expected handicap strokes for *playerId* on *hole* per the
  /// Triple Cup match that contains that hole.  Returns null when
  /// the hole is outside every match (caller falls back to the
  /// generic NET/SO calculation), or when the player isn't on a
  /// team for that match.  Bypasses local recomputation by reading
  /// the value the backend already produced in `match.players[*]
  /// .strokes_by_hole` — so the entry-screen dots agree with the
  /// leaderboard detail grid hole-for-hole.
  int? _tripleCupExpectedStrokes(int playerId, int hole) {
    final tc = tripleCupSummary;
    if (tc == null) return null;
    for (final m in tc.matches) {
      if (hole < m.startHole || hole > m.endHole) continue;
      final entry = m.players.firstWhere(
        (p) => p.playerId == playerId,
        orElse: () => const TripleCupMatchPlayer(
            playerId: -1, name: '', shortName: '', teamNumber: 0),
      );
      if (entry.playerId == -1) continue;
      return entry.strokesByHole[hole] ?? 0;
    }
    return null;
  }

  /// SO ("strokes off") value the BACKEND computed for *playerId* in
  /// the Triple Cup match containing *hole*.  Mirrors the per-match
  /// SO badge on the leaderboard — which already honors the 2v1
  /// fourball "phantom is scratch" rule (baseline 0) and the per-pair
  /// singles reset.  Returns null when the hole isn't inside any TC
  /// match (e.g. before the summary loads).  Callers use this to drive
  /// the player-row hcap badge so it matches the dots and the
  /// leaderboard hole-for-hole.
  int? _tripleCupSoForHole(int playerId, int hole) {
    final tc = tripleCupSummary;
    if (tc == null) return null;
    for (final m in tc.matches) {
      if (hole < m.startHole || hole > m.endHole) continue;
      final entry = m.players.firstWhere(
        (p) => p.playerId == playerId,
        orElse: () => const TripleCupMatchPlayer(
            playerId: -1, name: '', shortName: '', teamNumber: 0),
      );
      if (entry.playerId == -1) continue;
      return entry.soForHole(hole);   // per-hole SO (fourball donor), else per-match
    }
    return null;
  }

  /// Every TC match a player has on *hole* (one per match they're in).
  /// The 2v1 singles solo appears in TWO matches simultaneously — one
  /// vs each opponent on the team-of-2 — and his per-pair SO + per-
  /// hole strokes can differ between them.  The player-row hcap
  /// badge calls this so a solo who's -5 vs Glenn but -0 vs BobS
  /// shows BOTH badges side-by-side, not just whichever match the
  /// summary listed first.
  ///
  /// Returns an empty list when *playerId* isn't on any TC match at
  /// *hole*; falls back to the single-entry path naturally.
  List<({int? strokesOff, int strokesOnHole})>
      _tripleCupEntriesForHole(int playerId, int hole) {
    final tc = tripleCupSummary;
    if (tc == null) return const [];
    final out = <({int? strokesOff, int strokesOnHole})>[];
    for (final m in tc.matches) {
      if (hole < m.startHole || hole > m.endHole) continue;
      final entry = m.players.firstWhere(
        (p) => p.playerId == playerId,
        orElse: () => const TripleCupMatchPlayer(
            playerId: -1, name: '', shortName: '', teamNumber: 0),
      );
      if (entry.playerId == -1) continue;
      out.add((
        strokesOff:    entry.soForHole(hole),   // per-hole SO for fourball donor
        strokesOnHole: entry.strokesByHole[hole] ?? 0,
      ));
    }
    return out;
  }

  /// True when this player is on a Triple Cup foursomes (alt-shot)
  /// team for the current hole but it's the PARTNER's turn to play.
  /// False for the active player, for non-foursomes holes, for non-TC
  /// games, and when no first-tee player is set yet.
  bool _isInactiveAltShot(int playerId) {
    if (tripleCupSummary == null) return false;
    final hole = holeNumber;
    for (final m in tripleCupSummary!.matches) {
      if (m.segment != 'foursomes') continue;
      if (hole < m.startHole || hole > m.endHole) continue;
      final onTeam = m.players.firstWhere(
        (p) => p.playerId == playerId && !p.isPhantom,
        orElse: () => const TripleCupMatchPlayer(
            playerId: -1, name: '', shortName: '', teamNumber: 0),
      );
      if (onTeam.teamNumber == 0) return false;
      final active = m.activePlayerId(onTeam.teamNumber, hole);
      if (active == null) return false;
      return active != playerId;
    }
    return false;
  }

  String? _teamLabelFor(int playerId) {
    // Triple Cup: team_number 1 → Red (T1), 2 → Blue (T2).
    if (tripleCupSummary != null) {
      for (final m in tripleCupSummary!.matches) {
        for (final p in m.players) {
          if (p.playerId == playerId && !p.isPhantom) {
            return p.teamNumber == 1 ? 'T1' : 'T2';
          }
        }
      }
    }
    if (nassau == null) return null;
    // Nassau: no "T1"/"T2" text badge — team identity is the colour (the name
    // is tinted Blue/Orange via _nameColorFor and the row carries a matching
    // coloured left edge), so a letter badge would be redundant.
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
          // Hole header — Stack so the "?" legend button can sit top-right
          // without disturbing the centred Hole-N + Par/SI line.
          Stack(children: [
            Container(
              // width: infinity so the grey header fills the full card —
              // Stack doesn't propagate the parent Column's stretch.
              // Horizontal padding gives the centred Hole-N + meta line
              // breathing room so the "?" doesn't overlap the text.
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 10),
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
            // "?" legend — explains the row meta (handicap chip, dots,
            // tee, totals, game-specific badges).  Adaptive to the active
            // game(s) so we don't show irrelevant rows.
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                tooltip: 'What do these mean?',
                icon: Icon(
                  Icons.help_outline,
                  size: 22,
                  color: theme.colorScheme.primary,
                ),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => _ScoreEntryLegendSheet(
                    hasSkins:        skins != null,
                    hasNassau:       nassau != null,
                    hasSixes:        sixesSummary != null,
                    hasTripleCup:    tripleCupSummary != null,
                    hasPoints531:    points531Summary != null,
                    hasVegas:        vegasSummary != null,
                    // The 4-player bracket also feeds matchPlayData for cup
                    // singles; isCupSingles tells those apart.
                    hasMatchPlay:    matchPlayData != null && !isCupSingles,
                    hasThreePersonMatch: hasThreePersonMatch,
                    isEighteenHoleMatch: nassau?.isEighteenHoleMatch ?? false,
                    isCupSingles:    isCupSingles,
                    handicapMode:    handicapMode,
                  ),
                ),
              ),
            ),
          ]),

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
            final gross      = scores[m.player.id];
            final isHot      = idx == hotSpotIdx;
            final matchStrok = _strokesForHole(m, holeData);

            String? hcapLabel;
            if (isCupSingles) {
              // Singles: show the match-play differential (strokes the higher
              // player receives).  Hidden for the lower player (0 = gets none);
              // the stroke-this-hole indicator lives in the dot strip above.
              final so = _cupSinglesHandicapFor(m);
              if (so > 0) hcapLabel = 'gets $so';
            } else if (handicapMode == 'net' || handicapMode == 'strokes_off') {
              // Triple Cup: each match the player is on at this hole
              // gets its own "-N •" badge.  The 2v1 singles solo
              // appears in TWO matches at once (one per opponent on
              // the team-of-2) with different per-pair SO + per-hole
              // strokes; the first badge drives the score-box net
              // calc via matchStrok.  Other players only have one
              // entry — formats the same as the legacy single-badge
              // display.  Falls through to the generic mobile calc
              // when no TC summary is attached.
              final tcEntries = handicapMode == 'strokes_off'
                  ? _tripleCupEntriesForHole(m.player.id, holeNumber)
                  : const <({int? strokesOff, int strokesOnHole})>[];
              if (tcEntries.isNotEmpty) {
                // Dedupe identical entries.  In 2-player TC a single
                // hole shows up in two simultaneous matches (e.g. hole
                // 4 is in both F9 and Overall) — same pairing, same
                // per-pair SO — so rendering it twice ("gets 6 / gets
                // 6") is noise.  Only the genuine ghost-singles case in
                // 3-player TC (solo vs two opponents with different SOs)
                // produces distinct values worth showing side-by-side.
                // Zero-stroke entries are dropped (nothing given).
                final unique = <int>{};
                final labels = <String>[];
                for (final e in tcEntries) {
                  final so = e.strokesOff ?? 0;
                  if (so > 0 && unique.add(so)) labels.add('gets $so');
                }
                if (labels.isNotEmpty) hcapLabel = labels.join(' / ');
              } else {
                // Match Play single-elim brackets in SO mode: bubble shows
                // strokes vs the per-match opponent (semi opponent on
                // holes 1–9, final/3rd opponent on holes 10–18).  When
                // no opponent is known (back-9 still tentative) falls
                // back to _effectiveHcap which uses the foursome low.
                final mpSo = (handicapMode == 'strokes_off' &&
                              matchPlayData?['bracket_type'] == 'single_elim')
                    ? _matchPlaySo(m.player.id, holeNumber)
                    : null;
                final displayHcap = mpSo ?? _effectiveHcap(m);
                if (displayHcap > 0) hcapLabel = 'gets $displayHcap';
              }
            }

            final junkCount = allowJunk ? junkForPlayer(m.player.id) : 0;

            // Points 5-3-1: per-hole award and cumulative total.
            final p531Hole       = points531Summary != null
                ? _p531HolePoints()[m.player.id]
                : null;
            final p531Cumulative = points531Summary != null
                ? _p531CumulativeFor(m.player.id)
                : null;

            // Foursomes alt-shot: dim the partner whose turn it isn't.
            // Active is determined by hole parity from the team's
            // first-tee-off pick (server-supplied).
            final dimmed = _isInactiveAltShot(m.player.id);
            final withdrawn = m.isWithdrawnOnHole(holeNumber);
            return [
              GestureDetector(
                onLongPress: onWithdrawTap != null
                    ? () => onWithdrawTap!(m)
                    : null,
                child: _PlayerRow(
                member:              m,
                gross:               gross,
                isHot:               isHot,
                par:                 par,
                matchHcapLabel:      hcapLabel,
                strokesOnThisHole:   matchStrok,
                teamLabel:           _teamLabelFor(m.player.id),
                nameColor:           _nameColorFor(m, holeNumber),
                allowJunk:           allowJunk,
                junkCount:           junkCount,
                dimmed:              dimmed,
                deemphasized:        hotSpotIdx != -1 && !isHot,
                withdrawn:           withdrawn,
                p531HolePoints:      p531Hole,
                p531CumulativePoints: p531Cumulative,
                // Block taps while extra-match teams are unassigned, and for
                // withdrawn players on holes they're out for.
                onTap: (!withdrawn && gross != null && !isHot
                        && blockedExtraSeg == null)
                    ? () => onEditTap(m)
                    : null,
                onJunkAdd:    allowJunk ? () => onJunkAdd(m.player.id)    : null,
                onJunkRemove: allowJunk ? () => onJunkRemove(m.player.id) : null,
                spotsActive:  spotsActive,
                spotsCount:   spotsActive ? spotsCountFor(m.player.id) : 0,
                onSpotsAdd:   spotsActive ? () => onSpotsAdd(m.player.id)    : null,
                onSpotsRemove:spotsActive ? () => onSpotsRemove(m.player.id) : null,
                ),
              ),
              if (isHot)
                blockedExtraSeg == null
                  ? InlineScorePicker(
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

          // Phantom player row — read-only, shown at the bottom when
          // the foursome has a phantom player.  In 2v1 TC the phantom
          // is the solo's FOURBALL partner only; the foursomes (alt-
          // shot) and singles (ghost-singles) segments don't use it,
          // so hide the row on those holes — otherwise the user sees
          // "Waiting for Glenn…" on holes 7-18 where Glenn isn't
          // actually contributing.  For non-TC phantoms (Points 5-3-1
          // intra-foursome rotation), always show the row.
          if (phantomMembership != null
              && _phantomBelongsOnHole(holeNumber))
            Builder(builder: (_) {
              Color? phantomTeamColor;
              int?   phantomTeamNumber;
              if (tripleCupSummary != null) {
                final phantomPid = phantomMembership!.player.id;
                for (final m in tripleCupSummary!.matches) {
                  final onT1 = m.players.any(
                    (p) => p.playerId == phantomPid && p.teamNumber == 1,
                  );
                  final onT2 = m.players.any(
                    (p) => p.playerId == phantomPid && p.teamNumber == 2,
                  );
                  if (onT1) {
                    phantomTeamColor = tripleCupSummary!.team1Color;
                    phantomTeamNumber = 1;
                    break;
                  }
                  if (onT2) {
                    phantomTeamColor = tripleCupSummary!.team2Color;
                    phantomTeamNumber = 2;
                    break;
                  }
                }
              }
              return _PhantomPlayerRow(
                phantom:           phantomMembership!,
                holeNumber:        holeNumber,
                scores:            scores,
                phantomInit:       phantomInit,
                players:           players,
                tcPhantom:         tripleCupSummary?.phantom,
                phantomTeamColor:  phantomTeamColor,
                phantomTeamNumber: phantomTeamNumber,
                par:               par,
                donorStrokesThisHole:
                    _tripleCupExpectedStrokes(
                        phantomMembership!.player.id, holeNumber) ?? 0,
              );
            }),
          // Optional extra row inside the card (e.g. the Irish Rumble
          // borrowed-4th), so it reads as a 4th player, not a footer.
          if (bottomRow != null) bottomRow!,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Legend bottom sheet — opened by the "?" on the hole-card header.
// Adapts to the active games on this foursome so we only show rows that
// match what the user actually sees on screen.
// ---------------------------------------------------------------------------

class _ScoreEntryLegendSheet extends StatelessWidget {
  final bool   hasSkins;
  final bool   hasNassau;
  final bool   hasSixes;
  final bool   hasTripleCup;
  final bool   hasPoints531;
  final bool   hasVegas;
  /// 4-player single-elimination bracket (Mini Singles Bracket / match_play).
  final bool   hasMatchPlay;
  /// 3-player variant reached via the same pick (Three-Person Match).
  final bool   hasThreePersonMatch;
  /// True for the heads-up 18-Hole Match (Nassau Overall-only): the hole
  /// banner reads "Match: … wins hole" with no front/back/total split.
  final bool   isEighteenHoleMatch;
  final bool   isCupSingles;
  final String handicapMode; // 'net' | 'gross' | 'strokes_off'

  const _ScoreEntryLegendSheet({
    required this.hasSkins,
    required this.hasNassau,
    required this.hasSixes,
    required this.hasTripleCup,
    required this.hasPoints531,
    required this.hasVegas,
    required this.hasMatchPlay,
    required this.hasThreePersonMatch,
    required this.isEighteenHoleMatch,
    required this.isCupSingles,
    required this.handicapMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget row(Widget badge, String title, String body) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 56, child: Center(child: badge)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(body, style: theme.textTheme.bodySmall),
          ]),
        ),
      ]),
    );

    Widget pill(String text, {Color? bg, Color? fg}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: fg, fontWeight: FontWeight.w600)),
    );

    final showHcapChip = handicapMode != 'gross' || isCupSingles;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Score row guide', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Divider(height: 1),

            if (showHcapChip)
              row(
                pill('gets 16'),
                'Match handicap',
                isCupSingles
                  ? 'Strokes-off-low differential for this match (lower handicap plays scratch).'
                  : 'Handicap strokes this player receives in the current game (after Net % / Strokes-Off adjustments).',
              ),

            if (showHcapChip)
              row(
                const Text('• •', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                'Stroke dots',
                'Strokes received on THIS hole (one dot per stroke).',
              ),

            if (hasTripleCup)
              row(
                pill('White'),
                'Tee box',
                'Tee the player is using — drives par and stroke index.',
              ),

            row(
              const NetScoreButton(
                score: 3, par: 4, strokes: 0,
                selected: false, width: 30, height: 30,
              ),
              'Score notation guide',
              'Standard scorecard notation, net to par (or gross if Net-style '
                  'entry is off).  Under par is red — a circle for birdie, a '
                  'double circle for eagle or better.  Par is plain black.  Over '
                  'par is a square — bogey, or a double square for double bogey '
                  'or worse.',
            ),

            if (hasSkins) ...[
              const SizedBox(height: 4),
              const Divider(height: 1),
              const SizedBox(height: 4),
              Text('Skins', style: theme.textTheme.labelLarge),
              row(
                Icon(Icons.emoji_events, size: 22, color: scheme.primary),
                'Hole winner',
                'Trophy marks the player who took the skin.  Ties → carry over (when carryover is on).',
              ),
              row(
                pill('3', bg: scheme.primaryContainer, fg: scheme.onPrimaryContainer),
                'Skin total',
                'Cumulative skins won (regular + junk) — your running tally toward the payout.',
              ),
            ],

            if (hasNassau) ...[
              const SizedBox(height: 4),
              const Divider(height: 1),
              const SizedBox(height: 4),
              // The 18-Hole Match runs on Nassau (Overall bet only), so the
              // front/back/total framing doesn't apply — describe it as a match.
              Text(isEighteenHoleMatch ? 'Singles Match' : 'Nassau',
                  style: theme.textTheme.labelLarge),
              row(
                Icon(Icons.emoji_events, size: 22, color: scheme.primary),
                'Hole outcome banner',
                isEighteenHoleMatch
                    ? 'Colored strip under the hole names who won it (trophy) or '
                        'shows a halve.  A single 18-hole match — no front / back '
                        '/ total split.'
                    : 'Colored strip under the hole names the team that won it '
                        '(trophy) or shows a halve.  Front 9, back 9 and total '
                        'are tracked as separate bets.',
              ),
            ],

            if (hasSixes) ...[
              const SizedBox(height: 4),
              const Divider(height: 1),
              const SizedBox(height: 4),
              Text('Sixes', style: theme.textTheme.labelLarge),
              row(
                pill('M1', bg: scheme.primaryContainer, fg: scheme.onPrimaryContainer),
                'Match segment',
                'Six holes per segment.  Teams switch each segment (1-6, 7-12, 13-18).',
              ),
            ],

            if (hasPoints531) ...[
              const SizedBox(height: 4),
              const Divider(height: 1),
              const SizedBox(height: 4),
              Text('Points 5-3-1', style: theme.textTheme.labelLarge),
              row(
                pill('+5', bg: Colors.green.shade100, fg: Colors.green.shade900),
                'Hole points',
                'Best net = 5, second = 3, third = 1.  Ties split evenly.',
              ),
            ],

            if (hasTripleCup) ...[
              const SizedBox(height: 4),
              const Divider(height: 1),
              const SizedBox(height: 4),
              Text('Triple Cup', style: theme.textTheme.labelLarge),
              row(
                Icon(Icons.layers, size: 22, color: scheme.primary),
                'Segment format',
                'Fixed teams (T1 vs T2).  The format changes every 6 holes — '
                    'Fourball (best ball) 1–6, Foursomes (alt-shot) 7–12, '
                    'Singles 13–18.  Partners stay the same throughout.',
              ),
            ],

            if (hasVegas) ...[
              const SizedBox(height: 4),
              const Divider(height: 1),
              const SizedBox(height: 4),
              Text('Las Vegas', style: theme.textTheme.labelLarge),
              row(
                Icon(Icons.casino, size: 22, color: scheme.primary),
                'Team number',
                'Each team’s two net scores combine into a two-digit number '
                    '(low ball first — e.g. a 4 and a 5 make 45).  The gap '
                    'between the teams’ numbers is the points swing on the hole.',
              ),
            ],

            if (hasMatchPlay || hasThreePersonMatch) ...[
              const SizedBox(height: 4),
              const Divider(height: 1),
              const SizedBox(height: 4),
              Text('Mini Singles Bracket', style: theme.textTheme.labelLarge),
              // A 3-player group plays the Three-Person variant; only a true
              // 4-player group sees the front/back bracket text.
              if (hasMatchPlay && !hasThreePersonMatch)
                row(
                  Icon(Icons.account_tree, size: 22, color: scheme.primary),
                  'Bracket format',
                  'Two 9-hole semifinals on the front 9; the winners meet in the '
                      'final on the back 9, while the two losers play a 3rd–4th '
                      'place consolation match.',
                ),
              if (hasThreePersonMatch)
                row(
                  Icon(Icons.account_tree, size: 22, color: scheme.primary),
                  '3-player format',
                  'Three-Person Match — Points 5-3-1 over the front 9 seeds the '
                      'bracket, then the top two play a 1v1 match on the back 9.',
                ),
            ],
          ]),
        ),
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
  /// Cross-foursome phantom donor info from the TC summary.  Non-null
  /// in 2v1 TC fourball; null in 4-player TC and intra-foursome phantom
  /// modes (e.g. Points 5-3-1).
  final NassauPhantomInfo? tcPhantom;
  /// Solo's team color when the phantom is in a 2v1 TC foursome.  Used
  /// dimmed so the phantom reads as part of its team but still clearly
  /// "auto-scored, don't touch."  Null falls back to neutral ghost.
  final Color?            phantomTeamColor;
  /// The phantom's strokes on this hole (backend-computed, per-hole donor).
  /// Drives the "•" dots in the mirrored hcap bubble.
  final int               donorStrokesThisHole;
  /// Phantom's cup team number (1/2) — drives the "T1"/"T2" badge that
  /// replaces the person icon so the row matches the real players. Null
  /// for non-TC phantoms (keeps the neutral icon).
  final int?              phantomTeamNumber;
  /// Hole par — colors the score box by net-to-par (golf convention).
  final int?              par;

  const _PhantomPlayerRow({
    required this.phantom,
    required this.holeNumber,
    required this.scores,
    required this.players,
    this.phantomInit,
    this.tcPhantom,
    this.phantomTeamColor,
    this.donorStrokesThisHole = 0,
    this.phantomTeamNumber,
    this.par,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Dimmed team color when available (2v1 TC) — falls back to the
    // neutral ghost grey for intra-foursome phantoms / pre-config states.
    final neutralGhost = theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final tint         = phantomTeamColor != null
        ? Color.alphaBlend(
            phantomTeamColor!.withValues(alpha: 0.65),
            theme.colorScheme.surface,
          )
        : neutralGhost;

    // ── Cross-foursome (TC 2v1) phantom path ──────────────────────
    // Use donor info from the TC summary: the donor's name appears in
    // parens on the row title, and the per-hole score chip shows the
    // donor's NET (= phantom's stored gross after D1) or a "Waiting…"
    // placeholder when the donor hasn't yet posted that hole.
    if (tcPhantom != null) {
      final donor       = tcPhantom!.donorForHole(holeNumber);
      final donorName   = donor?.playerName ?? 'donor';   // full name in subtitle
      final donorSo     = tcPhantom!.soForHole(holeNumber);
      final hasScore    = donor?.hasScore ?? false;
      // Phantom's HoleScore.gross_score now carries the donor's raw GROSS
      // (the per-hole donor strokes-off is applied by the scoring layer), so
      // it displays like the other 3 players — gross digit + an SO badge.
      final phantomGross = scores[phantom.player.id];
      const title        = 'Phantom';
      final subtitle     = hasScore
          ? 'Gross from $donorName'
          : 'Waiting for $donorName…';

      return Container(
        decoration: BoxDecoration(
          // Team-color tint to match the real player rows (faint fill + a
          // 4px left edge in the team color).
          color: phantomTeamColor != null
              ? phantomTeamColor!.withValues(alpha: 0.07)
              : null,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
            left: phantomTeamColor != null
                ? BorderSide(color: phantomTeamColor!, width: 4)
                : BorderSide.none,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // Team badge (T1/T2) — matches the real player rows; falls back
            // to the neutral person icon for non-TC phantoms.
            if (phantomTeamNumber != null && phantomTeamColor != null) ...[
              Container(
                width: 28,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: phantomTeamColor!.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'T$phantomTeamNumber',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: phantomTeamColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ] else ...[
              Icon(Icons.person_outline, size: 18, color: tint),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(
                      title,   // "Phantom" — bold to match the player rows
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // The "-N •" hcap bubble sits next to "Phantom", mirroring
                    // the players' badge beside their short name.
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer
                            .withOpacity(0.6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: theme.colorScheme.outlineVariant),
                      ),
                      child: Text(
                        '-$donorSo'
                        '${donorStrokesThisHole > 0 ? ' ${'•' * donorStrokesThisHole}' : ''}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ]),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(color: tint),
                  ),
                ],
              ),
            ),
            if (phantomGross != null && hasScore)
              // Identical NetScoreButton to the real players so the phantom's
              // box matches its partner exactly — same size, golf colors
              // (red net-under-par), circle/square, no red fill.
              Stack(
                clipBehavior: Clip.none,
                children: [
                  NetScoreButton(
                    score:    phantomGross,
                    par:      par ?? 4,
                    strokes:  donorStrokesThisHole,
                    selected: false,
                    width:    40,
                    height:   36,
                  ),
                  if (donorStrokesThisHole > 0)
                    Positioned(
                      top: 2, right: 2,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(
                          donorStrokesThisHole.clamp(0, 2),
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
            else
              SizedBox(
                width: 40,
                height: 36,
                child: Center(
                  child: Text(
                    '…',
                    style: theme.textTheme.bodySmall?.copyWith(color: tint),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // ── Intra-foursome (Points 5-3-1 etc.) phantom path — unchanged ──
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
          Icon(Icons.person_outline, size: 18, color: neutralGhost),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  phantom.player.displayShort,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: neutralGhost,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(color: neutralGhost),
                ),
              ],
            ),
          ),
          if (sourceScore != null)
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: neutralGhost.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: neutralGhost.withValues(alpha: 0.3)),
              ),
              child: Text(
                '$sourceScore',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: neutralGhost,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: Text('—', style: theme.textTheme.bodySmall?.copyWith(color: neutralGhost)),
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
    final winner  = hole.winner!;
    final isMatch = nassau.isEighteenHoleMatch;
    final prefix  = isMatch ? 'Match' : 'Nassau';
    final Color bg;
    final Color fg;
    final String label;
    if (winner == 'halved') {
      bg    = Colors.grey.shade100;
      fg    = Colors.grey.shade700;
      // It's the HOLE that's halved, not the match/Nassau — say so plainly
      // (the win labels already read "… wins hole", so they stay clear).
      label = 'Hole: Halved';
    } else if (winner == 'team1') {
      bg    = GameColors.team1Bg;
      fg    = GameColors.team1;
      label = '$prefix: ${nassauWonByLabel(1, nassau.team1)} wins hole';
    } else {
      bg    = GameColors.team2Bg;
      fg    = GameColors.team2;
      label = '$prefix: ${nassauWonByLabel(2, nassau.team2)} wins hole';
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        // A halved hole is the term the app is named after — mark it with the
        // brand mark; a won hole keeps the trophy.
        if (winner == 'halved')
          const HalvedMark(size: 18, tooltip: 'Halved')
        else
          Icon(Icons.emoji_events, size: 14, color: fg),
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
  final int?          gross;
  final bool          isHot;
  final int           par;
  final String?       matchHcapLabel;
  final VoidCallback? onTap;
  final int           strokesOnThisHole;
  final String?       teamLabel;
  /// Override name color (e.g. cup singles team color). Ignored when isHot.
  final Color?        nameColor;
  final bool          allowJunk;
  final int           junkCount;
  final VoidCallback? onJunkAdd;
  final VoidCallback? onJunkRemove;
  final bool          spotsActive;
  final int           spotsCount;
  final VoidCallback? onSpotsAdd;
  final VoidCallback? onSpotsRemove;

  /// True for the dimmed partner in a Triple Cup foursomes (alt-shot)
  /// hole — only the active player tees off this hole, so their
  /// partner shouldn't be the score target.  Score selection disabled.
  final bool          dimmed;

  /// True when a different row is the active score target — this row is
  /// de-emphasised (dimmed, still tappable) so the active player stands out.
  final bool          deemphasized;

  /// True when this player has withdrawn ("can't continue") and is out
  /// for the hole being shown — render a WD badge and no score box.
  final bool          withdrawn;

  /// Points 5-3-1: points this player earned on the active hole (null = not yet scored).
  final double?       p531HolePoints;

  /// Points 5-3-1: cumulative points total for this player (null = not a P531 round).
  final double?       p531CumulativePoints;

  const _PlayerRow({
    required this.member,
    required this.gross,
    required this.isHot,
    required this.par,
    this.matchHcapLabel,
    this.onTap,
    this.strokesOnThisHole = 0,
    this.teamLabel,
    this.nameColor,
    this.allowJunk = false,
    this.junkCount = 0,
    this.onJunkAdd,
    this.onJunkRemove,
    this.spotsActive = false,
    this.spotsCount = 0,
    this.onSpotsAdd,
    this.onSpotsRemove,
    this.dimmed = false,
    this.deemphasized = false,
    this.withdrawn = false,
    this.p531HolePoints,
    this.p531CumulativePoints,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Team-coloured row (matches Wolf): a faint team tint + a 4px coloured
    // left edge whenever this player has a team colour (Sixes / Nassau / cup /
    // match play), so partners are obvious at a glance. The team tint stays on
    // even for the active row — the highlighted score box marks the input.
    final teamTint = nameColor;
    final body = Container(
      decoration: BoxDecoration(
        // Active row gets a clear green highlight (over any faint team tint) so
        // it's obvious whose score is up; the coloured left edge still marks
        // the team.
        color: isHot
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.28)
            : (teamTint != null
                ? teamTint.withValues(alpha: 0.07)
                : null),
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
          left: teamTint != null
              ? BorderSide(color: teamTint, width: 4)
              : BorderSide.none,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Team badge.  Uses [nameColor] (set from the active cup
        // colour map) when available so cup teams display in their
        // configured colour; falls back to the historic red/blue when
        // the row has no cup colour (casual games, etc.).
        if (teamLabel != null) ...[
          Builder(builder: (_) {
            final badgeFg = nameColor ??
                (teamLabel == 'T1'
                    ? Colors.red.shade700
                    : Colors.blue.shade700);
            // Pale version of the same colour for the chip background.
            final badgeBg = badgeFg.withValues(alpha: 0.15);
            return Container(
              width: 28,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                teamLabel!,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: badgeFg,
                ),
              ),
            );
          }),
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
                      // Bolder name on the active row so whose-score-is-up reads
                      // instantly; team colour is kept for identity.
                      fontWeight: isHot ? FontWeight.w800 : FontWeight.w600,
                      color: nameColor,
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
                // (Tee name intentionally not shown — matches the Pink Ball
                // screen and keeps the row compact.)
                if (withdrawn) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'WD',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onErrorContainer,
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
              // Spots: inline ⊖ N spots ⊕ (always shows the minus — negatives
              // allowed). Mutually exclusive with junk, so they never stack.
              if (spotsActive) ...[
                const SizedBox(height: 2),
                SpotsDots(
                  count:    spotsCount,
                  onAdd:    onSpotsAdd ?? () {},
                  onRemove: onSpotsRemove ?? () {},
                ),
              ],
            ],
          ),
        ),

        // Optional Points 5-3-1 pills
        if (p531CumulativePoints != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
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
          ),
        const SizedBox(width: 8),

        // Withdrawn players have no score box on holes they're out for —
        // just a muted "Out" marker.  Earlier holes still render normally
        // (they keep the gross they posted before withdrawing).
        if (withdrawn)
          Container(
            width: 40,
            height: 36,
            alignment: Alignment.center,
            child: Text('Out',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic)),
          )
        else
        // Score box — shows a NetScoreButton-style result once a score is
        // entered, or a plain highlighted border while the player is hot.
        GestureDetector(
          onTap: onTap,
          // Stroke dots sit in a strip BELOW the box (scoreCellWithDots) so the
          // bogey/double-bogey square never covers them.
          child: scoreCellWithDots(
            gross != null
                // Score entered: NetScoreButton for color + shape feedback.
                ? NetScoreButton(
                    score:    gross!,
                    par:      par,
                    strokes:  strokesOnThisHole,
                    selected: false,
                    width:    40,
                    height:   36,
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
            strokesOnThisHole,
            theme.colorScheme.primary,
          ),
        ),
      ]),
    );
    // Dim + disable interaction for the alt-shot partner whose turn it isn't.
    if (dimmed) {
      return Opacity(
        opacity: 0.40,
        child: IgnorePointer(ignoring: true, child: body),
      );
    }
    // De-emphasise the non-active rows (still tappable to edit their score) so
    // the active player is the one clear focal point.
    if (deemphasized) return Opacity(opacity: 0.55, child: body);
    return body;
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
// Score picker sheet (modal bottom sheet for editing a saved score)
// ---------------------------------------------------------------------------

class _ScorePickerSheet extends StatelessWidget {
  final String playerName;
  final int    par;
  final int    holeNumber;
  final int    strokes;
  final int?   current;
  /// Whether to offer "Clear score" — true only on the trailing hole (no-gaps).
  /// On an earlier hole the score is corrected by picking a new value instead.
  final bool   canClear;

  const _ScorePickerSheet({
    required this.playerName,
    required this.par,
    required this.holeNumber,
    required this.strokes,
    this.current,
    this.canClear = true,
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
          if (current != null && canClear)
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
  final MultiSkinsSummary?    multiSkins;
  final SixesSummary?         sixesSummary;
  final VegasSummary?         vegasSummary;
  final FourballSummary?      fourballSummary;
  final TripleCupSummary?     tripleCupSummary;
  final Points531Summary?     points531Summary;
  final Map<String, dynamic>?       matchPlayData;
  final ThreePersonMatchSummary?    threePersonMatchSummary;
  final int                         foursomeId;
  /// Needed for the per-game card chevrons that navigate to the
  /// leaderboard once the match is in progress.  Nullable so the section
  /// can render even before the round is loaded into RoundProvider.
  final int?                        roundId;
  final List<Membership>            players;
  final Scorecard                   scorecard;
  final int                         currentHole;
  final bool                        loadingNassau;
  final bool                        loadingSkins;
  final bool                        loadingMultiSkins;
  final bool                        loadingSixes;
  final bool                        loadingTripleCup;
  final bool                        loadingPoints531;
  final bool                        loadingVegas;
  final bool                        loadingMatchPlay;
  final bool                        loadingThreePersonMatch;
  final void Function(int hole)?    onTapHole;
  // Irish Rumble
  final List<Map<String, dynamic>>  irBallsConfig;
  final String                      irHandicapMode;
  // Stroke Play (low_net_round) — handicap settings from the game config
  // (not the round-level handicap_mode, which casual stroke play overrides).
  final String                      strokePlayHandicapMode;
  final int                         strokePlayNetPercent;
  // Stableford — authoritative per-hole + total points (config-aware).
  final Map<String, dynamic>?       stablefordResult;
  // The PRIMARY game. Side-game sections (skins/multi-skins/stroke-play/
  // stableford) render in entry ONLY when they are the primary; as side games
  // they live on the leaderboard, not here.
  final String?                     primaryGame;

  const _GameStatusSection({
    required this.games,
    required this.nassau,
    required this.skins,
    this.multiSkins,
    required this.sixesSummary,
    this.vegasSummary,
    this.fourballSummary,
    this.tripleCupSummary,
    this.points531Summary,
    required this.matchPlayData,
    this.threePersonMatchSummary,
    required this.foursomeId,
    this.roundId,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    required this.loadingNassau,
    required this.loadingSkins,
    this.loadingMultiSkins = false,
    this.loadingSixes      = false,
    this.loadingTripleCup  = false,
    required this.loadingPoints531,
    this.loadingVegas      = false,
    required this.loadingMatchPlay,
    this.loadingThreePersonMatch = false,
    required this.onTapHole,
    this.irBallsConfig   = const [],
    this.irHandicapMode  = 'net',
    this.strokePlayHandicapMode = 'net',
    this.strokePlayNetPercent   = 100,
    this.stablefordResult,
    this.primaryGame,
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

        // Skins standings — only when Skins is the primary (as a side game it
        // shows on the leaderboard, not during entry).
        if (primaryGame == 'skins') ...[
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

        // Multi-Group Skins standings (round-level pool across foursomes) —
        // only when it's the primary (a side game shows on the leaderboard).
        if (primaryGame == 'multi_skins') ...[
          if (multiSkins != null)
            _MultiSkinsStandingsCard(summary: multiSkins!)
          else if (loadingMultiSkins)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],

        // Sixes match grid
        if (games.contains('sixes')) ...[
          if (sixesSummary != null)
            _SixesMatchGrid(
              summary:     sixesSummary!,
              members:     players,
              currentHole: currentHole,
            )
          else if (loadingSixes)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],

        // Triple Cup (One Round Ryder Cup) match grid
        if (games.contains('triple_cup')) ...[
          if (tripleCupSummary != null)
            _TripleCupMatchGrid(
              summary:     tripleCupSummary!,
              currentHole: currentHole,
            )
          else if (loadingTripleCup)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
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

        // Las Vegas — team totals + per-hole numbers grid.
        if (games.contains('vegas')) ...[
          if (vegasSummary != null)
            _VegasStatusCard(
              summary:     vegasSummary!,
              currentHole: currentHole,
            )
          else if (loadingVegas)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const SizedBox(height: 12),
        ],

        // Fourball — match status card + per-hole progress grid.
        if (games.contains('fourball') && fourballSummary != null) ...[
          _FourballStatusCard(
            summary:     fourballSummary!,
            currentHole: currentHole,
          ),
          const SizedBox(height: 8),
          _FourballProgressGrid(
            summary:     fourballSummary!,
            players:     players,
            scorecard:   scorecard,
            currentHole: currentHole,
            onTapHole:   onTapHole,
          ),
          const SizedBox(height: 12),
        ],

        // Stroke Play — per-player net scores grid (no winner row).
        // Only when it's the primary (a side game shows on the leaderboard).
        if (primaryGame == 'low_net_round') ...[
          _StrokePlayProgressGrid(
            players:      players,
            scorecard:    scorecard,
            currentHole:  currentHole,
            onTapHole:    onTapHole,
            handicapMode: strokePlayHandicapMode,
            netPercent:   strokePlayNetPercent,
          ),
          const SizedBox(height: 12),
        ],

        // Stableford — per-player per-hole points grid + running total.
        // Only when it's the primary (a side game shows on the leaderboard).
        if (primaryGame == 'stableford' && stablefordResult != null) ...[
          _StablefordProgressGrid(
            players:     players,
            scorecard:   scorecard,
            result:      stablefordResult!,
            currentHole: currentHole,
            onTapHole:   onTapHole,
          ),
          const SizedBox(height: 12),
        ],

        // Match Play bracket status — only show when match_play or cup singles
        // is an active game for this foursome to prevent stale data bleeding
        // into other game types (e.g. Nassau / Four Ball foursomes).  Also
        // gated against:
        //   • 3-real-player foursomes (they play TPM, not a bracket — the
        //     card would show the bracket from a sibling 4-some via the
        //     round-shared matchPlayData).
        //   • cross-foursome payload (matchPlayData.foursome_id mismatch —
        //     leftover state from a previous tap-through).
        if ((games.contains('match_play') ||
             games.contains('singles_18') ||
             games.contains('singles_nassau')) &&
            players.where((m) => !m.player.isPhantom).length != 3 &&
            ((matchPlayData?['foursome_id'] == null) ||
             (matchPlayData?['foursome_id'] == foursomeId)) &&
            (matchPlayData != null || loadingMatchPlay)) ...[
          if (matchPlayData != null)
            matchPlayData!['bracket_type'] == 'cup_singles'
                ? _CupSinglesProgressGrid(
                    data:        matchPlayData!,
                    scorecard:   scorecard,
                    currentHole: currentHole,
                    onTapHole:   onTapHole,
                  )
                : _MatchPlayStatusCard(
                    data:       matchPlayData!,
                    foursomeId: foursomeId,
                    roundId:    roundId,
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
              roundId:    roundId,
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

        // Irish Rumble scorecard grid
        if (games.contains('irish_rumble') && irBallsConfig.isNotEmpty) ...[
          _IrishRumbleScorecardGrid(
            players:       players,
            scorecard:     scorecard,
            irBallsConfig: irBallsConfig,
            handicapMode:  irHandicapMode,
            currentHole:   currentHole,
            onTapHole:     onTapHole,
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Irish Rumble scorecard grid
// ---------------------------------------------------------------------------
//
// Full 18-hole grid: one row per player (net-to-par per hole) + a running
// team total row.  Cells that "count" toward the team score (i.e. the player
// is one of the best-N scorers on that hole) are filled with a tinted
// background.  N varies by hole segment per irBallsConfig.
//
// Holes 1-6:   1 counting row   (best 1)
// Holes 7-12:  2 counting rows  (best 2)
// Holes 13-17: 3 counting rows  (best 3)
// Hole 18:     4 counting rows  (all)

class _IrishRumbleScorecardGrid extends StatefulWidget {
  final List<Membership>            players;
  final Scorecard                   scorecard;
  final List<Map<String, dynamic>>  irBallsConfig;
  final String                      handicapMode;
  final int                         currentHole;
  final void Function(int)?         onTapHole;

  const _IrishRumbleScorecardGrid({
    required this.players,
    required this.scorecard,
    required this.irBallsConfig,
    required this.handicapMode,
    required this.currentHole,
    this.onTapHole,
  });

  @override
  State<_IrishRumbleScorecardGrid> createState() =>
      _IrishRumbleScorecardGridState();
}

class _IrishRumbleScorecardGridState
    extends State<_IrishRumbleScorecardGrid> {
  final ScrollController _scrollCtrl = ScrollController();

  static const double _labelColW = 60.0;
  static const double _cellW     = 34.0;
  static const double _rowH      = 28.0;
  static const double _totalRowH = 30.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToHole(widget.currentHole));
  }

  @override
  void didUpdateWidget(_IrishRumbleScorecardGrid old) {
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
    _scrollCtrl.animateTo(target,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// Returns balls-to-count for a given hole number.
  int _ballsForHole(int hole) {
    for (final seg in widget.irBallsConfig) {
      final start = seg['start_hole'] as int? ?? 0;
      final end   = seg['end_hole']   as int? ?? 0;
      if (hole >= start && hole <= end) {
        return seg['balls_to_count'] as int? ?? 1;
      }
    }
    return 1;
  }

  /// Net-to-par score for a player on a hole.
  /// Uses netScore for 'net' mode, grossScore otherwise, capped at +2.
  int? _netToPar(Membership m, int hole) {
    final entry = widget.scorecard.holeData(hole)?.scoreFor(m.player.id);
    if (entry == null) return null;
    final par = entry.par;
    final raw = widget.handicapMode == 'net'
        ? entry.netScore
        : entry.grossScore;
    if (raw == null) return null;
    final capped = raw.clamp(par - 10, par + 2); // double-bogey cap
    return capped - par;
  }

  /// Returns the set of player IDs whose scores count on a given hole.
  Set<int> _countingPlayerIds(int hole) {
    final n = _ballsForHole(hole);
    final scored = <({int playerId, int ntp})>[];
    for (final m in widget.players) {
      final ntp = _netToPar(m, hole);
      if (ntp != null) scored.add((playerId: m.player.id, ntp: ntp));
    }
    scored.sort((a, b) => a.ntp.compareTo(b.ntp)); // ascending = best first
    return scored.take(n).map((e) => e.playerId).toSet();
  }

  /// Running team total through all scored holes up to and including [maxHole].
  /// Returns null if no holes have been scored.
  int? _runningTotal(int maxHole) {
    int total = 0;
    bool any  = false;
    for (int h = 1; h <= maxHole; h++) {
      final n = _ballsForHole(h);
      final scored = <int>[];
      for (final m in widget.players) {
        final ntp = _netToPar(m, h);
        if (ntp != null) scored.add(ntp);
      }
      if (scored.isEmpty) continue;
      scored.sort();
      total += scored.take(n).fold(0, (s, v) => s + v);
      any    = true;
    }
    return any ? total : null;
  }

  String _fmtNtp(int ntp) {
    if (ntp == 0) return 'E';
    return ntp > 0 ? '+$ntp' : '$ntp';
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final players    = widget.players;
    final holeRange  = List.generate(18, (i) => i + 1);
    final accentBg   = theme.colorScheme.primaryContainer.withOpacity(0.35);
    final countBg    = theme.colorScheme.secondaryContainer.withOpacity(0.55);
    final currentBg  = theme.colorScheme.primaryContainer.withOpacity(0.35);

    Widget cell(int h, {required Widget child, Color? bg, bool isCurrent = false}) {
      return GestureDetector(
        onTap: widget.onTapHole == null ? null : () => widget.onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? (isCurrent ? accentBg : null),
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

    Widget totalCell(int h, {required Widget child, Color? bg}) {
      final isCurrent = h == widget.currentHole;
      return GestureDetector(
        onTap: widget.onTapHole == null ? null : () => widget.onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _cellW, height: _totalRowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? (isCurrent ? accentBg : null),
          ),
          child: child,
        ),
      );
    }

    // Pre-compute which player IDs count per hole (only if hole is scored).
    final countingIds = <int, Set<int>>{
      for (final h in holeRange) h: _countingPlayerIds(h),
    };

    // Pre-compute running team total per hole (cumulative through each hole).
    final runningTotals = <int, int?>{};
    int runAcc = 0;
    bool anyScored = false;
    for (final h in holeRange) {
      final n = _ballsForHole(h);
      final scored = <int>[];
      for (final m in players) {
        final ntp = _netToPar(m, h);
        if (ntp != null) scored.add(ntp);
      }
      if (scored.isEmpty) {
        runningTotals[h] = anyScored ? null : null;
        continue;
      }
      scored.sort();
      runAcc += scored.take(n).fold(0, (s, v) => s + v);
      anyScored = true;
      runningTotals[h] = runAcc;
    }

    // Segment boundary columns (first hole of each segment after the first).
    final segBoundaries = <int>{};
    for (int i = 1; i < widget.irBallsConfig.length; i++) {
      final start = widget.irBallsConfig[i]['start_hole'] as int? ?? 0;
      if (start > 1) segBoundaries.add(start);
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
            Text('Irish Rumble',
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
                  // Hole numbers row
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
                      cell(h,
                          isCurrent: h == widget.currentHole,
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
                      cell(h,
                          isCurrent: h == widget.currentHole,
                          child: Text(
                            '${widget.scorecard.holeData(h)?.par ?? "–"}',
                            style: theme.textTheme.bodySmall,
                          )),
                  ]),
                  // Balls-to-count row (shows "1" / "2" / "3" / "4" per segment)
                  Row(children: [
                    SizedBox(
                      width: _labelColW, height: _rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Count',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ),
                    ),
                    for (final h in holeRange) () {
                      final n = _ballsForHole(h);
                      final isFirst = segBoundaries.contains(h);
                      return Container(
                        width: _cellW, height: _rowH,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: isFirst
                              ? Border(
                                  left: BorderSide(
                                      color: theme.colorScheme.outlineVariant,
                                      width: 1.5))
                              : null,
                        ),
                        child: Text('$n',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold)),
                      );
                    }(),
                  ]),
                  // Thin divider
                  Container(
                    height: 1,
                    width: _labelColW + _cellW * holeRange.length,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // Player rows
                  for (final m in players) Builder(builder: (ctx) {
                    final name = m.player.displayShort.isNotEmpty
                        ? m.player.displayShort
                        : m.player.name;
                    return Row(children: [
                      SizedBox(
                        width: _labelColW, height: _rowH,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface)),
                        ),
                      ),
                      for (final h in holeRange) () {
                        final ntp      = _netToPar(m, h);
                        final counts   = countingIds[h]!.contains(m.player.id);
                        final isCurrent = h == widget.currentHole;
                        Color? bg;
                        if (ntp != null && counts) {
                          bg = countBg;
                        } else if (isCurrent) {
                          bg = currentBg;
                        }
                        Color textColor;
                        if (ntp == null) {
                          textColor = theme.colorScheme.onSurfaceVariant.withOpacity(0.4);
                        } else if (!counts) {
                          textColor = theme.colorScheme.onSurfaceVariant;
                        } else if (ntp < 0) {
                          textColor = underParColor; // golf: under par red
                        } else {
                          textColor = theme.colorScheme.onSurface;
                        }
                        return cell(h,
                            bg: bg,
                            isCurrent: isCurrent && ntp == null,
                            child: Text(
                              ntp != null ? _fmtNtp(ntp) : '·',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: counts
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: textColor),
                            ));
                      }(),
                    ]);
                  }),
                  // Thin divider before total
                  Container(
                    height: 1,
                    width: _labelColW + _cellW * holeRange.length,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // Running team total row
                  Row(children: [
                    SizedBox(
                      width: _labelColW, height: _totalRowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Total',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary)),
                      ),
                    ),
                    for (final h in holeRange) () {
                      final tot = runningTotals[h];
                      final isCurrent = h == widget.currentHole;
                      Color textColor;
                      if (tot == null) {
                        textColor = theme.colorScheme.onSurfaceVariant.withOpacity(0.4);
                      } else if (tot < 0) {
                        textColor = underParColor; // golf: under par red
                      } else {
                        textColor = theme.colorScheme.onSurface;
                      }
                      return totalCell(h,
                          bg: isCurrent
                              ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                              : null,
                          child: Text(
                            tot != null ? _fmtNtp(tot) : '·',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: textColor),
                          ));
                    }(),
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
      return strokesOnHole(effective, mySi);
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
      return strokesOnHole(so, mySi);
    }
    return 0;
  }

  String? _winnerForHole(int h) =>
      widget.nassau.holes.where((x) => x.hole == h).firstOrNull?.winner;

  int? _bottomDeltaForHole(int h) =>
      widget.nassau.holes.where((x) => x.hole == h).firstOrNull?.bottomDelta;

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
            Text(nassau.isEighteenHoleMatch ? 'Match Progress' : 'Nassau progress',
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
                          ? GameColors.team1
                          : nassau.team2.any((p) => p.playerId == m.player.id)
                              ? GameColors.team2
                              : null,
                    ),
                  // Top hole winner row
                  // Claremont: label "Top", show "1" (team colour) or "—".
                  // Standard:  label "Won by", show "T1"/"T2"/"=".
                  Row(children: [
                    SizedBox(
                      width: _labelColW, height: _rowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                            nassau.isClaremont ? 'Top' : 'Won by',
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
                        final String label;
                        bool nameStyle = false;
                        if (nassau.isClaremont) {
                          // Compact Claremont style: "1" coloured, "—" grey
                          if (winner == 'team1') {
                            bg = GameColors.team1Bg;
                            fg = GameColors.team1;
                            label = '1';
                          } else if (winner == 'team2') {
                            bg = GameColors.team2Bg;
                            fg = GameColors.team2;
                            label = '1';
                          } else if (winner == 'halved') {
                            fg = Colors.grey.shade500;
                            label = '—';
                          } else {
                            label = '·';
                          }
                        } else if (nassau.isEighteenHoleMatch) {
                          // 1-v-1: show the winner's colour-coded short name
                          // (≤5 chars — the colour is what catches the eye).
                          nameStyle = true;
                          String short(List<NassauPlayerInfo> t) {
                            final s = t.isNotEmpty
                                ? (t.first.shortName.isNotEmpty
                                    ? t.first.shortName : t.first.name)
                                : '';
                            return s.length > 5 ? s.substring(0, 5) : s;
                          }
                          if (winner == 'team1') {
                            bg = GameColors.team1Bg;
                            fg = GameColors.team1;
                            label = short(nassau.team1);
                          } else if (winner == 'team2') {
                            bg = GameColors.team2Bg;
                            fg = GameColors.team2;
                            label = short(nassau.team2);
                          } else if (winner == 'halved') {
                            bg = Colors.grey.shade100;
                            fg = Colors.grey.shade600;
                            label = '=';
                          } else {
                            label = '·';
                          }
                        } else {
                          // Standard style: team colour identifies the winner —
                          // "B"/"O" (Blue/Orange), matching setup + leaderboard.
                          if (winner == 'team1') {
                            bg = GameColors.team1Bg;
                            fg = GameColors.team1;
                            label = nassauTeamInitials(nassau.team1);
                          } else if (winner == 'team2') {
                            bg = GameColors.team2Bg;
                            fg = GameColors.team2;
                            label = nassauTeamInitials(nassau.team2);
                          } else if (winner == 'halved') {
                            bg = Colors.grey.shade100;
                            fg = Colors.grey.shade600;
                            label = '=';
                          } else {
                            label = '·';
                          }
                        }
                        return holeCell(h,
                            bg: bg,
                            child: Text(label,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.clip,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: nameStyle ? 9 : null,
                                  fontWeight: FontWeight.bold,
                                  color: fg ?? theme.colorScheme.onSurfaceVariant,
                                )));
                      }),
                  ]),

                  // Bottom hole points row — Claremont only
                  if (nassau.isClaremont)
                    Row(children: [
                      SizedBox(
                        width: _labelColW, height: _rowH,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('Bottom',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontStyle: FontStyle.italic)),
                        ),
                      ),
                      for (final h in holeRange)
                        Builder(builder: (_) {
                          final delta = _bottomDeltaForHole(h);
                          Color? bg;
                          Color? fg;
                          final String label;
                          if (delta == null) {
                            label = '·';
                          } else if (delta == 0) {
                            fg    = Colors.grey.shade500;
                            label = '—';
                          } else {
                            final pts = delta.abs();
                            if (delta > 0) {
                              bg = pts == 2
                                  ? GameColors.team1Bg
                                  : Colors.blue.shade50;
                              fg = GameColors.team1;
                            } else {
                              bg = pts == 2
                                  ? GameColors.team2Bg
                                  : Colors.red.shade50;
                              fg = Colors.red.shade700;
                            }
                            label = '$pts';
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
  /// Used by Nassau to tint names with their team color (blue / red).
  final Color?       nameColor;

  /// When true, colour each digit by net/gross vs par and add circle/square
  /// scorecard notation.  Off by default (e.g. Nassau keeps plain digits).
  final bool         scoreMarks;

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
    this.scoreMarks = false,
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
                  final hd = scorecard.holeData(h);
                  final gross = hd?.scoreFor(member.player.id)?.grossScore;
                  final baseStyle = theme.textTheme.bodySmall!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: gross == null
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  );
                  if (gross == null) return Text('–', style: baseStyle);
                  if (!scoreMarks) return Text('$gross', style: baseStyle);
                  // Colour + circle/square by net (or gross) vs par.  Strokes
                  // are 0 in gross mode, so this handles both settings.
                  final par = hd?.par;
                  final diff =
                      par == null ? null : (gross - strokesOnHole(h)) - par;
                  return scoreMark(
                      text: '$gross',
                      diff: diff,
                      baseStyle: baseStyle,
                      theme: theme);
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
// Fourball per-hole progress grid — modelled on _NassauProgressGrid.  Shows
// hole #, par, the four players (grouped + tinted by team), and a "Won by"
// row.  Unlike Nassau, the score that WON each hole — the winning team's
// best ball — is highlighted in that player's cell.
// ---------------------------------------------------------------------------

class _FourballProgressGrid extends StatefulWidget {
  final FourballSummary  summary;
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int hole)? onTapHole;

  const _FourballProgressGrid({
    required this.summary,
    required this.players,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
  });

  @override
  State<_FourballProgressGrid> createState() => _FourballProgressGridState();
}

class _FourballProgressGridState extends State<_FourballProgressGrid> {
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
  void didUpdateWidget(_FourballProgressGrid old) {
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
    _scrollCtrl.animateTo(target,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  // Strokes this player gets on hole [h] under the match's handicap mode —
  // mirrors services/fourball.py so the dots + nets match the calculator.
  int _strokesOnHoleFor(Membership m, int h) {
    final s = widget.summary;
    if (s.isGross) return 0;
    final hole  = widget.scorecard.holeData(h);
    if (hole == null) return 0;
    final entry = hole.scoreFor(m.player.id);
    final si    = entry?.strokeIndex ?? hole.strokeIndex;
    if (s.isNet) {
      if (s.netPercent == 100 && entry != null) return entry.handicapStrokes;
      final effective = (m.playingHandicap * s.netPercent / 100.0).round();
      return strokesOnHole(effective, si);
    }
    // strokes-off — anchored on the foursome low (full-round allocation).
    if (widget.players.isEmpty) return 0;
    final low = widget.players
        .map((p) => p.playingHandicap)
        .reduce((a, b) => a < b ? a : b);
    final rawSo = m.playingHandicap - low;
    if (rawSo <= 0) return 0;
    final so = (rawSo * s.netPercent / 100.0).round();
    if (so <= 0) return 0;
    return strokesOnHole(so, si);
  }

  FourballHole? _holeResult(int h) =>
      widget.summary.holes.where((x) => x.hole == h).firstOrNull;

  /// True when [m]'s score on hole [h] is the winning team's best ball —
  /// i.e. it's the score that actually won the hole.
  bool _isWinningCell(Membership m, int h) {
    final hr = _holeResult(h);
    if (hr == null || hr.winner == 'Halved') return false;
    final team = widget.summary.teamOf(m.player.id);
    if (team == null) return false;
    final winTeam = hr.winner == 'T1' ? 1 : 2;
    if (team != winTeam) return false;
    final winVal = winTeam == 1 ? hr.t1Net : hr.t2Net;
    final gross = widget.scorecard.holeData(h)?.scoreFor(m.player.id)?.grossScore;
    if (winVal == null || gross == null) return false;
    return gross - _strokesOnHoleFor(m, h) == winVal;
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final summary   = widget.summary;
    final scorecard = widget.scorecard;
    final current   = widget.currentHole;
    final onTapHole = widget.onTapHole;
    final holeRange = List.generate(18, (i) => i + 1);

    Color teamColor(int? t) => t == 1
        ? GameColors.team1
        : t == 2 ? GameColors.team2 : theme.colorScheme.onSurface;

    // Players ordered team 1 first, then team 2, so partners sit together.
    final ordered = [...widget.players]..sort((a, b) =>
        (summary.teamOf(a.player.id) ?? 9)
            .compareTo(summary.teamOf(b.player.id) ?? 9));

    Widget holeCell(int h, {required Widget child, Color? bg, bool? winBorder}) {
      final isCurrent = h == current;
      return GestureDetector(
        onTap: onTapHole == null ? null : () => onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? (isCurrent
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
                : null),
            border: isCurrent
                ? Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Fourball progress',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: _scrollCtrl,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Hole numbers
              Row(children: [
                SizedBox(width: _labelColW, height: _rowH,
                    child: const Align(alignment: Alignment.centerLeft,
                        child: Text('Hole',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)))),
                for (final h in holeRange)
                  holeCell(h, child: Text('$h',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold))),
              ]),
              // Par
              Row(children: [
                SizedBox(width: _labelColW, height: _rowH,
                    child: Align(alignment: Alignment.centerLeft,
                        child: Text('Par',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontStyle: FontStyle.italic)))),
                for (final h in holeRange)
                  holeCell(h, child: Text('${scorecard.holeData(h)?.par ?? "-"}',
                      style: theme.textTheme.bodySmall)),
              ]),
              Container(
                height: 1,
                width: _labelColW + _cellW * holeRange.length,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(vertical: 2),
              ),
              // Player score rows — names tinted by team; the winning best
              // ball each hole is highlighted in that player's cell.
              for (final m in ordered)
                Builder(builder: (_) {
                  final tNum  = summary.teamOf(m.player.id);
                  final tCol  = teamColor(tNum);
                  return Row(children: [
                    SizedBox(width: _labelColW, height: _rowH,
                        child: Align(alignment: Alignment.centerLeft,
                            child: Text(m.player.displayShort,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600, color: tCol)))),
                    for (final h in holeRange)
                      Builder(builder: (_) {
                        final hd    = scorecard.holeData(h);
                        final gross = hd?.scoreFor(m.player.id)?.grossScore;
                        final win   = _isWinningCell(m, h);
                        final strokes = _strokesOnHoleFor(m, h);
                        return holeCell(h,
                            bg: win
                                ? tCol.withValues(alpha: 0.18)
                                : null,
                            child: Stack(children: [
                              Center(child: Text(
                                  gross == null ? '–' : '$gross',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight:
                                          win ? FontWeight.w800 : FontWeight.w600,
                                      color: gross == null
                                          ? theme.colorScheme.onSurfaceVariant
                                          : win ? tCol : null))),
                              if (strokes > 0)
                                Positioned(top: 2, right: 2,
                                    child: Row(mainAxisSize: MainAxisSize.min,
                                        children: List.generate(
                                            strokes.clamp(0, 2),
                                            (i) => Container(
                                                width: 4, height: 4,
                                                margin: const EdgeInsets
                                                    .only(left: 1),
                                                decoration: BoxDecoration(
                                                    color: theme
                                                        .colorScheme.primary,
                                                    shape: BoxShape.circle))))),
                            ]));
                      }),
                  ]);
                }),
              Container(
                height: 1,
                width: _labelColW + _cellW * holeRange.length,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(vertical: 2),
              ),
              // Won by — T1 / T2 / = per hole.
              Row(children: [
                SizedBox(width: _labelColW, height: _rowH,
                    child: Align(alignment: Alignment.centerLeft,
                        child: Text('Won by',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic)))),
                for (final h in holeRange)
                  Builder(builder: (_) {
                    final hr = _holeResult(h);
                    Color? bg; Color? fg; String label;
                    if (hr == null) {
                      label = '·';
                    } else if (hr.winner == 'T1') {
                      bg = GameColors.team1Bg; fg = GameColors.team1; label = 'T1';
                    } else if (hr.winner == 'T2') {
                      bg = GameColors.team2Bg; fg = GameColors.team2; label = 'T2';
                    } else {
                      bg = Colors.grey.shade100; fg = Colors.grey.shade600;
                      label = '=';
                    }
                    return holeCell(h, bg: bg,
                        child: Text(label,
                            style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: fg ?? theme.colorScheme.onSurfaceVariant)));
                  }),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stroke Play (low_net_round) per-hole grid — modelled on _NassauProgressGrid
// but without team tinting or a winner row.  Shows hole #, par, then per-
// player gross scores with stroke-dot indicators in the corner so the user
// can see both the raw score and the strokes used to compute net.
// ---------------------------------------------------------------------------

class _StrokePlayProgressGrid extends StatefulWidget {
  final List<Membership> players;
  final Scorecard        scorecard;
  final int              currentHole;
  final void Function(int hole)? onTapHole;
  final String           handicapMode;   // 'net' | 'gross' | 'strokes_off'
  final int              netPercent;

  const _StrokePlayProgressGrid({
    required this.players,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
    required this.handicapMode,
    required this.netPercent,
  });

  @override
  State<_StrokePlayProgressGrid> createState() =>
      _StrokePlayProgressGridState();
}

class _StrokePlayProgressGridState extends State<_StrokePlayProgressGrid> {
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
  void didUpdateWidget(_StrokePlayProgressGrid old) {
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

  // Strokes this player gets on hole [h] under the active handicap mode —
  // mirrors the per-game logic so the dots match what the calculator used.
  int _strokesOnHoleFor(Membership m, int h) {
    if (widget.handicapMode == 'gross') return 0;

    final hole = widget.scorecard.holeData(h);
    if (hole == null) return 0;
    final entry = hole.scoreFor(m.player.id);
    final si    = entry?.strokeIndex ?? hole.strokeIndex;

    if (widget.handicapMode == 'net') {
      if (widget.netPercent == 100 && entry != null) {
        return entry.handicapStrokes;
      }
      final effective =
          (m.playingHandicap * widget.netPercent / 100.0).round();
      return strokesOnHole(effective, si);
    }
    // strokes_off — anchored on the foursome low.
    if (widget.players.isEmpty) return 0;
    final low = widget.players
        .map((p) => p.playingHandicap)
        .reduce((a, b) => a < b ? a : b);
    final rawSo = m.playingHandicap - low;
    if (rawSo <= 0) return 0;
    final so = (rawSo * widget.netPercent / 100.0).round();
    if (so <= 0) return 0;
    return strokesOnHole(so, si);
  }

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
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
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
                : null),
            border: isCurrent
                ? Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
                    width: 1.2)
                : null,
          ),
          child: child,
        ),
      );
    }

    String _modeLabel() {
      switch (widget.handicapMode) {
        case 'gross':       return 'Gross';
        case 'strokes_off': return 'SO ${widget.netPercent}%';
        default:            return 'Net ${widget.netPercent}%';
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
            Row(children: [
              Text('Stroke play progress',
                  style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
              const Spacer(),
              Text(_modeLabel(),
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
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
                  // Per-player gross scores with stroke-dot indicators.
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
                      scoreMarks:    true,
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

// ---------------------------------------------------------------------------
// Skins standings card
// ---------------------------------------------------------------------------

class _SkinsStandingsCard extends StatefulWidget {
  final SkinsSummary skins;
  final int          currentHole;

  const _SkinsStandingsCard({
    required this.skins,
    required this.currentHole,
  });

  @override
  State<_SkinsStandingsCard> createState() => _SkinsStandingsCardState();
}

class _SkinsStandingsCardState extends State<_SkinsStandingsCard> {
  final ScrollController _ctrl = ScrollController();
  static const double _stride = 36.0; // 32px cell + 4px gap

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _SkinsStandingsCard old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) _schedule();
  }

  void _schedule() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ctrl.hasClients) return;
        final target = ((widget.currentHole - 4) * _stride)
            .clamp(0.0, _ctrl.position.maxScrollExtent);
        _ctrl.animateTo(target,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skins       = widget.skins;        // aliases keep the body unchanged
    final currentHole = widget.currentHole;
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
                controller: _ctrl,
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
    // Full names across the header (short names like "PL"/"DP" are cryptic and
    // inconsistent); the row ellipsises if a 2-v-2 side runs long.
    String label(List<NassauPlayerInfo> team) => team
        .map((p) => p.name.isNotEmpty ? p.name : p.shortName)
        .join(' & ');
    final t1 = label(summary.team1);
    final t2 = label(summary.team2);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        // Blue (team 1) on the left — matches the team-1-first player rows + setup.
        nassauTeamDot(1),
        const SizedBox(width: 6),
        Expanded(
          child: Text(t1,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: GameColors.team1,
              ),
              overflow: TextOverflow.ellipsis),
        ),
        Text(' vs ',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        // Orange (team 2) on the right.
        Expanded(
          child: Text(t2,
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: GameColors.team2,
              ),
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 6),
        nassauTeamDot(2),
      ]),
    );
  }
}

/// Compact running-points band shown between the score-entry box and the
/// points table: each player's running total with the current hole's points
/// as a (+N) delta. Appears once a hole has been saved.
class _StablefordStrip extends StatelessWidget {
  final Map<String, dynamic> result;
  final int currentHole;
  const _StablefordStrip({required this.result, required this.currentHole});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final results = (result['results'] as List? ?? []);
    final key     = '$currentHole';
    final chips    = <Widget>[];
    for (final e in results) {
      final r       = e as Map<String, dynamic>;
      if ((r['holes_played'] as int? ?? 0) == 0) continue; // not started
      final total   = r['total_points'] ?? 0;               // running total
      final holes   = r['holes'] as Map<String, dynamic>?;
      final holePts = holes?[key];                           // this hole's pts
      final name    = (r['player_name']?.toString() ?? '').split(' ').first;
      final delta   = holePts == null
          ? ''
          : ' (${(holePts as num) >= 0 ? '+' : ''}$holePts)';
      chips.add(Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$name ',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          TextSpan(text: '$total',
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          TextSpan(text: delta, style: theme.textTheme.bodySmall),
        ])),
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
      child: Row(children: [
        Text('Stableford:',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 10),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: chips),
          ),
        ),
      ]),
    );
  }
}

/// Stableford per-hole points grid below the score card — modelled on
/// _StrokePlayProgressGrid. Each cell is the authoritative (config-aware)
/// points for that hole; the last column is the running total. Shows the
/// player rows with empty cells immediately, so it's visible before any score.
/// Horizontal scroll view that auto-scrolls so the current hole's column is
/// visible (positions it ~7 columns from the left) and re-scrolls when the
/// hole changes. Reused by the per-hole grids/strips under the score card so
/// you never have to scroll right to see the hole you just entered.
/// [leading] = fixed left label-column width, [stride] = per-hole column width.
class _AutoScrollHoleRow extends StatefulWidget {
  final int    currentHole;
  final double leading;
  final double stride;
  final Widget child;
  const _AutoScrollHoleRow({
    required this.currentHole,
    required this.leading,
    required this.stride,
    required this.child,
  });

  @override
  State<_AutoScrollHoleRow> createState() => _AutoScrollHoleRowState();
}

class _AutoScrollHoleRowState extends State<_AutoScrollHoleRow> {
  final ScrollController _ctrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _AutoScrollHoleRow old) {
    super.didUpdateWidget(old);
    if (old.currentHole != widget.currentHole) _schedule();
  }

  void _schedule() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ctrl.hasClients) return;
        final target =
            (widget.leading + (widget.currentHole - 7) * widget.stride)
                .clamp(0.0, _ctrl.position.maxScrollExtent);
        _ctrl.animateTo(target,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _ctrl,
        child: widget.child,
      );
}

class _StablefordProgressGrid extends StatelessWidget {
  final List<Membership>     players;
  final Scorecard            scorecard;
  final Map<String, dynamic> result;
  final int                  currentHole;
  final void Function(int hole)? onTapHole;

  const _StablefordProgressGrid({
    required this.players,
    required this.scorecard,
    required this.result,
    required this.currentHole,
    this.onTapHole,
  });

  static const double _labelColW = 60.0;
  static const double _cellW     = 28.0;
  static const double _rowH      = 26.0;
  static const double _totW      = 36.0;

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final holeRange = List.generate(18, (i) => i + 1);
    final byId = <int, Map<String, dynamic>>{
      for (final e in (result['results'] as List? ?? []))
        (e as Map<String, dynamic>)['player_id'] as int: e,
    };

    Widget holeCell(int h, {required Widget child}) {
      final isCurrent = h == currentHole;
      return GestureDetector(
        onTap: onTapHole == null ? null : () => onTapHole!(h),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _cellW, height: _rowH, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isCurrent
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
                : null,
            border: isCurrent
                ? Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
                    width: 1.2)
                : null,
          ),
          child: child,
        ),
      );
    }

    Widget labelCell(String s, {bool bold = false, bool italic = false}) =>
        SizedBox(
          width: _labelColW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(s,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                    fontStyle: italic ? FontStyle.italic : FontStyle.normal)),
          ),
        );

    Widget totCell(Widget child) =>
        SizedBox(width: _totW, height: _rowH, child: Center(child: child));

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
            Text('Stableford points',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            _AutoScrollHoleRow(
              currentHole: currentHole,
              leading: _labelColW,
              stride: _cellW,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hole numbers + Total
                  Row(children: [
                    labelCell('Hole', bold: true),
                    for (final h in holeRange)
                      holeCell(h,
                          child: Text('$h',
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold))),
                    totCell(const Text('Tot',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold))),
                  ]),
                  // Par
                  Row(children: [
                    labelCell('Par', italic: true),
                    for (final h in holeRange)
                      holeCell(h,
                          child: Text('${scorecard.holeData(h)?.par ?? "-"}',
                              style: theme.textTheme.bodySmall)),
                    totCell(const SizedBox.shrink()),
                  ]),
                  Container(
                    height: 1,
                    width: _labelColW + _cellW * holeRange.length + _totW,
                    color: theme.colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                  // Per-player points
                  for (final m in players)
                    () {
                      final r     = byId[m.player.id];
                      final holes = (r?['holes'] as Map<String, dynamic>?) ?? {};
                      final total = r?['total_points'] ?? 0;
                      return Row(children: [
                        labelCell(m.player.shortName.isNotEmpty
                            ? m.player.shortName
                            : m.player.name.split(' ').first),
                        for (final h in holeRange)
                          holeCell(h,
                              child: Text(
                                  holes['$h'] == null ? '' : '${holes['$h']}',
                                  style: theme.textTheme.bodySmall)),
                        totCell(Text('$total',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold))),
                      ]);
                    }(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PressesStrip extends StatelessWidget {
  final List<NassauPressResult> presses;
  final List<NassauPressResult> bottomPresses;
  final int currentHole;
  const _PressesStrip({
    required this.presses,
    this.bottomPresses = const [],
    required this.currentHole,
  });

  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final currentNine = currentHole <= 9 ? 'front' : 'back';

    // Combine top + bottom, tag each with isBottom flag.
    final allTagged = [
      for (final p in presses)       (press: p, isBottom: false),
      for (final p in bottomPresses) (press: p, isBottom: true),
    ];
    final visible = allTagged
        .where((t) => t.press.nine == currentNine)
        .toList();
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
          final p        = visible[i].press;
          final isBottom = visible[i].isBottom;
          // Sequential press number within this nine (and top/bottom group),
          // labelled by nine — e.g. "F9 Press 1"; Claremont bottom presses get
          // a "Bot" tag: "F9 Bot Press 1".
          int pressNo = 1;
          for (int k = 0; k < i; k++) {
            if (visible[k].isBottom == isBottom) pressNo++;
          }
          final ninePrefix = currentNine == 'front' ? 'F9' : 'B9';
          final label      = '$ninePrefix ${isBottom ? 'Bot ' : ''}Press $pressNo';
          final result   = p.result;
          final m        = p.margin ?? 0;
          final mAbs     = m.abs();
          Color  chipColor;
          String scoreText;

          if (result == 'team1') {
            chipColor = GameColors.team1Bg;
            scoreText = isBottom
                ? '+$mAbs pts'
                : (p.holesRemaining > 0 ? '$mAbs&${p.holesRemaining}' : '${mAbs}UP');
          } else if (result == 'team2') {
            chipColor = GameColors.team2Bg;
            scoreText = isBottom
                ? '+$mAbs pts'
                : (p.holesRemaining > 0 ? '$mAbs&${p.holesRemaining}' : '${mAbs}UP');
          } else if (result == 'halved') {
            chipColor = Colors.grey.shade200;
            scoreText = 'AS';
          } else {
            // Active / in-progress — show range only.
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
    final theme       = Theme.of(context);
    final isClaremont = summary.isClaremont;
    final hasBottom   = isClaremont &&
        summary.bottomFront9  != null &&
        summary.bottomBack9   != null &&
        summary.bottomOverall != null;

    // Label style for the "Top" / "Bot" row prefixes.
    final rowLabelStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.onSurfaceVariant,
    );

    Widget betRow(String? rowLabel, List<Widget> chips) => Row(children: [
      if (rowLabel != null)
        SizedBox(
          width: 32,
          child: Text(rowLabel, style: rowLabelStyle),
        ),
      Expanded(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: chips,
        ),
      ),
    ]);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Top bet row — labelled "Top" only when Claremont is active.
        // An 18-hole match has a single bet: show one "Match" chip.
        betRow(
          hasBottom ? 'Top' : null,
          summary.isEighteenHoleMatch
              ? [_betChip(context, 'Match', summary.overall, isNine: false)]
              : [
                  _betChip(context, 'F9',  summary.front9,  isNine: true),
                  _betChip(context, 'B9',  summary.back9,   isNine: true),
                  _betChip(context, 'ALL', summary.overall, isNine: false),
                ],
        ),
        // Bottom bet row (Claremont only).
        if (hasBottom) ...[
          const SizedBox(height: 4),
          betRow(
            'Bot',
            [
              _bottomChip(context, 'F9',  summary.bottomFront9!),
              _bottomChip(context, 'B9',  summary.bottomBack9!),
              _bottomChip(context, 'ALL', summary.bottomOverall!),
            ],
          ),
        ],
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

  Widget _betChip(BuildContext context, String label, NassauBetResult bet,
      {required bool isNine}) {
    final theme    = Theme.of(context);
    final result   = bet.result;
    final nineLen  = isNine ? 9 : 18;
    final holesLeft = nineLen - bet.holesPlayed;
    final t1Leads  = bet.margin > 0;
    // Team colours used both for the chip fill and the subtitle text,
    // so a glance tells you who's ahead in F9/B9/ALL.
    final t1Color = GameColors.team1;
    final t2Color = GameColors.team2;
    Color  bg;
    String subtitle;
    Color? subtitleColor;

    if (result != null) {
      if (result == 'halved') {
        bg       = Colors.grey.shade200;
        subtitle = 'AS';
      } else {
        final winsT1 = result == 'team1';
        bg            = winsT1 ? GameColors.team1Bg : GameColors.team2Bg;
        subtitleColor = winsT1 ? t1Color : t2Color;
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
      bg            = t1Leads ? GameColors.team1Bg : GameColors.team2Bg;
      subtitleColor = t1Leads ? t1Color : t2Color;
      subtitle      = '${bet.margin.abs()}&$holesLeft';
    } else {
      bg            = t1Leads ? GameColors.team1Bg : GameColors.team2Bg;
      subtitleColor = t1Leads ? t1Color : t2Color;
      subtitle      = '${bet.margin.abs()}UP';
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
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: subtitleColor,
            )),
      ]),
    );
  }

  /// Compact chip for Claremont bottom bets (points margin, +N / AS / —).
  Widget _bottomChip(
    BuildContext context,
    String label,
    NassauBottomBetResult bet,
  ) {
    final theme  = Theme.of(context);
    final result = bet.result;
    final t1Color = GameColors.team1;
    final t2Color = GameColors.team2;
    Color  bg;
    String subtitle;
    Color? subtitleColor;

    if (result != null) {
      if (result == 'halved') {
        bg       = Colors.grey.shade200;
        subtitle = 'AS';
      } else {
        final winsT1 = result == 'team1';
        bg            = winsT1 ? GameColors.team1Bg : GameColors.team2Bg;
        subtitleColor = winsT1 ? t1Color : t2Color;
        subtitle      = 'wins';
      }
    } else if (bet.holesPlayed == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = '—';
    } else if (bet.margin == 0) {
      bg       = theme.colorScheme.surfaceContainer;
      subtitle = 'AS';
    } else {
      final t1Leads = bet.margin > 0;
      bg            = t1Leads ? GameColors.team1Bg : GameColors.team2Bg;
      subtitleColor = t1Leads ? t1Color : t2Color;
      subtitle      = t1Leads ? '+${bet.margin}' : '${bet.margin}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: subtitleColor,
            )),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Match Play running-total bottom bar
// ---------------------------------------------------------------------------
//
// Shows one compact chip per match (Semi 1, Semi 2, Final, 3rd Place) in
// a strip identical in feel to the Nassau F9/B9/ALL chip row.
//
// Data shape mirrors match_play_screen.dart / _MatchPlayStatusCard:
//   data['matches'] → List of match maps with keys:
//     round, player1, player2, label, status, result,
//     winner_name, finished_hole, tie_break, holes, players_tbd

class _MatchPlayStatusBar extends StatelessWidget {
  final Map<String, dynamic> data;
  const _MatchPlayStatusBar({required this.data});

  // Short label: "Semi 1" → "S1", "Final" → "F", "3rd Place" → "3rd"
  String _shortLabel(String label) {
    if (label.startsWith('Semi')) {
      final num = label.replaceAll(RegExp(r'[^0-9]'), '');
      return 'S$num';
    }
    if (label.toLowerCase().contains('final')) return 'F';
    if (label.toLowerCase().contains('3rd'))   return '3rd';
    return label.length <= 4 ? label : label.substring(0, 4);
  }

  /// Running score line for one match — mirrors _matchSummary in the body card,
  /// but truncated to fit inside a narrow chip.  Uses short names so each chip
  /// stays compact even when player names are long.
  String _chipBody(Map<String, dynamic> match) {
    final status      = match['status']      as String;
    final result      = match['result']      as String?;
    final holes       = match['holes']       as List? ?? [];
    final p1          = (match['player1_short'] ?? match['player1']) as String? ?? '?';
    final p2          = (match['player2_short'] ?? match['player2']) as String? ?? '?';
    final winnerShort = (match['winner_short'] ?? match['winner_name']) as String?;
    final finishedOn  = match['finished_hole'] as int?;
    final tieBreak    = match['tie_break']   as String?;
    final round       = match['round']       as int;
    final playersTbd  = match['players_tbd'] as bool? ?? false;

    if (playersTbd) return '—';

    if (status == 'complete') {
      if (result == 'halved') return 'AS';
      if (winnerShort == null) return 'done';
      if (tieBreak == 'sudden_death')  return '$winnerShort (SD)';
      if (finishedOn != null) {
        final scheduledEnd = round == 1 ? 9 : 18;
        final remaining    = scheduledEnd - finishedOn;
        if (remaining > 0) {
          final h    = holes.cast<Map<String, dynamic>>().firstWhere(
            (h) => h['hole'] == finishedOn, orElse: () => <String, dynamic>{});
          final margin = ((h['margin'] as int?) ?? 0).abs();
          return '$winnerShort ${margin}&$remaining';
        }
      }
      return winnerShort;
    }

    if (holes.isEmpty) return status == 'pending' ? '—' : '…';

    final last    = holes.last as Map<String, dynamic>;
    final holeNum = last['hole']   as int? ?? 0;
    final margin  = last['margin'] as int? ?? 0;

    // Sudden death in progress (round-1 semi beyond hole 9)
    if (round == 1 && holeNum > 9) {
      if (margin == 0) return 'AS SD';
      final leader = margin > 0 ? p1 : p2;
      return '$leader SD';
    }

    if (margin == 0) return 'AS';
    final leader = margin > 0 ? p1 : p2;
    return '$leader ${margin.abs()}Up';
  }

  // Light tints of the player1 (blue) / player2 (orange) name colours, so a
  // "Paul 1Up" chip reads in the same colour as Paul's name in the
  // score-entry row above (GameColors.team1 / team2).

  Color _chipBg(Map<String, dynamic> match, ThemeData theme) {
    final status   = match['status'] as String;
    final result   = match['result'] as String?;
    final holes    = match['holes']  as List? ?? [];
    final round    = match['round']  as int;

    if (status == 'complete') {
      if (result == 'halved') return Colors.grey.shade200;
      // Winner-tinted to match the player's name colour in the score-entry row.
      if (result == 'player1') return GameColors.team1Bg;
      if (result == 'player2') return GameColors.team2Bg;
      return Colors.grey.shade200;
    }
    if (holes.isEmpty) return theme.colorScheme.surfaceContainer;

    final last   = holes.last as Map<String, dynamic>;
    final holeNum = last['hole']   as int? ?? 0;
    final margin  = last['margin'] as int? ?? 0;

    if (round == 1 && holeNum > 9) return Colors.amber.shade100; // sudden death
    if (margin == 0)  return theme.colorScheme.surfaceContainer;
    return margin > 0 ? GameColors.team1Bg : GameColors.team2Bg;
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final matches = (data['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

    if (matches.isEmpty) return const SizedBox.shrink();

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Row(
        children: [
          // "MP" prefix label, like "Top" / "Bot" in the Nassau bar
          Text('MP',
              style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: matches.map((m) {
                final rawLabel  = m['label'] as String? ?? 'M${m['round']}';
                final chipLabel = _shortLabel(rawLabel);
                final body      = _chipBody(m);
                final bg        = _chipBg(m, theme);

                return Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(chipLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(body,
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center),
                    ]),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sixes match grid (ported from sixes_screen.dart _MatchGrid / _SegmentCard)
// ---------------------------------------------------------------------------
// Multi-Group Skins standings card — compact round-level pool snapshot for
// the score-entry screen.  Shows pool, Thru, skins, payout per participant
// and the per-hole winner strip ("—" = dead skin).  Tapping the title bar
// navigates to the full /multi-skins screen.
// ---------------------------------------------------------------------------

class _MultiSkinsStandingsCard extends StatelessWidget {
  final MultiSkinsSummary summary;
  const _MultiSkinsStandingsCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.attach_money, size: 18),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Multi-Group Skins — '
                '\$${summary.pool.toStringAsFixed(2)} pool, '
                '${summary.totalSkins} skin(s) won',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          // Standings table (Thru / Skins / Payout)
          Table(
            columnWidths: const {
              0: FlexColumnWidth(),
              1: FixedColumnWidth(36),
              2: FixedColumnWidth(40),
              3: FixedColumnWidth(56),
            },
            children: [
              TableRow(children: [
                Text('Player',
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold)),
                Text('Thru', textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold)),
                Text('Skins', textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold)),
                Text('Payout', textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold)),
              ]),
              for (final p in summary.players)
                TableRow(children: [
                  Text(p.shortName.isNotEmpty ? p.shortName : p.name,
                      style: theme.textTheme.bodySmall),
                  Text(p.thru == 0 ? '—' : '${p.thru}',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall),
                  Text('${p.skinsWon}',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall),
                  Text('\$${p.payout.toStringAsFixed(2)}',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall),
                ]),
            ],
          ),
        ]),
      ),
    );
  }
}

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
          // Colour by the actual Django team so it matches the hole rows.
          final topColor    = p1InTeam2 ? GameColors.team2 : GameColors.team1;
          final bottomColor = p1InTeam2 ? GameColors.team1 : GameColors.team2;
          return _SixesSegmentCard(
            matchNumber:  matchNum,
            segment:      seg,
            team1Label:   _teamLabel(topTeam),
            team2Label:   _teamLabel(bottomTeam),
            team1Color:   topColor,
            team2Color:   bottomColor,
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
  final Color?        team1Color;
  final Color?        team2Color;
  final bool          teamsSwapped;
  final int           currentHole;

  const _SixesSegmentCard({
    required this.matchNumber,
    required this.segment,
    required this.team1Label,
    required this.team2Label,
    this.team1Color,
    this.team2Color,
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
                    color: team1Color,
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
                    color: team2Color,
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
// Triple Cup (One Round Ryder Cup) match grid — mirrors _SixesMatchGrid
// ---------------------------------------------------------------------------

class _TripleCupMatchGrid extends StatelessWidget {
  final TripleCupSummary summary;
  final int              currentHole;

  const _TripleCupMatchGrid({
    required this.summary,
    required this.currentHole,
  });

  @override
  Widget build(BuildContext context) {
    final matches = summary.matches;
    if (matches.isEmpty) return const SizedBox.shrink();
    final t1Color = summary.team1Color;
    final t2Color = summary.team2Color;

    // Progressive reveal — same pattern as Sixes: the next match shows
    // only once the previous one is done.  Singles 1 and Singles 2
    // share holes 13–18 so they reveal together.
    //
    // 2-player TC is a Nassau (F9 + B9 + Overall) where Overall spans
    // 1-18 and is genuinely "live" from hole 1.  Skip the reveal
    // gating in that case — show all three cards from the start so
    // the user can track Overall progress alongside F9 / B9.
    final List<TripleCupMatch> visible;
    if (summary.groupSize == 2) {
      visible = List<TripleCupMatch>.from(matches);
    } else {
      visible = <TripleCupMatch>[];
      for (var i = 0; i < matches.length; i++) {
        final m = matches[i];
        visible.add(m);
        final done = m.status == 'complete' || m.status == 'halved';
        // If this match isn't done AND the next match doesn't share
        // the same hole range, stop revealing — wait for the current
        // one to finish.
        if (!done) {
          final shareNext = i + 1 < matches.length &&
              matches[i + 1].startHole == m.startHole &&
              matches[i + 1].endHole   == m.endHole;
          if (!shareNext) break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(children: [
            Text('Cup ',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary)),
            Text(_fmt(summary.team1Points),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: t1Color)),
            Text(' – ',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(_fmt(summary.team2Points),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: t2Color)),
            Text(' of ${summary.pointsAvailable}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: visible.map((m) {
              final isCurrent = currentHole >= m.startHole &&
                  currentHole <= m.endHole;
              return _TripleCupMatchCard(
                match:     m,
                isCurrent: isCurrent,
                t1Color:   t1Color,
                t2Color:   t2Color,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  static String _fmt(double p) =>
      p == p.truncateToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(1);
}

class _TripleCupMatchCard extends StatelessWidget {
  final TripleCupMatch match;
  final bool   isCurrent;
  final Color  t1Color;
  final Color  t2Color;

  const _TripleCupMatchCard({
    required this.match,
    required this.isCurrent,
    required this.t1Color,
    required this.t2Color,
  });

  Color _statusColor(BuildContext ctx) {
    switch (match.result) {
      case 'team1':  return t1Color;
      case 'team2':  return t2Color;
      case 'halved': return Colors.grey.shade700;
    }
    // In progress: tint by current leader so "1 UP thru 3" reads in
    // the leading team's color.  AS thru N stays neutral.
    if (match.status == 'in_progress') {
      final margin = match.holes.isNotEmpty ? match.holes.last.margin : 0;
      if (margin > 0) return t1Color;
      if (margin < 0) return t2Color;
      return Theme.of(ctx).colorScheme.onSurfaceVariant;
    }
    return Theme.of(ctx).colorScheme.onSurfaceVariant;
  }

  String _statusLabel() {
    final raw = match.statusDisplay;
    return raw == '—' ? 'Pending' : raw;
  }

  String _segmentTag() {
    switch (match.segment) {
      case 'fourball':  return 'Four Ball';
      case 'foursomes': return 'Alt-Shot';
      default:
        // Singles: differentiate at-a-glance using the backend's match
        // label.  4-player TC has "Singles 1"/"Singles 2"; 2-player TC
        // Nassau has "Front 9"/"Back 9"/"Overall".  Empty/legacy labels
        // fall back to plain "Singles" so older rounds still read OK.
        final lbl = match.label.trim();
        return lbl.isEmpty ? 'Singles' : lbl;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final lastPlayed = match.holes.isNotEmpty ? match.holes.last.hole : null;
    final decided    = match.status == 'complete' || match.status == 'halved';
    final displayEnd = (decided && lastPlayed != null && lastPlayed < match.endHole)
        ? lastPlayed
        : match.endHole;

    return Card(
      margin: const EdgeInsets.only(right: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isCurrent
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: Container(
        width: 120,
        padding: const EdgeInsets.all(10),
        // Compact 3-row layout: segment / match score (focal) / hole range.
        // Team identity comes through via the status color — red/blue (or
        // cup-team colors) tints the score line.  Player-level detail
        // (team rosters, SO) lives on the player rows above and on the
        // leaderboard.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _segmentTag(),
              style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.tertiary),
            ),
            const SizedBox(height: 4),
            Text(
              _statusLabel(),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _statusColor(context)),
            ),
            const SizedBox(height: 4),
            Text(
              'Holes ${match.startHole}–$displayEnd',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            // Singles segment has two simultaneous 1v1 matches — show
            // the pairing so the user can tell which match this card
            // belongs to.  Fourball / Foursomes share the same 2v2
            // partnership across the foursome, so the pairing is
            // already obvious from the colored player rows above.
            if (match.segment == 'singles') ...[
              const SizedBox(height: 4),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: theme.textTheme.bodySmall,
                  children: [
                    TextSpan(
                      text: match.team1.hasPlayers
                          ? match.team1.shorts.join('/')
                          : '??',
                      style: TextStyle(
                          color: t1Color, fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: '  v.  ',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    TextSpan(
                      text: match.team2.hasPlayers
                          ? match.team2.shorts.join('/')
                          : '??',
                      style: TextStyle(
                          color: t2Color, fontWeight: FontWeight.w600),
                    ),
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

// ---------------------------------------------------------------------------
// Match Play status card (compact bracket snapshot for score entry screen)
// ---------------------------------------------------------------------------

class _MatchPlayStatusCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final int                  foursomeId;
  final int?                 roundId;

  const _MatchPlayStatusCard({
    required this.data,
    required this.foursomeId,
    this.roundId,
  });

  List<Map<String, dynamic>> _matchesForRound(int round) =>
      (data['matches'] as List? ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .where((m) => (m['round'] as int) == round)
          .toList();

  /// Human-readable one-liner for a single match (mirrors match_play_screen.dart).
  /// Uses short names so the status column fits inside the compact bottom
  /// cards on the score-entry screen ("Paul L wins 3&2" vs "Paul Lipkin
  /// wins 3&2" — the latter truncates).
  String _matchSummary(Map<String, dynamic> match) {
    final status           = match['status']           as String;
    final result           = match['result']           as String?;
    final holes            = (match['holes']           as List? ?? []);
    final p1Short          = (match['player1_short'] ?? match['player1']) as String;
    final p2Short          = (match['player2_short'] ?? match['player2']) as String;
    final winnerShort      = (match['winner_short'] ?? match['winner_name']) as String?;
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
      if (winnerShort == null) return 'Complete';
      if (tieBreak == 'sudden_death')  return '$winnerShort wins (SD)';
      if (tieBreak == 'last_hole_won') return '$winnerShort wins (last hole)';
      if (finishedOn != null) {
        final scheduledEnd = round == 1 ? 9 : 18;
        final remaining    = scheduledEnd - finishedOn;
        final h = holes.cast<Map<String, dynamic>>().firstWhere(
              (h) => h['hole'] == finishedOn,
              orElse: () => <String, dynamic>{});
        final margin = ((h['margin'] as int?) ?? 0).abs();
        if (remaining > 0) return '$winnerShort ${margin}&$remaining';
        if (margin > 0)    return '$winnerShort wins $margin Up';
      }
      return '$winnerShort wins';
    }

    // in_progress
    if (holes.isEmpty) return 'In progress';
    final last        = holes.last as Map<String, dynamic>;
    final lastHoleNum = last['hole']   as int? ?? 0;
    final margin      = last['margin'] as int? ?? 0;
    // SD in progress for a round-1 semi
    if (round == 1 && lastHoleNum > 9) {
      if (margin == 0) return 'All Square — SD thru $lastHoleNum';
      final leader = margin > 0 ? p1Short : p2Short;
      return '$leader leads — SD thru $lastHoleNum';
    }
    if (margin == 0) return 'All Square thru $lastHoleNum';
    final leader = margin > 0 ? p1Short : p2Short;
    return '$leader ${margin.abs()} Up thru $lastHoleNum';
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final status = data['status'] as String? ?? 'pending';
    final winner = data['winner'] as String?;
    final r1     = _matchesForRound(1);
    final r2     = _matchesForRound(2);

    // Pending → bracket setup; in-progress or complete → leaderboard so
    // the user lands on the rich bracket view (MatchPlayDetailView).
    // Same routing convention as the Three-Person Match card below for
    // consistency.
    final isPending = status == 'pending';
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (isPending) {
            Navigator.of(context).pushNamed(
              '/match-play-setup',
              arguments: foursomeId,
            );
          } else if (roundId != null) {
            Navigator.of(context).pushNamed(
              '/leaderboard',
              arguments: {
                'roundId':       roundId,
                'initialTabKey': 'match_play',
              },
            );
          }
        },
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
                Text('Mini Singles Bracket',
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
    // Use short names so "p1 vs p2" fits beside the status summary in the
    // bottom card without truncation.  Falls back to full names on the
    // off chance _short is missing (older payload, etc.).
    final p1     = (match['player1_short'] ?? match['player1']) as String? ?? '?';
    final p2     = (match['player2_short'] ?? match['player2']) as String? ?? '?';
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
  final int?                    roundId;

  const _ThreePersonMatchStatusCard({
    required this.summary,
    required this.foursomeId,
    this.roundId,
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
              color: Colors.red.shade700, fontStyle: FontStyle.italic),
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

    // Routing convention matches the Match Play card directly above:
    //   pending  → TPM setup screen
    //   running  → leaderboard (Three-Person Match tab) so the user
    //              lands on the rich detail view rather than the
    //              setup-screen-redirect dance.
    final isPending = status == 'pending';
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (isPending) {
            Navigator.of(context).pushNamed(
              '/three-person-match-setup',
              arguments: foursomeId,
            );
          } else if (roundId != null) {
            Navigator.of(context).pushNamed(
              '/leaderboard',
              arguments: {
                'roundId':       roundId,
                'initialTabKey': 'three_person_match',
              },
            );
          }
        },
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
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant),
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
  late List<Membership> _ordered = List.of(widget.members);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
              'Drag rows to set Red vs Blue for this extra match.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            TeamSplitter4(
              players: _ordered,
              onChanged: (ordered) => setState(() => _ordered = ordered),
            ),

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop([
                  _ordered.take(2).map((m) => m.player.id).toList(),
                  _ordered.skip(2).take(2).map((m) => m.player.id).toList(),
                ]),
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
      return strokesOnHole(effective, mySi);
    }
    if (summary.handicapMode == 'strokes_off') {
      if (players.isEmpty) return 0;
      final low   = players.map((p) => p.playingHandicap).reduce((a, b) => a < b ? a : b);
      final rawSo = m.playingHandicap - low;
      if (rawSo <= 0) return 0;
      final so = (rawSo * summary.netPercent / 100.0).round();
      if (so <= 0) return 0;
      return strokesOnHole(so, mySi);
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
        bg    = Colors.red.shade100;
        fg    = Colors.red.shade700;
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

// ---------------------------------------------------------------------------
// Cup Singles — shared helpers
// ---------------------------------------------------------------------------

Color _cupSinglesTeamColor(String? raw) {
  switch ((raw ?? '').toLowerCase().trim()) {
    case 'red':    return const Color(0xFFB71C1C);
    case 'blue':   return const Color(0xFF0D47A1);
    case 'green':  return const Color(0xFF1B5E20);
    case 'gold':
    case 'yellow': return const Color(0xFFF57F17);
    case 'orange': return const Color(0xFFE65100);
    case 'purple': return const Color(0xFF4A148C);
    case 'black':  return Colors.black87;
    default:       return const Color(0xFF455A64);
  }
}

String _cupSinglesWonByText(Map<String, dynamic> m) {
  final status      = m['status']           as String? ?? 'pending';
  final result      = m['result']           as String?;
  final holesPlayed = m['holes_played']     as int?    ?? 0;
  final overallUp   = m['overall_holes_up'] as int?    ?? 0;
  final finishedOn  = m['finished_on_hole'] as int?;
  final p1          = m['player1']          as String? ?? '?';
  final p2          = m['player2']          as String? ?? '?';

  if (holesPlayed == 0) return 'Not started';
  if (status == 'complete') {
    if (result == 'halved') return 'Halved';
    final winner = result == 'player1' ? p1 : p2;
    if (finishedOn != null) {
      final rem = 18 - finishedOn;
      final mag = overallUp.abs();
      return rem > 0 ? '$winner $mag&$rem' : '$winner wins $mag Up';
    }
    return '$winner wins';
  }
  if (overallUp == 0) return 'All Square thru $holesPlayed';
  final leader = overallUp > 0 ? p1 : p2;
  return '$leader ${overallUp.abs()} Up thru $holesPlayed';
}

Widget _cupSinglesSegBox(
  String label,
  int?   holesUp,
  bool   notStarted,
  Color  p1Color,
  Color  p2Color,
  ThemeData theme,
) {
  Color  color;
  String text = label;

  if (notStarted || holesUp == null) {
    color = theme.colorScheme.outlineVariant;
  } else if (holesUp == 0) {
    color = theme.colorScheme.onSurfaceVariant;
    text  = '$label=';
  } else {
    color = holesUp > 0 ? p1Color : p2Color;
  }

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withOpacity(0.45)),
    ),
    child: Text(text,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.bold, color: color)),
  );
}

// ---------------------------------------------------------------------------
// Cup Singles — compact status bar (above hole navigator)
// ---------------------------------------------------------------------------

class _CupSinglesStatusBar extends StatelessWidget {
  final Map<String, dynamic> data;
  const _CupSinglesStatusBar({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final matches = (data['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    final t1Color  = _cupSinglesTeamColor(data['team1_colour'] as String?);
    final t2Color  = _cupSinglesTeamColor(data['team2_colour'] as String?);
    final muted    = theme.colorScheme.onSurfaceVariant.withOpacity(0.45);
    final neutral  = theme.colorScheme.onSurfaceVariant;

    // Builds a single "Label  value" chip from per-segment fields.
    //
    // status:     'pending' | 'in_progress' | 'complete'
    // holesUp:    margin (positive = p1 leads); null when pending
    // finishedOn: hole number where this sub-match closed (null if not complete)
    // endHole:    last hole of this segment (9 for F9, 18 for B9/All)
    //
    // Display rules:
    //   pending                          → "Pend"   (dim)
    //   in_progress, AS                  → "AS"     (neutral)
    //   in_progress, leading             → "Xup"    (leader color)
    //   complete, halved / margin==0     → "AS"     (neutral)
    //   complete, finishedOn < endHole   → "X&Y"    (leader color)
    //   complete, finishedOn == endHole  → "Xup"    (leader color)
    Widget segChip(String label, String status, int? holesUp,
        int? finishedOn, int endHole) {
      String txt;
      Color  color;

      if (status == 'pending' || holesUp == null) {
        txt   = 'Pend';
        color = muted;
      } else if (holesUp == 0) {
        txt   = 'AS';
        color = neutral;
      } else {
        color = holesUp > 0 ? t1Color : t2Color;
        if (status == 'complete' && finishedOn != null && finishedOn < endHole) {
          final remaining = endHole - finishedOn;
          txt = '${holesUp.abs()}&$remaining';
        } else {
          txt = '${holesUp.abs()}up';
        }
      }

      return RichText(
        text: TextSpan(children: [
          TextSpan(
              text: '$label ',
              style: TextStyle(
                  fontSize: 10,
                  color: neutral.withOpacity(0.6),
                  fontWeight: FontWeight.w500)),
          TextSpan(
              text: txt,
              style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.bold)),
        ]),
      );
    }

    // Determine which team is red (for "red first" display order).
    final t1IsRed  = (data['team1_colour'] as String? ?? '').toLowerCase() == 'red';
    final redColor  = t1IsRed ? t1Color : t2Color;
    final blueColor = t1IsRed ? t2Color : t1Color;

    final matchCols = <Widget>[];
    for (var i = 0; i < matches.length; i++) {
      final m           = matches[i];
      final p1Name = m['player1'] as String? ?? '?';
      final p2Name = m['player2'] as String? ?? '?';

      // Per-segment status from backend Nassau sub-match computation.
      final f9Status  = m['f9_status']  as String? ?? 'pending';
      final f9Up      = m['f9_holes_up']         as int?;
      final f9FinOn   = m['f9_finished_on_hole']  as int?;

      final b9Status  = m['b9_status']  as String? ?? 'pending';
      final b9Up      = m['b9_holes_up']         as int?;
      final b9FinOn   = m['b9_finished_on_hole']  as int?;

      final allStatus = m['status']     as String? ?? 'pending';
      final allUp     = m['overall_holes_up']    as int?;
      final allFinOn  = m['finished_on_hole']    as int?;

      // Red player first, then blue — always show both names in their colors.
      final redName  = t1IsRed ? p1Name : p2Name;
      final blueName = t1IsRed ? p2Name : p1Name;

      if (i > 0) {
        matchCols.add(const SizedBox(width: 8));
        matchCols.add(VerticalDivider(
            width: 1, color: theme.colorScheme.outlineVariant));
        matchCols.add(const SizedBox(width: 8));
      }
      matchCols.add(Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Always show "RedPlayer v. BluePlayer" in team colors, centered
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(children: [
                TextSpan(
                    text: redName,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: redColor)),
                TextSpan(
                    text: ' v. ',
                    style: TextStyle(
                        fontSize: 12,
                        color: neutral.withOpacity(0.55))),
                TextSpan(
                    text: blueName,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: blueColor)),
              ]),
            ),
            const SizedBox(height: 5),
            // F9 · B9 · All — each uses its own sub-match status
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              segChip('F9',  f9Status,  f9Up,  f9FinOn,  9),
              const SizedBox(width: 10),
              segChip('B9',  b9Status,  b9Up,  b9FinOn,  18),
              const SizedBox(width: 10),
              segChip('All', allStatus, allUp, allFinOn, 18),
            ]),
          ],
        ),
      ));
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color        : theme.colorScheme.surfaceContainerLow,
        borderRadius : BorderRadius.circular(8),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: matchCols,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cup Singles — per-hole progress grid (mirrors _NassauProgressGrid layout)
// ---------------------------------------------------------------------------

class _CupSinglesProgressGrid extends StatefulWidget {
  final Map<String, dynamic>     data;        // cup_singles_summary
  final Scorecard                scorecard;
  final int                      currentHole;
  final void Function(int hole)? onTapHole;

  const _CupSinglesProgressGrid({
    required this.data,
    required this.scorecard,
    required this.currentHole,
    this.onTapHole,
  });

  @override
  State<_CupSinglesProgressGrid> createState() =>
      _CupSinglesProgressGridState();
}

class _CupSinglesProgressGridState extends State<_CupSinglesProgressGrid> {
  final List<ScrollController> _scrollCtrl = [];

  static const double _labelColW = 58.0;
  static const double _cellW     = 34.0;
  static const double _rowH      = 28.0;

  static Color _tc(String? raw) {
    switch ((raw ?? '').toLowerCase().trim()) {
      case 'red':    return const Color(0xFFB71C1C);
      case 'blue':   return const Color(0xFF0D47A1);
      case 'green':  return const Color(0xFF1B5E20);
      case 'gold':
      case 'yellow': return const Color(0xFFF57F17);
      case 'orange': return const Color(0xFFE65100);
      case 'purple': return const Color(0xFF4A148C);
      case 'black':  return Colors.black87;
      default:       return const Color(0xFF455A64);
    }
  }

  List<Map<String, dynamic>> get _matches =>
      (widget.data['matches'] as List? ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.add(ScrollController());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.isNotEmpty) _scrollToHole(_scrollCtrl[0], widget.currentHole);
    });
  }

  @override
  void didUpdateWidget(_CupSinglesProgressGrid old) {
    super.didUpdateWidget(old);
    if (_scrollCtrl.isEmpty) _scrollCtrl.add(ScrollController());
    if (old.currentHole != widget.currentHole) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.isNotEmpty) _scrollToHole(_scrollCtrl[0], widget.currentHole);
      });
    }
  }

  @override
  void dispose() {
    for (final sc in _scrollCtrl) sc.dispose();
    super.dispose();
  }

  void _scrollToHole(ScrollController sc, int hole) {
    if (!sc.hasClients) return;
    final target = (_labelColW + (hole - 7) * _cellW)
        .clamp(0.0, sc.position.maxScrollExtent);
    sc.animateTo(target,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final matches   = _matches;
    final scorecard = widget.scorecard;
    final cur       = widget.currentHole;
    final onTap     = widget.onTapHole;
    final holeRange = List.generate(18, (i) => i + 1);

    // Team colours: cup mode carries configured colours; casual (null) uses the
    // standard blue (team 1) / orange (team 2) constants.
    final t1ColourStr = widget.data['team1_colour'] as String?;
    final t2ColourStr = widget.data['team2_colour'] as String?;
    final t1Color = t1ColourStr == null ? kTripleCupTeam1Color : _tc(t1ColourStr);
    final t2Color = t2ColourStr == null ? kTripleCupTeam2Color : _tc(t2ColourStr);

    // Orange (team 2) on top, Blue (team 1) below — blue renders second, per
    // the app convention. Casual (null colour) = team 1 blue.
    final t1IsBlue = (t1ColourStr ?? 'blue').toLowerCase() == 'blue';
    final blueColor = t1IsBlue ? t1Color : t2Color;
    final redColor  = t1IsBlue ? t2Color : t1Color;

    if (_scrollCtrl.isEmpty) _scrollCtrl.add(ScrollController());
    final sc = _scrollCtrl[0];

    // Label column cell (left side)
    Widget labelCell(String text, {Color? color, bool italic = false}) =>
        SizedBox(
          width: _labelColW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: color != null ? FontWeight.w600 : FontWeight.normal,
                    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                    color: color ?? theme.colorScheme.onSurfaceVariant)),
          ),
        );

    // Score/header cell for a given hole column
    Widget holeCell(int h, {required Widget child, Color? bg}) {
      final isCurrent = h == cur;
      return GestureDetector(
        onTap: onTap == null ? null : () => onTap(h),
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

    // Build all rows into one list — single scrollable keeps everything aligned
    final rows = <Widget>[];
    final totalW = _labelColW + _cellW * holeRange.length;

    // ── Hole numbers (once) ──────────────────────────────────────────────────
    rows.add(Row(children: [
      labelCell('Hole'),
      for (final h in holeRange)
        holeCell(h,
            child: Text('$h',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
    ]));

    // ── Par row (once) ───────────────────────────────────────────────────────
    rows.add(Row(children: [
      labelCell('Par', italic: true),
      for (final h in holeRange)
        holeCell(h,
            child: Text(
              '${scorecard.holeData(h)?.par ?? "-"}',
              style: theme.textTheme.bodySmall,
            )),
    ]));

    rows.add(Container(
      height: 1, width: totalW,
      color: theme.colorScheme.outlineVariant,
      margin: const EdgeInsets.symmetric(vertical: 2),
    ));

    // ── Per-match rows ───────────────────────────────────────────────────────
    for (var mi = 0; mi < matches.length; mi++) {
      final m = matches[mi];

      final holeMap = <int, Map<String, dynamic>>{};
      for (final h in (m['holes'] as List? ?? [])) {
        final hm = Map<String, dynamic>.from(h as Map);
        holeMap[hm['hole_number'] as int] = hm;
      }

      final blueP = t1IsBlue
          ? (m['player1'] as String? ?? '?')
          : (m['player2'] as String? ?? '?');
      final redP  = t1IsBlue
          ? (m['player2'] as String? ?? '?')
          : (m['player1'] as String? ?? '?');

      Widget scoreCell(int h, String? scoreStr, Color nameColor) {
        final isCur = h == cur;
        return GestureDetector(
          onTap: onTap == null ? null : () => onTap(h),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: _cellW, height: _rowH,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isCur
                  ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                  : null,
              border: isCur
                  ? Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.6),
                      width: 1.2)
                  : null,
            ),
            child: Text(scoreStr ?? '·',
                style: TextStyle(
                    fontSize: 11,
                    color: scoreStr != null
                        ? nameColor
                        : theme.colorScheme.onSurfaceVariant.withOpacity(0.3),
                    fontWeight: scoreStr != null
                        ? FontWeight.w600
                        : FontWeight.normal)),
          ),
        );
      }

      // Orange player (team 2) on top
      rows.add(Row(children: [
        labelCell(redP, color: redColor),
        for (final h in holeRange)
          scoreCell(
            h,
            holeMap.containsKey(h)
                ? '${t1IsBlue ? holeMap[h]!['p2_net'] : holeMap[h]!['p1_net']}'
                : null,
            redColor,
          ),
      ]));

      // Blue player (team 1) below — blue renders second, per convention
      rows.add(Row(children: [
        labelCell(blueP, color: blueColor),
        for (final h in holeRange)
          scoreCell(
            h,
            holeMap.containsKey(h)
                ? '${t1IsBlue ? holeMap[h]!['p1_net'] : holeMap[h]!['p2_net']}'
                : null,
            blueColor,
          ),
      ]));

      // Won by row
      rows.add(Row(children: [
        labelCell('Won by', italic: true),
        for (final h in holeRange)
          Builder(builder: (_) {
            if (!holeMap.containsKey(h)) {
              return holeCell(h,
                  child: Text('·',
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant
                              .withOpacity(0.3))));
            }
            final hd    = holeMap[h]!;
            final p1Net = hd['p1_net'] as int? ?? 0;
            final p2Net = hd['p2_net'] as int? ?? 0;
            final p1Won = p1Net < p2Net;
            final p2Won = p2Net < p1Net;
            final blueWon = t1IsBlue ? p1Won : p2Won;
            final redWon  = t1IsBlue ? p2Won : p1Won;

            Color? bg;
            Color? fg;
            String label;
            if (blueWon) {
              bg = blueColor.withOpacity(0.15);
              fg = blueColor;
              label = 'B';
            } else if (redWon) {
              bg = redColor.withOpacity(0.15);
              fg = redColor;
              label = 'R';
            } else {
              bg = theme.colorScheme.surfaceContainerHighest;
              fg = theme.colorScheme.onSurfaceVariant;
              label = '=';
            }
            return holeCell(h,
                bg: bg,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: fg)));
          }),
      ]));

      // Thin divider between matches (not after last)
      if (mi < matches.length - 1) {
        rows.add(Container(
          height: 1, width: totalW,
          color: theme.colorScheme.outlineVariant,
          margin: const EdgeInsets.symmetric(vertical: 3),
        ));
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
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: sc,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cup Singles — full status card (in the game summary panel)
// ---------------------------------------------------------------------------

class _CupSinglesStatusCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _CupSinglesStatusCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final matches = (data['matches'] as List? ?? [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    final t1Color = _cupSinglesTeamColor(data['team1_colour'] as String?);
    final t2Color = _cupSinglesTeamColor(data['team2_colour'] as String?);

    // ── Status bar: Match 1 [F9][B9][All]  |  Match 2 [F9][B9][All] ─────────
    final matchCols = <Widget>[];
    for (var i = 0; i < matches.length; i++) {
      final m          = matches[i];
      final notStarted = (m['holes_played'] as int? ?? 0) == 0;
      final f9Up       = m['f9_holes_up']      as int?;
      final b9Up       = m['b9_holes_up']      as int?;
      final allUp      = m['overall_holes_up'] as int?;

      if (i > 0) {
        matchCols.add(const SizedBox(width: 8));
        matchCols.add(VerticalDivider(
            width: 1, color: theme.colorScheme.outlineVariant));
        matchCols.add(const SizedBox(width: 8));
      }
      matchCols.add(Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Match ${i + 1}',
                style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 5),
            Row(children: [
              _cupSinglesSegBox('F9',  f9Up,  notStarted, t1Color, t2Color, theme),
              const SizedBox(width: 3),
              _cupSinglesSegBox('B9',  b9Up,  notStarted, t1Color, t2Color, theme),
              const SizedBox(width: 3),
              _cupSinglesSegBox('All', allUp, notStarted, t1Color, t2Color, theme),
            ]),
          ],
        ),
      ));
    }

    // ── Per-match player + won-by rows ────────────────────────────────────────
    final matchSections = <Widget>[];
    for (var i = 0; i < matches.length; i++) {
      final m          = matches[i];
      final p1         = m['player1'] as String? ?? '?';
      final p2         = m['player2'] as String? ?? '?';
      final wonBy      = _cupSinglesWonByText(m);
      final notStarted = (m['holes_played'] as int? ?? 0) == 0;
      final result     = m['result'] as String?;
      final overallUp  = m['overall_holes_up'] as int? ?? 0;
      final isHalved   = result == 'halved' || overallUp == 0;
      final p1Leads    = !notStarted &&
          (result == 'player1' || (result == null && overallUp > 0));

      Color wonByColor  = theme.colorScheme.onSurfaceVariant;
      bool  wonByItalic = notStarted || isHalved;
      if (!notStarted && !isHalved) {
        wonByColor = p1Leads ? t1Color : t2Color;
      }

      matchSections.add(Padding(
        padding: EdgeInsets.only(bottom: i == matches.length - 1 ? 0 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Match ${i + 1}',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            // Team 1 / player 1 row
            Row(children: [
              Container(
                width: 9, height: 9,
                decoration: BoxDecoration(shape: BoxShape.circle, color: t1Color),
              ),
              const SizedBox(width: 7),
              Text(p1,
                  style: TextStyle(
                      color: t1Color,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ]),
            const SizedBox(height: 3),
            // Team 2 / player 2 row
            Row(children: [
              Container(
                width: 9, height: 9,
                decoration: BoxDecoration(shape: BoxShape.circle, color: t2Color),
              ),
              const SizedBox(width: 7),
              Text(p2,
                  style: TextStyle(
                      color: t2Color,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ]),
            const SizedBox(height: 5),
            // Won by row
            Row(children: [
              Text('Won by:  ',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
              Expanded(
                child: Text(wonBy,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: wonByColor,
                        fontWeight: FontWeight.w600,
                        fontStyle: wonByItalic
                            ? FontStyle.italic
                            : FontStyle.normal)),
              ),
            ]),
          ],
        ),
      ));
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Singles',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          // Status bar
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: matchCols,
            ),
          ),
          const Divider(height: 22),
          // Per-match sections
          ...matchSections,
        ]),
      ),
    );
  }
}


// ---------------------------------------------------------------------------
// Las Vegas status card — team totals + per-hole numbers (shown in score entry)
// ---------------------------------------------------------------------------

class _VegasStatusCard extends StatelessWidget {
  final VegasSummary summary;
  final int currentHole;
  const _VegasStatusCard({required this.summary, required this.currentHole});

  String _money(double v) {
    if (v == 0) return '—';
    final s = v > 0 ? '+' : '−';
    return '$s\$${v.abs().toStringAsFixed(2)}';
  }

  Widget _teamRow(BuildContext ctx, VegasTeamSummary t, Color color) {
    final theme = Theme.of(ctx);
    final names = t.players.map((p) => p.shortName).join(' & ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Container(width: 4, height: 20,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Expanded(child: Text(names,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis)),
        Text('${t.points} pts',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(width: 10),
        SizedBox(width: 64, child: Text(_money(t.money),
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
                color: t.money > 0 ? GameColors.win
                    : t.money < 0 ? GameColors.loss
                    : theme.colorScheme.onSurfaceVariant))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    VegasTeamSummary? team(int n) =>
        summary.teams.where((t) => t.teamNumber == n).firstOrNull;
    final t1 = team(1), t2 = team(2);
    final decided = summary.holes.where((h) => h.winner != null).toList();

    Color winColor(String? w) => w == 'team1' ? GameColors.team1
        : w == 'team2' ? GameColors.team2
        : theme.colorScheme.onSurfaceVariant;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Las Vegas', style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(summary.birdieMode == 'flip' ? 'Flip' : 'Multiply',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (summary.carryover) ...[
              const SizedBox(width: 8),
              Text('Carryover', style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
          const SizedBox(height: 6),
          if (t1 != null) _teamRow(context, t1, GameColors.team1),
          if (t2 != null) _teamRow(context, t2, GameColors.team2),
          if (decided.isNotEmpty) ...[
            const Divider(height: 18),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final h in decided)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: winColor(h.winner).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: h.hole == currentHole
                            ? theme.colorScheme.primary
                            : winColor(h.winner).withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    // A halved Vegas hole is worth 0 points (a push), not the
                    // match-play "½" — the equal numbers already show the tie.
                    h.winner == 'halved'
                        ? 'H${h.hole} ${h.team1Number}-${h.team2Number}'
                        : 'H${h.hole} ${h.team1Number}-${h.team2Number} '
                          '+${h.points}',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: winColor(h.winner),
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Live Fourball match status during score entry: both teams on one line
/// (long names, "vs." between, colored), then the running result led by the
/// leading team's short names ("Paul & Mike 2 UP thru 5" / "All Square" /
/// "Paul & Mike win 3&2").
class _FourballStatusCard extends StatelessWidget {
  final FourballSummary summary;
  final int currentHole;
  const _FourballStatusCard(
      {required this.summary, required this.currentHole});

  String _hcapLabel() {
    if (summary.isGross) return 'Gross';
    final pct = summary.netPercent == 100 ? '' : ' ${summary.netPercent}%';
    return summary.isStrokesOff ? 'Strokes-off$pct' : 'Net$pct';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Color sideColor(String? side) => side == 'team1'
        ? GameColors.team1
        : side == 'team2'
            ? GameColors.team2
            : theme.colorScheme.onSurfaceVariant;

    String longNames(FourballTeamInfo t) =>
        t.players.isNotEmpty ? t.players.join(' & ') : 'Team';
    String shortNames(FourballTeamInfo t) =>
        (t.shortNames.isNotEmpty ? t.shortNames : t.players).join(' & ');

    // "thru N" is holes COMPLETED (a count), not a hole number — reads right on
    // a mid-course / shotgun start (played 7–12 = thru 6, not 12).
    final thru = summary.holesPlayed;
    final margin    = summary.holesUp.abs();
    final leadTeam  = summary.holesUp > 0 ? summary.team1 : summary.team2;
    // Live status line, led by the leading/winning team's short names:
    //   "Paul & Mike 2 UP thru 5" / "All Square thru 5" / "Paul & Mike win 3&2".
    final String statusLine;
    if (summary.status == 'complete') {
      // Holes remaining at close-out = 18 − holes played (count-based, so a
      // mid-course start still yields the right "&M").
      final toPlay = 18 - summary.holesPlayed;
      statusLine = toPlay > 0
          ? '${shortNames(leadTeam)} win $margin&$toPlay'
          : '${shortNames(leadTeam)} win $margin UP';
    } else if (summary.status == 'halved') {
      statusLine = 'All Square';
    } else if (thru == 0) {
      statusLine = 'Not started';
    } else if (summary.holesUp == 0) {
      statusLine = 'All Square thru $thru';
    } else {
      statusLine = '${shortNames(leadTeam)} $margin UP thru $thru';
    }
    final leaderColor = sideColor(summary.leader);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Fourball', style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(_hcapLabel(),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 6),
          // Both teams on one line, long names, "vs." in between.
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: longNames(summary.team1),
                  style: TextStyle(
                      color: GameColors.team1, fontWeight: FontWeight.w700)),
              TextSpan(
                  text: '  vs.  ',
                  style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500)),
              TextSpan(
                  text: longNames(summary.team2),
                  style: TextStyle(
                      color: GameColors.team2, fontWeight: FontWeight.w700)),
            ]),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Row(children: [
            Icon(
                summary.status == 'complete'
                    ? Icons.flag_rounded
                    : summary.status == 'halved'
                        ? Icons.handshake_rounded
                        : Icons.timelapse_rounded,
                size: 16, color: leaderColor),
            const SizedBox(width: 6),
            Text(statusLine,
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600, color: leaderColor)),
          ]),
        ]),
      ),
    );
  }
}

