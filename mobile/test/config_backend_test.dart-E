/// What backend does this build talk to?
///
/// USE_LOCAL defaults to FALSE, so a plain `flutter run` — on the simulator as
/// much as on a phone — points at Railway PRODUCTION. That default is the whole
/// reason the ribbon exists: a debug build wired to prod is indistinguishable
/// from a local one on screen, and test data lands in the real account.
///
/// These run with no --dart-define, so they assert the DEFAULT.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/config.dart';

void main() {
  test('a plain run points at production, not local', () {
    expect(Config.isProd, isTrue);
    expect(Config.backendLabel, 'PROD');
    expect(Config.baseUrl, contains('railway'));
  });

  test('the label never comes back empty, so the ribbon always says something',
      () {
    expect(Config.backendLabel.trim(), isNotEmpty);
  });
}
