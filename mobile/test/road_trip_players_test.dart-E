/// test/road_trip_players_test.dart
/// -------------------------------
/// Players & Handicaps: the adjust sheet's two gates, and the promise it
/// makes about rounds already played.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final screen =
      File('lib/screens/road_trip_players_screen.dart').readAsStringSync();
  final list =
      File('lib/screens/tournament_list_screen.dart').readAsStringSync();
  final views  = File('../api/views.py').readAsStringSync();
  final engine = File('../services/road_trip.py').readAsStringSync();

  group('it is reachable', () {
    test('a trip gets a named button, and only an organiser', () {
      expect(list.contains("'Players & Handicaps'"), isTrue);
      expect(list.contains('RoadTripPlayersScreen'), isTrue);
      // An index cut is the organiser's ruling, not a thing the field does.
      final i = list.indexOf("'Players & Handicaps'");
      expect(list.substring(i - 200, i).contains('isStaff'), isTrue);
    });
  });

  group('the adjust sheet', () {
    test('Save needs BOTH a moved index and a reason', () {
      // An adjustment that changes nothing is noise on the group's board, and
      // one with no reason is what the reason field exists to prevent.
      expect(
          screen.contains(
              "_index != _start && _why.text.trim().isNotEmpty"),
          isTrue);
      expect(screen.contains('onPressed: _ready'), isTrue);
    });

    test('the reason says it is shown to the group', () {
      expect(screen.contains("helperText: 'Shown to the group'"), isTrue);
    });

    test('it names the round it applies from, and the promise', () {
      expect(screen.contains("'Applies from'"), isTrue);
      expect(
          screen.contains(
              'Rounds already played keep the handicap they were scored with.'),
          isTrue);
    });

    test('the index moves in tenths', () {
      expect(screen.contains('_step(-0.1)'), isTrue);
      expect(screen.contains('_step(0.1)'), isTrue);
    });
  });

  group('the server owns the rules', () {
    test('a reason is required there too', () {
      expect(views.contains('A reason is required'), isTrue);
    });

    test('the round it applies from is the server\'s answer', () {
      // A client that drew its screen a hole ago would name the wrong one.
      expect(views.contains('def _next_unplayed'), isTrue);
      expect(views.contains('from_round_number=nxt.round_number'), isTrue);
    });

    test('an adjustment REACHES the rounds it governs', () {
      // The engine reads the membership, so a note in a log would score
      // nothing.
      expect(views.contains('apply_indexes(tournament)'), isTrue);
      expect(engine.contains('def apply_indexes'), isTrue);
      expect(engine.contains('if r.id in scored:'), isTrue);
    });

    test('locked mode has a number to lock TO', () {
      // Without the recorded start it would fall through to the golfer's
      // current index — the very number locking is meant to hold still.
      expect(engine.contains('def capture_starting_indexes'), isTrue);
      expect(engine.contains("config.handicap_mode == 'locked'"), isTrue);
      expect(engine.contains('current.setdefault('), isTrue);
    });
  });
}
