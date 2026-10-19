// The picker's near-me states — the design's own contract.
//
// `handoff-near-me` specifies four states and the copy for each, and the
// states are what an edit to this 460-line widget breaks silently. The copy
// strings are asserted verbatim because they are verbatim in the handoff.
//
// The location call is injected (`nearMeOverride`): `Geolocator` has no
// platform binding under `flutter test`, so the real path cannot be driven
// here. What it returns is exactly what `coursesNearMe` returns, and
// `near_me_test.dart` is what pins that it returns the right thing.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/client.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/providers/auth_provider.dart';
import 'package:golf_mobile/utils/near_me.dart';
import 'package:golf_mobile/widgets/course_search_field.dart';
import 'package:provider/provider.dart';

const _home = CourseInfo(id: 7, name: 'Tilden Park', city: 'Berkeley',
    state: 'CA');
const _recent = CourseInfo(id: 8, name: 'Metropolitan', city: 'Oakland',
    state: 'CA');

class _StubClient extends ApiClient {
  const _StubClient() : super(token: 't');
  @override
  Future<List<CourseInfo>> getCourses() async => const [_home, _recent];
  @override
  Future<List<CourseInfo>> getRecentCourses() async => const [_recent];
}

class _FakeAuth extends AuthProvider {
  @override
  ApiClient get client => const _StubClient();
  @override
  PlayerProfile? get player => null;   // no home course: keeps RECENT only
}

Future<void> _pump(
  WidgetTester tester, {
  required Future<NearMeResult> Function(ApiClient) nearMe,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: ChangeNotifierProvider<AuthProvider>.value(
      value: _FakeAuth(),
      child: Scaffold(
        body: SingleChildScrollView(
          child: CourseSearchField(
            selected: null,
            onSelected: (_) {},
            nearMeOverride: nearMe,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<NearMeResult> _ok(ApiClient _) async => const NearMeResult(
      NearMeOutcome.ok,
      [
        CourseHit(source: 'account', name: 'Poppy Hills', city: 'Pebble Beach',
            state: 'CA', distanceMiles: 1),
        CourseHit(source: 'api', name: 'Spyglass Hill', city: 'Pebble Beach',
            state: 'CA', distanceMiles: 12),
      ],
    );

/// `testWidgets`, with the platform forced to iOS for the body.
///
/// Two things make this necessary rather than a `setUp`. `defaultTargetPlatform`
/// is **android** under `flutter test`, and the pill is deliberately not
/// offered there yet (`nearMeOffered`) — so without the override every test
/// below would assert against a widget that is correctly hidden. And the
/// binding checks that no foundation debug variable outlives the test BODY,
/// which runs before any `tearDown`, so it has to be reset in here.
void _testOnIOS(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  _testOnIOS('idle shows the pill and nothing has been located', (t) async {
    await _pump(t, nearMe: _ok);
    expect(find.text('Courses near me'), findsOneWidget);
    expect(find.text('Near you'), findsNothing);
    expect(find.text('Finding courses near you…'), findsNothing);
  });

  _testOnIOS('the whole pill is tappable, not just the icon', (t) async {
    // The reported failure mode on the Spots button: a control whose target
    // is the glyph. Tapping near the pill's trailing edge must work.
    var called = false;
    await _pump(t, nearMe: (c) async {
      called = true;
      return _ok(c);
    });
    final box = t.getRect(find.text('Courses near me'));
    await t.tapAt(Offset(box.right + 40, box.center.dy));
    await t.pumpAndSettle();
    expect(called, isTrue);
  });

  _testOnIOS('results replace the pill with Near you and Clear', (t) async {
    await _pump(t, nearMe: _ok);
    await t.tap(find.text('Courses near me'));
    await t.pumpAndSettle();

    expect(find.text('NEAR YOU'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Courses near me'), findsNothing);
    expect(find.text('Poppy Hills'), findsOneWidget);
    expect(find.text('Spyglass Hill'), findsOneWidget);
  });

  _testOnIOS('the distance is whole miles', (t) async {
    // Not `1.2 mi`: the anchor is cut to ~1.1 km, so a tenth is a digit
    // nobody has.
    await _pump(t, nearMe: _ok);
    await t.tap(find.text('Courses near me'));
    await t.pumpAndSettle();
    expect(find.text('1 mi'), findsOneWidget);
    expect(find.text('12 mi'), findsOneWidget);
  });

  _testOnIOS('RECENT is hidden while near-me results show', (t) async {
    await _pump(t, nearMe: _ok);
    expect(find.text('RECENT'), findsOneWidget);

    await t.tap(find.text('Courses near me'));
    await t.pumpAndSettle();
    expect(find.text('RECENT'), findsNothing,
        reason: 'two lists of courses, one headed Near you, is unreadable');
  });

  _testOnIOS('Clear returns to the pill and brings RECENT back', (t) async {
    await _pump(t, nearMe: _ok);
    await t.tap(find.text('Courses near me'));
    await t.pumpAndSettle();
    await t.tap(find.text('Clear'));
    await t.pumpAndSettle();

    expect(find.text('Courses near me'), findsOneWidget);
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.text('NEAR YOU'), findsNothing);
  });

  _testOnIOS('an empty result says so, and keeps Clear', (t) async {
    // An answer, not a failure: it must not drop back to the pill silently
    // nor tell the golfer to check his settings over an empty county.
    await _pump(t,
        nearMe: (_) async => const NearMeResult(NearMeOutcome.ok, []));
    await t.tap(find.text('Courses near me'));
    await t.pumpAndSettle();
    expect(find.text('No courses within 25 mi.'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
  });

  group('the failure lines', () {
    _testOnIOS('denied keeps the pill, explains, and offers NO Settings',
        (t) async {
      await _pump(t,
          nearMe: (_) async => const NearMeResult(NearMeOutcome.denied));
      await t.tap(find.text('Courses near me'));
      await t.pumpAndSettle();

      expect(find.text('Location is off. Search by name instead.'),
          findsOneWidget);
      expect(find.text('Courses near me'), findsOneWidget);
      expect(find.text('Settings'), findsNothing,
          reason: '"not now" must not send him to a screen he does not need');
    });

    _testOnIOS('deniedForever is the one that offers Settings', (t) async {
      await _pump(t,
          nearMe: (_) async =>
              const NearMeResult(NearMeOutcome.deniedForever));
      await t.tap(find.text('Courses near me'));
      await t.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
    });

    _testOnIOS('a timeout says try again, not that location is off',
        (t) async {
      await _pump(t,
          nearMe: (_) async => const NearMeResult(NearMeOutcome.timedOut));
      await t.tap(find.text('Courses near me'));
      await t.pumpAndSettle();
      expect(find.text("Couldn't get your location. Try again."),
          findsOneWidget);
    });

    _testOnIOS('a failed lookup names the search, not the location',
        (t) async {
      await _pump(t,
          nearMe: (_) async => const NearMeResult(NearMeOutcome.failed));
      await t.tap(find.text('Courses near me'));
      await t.pumpAndSettle();
      expect(find.text("Couldn't search for courses near you. Try again."),
          findsOneWidget);
    });
  });

  _testOnIOS('typing returns to the normal list', (t) async {
    await _pump(t, nearMe: _ok);
    await t.tap(find.text('Courses near me'));
    await t.pumpAndSettle();
    expect(find.text('NEAR YOU'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'peb');
    await t.pumpAndSettle();
    expect(find.text('NEAR YOU'), findsNothing);
  });
}
