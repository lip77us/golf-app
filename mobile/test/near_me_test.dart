// Courses near me — the privacy guarantee and the failure tree.
//
// What is worth pinning here is NOT that the pill draws. It is the two things
// a refactor can quietly undo:
//
//  * the position is cut to two decimal places before it is sent, which is
//    what earns the Coarse Location declaration (see
//    `docs/location-permission.md`), and
//  * each way of failing resolves to its OWN outcome, because the picker says
//    something different for each and only one of them may offer Settings.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:golf_mobile/api/client.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/coarse_position.dart';
import 'package:golf_mobile/utils/near_me.dart';

Position _at(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.utc(2026, 10, 19),
      accuracy: 1000,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// Records the coordinates it is asked for instead of calling the network.
class _SpyClient extends ApiClient {
  _SpyClient() : super(token: 't');
  double? lat, lng;
  bool explode = false;

  @override
  Future<List<CourseHit>> findCoursesNear(double a, double b,
      {int radiusMiles = 25}) async {
    lat = a;
    lng = b;
    if (explode) throw Exception('offline');
    return const [
      CourseHit(source: 'account', name: 'Spyglass', distanceMiles: 1),
    ];
  }
}

Future<NearMeResult> _run(
  _SpyClient client, {
  bool service = true,
  LocationPermission permission = LocationPermission.whileInUse,
  LocationPermission? afterRequest,
  Future<Position> Function()? position,
}) =>
    coursesNearMe(
      client,
      isServiceEnabled: () async => service,
      checkPermission: () async => permission,
      requestPermission: () async => afterRequest ?? permission,
      getPosition: position ?? (() async => _at(36.5683219, -121.9500777)),
    );

void main() {
  group('the position is cut before it is sent', () {
    test('two decimal places, rounded not truncated', () {
      expect(coarsenForPrivacy(36.5689), '36.57');
      expect(coarsenForPrivacy(-121.9499), '-121.95');
    });

    test('it returns a String so the places cannot grow back', () {
      // A double would be a value somebody could re-format with six places.
      expect(coarsenForPrivacy(36.5), isA<String>());
      expect(coarsenForPrivacy(36.5), '36.50');
    });

    test('never more than two places, whatever comes in', () {
      for (final v in [0.0, 1.0 / 3, -89.999999, 179.987654321, 36.5683219]) {
        final places = coarsenForPrivacy(v).split('.')[1].length;
        expect(places, 2, reason: '$v produced ${coarsenForPrivacy(v)}');
      }
    });

    test('the number of places is the constant, not a literal', () {
      expect(kCoarseDecimals, 2);
      expect(coarsenForPrivacy(1.23456).split('.')[1].length, kCoarseDecimals);
    });
  });

  group('the failure tree', () {
    test('a fix reaches the client and returns its courses', () async {
      final c = _SpyClient();
      final r = await _run(c);
      expect(r.outcome, NearMeOutcome.ok);
      expect(r.courses.single.name, 'Spyglass');
      expect(c.lat, isNotNull);
    });

    test('location switched off is asked BEFORE permission', () async {
      // The permission prompt would be a question whose yes changes nothing.
      var asked = false;
      final r = await coursesNearMe(
        _SpyClient(),
        isServiceEnabled: () async => false,
        checkPermission: () async {
          asked = true;
          return LocationPermission.denied;
        },
        requestPermission: () async => LocationPermission.whileInUse,
        getPosition: () async => _at(1, 1),
      );
      expect(r.outcome, NearMeOutcome.serviceOff);
      expect(asked, isFalse, reason: 'permission was checked anyway');
    });

    test('denied is asked for once, then reported as denied', () async {
      var requests = 0;
      final r = await coursesNearMe(
        _SpyClient(),
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.denied,
        requestPermission: () async {
          requests++;
          return LocationPermission.denied;
        },
        getPosition: () async => _at(1, 1),
      );
      expect(r.outcome, NearMeOutcome.denied);
      expect(requests, 1, reason: 'the OS must not be prompted in a loop');
    });

    test('deniedForever is its own outcome, not denied', () async {
      // It is the ONLY one that may offer Settings: the OS will never prompt
      // again. Collapsing the two would send a golfer who simply said "not
      // now" to a settings screen he does not need.
      final r = await _run(_SpyClient(),
          permission: LocationPermission.deniedForever);
      expect(r.outcome, NearMeOutcome.deniedForever);
    });

    test('a granted permission does not re-prompt', () async {
      var requests = 0;
      await coursesNearMe(
        _SpyClient(),
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async {
          requests++;
          return LocationPermission.always;
        },
        getPosition: () async => _at(1, 1),
      );
      expect(requests, 0);
    });

    test('no fix in time is timedOut', () async {
      final r = await _run(_SpyClient(),
          position: () => Future.error(TimeoutException('no fix')));
      expect(r.outcome, NearMeOutcome.timedOut);
    });

    test('switched off DURING the fix is serviceOff, not a timeout',
        () async {
      final r = await _run(_SpyClient(),
          position: () =>
              Future.error(const LocationServiceDisabledException()));
      expect(r.outcome, NearMeOutcome.serviceOff);
    });

    test('a position that arrives and a lookup that fails is failed',
        () async {
      // Distinct from timedOut on purpose: naming the wrong step would send
      // the golfer to his location settings over a network problem.
      final c = _SpyClient()..explode = true;
      final r = await _run(c);
      expect(r.outcome, NearMeOutcome.failed);
    });

    test('an empty result is ok, not a failure', () async {
      // "No courses within 25 mi" is an answer. Drawing it as a failure
      // would tell a golfer to check his settings over an empty county.
      final r = await coursesNearMe(
        _EmptyClient(),
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.whileInUse,
        requestPermission: () async => LocationPermission.whileInUse,
        getPosition: () async => _at(36.57, -121.95),
      );
      expect(r.outcome, NearMeOutcome.ok);
      expect(r.courses, isEmpty);
      expect(r.ok, isTrue);
    });
  });

  group('the platform gate', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('iOS is offered', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(nearMeOffered, isTrue);
    });

    test('Android is NOT, until the manifest and Data safety land together',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(nearMeOffered, isFalse);
    });
  });
}

class _EmptyClient extends ApiClient {
  _EmptyClient() : super(token: 't');
  @override
  Future<List<CourseHit>> findCoursesNear(double a, double b,
          {int radiusMiles = 25}) async =>
      const [];
}
