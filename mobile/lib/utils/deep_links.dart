import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../main.dart' show navigatorKey, gDeepLinkReady;
import '../providers/auth_provider.dart';
import '../screens/tournament_leaderboard_screen.dart';

/// Handles incoming universal links — taps on https://link.halved.golf/watch/<token>/
/// that open the app.  Resolves the token to a round (recording the opener as a
/// watcher server-side) and pushes the read-only leaderboard.
///
/// Cold-start ordering matters: the link can arrive before the saved session is
/// applied in-memory AND before the splash hands off to a real screen. So we
/// STASH the token and flush it only once (a) the user is signed in and (b) the
/// app is past the splash — retrying as auth settles. We never force a login
/// screen: a logged-in user tapping a watch link must NOT be bounced to re-auth,
/// and even a signed-out user is taken to the round right after they log in.
///
/// Requires the iOS Associated Domains entitlement (`applinks:link.halved.golf`)
/// and the matching apple-app-site-association file; until those are live the
/// link just opens the web watch page in a browser.
class DeepLinkService {
  final AuthProvider auth;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  VoidCallback? _authListener;

  String? _pendingToken;
  int _flushAttempts = 0;

  DeepLinkService(this.auth);

  Future<void> start() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _capture(initial);
    } catch (_) {/* no initial link */}
    _sub = _appLinks.uriLinkStream.listen(_capture, onError: (_) {});
    // Re-attempt any stashed link when auth state changes (e.g. after login /
    // after the saved session finishes restoring).
    _authListener = _flush;
    auth.addListener(_authListener!);
  }

  void dispose() {
    _sub?.cancel();
    if (_authListener != null) auth.removeListener(_authListener!);
  }

  void _capture(Uri uri) {
    // Expect .../watch/<token>/  (accepts extra path segments defensively).
    final segs = uri.pathSegments;
    final i = segs.indexOf('watch');
    if (i < 0 || i + 1 >= segs.length) {
      return;
    }
    final token = segs[i + 1].trim();
    if (token.isEmpty) return;
    _pendingToken = token;
    _flushAttempts = 0;
    _flush();
  }

  Future<void> _flush() async {
    final token = _pendingToken;
    if (token == null) return;

    // Not signed in yet — the saved session may still be restoring, or the user
    // hasn't logged in. Keep the token stashed; the auth listener retries once
    // they're authenticated. NEVER force a login screen here.
    if (!auth.isLoggedIn) return;

    // Wait until the navigator is mounted AND the splash has handed off to a
    // real screen, so our push isn't clobbered by the splash's pushReplacement.
    if (navigatorKey.currentState == null || !gDeepLinkReady) {
      if (_flushAttempts++ < 40) {   // ~12s max, then give up quietly
        Future.delayed(const Duration(milliseconds: 300), _flush);
      }
      return;
    }

    _pendingToken = null;   // consume — don't double-navigate
    try {
      final res          = await auth.client.resolveWatchToken(token);
      final roundId      = res['round_id'] as int?;
      final isTournament = res['is_tournament'] == true;
      final tournamentId = res['tournament_id'] as int?;
      final tournamentNm = (res['tournament_name'] as String?) ?? 'Tournament';
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
