/// config.dart
///
/// Server selection is controlled at launch time via --dart-define.
/// No code changes needed — just pick the right run configuration.
///
/// Railway (default, physical iPhone):
///   flutter run
///
/// Local Django server (iOS Simulator):
///   flutter run --dart-define=USE_LOCAL=true
///
/// Local Django server from a PHYSICAL phone — `localhost` there means the
/// phone itself, so it needs the Mac's address on the network:
///   flutter run --dart-define=API_BASE=http://192.168.4.137:8000/api
///
/// In VS Code, use the "Golf (Local)" or "Golf (Railway)" launch configs.

import 'package:package_info_plus/package_info_plus.dart';

class Config {
  static const bool _useLocal =
      bool.fromEnvironment('USE_LOCAL', defaultValue: false);

  static const String _railway = 'https://web-production-b84d4a.up.railway.app/api';
  static const String _local   = 'http://localhost:8000/api';

  /// An explicit base wins over both. This exists for testing a physical phone
  /// against the Mac, where neither default is right: Railway is the wrong
  /// server and `localhost` is the wrong machine.
  static const String _explicit = String.fromEnvironment('API_BASE');

  static const String baseUrl =
      _explicit != '' ? _explicit : (_useLocal ? _local : _railway);

  /// The version string of this build.  Populated at startup by [init] from the
  /// app bundle (package_info_plus) so it can NEVER drift from pubspec.yaml —
  /// which is exactly what caused About to show a stale version and mis-fed the
  /// force-upgrade check.  The literal below is only a fallback if the platform
  /// lookup fails; keep it roughly current but it is not the source of truth.
  static String appVersion = '2.4.0';

  /// Load the real build version from the bundle.  Call once early in main()
  /// (before the version-compatibility check).  Never throws.
  static Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) appVersion = info.version;
    } catch (_) {
      // Keep the fallback literal — an unreadable bundle shouldn't block startup.
    }
  }

  /// Which backend this build is wired to, for the debug ribbon.
  ///
  /// The question that matters is not "which server" but the one dangerous
  /// combination: a DEBUG build talking to PRODUCTION.  `USE_LOCAL` defaults
  /// to false, so a plain `flutter run` — including on the simulator — points
  /// at Railway, and throwaway test data lands in the real account.  Nothing
  /// on screen distinguished that from local, which is exactly how a junk
  /// tournament got created in production.
  static bool get isProd => baseUrl == _railway;

  /// Short name for the ribbon.  An explicit --dart-define=API_BASE shows its
  /// host, since neither label would be true.
  static String get backendLabel {
    if (baseUrl == _railway) return 'PROD';
    if (baseUrl == _local)   return 'LOCAL';
    return Uri.tryParse(baseUrl)?.host ?? 'CUSTOM';
  }

  /// Public App Store listing — the "Update" button on the blocking
  /// update-required screen sends users here.
  static const String appStoreUrl = 'https://apps.apple.com/app/id6768284628';
}
