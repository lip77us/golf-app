// The Find a course screen (`handoff-find-a-course`): search, Courses near me,
// Near you and Recents. The location call is injected (`nearMeOverride`) —
// `Geolocator` has no platform binding under `flutter test`.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/client.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/providers/auth_provider.dart';
import 'package:golf_mobile/screens/course_find_screen.dart';
import 'package:golf_mobile/utils/near_me.dart';
import 'package:provider/provider.dart';

const _tilden = CourseInfo(id: 1, name: 'Tilden Park GC', city: 'Berkeley',
    state: 'CA');
const _harding = CourseInfo(id: 2, name: 'TPC Harding Park',
    city: 'San Francisco', state: 'CA');

class _Stub extends ApiClient {
  _Stub({this.hits = const [], this.recents = const []})
      : super(token: 't');
  final List<CourseHit> hits;
  final List<RecentPlay> recents;
  @override
  Future<List<RecentPlay>> getRecentPlays() async => recents;
  @override
  Future<List<CourseInfo>> getCourses() async => const [_tilden, _harding];
  @override
  Future<CourseInfo> getCourse(int id) async =>
      CourseInfo(id: id, name: 'Claremont CC', city: 'Oakland', state: 'CA');
  @override
  Future<CourseInfo> addCatalogCourse(int id) async =>
      CourseInfo(id: 60 + id, name: 'Clarksburg GC');
  @override
  Future<CourseInfo> importApiCourse(String id) async =>
      const CourseInfo(id: 70, name: 'Claypool Links');
  @override
  Future<CourseSearchResult> findCourses(String q) async =>
      CourseSearchResult(hits: [
        for (final h in hits)
          if (h.name.toLowerCase().contains(q.toLowerCase()) ||
              h.city.toLowerCase().contains(q.toLowerCase()))
            h
      ]);
}

class _Auth extends AuthProvider {
  _Auth(this._c);
  final ApiClient _c;
  @override
  ApiClient get client => _c;
}

final _recents = [
  RecentPlay(
      course: _tilden,
      lastPlayed: DateTime.now().subtract(const Duration(days: 2)),
      teeName: 'White',
      isHome: true),
  RecentPlay(
      course: _harding,
      lastPlayed: DateTime(2026, 10, 4),
      teeName: 'Blue'),
];

CourseFindResult? _result;

