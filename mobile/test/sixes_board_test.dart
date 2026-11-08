// The Sixes board's derivations — the rules the four cards all read from.
//
// `SixesMatch` exists so the live card, the holes-won row, the strokes card
// and the ledger cannot answer "is it closed out" or "how many to play" three
// different ways. These pin the answers.

import 'dart:io';

import 'package:flutter/material.dart';
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
  int number = 1,
  bool extra = false,
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
    // **The engine's real label**, not `M1`. The fixture used to say `M1`,
    // which is a shape `sixes_summary` has never produced — and a board that
    // mangled the real one (`Holes 11–16 (Match atch 3)`, via
    // `replaceFirst('M', 'Match ')` hitting the M in "Match") passed every
    // test here because the fixture agreed with the bug.
    'label': 'Holes $start–$end (Match $number'
             '${extra ? ', extra' : ''})',
    'start_hole': start, 'end_hole': end,
    'is_extra': extra, 'status': status, 'winner': winner,
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

  group('the strokes card', () {
    test('every stroke is a filled dot', () {
      // A spent stroke used to be hollow. Nobody could read it — the question
      // that retired it was "what are the closed circles vs the open circles"
      // — and it inverted this app's vocabulary, where filled means settled.
      // The ledger on the same screen says exactly that.
      final src = File('lib/widgets/sixes_board.dart').readAsStringSync();
      final at = src.indexOf('static Widget _dot(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('\n  }', at));
      expect(body.contains('Border.all'), isFalse,
          reason: 'a stroke dot is filled, never outlined');
      expect(body.contains('Colors.transparent'), isFalse);
      expect(body, contains('Halved.brightMint'));
    });
  });

  group('the board draws every bet', () {
    Map<String, dynamic> seg(int n, int a, int b, String status,
        String winner, {bool extra = false}) => {
          'label': 'Holes $a–$b (Match $n${extra ? ', extra' : ''})',
          'start_hole': a, 'end_hole': b, 'num_holes': b - a + 1,
          'is_extra': extra, 'is_void': false,
          'status': status, 'winner': winner,
          't1_points': 0, 't2_points': 0,
          'team1': {'players': ['Paul', 'Larry'],
                    'players_short': ['Paul', 'Larry'],
                    'player_ids': [1, 2], 'method': 'manual'},
          'team2': {'players': ['Jim', 'RyanL'],
                    'players_short': ['Jim', 'RyanL'],
                    'player_ids': [3, 4], 'method': 'manual'},
          'holes': [
            for (var h = a; h <= b; h++)
              {'hole': h, 'winner': 'Halved', 'margin': 0,
               't1_points': 0, 't2_points': 0},
          ],
        };

    // Tilden, 7 Nov 2026: three matches and a spawned extra on 17–18.
    final group = <String, dynamic>{
      '_single_group': true,
      'summary': {
        'segments': [
          seg(1, 1, 4, 'complete', 'Team 1'),
          seg(2, 5, 10, 'halved', 'Halved'),
          seg(3, 11, 16, 'complete', 'Team 2'),
          seg(4, 17, 18, 'halved', 'Halved', extra: true),
        ],
        'holes': const [],
        'players': const [],
        'money': {'bet_unit': 10.0, 'by_player': const []},
      },
    };

    Future<void> pump(WidgetTester t) async {
      await t.binding.setSurfaceSize(const Size(430, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(
            child: SixesBoard(group: group))),
      ));
    }

    testWidgets('an extra match gets a row', (t) async {
      // It has teams, holes, a result and a stake, and the ledger already
      // pays it — so a board that hid it left a golfer asking what happened
      // to the fourth match on his receipt.
      await pump(t);
      expect(find.textContaining('Match 4, extra'), findsWidgets);
    });

    testWidgets('the header counts it', (t) async {
      await pump(t);
      expect(find.text('4 matches'), findsOneWidget);
      expect(find.text('3 matches'), findsNothing);
    });

    testWidgets('the label is the engine\'s, verbatim', (t) async {
      // `replaceFirst('M', 'Match ')` hit the M in "Match" and drew
      // `Holes 11–16 (Match atch 3)`.
      await pump(t);
      // `atch 3)` alone would match the CORRECT label too — "Match 3)"
      // contains it — so the assertion has to name the doubling.
      expect(find.textContaining('Match atch'), findsNothing);
      expect(find.textContaining('Holes 17–18 (Match 4, extra)'),
          findsWidgets);
    });
  });
}
