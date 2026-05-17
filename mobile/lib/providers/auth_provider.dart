/// providers/auth_provider.dart
/// Manages login state and persists the auth token across restarts.

import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/client.dart';
import '../api/models.dart';

/// Persist a one-line breadcrumb describing why the session ended.  The
/// login screen reads `auth_last_401` (an HTTP 401 trigger) AND
/// `auth_last_logout` (anything else: manual tap, restoreSession failure,
/// etc.) so we can finally pin down the intermittent silent-logout bug.
Future<void> _writeLogoutBreadcrumb(String reason) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final stamp = DateTime.now().toIso8601String();
    await prefs.setString('auth_last_logout', '$stamp  $reason');
  } catch (_) {}
}

class AuthProvider extends ChangeNotifier {
  static const _tokenKey = 'auth_token';

  String?        _token;
  PlayerProfile? _player;
  bool           _isStaff = false;
  bool           _loading = false;
  String?        _error;

  String?        get token     => _token;
  PlayerProfile? get player    => _player;
  bool           get isStaff   => _isStaff;
  bool           get loading   => _loading;
  String?        get error     => _error;
  bool           get isLoggedIn => _token != null;

  ApiClient get client => ApiClient(
        token: _token,
        onSessionExpired: () {
          _writeLogoutBreadcrumb('401 onSessionExpired callback');
          logout(silent: true, reason: '401');
        },
      );

  /// Called at app startup — restore saved token and fetch profile.
  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_tokenKey);
    if (saved == null) return;
    _token = saved;
    try {
      final result = await ApiClient(token: saved).me();
      _player  = result.player;
      _isStaff = result.isStaff;
    } catch (e) {
      // Token expired or server unreachable — clear it.  Breadcrumb the
      // error so the login screen can tell the user (and us) which path
      // dropped them: 401 vs network blip vs other.
      await _writeLogoutBreadcrumb('restoreSession failed: $e');
      _token = null;
      await prefs.remove(_tokenKey);
    }
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    _loading = true;
    _error   = null;
    notifyListeners();

    try {
      final result = await ApiClient().login(username, password);
      // Persist and apply atomically so we don't end up half-logged-in if
      // a side call fails after the token has been set.  The login
      // response already contains the player profile, so no follow-up
      // /auth/me/ request is needed — that second call was the source of
      // the previous "login twice" bug when it hit a transient failure.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, result.token);
      _token   = result.token;
      _player  = result.player;
      _isStaff = result.isStaff;
    } on ApiException catch (e) {
      _error  = e.message;
      _token  = null;
      _player = null;
    } catch (e) {
      _error  = 'Could not reach server. Check your connection.';
      _token  = null;
      _player = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// `reason` is an internal diagnostic tag for the silent-logout bug —
  /// callers from app code don't need to pass it; the breadcrumb defaults
  /// to "manual tap" since drawer logout is the only public entry point.
  Future<void> logout({bool silent = false, String reason = 'manual'}) async {
    // Capture the call stack so we can identify which code path triggered
    // the logout when the user reports the next intermittent silent-out.
    final stack = StackTrace.current.toString().split('\n').take(8).join(' | ');
    final msg   = '[AUTH-LOGOUT] reason=$reason silent=$silent stack=$stack';
    debugPrint(msg);
    developer.log(msg, name: 'AUTH');
    await _writeLogoutBreadcrumb('logout reason=$reason  stack=$stack');

    if (!silent) {
      try {
        await client.logout();
      } catch (_) {}
    }
    _token   = null;
    _player  = null;
    _isStaff = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    notifyListeners();
  }
}
