// The Sixes board's derivations — the rules the four cards all read from.
//
// `SixesMatch` exists so the live card, the holes-won row, the strokes card
// and the ledger cannot answer "is it closed out" or "how many to play" three
// different ways. These pin the answers.

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/sixes_board.dart';

/// `winners` is one entry per hole from `start`, 'T1' | 'T2' | 'Halved';
/// a short list leaves the rest of the match unplayed.
SixesMatch match({
  int start = 1,
  int end = 6,
  String status = 'in_progress',
  String winner = '—',
  List<String> winners = const [],
  List<int> a = const [1, 2],
  List<int> b = const [3, 4],
}) {
  var margin = 0;
  final holes = <Map<String, dynamic>>[];
  for (var i = 0; i < winners.length; i++) {
    if (winners[i] == 'T1') margin += 1;
    if (winners[i] == 'T2') margin -= 1;
    holes.add({
      'hole': start + i, 'winner': winners[i], 'margin': margin,
      't1_points': 0, 't2_points': 0,
    });
  }
  return SixesMatch(SixesSegment.fromJson({
    'label': 'M1', 'start_hole': start, 'end_hole': end,
    'is_extra': false, 'status': status, 'winner': winner,
    'team1': {'players': ['Paul', 'AD'], 'players_short': ['Paul', 'AD'],
              'player_ids': a, 'method': 'manual'},
    'team2': {'players': ['AP', 'AB'], 'players_short': ['AP', 'AB'],
              'player_ids': b, 'method': 'manual'},
    'holes': holes, 't1_points': 0, 't2_points': 0,
  }));
}

void main() {
  group('how far through', () {
    test('an unplayed hole is not a halved one', () {
      // The backend emits a segment's holes up front, so a null winner means
      // nobody has played it — which is the whole "not played" tile.
      final m = match(winners: const ['T1', 'Halved']);
      expect(m.thru, 2);
      expect(m.toPlay, 4);
      expect(m.sideAt(3), isNull);
      expect(m.sideAt(2), 'halved');
    });

    test('sides map to A and B, not to team numbers', () {
      final m = match(winners: const ['T1', 'T2']);
      expect(m.sideAt(1), 'A');
      expect(m.sideAt(2), 'B');
    });

    test('the next hole is the first unplayed one', () {
      expect(match(winners: const ['T1', 'T1']).nextHole, 3);
    });

    test('a finished match has no next hole', () {
      expect(match(status: 'complete', winner: 'Team 1',
              winners: const ['T1', 'T1', 'T1', 'T1']).nextHole, isNull);
    });
  });

  group('the figure', () {
    test('level reads AS while live', () {
      expect(match(winners: const ['T1', 'T2']).figure, 'AS');
    });

    test('a lead reads N UP while live', () {
      expect(match(winners: const ['T1', 'T1']).figure, '2 UP');
    });

    test('a close-out reads N&M, closed up', () {
      // 3 up with 2 to play, decided on the 4th. No spaces: the packet
      // writes it `2&1` and the V2 screenshots render both the big figure
      // and the `won 2&1` tag that way.
      final m = match(status: 'complete', winner: 'Team 1',
          winners: const ['T1', 'T1', 'Halved', 'T1']);
      expect(m.closedOut, isTrue);
      expect(m.figure, '3&2');
    });

    test('a match that goes the distance reads N UP, not N & 0', () {
      final m = match(status: 'complete', winner: 'Team 1',
          winners: const ['T1', 'T1', 'Halved', 'Halved', 'Halved', 'Halved']);
      expect(m.closedOut, isFalse);
      expect(m.figure, '2 UP');
    });

    test('a level finish is a Push, not AS', () {
      // AS is a live state; a finished level match is money that does not
      // move, and the board says so.
      final m = match(status: 'halved', winner: 'Halved',
          winners: const ['T1', 'T2', 'Halved', 'Halved', 'Halved', 'Halved']);
      expect(m.figure, 'Push');
    });

    test('an undrawn match says nothing', () {
      final m = SixesMatch(SixesSegment.fromJson({
        'label': 'M2', 'start_hole': 7, 'end_hole': 12,
        'is_extra': false, 'status': 'pending', 'winner': '—',
        'team1': {'players': [], 'players_short': [], 'player_ids': [],
                  'method': 'manual'},
        'team2': {'players': [], 'players_short': [], 'player_ids': [],
                  'method': 'manual'},
        'holes': [], 't1_points': 0, 't2_points': 0,
      }));
      expect(m.drawn, isFalse);
      expect(m.figure, '—');
      expect(m.nextHole, isNull, reason: 'nothing to play until it is drawn');
    });
  });

  group('a decided match says WHAT it was, not that it ended', () {
    // V2, 24 Oct: `Final` was a word that said only that the match had
    // stopped. The status under the label is the result now, in the winning
    // side's colour, and the winning side carries a `won 2&1` tag.

    test('a push is still a push', () {
      final m = match(status: 'halved', winner: 'Halved',
          winners: const ['T1', 'T2', 'Halved', 'Halved', 'Halved', 'Halved']);
      expect(m.figure, 'Push');
      expect(m.leaderColour, isNull,
          reason: 'nobody won, so nothing takes a side colour');
    });

    test('the result carries the winner colour', () {
      final a = match(status: 'complete', winner: 'Team 1',
          winners: const ['T1', 'T1', 'Halved', 'T1']);
      final b = match(status: 'complete', winner: 'Team 2',
          winners: const ['T2', 'T2', 'Halved', 'T2']);
      expect(a.figure, '3&2');
      expect(b.figure, '3&2');
      expect(a.leaderColour, isNot(b.leaderColour),
          reason: 'the same figure, opposite sides');
    });

    test('a live match has no result to show yet', () {
      final m = match(winners: const ['T1', 'T1']);
      expect(m.isDone, isFalse);
      expect(m.figure, '2 UP');
    });
  });

  group('who is leading', () {
    test('level has no colour — nobody is ahead', () {
      expect(match(winners: const ['T1', 'T2']).leaderColour, isNull);
    });

    test('the colours belong to the SIDE, not the golfer', () {
      // Side A is pine in every match; the men on it change.
      final one = match(winners: const ['T1']);
      final two = match(start: 7, end: 12, a: const [1, 3], b: const [2, 4],
          winners: const ['T1']);
      expect(one.leaderColour, two.leaderColour);
    });
  });
}
