/// test/road_trip_board_test.dart
/// -----------------------------
/// The trip board: the four cell states, the three sections, and the switch.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/road_trip_board.dart';

Map<String, dynamic> _cell(int r, String state, {int? toPar, int holes = 0}) =>
    {'round': r, 'state': state, 'to_par': toPar, 'holes': holes};

Map<String, dynamic> _row(
  String name, {
  int? rank,
  int? total,
  int played = 3,
  int needs = 0,
  bool tied = false,
  String? tieNote,
  int id = 1,
  List<Map<String, dynamic>>? cells,
}) =>
    {
      'player_id': id, 'name': name, 'rank': rank, 'tied': tied,
      'tie_note': tieNote, 'total': total, 'played': played, 'needs': needs,
      'cells': cells ??
          [
            _cell(1, 'counted', toPar: -2),
            _cell(2, 'dropped', toPar: 5),
            _cell(3, 'counted', toPar: 0),
          ],
    };

Map<String, dynamic> _data({
  List<String> titles = const ['net', 'gross'],
  bool provisional = false,
  List<Map<String, dynamic>>? ranked,
  List<Map<String, dynamic>>? qualifying,
  List<Map<String, dynamic>>? ineligible,
  int counts = 2,
  int nRounds = 3,
  int complete = 3,
}) {
  final board = {
    'provisional': provisional,
    'ranked': ranked ?? [_row('Ann', rank: 1, total: -2)],
    'qualifying': qualifying ?? const <Map<String, dynamic>>[],
    'ineligible': ineligible ?? const <Map<String, dynamic>>[],
  };
  return {
    'titles': titles,
    'counts': counts,
    'n_rounds': nRounds,
    'rounds': [
      for (var i = 1; i <= nRounds; i++)
        {'round_number': i, 'label': 'R$i', 'course': 'Links $i',
         'is_complete': i <= complete},
    ],
    for (final t in titles) t: board,
  };
}

