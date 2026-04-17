/// providers/round_provider.dart
///
/// Manages the active round, scorecard, and leaderboard.
///
/// Offline-first changes (vs. original):
///   • submitHole   — writes to [LocalDatabase] first (never fails for the
///                    user), then asks [SyncService] to deliver it in the
///                    background. Returns true immediately.
///   • loadRound    — tries the API; on [NetworkException] falls back to the
///                    local cache.
///   • loadScorecard— same fallback; also merges any unsynced local scores on
///                    top of the server/cached state so the user always sees
///                    what they entered.
///   • [localPendingByHole] — exposed so the scorecard UI can overlay unsynced
///                    scores without an extra async call.

import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../local/local_database.dart';
import '../sync/sync_service.dart';
import '../widgets/error_view.dart';

class RoundProvider extends ChangeNotifier {
  ApiClient         _client;
  final LocalDatabase _localDb;
  final SyncService   _sync;

  RoundProvider(this._client, this._localDb, this._sync) {
    _sync.addListener(_onSyncChanged);
  }

  /// Called by ProxyProvider when the auth token changes.
  void updateClient(ApiClient client) {
    _client = client;
    _sync.updateClient(client);
  }

  @override
  void dispose() {
    _sync.removeListener(_onSyncChanged);
    super.dispose();
  }

  // Track pending count so we only react when items are actually cleared.
  int _lastPendingCount = 0;

  void _onSyncChanged() {
    final id = _activeFoursomeId;
    if (id == null) return;

    final current = _sync.pendingCount;
    if (current < _lastPendingCount) {
      // Items were just synced — refresh the overlay from DB so cloud icons clear.
      _refreshPendingOverlay(id);
    }
    _lastPendingCount = current;
  }

  /// Public: called on screen re-entry to re-sync the pending overlay from DB.
  Future<void> refreshPendingOverlay() async {
    if (_activeFoursomeId == null) return;
    await _refreshPendingOverlay(_activeFoursomeId!);
  }

  /// Re-read pending-score overlay from the DB without a full scorecard reload.
  Future<void> _refreshPendingOverlay(int foursomeId) async {
    _localPendingByHole = await _localDb.pendingForFoursome(foursomeId);
    if (_sync.pendingCount == 0 && _sync.isOnline) {
      // Queue is drained and we're online — the offline error is no longer
      // valid. Clear it and notify immediately so the banner drops right away,
      // regardless of whether the follow-up scorecard fetch succeeds or fails.
      _error = null;
      notifyListeners();
      _refreshScorecardQuietly(foursomeId); // fire-and-forget, updates net scores
    } else {
      notifyListeners();
    }
  }

  // ── State ──────────────────────────────────────────────────────────────────

  Round?        _round;
  Scorecard?    _scorecard;
  Leaderboard?  _leaderboard;
  SixesSummary? _sixesSummary;
  int?          _activeFoursomeId;

  /// Foursomes whose Sixes match has been set up (segments + teams exist).
  /// Used by RoundScreen to label the entry button "Start Match" vs "Enter Scores".
  final Set<int> _sixesStartedFoursomes = {};

  bool    _loadingRound       = false;
  bool    _loadingScorecard   = false;
  bool    _loadingLeaderboard = false;
  bool    _loadingSixes       = false;
  bool    _submitting         = false;
  String? _error;

  /// Scores saved locally but not yet confirmed by the server.
  /// Structure: { holeNumber: { playerId: grossScore } }
  /// The scorecard UI overlays these on top of the server data.
  Map<int, Map<int, int>> _localPendingByHole = {};

  // ── Getters ────────────────────────────────────────────────────────────────

  Round?        get round              => _round;
  Scorecard?    get scorecard          => _scorecard;
  Leaderboard?  get leaderboard        => _leaderboard;
  SixesSummary? get sixesSummary       => _sixesSummary;
  int?          get activeFoursomeId   => _activeFoursomeId;

  /// True once sixes segments with players have been saved for [foursomeId].
  bool sixesIsStarted(int foursomeId) =>
      _sixesStartedFoursomes.contains(foursomeId);
  bool          get loadingRound       => _loadingRound;
  bool          get loadingScorecard   => _loadingScorecard;
  bool          get loadingLeaderboard => _loadingLeaderboard;
  bool          get loadingSixes       => _loadingSixes;
  bool          get submitting         => _submitting;
  String?       get error              => _error;
  Map<int, Map<int, int>> get localPendingByHole => _localPendingByHole;

  void _clearError() { _error = null; }

  // ── Round ──────────────────────────────────────────────────────────────────

