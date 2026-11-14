// Which course a new round starts on: the home course immediately, then the
// course the phone says you are at — never waiting for the phone, never
// prompting, never sending the position anywhere.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:golf_mobile/api/client.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/providers/auth_provider.dart';
import 'package:golf_mobile/utils/default_course.dart';
import 'package:golf_mobile/widgets/course_bar.dart';
import 'package:provider/provider.dart';

// Tilden Park, and a course about 0.3 mi away, and one ~4 mi away.
const _tilden = CourseInfo(id: 1, name: 'Tilden Park GC', city: 'Berkeley',
    state: 'CA', latitude: 37.9150, longitude: -122.2430);
const _near = CourseInfo(id: 2, name: 'Next Door', latitude: 37.9190,
    longitude: -122.2430); // ~0.28 mi north
const _far = CourseInfo(id: 3, name: 'Claremont CC', latitude: 37.8480,
    longitude: -122.2330);
const _blank = CourseInfo(id: 4, name: 'No Coordinates');

/// `testWidgets` on iOS: near-me is not offered on Android yet
/// (`nearMeOffered`), and `flutter test` runs as Android.
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
  group('the distance rule', () {
    test('a degree of latitude is about 69 miles', () {
      expect(milesBetween(37, -122, 38, -122), closeTo(69.1, 0.3));
    });

    test('within half a mile picks the course, not the one a road away', () {
      final c = nearestWithin(
          [_tilden, _near, _far], 37.9152, -122.2430);
      expect(c, _tilden);
    });

    test('nobody within range is null', () {
      expect(nearestWithin([_far], 37.9150, -122.2430), isNull);
    });

    test('a course with no coordinates is never a match', () {
      expect(nearestWithin([_blank], 37.9, -122.2), isNull);
    });

    test('the radius is half a mile, not a tenth', () {
      expect(kHereMiles, 0.5);
      // ~0.28 mi: outside a tenth, inside the radius we use.
      expect(nearestWithin([_near], 37.9150, -122.2430), _near);
    });

    test('home is the course with the home id, or null', () {
      expect(homeCourse([_tilden, _far], 3), _far);
      expect(homeCourse([_tilden], null), isNull);
      expect(homeCourse([_tilden], 99), isNull);
    });
  });

  group('the quiet fix', () {
    test('never prompts: a permission not yet asked is a no', () async {
      var asked = false;
      final p = await quietPosition(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.denied,
        getPosition: () async {
          asked = true;
          throw StateError('must not be reached');
        },
      );
      expect(p, isNull);
      expect(asked, isFalse);
    });

    test('permission already granted gives the fix', () async {
      final p = await quietPosition(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.whileInUse,
        getPosition: () async => Position(
            latitude: 37.9, longitude: -122.2, timestamp: DateTime.now(),
            accuracy: 5, altitude: 0, altitudeAccuracy: 0, heading: 0,
            headingAccuracy: 0, speed: 0, speedAccuracy: 0),
      );
      expect(p, (lat: 37.9, lon: -122.2));
    });

    test('location switched off is a no', () async {
      final p = await quietPosition(
        isServiceEnabled: () async => false,
        checkPermission: () async => LocationPermission.always,
        getPosition: () async => throw StateError('no'),
      );
      expect(p, isNull);
    });

    test('a slow phone is given up on, not waited for', () async {
      final started = DateTime.now();
      final p = await quietPosition(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.whileInUse,
        getPosition: () => Completer<Position>().future, // never answers
        timeout: const Duration(milliseconds: 50),
      );
      expect(p, isNull);
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(1000));
    });

    test('the budget is two seconds', () {
      expect(kHereTimeout, const Duration(seconds: 2));
    });

    test('an error is a no, never a throw', () async {
      final p = await quietPosition(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.whileInUse,
        getPosition: () async => throw Exception('boom'),
      );
      expect(p, isNull);
    });
  });

  group('courseHere', () {
    test('is not offered off iOS, and does not even ask for a fix', () async {
      var asked = false;
      final c = await courseHere([_tilden],
          offered: false, position: () async { asked = true; return null; });
      expect(c, isNull);
      expect(asked, isFalse);
    });

    test('no course has coordinates: skips the fix entirely', () async {
      var asked = false;
      await courseHere([_blank],
          offered: true, position: () async { asked = true; return null; });
      expect(asked, isFalse);
    });

    test('finds the course the phone is at', () async {
      final c = await courseHere([_tilden, _far],
          offered: true, position: () async => (lat: 37.9151, lon: -122.2431));
      expect(c, _tilden);
    });
  });

  group('the course bar fills itself in', () {
    PlayerProfile? me;
    CourseInfo? chosen;
    final defaulted = <int>[];

    Future<void> pump(
      WidgetTester t, {
      int? homeId,
      Future<({double lat, double lon})?> Function()? position,
      CourseInfo? selected,
      bool preselect = true,
    }) async {
      chosen = selected;
      defaulted.clear();
      me = homeId == null ? null : _profile(homeId);
      await t.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: _Auth(me),
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (ctx, set) => CourseBar(
                selected: chosen,
                preselectDefault: preselect,
                positionOverride: position,
                onDefaulted: (c) => defaulted.add(c.id),
                onSelected: (c) => set(() => chosen = c),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
      await t.pump();
    }

    _onIOS('the home course, at once, before the phone answers',
        (t) async {
      final slow = Completer<({double lat, double lon})?>();
      await pump(t, homeId: 1, position: () => slow.future);
      expect(chosen?.id, 1, reason: 'home first; the phone has not answered');
      expect(find.text('(Home Course)'), findsOneWidget);
      slow.complete(null);
      await t.pump();
      expect(chosen?.id, 1);
    });

    _onIOS('no home course: blank, never an error', (t) async {
      await pump(t, position: () async => null);
      expect(chosen, isNull);
      expect(find.text('Find a course'), findsWidgets);
    });

    _onIOS('standing at another of your courses swaps to it', (t) async {
      await pump(t, homeId: 1,
          position: () async => (lat: 37.8480, lon: -122.2330));
      await t.pump();
      expect(chosen?.id, 3);
      expect(defaulted, [1, 3], reason: 'home, then the one you are at');
    });

    _onIOS('standing at nothing of yours keeps home', (t) async {
      await pump(t, homeId: 1, position: () async => (lat: 0.0, lon: 0.0));
      await t.pump();
      expect(chosen?.id, 1);
    });

    _onIOS('a failed fix keeps home', (t) async {
      await pump(t, homeId: 1, position: () async => null);
      await t.pump();
      expect(chosen?.id, 1);
    });

    _onIOS('no home and standing at a course: starts there', (t) async {
      await pump(t, position: () async => (lat: 37.9151, lon: -122.2431));
      await t.pump();
      expect(chosen?.id, 1);
    });

    _onIOS('a golfer who already chose is never overridden', (t) async {
      await pump(t, homeId: 1, selected: _far,
          position: () async => (lat: 37.9151, lon: -122.2431));
      await t.pump();
      expect(chosen?.id, 3);
      expect(defaulted, isEmpty);
    });

    _onIOS('a form that did not ask for a default stays blank', (t) async {
      await pump(t, homeId: 1, preselect: false,
          position: () async => (lat: 37.9151, lon: -122.2431));
      await t.pump();
      expect(chosen, isNull);
    });

    _onIOS('a late swap is dropped once he has touched the course',
        (t) async {
      final late = Completer<({double lat, double lon})?>();
      await pump(t, homeId: 1, position: () => late.future);
      await t.tap(find.byKey(const ValueKey('course-bar')));
      await t.pumpAndSettle(); // the finder screen opens (and fails to load)
      late.complete((lat: 37.8480, lon: -122.2330));
      await t.pump();
      expect(chosen?.id, 1, reason: 'the swap landed after he touched it');
    });
  });
}

PlayerProfile _profile(int homeId) => PlayerProfile(
      id: 9, name: 'Me', handicapIndex: '10.0', isPhantom: false, email: '',
      homeCourseId: homeId);

class _Stub extends ApiClient {
  _Stub() : super(token: 't');
  @override
  Future<List<CourseInfo>> getCourses() async =>
      const [_tilden, _near, _far, _blank];
  @override
  Future<List<RecentPlay>> getRecentPlays() async => const [];
}

class _Auth extends AuthProvider {
  _Auth(this._p);
  final PlayerProfile? _p;
  @override
  ApiClient get client => _Stub();
  @override
  PlayerProfile? get player => _p;
}