Future<void> _pump(WidgetTester t, Map<String, dynamic> data,
    {int? readerId}) async {
  t.view.physicalSize = const Size(1200, 2200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(body: RoadTripBoard(data: data, readerId: readerId)),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the board', () {
    testWidgets('it states the counting rule and where the trip is',
        (t) async {
      await _pump(t, _data());
      expect(find.text('Best 2 of 3 · to par'), findsOneWidget);
      expect(find.text('Final'), findsOneWidget);
    });

    testWidgets('mid-trip it says which round it is after', (t) async {
      await _pump(t, _data(complete: 1));
      expect(find.text('After round 1'), findsOneWidget);
    });

    testWidgets('provisional is SAID, not implied', (t) async {
      await _pump(t, _data(provisional: true));
      expect(find.textContaining('Rounds start dropping'), findsOneWidget);
    });

    testWidgets('one title draws no switch', (t) async {
      // A single-segment control is a control with nothing to do.
      await _pump(t, _data(titles: const ['net']));
      expect(find.text('Net Championship'), findsNothing);
      await _pump(t, _data());
      expect(find.text('Net Championship'), findsOneWidget);
      expect(find.text('Gross Championship'), findsOneWidget);
    });
  });

  group('the round strip', () {
    testWidgets('a dropped round is shown, struck through, never hidden',
        (t) async {
      await _pump(t, _data());
      await t.tap(find.text('Ann'));
      await t.pumpAndSettle();
      // Counted, dropped and their labels are all on screen.
      expect(find.text('R1'), findsOneWidget);
      expect(find.text('R2'), findsOneWidget);
      expect(find.text('−2'), findsWidgets);   // the counted −2
      expect(find.text('+5'), findsOneWidget);      // the dropped round
    });

    testWidgets('a missed round is a dash and a pending one is not a score',
        (t) async {
      await _pump(t, _data(ranked: [
        _row('Ann', rank: 1, total: 0, cells: [
          _cell(1, 'counted', toPar: 0),
          _cell(2, 'missed'),
          _cell(3, 'pending', holes: 4),
        ]),
      ]));
      await t.tap(find.text('Ann'));
      await t.pumpAndSettle();
      expect(find.text('–'), findsWidgets);
      // Four holes at level par must not read as E on a row of finished
      // rounds — the cell says how far, not how well.
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('one row opens at a time', (t) async {
      await _pump(t, _data(ranked: [
        _row('Ann', rank: 1, total: -2, id: 1),
        _row('Bea', rank: 2, total: 3, id: 2),
      ]));
      await t.tap(find.text('Ann'));
      await t.pumpAndSettle();
      expect(find.text('R1'), findsOneWidget);
      await t.tap(find.text('Bea'));
      await t.pumpAndSettle();
      // Still one strip, not two.
      expect(find.text('R1'), findsOneWidget);
    });

    testWidgets('a cut index is badged and explained', (t) async {
      await _pump(t, _data(ranked: [
        {..._row('Niamh', rank: 1, total: -4),
         'adjusted': {'from_round': 6, 'index': 16.0,
                      'reason': 'Net under par in four of the first five'}},
      ]));
      expect(find.text('HCP CUT'), findsOneWidget);
      await t.tap(find.text('Niamh'));
      await t.pumpAndSettle();
      expect(find.textContaining('from R6'), findsOneWidget);
      expect(find.textContaining('four of the first five'), findsOneWidget);
    });

    testWidgets('a tie says which round settled it', (t) async {
      await _pump(t, _data(ranked: [
        _row('Ann', rank: 1, total: 0, tieNote: 'Lahinch'),
      ]));
      await t.tap(find.text('Ann'));
      await t.pumpAndSettle();
      expect(find.text('Tie decided on Lahinch'), findsOneWidget);
    });
  });

  group('the three sections', () {
    testWidgets('qualifying and ineligible are named and explained',
        (t) async {
      await _pump(t, _data(
        qualifying: [_row('Mark', played: 1, needs: 1, id: 3)],
        ineligible: [_row('Paul', played: 0, needs: 2, id: 4)],
      ));
      expect(find.text('Still qualifying'), findsOneWidget);
      expect(find.textContaining('enough left to get there'), findsOneWidget);
      expect(find.text('Not eligible'), findsOneWidget);
      // His rounds were real and his side games still count — the section
      // says so rather than just dimming him.
      expect(find.textContaining('Side games still count'), findsOneWidget);
    });

    testWidgets('an empty section draws nothing at all', (t) async {
      await _pump(t, _data());
      expect(find.text('Still qualifying'), findsNothing);
      expect(find.text('Not eligible'), findsNothing);
    });

    testWidgets('a golfer without his rounds claims no total', (t) async {
      await _pump(t, _data(
        qualifying: [_row('Mark', played: 1, needs: 1, id: 3, total: null)],
      ));
      expect(find.textContaining('needs 1 more'), findsOneWidget);
    });
  });

  group('the reader', () {
    testWidgets('his own row is marked', (t) async {
      await _pump(t, _data(ranked: [_row('Ann', rank: 1, total: -2, id: 7)]),
          readerId: 7);
      expect(find.text('YOU'), findsOneWidget);
    });
  });

  group('it is reachable', () {
    final src = File('lib/screens/tournament_leaderboard_screen.dart')
        .readAsStringSync();

    test('the tournament board dispatches the tab', () {
      expect(src.contains("case 'road_trip':"), isTrue);
      expect(src.contains('RoadTripBoard'), isTrue);
    });

    test('the trip leads the tabs, because it IS the championship', () {
      expect(src.contains("if (tabs.remove('road_trip')) tabs.insert(0,"),
          isTrue);
    });

    test('the server sends the block', () {
      final views = File('../api/views.py').readAsStringSync();
      expect(views.contains("games['road_trip'] = {'label': 'Road Trip'"),
          isTrue);
    });
  });
}
