/// test/fourball_standing_test.dart
/// --------------------------------
/// The standing ribbon's two strings on a Fourball round.
///
/// **A neutral margin wearing the leader's colour, and no names.** The status
/// card this replaced led every line with the leading pair; the row sits above
/// four player rows already tinted with the two sides' fixed colours, so the
/// names are the colours again in words. That is Nassau's ruling, and Fourball
/// can take it for the reason Vegas can — the sides are set at setup and never
/// change.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/fourball_standing.dart';

const _me = 11;
const _mate = 12;
const _a = 13;

FourballTeamInfo _team(List<int> ids, List<String> names) => FourballTeamInfo(
      players: names, shortNames: names, playerIds: ids, isWinner: false,
    );

FourballSummary _summary({
  String status = 'in_progress',
  int holesUp = 0,
  String? leader,
  int holesPlayed = 5,
  int? holesToPlay,
  Map<String, double> money = const {},
}) =>
    FourballSummary(
      status: status, result: null, resultLabel: '—',
      finishedOnHole: null, holesToPlay: holesToPlay,
      handicapMode: 'net', netPercent: 100,
      holesUp: holesUp, leader: leader,
      holesPlayed: holesPlayed, currentHole: holesPlayed + 1,
      team1: _team(const [_me, _mate], const ['Paul', 'Mike']),
      team2: _team(const [_a, 14], const ['Jim', 'Dave']),
      holes: const [],
      betAmount: 20,
      money: [
        for (final e in money.entries)
          FourballMoneyEntry(name: e.key, amount: e.value),
      ],
    );

void main() {
  group('the match, without names', () {
    test('a lead reads the margin and the thru', () {
      final st = fourballStanding(
          _summary(holesUp: 2, leader: 'team1'), _me)!;
      expect(st.standing, '2 UP thru 5');
      expect(st.leader, 'team1');
    });

    test('**the margin is neutral, and the colour names the side**', () {
      // The same string reaches all four phones; only the tint differs, and it
      // agrees with the player rows below rather than with the reader.
      final s = _summary(holesUp: -2, leader: 'team2');
      expect(fourballStanding(s, _me)!.standing, '2 UP thru 5');
      expect(fourballStanding(s, _a)!.standing, '2 UP thru 5');
      expect(fourballStanding(s, _me)!.leader, 'team2');
    });

    test('and it never carries a name', () {
      final st = fourballStanding(
          _summary(holesUp: 2, leader: 'team1'), _me)!;
      expect(st.standing.contains('Paul'), isFalse);
      expect(st.standing.contains('&'), isFalse);
    });

    test('level reads All Square, and takes no colour', () {
      final st = fourballStanding(_summary(holesUp: 0), _me)!;
      expect(st.standing, 'All Square thru 5');
      expect(st.leader, isNull);
    });
  });

  group('**the close-out comes from the server**', () {
    test('a decided match reads win N&M', () {
      // `holes_to_play` walks the group's own play order. `18 −
      // finishedOnHole` read right off the 1st tee and wrong off every
      // shotgun: a match closing on the 7th played from a shotgun on 13, with
      // five left, printed `3&11`.
      final st = fourballStanding(
          _summary(status: 'complete', holesUp: 3, leader: 'team1',
                   holesToPlay: 2),
          _me)!;
      expect(st.standing, 'win 3&2');
    });

    test('one that ran to the last hole reads win N UP', () {
      final st = fourballStanding(
          _summary(status: 'complete', holesUp: 1, leader: 'team1',
                   holesToPlay: 0),
          _me)!;
      expect(st.standing, 'win 1 UP');
    });

    test('a halved match is All Square with no thru', () {
      final st = fourballStanding(_summary(status: 'halved'), _me)!;
      expect(st.standing, 'All Square');
    });
  });

  group('**thru is a COUNT, not a hole number**', () {
    test('a shotgun group that played 7 to 12 is thru 6', () {
      final st = fourballStanding(
          _summary(holesUp: 1, leader: 'team1', holesPlayed: 6), _me)!;
      expect(st.standing, '1 UP thru 6');
    });
  });

  group('the money waits for the match', () {
    test('**nothing until it settles**', () {
      // A single match settles exactly once. `$0` on the 9th would read as a
      // match played for nothing.
      expect(fourballStanding(_summary(holesUp: 2, leader: 'team1'), _me)!
          .figure, '');
    });

    test('and then it is the reader\'s own side of it', () {
      final s = _summary(
          status: 'complete', holesUp: 3, leader: 'team1', holesToPlay: 2,
          money: {'Paul': 20, 'Jim': -20});
      expect(fourballStanding(s, _me)!.figure, '+\$20');
      expect(fourballStanding(s, _a)!.figure, '−\$20');
    });

    test('a watcher gets the match and no money', () {
      final s = _summary(
          status: 'complete', holesUp: 3, leader: 'team1', holesToPlay: 2,
          money: {'Paul': 20});
      final st = fourballStanding(s, 999)!;
      expect(st.standing, 'win 3&2');
      expect(st.figure, '');
    });
  });

  group('when there is nothing to say', () {
    test('before a hole is played it reads Tee off', () {
      expect(fourballStanding(_summary(holesPlayed: 0), _me)!.standing,
             'Tee off');
    });

    test('teams not set, no row', () {
      final s = FourballSummary(
        status: 'pending', result: null, resultLabel: '—',
        finishedOnHole: null, holesToPlay: null,
        handicapMode: 'net', netPercent: 100,
        holesUp: 0, leader: null, holesPlayed: 0, currentHole: 1,
        team1: _team(const [], const []), team2: _team(const [], const []),
        holes: const [], betAmount: 20, money: const [],
      );
      expect(fourballStanding(s, _me), isNull);
    });

    test('no summary, no row', () {
      expect(fourballStanding(null, _me), isNull);
    });
  });
}
