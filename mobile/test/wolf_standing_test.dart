/// test/wolf_standing_test.dart
/// ----------------------------
/// The standing ribbon's two strings on a Wolf round.
///
/// Two things make Wolf different from every game already on this row, and
/// both are the subject here: it ACCUMULATES rather than resetting, so the row
/// takes no hole; and a halved hole SPLITS its points, so ties are the common
/// case and half-points are real.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/wolf_standing.dart';

const _me = 11;
const _b = 12;
const _c = 13;
const _d = 14;

WolfHole _hole(int n, {bool scored = true}) => WolfHole(
      hole: n, par: 4, strokeIndex: n,
      wolfId: _me, wolfShort: 'P11', decision: 'partner',
      partnerId: _b, partnerShort: 'P12', partnerLocked: false,
      winningSide: scored ? 'wolf' : null, pot: 4,
      teeOrder: const [],
      entries: scored
          ? [
              for (final id in const [_me, _b, _c, _d])
                WolfHoleEntry(
                  playerId: id, shortName: 'P$id', name: 'P$id',
                  role: id == _me ? 'wolf' : 'opponent',
                  netScore: 4, gross: 4, points: 1,
                ),
            ]
          : const [],
    );

WolfSummary _summary({
  Map<int, double> points = const {},
  Map<int, double> money = const {},
  List<WolfHole> holes = const [],
  List<int> field = const [_me, _b, _c, _d],
}) =>
    WolfSummary(
      status: 'in_progress', handicapMode: 'net', netPercent: 100,
      loneWolfPoints: 4, blindWolfPoints: 6, teamWinPoints: 2,
      wolfLosesTies: false, nonWolfBonus: false,
      lastPlaceWolf1718: false, requireLoneOrBlind: false,
      wolfOrder: field, lockedPositions: const [],
      players: [
        for (final id in field)
          WolfPlayerTotal(playerId: id, name: 'P$id', shortName: 'P$id',
              points: points[id] ?? 0, holesPlayed: holes.length,
              money: money[id] ?? 0, phcpInPlay: 0),
      ],
      holes: holes,
      betUnit: 1, lossCap: null,
    );

void main() {
  group('where you are, and what put you there', () {
    test('the place leads and the points follow', () {
      final s = _summary(
        points: {_me: 12, _b: 15, _c: 8, _d: 4}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.standing, '2nd of 4 · 12 pts');
    });

    test('the leader reads 1st', () {
      final s = _summary(
        points: {_me: 15, _b: 12, _c: 8, _d: 4}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.standing, '1st of 4 · 15 pts');
    });

    test('**a tie shows the T, and Wolf ties constantly**', () {
      // A halved hole SPLITS its points, so two golfers level is the common
      // case rather than the edge one. `placeLabel` is shared with Stroke Play
      // so `T-2` is written the same way on both.
      final s = _summary(
        points: {_me: 12, _b: 15, _c: 12, _d: 4}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.standing, 'T-2 of 4 · 12 pts');
    });

    test('a three-handed game says of 3', () {
      final s = _summary(
        points: {_me: 5, _b: 3, _c: 1}, holes: [_hole(1)],
        field: const [_me, _b, _c]);
      expect(wolfStanding(s, _me)!.standing, '1st of 3 · 5 pts');
    });
  });

  group('**half points are real, and whole ones are not decimals**', () {
    test('a split hole shows the half', () {
      final s = _summary(points: {_me: 12.5}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.standing, '1st of 4 · 12.5 pts');
    });

    test('a whole number never reads 12.0', () {
      // The Points 5-3-1 lock card shipped `41.0 PTS` on every row by
      // forgetting this.
      expect(wolfPoints(12), '12');
      expect(wolfPoints(12.5), '12.5');
      expect(wolfPoints(0), '0');
    });

    test('and half points rank properly', () {
      final s = _summary(
        points: {_me: 12.5, _b: 12, _c: 13, _d: 0}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.standing, '2nd of 4 · 12.5 pts');
    });
  });

  group('the money', () {
    test('**live from the first hole, and still settled money**', () {
      // Wolf points net to zero on every hole, so a hole IS its own
      // settlement — the running figure is money already owed, not a forecast
      // of one. That is what lets this row say `so far` where Sixes and Rabbit
      // had to wait for a leg to close.
      final s = _summary(
        points: {_me: 2}, money: {_me: 6, _b: -2}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.figure, '+\$6 so far');
      expect(wolfStanding(s, _b)!.figure, '−\$2 so far');
    });

    test('level is silent, not \$0', () {
      final s = _summary(points: {_me: 4, _b: 4}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.figure, '');
    });

    test('the minus is U+2212, not a hyphen', () {
      final s = _summary(money: {_me: -3}, holes: [_hole(1)]);
      expect(wolfStanding(s, _me)!.figure.startsWith('−'), isTrue);
    });
  });

  group('**Wolf accumulates, so the row takes no hole**', () {
    test('the standing is the same whichever hole is on screen', () {
      // Every other game on this row takes a hole because a match, a leg or a
      // Survivor RESETS and the row has to report the one being shown. Wolf
      // has nothing to reset — a hole adds points and never re-opens one — so
      // there is no argument to get wrong.
      final s = _summary(
        points: {_me: 12, _b: 15}, holes: [_hole(1), _hole(2), _hole(3)]);
      expect(wolfStanding(s, _me)!.standing, '2nd of 4 · 12 pts');
    });
  });

  group('when there is nothing to say', () {
    test('**before the first score the row still draws**', () {
      // The pill is the way in; losing it here gives the feature up exactly
      // when a first-time player goes looking for the leaderboard.
      final s = _summary(holes: [_hole(1, scored: false)]);
      expect(wolfStanding(s, _me)!.standing, 'Tee off');
    });

    test('a watcher is not in the game', () {
      expect(wolfStanding(_summary(holes: [_hole(1)]), 999), isNull);
    });

    test('no summary, no row', () {
      expect(wolfStanding(null, _me), isNull);
    });
  });
}
