/// test/road_trip_wizard_test.dart
/// -------------------------------
/// Road Trip in the create flow.
///
/// Source-level, like the other wizard guards: booting the whole wizard needs
/// a provider apiece and what is at risk here is the WIRING, not the
/// rendering — a format that reaches the picker but no step, or a step that
/// collects settings nothing posts.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';

void main() {
  final wizard =
      File('lib/screens/new_round_wizard.dart').readAsStringSync();

  group('the format is reachable', () {
    test('it is offered as an individual FORMAT, not a fourth event type', () {
      // Every golfer against the field over several rounds — the same
      // scoring unit as stroke play, a different shape of championship.
      expect(wizard.contains("('road_trip', 'Road Trip',"), isTrue);
    });

    test('it has a step, and that step is in the flow', () {
      expect(wizard.contains('_StepKind.roadTrip'), isTrue);
      expect(wizard.contains('class _StepRoadTrip'), isTrue);
      expect(wizard.contains('if (_isRoadTrip) {'), isTrue);
    });

    test('the settings it collects are POSTED', () {
      // A step that gathers settings nothing sends is the shape that has bitten
      // this app before: configured by not being configured.
      expect(wizard.contains('client.postRoadTripSetup('), isTrue);
      for (final f in ['netOn', 'grossOn', 'handicapMode',
                       'netMaxDoubleBogey', 'grossMaxDoubleBogey']) {
        expect(wizard.contains('$f'), isTrue, reason: '\$f must be sent');
      }
    });

    test('there is no money gate on the post', () {
      // The two championships only post when a fee was set, because their
      // config IS the stake. A trip's config is what the board is scored on.
      final i = wizard.indexOf('client.postRoadTripSetup(');
      final before = wizard.substring(i - 600, i);
      expect(before.contains('_lowNetEntryFee > 0'), isFalse);
    });
  });

  group('the trip replaces the championship it sits where', () {
    test('picking it removes the stroke-play board', () {
      // Two boards ranking the same golfers by different rules is the thing
      // the marker swap exists to prevent.
      expect(wizard.contains('GameIds.roadTrip,'), isTrue);
      final i = wizard.indexOf('_tournamentActiveGames.removeAll({');
      expect(wizard.substring(i, i + 260).contains('GameIds.roadTrip'), isTrue,
          reason: 'leaving the format must take the marker with it');
    });

    test('the catalog gives it a NAME, not a slug', () {
      // Set on the tournament, so it never reaches the casual picker's
      // catalog — exactly the gap that made a board read `eclectic`.
      expect(gameDisplayName(GameIds.roadTrip), 'Road Trip');
    });
  });

  group('the review states the rules it just set', () {
    test('six lines, including the ones a group argues about', () {
      expect(wizard.contains('_RoadTripReview'), isTrue);
      expect(wizard.contains('can be '), isTrue);
      expect(wizard.contains("'Eligible with'"), isTrue);
      expect(wizard.contains("'Final round, then back one at a time'"), isTrue);
      expect(wizard.contains('manual adjust from any unplayed round'), isTrue);
    });
  });

  group('the step list is honest', () {
    test('a trip has no payouts step', () {
      // Trip money is not in this packet's scope, and a step collecting a fee
      // nothing settles would be worse than no step.
      final i = wizard.indexOf('if (_isRoadTrip) {');
      final flow = wizard.substring(i, wizard.indexOf('];', i));
      expect(flow.contains('_StepKind.payouts'), isFalse);
      expect(flow.contains('_StepKind.review'), isTrue);
      expect(flow.contains('_StepKind.games'), isTrue);
    });

    test('the header count reads the derived list', () {
      // The plan row has to name the new step or the count is a lie.
      expect(wizard.contains("(label: 'The trip'"), isTrue);
    });
  });
}
