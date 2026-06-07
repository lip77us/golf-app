/// services/push_service.dart
/// Thin wrapper around Firebase Cloud Messaging: initialise Firebase, register
/// this device's token with the backend after login, drop it on logout, and
/// route a notification tap to the relevant leaderboard.
///
/// Everything is defensive — if Firebase isn't configured (e.g. running on a
/// build without the native setup), the app still launches and simply has no
/// push. Failures never propagate to auth or UI.

import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import '../providers/auth_provider.dart';

class PushService {
  static bool _ready = false;          // Firebase initialised OK
  static bool _listenersSet = false;
  static String? _lastToken;

  static String get _platform => Platform.isIOS ? 'ios' : 'android';

  /// Call once at startup, before runApp. Guarded so a missing/!misconfigured
  /// Firebase setup can't crash the app.
  static Future<void> initFirebase() async {
    try {
      await Firebase.initializeApp();
      _ready = true;
    } catch (_) {
      _ready = false; // push disabled; app runs normally
    }
  }

  /// Wire auth → push: register on login, unregister on logout. Also sets up
  /// tap handling. Call once after the providers + navigator exist.
  static void attach(AuthProvider auth, GlobalKey<NavigatorState> navKey) {
    auth.onAuthenticated = () => registerCurrentDevice(auth);
    auth.onLoggingOut    = () => unregisterCurrentDevice(auth);
    _setupTapHandling(navKey);
    if (auth.isLoggedIn) registerCurrentDevice(auth);
  }

  static Future<void> registerCurrentDevice(AuthProvider auth) async {
    if (!_ready || !auth.isLoggedIn) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      // Show notifications while the app is foregrounded (iOS).
      await messaging.setForegroundNotificationPresentationOptions(
          alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token == null) return;
      _lastToken = token;
      await auth.client.registerDevice(token, _platform);
      if (!_listenersSet) {
        _listenersSet = true;
        messaging.onTokenRefresh.listen((t) async {
          _lastToken = t;
          try {
            await auth.client.registerDevice(t, _platform);
          } catch (_) {}
        });
      }
    } catch (_) {/* best-effort */}
  }

  static Future<void> unregisterCurrentDevice(AuthProvider auth) async {
    if (!_ready) return;
    try {
      final token = _lastToken ??
          await FirebaseMessaging.instance.getToken();
      if (token != null) await auth.client.unregisterDevice(token);
    } catch (_) {/* best-effort */}
  }

  static void _setupTapHandling(GlobalKey<NavigatorState> navKey) {
    if (!_ready) return;
    try {
      // Tap while backgrounded.
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _handleTap(navKey, m));
      // Tap that cold-launched the app.
      FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null) _handleTap(navKey, m);
      });
    } catch (_) {}
  }

  static void _handleTap(GlobalKey<NavigatorState> navKey, RemoteMessage m) {
    final roundId = int.tryParse(m.data['round_id']?.toString() ?? '');
    if (roundId == null) return;
    // All current events (round started/completed) carry a round id → open its
    // read-only leaderboard, after the first frame so the navigator exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navKey.currentState?.pushNamed('/leaderboard', arguments: roundId);
    });
  }
}
