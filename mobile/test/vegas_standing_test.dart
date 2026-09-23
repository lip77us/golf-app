/// test/vegas_standing_test.dart
/// -----------------------------
/// The standing ribbon's two strings on a Las Vegas round.
///
/// **Vegas is the only game on this row whose margin can be SIGNED**, and the
/// division that makes that safe is the subject here: the sign is always the
/// reader's and the colour is always the leader's, so neither can contradict
/// the player rows six lines below.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/vegas_standing.dart';

const _me = 11;
const _partner = 12;
const _a = 13;
const _b = 14;

VegasHole _hole(int n, {String? winner = 'team1', int points = 12}) =>
    VegasHole(
      hole: n, team1Number: 45, team2Number: 57,
      winner: winner, points: points, multiplier: 1, carry: 0,
    );

VegasTeamSummary _team(int n, List<int> ids, int points, double money) =>
    VegasTeamSummary(
      teamNumber: n,
      players: [
        for (final id in ids)
          VegasPlayer(id: id, name: 'P$id', shortName: 'P$id'),
      ],
      points: points, money: money,
    );

VegasSummary _summary({
  int t1Points = 0,
  int t2Points = 0,
  double t1Money = 0,
  double t2Money = 0,
  List<VegasHole> holes = const [],
  bool teams = true,
}) =>
    VegasSummary(
      status: 'in_progress', handicapMode: 'net', netPercent: 100,
      netMaxDoubleBogey: false, birdieMode: 'flip', carryover: false,
      teams: teams
          ? [
              _team(1, const [_me, _partner], t1Points, t1Money),
              _team(2, const [_a, _b], t2Points, t2Money),
            ]
          : const [],
      holes: holes,
      betUnit: 1,
    );

void main() {
  group('**the sign is the READER\'s**', () {
    test('his side ahead reads a plus', () {
      final s = _summary(t1Points: 96, t2Points: 84, holes: [_hole(1)]);
      expect(vegasStanding(s, _me)!.standing, '+12 pts');
    });

    test('and the SAME hole reads a minus to the other side', () {
      // The one thing a neutral margin exists to avoid, and the one thing
      // Vegas does not need to avoid: the sides are fixed at setup, so each
      // golfer's own side is unambiguous all afternoon.
      final s = _summary(t1Points: 96, t2Points: 84, holes: [_hole(1)]);
      expect(vegasStanding(s, _a)!.standing, '−12 pts');
    });

    test('the minus is U+2212, not a hyphen', () {
      final s = _summary(t1Points: 84, t2Points: 96, holes: [_hole(1)]);
      expect(vegasStanding(s, _me)!.standing.startsWith('−'), isTrue);
    });
  });

  group('**the colour is the LEADER\'s**', () {
    test('team 1 ahead names team 1, whoever is reading', () {
      // The player rows below are tinted team 1 blue and team 2 orange, FIXED.
      // A colour up here meaning "the reader" would be the Sixes defect by
      // another door.
      final s = _summary(t1Points: 96, t2Points: 84, holes: [_hole(1)]);
      expect(vegasStanding(s, _me)!.leader, 1);
      expect(vegasStanding(s, _a)!.leader, 1);
    });

    test('team 2 ahead names team 2, whoever is reading', () {
      final s = _summary(t1Points: 84, t2Points: 96, holes: [_hole(1)]);
      expect(vegasStanding(s, _me)!.leader, 2);
      expect(vegasStanding(s, _a)!.leader, 2);
    });

    test('**level takes no colour, because there is no leader**', () {
      final s = _summary(t1Points: 90, t2Points: 90, holes: [_hole(1)]);
      final st = vegasStanding(s, _me)!;
      expect(st.leader, isNull);
      // `Even`, not `All Square` — that is match play's phrase, and Vegas is a
      // points swing rather than a hole count.
      expect(st.standing, 'Even');
    });
  });

  group('the money', () {
    test('**live from the first hole, and still settled money**', () {
      // A Vegas hole pays on the hole, so the running figure is money already
      // owed rather than a projection of one.
      final s = _summary(
          t1Points: 96, t2Points: 84, t1Money: 12, t2Money: -12,
          holes: [_hole(1)]);
      expect(vegasStanding(s, _me)!.figure, '+\$12 so far');
      expect(vegasStanding(s, _a)!.figure, '−\$12 so far');
    });

    test('level is silent, not \$0', () {
      final s = _summary(t1Points: 90, t2Points: 90, holes: [_hole(1)]);
      expect(vegasStanding(s, _me)!.figure, '');
    });
  });

  group('**Vegas accumulates, so the row takes no hole**', () {
    test('more holes do not change how the standing is read', () {
      // A hole adds its swing to a total and never re-opens one, so there is
      // no leg or match to back up into.
      final s = _summary(
        t1Points: 96, t2Points: 84,
        holes: [_hole(1), _hole(2), _hole(3)]);
      expect(vegasStanding(s, _me)!.standing, '+12 pts');
    });
  });

  group('when there is nothing to say', () {
    test('**before a hole is decided the row still draws**', () {
      // The pill is the way in; losing it here gives the feature up exactly
      // when a first-time player goes looking for the leaderboard.
      final s = _summary(holes: [_hole(1, winner: null, points: 0)]);
      expect(vegasStanding(s, _me)!.standing, 'Tee off');
    });

    test('a watcher has no side, and a signed margin needs one', () {
      final s = _summary(t1Points: 96, t2Points: 84, holes: [_hole(1)]);
      expect(vegasStanding(s, 999), isNull);
    });

    test('teams not yet set, no row', () {
      expect(vegasStanding(_summary(teams: false), _me), isNull);
    });

    test('no summary, no row', () {
      expect(vegasStanding(null, _me), isNull);
    });
  });
}
