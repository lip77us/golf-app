import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The texted receipt link reaching the receipt — the Android half, and the
/// push tap.
///
/// Source guards: `_handleTap` is private and static, and the manifest is
/// XML, so neither is reachable from a widget test.  What they pin is the
/// WIRING, which is the thing that was missing in both places.
void main() {
  group('the android app link', () {
    final manifest = File(
        'android/app/src/main/AndroidManifest.xml').readAsStringSync();

    test('claims the receipt path as well as the watch path', () {
      expect(manifest, contains('android:pathPrefix="/watch/"'));
      expect(manifest, contains('android:pathPrefix="/r/"'),
          reason: 'a texted receipt link opens the browser without it');
    });

    test('both sit in the verified filter, on the link host', () {
      // Outside `autoVerify`, Android shows a disambiguation dialog instead
      // of opening the app; on the wrong host it never matches at all.
      final start = manifest.indexOf('android:autoVerify="true"');
      expect(start, greaterThan(-1));
      final filter = manifest.substring(
          start, manifest.indexOf('</intent-filter>', start));
      // The ATTRIBUTE, not the bare substring — a comment mentioning the
      // path would satisfy that and say nothing.
      expect(RegExp(r'android:pathPrefix="/r/"').allMatches(filter).length, 1);
      expect(RegExp(r'android:host="link\.halved\.golf"')
          .allMatches(filter).length, 2,
          reason: 'each data element needs its own host');
    });
  });

  group('the receipt push', () {
    final src = File('lib/services/push_service.dart').readAsStringSync();
    final tap = src.substring(src.indexOf('static void _handleTap'));

    test('is routed before the round id is read', () {
      // The receipt push carries a `round_id` like every other event, so a
      // branch placed after it can never run: the tap opens the leaderboard
      // and the `code` it carries is read by nothing.
      final branch = tap.indexOf("m.data['type'] == 'receipt'");
      final roundId = tap.indexOf("m.data['round_id']");
      expect(branch, greaterThan(-1), reason: 'no receipt branch at all');
      expect(branch, lessThan(roundId),
          reason: 'the receipt branch must come first or it is unreachable');
    });

    test('goes through the deep-link queue, not its own navigator push', () {
      // A tap has the same cold-start problem a link does — auth restoring,
      // splash still up — and `DeepLinkService._flush` already solves it. A
      // second opener is a second copy of that retry.
      final branch = tap.substring(tap.indexOf("m.data['type'] == 'receipt'"));
      final body = branch.substring(0, branch.indexOf("m.data['round_id']"));
      expect(body, contains('handleLink'));
      expect(body, isNot(contains('pushNamed')),
          reason: 'the queue owns the navigation');
    });

    test('still lands somewhere when the queue cannot take it', () {
      // No service, or a url that will not parse: fall through to the
      // round's board. Landing somewhere related beats landing nowhere.
      expect(tap, contains("pushNamed('/leaderboard'"));
    });
  });
}
