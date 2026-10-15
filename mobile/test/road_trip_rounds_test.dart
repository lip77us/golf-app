/// test/road_trip_rounds_test.dart
/// ------------------------------
/// Rounds & Side Games: the list, the edit sheet, and the rule that a
/// complete round's games are final.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/screens/road_trip_rounds_screen.dart';

void main() {
  final screen =
      File('lib/screens/road_trip_rounds_screen.dart').readAsStringSync();
  final list =
      File('lib/screens/tournament_list_screen.dart').readAsStringSync();
  final views = File('../api/views.py').readAsStringSync();

  group('the screen is reachable', () {
    test('a trip gets a named button on its tournament card', () {
      // The rounds ARE the trip, so this is not a gear item two screens down.
      expect(list.contains("'Rounds & Side Games'"), isTrue);
      expect(list.contains('RoadTripRoundsScreen'), isTrue);
      expect(list.contains('GameIds.roadTrip'), isTrue);
    });

    test('and only a trip gets it', () {
      expect(
          list.contains(
              "tournament.activeGames.contains(GameIds.roadTrip))"),
          isTrue);
    });
  });

  group('the chips are FIELD games', () {
    test('it offers the five, Hot Seat among them', () {
      // Low net and Low gross are ONE game here — Stroke Play, whose own
      // setup carries the net/gross switch. Two chips writing the same slug
      // would let a TD pick both and get one.
      for (final id in <String>[
        GameIds.strokePlay,
        GameIds.betterBall,
        GameIds.irishRumble,
        GameIds.hotSpot,
        GameIds.fortyBalls,
      ]) {
        expect(kRoadTripFieldGames, contains(id));
      }
      expect(screen.contains("'Low gross'"), isFalse);
    });

    test('Hot Seat is offered here AND accepted by the endpoint', () {
      // The gap: it was on the per-round side-games picker and not on this
      // sheet, and FIELD_GAMES agreed with the sheet — so the one game was
      // reachable from one screen and not the other. Both halves or neither,
      // because a chip the server refuses is worse than no chip.
      expect(kRoadTripFieldGames, contains(GameIds.hotSpot));
      expect(views.contains("'hot_spot', 'forty_balls')"), isTrue);
    });

    test('the chips are named by the CATALOG, not by this file', () {
      // This list used to carry its own labels, which made the screen a
      // second place every game is named. Hot Spot becoming Hot Seat is what
      // a second place costs: the copy here would have gone on saying the old
      // name with nothing to catch it.
      expect(kFieldGameLabel(GameIds.hotSpot), 'Hot Seat');
      expect(kFieldGameLabel(GameIds.hotSpot), gameDisplayName(GameIds.hotSpot));
      expect(kFieldGameLabel(GameIds.strokePlay), 'Stroke Play');
      // An unknown id degrades to itself, as the old `orElse` did.
      expect(kFieldGameLabel('nonsense'), 'nonsense');
    });

    test('one of the one-pool family at a time, via the shared toggle', () {
      // Four of the five rank the same groups into the same pool. Turning one
      // on turns an incompatible one OFF rather than greying it out — the
      // call the new-round wizard makes, through the same shared function so
      // the two cannot drift.
      expect(screen.contains('applyGameToggle(_picked, id, v)'), isTrue);

      var picked = <String>{GameIds.irishRumble};
      picked = applyGameToggle(picked, GameIds.hotSpot, true);
      expect(picked, contains(GameIds.hotSpot));
      expect(picked, isNot(contains(GameIds.irishRumble)));

      // ...and back the other way, which is the direction that was broken.
      picked = applyGameToggle(picked, GameIds.irishRumble, true);
      expect(picked, contains(GameIds.irishRumble));
      expect(picked, isNot(contains(GameIds.hotSpot)));

      // Stroke Play is an overlay and survives either.
      picked = applyGameToggle({GameIds.strokePlay}, GameIds.hotSpot, true);
      expect(picked, containsAll(<String>[GameIds.strokePlay, GameIds.hotSpot]));
    });

    test('the sheet SAYS so, and names the family from the catalog', () {
      // A chip that silently deselects another is visible but unexplained,
      // and the TD needs to know which games trade off. The list is derived
      // from the catalog's `excludes`, so the sentence cannot name three
      // games on a screen that offers four.
      expect(kOnePoolFieldGames, <String>[
        GameIds.betterBall,
        GameIds.irishRumble,
        GameIds.hotSpot,
        GameIds.fortyBalls,
      ]);
      // Stroke Play excludes none of them, so it falls out on its own rather
      // than being special-cased.
      expect(kOnePoolFieldGames, isNot(contains(GameIds.strokePlay)));
      expect(screen.contains('all rank the same groups, so '), isTrue);
      expect(screen.contains('picking one clears the others'), isTrue);
    });

    test('and the server refuses the pair regardless of the sheet', () {
      expect(views.contains('ONE_OF_THESE'), isTrue);
      expect(views.contains('rank the same groups into the same pool'), isTrue);
    });

    test("a group's own games are never touched", () {
      // Skins, Nassau and Wolf belong to the group. The endpoint keeps them.
      expect(views.contains('keep = [g for g in before '
          'if g not in self.FIELD_GAMES]'), isTrue);
    });
  });

  group('the rule the packet is firm about', () {
    test('a complete round SAYS its games are final', () {
      // Said, not just greyed: a button that has quietly gone dead reads as a
      // fault rather than as a rule.
      expect(screen.contains('Round complete. Side games are final.'), isTrue);
      expect(screen.contains('before or during the round'), isTrue);
    });

    test('the server refuses it too, with 409', () {
      expect(views.contains('its side games are final.'), isTrue);
      expect(views.contains('HTTP_409_CONFLICT'), isTrue);
    });

    test('the group is told what changed', () {
      expect(views.contains('def _notify_field_games'), isTrue);
      expect(views.contains("parts.append('added '"), isTrue);
    });
  });

  group('the sheet', () {
    test('Save is dead until something changes', () {
      // A live Save on an untouched sheet invites a write that says nothing
      // and a chat message about it.
      expect(screen.contains('bool get _changed'), isTrue);
      expect(screen.contains('onPressed: _changed'), isTrue);
    });

    test('it states what adding a game mid-round means', () {
      expect(screen.contains('scores it from hole 1'), isTrue);
      expect(screen.contains("trip championship isn't"), isTrue);
    });
  });
}
