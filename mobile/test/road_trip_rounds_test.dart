/// test/road_trip_rounds_test.dart
/// ------------------------------
/// Rounds & Side Games: the list, the edit sheet, and the rule that a
/// complete round's games are final.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    test('four, not the five the packet drew', () {
      // Low net and Low gross are ONE game here — Stroke Play, whose own
      // setup carries the net/gross switch. Two chips writing the same slug
      // would let a TD pick both and get one.
      expect(screen.contains("('low_net_round', 'Stroke Play')"), isTrue);
      expect(screen.contains("('better_ball',   'Better Ball')"), isTrue);
      expect(screen.contains("('irish_rumble',  'Irish Rumble')"), isTrue);
      expect(screen.contains("('forty_balls',   '40 Balls')"), isTrue);
      expect(screen.contains("'Low gross'"), isFalse);
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