  Future<void> loadRound(int roundId) async {
    _loadingRound = true;
    _clearError();
    notifyListeners();

    try {
      _round = await _client.getRound(roundId);
      // Cache for offline use — fire-and-forget
      _cacheRound(roundId, _round!);
      // Pre-load sixes status for each foursome so the round screen can show
      // "Start Match" vs "Enter Scores" without an extra tap.
      if (_round!.activeGames.contains('sixes')) {
        for (final fs in _round!.foursomes) {
          loadSixes(fs.id); // intentionally unawaited — non-fatal
        }
      }
    } on NetworkException {
      final cached = await _localDb.getCachedRound(roundId);
      if (cached != null) {
        _round = Round.fromJson(cached);
        // Cache loaded fine — no error banner needed.
      } else {
        _error = 'No connection and no cached data for this round.';
      }
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      _loadingRound = false;
      notifyListeners();
    }
  }

  void _cacheRound(int roundId, Round round) {
    // Serialize via the existing fromJson-compatible map.
    final json = {
      'id':           round.id,
      'round_number': round.roundNumber,
      'date':         round.date,
      'course':       {
        'id':            round.course.id,
        'course_name':   round.course.courseName,
        'tee_name':      round.course.teeName,
        'slope':         round.course.slope,
        'course_rating': round.course.courseRating,
        'par':           round.course.par,
      },
      'status':       round.status,
      'active_games': round.activeGames,
      'bet_unit':     round.betUnit,
      'foursomes':    round.foursomes.map((f) => {
        'id':           f.id,
        'group_number': f.groupNumber,
        'has_phantom':  f.hasPhantom,
        'pink_ball_order': f.pinkBallOrder,
        'memberships':  f.memberships.map((m) => {
          'id': m.id,
          'player': {
            'id':              m.player.id,
            'name':            m.player.name,
            'handicap_index':  m.player.handicapIndex,
            'is_phantom':      m.player.isPhantom,
            'email':           m.player.email,
            'phone':           m.player.phone,
          },
          'course_handicap':  m.courseHandicap,
          'playing_handicap': m.playingHandicap,
        }).toList(),
      }).toList(),
    };
    _localDb.cacheRound(roundId, json);  // intentionally unawaited
  }

  // ── Scorecard ──────────────────────────────────────────────────────────────

  Future<void> loadScorecard(int foursomeId) async {
    _activeFoursomeId = foursomeId;
    _loadingScorecard = true;
    _clearError();
    notifyListeners();

    try {
      _scorecard = await _client.getScorecard(foursomeId);
      _cacheScorecardQuietly(foursomeId, _scorecard!);
    } on NetworkException {
      final cached = await _localDb.getCachedScorecard(foursomeId);
      if (cached != null) {
        _scorecard = Scorecard.fromJson(cached);
        // Cache loaded fine — no error banner needed. The sync badge shows
        // any pending scores; we don't need a second "offline" message.
      } else {
        _error = 'No connection and no cached data for this scorecard.';
      }
    } catch (e) {
      _error = friendlyError(e);
    }

    // Always load local pending overlay (even if server call succeeded,
    // items may still be in the queue if the sync hasn't completed yet).
    _localPendingByHole =
        await _localDb.pendingForFoursome(foursomeId);

    _loadingScorecard = false;
    notifyListeners();
  }

  // ── Score submission (offline-first) ──────────────────────────────────────

