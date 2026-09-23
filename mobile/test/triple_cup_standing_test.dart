/// test/triple_cup_standing_test.dart
/// ----------------------------------
/// The standing ribbon's two strings on a Triple Cup round.
///
/// **The cup is the headline, including `0–0`.** Triple Cup exists to produce
/// a cup score; the match in front of you is a way of earning a point in it.
/// That split is the subject here, along with which of four simultaneous
/// matches the figure reports.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/triple_cup_standing.dart';

const _me = 11;
const _b = 12;

TripleCupHole _hole(int n, {String? winner}) => TripleCupHole(
      hole: n, par: 4, strokeIndex: n, t1Net: null, t2Net: null,
      t1TeamGross: null, t2TeamGross: null,
      t1TeamStrokes: null, t2TeamStrokes: null,
      winner: winner, margin: 0, scores: const [],
    );

TripleCupMatch _match({
  int number = 1,
  String segment = 'fourball',
  String? label,
  int start = 1,
  int end = 6,
  String status = 'in_progress',
  int holesUp = 0,
  int? holesToPlay,
  List<int> playerIds = const [_me, _b],
  List<TripleCupHole> holes = const [],
}) =>
    TripleCupMatch(
      matchNumber: number, segment: segment, label: label ?? 'M$number',
      startHole: start, endHole: end, displayEndHole: end,
      status: status, result: null, finishedOnHole: null,
      holesToPlay: holesToPlay, holesUpFinal: holesUp, winnerLabel: '—',
      team1: const TripleCupTeamInfo(players: ['Paul'], shorts: ['Paul']),
      team2: const TripleCupTeamInfo(players: ['Jim'], shorts: ['Jim']),
      team1FirstTeeId: null, team2FirstTeeId: null,
      players: [
        for (final id in playerIds)
          TripleCupMatchPlayer(
            playerId: id, name: 'P$id', shortName: 'P$id',
            teamNumber: id == _me ? 1 : 2),
      ],
      holes: holes,
    );

TripleCupSummary _summary({
  double t1 = 0,
  double t2 = 0,
  int available = 4,
  List<TripleCupMatch> matches = const [],
  double? cupT1,
  double? cupT2,
  double? toWin,
}) =>
    TripleCupSummary(
      status: 'in_progress', groupSize: 4,
      handicapMode: 'net', netPercent: 100,
      altShotLowPct: 50, altShotHighPct: 50,
      matches: matches,
      team1Wins: 0, team2Wins: 0, halves: 0,
      team1Points: t1, team2Points: t2, pointsAvailable: available,
      betUnit: 0, money: const [],
      cupTeam1Points: cupT1, cupTeam2Points: cupT2, cupToWin: toWin,
    );

