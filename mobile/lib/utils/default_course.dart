/// Which course a new round should start on.
///
/// Paul, 13 Nov 2026: start on the HOME course; and if the phone says you are
/// standing at one of your courses, start on that instead — but **never make
/// the form wait for the phone**: *"if there is a delay getting the phone's
/// position, then don't worry, just put the home course there or leave it
/// blank if there is no home course."*
///
/// So this is two answers, in two steps, and the second is a bonus:
///
///  1. [homeCourse] — immediate. The golfer's home course, or null.
///  2. [courseHere] — the course within [kHereMiles] of the phone, found by a
///     quick quiet fix with a short [kHereTimeout]. Null for every way it can
///     fail, because every way it can fail has the same answer: carry on with
///     step 1.
///
/// ## What "quiet" means
///
/// Everything else about location in this app is "only when you tap Courses
/// near me" (`utils/near_me.dart`). This is the one exception and it is
/// narrow on purpose:
///
///  * **It never prompts.** It runs only if permission was ALREADY granted —
///    which, since the picker's pill is the only place that asks, means the
///    golfer has used the pill before.
///  * **The position never leaves the phone.** The match is against the
///    coordinates of the golfer's OWN courses, which the app already holds.
///    Nothing is sent, nothing is stored.
///  * **One fix, short, then stop** — no stream, no background update.
///
/// ## Why the radius is not 0.1 mile
///
/// A course is ONE stored point (a clubhouse or a centroid) and a golfer on
/// the first tee can be a third of a mile from it. And while the app asks iOS
/// for REDUCED accuracy (`NSLocationDefaultAccuracyReduced`, an invariant
/// `build-ipa.sh` enforces) the fix itself can be kilometres out. So this
/// only ever fires when the golfer is at the course and the OS gave a good
/// fix; the radius is wide enough to survive the first tee and narrow enough
/// that two courses on one road are not confused.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../api/models.dart';
import 'near_me.dart' show nearMeOffered;

/// How close, in miles, the phone has to be to a course to start on it.
const double kHereMiles = 0.5;

/// How long to wait for the quiet fix before giving up and staying on home.
const Duration kHereTimeout = Duration(seconds: 2);

/// The golfer's home course out of [courses], or null.
CourseInfo? homeCourse(List<CourseInfo> courses, int? homeCourseId) {
  if (homeCourseId == null) return null;
  for (final c in courses) {
    if (c.id == homeCourseId) return c;
  }
  return null;
}

/// Great-circle distance in miles.
double milesBetween(double lat1, double lon1, double lat2, double lon2) {
  const r = 3958.8; // earth radius, miles
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a.toDouble())));
}

/// The nearest of [courses] to ([lat], [lon]) within [withinMiles], or null.
/// A course with no coordinates is never a match.
CourseInfo? nearestWithin(
  List<CourseInfo> courses,
  double lat,
  double lon, {
  double withinMiles = kHereMiles,
}) {
  CourseInfo? best;
  var bestMiles = double.infinity;
  for (final c in courses) {
    final cLat = c.latitude, cLon = c.longitude;
    if (cLat == null || cLon == null) continue;
    final d = milesBetween(lat, lon, cLat, cLon);
    if (d <= withinMiles && d < bestMiles) {
      best = c;
      bestMiles = d;
    }
  }
  return best;
}

/// One quiet fix, or null — never a prompt, never an error.
///
/// Every injectable so the decision tree is testable without a device.
Future<({double lat, double lon})?> quietPosition({
  Future<bool> Function()? isServiceEnabled,
  Future<LocationPermission> Function()? checkPermission,
  Future<Position> Function()? getPosition,
  Duration timeout = kHereTimeout,
}) async {
  try {
    if (!await (isServiceEnabled ?? Geolocator.isLocationServiceEnabled)()) {
      return null;
    }
    final status = await (checkPermission ?? Geolocator.checkPermission)();
    // **Only a permission already granted.** `denied` here means "not asked
    // yet" and asking is the picker pill's job, on a tap — not this.
    if (status != LocationPermission.whileInUse &&
        status != LocationPermission.always) {
      return null;
    }
    final pos = await (getPosition ??
            () => Geolocator.getCurrentPosition(
                locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.high)))()
        .timeout(timeout);
    return (lat: pos.latitude, lon: pos.longitude);
  } catch (_) {
    return null; // timed out, switched off, refused: all the same answer
  }
}

/// The course the phone says you are at, among [courses], or null.
///
/// Offered on iOS only, like the rest of location here (`nearMeOffered`).
Future<CourseInfo?> courseHere(
  List<CourseInfo> courses, {
  Future<({double lat, double lon})?> Function()? position,
  bool? offered,
}) async {
  if (!(offered ?? nearMeOffered)) return null;
  final withCoords =
      courses.where((c) => c.latitude != null && c.longitude != null);
  if (withCoords.isEmpty) return null; // nothing to compare — skip the fix
  final p = await (position ?? quietPosition)();
  if (p == null) return null;
  return nearestWithin(courses, p.lat, p.lon);
}
