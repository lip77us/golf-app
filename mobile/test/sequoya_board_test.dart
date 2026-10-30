/// test/sequoya_board_test.dart
/// ----------------------------
/// The Sequoya 3s board, against REAL engine output: the two fixtures are the
/// packet's worked example played through `services/sequoya_threes.py`
/// (`ThePacketsWorkedExampleTests`, REGEN_SEQUOYA_FIXTURES=1).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/sequoya_board_model.dart';
import 'package:golf_mobile/widgets/sequoya_board.dart';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

SequoyaBoardData _data(String name) =>
    SequoyaBoardData.fromSummary(_json(name));

Future<void> _pump(WidgetTester t, SequoyaBoardData d) async {
  await t.binding.setSurfaceSize(const Size(390, 2200));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: SequoyaBoard(data: d))),
  ));
  await t.pump();
}

void main() {
  group('the model reads the engine', () {
    final mid = _data('sequoya_thru_13');
    final end = _data('sequoya_final');

    test('thru 13 is live in match 5, next hole 14', () {
      expect(mid.roundOver, isFalse);
      expect(mid.nextHole, 14);
      expect(mid.liveMatch!.index, 5);
      expect(mid.holesLeft, 5);
      expect(mid.settled, 4);
      expect(mid.betCount, 10);
    });

    test('the money is the live figure, ranked and zero-sum', () {
      expect([for (final g in mid.golfers) g.money], [5, 5, -5, -5]);
      expect(mid.golfers.fold<double>(0, (n, g) => n + g.money), 0);
    });

    test('the finish is the packet\'s figures', () {
      expect(end.roundOver, isTrue);
      expect(end.liveMatch, isNull);
      expect(end.betCount, 13);
      expect({for (final g in end.golfers) g.firstName: g.money},
          {'Paul': 15, 'Sam': 5, 'Lee': -5, 'Dave': -15});
    });

    test('a close-out reads off the hole it closed on', () {
      expect(mid.matches[0].head.value, '2&1');
      expect(mid.matches[2].head.lead, isNull);
    });

    test('a match won with its press lost is level on the ledger', () {
      // M2: Dave & Lee won the match, Paul & Sam won Paul's press, the auto
      // press halved — so Paul's M2 mark nets one bet each way.
      final paul = mid.golfers.firstWhere((g) => g.firstName == 'Paul');
      expect(paul.marks[1].glyph, '=');
      expect(paul.marks[1].settled, isTrue);
    });

    test('a live match is outlined and an unstarted one is a dot', () {
      final paul = mid.golfers.firstWhere((g) => g.firstName == 'Paul');
      expect(paul.marks[4].settled, isFalse);
      expect(paul.marks[4].glyph, '+');
      expect(paul.marks[5].glyph, '·');
    });

    test('halved and unplayed are different tiles', () {
      expect(mid.hole(7)!.played, isTrue);
      expect(mid.hole(7)!.winnerSide, isNull);
      expect(mid.hole(14)!.played, isFalse);
    });

    test('next follows PLAY order, not hole number', () {
      final raw = _json('sequoya_thru_13');
      final holes = (raw['scorecard']['holes'] as List);
      // Off a shotgun the 14th might be played first; the next hole is
      // whichever comes first unplayed in the order the server lists.
      final moved = holes.removeAt(15);          // hole 16 to the front
      holes.insert(0, moved);
      expect(SequoyaBoardData.fromSummary(raw).nextHole, 16);
    });
  });

  group('the board draws', () {
    testWidgets('the live match, its bets and the strokes card', (t) async {
      await _pump(t, _data('sequoya_thru_13'));
      expect(find.textContaining('MATCH 5 OF 6'), findsOneWidget);
      expect(find.text('Auto press'), findsOneWidget);
      expect(find.text('starts 14'), findsOneWidget);
      expect(find.textContaining('STROKES · MATCH 5'), findsNothing,
          reason: 'gross fixture has no strokes to lay out');
      expect(find.text('Each · now'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('the finish', (t) async {
      await _pump(t, _data('sequoya_final'));
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('6 matches · 13 bets'), findsOneWidget);
      expect(find.text('Final, each'), findsOneWidget);
      expect(find.text('+\$15'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a strokes round shows the strokes card', (t) async {
      final raw = _json('sequoya_thru_13');
      raw['handicap'] = {'mode': 'strokes_off', 'net_percent': 100};
      await _pump(t, SequoyaBoardData.fromSummary(raw));
      expect(find.textContaining('STROKES · MATCH 5'), findsOneWidget);
      expect(find.text('OFF THE LOW'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('the leaderboard keeps the way to the receipts', () {
      final src = File('lib/screens/leaderboard_screen.dart')
          .readAsStringSync();
      expect(src, contains('SequoyaBoard(data:'));
      expect(src, contains("'/sequoya-threes-settlement'"));
      expect(src, isNot(contains('_SeqPane')),
          reason: 'one board, not a second drawing beside it');
    });
  });
}
