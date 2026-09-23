/// test/points_race_standing_test.dart
/// -----------------------------------
/// The shared points-race row — Wolf and Points 5-3-1.
///
/// Two games, one shape: every golfer is on his own, a hole hands out points,
/// and the points settle into money. What is pinned here is the SHAPE; each
/// game's own test file pins that it feeds this the right numbers.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/points_race_standing.dart';
import 'package:golf_mobile/utils/standing_money.dart';

const _me = 11;

List<RaceEntry> _field(Map<int, double> points,
        {Map<int, double> money = const {}}) =>
    [
      for (final e in points.entries)
        (id: e.key, points: e.value, money: money[e.key] ?? 0),
    ];

void main() {
  group('where you are, and what put you there', () {
    test('the place leads and the points follow', () {
      final st = pointsRaceStanding(
          _field({_me: 12, 12: 15, 13: 8, 14: 4}), _me, anyScored: true)!;
      expect(st.standing, '2nd of 4 · 12 pts');
    });

    test('a three-handed game says of 3', () {
      final st = pointsRaceStanding(
          _field({_me: 27, 12: 20, 13: 7}), _me, anyScored: true)!;
      expect(st.standing, '1st of 3 · 27 pts');
    });

    test('**a tie shows the T, and both games tie constantly**', () {
      // Wolf halves a tied hole's points and Points averages 5 and 3 into 4
      // and 4, so two golfers level is ordinary rather than an edge case.
      final st = pointsRaceStanding(
          _field({_me: 12, 12: 15, 13: 12}), _me, anyScored: true)!;
      expect(st.standing, 'T-2 of 3 · 12 pts');
    });
  });

  group('**half points are real, and whole ones are not decimals**', () {
    test('the half survives and the .0 does not', () {
      // The Points 5-3-1 lock card shipped `41.0 PTS` on every row by
      // forgetting that the decimal is load-bearing only when it is a half.
      expect(racePoints(12), '12');
      expect(racePoints(12.5), '12.5');
      expect(racePoints(0), '0');
    });

    test('and a half ranks properly', () {
      final st = pointsRaceStanding(
          _field({_me: 12.5, 12: 12, 13: 13}), _me, anyScored: true)!;
      expect(st.standing, '2nd of 3 · 12.5 pts');
    });
  });

  group('the money', () {
    test('it rides in the quiet slot', () {
      final st = pointsRaceStanding(
          _field({_me: 12}, money: {_me: 6}), _me, anyScored: true)!;
      expect(st.figure, '+\$6 so far');
    });

    test('**empty, never \$0**', () {
      // A round that has settled nothing has nothing to say about money, and
      // a zero reads as a settled result.
      expect(standingMoney(0), '');
      expect(standingMoney(0.004), '');
    });

    test('whole dollars lose the decimal, anything else keeps the cents', () {
      // A pot split three ways must not silently round away a third.
      expect(standingMoney(10), '+\$10 so far');
      expect(standingMoney(-4.5), '−\$4.50 so far');
    });

    test('the minus is U+2212, not a hyphen', () {
      expect(standingMoney(-10).startsWith('−'), isTrue);
    });
  });

  group('**before a hole is scored the row still draws**', () {
    test('it reads Tee off, whatever the totals say', () {
      // The pill is the way in; losing it here gives the feature up exactly
      // when a first-time player goes looking for the leaderboard.
      final st = pointsRaceStanding(
          _field({_me: 0, 12: 0}), _me, anyScored: false)!;
      expect(st.standing, 'Tee off');
    });

    test('**anyScored is asked, not inferred from a zero total**', () {
      // A golfer can legitimately have nothing after a hole he lost outright,
      // and inferring from the total would silence his row.
      final st = pointsRaceStanding(
          _field({_me: 0, 12: 9}), _me, anyScored: true)!;
      expect(st.standing, '2nd of 2 · 0 pts');
    });
  });

  group('when there is nothing to say', () {
    test('a watcher is not in the race', () {
      expect(pointsRaceStanding(_field({_me: 12}), 999, anyScored: true),
             isNull);
    });

    test('no reader, no row', () {
      expect(pointsRaceStanding(_field({_me: 12}), null, anyScored: true),
             isNull);
    });
  });
}