Future<void> _open(
  WidgetTester t, {
  _Stub? client,
  Future<NearMeResult> Function(ApiClient)? nearMe,
}) async {
  _result = null;
  await t.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
    value: _Auth(client ?? _Stub(recents: _recents)),
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                _result = await Navigator.of(ctx).push<CourseFindResult>(
                  MaterialPageRoute(
                      builder: (_) =>
                          CourseFindScreen(nearMeOverride: nearMe)),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

Future<NearMeResult> _ok(ApiClient _) async => const NearMeResult(
      NearMeOutcome.ok, [
        CourseHit(source: 'account', name: 'Poppy Hills', city: 'Pebble Beach',
            state: 'CA', distanceMiles: 1),
        CourseHit(source: 'catalog', name: 'Spyglass Hill', city: 'Pebble Beach',
            state: 'CA', distanceMiles: 6),
      ]);

void _onIOS(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await body(t);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  group('the start state', () {
    _onIOS('says what it is and offers near me, located nowhere', (t) async {
      await _open(t);
      expect(find.text('Find a course'), findsOneWidget);
      expect(find.text('Where are you playing today?'), findsOneWidget);
      expect(find.text('Courses near me'), findsOneWidget);
      expect(find.text('uses your location once'), findsOneWidget);
      expect(find.text('NEAR YOU'), findsNothing);
    });

    _onIOS('Recents: five at most, with town · tees and a date pill', (t) async {
      await _open(t);
      expect(find.text('RECENTS'), findsOneWidget);
      expect(find.text('Berkeley, CA · White tees'), findsOneWidget);
      expect(find.text('San Francisco, CA · Blue tees'), findsOneWidget);
      expect(find.text('Oct 4'), findsOneWidget);
    });

    _onIOS('the home course gets Home · and its day', (t) async {
      await _open(t);
      expect(find.textContaining('Home · '), findsOneWidget);
    });

    _onIOS('no recents, no section', (t) async {
      await _open(t, client: _Stub());
      expect(find.text('RECENTS'), findsNothing);
    });
  });

  group('picking a recent', () {
    _onIOS('returns the course AND its tees', (t) async {
      await _open(t);
      await t.tap(find.text('TPC Harding Park'));
      await t.pumpAndSettle();
      expect(_result!.course.id, 2);
      expect(_result!.teeName, 'Blue');
      expect(_result!.toast, 'TPC Harding Park · playing today');
    });

    _onIOS('back returns nothing', (t) async {
      await _open(t);
      await t.tap(find.text('‹'));
      await t.pumpAndSettle();
      expect(_result, isNull);
      expect(find.text('open'), findsOneWidget);
    });
  });

  group('Courses near me', () {
    _onIOS('results show Near you with whole-mile pills and Clear', (t) async {
      await _open(t, nearMe: _ok);
      await t.tap(find.byKey(const ValueKey('near-me')));
      await t.pumpAndSettle();
      expect(find.text('NEAR YOU'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('Poppy Hills'), findsOneWidget);
      expect(find.text('1 mi'), findsOneWidget);
      expect(find.text('6 mi'), findsOneWidget);
      expect(find.text('updated just now'), findsOneWidget);
      // Recents stay: a Near you list does not hide them.
      expect(find.text('RECENTS'), findsOneWidget);
    });

    _onIOS('Clear removes the section', (t) async {
      await _open(t, nearMe: _ok);
      await t.tap(find.byKey(const ValueKey('near-me')));
      await t.pumpAndSettle();
      await t.tap(find.text('Clear'));
      await t.pumpAndSettle();
      expect(find.text('NEAR YOU'), findsNothing);
      expect(find.text('uses your location once'), findsOneWidget);
    });

    _onIOS('locating is not tappable and says so', (t) async {
      var calls = 0;
      await _open(t, nearMe: (c) async {
        calls++;
        await Future<void>.delayed(const Duration(seconds: 5));
        return _ok(c);
      });
      await t.tap(find.byKey(const ValueKey('near-me')));
      await t.pump();
      expect(find.text('Finding courses near you…'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('near-me')));
      await t.pump();
      expect(calls, 1);
      await t.pumpAndSettle(const Duration(seconds: 6));
    });

    for (final o in [
      NearMeOutcome.denied,
      NearMeOutcome.deniedForever,
      NearMeOutcome.serviceOff,
    ]) {
      _onIOS('$o: Location is off, and nothing else', (t) async {
        await _open(t, nearMe: (_) async => NearMeResult(o));
        await t.tap(find.byKey(const ValueKey('near-me')));
        await t.pumpAndSettle();
        expect(find.text('Location is off'), findsOneWidget);
        expect(find.text('search still works'), findsOneWidget);
        expect(find.text('Settings'), findsNothing);
        // Recents and search carry on exactly as normal.
        expect(find.text('RECENTS'), findsOneWidget);
      });
    }

    _onIOS('a timeout just returns to ready, with no second error', (t) async {
      await _open(t,
          nearMe: (_) async => const NearMeResult(NearMeOutcome.timedOut));
      await t.tap(find.byKey(const ValueKey('near-me')));
      await t.pumpAndSettle();
      expect(find.text('Courses near me'), findsOneWidget);
      expect(find.text('Location is off'), findsNothing);
    });

    _onIOS('an empty answer says so and keeps Clear', (t) async {
      await _open(t,
          nearMe: (_) async => const NearMeResult(NearMeOutcome.ok, []));
      await t.tap(find.byKey(const ValueKey('near-me')));
      await t.pumpAndSettle();
      expect(find.text('No courses within 8 mi.'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });

    _onIOS('Near you is not remembered next time', (t) async {
      await _open(t, nearMe: _ok);
      await t.tap(find.byKey(const ValueKey('near-me')));
      await t.pumpAndSettle();
      await t.tap(find.text('‹'));
      await t.pumpAndSettle();
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('NEAR YOU'), findsNothing);
    });
  });

  group('searching', () {
    final hits = [
      const CourseHit(source: 'account', name: 'Claremont CC',
          city: 'Oakland', state: 'CA', courseId: 5, inAccount: true),
      const CourseHit(source: 'catalog', name: 'Clarksburg GC',
          city: 'Clarksburg', state: 'CA', catalogId: 6),
      const CourseHit(source: 'api', name: 'Claypool Links',
          city: 'Richmond', state: 'CA', golfApiId: 'x'),
    ];

    _onIOS('typing replaces everything below the bar with Results', (t) async {
      await _open(t, client: _Stub(hits: hits, recents: _recents));
      await t.enterText(find.byType(TextField), 'cla');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.text('RESULTS'), findsOneWidget);
      expect(find.text('RECENTS'), findsNothing);
      expect(find.text('Courses near me'), findsNothing);
    });

    _onIOS('every result carries its tag', (t) async {
      await _open(t, client: _Stub(hits: hits, recents: _recents));
      await t.enterText(find.byType(TextField), 'cla');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.text('Yours'), findsOneWidget);
      expect(find.text('Catalog'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
    });

    _onIOS('town matches too', (t) async {
      await _open(t, client: _Stub(hits: hits, recents: _recents));
      await t.enterText(find.byType(TextField), 'oakland');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.text('Claremont CC'), findsOneWidget);
    });

    _onIOS('no match is one line, naming the search', (t) async {
      await _open(t, client: _Stub(hits: hits, recents: _recents));
      await t.enterText(find.byType(TextField), 'clazzz');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.text('No course matches "clazzz". Try the town.'),
          findsOneWidget);
    });

    _onIOS('clearing the text brings the browse view back', (t) async {
      await _open(t, client: _Stub(hits: hits, recents: _recents));
      await t.enterText(find.byType(TextField), 'cla');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('clear')));
      await t.pumpAndSettle();
      expect(find.text('RECENTS'), findsOneWidget);
    });

    Future<void> pick(WidgetTester t, String q, String name) async {
      await _open(t, client: _Stub(hits: hits, recents: _recents));
      await t.enterText(find.byType(TextField), q);
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.tap(find.text(name));
      await t.pumpAndSettle();
    }

    _onIOS('one of yours is "playing today", with no tees', (t) async {
      await pick(t, 'claremont', 'Claremont CC');
      expect(_result!.toast, 'Claremont CC · playing today');
      expect(_result!.teeName, isNull);
    });

    _onIOS('a catalog course is added to yours', (t) async {
      await pick(t, 'clarks', 'Clarksburg GC');
      expect(_result!.toast, 'Clarksburg GC · added to your courses');
    });

    _onIOS('an Add course is created, then returned', (t) async {
      await pick(t, 'claypool', 'Claypool Links');
      expect(_result!.course.id, 70);
      expect(_result!.toast, 'Claypool Links · added to your courses');
    });
  });

  group('recentWhen', () {
    final now = DateTime(2026, 11, 14); // a Saturday
    test('this week is the weekday', () {
      expect(recentWhen(DateTime(2026, 11, 14), now), 'Sat');
      expect(recentWhen(DateTime(2026, 11, 12), now), 'Thu');
    });
    test('older is month and day', () {
      expect(recentWhen(DateTime(2026, 11, 7), now), 'Nov 7');
      expect(recentWhen(DateTime(2026, 10, 18), now), 'Oct 18');
    });
    test('unknown is blank', () {
      expect(recentWhen(null, now), '');
    });
  });
}
