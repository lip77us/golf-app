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
      // Non-JSON body — most commonly Django's HTML debug page in dev mode
      // (DEBUG=True returns a several-thousand-line stacktrace).  Dumping
      // that into the user-facing error overflowed the screen by 15k
      // pixels.  Treat anything that smells like HTML as opaque; for short
      // plain-text bodies, keep them since they're often useful.
      final body = res.body.trim();
      final looksLikeHtml = body.startsWith('<') ||
          body.toLowerCase().contains('<!doctype html');
      if (body.isEmpty || looksLikeHtml) {
        message = 'Server error (HTTP ${res.statusCode}). '
            'Check the server log for details.';
      } else if (body.length > 240) {
        message = '${body.substring(0, 240)}…';
      } else {
        message = body;
      }
    }
    if (res.statusCode == 401) {
      onSessionExpired?.call();
      throw AuthException(message);
    }
    throw ApiException(res.statusCode, message);
  }

  // ---- Version check ----

  /// Fetches the server's version info.  No auth token required.
  /// Returns a map with keys: server_version, min_client_version.
  Future<Map<String, dynamic>> getVersion() async {
    final data = await _get('/version/');
    return data as Map<String, dynamic>;
  }

  // ---- Auth ----

  Future<AuthResult> login({
    required String accountName,
    required String username,
    required String password,
  }) async {
    final data = await _post('/auth/login/', {
      'account_name': accountName,
      'username':     username,
      'password':     password,
    });
    return AuthResult.fromJson(data as Map<String, dynamic>);
  }

  /// Phone-first login step 1: request an SMS one-time passcode.
  /// Returns the server's `debug_code` (only present in dev/DEBUG) so the
  /// flow can be completed without a real SMS provider; null in production.
  Future<String?> requestOtp({required String phone}) async {
    final data = await _post('/auth/otp/request/', {'phone': phone});
    return (data as Map<String, dynamic>)['debug_code'] as String?;
  }

  /// Phone-first login step 2: verify the passcode.  An unknown phone
  /// self-creates an account (`AuthResult.isNewAccount == true`).  `name`
  /// seeds the new account/player and is ignored for an existing phone.
  Future<AuthResult> verifyOtp({
    required String phone,
    required String code,
    String? name,
  }) async {
    final data = await _post('/auth/otp/verify/', {
      'phone': phone,
      'code':  code,
      if (name != null) 'name': name,
    });
    return AuthResult.fromJson(data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    await _post('/auth/logout/', {});
  }

  /// Self-service account deletion (App Store Guideline 5.1.1(v)).
  /// Deletes the caller's login and anonymizes their player profile,
  /// keeping shared golf history.  Throws [ApiException] if the caller
  /// is the only admin of an account that still has other members.
  Future<void> deleteMyAccount() async {
    await _delete('/auth/delete-account/');
  }

  // ---- Account-member management ----

  Future<List<Member>> getAccountMembers() async {
    final data = await _get('/account/members/');
    return (data as List)
        .map((m) => Member.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  Future<Member> createAccountMember({
    required String username,
    required String password,
    String email     = '',
    String firstName = '',
    String lastName  = '',
    bool   isAccountAdmin = false,
  }) async {
    final data = await _post('/account/members/', {
      'username':         username,
      'password':         password,
      'email':            email,
      'first_name':       firstName,
      'last_name':        lastName,
      'is_account_admin': isAccountAdmin,
    });
    return Member.fromJson(data as Map<String, dynamic>);
  }

  /// PATCH /api/account/members/{id}/.  Pass only the fields you want
  /// to change — omitted fields are left alone server-side.  Pass
  /// `password` (≥8 chars) to reset; omit to leave the hash alone.
  Future<Member> updateAccountMember(
    int memberId, {
    String? email,
    String? firstName,
    String? lastName,
    bool?   isAccountAdmin,
    bool?   isActive,
    String? password,
  }) async {
    final body = <String, dynamic>{};
    if (email          != null) body['email']            = email;
    if (firstName      != null) body['first_name']       = firstName;
    if (lastName       != null) body['last_name']        = lastName;
    if (isAccountAdmin != null) body['is_account_admin'] = isAccountAdmin;
    if (isActive       != null) body['is_active']        = isActive;
    if (password       != null) body['password']         = password;
    final data = await _patch('/account/members/$memberId/', body);
    return Member.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteAccountMember(int memberId) async {
    await _delete('/account/members/$memberId/');
  }

  Future<MeResult> me() async {
    final data = await _get('/auth/me/');
    return MeResult.fromJson(data as Map<String, dynamic>);
  }

  /// The caller's personal invite link + share text (Friends Phase 1).
  Future<InviteInfo> getInvite() async {
    final data = await _get('/invite/');
    return InviteInfo.fromJson(data as Map<String, dynamic>);
  }

  /// Submit a "suggest a new game" note. Stored server-side for review.
  Future<void> submitGameSuggestion({
    String gameName = '',
    String numPlayers = '',
    String numRounds = '',
    String holeScoring = '',
    String betting = '',
    String notes = '',
    String contactEmail = '',
  }) async {
    await _post('/game-suggestions/', {
      'game_name':    gameName,
      'num_players':  numPlayers,
      'num_rounds':   numRounds,
      'hole_scoring': holeScoring,
      'betting':      betting,
      'notes':        notes,
      'contact_email': contactEmail,
    });
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
    // Choose one path for the linked login:
    //   * `userId`               — link to an existing account member.
    //   * `username` + `password` — create a brand-new member.
    //   * none of the above       — Player has no linked login.
    // Passing both userId and username/password is rejected by the API.
    int?    userId,
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
      if (userId != null) 'user_id': userId,
      if (username != null && username.isNotEmpty) 'username': username,
      if (password != null && password.isNotEmpty) 'password': password,
    });
    return PlayerProfile.fromJson(data as Map<String, dynamic>);
  }

  /// DELETE /api/players/{id}/.  Admin-only.  Returns 400 if the
  /// player has played in any rounds (FoursomeMembership / HoleScore
  /// FKs are PROTECT) — surface the API's `detail` message to the
  /// user in that case.
  Future<void> deletePlayer(int id) async {
    await _delete('/players/$id/');
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
    // Member-link rebinding:
    //   userId != null         → link this Player to that member.
    //   unlinkUser = true      → clear the existing link.
    //   neither (the default)  → leave the link unchanged.
    int?    userId,
    bool    unlinkUser = false,
    // Home course:
    //   homeCourseId != null   → set this golfer's home course.
    //   clearHomeCourse = true  → clear it.
    //   neither (the default)   → leave it unchanged.
    int?    homeCourseId,
    bool    clearHomeCourse = false,
  }) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (handicapIndex != null) 'handicap_index': handicapIndex,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
      if (sex != null) 'sex': sex,
      if (shortName != null) 'short_name': shortName,
      if (unlinkUser) 'user_id': null
      else if (userId != null) 'user_id': userId,
      if (clearHomeCourse) 'home_course_id': null
      else if (homeCourseId != null) 'home_course_id': homeCourseId,
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

  /// Resolve a universal watch link's token → the round/tournament to open
  /// (and record the caller as a watcher). Used by the deep-link handler when
  /// the app is opened via https://halved.golf/watch/<token>/.
  Future<Map<String, dynamic>> resolveWatchToken(String token) async {
    final data = await _get('/watch/$token/resolve/');
    return data as Map<String, dynamic>;
  }

  /// Tees available at a foursome's COURSE (for the tee-box editor). Sourced
  /// from the round's course, not the viewer's account — so a cross-account
  /// scorer (TD or designated scorer) gets the right options.
  Future<List<TeeInfo>> getFoursomeCourseTees(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/tees/');
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

  Future<Map<String, dynamic>> getTournamentLeaderboard(int tournamentId, {int? roundId}) async {
    final query = roundId != null ? '?round_id=$roundId' : '';
    final data = await _get('/tournaments/$tournamentId/leaderboard/$query');
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> getTournamentCupStandings(int tournamentId) async {
    final data = await _get('/tournaments/$tournamentId/cup-standings/');
    return Map<String, dynamic>.from(data as Map);
  }

  /// Live cup standings for a specific round (Irish Rumble + Nassau + Singles).
  Future<Map<String, dynamic>> getCupRoundLiveSummary(int roundId) async {
    final data = await _get('/rounds/$roundId/cup-live/');
    return Map<String, dynamic>.from(data as Map);
  }

  Future<LowNetChampionshipSetup> getTournamentLowNetSetup(int tournamentId) async {
    final data = await _get('/tournaments/$tournamentId/low-net/setup/');
    return LowNetChampionshipSetup.fromJson(data as Map<String, dynamic>);
  }

  Future<LowNetChampionshipSetup> postTournamentLowNetSetup(
      int tournamentId, LowNetChampionshipSetup setup) async {
    final data = await _post(
        '/tournaments/$tournamentId/low-net/setup/', setup.toJson());
    return LowNetChampionshipSetup.fromJson(data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> getTournamentStablefordSetup(int tournamentId) async {
    final data = await _get('/tournaments/$tournamentId/stableford/setup/');
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> postTournamentStablefordSetup(
    int tournamentId, {
    required String                     handicapMode,
    required int                        netPercent,
    required double                     entryFee,
    required List<Map<String, dynamic>> payouts,
    required Map<String, int>           pointsTable,
  }) async {
    final data = await _post('/tournaments/$tournamentId/stableford/setup/', {
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
      'entry_fee'    : entryFee.toStringAsFixed(2),
      'payouts'      : payouts,
      'pts_albatross': pointsTable['albatross'],
      'pts_eagle'    : pointsTable['eagle'],
      'pts_birdie'   : pointsTable['birdie'],
      'pts_par'      : pointsTable['par'],
      'pts_bogey'    : pointsTable['bogey'],
      'pts_double'   : pointsTable['double'],
    });
    return Map<String, dynamic>.from(data as Map);
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

  /// Read-only cross-account history: rounds in OTHER accounts a friend added
  /// your (phone-matched) player to. [status] optional ('' = all).
  Future<List<SharedRoundSummary>> getSharedRounds({String status = ''}) async {
    final q = status.isEmpty ? '' : '?status=$status';
    final data = await _get('/rounds/shared-with-me/$q');
    return (data as List)
        .map((r) => SharedRoundSummary.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Rounds (in other accounts) a TD designated me to score (Friends Phase 2b).
  Future<List<ScoringRound>> getScoringForMe() async {
    final data = await _get('/rounds/scoring-for-me/');
    return (data as List)
        .map((r) => ScoringRound.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  // ---- Round message feed (chat + server events) ----

  /// Fetch the round's message thread. Pass [since] (the highest message id you
  /// already have) for an incremental catch-up; omit/0 for the full thread.
  /// Returns the page plus the caller's unread count and own player id.
  Future<RoundMessagesResult> getMessages(int roundId, {int since = 0}) async {
    final q = since > 0 ? '?since=$since' : '';
    final data = await _get('/rounds/$roundId/messages/$q');
    return RoundMessagesResult.fromJson((data as Map).cast<String, dynamic>());
  }

  /// Post a human chat message to the round thread. Returns the created message
  /// (the server also auto-advances the poster's read marker).
  Future<ChatMessage> postMessage(int roundId, String body) async {
    final data = await _post('/rounds/$roundId/messages/', {'body': body});
    return ChatMessage.fromJson((data as Map).cast<String, dynamic>());
  }

  /// Advance the caller's read marker to [lastSeenId]; returns the new unread
  /// count.
  Future<int> markMessagesRead(int roundId, int lastSeenId) async {
    final data = await _post(
        '/rounds/$roundId/messages/read/', {'last_seen_id': lastSeenId});
    return (data as Map)['unread'] as int? ?? 0;
  }

  /// Support staff only: resolve a round by watch token, /watch/ URL, or numeric
  /// id for READ-ONLY review. Returns a summary {round_id, account_name, …};
  /// the lookup is audited server-side. Throws on 403 (not support) / 404.
  Future<Map<String, dynamic>> supportLookupRound(String query) async {
    final data = await _get(
        '/support/round/?q=${Uri.encodeQueryComponent(query.trim())}');
    return (data as Map).cast<String, dynamic>();
  }

  /// Multi-foursome rounds (tournaments / multi-group skins) in OTHER accounts
  /// that a friend/TD added me to — I can open these to score my own group and
  /// read the whole-field leaderboard (no scorer designation needed).
  Future<List<ScoringRound>> getPlayingForMe() async {
    final data = await _get('/rounds/playing-for-me/');
    return (data as List)
        .map((r) => ScoringRound.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Called when I open a shared round: idempotently mirrors it into my account
  /// (participant → TD + course; watcher → the person who invited me). Safe to
  /// call on every open.
  Future<void> joinRound(int roundId) async {
    await _post('/rounds/$roundId/join/', {});
  }

  /// Called when I open a shared tournament I'm watching — adds the person who
  /// invited me to My Golfers. Idempotent.
  Future<void> joinTournament(int tournamentId) async {
    await _post('/tournaments/$tournamentId/join/', {});
  }

  /// Register this device's push (FCM) token for the current user.
  Future<void> registerDevice(String token, String platform) async {
    await _post('/devices/register/', {'token': token, 'platform': platform});
  }

  /// Drop this device's push token (on logout).
  Future<void> unregisterDevice(String token) async {
    await _post('/devices/unregister/', {'token': token});
  }

  /// Look up a registered Halved member by phone number (no browsable
  /// directory). Returns {found, name, short_name, sex, handicap_index}.
  Future<Map<String, dynamic>> lookupHalvedUser(String phone) async {
    final data = await _get(
        '/halved-users/lookup/?phone=${Uri.encodeQueryComponent(phone)}');
    return (data as Map).cast<String, dynamic>();
  }

  /// My Golfers eligible to invite as watchers of a round/tournament —
  /// excludes anyone already playing in it.
  Future<List<PlayerProfile>> getRoundWatcherCandidates(int roundId) async {
    final data = await _get('/rounds/$roundId/watcher-candidates/');
    return (data as List)
        .map((p) => PlayerProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<List<PlayerProfile>> getTournamentWatcherCandidates(
      int tournamentId) async {
    final data = await _get('/tournaments/$tournamentId/watcher-candidates/');
    return (data as List)
        .map((p) => PlayerProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  /// Invite a non-playing watcher to a round (by roster golfer or raw phone).
  /// Returns the response, incl. `is_on_app` — true when the watcher already
  /// has Halved (so the caller can skip the download-link share for them).
  Future<Map<String, dynamic>> addRoundWatcher(int roundId,
      {int? playerId, String? phone, String? name}) async {
    final data = await _post('/rounds/$roundId/watchers/', {
      if (playerId != null) 'player_id': playerId,
      if (phone != null) 'phone': phone,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    return (data as Map).cast<String, dynamic>();
  }

  /// Invite a non-playing watcher to a whole tournament. Returns the response
  /// (incl. `is_on_app`).
  Future<Map<String, dynamic>> addTournamentWatcher(int tournamentId,
      {int? playerId, String? phone, String? name}) async {
    final data = await _post('/tournaments/$tournamentId/watchers/', {
      if (playerId != null) 'player_id': playerId,
      if (phone != null) 'phone': phone,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    return (data as Map).cast<String, dynamic>();
  }

  /// TD designates (or clears) a foursome member as its scorer.
  Future<void> setFoursomeScorer(int foursomeId, int playerId,
      {bool isScorer = true}) async {
    await _post('/foursomes/$foursomeId/scorer/',
        {'player_id': playerId, 'is_scorer': isScorer});
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
    final data = await _get('/courses/');
    return (data as List)
        .map((c) => CourseInfo.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// The account's most recently played distinct courses (up to 3, newest
  /// first). Drives the course picker's recents quick-pick. Empty for a brand
  /// new account with no rounds.
  Future<List<CourseInfo>> getRecentCourses() async {
    final data = await _get('/courses/recent/');
    return (data as List)
        .map((c) => CourseInfo.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Search the shared course catalog (deduped across accounts). Fast + free —
  /// no GolfCourseAPI call. Includes courses any account has imported.
  Future<List<CatalogCourse>> searchCatalog(String query) async {
    final data = await _get(
      '/catalog/courses/?q=${Uri.encodeComponent(query)}',
    );
    final list = (data as Map<String, dynamic>)['courses'] as List? ?? [];
    return list
        .map((c) => CatalogCourse.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Copy-on-add: clone a catalog course into the caller's account (no API
  /// call). Returns the account's own CourseInfo (idempotent).
  Future<CourseInfo> addCatalogCourse(int catalogId) async {
    final data = await _post('/catalog/courses/$catalogId/add/', {});
    final m = data as Map<String, dynamic>;
    return CourseInfo.fromJson(m['course'] as Map<String, dynamic>);
  }

  /// Unified one-box course search: merges the account's own courses, the
  /// shared catalog, and a live GolfCourseAPI search into one deduped list.
  /// Best-effort on the API side — local results still return if it's down.
  Future<List<CourseHit>> findCourses(String query) async {
    final data = await _get(
      '/courses/find/?q=${Uri.encodeComponent(query)}',
    );
    final list = (data as Map<String, dynamic>)['courses'] as List? ?? [];
    return list
        .map((c) => CourseHit.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Import an api-sourced search hit (fetches its tees from GolfCourseAPI,
  /// upserts the shared catalog, clones into the account) and return the
  /// account's own CourseInfo.
  Future<CourseInfo> importApiCourse(String golfApiId) async {
    final res = await importCourse(int.parse(golfApiId));
    return CourseInfo.fromJson(res['course'] as Map<String, dynamic>);
  }

  Future<CourseInfo> getCourse(int id) async {
    final data = await _get('/courses/$id/');
    return CourseInfo.fromJson(data as Map<String, dynamic>);
  }

  /// DELETE /api/courses/{id}/.  Admin-only.  Cascades to the course's
  /// tees; returns 400 if any tee has been used in a round (the
  /// FoursomeMembership FK is PROTECT).  Surface the API's `detail`
  /// to the user.
  Future<void> deleteCourse(int id) async {
    await _delete('/courses/$id/');
  }

  /// DELETE /api/tees/{id}/.  Admin-only.  Same PROTECT story as
  /// deleteCourse — surface the `detail` on 400.
  Future<void> deleteTee(int id) async {
    await _delete('/tees/$id/');
  }

  /// GET /api/tees/{id}/.  Returns full tee data including the
  /// 18-hole JSON blob — used by the per-tee edit screen.
  Future<TeeInfo> getTee(int id) async {
    final data = await _get('/tees/$id/');
    return TeeInfo.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/courses/{courseId}/tees/paste/.  Admin-only.  Adds
  /// a new tee or updates one in place (matched by name, CI).  Use
  /// [dryRun] to fetch a preview without persisting.
  Future<Map<String, dynamic>> pasteTee({
    required int    courseId,
    required String name,
    required int    slope,
    required double courseRating,
    String? sex,
    required String paste,
    bool    dryRun = false,
  }) async {
    final data = await _post('/courses/$courseId/tees/paste/', {
      'name':          name,
      'slope':         slope,
      'course_rating': courseRating,
      'sex':           sex,
      'paste':         paste,
      'dry_run':       dryRun,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  /// POST /api/courses/paste/.  Admin-only.
  ///
  /// Either creates a new course (pass `name`) or re-rates an
  /// existing one (pass `replaceCourseId`) from a pasted scorecard
  /// blob.  Set `dryRun: true` to get back the parsed structure
  /// without persisting — used to populate a preview step.
  ///
  /// On parse errors the API returns 400 with `{paste: [...]}`;
  /// surface those as inline field errors.
  Future<Map<String, dynamic>> pasteCourse({
    String? name,
    int?    replaceCourseId,
    required String paste,
    bool    dryRun = false,
  }) async {
    assert(name != null || replaceCourseId != null,
        'pasteCourse needs either name (create) or replaceCourseId (update).');
    final body = <String, dynamic>{
      'paste':   paste,
      'dry_run': dryRun,
      if (name != null) 'name': name,
      if (replaceCourseId != null) 'replace_course_id': replaceCourseId,
    };
    final data = await _post('/courses/paste/', body);
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Round> createRound({
    int? tournamentId,
    required int courseId,
    required String date,          // 'YYYY-MM-DD'
    List<String> activeGames = const [],
    String? primaryGame,
    Map<String, double> gamePointValues = const {},
    Map<String, int>    cupGroupCounts  = const {},
    int roundNumber = 1,
    String handicapMode = 'net',
    int netPercent = 100,
    bool netMaxDoubleBogey = true,
    int numHoles = 18,
    int startingHole = 1,
  }) async {
    final data = await _post('/rounds/', {
      'course_id'          : courseId,
      'date'               : date,
      'active_games'       : activeGames,
      if (primaryGame != null) 'primary_game': primaryGame,
      'round_number'       : roundNumber,
      'handicap_mode'      : handicapMode,
      'net_percent'        : netPercent,
      'net_max_double_bogey': netMaxDoubleBogey,
      'num_holes'          : numHoles,
      'starting_hole'      : startingHole,
      if (gamePointValues.isNotEmpty) 'game_point_values': gamePointValues,
      if (cupGroupCounts.isNotEmpty)  'cup_group_counts' : cupGroupCounts,
      if (tournamentId != null) 'tournament_id': tournamentId,
    });
    return Round.fromJson(data as Map<String, dynamic>);
  }

  /// Partial update of a round.  Used by the game-setup screens (bet
  /// unit, net-double-bogey cap).  Adding more fields just means passing
  /// them in the map.
  Future<Round> updateRound(
    int roundId, {
    double? betUnit,
    bool?   netMaxDoubleBogey,
  }) async {
    final body = <String, dynamic>{};
    if (betUnit != null)            body['bet_unit'] = betUnit;
    if (netMaxDoubleBogey != null)  body['net_max_double_bogey'] = netMaxDoubleBogey;
    final data = await _patch('/rounds/$roundId/', body);
    return Round.fromJson(data as Map<String, dynamic>);
  }

  Future<Round> setupRound(
    int roundId, {
    /// Each entry: {"player_id": int, "tee_id": int}.  Add an optional
    /// "group_number": int per entry to force explicit foursome
    /// composition (backend takes the explicit-groups path when ANY
    /// entry carries the field — must be present on ALL of them then).
    required List<Map<String, int>> players,
    double handicapAllowance = 1.0,
    bool randomise = true,
    bool autoSetupGames = false,
    List<String> activeGames = const [],
  }) async {
    final body = <String, dynamic>{
      'players'            : players,
      'handicap_allowance' : handicapAllowance,
      'randomise'          : randomise,
      'auto_setup_games'   : autoSetupGames,
    };
    if (activeGames.isNotEmpty) body['active_games'] = activeGames;
    final data = await _post('/rounds/$roundId/setup/', body);
    return Round.fromJson(data as Map<String, dynamic>);
  }

  Future<Leaderboard> completeRound(int roundId) async {
    final data = await _post('/rounds/$roundId/complete/', {});
    return Leaderboard.fromJson(data as Map<String, dynamic>);
  }

  Future<void> reopenRound(int roundId) async {
    await _post('/rounds/$roundId/reopen/', {});
  }

  /// TD-only "no-show" tool — remove a real player from a foursome
  /// before scoring begins.  The backend reconfigures any Triple Cup
  /// game on the foursome (4→3 brings in the cross-foursome phantom;
  /// 3→2 swaps to F9/B9/Overall Nassau) and revalidates the donor
  /// pool for the rest of the round.  Throws on 4xx — the error body
  /// carries human-readable detail/errors for the UI to surface.
  Future<Map<String, dynamic>> removeFoursomePlayer(
    int foursomeId,
    int playerId,
  ) async {
    final data = await _post(
      '/foursomes/$foursomeId/remove-player/',
      {'player_id': playerId},
    );
    return data as Map<String, dynamic>;
  }

  /// Mid-round withdrawal ("can't continue").  Keeps the player and their
  /// posted scores; they're simply not expected on holes after [afterHole].
  /// [killNextHole] voids the hole the group abandoned at the withdrawal.
  /// [sixesAction] ('void' | 'solo') is only used when Sixes is active.
  Future<Map<String, dynamic>> withdrawPlayer(
    int foursomeId,
    int playerId,
    int afterHole, {
    bool killNextHole = false,
    String? sixesAction,
  }) async {
    final data = await _post(
      '/foursomes/$foursomeId/withdraw-player/',
      {
        'player_id'     : playerId,
        'after_hole'    : afterHole,
        'kill_next_hole': killNextHole,
        if (sixesAction != null) 'sixes_segment_action': sixesAction,
      },
    );
    return data as Map<String, dynamic>;
  }

  /// Undo a mistaken withdrawal — clears the WD flags and un-voids any
  /// Sixes segments that were voided by it.
  Future<Map<String, dynamic>> reinstatePlayer(
    int foursomeId,
    int playerId,
  ) async {
    final data = await _post(
      '/foursomes/$foursomeId/reinstate-player/',
      {'player_id': playerId},
    );
    return data as Map<String, dynamic>;
  }

  /// TD-only "rebalance at the tee box" tool — move a player from
  /// one foursome to another.  Both sides' TC games reconfigure
  /// automatically (4↔3 phantom add/strip, 3↔2 Nassau swap).  Same
  /// pre-play-only constraint as removeFoursomePlayer.
  Future<Map<String, dynamic>> moveRoundPlayer(
    int roundId, {
    required int playerId,
    required int fromFoursomeId,
    required int toFoursomeId,
  }) async {
    final data = await _post(
      '/rounds/$roundId/move-player/',
      {
        'player_id'       : playerId,
        'from_foursome_id': fromFoursomeId,
        'to_foursome_id'  : toFoursomeId,
      },
    );
    return data as Map<String, dynamic>;
  }

  /// TD-only "shift the schedule" tool — swap this foursome's tee
  /// position (group_number + tee_time) with the foursome at the
  /// target position.  Donor-pool revalidated post-swap.
  Future<Map<String, dynamic>> swapFoursomePosition(
    int foursomeId, {
    required int targetGroupNumber,
  }) async {
    final data = await _post(
      '/foursomes/$foursomeId/swap-position/',
      {'target_group_number': targetGroupNumber},
    );
    return data as Map<String, dynamic>;
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
    required List<Map<String, int?>> scores, // [{player_id, gross_score?}, ...]
                                             // gross_score null = clear (delete)
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
    String variant      = 'none',  // 'none' | 'tiebreak_2nd' | 'claremont'
    bool   playFront    = true,
    bool   playBack     = true,
    bool   playOverall  = true,
    double? lossCap,               // presses/Claremont only; null = uncapped
  }) async {
    final data = await _post('/foursomes/$foursomeId/nassau/setup/', {
      'team1_player_ids': team1Ids,
      'team2_player_ids': team2Ids,
      'handicap_mode'   : handicapMode,
      'net_percent'     : netPercent,
      'press_mode'      : pressMode,
      'press_unit'      : pressUnit,
      'variant'         : variant,
      'play_front'      : playFront,
      'play_back'       : playBack,
      'play_overall'    : playOverall,
      'loss_cap'        : lossCap?.toStringAsFixed(2),
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

  // ---- Sixes ----

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
    String handicapMode       = 'net',
    int    netPercent         = 100,
    String scoringFormat      = 'classic',
    String handicapAllocation = 'per_segment',
  }) async {
    await _post('/foursomes/$foursomeId/sixes/setup/', {
      'segments'            : segments,
      'handicap_mode'       : handicapMode,
      'net_percent'         : netPercent,
      'scoring_format'      : scoringFormat,
      'handicap_allocation' : handicapAllocation,
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
    String  handicapMode  = 'net',
    int     netPercent    = 100,
    double? lossCap,
    String  payoutStyle   = 'per_point',
    String  perPointMode  = 'average',
  }) async {
    final data = await _post('/foursomes/$foursomeId/points_531/setup/', {
      'handicap_mode' : handicapMode,
      'net_percent'   : netPercent,
      // null = uncapped; the backend treats a missing/null cap as the
      // 36×bet_unit theoretical max (never binds).
      'loss_cap'      : lossCap,
      'payout_style'  : payoutStyle,
      'per_point_mode': perPointMode,
    });
    return Points531Summary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Triple Cup (One Round Ryder Cup) ----

  /// GET /api/foursomes/{id}/triple-cup/
  Future<TripleCupSummary> getTripleCupSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/triple-cup/');
    return TripleCupSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/triple-cup/setup/
  ///
  /// Creates (or replaces) the Triple Cup game.  team1/team2 player
  /// IDs must total 2, 3, or 4 — the backend derives the match plan
  /// (4 matches for 2v2/2v1, 3 for 1v1) from the resulting shape.
  Future<TripleCupSummary> postTripleCupSetup(
    int foursomeId, {
    required List<int> team1Ids,
    required List<int> team2Ids,
    String handicapMode             = 'net',
    int    netPercent               = 100,
    int    altShotLowPct            = 50,
    int    altShotHighPct           = 50,
    bool   foursomesFirst           = false,
    int?   foursomesTeam1FirstTee,
    int?   foursomesTeam2FirstTee,
  }) async {
    final data = await _post('/foursomes/$foursomeId/triple-cup/setup/', {
      'team1_player_ids'           : team1Ids,
      'team2_player_ids'           : team2Ids,
      'handicap_mode'              : handicapMode,
      'net_percent'                : netPercent,
      'alt_shot_low_pct'           : altShotLowPct,
      'alt_shot_high_pct'          : altShotHighPct,
      'foursomes_first'            : foursomesFirst,
      if (foursomesTeam1FirstTee != null)
        'foursomes_team1_first_tee': foursomesTeam1FirstTee,
      if (foursomesTeam2FirstTee != null)
        'foursomes_team2_first_tee': foursomesTeam2FirstTee,
    });
    return TripleCupSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/triple-cup/foursomes-tee-off/
  ///
  /// Sets (or clears) the alt-shot first-tee-off player on each side
  /// of the Triple Cup foursomes match.  Either field may be null to
  /// clear that team's choice.  Returns the refreshed TC summary.
  Future<TripleCupSummary> postTripleCupFoursomesTeeOff(
    int foursomeId, {
    int? team1FirstTee,
    int? team2FirstTee,
  }) async {
    final data = await _post(
      '/foursomes/$foursomeId/triple-cup/foursomes-tee-off/',
      {
        'team1_first_tee': team1FirstTee,
        'team2_first_tee': team2FirstTee,
      },
    );
    return TripleCupSummary.fromJson(data as Map<String, dynamic>);
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
    String  payoutStyle  = 'pool',
    String  perPointMode = 'first',
    double  perPointRate = 0.0,
    double? lossCap,
  }) async {
    final data = await _post('/foursomes/$foursomeId/skins/setup/', {
      'handicap_mode' : handicapMode,
      'net_percent'   : netPercent,
      'carryover'     : carryover,
      'allow_junk'    : allowJunk,
      'payout_style'  : payoutStyle,
      'per_point_mode': perPointMode,
      'per_point_rate': perPointRate,
      if (lossCap != null) 'loss_cap': lossCap,
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

  // ---- Spots ----

  /// GET /api/foursomes/{id}/spots/
  Future<SpotsSummary> getSpotsSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/spots/');
    return SpotsSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/spots/setup/
  Future<SpotsSummary> postSpotsSetup(
    int foursomeId, {
    double? betUnit,
    String  payoutStyle  = 'per_point',
    String  perPointMode = 'all',
    double? lossCap,
  }) async {
    final data = await _post('/foursomes/$foursomeId/spots/setup/', {
      if (betUnit != null) 'bet_unit': betUnit.toStringAsFixed(2),
      'payout_style'  : payoutStyle,
      'per_point_mode': perPointMode,
      if (lossCap != null) 'loss_cap': lossCap,
    });
    return SpotsSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/spots/tally/ — upsert per-player counts for a hole
  /// ([entries] = list of {player_id, count}; count=0 deletes).
  Future<SpotsSummary> postSpotsTally(
    int foursomeId, {
    required int                    holeNumber,
    required List<Map<String, int>> entries,
  }) async {
    final data = await _post('/foursomes/$foursomeId/spots/tally/', {
      'hole_number': holeNumber,
      'entries'    : entries,
    });
    return SpotsSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Wolf ----

  /// GET /api/foursomes/{id}/wolf/
  Future<WolfSummary> getWolfSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/wolf/');
    return WolfSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/wolf/setup/
  ///
  /// Create (or replace) the Wolf game.  [wolfOrder] is the rotation of
  /// real player ids the Wolf cycles through.  Point values + option
  /// toggles default to the classic configuration.
  Future<WolfSummary> postWolfSetup(
    int foursomeId, {
    String     handicapMode      = 'net',
    int        netPercent        = 100,
    List<int>  wolfOrder         = const [],
    int        loneWolfPoints    = 3,
    int        blindWolfPoints   = 6,
    int        teamWinPoints     = 1,
    bool       wolfLosesTies     = false,
    bool       nonWolfBonus      = false,
    bool       lastPlaceWolf1718 = true,
    bool       requireLoneOrBlind = false,
    double?    lossCap,
  }) async {
    final data = await _post('/foursomes/$foursomeId/wolf/setup/', {
      'handicap_mode'         : handicapMode,
      'net_percent'           : netPercent,
      'wolf_order'            : wolfOrder,
      'lone_wolf_points'      : loneWolfPoints,
      'blind_wolf_points'     : blindWolfPoints,
      'team_win_points'       : teamWinPoints,
      'wolf_loses_ties'       : wolfLosesTies,
      'non_wolf_bonus'        : nonWolfBonus,
      'last_place_wolf_1718'  : lastPlaceWolf1718,
      'require_lone_or_blind' : requireLoneOrBlind,
      'loss_cap'              : lossCap?.toStringAsFixed(2),
    });
    return WolfSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Las Vegas (2v2) ----

  /// GET /api/foursomes/{id}/vegas/
  Future<VegasSummary> getVegasSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/vegas/');
    return VegasSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/vegas/setup/  — fix the two teams + options.
  Future<VegasSummary> postVegasSetup(
    int foursomeId, {
    required List<int> team1PlayerIds,
    required List<int> team2PlayerIds,
    String handicapMode      = 'net',
    int    netPercent        = 100,
    bool   netMaxDoubleBogey = true,
    String birdieMode        = 'flip',
    bool   carryover         = false,
    double? lossCap,
  }) async {
    final data = await _post('/foursomes/$foursomeId/vegas/setup/', {
      'team1_player_ids'    : team1PlayerIds,
      'team2_player_ids'    : team2PlayerIds,
      'handicap_mode'       : handicapMode,
      'net_percent'         : netPercent,
      'net_max_double_bogey': netMaxDoubleBogey,
      'birdie_mode'         : birdieMode,
      'carryover'           : carryover,
      'loss_cap'            : lossCap?.toStringAsFixed(2),
    });
    return VegasSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Fourball (2v2 best-ball match play) ----

  /// GET /api/foursomes/{id}/fourball/
  Future<FourballSummary> getFourballSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/fourball/');
    return FourballSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/fourball/setup/ — fix the two teams + options.
  Future<FourballSummary> postFourballSetup(
    int foursomeId, {
    required List<int> team1PlayerIds,
    required List<int> team2PlayerIds,
    String  handicapMode = 'net',
    int     netPercent   = 100,
    double? betAmount,
  }) async {
    final data = await _post('/foursomes/$foursomeId/fourball/setup/', {
      'team1_player_ids': team1PlayerIds,
      'team2_player_ids': team2PlayerIds,
      'handicap_mode'   : handicapMode,
      'net_percent'     : netPercent,
      if (betAmount != null) 'bet_amount': betAmount.toStringAsFixed(2),
    });
    return FourballSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/wolf/order/
  ///
  /// Update only the rotation order (decisions/results survive).
  Future<WolfSummary> postWolfOrder(
    int foursomeId, {
    required List<int> wolfOrder,
  }) async {
    final data = await _post('/foursomes/$foursomeId/wolf/order/', {
      'wolf_order': wolfOrder,
    });
    return WolfSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/wolf/decision/
  ///
  /// Record the Wolf's choice on [holeNumber].  [decision] is
  /// 'partner' | 'lone' | 'blind' | 'pending' (pending clears it).
  /// [partnerId] is required for 'partner' and ignored otherwise.
  Future<WolfSummary> postWolfDecision(
    int foursomeId, {
    required int    holeNumber,
    required String decision,
    int?            partnerId,
  }) async {
    final data = await _post('/foursomes/$foursomeId/wolf/decision/', {
      'hole_number': holeNumber,
      'decision'   : decision,
      if (partnerId != null) 'partner_id': partnerId,
    });
    return WolfSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Rabbit ----

  /// GET /api/foursomes/{id}/rabbit/
  Future<RabbitSummary> getRabbitSummary(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/rabbit/');
    return RabbitSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/foursomes/{id}/rabbit/setup/
  ///
  /// Create (or replace) the Rabbit game.  [accumulate] toggles the
  /// lead-buffer vs lose-on-first-loss behavior; [numSegments] is 1, 2 or 3.
  Future<RabbitSummary> postRabbitSetup(
    int foursomeId, {
    String handicapMode = 'net',
    int    netPercent   = 100,
    bool   accumulate   = true,
    int    numSegments  = 1,
  }) async {
    final data = await _post('/foursomes/$foursomeId/rabbit/setup/', {
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
      'accumulate'   : accumulate,
      'num_segments' : numSegments,
    });
    return RabbitSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Multi-Foursome Skins (round-scoped) ----

  /// GET /api/rounds/{id}/multi-skins/
  Future<MultiSkinsSummary> getMultiSkinsSummary(int roundId) async {
    final data = await _get('/rounds/$roundId/multi-skins/');
    return MultiSkinsSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/rounds/{id}/multi-skins/setup/
  Future<MultiSkinsSummary> postMultiSkinsSetup(
    int roundId, {
    required List<int> participantIds,
    String   handicapMode = 'net',
    int      netPercent   = 100,
    double?  betUnit,
  }) async {
    final body = <String, dynamic>{
      'handicap_mode'  : handicapMode,
      'net_percent'    : netPercent,
      'participant_ids': participantIds,
    };
    if (betUnit != null) body['bet_unit'] = betUnit.toStringAsFixed(2);
    final data = await _post('/rounds/$roundId/multi-skins/setup/', body);
    return MultiSkinsSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Match Play ----

  Future<Map<String, dynamic>> getMatchPlay(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/match-play/');
    return data as Map<String, dynamic>;
  }

  /// Configure entry fee, payouts, and bracket seedings; returns the full
  /// match play summary.  Safe to call before play starts.
  ///
  /// [seedOrder] — optional list of player IDs in desired seed order
  /// (index 0 = seed 1, plays seed 4 in Semi 1).  Omit to use the
  /// default automatic handicap seeding.
  Future<Map<String, dynamic>> postMatchPlaySetup(
    int foursomeId, {
    double               entryFee     = 0,
    Map<String, double>  payoutConfig = const {},
    List<int>?           seedOrder,
    /// Per-bracket handicap mode override.  When null the backend keeps
    /// whatever the bracket already has (or falls back to round mode for
    /// a fresh bracket).  Use 'net' / 'gross' / 'strokes_off'.
    String?              handicapMode,
    int?                 netPercent,
  }) async {
    final body = <String, dynamic>{
      'entry_fee'    : entryFee,
      'payout_config': {for (final e in payoutConfig.entries) e.key: e.value},
    };
    if (seedOrder    != null) body['seed_order']    = seedOrder;
    if (handicapMode != null) body['handicap_mode'] = handicapMode;
    if (netPercent   != null) body['net_percent']   = netPercent;
    final data = await _post('/foursomes/$foursomeId/match-play/setup/', body);
    return data as Map<String, dynamic>;
  }

  // ---- Three-Person Match ----

  /// Fetch the current Three-Person Match summary for a foursome.
  Future<ThreePersonMatchSummary> getThreePersonMatch(int foursomeId) async {
    final data = await _get('/foursomes/$foursomeId/three-person-match/');
    return ThreePersonMatchSummary.fromJson(data as Map<String, dynamic>);
  }

  /// Set up (or replace) the Three-Person Match for a foursome.
  Future<ThreePersonMatchSummary> postThreePersonMatchSetup(
    int foursomeId, {
    String               handicapMode = 'net',
    int                  netPercent   = 100,
    double               entryFee     = 0.0,
    Map<String, double>  payoutConfig = const {},
  }) async {
    final data = await _post('/foursomes/$foursomeId/three-person-match/setup/', {
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
      'entry_fee'    : entryFee,
      'payout_config': {for (final e in payoutConfig.entries) e.key: e.value},
    });
    return ThreePersonMatchSummary.fromJson(data as Map<String, dynamic>);
  }

  // ---- Irish Rumble setup (round-level) ----

  Future<Map<String, dynamic>> getIrishRumbleConfig(int roundId) async {
    final data = await _get('/rounds/$roundId/irish-rumble/setup/');
    return data as Map<String, dynamic>;
  }

  /// Irish Rumble standings — segments + overall, including each group's
  /// borrowed-4th donor status (`overall[].phantom`).  Used by score entry to
  /// show a leveled threesome its borrowed-ball / pending holes.
  Future<Map<String, dynamic>> getIrishRumbleResult(int roundId) async {
    final data = await _get('/rounds/$roundId/irish-rumble/');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postIrishRumbleSetup(
    int roundId, {
    required String                      handicapMode,
    required int                         netPercent,
    required double                      entryFee,
    required List<Map<String, dynamic>>  payouts,
    String                               variant     = 'classic',
    List<int>?                           customBalls,
  }) async {
    final body = <String, dynamic>{
      'handicap_mode': handicapMode,
      'net_percent'  : netPercent,
      'entry_fee'    : entryFee.toStringAsFixed(2),
      'payouts'      : payouts,
      'variant'      : variant,
    };
    if (variant == 'custom' && customBalls != null) {
      body['custom_balls'] = customBalls;
    }
    final data = await _post('/rounds/$roundId/irish-rumble/setup/', body);
    return data as Map<String, dynamic>;
  }

  // ---- Course import (GolfCourseAPI) ----

  /// Search golf courses by name via GolfCourseAPI.
  /// Returns a list of course maps:
  ///   [{ id (int), club_name, course_name, city, state, country, already_imported }]
  Future<List<Map<String, dynamic>>> searchGolfApiCourses(String query) async {
    final data    = await _get('/courses/golf-api/search/?q=${Uri.encodeComponent(query)}');
    final courses = (data as Map<String, dynamic>)['courses'] as List? ?? [];
    return courses.map((c) => Map<String, dynamic>.from(c as Map)).toList();
  }

  /// Fetch full course detail (tees + holes) from GolfCourseAPI.
  /// [courseId] is the numeric id returned by searchGolfApiCourses.
  Future<Map<String, dynamic>> getGolfApiCourse(int courseId) async {
    final data = await _get('/courses/golf-api/courses/$courseId/');
    return data as Map<String, dynamic>;
  }

  /// Import a course from GolfCourseAPI into the local database.
  ///
  /// Returns { already_exists, created, tees_imported, course: {...} }
  /// Throws ApiException(409) when the course exists and forceUpdate=false —
  /// the caller can catch that and offer the user Skip / Update.
  Future<Map<String, dynamic>> importCourse(
    int courseId, {
    bool forceUpdate = false,
  }) async {
    final body = <String, dynamic>{
      'course_id'   : courseId,
      'force_update': forceUpdate,
    };
    final data = await _post('/courses/import/', body);
    return data as Map<String, dynamic>;
  }

  // ---- Foursome per-game override ----

  Future<Map<String, dynamic>> patchFoursomeActiveGames(
    int foursomeId, {
    required List<String> activeGames,
  }) async {
    final data = await _patch('/foursomes/$foursomeId/active-games/', {
      'active_games': activeGames,
    });
    return data as Map<String, dynamic>;
  }

  /// Set a group's custom name (TD action). Blank clears it → "Group N".
  Future<Foursome> setFoursomeName(int foursomeId, String name) async {
    final data = await _patch('/foursomes/$foursomeId/', {'name': name});
    return Foursome.fromJson(data as Map<String, dynamic>);
  }

  /// Reassign each player's tee for a foursome.  Server-side this also
  /// recomputes course_handicap + playing_handicap from the new tee.
  /// Returns the updated scorecard payload.  Throws ApiException(400)
  /// when any hole has already been scored — tees can only change
  /// before the first score is entered.
  Future<Map<String, dynamic>> patchFoursomeTees(
    int foursomeId, {
    required List<Map<String, int>> tees,
  }) async {
    final data = await _patch('/foursomes/$foursomeId/tees/', {
      'tees': tees,
    });
    return data as Map<String, dynamic>;
  }

  // ---- Low Net setup (round-level) ----

  Future<Map<String, dynamic>> getLowNetConfig(int roundId) async {
    final data = await _get('/rounds/$roundId/low-net/setup/');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getStablefordResult(int roundId) async {
    final data = await _get('/rounds/$roundId/stableford/');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getStablefordConfig(int roundId) async {
    final data = await _get('/rounds/$roundId/stableford/setup/');
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postStablefordSetup(
    int roundId, {
    required String                     handicapMode,
    required int                        netPercent,
    required String                     payoutStyle, // 'pool' | 'per_point'
    required double                     perPointRate,
    required String                     perPointMode, // 'average' | 'all' | 'first'
    required double                     entryFee,
    required List<Map<String, dynamic>> payouts,
    required Map<String, int>           pointsTable, // keys: albatross..double
    List<int>                           excludedPlayerIds = const [],
    double?                             lossCap, // per_point only; null = uncapped
  }) async {
    final data = await _post('/rounds/$roundId/stableford/setup/', {
      'handicap_mode'      : handicapMode,
      'net_percent'        : netPercent,
      'payout_style'       : payoutStyle,
      'per_point_rate'     : perPointRate.toStringAsFixed(2),
      'per_point_mode'     : perPointMode,
      'loss_cap'           : lossCap?.toStringAsFixed(2),
      'entry_fee'          : entryFee.toStringAsFixed(2),
      'payouts'            : payouts,
      'excluded_player_ids': excludedPlayerIds,
      'pts_albatross'      : pointsTable['albatross'],
      'pts_eagle'          : pointsTable['eagle'],
      'pts_birdie'         : pointsTable['birdie'],
      'pts_par'            : pointsTable['par'],
      'pts_bogey'          : pointsTable['bogey'],
      'pts_double'         : pointsTable['double'],
    });
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postLowNetSetup(
    int roundId, {
    required String                     handicapMode,
    required int                        netPercent,
    required double                     entryFee,
    required List<Map<String, dynamic>> payouts,
    List<int>                           excludedPlayerIds = const [],
  }) async {
    final data = await _post('/rounds/$roundId/low-net/setup/', {
      'handicap_mode'      : handicapMode,
      'net_percent'        : netPercent,
      'entry_fee'          : entryFee.toStringAsFixed(2),
      'payouts'            : payouts,
      'excluded_player_ids': excludedPlayerIds,
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
    required String                      ballColor,
    required double                      entryFee,
    required List<Map<String, dynamic>>  payouts,
  }) async {
    final data = await _post('/rounds/$roundId/pink-ball/setup/', {
      'ball_color': ballColor,
      'entry_fee' : entryFee.toStringAsFixed(2),
      'payouts'   : payouts,
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

  // ---- Team Tournament (Ryder Cup) ----

  /// GET /api/tournaments/<id>/team-tournament/
  /// Returns the full summary (teams, total points, per-round breakdown).
  /// Throws ApiException(404) when no team tournament has been set up.
  Future<TeamTournamentSummary> getTeamTournament(int tournamentId) async {
    final data = await _get('/tournaments/$tournamentId/team-tournament/');
    return TeamTournamentSummary.fromJson(data as Map<String, dynamic>);
  }

  /// POST /api/tournaments/<id>/team-tournament/setup/
  /// Creates (or replaces) the cup config + team shells.
  /// [teams] is a list of {name, team_number, colour?, short_code?}
  Future<Map<String, dynamic>> postTeamTournamentSetup(
    int tournamentId, {
    required String             cupName,
    required int                playersPerTeam,
    required List<Map<String, dynamic>> teams,
  }) async {
    final data = await _post('/tournaments/$tournamentId/team-tournament/setup/', {
      'cup_name'        : cupName,
      'players_per_team': playersPerTeam,
      'teams'           : teams,
    });
    return data as Map<String, dynamic>;
  }

  /// POST /api/tournaments/<id>/team-tournament/draft-complete/
  /// Locks the rosters.
  Future<void> postDraftComplete(int tournamentId) async {
    await _post('/tournaments/$tournamentId/team-tournament/draft-complete/', {});
  }

  /// POST /api/tournaments/<id>/team-tournament/teams/<teamId>/players/
  /// Adds [playerId] to the team.  Automatically removes the player from any
  /// other team in this tournament.
  Future<Map<String, dynamic>> postAddTeamPlayer(
    int tournamentId, int teamId, int playerId,
  ) async {
    final data = await _post(
      '/tournaments/$tournamentId/team-tournament/teams/$teamId/players/',
      {'player_id': playerId},
    );
    return data as Map<String, dynamic>;
  }

  /// DELETE /api/tournaments/<id>/team-tournament/teams/<teamId>/players/<playerId>/
  Future<void> deleteTeamPlayer(
    int tournamentId, int teamId, int playerId,
  ) async {
    await _delete(
      '/tournaments/$tournamentId/team-tournament/teams/$teamId/players/$playerId/',
    );
  }

  /// PATCH /api/tournaments/<id>/team-tournament/teams/<teamId>/
  /// Renames the team.
  Future<void> patchTeamName(int tournamentId, int teamId, String name) async {
    await _patch(
      '/tournaments/$tournamentId/team-tournament/teams/$teamId/',
      {'name': name},
    );
  }

  // ---- Ryder Cup round config ----

  /// GET /api/rounds/<id>/ryder-cup/
  Future<Map<String, dynamic>> getRyderCupRound(int roundId) async {
    final data = await _get('/rounds/$roundId/ryder-cup/');
    return data as Map<String, dynamic>;
  }

  /// POST /api/rounds/<id>/ryder-cup/setup/
  /// [foursomes] = [{foursome_id, game_type, team1_id?, team2_id?}, ...]
  /// [irishRumblePairings] = [{foursome_a_id, foursome_b_id, team_a_id, team_b_id}, ...]
  /// POST /api/rounds/{id}/ryder-cup/change-game/.  Admin-only.
  ///
  /// Swaps the cup game for every foursome in this round without
  /// rebuilding the player roster.  Supported targets: nassau,
  /// quota_nassau, singles_nassau, singles_18.  Other games (irish_rumble,
  /// match_play) return 501; use the full Cup Round Setup wizard.
  ///
  /// Returns `{changed: int, skipped: List<int>}`.  `skipped` lists
  /// group numbers whose foursomes couldn't be auto-teamed (e.g. all
  /// players belong to one team).
  Future<Map<String, dynamic>> postRyderCupChangeGame(
    int roundId, {
    required String gameType,
    String? pointValue,
  }) async {
    final body = <String, dynamic>{
      'game_type': gameType,
      if (pointValue != null) 'point_value': pointValue,
    };
    final data = await _post(
      '/rounds/$roundId/ryder-cup/change-game/', body,
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> postRyderCupRoundSetup(
    int roundId, {
    required double nassauPointValue,
    required double pointMultiplier,
    String notes = '',
    /// 'custom' (default — admin picks game_type per foursome) or
    /// 'triple_cup' ("One Day Ryder Cup" preset that locks every
    /// foursome to Triple Cup; the backend auto-fills game_type).
    String roundFormat = 'custom',
    required List<Map<String, dynamic>> foursomes,
    List<Map<String, dynamic>> irishRumblePairings = const [],
  }) async {
    final data = await _post('/rounds/$roundId/ryder-cup/setup/', {
      'nassau_point_value'  : nassauPointValue,
      'point_multiplier'    : pointMultiplier,
      'notes'               : notes,
      'round_format'        : roundFormat,
      'foursomes'           : foursomes,
      'irish_rumble_pairings': irishRumblePairings,
    });
    return data as Map<String, dynamic>;
  }

  /// POST /api/rounds/<id>/ryder-cup/calculate/
  /// Triggers a points recalculation from current game results.
  Future<Map<String, dynamic>> postRyderCupCalculate(int roundId) async {
    final data = await _post('/rounds/$roundId/ryder-cup/calculate/', {});
    return data as Map<String, dynamic>;
  }

  /// PATCH /api/rounds/<id>/tee-times/
  /// Sets tee times on foursomes identified by group_number.
  /// [entries] = [{group_number: 1, tee_time: "08:00"}, ...]
  /// Pass tee_time as null to clear a group's tee time.
  Future<List<Foursome>> setTeeTimes(
    int roundId,
    List<Map<String, dynamic>> entries,
  ) async {
    final data = await _patch('/rounds/$roundId/tee-times/',
        {'tee_times': entries});
    return (data as List)
        .map((f) => Foursome.fromJson(f as Map<String, dynamic>))
        .toList();
  }

  // ---- Phantom player ----

  /// Idempotent — safe to call on every score-entry screen load.
  Future<PhantomInitResult> initPhantom(int foursomeId) async {
    final data = await _post('/foursomes/$foursomeId/phantom/init/', {});
    return PhantomInitResult.fromJson(data as Map<String, dynamic>);
  }

  // ---- Quota Nassau ----

  Future<QuotaNassauSummary?> getQuotaNassauSummary(int foursomeId) async {
    try {
      final data = await _get('/foursomes/$foursomeId/quota-nassau/');
      return QuotaNassauSummary.fromJson(data as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<QuotaNassauSummary> postQuotaNassauSetup(
    int foursomeId,
    List<Map<String, dynamic>> pairings,
  ) async {
    final data = await _post('/foursomes/$foursomeId/quota-nassau/setup/', {
      'pairings': pairings,
    });
    return QuotaNassauSummary.fromJson(data as Map<String, dynamic>);
  }
}
