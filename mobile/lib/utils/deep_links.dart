import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../main.dart' show navigatorKey;
import '../providers/auth_provider.dart';
import '../screens/tournament_leaderboard_screen.dart';

/// Handles incoming universal links — taps on https://halved.golf/watch/<token>/
/// that open the app.  Resolves the token to a round (recording the opener as a
/// watcher server-side) and pushes the read-only leaderboard.
///
/// Requires the iOS Associated Domains entitlement (`applinks:halved.golf`) and
/// the matching apple-app-site-association file served at halved.golf; until
/// those are live the same link just opens the web watch page in a browser.
class DeepLinkService {
  final AuthProvider auth;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  DeepLinkService(this.auth);

  Future<void> start() async {
    // Cold start — the app was launched by tapping a link.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await _handle(initial);
    } catch (_) {/* no initial link */}
    // Warm — links tapped while the app is already running.
    _sub = _appLinks.uriLinkStream.listen(
      (uri) => _handle(uri),
      onError: (_) {},
    );
  }

  void dispose() => _sub?.cancel();

  Future<void> _handle(Uri uri) async {
    // Expect .../watch/<token>/  (accepts extra path segments defensively).
    final segs = uri.pathSegments;
    final i = segs.indexOf('watch');
    if (i < 0 || i + 1 >= segs.length) return;
    final token = segs[i + 1].trim();
    if (token.isEmpty) return;

    // Resolving needs an authenticated user (round_for_reader admits the
    // phone-matched watcher). If not signed in, drop to login — they can
    // re-tap the link after; the web page is the fallback meanwhile.
    if (!auth.isLoggedIn) {
      navigatorKey.currentState
          ?.pushNamedAndRemoveUntil('/login', (r) => false);
      return;
    }
    try {
      final res           = await auth.client.resolveWatchToken(token);
      final roundId       = res['round_id'] as int?;
      final isTournament  = res['is_tournament'] == true;
      final tournamentId  = res['tournament_id'] as int?;
      final tournamentNm  = (res['tournament_name'] as String?) ?? 'Tournament';
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      if (isTournament && tournamentId != null) {
        nav.push(MaterialPageRoute(
          builder: (_) => TournamentLeaderboardScreen(
              tournamentId: tournamentId, tournamentName: tournamentNm),
        ));
      } else if (roundId != null) {
        nav.pushNamed('/leaderboard', arguments: roundId);
      }
    } catch (_) {/* bad / expired token — ignore, web page is the fallback */}
  }
}
