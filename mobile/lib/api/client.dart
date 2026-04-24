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

  // 30 s is generous but necessary: a cold Django dev server (or a just-
  // restarted autoreloader) can take well over 10 s to respond to the
  // first request after startup.  A too-tight timeout here causes the
  // client to give up before the server replies, even though the server
  // ultimately returns 200 — which looked like a "login failed, try
  // again" bug from the user's perspective.
  static const _timeout = Duration(seconds: 30);

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
      throw const NetworkException(
          'Server is taking too long to respond. Please try again.');
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
      throw const NetworkException(
          'Server is taking too long to respond. Please try again.');
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
      throw const NetworkException(
          'Server is taking too long to respond. Please try again.');
    } on SocketException {
      throw const NetworkException('No connection. Check your network.');
    } catch (e) {
      throw NetworkException('Unexpected error: $e');
    }
  }

  Future<void> _delete(String path) async {
    final uri = Uri.parse('${Config.baseUrl}$path');
    try {
      final res =
          await http.delete(uri, headers: _headers).timeout(_timeout);
      _handle(res);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const NetworkException(
          'Server is taking too long to respond. Please try again.');
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

  Future<MeResult> me() async {
    final data = await _get('/auth/me/');
    return MeResult.fromJson(data as Map<String, dynamic>);
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
    String sex = 'M',
    // Optional 5-char display label.  Omitted → server auto-fills from
    // initials.  Empty-string is also safe (server treats it as blank).
    String? shortName,
    // Optional login credentials — when provided the server creates a
    // linked Django User so the player can log in to the mobile app.
    String? username,
    String? password,
  }) async {
    final data = await _post('/players/', {
      'name': name,
      'handicap_index': handicapIndex,
      'sex': sex,
      if (shortName != null && shortName.isNotEmpty) 'short_name': shortName,
      if (email.isNotEmpty) 'email': email,
      if (phone.isNotEmpty) 'phone': phone,
      if (username != null && username.isNotEmpty) 'username': username,
      if (password != null && password.isNotEmpty) 'password': password,
    });
    return PlayerProfile.fromJson(data as Map<String, dynamic>);
  }

  Future<PlayerProfile> updatePlayer(
    int id, {
    String? name,
    String? handicapIndex,
    String? email,
    String? phone,
    String? sex,
    // Pass a non-null value to update short_name.  Empty string clears
    // it on the server (which then re-derives from initials on save).
    String? shortName,
  }) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (handicapIndex != null) 'handicap_index': handicapIndex,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
      if (sex != null) 'sex': sex,
      if (shortName != null) 'short_name': shortName,
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

  Future<void> deleteTournament(int id) async {
    await _delete('/tournaments/$id/');
  }

  // ---- Rounds ----

  Future<Round> getRound(int id) async {
    final data = await _get('/rounds/$id/');
    return Round.fromJson(data as Map<String, dynamic>);
  }

  /// Casual rounds the authenticated user is part of.
  /// [status] is 'in_progress' (default) or 'complete'.
  Future<List<CasualRoundSummary>> getCasualRounds({
    String status = 'in_progress',
  }) async {
    final data = await _get('/rounds/casual/?status=$status');
    return (data as List)
        .map((r) => CasualRoundSummary.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Permanently delete a casual round.  Only the creator may call this;
  /// the server returns 403 for anyone else.
  Future<void> deleteCasualRound(int roundId) async {
    final uri = Uri.parse('${Config.baseUrl}/rounds/$roundId/');
    try {
      final res = await http.delete(uri, headers: _headers).timeout(_timeout);
      if (res.statusCode == 204) return;
      _handle(res); // throws ApiException for non-2xx
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const NetworkException('Server is taking too long to respond. Please try again.');
    } on SocketException {
      throw const NetworkException('No connection. Check your network.');
    } catch (e) {
      throw NetworkException('Unexpected error: $e');
    }
  }

  Future<List<CourseInfo>> getCourses() async {
    // Reusing the tees endpoint but returning courses might be tricky if we don't have a dedicated endpoint.
    // However, since TeeInfo embeds CourseInfo, we can extract them if needed, or better, we can assume a `/courses/` endpoint.
    final data = await _get('/courses/');
    return (data as List)
        .map((c) => CourseInfo.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<Round> createRound({
    int? tournamentId,
    required int courseId,
    required String date,          // 'YYYY-MM-DD'
    List<String> activeGames = const [],
    int roundNumber = 1,
    String handicapMode = 'net',
    int netPercent = 100,
  }) async {
    final data = await _post('/rounds/', {
      'course_id'     : courseId,
      'date'          : date,
      'active_games'  : activeGames,
      'round_number'  : roundNumber,
      'handicap_mode' : handicapMode,
      'net_percent'   : netPercent,
      if (tournamentId != null) 'tournament_id': tournamentId,
    });
    return Round.fromJson(data as Map<String, dynamic>);
  }

  /// Partial update of a round.  Currently only `bet_unit` is wired
  /// through, used by the Sixes setup screen so the user can adjust the
  /// round-level bet unit without leaving the match setup flow.  Adding
  /// more fields just means passing them in the map.
  Future<Round> updateRound(int roundId, {double? betUnit}) async {
    final body = <String, dynamic>{};
    if (betUnit != null) body['bet_unit'] = betUnit;
    final data = await _patch('/rounds/$roundId/', body);
    return Round.fromJson(data as Map<String, dynamic>);
  }

  Future<Round> setupRound(
    int roundId, {
    required List<Map<String, int>> players, // [{"player_id": 1, "tee_id": 2}]
    double handicapAllowance = 1.0,
    bool randomise = true,
    bool autoSetupGames = false,
  }) async {
    final data = await _post('/rounds/$roundId/setup/', {
      'players'            : players,
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

  /// GET /api/foursomes/{id}/nassau/
  Future<NassauSummary> getNassauSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/nassau/');
    return NassauSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/nassau/setup/
  ///
  /// Creates (or replaces) the NassauGame.  Returns the full summary
  /// so the caller doesn't need a second GET.
  Future<NassauSummary> postNassauSetup(
    int foursomeId, {
    required List<int> team1Ids,
    required List<int> team2Ids,
    String handicapMode = 'net',
    int    netPercent   = 100,
    String pressMode    = 'none',
    double pressUnit    = 0.0,
  }) async {
    final data = await _post('/foursomes/$foursomeId/nassau/setup/', {
      'team1_player_ids': team1Ids,
      'team2_player_ids': team2Ids,
      'handicap_mode'   : handicapMode,
      'net_percent'     : netPercent,
      'press_mode'      : pressMode,
      'press_unit'      : pressUnit,
    });
    return NassauSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/nassau/press/
  ///
  /// Losing team calls a manual press starting at [startHole].
  /// The winning team always accepts.  Returns the updated summary.
  Future<NassauSummary> postNassauPress(
    int foursomeId, {
    required int startHole,
  }) async {
    final data = await _post('/foursomes/$foursomeId/nassau/press/', {
      'start_hole': startHole,
    });
    return NassauSummary.fromJson(data as Map<String, dynamic>);
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
  ///
  /// [handicapMode] is 'net' (default) or 'gross'.  [netPercent] is
  /// only meaningful when handicapMode == 'net' (100 = full handicap,
  /// 90 = 90% allowance, etc.).
  Future<void> postSixesSetup(
    int foursomeId,
    List<Map<String, dynamic>> segments, {
    String handicapMode = 'net',
    int    netPercent   = 100,
  }) async {
    await _post('/foursomes/$foursomeId/sixes/setup/', {
      'segments'     : segments,
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
    });
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

  // ---- Points 5-3-1 ----

  /// GET /api/foursomes/{id}/points_531/
  ///
  /// Returns the full Points 5-3-1 summary as a raw map so screens can
  /// parse it via [Points531Summary.fromJson].  Unlike Sixes there is
  /// no extra-teams endpoint because Points 5-3-1 has no teams.
  Future<Map<String, dynamic>> getPoints531(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/points_531/');
    return data as Map<String, dynamic>;
  }

  Future<Points531Summary> getPoints531Summary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/points_531/');
    return Points531Summary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/points_531/setup/
  ///
  /// Create (or replace) the Points 5-3-1 game for this foursome.
  /// [handicapMode] is 'net' | 'gross' | 'strokes_off'; [netPercent]
  /// is only applied when handicapMode == 'net'.  Returns the fresh
  /// summary so the caller doesn't need a second GET.
  Future<Points531Summary> postPoints531Setup(
    int foursomeId, {
    String handicapMode = 'net',
    int    netPercent   = 100,
  }) async {
    final data = await _post('/foursomes/$foursomeId/points_531/setup/', {
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
    });
    return Points531Summary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Skins ----

  /// GET /api/foursomes/{id}/skins/
  Future<SkinsSummary> getSkinsSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/skins/');
    return SkinsSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/skins/setup/
  Future<SkinsSummary> postSkinsSetup(
    int foursomeId, {
    String handicapMode = 'net',
    int    netPercent   = 100,
    bool   carryover    = true,
    bool   allowJunk    = false,
  }) async {
    final data = await _post('/foursomes/$foursomeId/skins/setup/', {
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
      'carryover'    : carryover,
      'allow_junk'   : allowJunk,
    });
    return SkinsSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/skins/junk/
  ///
  /// Upserts junk-skin counts for all players on [holeNumber].
  /// [junkEntries] is a list of {player_id, junk_count} maps.
  /// Returns the updated SkinsSummary.
  Future<SkinsSummary> postSkinsJunk(
    int foursomeId, {
    required int                       holeNumber,
    required List<Map<String, int>>    junkEntries,
  }) async {
    final data = await _post('/foursomes/$foursomeId/skins/junk/', {
      'hole_number' : holeNumber,
      'junk_entries': junkEntries,
    });
    return SkinsSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Match Play ----

  Future<Map<String, dynamic>> getMatchPlay(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/match-play/');
    return data as Map<String, dynamic>;
  }

  // ---- Irish Rumble setup (round-level) ----

  Future<Map<String, dynamic>> getIrishRumbleConfig(int roundId) async {
    final data = await _get('/rounds/$roundId/irish-rumble/setup/');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postIrishRumbleSetup(
    int roundId, {
    required String handicapMode,
    required int    netPercent,
    required double betUnit,
  }) async {
    final data = await _post('/rounds/$roundId/irish-rumble/setup/', {
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
      'bet_unit'     : betUnit.toStringAsFixed(2),
    });
    return data as Map<String, dynamic>;
  }

  // ---- Low Net setup (round-level) ----

  Future<Map<String, dynamic>> getLowNetConfig(int roundId) async {
    final data = await _get('/rounds/$roundId/low-net/setup/');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postLowNetSetup(
    int roundId, {
    required String                   handicapMode,
    required int                      netPercent,
    required double                   entryFee,
    required List<Map<String, dynamic>> payouts,
  }) async {
    final data = await _post('/rounds/$roundId/low-net/setup/', {
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
      'entry_fee'    : entryFee.toStringAsFixed(2),
      'payouts'      : payouts,
    });
    return data as Map<String, dynamic>;
  }

  // ---- Pink Ball setup (round-level) ----

  Future<Map<String, dynamic>> getPinkBallSetup(int roundId) async {
    final data = await _get('/rounds/$roundId/pink-ball/setup/');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postPinkBallSetup(
    int roundId, {
    required String ballColor,
    required double betUnit,
    int placesPaid = 1,
  }) async {
    final data = await _post('/rounds/$roundId/pink-ball/setup/', {
      'ball_color'  : ballColor,
      'bet_unit'    : betUnit.toStringAsFixed(2),
      'places_paid' : placesPaid,
    });
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postPinkBallOrder(
    int foursomeId, {
    required List<int> order,
  }) async {
    final data = await _post('/foursomes/$foursomeId/pink-ball/order/', {
      'order': order,
    });
    return data as Map<String, dynamic>;
  }
}
