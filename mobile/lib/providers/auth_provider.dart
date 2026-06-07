/// providers/auth_provider.dart
/// Manages login state and persists the auth token across restarts.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/client.dart';
import '../api/models.dart';

class AuthProvider extends ChangeNotifier {
  static const _tokenKey       = 'auth_token';
  // Remembered last-used account name so the login screen can
  // pre-fill it on next launch.  Account names are typically stable
  // (a group name), so pre-filling beats forcing re-entry every time.
  static const _accountNameKey = 'last_account_name';

  String?        _token;
  String?        _username;
  PlayerProfile? _player;
  AccountInfo?   _account;
  bool           _isStaff        = false;
  bool           _isAccountAdmin = false;
  bool           _loading        = false;
  String?        _error;
  String?        _lastAccountName;
  bool           _isNewAccount   = false;

  String?        get token            => _token;
  String?        get username         => _username;
  PlayerProfile? get player           => _player;
  AccountInfo?   get account          => _account;
  bool           get isStaff          => _isStaff;
  bool           get isAccountAdmin   => _isAccountAdmin;
  /// True for anyone who should see admin-level controls in the app
  /// (configure games, edit other foursomes, create tournaments, etc.).
  /// `isStaff` = Django superuser-style access (legacy, pre-accounts).
  /// `isAccountAdmin` = elevated role within the user's Account.
  /// Either one grants admin powers within the user's own tenant.
  bool           get isAdmin          => _isStaff || _isAccountAdmin;
  bool           get loading          => _loading;
  String?        get error            => _error;
  String?        get lastAccountName  => _lastAccountName;
  /// True when the last phone verify self-created a new account — the
  /// phone-login UI reads this to route a first-time user through profile
  /// setup.  Reset on the next login attempt.
  bool           get isNewAccount      => _isNewAccount;
  bool           get isLoggedIn       => _token != null;

  /// Optional hooks so platform integrations (push notifications) can react to
  /// auth changes without coupling this provider to Firebase. Wired in main().
  /// Both are best-effort; failures must never affect auth.
  Future<void> Function()? onAuthenticated;
  Future<void> Function()? onLoggingOut;

  ApiClient get client => ApiClient(
        token: _token,
        onSessionExpired: () => logout(silent: true),
      );

  /// Called at app startup — restore saved token, fetch profile, and
  /// load the last-used account name for the login screen pre-fill.
  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _lastAccountName = prefs.getString(_accountNameKey);

    final saved = prefs.getString(_tokenKey);
    if (saved == null) {
      notifyListeners();
      return;
    }
    _token = saved;
    try {
      final result = await ApiClient(token: saved).me();
      _username       = result.username;
      _player         = result.player;
      _account        = result.account;
      _isStaff        = result.isStaff;
      _isAccountAdmin = result.isAccountAdmin;
    } catch (_) {
      // Token expired or server unreachable — clear it.
      _token = null;
      await prefs.remove(_tokenKey);
    }
    notifyListeners();
  }

  Future<void> login(String accountName, String username, String password) async {
    _loading = true;
    _error   = null;
    notifyListeners();

    try {
      final result = await ApiClient().login(
        accountName: accountName,
        username:    username,
        password:    password,
      );
      // Persist token + remembered account name atomically with the
      // local state, so a side-call failure can't leave us
      // half-logged-in.  The login response already contains the
      // player + account, so no follow-up /auth/me/ is needed.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey,       result.token);
      await prefs.setString(_accountNameKey, accountName);
      _token            = result.token;
      _username         = result.username;
      _player           = result.player;
      _account          = result.account;
      _isStaff          = result.isStaff;
      _isAccountAdmin   = result.isAccountAdmin;
      _lastAccountName  = accountName;
      onAuthenticated?.call();   // register for push (best-effort)
    } on ApiException catch (e) {
      _error   = e.message;
      _token   = null;
      _player  = null;
      _account = null;
    } catch (e) {
      _error   = 'Could not reach server. Check your connection.';
      _token   = null;
      _player  = null;
      _account = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Phone-first login step 1: request an SMS passcode.  Returns the dev-only
  /// `debug_code` when the server is in DEBUG (null in production), so manual
  /// testing can complete the flow without a real SMS.  Sets [error] on
  /// failure (invalid number, rate-limited, server unreachable).
  Future<String?> requestOtp(String phone) async {
    _loading = true;
    _error   = null;
    notifyListeners();
    try {
      return await ApiClient().requestOtp(phone: phone);
    } on ApiException catch (e) {
      _error = e.message;
      return null;
    } catch (_) {
      _error = 'Could not reach server. Check your connection.';
      return null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Phone-first login step 2: verify the passcode and sign in.  An unknown
  /// phone self-creates an account; check [isNewAccount] afterward to route to
  /// profile setup.  Mirrors [login]'s token/state persistence so the auth
  /// gate reacts identically.
  Future<void> verifyOtp(String phone, String code, {String? name}) async {
    _loading = true;
    _error   = null;
    notifyListeners();
    try {
      final result = await ApiClient().verifyOtp(
        phone: phone, code: code, name: name,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, result.token);
      // Remember the account name only for display / legacy-form pre-fill.
      await prefs.setString(_accountNameKey, result.account.name);
      _token            = result.token;
      _username         = result.username;
      _player           = result.player;
      _account          = result.account;
      _isStaff          = result.isStaff;
      _isAccountAdmin   = result.isAccountAdmin;
      _isNewAccount     = result.isNewAccount;
      _lastAccountName  = result.account.name;
      onAuthenticated?.call();   // register for push (best-effort)
    } on ApiException catch (e) {
      _error   = e.message;
      _token   = null;
      _player  = null;
      _account = null;
    } catch (e) {
      _error   = 'Could not reach server. Check your connection.';
      _token   = null;
      _player  = null;
      _account = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Reflect an updated player profile in the session (e.g. after the
  /// first-run profile-setup screen saves name / handicap), so the drawer and
  /// any player-derived UI update without a relaunch.
  void applyPlayer(PlayerProfile player) {
    _player = player;
    notifyListeners();
  }

  /// Permanently delete the signed-in user's account, then clear the
  /// local session (which trips the auth gate in main.dart and routes
  /// back to the login screen).  Rethrows [ApiException] so the caller
  /// can surface the server message (e.g. the last-admin guard) without
  /// the session being torn down.
  Future<void> deleteAccount() async {
    // Let errors propagate BEFORE we clear any local state, so a blocked
    // deletion (e.g. last admin) leaves the user logged in.
    await client.deleteMyAccount();

    _token          = null;
    _username       = null;
    _player         = null;
    _account        = null;
    _isStaff        = false;
    _isAccountAdmin = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    // The login is gone, so don't pre-fill the old account name either.
    await prefs.remove(_accountNameKey);
    _lastAccountName = null;
    notifyListeners();
  }

  Future<void> logout({bool silent = false}) async {
    // Drop this device's push token while we still have a valid token/client.
    try { await onLoggingOut?.call(); } catch (_) {}
    if (!silent) {
      try {
        await client.logout();
      } catch (_) {}
    }
    _token          = null;
    _username       = null;
    _player         = null;
    _account        = null;
    _isStaff        = false;
    _isAccountAdmin = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    // Intentionally KEEP _accountNameKey — the next login screen
    // pre-fills it as a convenience.
    notifyListeners();
  }
}
