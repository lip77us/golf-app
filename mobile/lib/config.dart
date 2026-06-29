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

class Config {
  static const bool _useLocal =
      bool.fromEnvironment('USE_LOCAL', defaultValue: false);

  static const String _railway = 'https://web-production-b84d4a.up.railway.app/api';
  static const String _local   = 'http://localhost:8000/api';

  static const String baseUrl = _useLocal ? _local : _railway;

  /// The version string of this build.  Must be kept in sync with
  /// pubspec.yaml's `version:` field (the part before the `+`).  The
  /// server's GET /api/version/ endpoint returns a min_client_version;
  /// if this value is older the app will show a blocking update dialog.
  ///
  /// TODO: read this from pubspec at build time via package_info_plus
  /// so we stop having two sources of truth.
  static const String appVersion = '2.2.0';

  /// Public App Store listing — the "Update" button on the blocking
  /// update-required screen sends users here.
  static const String appStoreUrl = 'https://apps.apple.com/app/id6768284628';
}
