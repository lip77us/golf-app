/// providers/round_provider.dart
/// Manages the active round, scorecard for a selected foursome,
/// and leaderboard. One instance lives for the duration of a round session.

import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../widgets/error_view.dart';

class RoundProvider extends ChangeNotifier {
  ApiClient _client;

  RoundProvider(this._client);

  /// Called by ProxyProvider when the auth token changes (login/logout).
  void updateClient(ApiClient client) {
    _client = client;
  }

  Round?      _round;
  Scorecard?  _scorecard;
  Leaderboard? _leaderboard;
  int?        _activeFoursomeId;

  bool    _loadingRound       = false;
  bool    _loadingScorecard   = false;
  bool    _loadingLeaderboard = false;
  bool    _submitting         = false;
  String? _error;

  Round?       get round       => _round;
  Scorecard?   get scorecard   => _scorecard;
  Leaderboard? get leaderboard => _leaderboard;
  int?         get activeFoursomeId => _activeFoursomeId;
  bool         get loadingRound       => _loadingRound;
  bool         get loadingScorecard   => _loadingScorecard;
  bool         get loadingLeaderboard => _loadingLeaderboard;
  bool         get submitting         => _submitting;
  String?      get error              => _error;

  void _clearError() { _error = null; }

  // ---- Round ----

  Future<void> loadRound(int roundId) async {
    _loadingRound = true;
    _clearError();
    notifyListeners();
    try {
      _round = await _client.getRound(roundId);
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      _loadingRound = false;
      notifyListeners();
    }
  }

  // ---- Scorecard ----

  Future<void> loadScorecard(int foursomeId) async {
    _activeFoursomeId = foursomeId;
    _loadingScorecard = true;
    _clearError();
    notifyListeners();
    try {
      _scorecard = await _client.getScorecard(foursomeId);
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      _loadingScorecard = false;
      notifyListeners();
    }
  }

  /// Submit scores for all players on one hole.
  /// On success, updates both scorecard and leaderboard from the response.
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
      final result = await _client.submitScores(
        foursomeId: foursomeId,
        holeNumber: holeNumber,
        scores: scores,
        pinkBallLost: pinkBallLost,
      );

      if (result['scorecard'] != null) {
        _scorecard = Scorecard.fromJson(
          result['scorecard'] as Map<String, dynamic>
        );
      }
      if (result['leaderboard'] != null) {
        _leaderboard = Leaderboard.fromJson(
          result['leaderboard'] as Map<String, dynamic>
        );
      }
      return true;
    } catch (e) {
      _error = friendlyError(e);
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  // ---- Leaderboard ----

  Future<void> loadLeaderboard(int roundId) async {
    _loadingLeaderboard = true;
    _clearError();
    notifyListeners();
    try {
      _leaderboard = await _client.getLeaderboard(roundId);
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      _loadingLeaderboard = false;
      notifyListeners();
    }
  }

  // ---- Complete round ----

  /// Marks the round complete on the server. Returns the final leaderboard
  /// on success (null on error). Also updates _round.status locally.
  Future<Leaderboard?> completeRound(int roundId) async {
    _submitting = true;
    _clearError();
    notifyListeners();
    try {
      final lb = await _client.completeRound(roundId);
      _leaderboard = lb;
      // Reflect the status change locally without a full reload
      if (_round != null) {
        _round = Round(
          id: _round!.id,
          roundNumber: _round!.roundNumber,
          date: _round!.date,
          course: _round!.course,
          status: 'complete',
          activeGames: _round!.activeGames,
          betUnit: _round!.betUnit,
          foursomes: _round!.foursomes,
        );
      }
      return lb;
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
