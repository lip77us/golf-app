/// api/client.dart
/// Typed HTTP client for the Golf App Django API.
/// All methods throw ApiException on non-2xx responses.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thrown when the server returns 401 — session has expired.
class AuthException extends ApiException {
  const AuthException(String message) : super(401, message);
}

/// Thrown when the device cannot reach the server (no network, timeout, etc.).
class NetworkException extends ApiException {
  const NetworkException(String message) : super(0, message);
}

typedef SessionExpiredCallback = void Function();

class ApiClient {
  final String? token;

  /// Called once when a 401 is received. Use this to trigger a logout/redirect.
  final SessionExpiredCallback? onSessionExpired;

  static const _timeout = Duration(seconds: 10);

  const ApiClient({this.token, this.onSessionExpired});

  // ---- low-level helpers ----

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Token $token',
  };

  Future<dynamic> _get(String path) async {
    final uri = Uri.parse('${Config.baseUrl}$path');
    try {
      final res = await http.get(uri, headers: _headers).timeout(_timeout);
      return _handle(res);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const NetworkException('Request timed out. Check your connection.');
    } on SocketException {
      throw const NetworkException('No connection. Check your network.');
    } catch (e) {
      throw NetworkException('Unexpected error: $e');
    }
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('${Config.baseUrl}$path');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode(body),
      ).timeout(_timeout);
      return _handle(res);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const NetworkException('Request timed out. Check your connection.');
    } on SocketException {
      throw const NetworkException('No connection. Check your network.');
    } catch (e) {
      throw NetworkException('Unexpected error: $e');
    }
  }

  Future<dynamic> _patch(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('${Config.baseUrl}$path');
    try {
      final res = await http.patch(
        uri,
        headers: _headers,
        body: jsonEncode(body),
      ).timeout(_timeout);
      return _handle(res);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const NetworkException('Request timed out. Check your connection.');
    } on SocketException {
      throw const NetworkException('No connection. Check your network.');
    } catch (e) {
      throw NetworkException('Unexpected error: $e');
    }
  }

  dynamic _handle(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return null;
      return jsonDecode(res.body);
    }
    String message;
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      message = (body['detail'] ?? body.values.first).toString();
    } catch (_) {
      message = res.body.isNotEmpty ? res.body : 'HTTP ${res.statusCode}';
    }
    if (res.statusCode == 401) {
      onSessionExpired?.call();
      throw AuthException(message);
    }
    throw ApiException(res.statusCode, message);
  }

  // ---- Auth ----

  Future<AuthResult> login(String username, String password) async {
    final data = await _post('/auth/login/', {
      'username': username,
      'password': password,
    });
    return AuthResult.fromJson(data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    await _post('/auth/logout/', {});
  }

  Future<PlayerProfile> me() async {
    final data = await _get('/auth/me/');
    return PlayerProfile.fromJson(data as Map<String, dynamic>);
  }

  // ---- Reference data ----

  Future<List<PlayerProfile>> getPlayers() async {
    final data = await _get('/players/');
    return (data as List)
        .map((p) => PlayerProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<PlayerProfile> createPlayer({
    required String name,
    required String handicapIndex,
    String email = '',
    String phone = '',
  }) async {
    final data = await _post('/players/', {
      'name': name,
      'handicap_index': handicapIndex,
      if (email.isNotEmpty) 'email': email,
      if (phone.isNotEmpty) 'phone': phone,
    });
    return PlayerProfile.fromJson(data as Map<String, dynamic>);
  }

  Future<PlayerProfile> updatePlayer(
    int id, {
    String? name,
    String? handicapIndex,
    String? email,
    String? phone,
  }) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (handicapIndex != null) 'handicap_index': handicapIndex,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
    };
    final data = await _patch('/players/$id/', body);
    return PlayerProfile.fromJson(data as Map<String, dynamic>);
  }

  Future<List<TeeInfo>> getTees() async {
    final data = await _get('/tees/');
    return (data as List)
        .map((t) => TeeInfo.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  // ---- Tournaments ----

  Future<List<Tournament>> getTournaments() async {
    final data = await _get('/tournaments/');
    return (data as List)
        .map((t) => Tournament.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  Future<Tournament> getTournament(int id) async {
    final data = await _get('/tournaments/$id/');
    return Tournament.fromJson(data as Map<String, dynamic>);
  }

  Future<Tournament> createTournament({
    required String name,
    required String startDate,   // 'YYYY-MM-DD'
    List<String> activeGames = const [],
    int totalRounds = 1,
  }) async {
    final data = await _post('/tournaments/', {
      'name'         : name,
      'start_date'   : startDate,
      'active_games' : activeGames,
      'total_rounds' : totalRounds,
    });
    return Tournament.fromJson(data as Map<String, dynamic>);
  }

  // ---- Rounds ----

  Future<Round> getRound(int id) async {
    final data = await _get('/rounds/$id/');
    return Round.fromJson(data as Map<String, dynamic>);
  }

  Future<Round> createRound({
    int? tournamentId,
    required int teeId,
    required String date,          // 'YYYY-MM-DD'
    double betUnit = 1.0,
    List<String> activeGames = const [],
    int roundNumber = 1,
  }) async {
    final data = await _post('/rounds/', {
      'tee_id'       : teeId,
      'date'         : date,
      'bet_unit'     : betUnit,
      'active_games' : activeGames,
      'round_number' : roundNumber,
      if (tournamentId != null) 'tournament_id': tournamentId,
    });
    return Round.fromJson(data as Map<String, dynamic>);
  }

  Future<Round> setupRound(
    int roundId, {
    required List<int> playerIds,
    double handicapAllowance = 1.0,
    bool randomise = true,
    bool autoSetupGames = false,
  }) async {
    final data = await _post('/rounds/$roundId/setup/', {
      'player_ids'        : playerIds,
      'handicap_allowance': handicapAllowance,
      'randomise'         : randomise,
      'auto_setup_games'  : autoSetupGames,
    });
    return Round.fromJson(data as Map<String, dynamic>);
  }

  Future<Leaderboard> completeRound(int roundId) async {
    final data = await _post('/rounds/$roundId/complete/', {});
    return Leaderboard.fromJson(data as Map<String, dynamic>);
  }

  // ---- Foursomes ----

  Future<Foursome> getFoursome(int id) async {
    final data = await _get('/foursomes/$id/');
    return Foursome.fromJson(data as Map<String, dynamic>);
  }

  // ---- Scorecard ----

  Future<Scorecard> getScorecard(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/scorecard/');
    return Scorecard.fromJson(data as Map<String, dynamic>);
  }

  /// Submit scores for all players on one hole.
  /// Returns updated {scorecard, leaderboard}.
  Future<Map<String, dynamic>> submitScores({
    required int foursomeId,
    required int holeNumber,
    required List<Map<String, int>> scores, // [{player_id, gross_score}, ...]
    bool pinkBallLost = false,
  }) async {
    final data = await _post('/foursomes/$foursomeId/scores/', {
      'hole_number': holeNumber,
      'scores': scores,
      'pink_ball_lost': pinkBallLost,
    });
    return data as Map<String, dynamic>;
  }

  // ---- Leaderboard ----

  Future<Leaderboard> getLeaderboard(int roundId) async {
    final data = await _get('/rounds/$roundId/leaderboard/');
    return Leaderboard.fromJson(data as Map<String, dynamic>);
  }

  // ---- Nassau ----

  Future<void> setupNassau(
    int foursomeId, {
    required List<int> team1Ids,
    required List<int> team2Ids,
    double pressPct = 0.5,
  }) async {
    await _post('/foursomes/$foursomeId/nassau/setup/', {
      'team1_player_ids': team1Ids,
      'team2_player_ids': team2Ids,
      'press_pct': pressPct,
    });
  }

  Future<Map<String, dynamic>> getNassau(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/nassau/');
    return data as Map<String, dynamic>;
  }

  // ---- Six's ----

  Future<Map<String, dynamic>> getSixes(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/sixes/');
    return data as Map<String, dynamic>;
  }

  Future<SixesSummary> getSixesSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/sixes/');
    return SixesSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/sixes/setup/
  ///
  /// [segments] is a list of segment dicts, each with:
  ///   start_hole, end_hole, team_select_method,
  ///   team1_player_ids, team2_player_ids
  Future<void> postSixesSetup(
    int foursomeId,
    List<Map<String, dynamic>> segments,
  ) async {
    await _post('/foursomes/$foursomeId/sixes/setup/', {'segments': segments});
  }

  /// POST /api/foursomes/{id}/sixes/extra-teams/
  ///
  /// Sets teams on the existing is_extra=True segment without disturbing any
  /// standard segments or hole results.  Returns the updated SixesSummary.
  Future<SixesSummary> postSixesExtraTeams(
    int foursomeId,
    List<int> team1Ids,
    List<int> team2Ids,
  ) async {
    final data = await _post(
      '/foursomes/$foursomeId/sixes/extra-teams/',
      {'team1_player_ids': team1Ids, 'team2_player_ids': team2Ids},
    );
    return SixesSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Match Play ----

  Future<Map<String, dynamic>> getMatchPlay(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/match-play/');
    return data as Map<String, dynamic>;
  }
}