void main() {
  group('**one definition of where a match stands**', () {
    test('the strip and the row cannot write it differently', () {
      // Both call `tripleCupMatchState`; the row used to compute its own.
      final m = _match(holesUp: 2, holes: [_hole(1, winner: 'T1')]);
      final st = tripleCupMatchState(m);
      final s = _summary(matches: [m]);
      expect(st.value, tripleCupStanding(s, _me, hole: 1)!.figure);
      expect(st.leader, tripleCupStanding(s, _me, hole: 1)!.matchLeader);
    });

    test('a close-out reads win N&M, from the server\'s holes left', () {
      final st = tripleCupMatchState(
          _match(status: 'complete', holesUp: 3, holesToPlay: 2));
      expect(st.value, 'win 3&2');
    });

    test('level and halved both take no colour', () {
      expect(tripleCupMatchState(_match(holes: [_hole(1, winner: 'Halved')]))
          .leader, isNull);
      expect(tripleCupMatchState(_match(status: 'halved')).value, 'All Square');
    });
  });

  group('**the cup is the headline**', () {
    test('including 0–0 before a point is won, and WITHOUT `of 4`', () {
      // How many points are available never changes all afternoon; the format
      // changes twice and changes what the group is about to do.
      // A headline that means one thing before the first point and another
      // after is a slot nobody can learn.
      final s = _summary(matches: [_match()]);
      expect(tripleCupStanding(s, _me, hole: 1)!.standing, '0–0');
    });

    test('halves are real, and whole points are not decimals', () {
      final s = _summary(t1: 2.5, t2: 1.5, matches: [_match()]);
      expect(tripleCupStanding(s, _me, hole: 1)!.standing, '2½–1½');
      expect(cupPoints(3), '3');
      expect(cupPoints(0.5), '½');
      expect(cupPoints(0), '0');
    });
  });

  group('**the format is named in front of the margin**', () {
    test('a fourball says so', () {
      final s = _summary(matches: [
        _match(holesUp: 1, holes: [_hole(1, winner: 'T1')]),
      ]);
      final st = tripleCupStanding(s, _me, hole: 1)!;
      expect(st.figureLabel, 'M1');
      expect(st.figure, '1 UP thru 1');
    });

    test('**the label distinguishes Singles 1 from Singles 2**', () {
      // Two singles run at once; the segment alone would name them the same.
      final s = _summary(matches: [
        _match(number: 2, segment: 'singles', start: 13, end: 18),
      ]);
      expect(tripleCupStanding(s, _me, hole: 13)!.figureLabel, 'M2');
    });

    test('and the segment is the fallback when a match has no label', () {
      expect(segmentLabel(_match(segment: 'foursomes', label: '')),
             'Foursomes');
    });
  });

  group('**on a CUP round the headline is the tournament\'s cup**', () {
    test('the tournament total replaces the foursome\'s four points', () {
      // A casual Triple Cup is a cup of its own; on a Ryder-Cup round the
      // foursome is one of several and the golfer is playing for the
      // twenty-four.
      final s = _summary(
        t1: 2, t2: 1,               // this foursome
        cupT1: 6.5, cupT2: 4.5,     // the tournament
        toWin: 12.5,
        matches: [_match()]);
      expect(tripleCupStanding(s, _me, hole: 1)!.standing,
             '6½–4½ · 12½ to win');
    });

    test('**`to win` comes AFTER the score it counts from**', () {
      // It reads backwards in front of one, which is why it is not in the
      // row's quiet slot — that slot sits ahead of the standing.
      final s = _summary(cupT1: 6.5, cupT2: 4.5, toWin: 12.5,
                         matches: [_match()]);
      final st = tripleCupStanding(s, _me, hole: 1)!;
      expect(st.standing.indexOf('6½–4½'),
             lessThan(st.standing.indexOf('12½ to win')));
    });

    test('a casual Triple Cup has no cup above it, and says nothing', () {
      final s = _summary(t1: 2, t2: 1, matches: [_match()]);
      final st = tripleCupStanding(s, _me, hole: 1)!;
      expect(st.standing, '2–1');
      expect(st.toWin, '');
    });

    test('and the match still rides in the figure', () {
      final s = _summary(
        cupT1: 6.5, cupT2: 4.5, toWin: 12.5,
        matches: [_match(holesUp: 1, holes: [_hole(1, winner: 'T1')])]);
      final st = tripleCupStanding(s, _me, hole: 1)!;
      expect(st.figure, '1 UP thru 1');
      expect(st.figureLabel, 'M1');
    });
  });

  group('**the figure is the reader\'s own match**', () {
    test('four run at once, and the hole on screen picks one', () {
      final s = _summary(matches: [
        _match(number: 1, start: 1, end: 6, holesUp: 2,
               holes: [_hole(1, winner: 'T1'), _hole(2, winner: 'T1')]),
        _match(number: 2, start: 7, end: 12, playerIds: const [13, 14]),
      ]);
      expect(tripleCupStanding(s, _me, hole: 2)!.figure, '2 UP thru 2');
    });

    test('the colour names the match LEADER, whoever is reading', () {
      final s = _summary(matches: [
        _match(holesUp: -2, holes: [_hole(1, winner: 'T2')]),
      ]);
      expect(tripleCupStanding(s, _me, hole: 1)!.matchLeader, 2);
      expect(tripleCupStanding(s, _b, hole: 1)!.matchLeader, 2);
      // Neutral, so the same string reaches both sides.
      expect(tripleCupStanding(s, _me, hole: 1)!.figure,
             tripleCupStanding(s, _b, hole: 1)!.figure);
    });

    test('**a closed-out match keeps reporting its result**', () {
      // The group is still playing golf in the other three, and `win 3&2` is
      // what he tells them on the next tee.
      final s = _summary(matches: [
        _match(status: 'complete', holesUp: 3, holesToPlay: 2),
      ]);
      expect(tripleCupStanding(s, _me, hole: 5)!.figure, 'win 3&2');
    });

    test('thru counts THIS match, not the course', () {
      // A segment is six holes of its own, so the header's hole number does
      // not say how far into the match the group is.
      final s = _summary(matches: [
        _match(start: 7, end: 12, holesUp: 1,
               holes: [_hole(7, winner: 'T1'), _hole(8, winner: 'Halved')]),
      ]);
      expect(tripleCupStanding(s, _me, hole: 8)!.figure, '1 UP thru 2');
    });
  });

  group('**when the reader is not in the match on screen**', () {
    test('**a TD gets the GROUP\'s match, not a blank**', () {
      // He opened a foursome he is not playing in, and the screen he got is
      // entirely about that group: its hole, its four rows, its card. A row
      // that went blank there reported nothing about the thing on screen.
      final s = _summary(t1: 1, matches: [
        _match(holesUp: 1, playerIds: const [21, 22],
               holes: [_hole(1, winner: 'T1')]),
      ]);
      final st = tripleCupStanding(s, 999, hole: 1)!;
      expect(st.standing, '1–0');
      expect(st.figure, '1 UP thru 1');
      expect(st.figureLabel, 'M1');
    });

    test('**his own match still wins when he is in one**', () {
      final s = _summary(matches: [
        _match(number: 1, holesUp: 2, playerIds: const [21, 22],
               holes: [_hole(1, winner: 'T1')]),
        _match(number: 2, label: 'M2', holesUp: 1,
               playerIds: const [_me, 23], holes: [_hole(1, winner: 'T1')]),
      ]);
      expect(tripleCupStanding(s, _me, hole: 1)!.figureLabel, 'M2');
    });

    test('a hole no match covers gives the cup alone', () {
      final s = _summary(t1: 1, matches: [
        _match(start: 7, end: 12, playerIds: const [13, 14]),
      ]);
      final st = tripleCupStanding(s, _me, hole: 2)!;
      expect(st.standing, '1–0');
      expect(st.figure, '');
    });

    test('no matches drawn yet, no row', () {
      expect(tripleCupStanding(_summary(), _me, hole: 1), isNull);
    });

    test('no summary, no row', () {
      expect(tripleCupStanding(null, _me, hole: 1), isNull);
    });
  });
}
