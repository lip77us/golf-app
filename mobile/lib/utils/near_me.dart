/// One location fix, on a tap, for the course picker's "Courses near me".
///
/// The rules this file exists to keep, from `docs/location-permission.md` and
/// the near-me handoff:
///
///  * **Nothing here runs unless the golfer taps.** No prefetch on picker
///    open, app launch or round start. It is also a quota rule: the upstream
///    proximity call is a new line against a 10k/day allowance.
///  * **One fix, then stop.** `getCurrentPosition`, never a stream, never a
///    background update.
///  * **Reduced accuracy**, asked for explicitly. A 25-mile search cannot use
///    a 5 m fix.
///  * **Every failure has a name**, because the picker has to say something
///    different for each: location switched off at the device, refused now,
///    refused permanently (which is the only one that can offer Settings),
///    and no fix in time.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:geolocator/geolocator.dart';

import '../api/client.dart';
import '../api/models.dart';

/// Whether to OFFER "Courses near me" at all on this platform.
///
/// **False on Android, deliberately, and this is the one line to flip.**
/// iOS ships first (Paul, 19 Oct 2026: "initially on the iphone and
/// eventually on Android after we are accepted there"), and Android's half
/// is not a code change but a compliance one: `ACCESS_COARSE_LOCATION` in the
/// manifest AND the Play Data-safety section answered. Those go together,
/// because Data safety has to be accurate for any release on Play including
/// a closed test — shipping the permission ahead of the form is the risk, not
/// shipping it late.
///
/// Hiding the pill rather than letting it fail is the point: with no
/// permission declared, `requestPermission` returns denied forever, so the
/// button would be there and permanently answer "Location is off", which
/// reads as a bug rather than as a feature that has not arrived.
///
/// `docs/location-permission.md` §5 is the checklist to work through before
/// this becomes `true`.
bool get nearMeOffered => defaultTargetPlatform != TargetPlatform.android;

/// How long to wait for a fix before giving up. The handoff's figure.
const Duration kNearMeTimeout = Duration(seconds: 10);

/// Why a near-me search could not run — or [ok] if it did.
enum NearMeOutcome {
  ok,

  /// Location is switched off for the whole device, so there is no point
  /// asking for permission: the prompt would be answered by a system that
  /// cannot deliver.
  serviceOff,

  /// Refused this time. Asking again later is legitimate.
  denied,

  /// Refused permanently ("Don't allow again" / iOS Never). **The only
  /// outcome that may offer a link to Settings**, because it is the only one
  /// where the OS will never show the prompt again — offering it on a plain
  /// `denied` sends a golfer to a screen he does not need.
  deniedForever,

  /// No fix inside [kNearMeTimeout].
  timedOut,

  /// The position came back but the lookup failed — offline, or the server
  /// refused it.
  failed,
}

class NearMeResult {
  final NearMeOutcome outcome;

  /// Nearest first. Empty on [NearMeOutcome.ok] means there is genuinely
  /// nothing within the radius, which the picker says in as many words — it
  /// is NOT the same as a failure and must not be drawn as one.
  final List<CourseHit> courses;

  const NearMeResult(this.outcome, [this.courses = const []]);

  bool get ok => outcome == NearMeOutcome.ok;
}

/// Ask the OS where we are, once, and hand the position to the server.
///
/// [permission] and [requestPermission] and friends are injectable so the
/// decision tree can be tested without a device; production passes nothing.
Future<NearMeResult> coursesNearMe(
  ApiClient client, {
  int radiusMiles = 25,
  Future<bool> Function()? isServiceEnabled,
  Future<LocationPermission> Function()? checkPermission,
  Future<LocationPermission> Function()? requestPermission,
  Future<Position> Function()? getPosition,
}) async {
  final serviceCheck = isServiceEnabled ?? Geolocator.isLocationServiceEnabled;
  final check = checkPermission ?? Geolocator.checkPermission;
  final request = requestPermission ?? Geolocator.requestPermission;

  // Asked BEFORE permission: if the device's location is off, the permission
  // prompt is a question whose yes changes nothing, and "Location is off" is
  // the sentence that actually tells the golfer what to do.
  if (!await serviceCheck()) {
    return const NearMeResult(NearMeOutcome.serviceOff);
  }

  var status = await check();
  if (status == LocationPermission.denied) {
    // The first tap is what triggers the OS prompt. Only here.
    status = await request();
  }
  if (status == LocationPermission.deniedForever) {
    return const NearMeResult(NearMeOutcome.deniedForever);
  }
  if (status == LocationPermission.denied ||
      status == LocationPermission.unableToDetermine) {
    return const NearMeResult(NearMeOutcome.denied);
  }

  final Position pos;
  try {
    pos = await (getPosition ?? _singleReducedFix)();
  } on TimeoutException {
    return const NearMeResult(NearMeOutcome.timedOut);
  } on LocationServiceDisabledException {
    // Switched off between the check above and the fix.
    return const NearMeResult(NearMeOutcome.serviceOff);
  } catch (_) {
    return const NearMeResult(NearMeOutcome.timedOut);
  }

  try {
    final hits = await client.findCoursesNear(pos.latitude, pos.longitude,
        radiusMiles: radiusMiles);
    return NearMeResult(NearMeOutcome.ok, hits);
  } catch (_) {
    return const NearMeResult(NearMeOutcome.failed);
  }
}

/// One fix at reduced accuracy, with the timeout attached.
Future<Position> _singleReducedFix() => Geolocator.getCurrentPosition(
      locationSettings: AppleSettings(
        accuracy: LocationAccuracy.reduced,
        timeLimit: kNearMeTimeout,
        // **Explicitly false**: the plugin defaults it to TRUE. It only does
        // anything with `UIBackgroundModes: location` and an Always usage
        // description, neither of which this app has — but a flag that asks
        // for background updates must be off because we mean it to be off,
        // not because a plist key happens to be absent.
        allowBackgroundLocationUpdates: false,
      ),
    );

/// Open the app's own settings page, for [NearMeOutcome.deniedForever].
///
/// Here rather than in the widget so `geolocator` is imported by exactly one
/// file in the app: the plugin choice stays replaceable, and nothing else can
/// reach for a location API by accident.
Future<bool> openLocationSettings() => Geolocator.openAppSettings();
