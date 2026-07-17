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
/// In VS Code, use the "Golf (Local)" or "Golf (Railway)" launch configs.

import 'package:package_info_plus/package_info_plus.dart';

class Config {
  static const bool _useLocal =
      bool.fromEnvironment('USE_LOCAL', defaultValue: false);

  static const String _railway = 'https://web-production-b84d4a.up.railway.app/api';
  static const String _local   = 'http://localhost:8000/api';

  static const String baseUrl = _useLocal ? _local : _railway;

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

  /// Public App Store listing — the "Update" button on the blocking
  /// update-required screen sends users here.
  static const String appStoreUrl = 'https://apps.apple.com/app/id6768284628';
}
