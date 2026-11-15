/// test/wizard_flights_test.dart
/// ----------------------------
/// Flights are asked for in the WIZARD and cut on create.
///
/// They used to be set only from the hub, after setup had been completed —
/// reported 25 Sep 2026: *"I can see a TD not remember to do that, or not
/// understanding why they need to complete the configuration and then go back
/// in to edit it."* Setup should be finished when setup finishes.
///
/// Source-level for the placement claims, because what went wrong is WHERE a
/// question is asked, and no widget test fails on a question being in the
/// wrong place.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/flight_share.dart';

void main() {
  final wizard =
      File('lib/screens/new_round_wizard.dart').readAsStringSync();

  group('**asked in the wizard, not after it**', () {
    test('the payouts step carries a flights card', () {
      expect(wizard, contains('Widget _flightsCard('));
      expect(wizard, contains('_flightsCard(context)'));
    });

    test('the deferred placeholder is gone', () {
      // It said `LATER`, then `AFTER PAIRINGS`, and both pointed somewhere
      // else. There is nowhere else to point now.
      expect(wizard.contains('_flightsDeferred'), isFalse);
    });

    test('the cut happens on create', () {
      expect(wizard, contains('setFlights(tournamentId'));
      // AFTER the round and its foursomes are written — the cut reads every
      // golfer's index off the memberships that call creates.
      expect(wizard.indexOf('setFlights(tournamentId'),
          greaterThan(wizard.indexOf('3. Create Round 1 with foursomes')));
    });

    test('a one-board event posts no cut', () {
      // Guarded on the count rather than posting `1`, which the server
      // refuses as "not a cut".
      expect(wizard, contains('_flightCount > 1'));
    });
  });

  group('**the split it shows is exact**', () {
    test('the sizes come from the count, which the wizard already has', () {
      // The field is chosen two steps before payouts, so this is not an
      // estimate: an equal cut's sizes depend on the golfer count alone.
      expect(flightSizes(13, 2), [7, 6]);
      expect(flightShareLabel(const [39, 16, 10], 1, flightSizes(13, 2)),
          'Flights pay \$7–\$9');
    });

    test('one board says nothing about flights', () {
      expect(flightSizes(13, 1), isEmpty);
      expect(flightShareLabel(const [39, 16, 10], 1, flightSizes(13, 1)),
          isEmpty);
    });
  });
}