  /// Save scores for one hole.
  ///
  /// Writes to the local database immediately — this call is the user's
  /// commit point and effectively never fails.  The [SyncService] delivers
  /// the score to the server in the background whenever connectivity allows.
  Future<bool> submitHole({
    required int foursomeId,
    required int holeNumber,
    required List<Map<String, int>> scores,
    bool pinkBallLost = false,
  }) async {
    _submitting = true;
    _clearError();
    notifyListeners();

    try {
      // 1. Write to local DB and queue for sync.
      await _sync.enqueue(
        foursomeId:   foursomeId,
        holeNumber:   holeNumber,
        scores:       scores,
        pinkBallLost: pinkBallLost,
      );

      // 2. Re-read the full pending overlay from DB — more reliable than
      //    patching the in-memory map, and guarantees all holes are present.
      _localPendingByHole =
          await _localDb.pendingForFoursome(foursomeId);

      // 3. If the sync service already drained the item (we were online),
      //    do a quiet scorecard refresh to get updated net scores / totals.
      if (_sync.isOnline && _sync.pendingCount == 0) {
        _refreshScorecardQuietly(foursomeId);
      }

      return true;
    } catch (e) {
      // Should almost never happen — means local DB itself failed.
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// Reload the scorecard silently (no loading spinner) after a sync.
  Future<void> _refreshScorecardQuietly(int foursomeId) async {
    try {
      final fresh = await _client.getScorecard(foursomeId);
      _scorecard = fresh;
      _cacheScorecardQuietly(foursomeId, fresh);
      // Clear overlay holes that the server now confirms.
      _localPendingByHole = await _localDb.pendingForFoursome(foursomeId);
      notifyListeners();
    } catch (_) {
      // Ignore — cached / pending state stays consistent.
    }
  }

  void _cacheScorecardQuietly(int foursomeId, Scorecard sc) {
    // Build a JSON-serialisable map matching Scorecard.fromJson's shape.
    final json = {
      'foursome_id':   sc.foursomeId,
      'group_number':  sc.groupNumber,
      'holes': sc.holes.map((h) => {
        'hole_number':   h.holeNumber,
        'par':           h.par,
        'stroke_index':  h.strokeIndex,
        'yards':         h.yards,
        'scores': h.scores.map((s) => {
          'player_id':         s.playerId,
          'player_name':       s.playerName,
          'hole_number':       s.holeNumber,
          'gross_score':       s.grossScore,
          'handicap_strokes':  s.handicapStrokes,
          'net_score':         s.netScore,
          'stableford_points': s.stablefordPoints,
        }).toList(),
      }).toList(),
      'totals': sc.totals.map((t) => {
        'player_id':        t.playerId,
        'name':             t.name,
        'front_gross':      t.frontGross,
        'back_gross':       t.backGross,
        'total_gross':      t.totalGross,
        'front_net':        t.frontNet,
        'back_net':         t.backNet,
        'total_net':        t.totalNet,
        'total_stableford': t.totalStableford,
      }).toList(),
    };
    _localDb.cacheScorecard(foursomeId, json);  // intentionally unawaited
  }

  // ── Sixes ──────────────────────────────────────────────────────────────────

  /// POST the sixes team setup for a foursome.
  ///
  /// [segments] follows the services/sixes.py team_data format:
  ///   [ { 'start_hole', 'end_hole', 'team_select_method',
  ///       'team1_player_ids', 'team2_player_ids' }, ... ]
  ///
  /// Returns true on success.  On failure, [error] is set and false returned.
  Future<bool> setupSixes(
    int foursomeId,
    List<Map<String, dynamic>> segments,
  ) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      await _client.postSixesSetup(foursomeId, segments);
      _sixesStartedFoursomes.add(foursomeId); // mark as started
      return true;
    } on NetworkException {
      _error = 'No connection — cannot save match setup while offline.';
      return false;
    } catch (e) {
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// Set teams on an existing extra (is_extra=True) segment without
  /// deleting standard segments or hole results.
  ///
  /// Returns true on success.  On failure [error] is set and false returned.
  Future<bool> setExtraTeams(
    int foursomeId,
    List<int> team1Ids,
    List<int> team2Ids,
  ) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      _sixesSummary =
          await _client.postSixesExtraTeams(foursomeId, team1Ids, team2Ids);
      return true;
    } on NetworkException {
      _error = 'No connection — cannot save extra match teams while offline.';
      return false;
    } catch (e) {
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// Load the Six's segment summary for the active foursome.
  /// Non-fatal — a failure just leaves [sixesSummary] null; the screen
  /// still works for score entry using the cached scorecard.
  Future<void> loadSixes(int foursomeId) async {
    _loadingSixes = true;
    notifyListeners();
    try {
      _sixesSummary = await _client.getSixesSummary(foursomeId);
      // Mark as started if the server says segments with players exist.
      final started = _sixesSummary!.segments.any(
        (s) => s.team1.hasPlayers && s.team2.hasPlayers,
      );
      if (started) _sixesStartedFoursomes.add(foursomeId);
    } on NetworkException {
      // Offline — silently keep whatever we had before.
    } catch (e) {
      debugPrint('loadSixes error: $e');
    } finally {
      _loadingSixes = false;
      notifyListeners();
    }
  }

  // ── Leaderboard ────────────────────────────────────────────────────────────

  Future<void> loadLeaderboard(int roundId) async {
    _loadingLeaderboard = true;
    _clearError();
    notifyListeners();
    try {
      _leaderboard = await _client.getLeaderboard(roundId);
    } on NetworkException {
      _error = 'No connection — leaderboard unavailable offline.';
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      _loadingLeaderboard = false;
      notifyListeners();
    }
  }

  // ── Complete round ─────────────────────────────────────────────────────────

  Future<Leaderboard?> completeRound(int roundId) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      final lb = await _client.completeRound(roundId);
      _leaderboard = lb;
      if (_round != null) {
        _round = Round(
          id:          _round!.id,
          roundNumber: _round!.roundNumber,
          date:        _round!.date,
          course:      _round!.course,
          status:      'complete',
          activeGames: _round!.activeGames,
          betUnit:     _round!.betUnit,
          foursomes:   _round!.foursomes,
        );
      }
      return lb;
    } on NetworkException {
      _error = 'No connection — cannot complete round while offline.';
      return null;
    } catch (e) {
      _error = friendlyError(e);
      return null;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
