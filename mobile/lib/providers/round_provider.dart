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

  Round?           _round;
  Scorecard?       _scorecard;
  Leaderboard?     _leaderboard;
  SixesSummary?    _sixesSummary;
  Points531Summary? _points531Summary;
  SkinsSummary?    _skinsSummary;
  WolfSummary?     _wolfSummary;
  RabbitSummary?   _rabbitSummary;
  TripleCupSummary? _tripleCupSummary;
  MultiSkinsSummary? _multiSkinsSummary;
  NassauSummary?         _nassauSummary;
  QuotaNassauSummary?    _quotaNassauSummary;
  Map<String, dynamic>? _matchPlayData;
  ThreePersonMatchSummary? _threePersonMatchSummary;
  Map<String, dynamic>? _lowNetConfig;   // { handicap_mode, net_percent, ... }
  /// Keyed by foursomeId.  Populated by initPhantom() on first entry.
  final Map<int, PhantomInitResult> _phantomInit = {};
  int?             _activeFoursomeId;

  /// Foursomes whose Sixes match has been set up (segments + teams exist).
  /// Used by RoundScreen to label the entry button "Start Match" vs "Enter Scores".
  final Set<int> _sixesStartedFoursomes = {};

  bool    _loadingRound       = false;
  bool    _loadingScorecard   = false;
  bool    _loadingLeaderboard = false;
  bool    _loadingSixes       = false;
  bool    _loadingPoints531   = false;
  bool    _loadingSkins       = false;
  bool    _loadingWolf        = false;
  bool    _loadingRabbit      = false;
  bool    _loadingTripleCup   = false;
  bool    _loadingMultiSkins  = false;
  bool    _loadingNassau      = false;
  bool    _loadingQuotaNassau = false;
  bool    _loadingMatchPlay          = false;
  bool    _loadingThreePersonMatch   = false;
  bool    _loadingLowNet             = false;
  bool    _submitting         = false;
  String? _error;

  /// Scores saved locally but not yet confirmed by the server.
  /// Structure: { holeNumber: { playerId: grossScore } }
  /// The scorecard UI overlays these on top of the server data.
  Map<int, Map<int, int>> _localPendingByHole = {};

  // ── Getters ────────────────────────────────────────────────────────────────

  Round?            get round              => _round;
  Scorecard?        get scorecard          => _scorecard;
  Leaderboard?      get leaderboard        => _leaderboard;
  SixesSummary?     get sixesSummary       => _sixesSummary;
  Points531Summary? get points531Summary   => _points531Summary;
  SkinsSummary?     get skinsSummary       => _skinsSummary;
  WolfSummary?      get wolfSummary        => _wolfSummary;
  RabbitSummary?    get rabbitSummary      => _rabbitSummary;
  TripleCupSummary? get tripleCupSummary   => _tripleCupSummary;
  MultiSkinsSummary? get multiSkinsSummary  => _multiSkinsSummary;
  NassauSummary?        get nassauSummary      => _nassauSummary;
  QuotaNassauSummary?   get quotaNassauSummary => _quotaNassauSummary;
  bool                  get loadingQuotaNassau => _loadingQuotaNassau;
  Map<String, dynamic>?       get matchPlayData            => _matchPlayData;
  ThreePersonMatchSummary?    get threePersonMatchSummary  => _threePersonMatchSummary;
  Map<String, dynamic>?       get lowNetConfig             => _lowNetConfig;
  PhantomInitResult?    phantomInitFor(int foursomeId) => _phantomInit[foursomeId];
  int?                  get activeFoursomeId  => _activeFoursomeId;

  /// True once sixes segments with players have been saved for [foursomeId].
  bool sixesIsStarted(int foursomeId) =>
      _sixesStartedFoursomes.contains(foursomeId);
  bool              get loadingRound       => _loadingRound;
  bool              get loadingScorecard   => _loadingScorecard;
  bool              get loadingLeaderboard => _loadingLeaderboard;
  bool              get loadingSixes       => _loadingSixes;
  bool              get loadingPoints531   => _loadingPoints531;
  bool              get loadingSkins       => _loadingSkins;
  bool              get loadingWolf        => _loadingWolf;
  bool              get loadingRabbit      => _loadingRabbit;
  bool              get loadingTripleCup   => _loadingTripleCup;
  bool              get loadingMultiSkins  => _loadingMultiSkins;
  bool              get loadingNassau      => _loadingNassau;
  bool              get loadingMatchPlay          => _loadingMatchPlay;
  bool              get loadingThreePersonMatch   => _loadingThreePersonMatch;
  bool              get loadingLowNet             => _loadingLowNet;
  bool              get submitting         => _submitting;
  String?           get error              => _error;
  Map<int, Map<int, int>> get localPendingByHole => _localPendingByHole;

  void _clearError() { _error = null; }

  /// Reset all cached round/scorecard/game state on sign-out, so the next user
  /// on this device never sees the previous user's round (e.g. a TD's group).
  /// Does NOT notifyListeners — the app navigates to /login right after.
  void clearForLogout() {
    _round                   = null;
    _scorecard               = null;
    _sixesSummary            = null;
    _points531Summary        = null;
    _skinsSummary            = null;
    _wolfSummary             = null;
    _rabbitSummary           = null;
    _tripleCupSummary        = null;
    _multiSkinsSummary       = null;
    _nassauSummary           = null;
    _quotaNassauSummary      = null;
    _matchPlayData           = null;
    _threePersonMatchSummary = null;
    _activeFoursomeId        = null;
    _sixesStartedFoursomes.clear();
    _localPendingByHole      = {};
    _error                   = null;
  }

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
      // Pre-load the round-level Multi-Skins summary so the round screen
      // can show payout/skins running totals alongside per-foursome cards.
      if (_round!.activeGames.contains('multi_skins')) {
        loadMultiSkins(roundId); // unawaited
      } else {
        _multiSkinsSummary = null;
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
        'name':          round.course.name,
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
            'short_name':      m.player.shortName,
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
    // If we're switching to a different foursome, clear stale scorecard data
    // immediately so any in-flight build() calls don't fire _jumpToFirstUnplayed
    // with the wrong foursome's holes.  Also drop the per-game summaries
    // from the previous foursome — they're foursome-scoped, and the
    // score-entry sync-drain refresher uses "summary != null" as a
    // "keep this summary fresh" signal, which would otherwise trigger
    // 404s when the new foursome isn't configured for the same games.
    if (_activeFoursomeId != foursomeId) {
      _scorecard        = null;
      _nassauSummary    = null;
      _skinsSummary     = null;
      _tripleCupSummary = null;
      _sixesSummary     = null;
      _points531Summary = null;
      _wolfSummary      = null;
      _rabbitSummary    = null;
    }
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
  /// Persist a new round-level bet_unit.  Called from the Sixes setup
  /// screen when the user edits the bet unit inline while starting a
  /// match.  Updates the cached [round] in place on success so any other
  /// UI watching the provider sees the new value without a full reload.
  ///
  /// Returns true on success.  On failure, [error] is set and false
  /// returned (and [round] is left unchanged).
  Future<bool> updateRoundBetUnit(double betUnit) async {
    if (_round == null) {
      _error = 'No round loaded — cannot update stake.';
      notifyListeners();
      return false;
    }
    try {
      final updated = await _client.updateRound(_round!.id, betUnit: betUnit);
      _round = updated.foursomes.isNotEmpty ? updated : _round;
      _cacheRound(_round!.id, _round!);
      notifyListeners();
      return true;
    } on NetworkException {
      _error = 'No connection — cannot update stake while offline.';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  /// Persist the round-level net-double-bogey cap flag.  Fire-and-
  /// listenable from any setup screen so the SwitchListTile change
  /// reaches the server immediately and the local Round mirrors the
  /// updated value for other screens that watch the provider.
  Future<bool> updateRoundNetMaxDoubleBogey(bool value) async {
    if (_round == null) {
      _error = 'No round loaded — cannot update cap.';
      notifyListeners();
      return false;
    }
    try {
      final updated = await _client.updateRound(
        _round!.id,
        netMaxDoubleBogey: value,
      );
      _round = updated.foursomes.isNotEmpty ? updated : _round;
      _cacheRound(_round!.id, _round!);
      notifyListeners();
      return true;
    } on NetworkException {
      _error = 'No connection — cannot update cap while offline.';
      notifyListeners();
      return false;
    } catch (e) {
      _error = friendlyError(e);
      notifyListeners();
      return false;
    }
  }

  /// [segments] follows the services/sixes.py team_data format:
  ///   [ { 'start_hole', 'end_hole', 'team_select_method',
  ///       'team1_player_ids', 'team2_player_ids' }, ... ]
  ///
  /// Returns true on success.  On failure, [error] is set and false returned.
  ///
  /// [handicapMode] is 'net' (default) or 'gross'.  [netPercent] is only
  /// meaningful when handicapMode == 'net' (100 = full handicap).
  Future<bool> setupSixes(
    int foursomeId,
    List<Map<String, dynamic>> segments, {
    String handicapMode       = 'net',
    int    netPercent         = 100,
    String scoringFormat      = 'classic',
    String handicapAllocation = 'per_segment',
  }) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      await _client.postSixesSetup(
        foursomeId,
        segments,
        handicapMode:        handicapMode,
        netPercent:          netPercent,
        scoringFormat:       scoringFormat,
        handicapAllocation:  handicapAllocation,
      );
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

  /// Load the Sixes segment summary for the active foursome.
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

  /// Load the Points 5-3-1 summary for the active foursome.
  /// Same failure semantics as [loadSixes] — non-fatal, silently keeps
  /// the last known good snapshot on network errors so the entry screen
  /// keeps working offline.
  Future<void> loadPoints531(int foursomeId) async {
    _loadingPoints531 = true;
    notifyListeners();
    try {
      _points531Summary = await _client.getPoints531Summary(foursomeId);
    } on NetworkException {
      // Offline — keep the previous summary around if we had one.
    } catch (e) {
      debugPrint('loadPoints531 error: $e');
    } finally {
      _loadingPoints531 = false;
      notifyListeners();
    }
  }

  /// Load the low-net (Stroke Play) config for the active round.
  /// Needed so the score-entry screen knows the handicap mode (net / gross /
  /// strokes_off) chosen during Stroke Play setup — that value lives in the
  /// low-net config, NOT on the top-level round object.
  Future<void> loadLowNetConfig(int roundId) async {
    _loadingLowNet = true;
    notifyListeners();
    try {
      _lowNetConfig = await _client.getLowNetConfig(roundId);
    } on NetworkException {
      // Offline — keep the previous config around if we had one.
    } catch (e) {
      debugPrint('loadLowNetConfig error: $e');
    } finally {
      _loadingLowNet = false;
      notifyListeners();
    }
  }

  /// Initialise the phantom player for a foursome.
  ///
  /// Idempotent — calling repeatedly is safe; the server only randomises the
  /// rotation once (subsequent calls return the same config).  Cached locally
  /// so repeated `_loadGameSummaries` calls avoid redundant network trips if
  /// we already have a result for this foursome.
  Future<void> initPhantom(int foursomeId) async {
    if (_phantomInit.containsKey(foursomeId)) return; // already done
    try {
      final result = await _client.initPhantom(foursomeId);
      _phantomInit[foursomeId] = result;
      notifyListeners();
    } on NetworkException {
      // Offline — phantom row will show without source label.
    } catch (e) {
      debugPrint('initPhantom error: $e');
    }
  }

  /// Load the Skins summary for the active foursome.
  /// Same failure semantics as [loadPoints531] — non-fatal on network
  /// errors so the entry screen keeps working offline.
  Future<void> loadSkins(int foursomeId) async {
    _loadingSkins = true;
    notifyListeners();
    try {
      _skinsSummary = await _client.getSkinsSummary(foursomeId);
    } on NetworkException {
      // Offline — keep the previous summary around if we had one.
    } catch (e) {
      debugPrint('loadSkins error: $e');
    } finally {
      _loadingSkins = false;
      notifyListeners();
    }
  }

  /// Load the Wolf summary for the active foursome.
  /// Same failure semantics as [loadSkins] — non-fatal on network errors so
  /// the entry screen keeps working offline.
  Future<void> loadWolf(int foursomeId) async {
    _loadingWolf = true;
    notifyListeners();
    try {
      _wolfSummary = await _client.getWolfSummary(foursomeId);
    } on NetworkException {
      // Offline — keep the previous summary around if we had one.
    } catch (e) {
      debugPrint('loadWolf error: $e');
    } finally {
      _loadingWolf = false;
      notifyListeners();
    }
  }

  /// Replace the cached Wolf summary directly (e.g. after a setup/decision
  /// POST returns a fresh one) so the screen repaints without a round-trip.
  void setWolfSummary(WolfSummary summary) {
    _wolfSummary = summary;
    notifyListeners();
  }

  /// Load the Rabbit summary for the active foursome.  Non-fatal on network
  /// errors so the entry screen keeps working offline.
  Future<void> loadRabbit(int foursomeId) async {
    _loadingRabbit = true;
    notifyListeners();
    try {
      _rabbitSummary = await _client.getRabbitSummary(foursomeId);
    } on NetworkException {
      // Offline — keep the previous summary around if we had one.
    } catch (e) {
      debugPrint('loadRabbit error: $e');
    } finally {
      _loadingRabbit = false;
      notifyListeners();
    }
  }

  /// Replace the cached Rabbit summary directly (e.g. after a setup POST
  /// returns a fresh one) so the screen repaints without a round-trip.
  void setRabbitSummary(RabbitSummary summary) {
    _rabbitSummary = summary;
    notifyListeners();
  }

  /// Load the Triple Cup summary for the active foursome.  Non-fatal
  /// on network or 404 errors so the entry screen keeps working
  /// offline / before the game has been set up.
  Future<void> loadTripleCup(int foursomeId) async {
    _loadingTripleCup = true;
    notifyListeners();
    try {
      _tripleCupSummary = await _client.getTripleCupSummary(foursomeId);
    } on NetworkException {
      // Offline — keep last known summary.
    } catch (e) {
      // 404 (no game set up yet) is normal during setup; log others.
      debugPrint('loadTripleCup error: $e');
      _tripleCupSummary = null;
    } finally {
      _loadingTripleCup = false;
      notifyListeners();
    }
  }

  /// Set (or clear) the foursomes alt-shot first-tee-off player on
  /// each side.  Pass null to clear that team's pick.  Returns true
  /// on success and refreshes [tripleCupSummary].  Surfaces server
  /// errors via [error].
  Future<bool> setTripleCupFoursomesTeeOff(
    int foursomeId, {
    int? team1FirstTee,
    int? team2FirstTee,
  }) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      _tripleCupSummary = await _client.postTripleCupFoursomesTeeOff(
        foursomeId,
        team1FirstTee: team1FirstTee,
        team2FirstTee: team2FirstTee,
      );
      return true;
    } on NetworkException {
      _error = 'No connection — cannot save tee-off while offline.';
      return false;
    } catch (e) {
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// Create (or replace) the Triple Cup game for a foursome.  Returns
  /// true on success and stashes the resulting summary; on failure
  /// [error] is set and false returned.
  Future<bool> setupTripleCup(
    int foursomeId, {
    required List<int> team1Ids,
    required List<int> team2Ids,
    String handicapMode             = 'net',
    int    netPercent               = 100,
    int    altShotLowPct            = 50,
    int    altShotHighPct           = 50,
    int?   foursomesTeam1FirstTee,
    int?   foursomesTeam2FirstTee,
  }) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      _tripleCupSummary = await _client.postTripleCupSetup(
        foursomeId,
        team1Ids:                  team1Ids,
        team2Ids:                  team2Ids,
        handicapMode:              handicapMode,
        netPercent:                netPercent,
        altShotLowPct:             altShotLowPct,
        altShotHighPct:            altShotHighPct,
        foursomesTeam1FirstTee:    foursomesTeam1FirstTee,
        foursomesTeam2FirstTee:    foursomesTeam2FirstTee,
      );
      return true;
    } on NetworkException {
      _error = 'No connection — cannot save Triple Cup setup while offline.';
      return false;
    } catch (e) {
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// Load the round-level Multi-Foursome Skins summary.
  /// Non-fatal on network errors.
  Future<void> loadMultiSkins(int roundId) async {
    _loadingMultiSkins = true;
    notifyListeners();
    try {
      _multiSkinsSummary = await _client.getMultiSkinsSummary(roundId);
    } on NetworkException {
      // Offline — keep the previous summary around if we had one.
    } catch (e) {
      debugPrint('loadMultiSkins error: $e');
    } finally {
      _loadingMultiSkins = false;
      notifyListeners();
    }
  }

  // ── Nassau ─────────────────────────────────────────────────────────────────

  /// Load the Nassau summary for the active foursome.
  /// Non-fatal on network errors — keeps the last known state.
  Future<void> loadNassau(int foursomeId) async {
    _loadingNassau = true;
    notifyListeners();
    try {
      _nassauSummary = await _client.getNassauSummary(foursomeId);
    } on NetworkException {
      // Offline — keep the previous summary around.
    } catch (e, st) {
      debugPrint('loadNassau($foursomeId) ERROR: $e\n$st');
    } finally {
      _loadingNassau = false;
      notifyListeners();
    }
  }

  // ── Quota Nassau ───────────────────────────────────────────────────────────

  Future<void> loadQuotaNassau(int foursomeId) async {
    _loadingQuotaNassau = true;
    notifyListeners();
    try {
      _quotaNassauSummary = await _client.getQuotaNassauSummary(foursomeId);
    } on NetworkException {
      // Offline — keep the previous summary around.
    } catch (e) {
      debugPrint('loadQuotaNassau error: $e');
    } finally {
      _loadingQuotaNassau = false;
      notifyListeners();
    }
  }

  // ── Match Play ─────────────────────────────────────────────────────────────

  /// Load the Match Play summary for the active foursome.
  /// Non-fatal on network errors — keeps the last known state.
  Future<void> loadMatchPlay(int foursomeId) async {
    _loadingMatchPlay = true;
    notifyListeners();
    try {
      _matchPlayData = await _client.getMatchPlay(foursomeId);
    } on NetworkException {
      // Offline — keep the previous data around.
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        // Cup singles foursomes return 404 when the bracket isn't set up yet.
        // Keep _matchPlayData null; the UI handles null gracefully.
      } else {
        debugPrint('loadMatchPlay error: $e');
      }
    } catch (e, st) {
      debugPrint('loadMatchPlay error: $e\n$st');
    } finally {
      _loadingMatchPlay = false;
      notifyListeners();
    }
  }

  // ── Three-Person Match ──────────────────────────────────────────────────────

  /// Load the Three-Person Match summary for the active foursome.
  /// Non-fatal on network errors — keeps the last known state.
  Future<void> loadThreePersonMatch(int foursomeId) async {
    _loadingThreePersonMatch = true;
    notifyListeners();
    try {
      _threePersonMatchSummary = await _client.getThreePersonMatch(foursomeId);
    } on NetworkException {
      // Offline — keep the previous summary around.
    } on ApiException catch (e) {
      // 404 = no TPM bracket yet for this foursome.  Expected for new
      // rounds before setup completes; don't spam the console.
      if (e.statusCode != 404) {
        debugPrint('loadThreePersonMatch error: $e');
      }
      _threePersonMatchSummary = null;
    } catch (e) {
      debugPrint('loadThreePersonMatch error: $e');
    } finally {
      _loadingThreePersonMatch = false;
      notifyListeners();
    }
  }

  /// POST /three-person-match/setup/ — set up or replace the Three-Person Match.
  Future<bool> setupThreePersonMatch(
    int foursomeId, {
    String              handicapMode = 'net',
    int                 netPercent   = 100,
    double              entryFee     = 0.0,
    Map<String, double> payoutConfig = const {},
  }) async {
    try {
      _threePersonMatchSummary = await _client.postThreePersonMatchSetup(
        foursomeId,
        handicapMode: handicapMode,
        netPercent:   netPercent,
        entryFee:     entryFee,
        payoutConfig: payoutConfig,
      );
      notifyListeners();
      return true;
    } catch (e) {
      _error = e is ApiException ? e.message : e.toString();
      notifyListeners();
      return false;
    }
  }

  /// POST /nassau/setup/ — create or replace the Nassau game configuration.
  ///
  /// Returns true on success.  On failure, [error] is set and false returned.
  Future<bool> setupNassau(
    int foursomeId, {
    required List<int> team1Ids,
    required List<int> team2Ids,
    String handicapMode = 'net',
    int    netPercent   = 100,
    String pressMode    = 'none',
    double pressUnit    = 0.0,
    String variant      = 'none',
  }) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      _nassauSummary = await _client.postNassauSetup(
        foursomeId,
        team1Ids:     team1Ids,
        team2Ids:     team2Ids,
        handicapMode: handicapMode,
        netPercent:   netPercent,
        pressMode:    pressMode,
        pressUnit:    pressUnit,
        variant:      variant,
      );
      return true;
    } on NetworkException {
      _error = 'No connection — cannot save Nassau setup while offline.';
      return false;
    } catch (e) {
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// POST /nassau/press/ — losing team calls a manual press at [startHole].
  ///
  /// Returns true on success.  On failure (bad state, network, etc.),
  /// [error] is set and false returned.
  Future<bool> callNassauPress(int foursomeId, {required int startHole}) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      _nassauSummary = await _client.postNassauPress(
        foursomeId,
        startHole: startHole,
      );
      return true;
    } on NetworkException {
      _error = 'No connection — cannot call press while offline.';
      return false;
    } catch (e) {
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
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

  // ── Reopen round ───────────────────────────────────────────────────────────

  Future<bool> reopenRound(int roundId) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      await _client.reopenRound(roundId);
      if (_round != null && _round!.id == roundId) {
        _round = Round(
          id:          _round!.id,
          roundNumber: _round!.roundNumber,
          date:        _round!.date,
          course:      _round!.course,
          status:      'in_progress',
          activeGames: _round!.activeGames,
          betUnit:     _round!.betUnit,
          foursomes:   _round!.foursomes,
        );
      }
      if (_leaderboard != null && _leaderboard!.roundId == roundId) {
        _leaderboard = Leaderboard(
          roundId:               _leaderboard!.roundId,
          roundDate:             _leaderboard!.roundDate,
          course:                _leaderboard!.course,
          status:                'in_progress',
          isCupRound:            _leaderboard!.isCupRound,
          activeGames:           _leaderboard!.activeGames,
          games:                 _leaderboard!.games,
          tournamentId:          _leaderboard!.tournamentId,
          tournamentName:        _leaderboard!.tournamentName,
          tournamentActiveGames: _leaderboard!.tournamentActiveGames,
        );
      }
      return true;
    } on NetworkException {
      _error = 'No connection — cannot reopen round while offline.';
      return false;
    } catch (e) {
      _error = friendlyError(e);
      return false;
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
