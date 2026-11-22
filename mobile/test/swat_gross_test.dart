import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/swat_gross_board.dart';

Map<String, dynamic> _data({bool donors = false}) {
  final par = {for (var h = 1; h <= 18; h++) '$h': 4};
  final si = {for (var h = 1; h <= 18; h++) '$h': h};
  return {
    'par': par, 'si': si,
    'teams': [
      {
        'id': 1, 'name': 'Team Brandt', 'three': true, 'thru': 2,
        'finished': false, 'best_to_par': -1, 'gross_place': 1,
        'gross_tied': false,
        'players': [
          {'id': 10, 'name': 'Kelly Brandt', 'short': 'KB', 'index': 4.8},
        ],
        'best': {'1': 3, '2': 4},
        'phantom': {'1': 5, '2': 4},
        if (donors) 'phantom_donors': {'1': 'WU', '2': 'PRI'},
      },
      {
        'id': 2, 'name': 'Team Moran', 'three': false, 'thru': 0,
        'finished': false, 'best_to_par': 0, 'gross_place': null,
        'gross_tied': false, 'players': [], 'best': {}, 'phantom': null,
      },
    ],
    'players': [
      {'id': 10, 'name': 'Kelly Brandt', 'short': 'KB', 'team': 'Team Brandt',
       'team_id': 1, 'band': 'A', 'index': 4.8, 'thru': 2, 'gross': 7, 'par': 8,
       'holes': {'1': 3, '2': 4}},
    ],
  };
}

Widget _wrap(Map<String, dynamic> d) => MaterialApp(
    home: Scaffold(body: SwatGrossBoard(data: d)));

void main() {
  testWidgets('teams are ranked and an unstarted team has no place', (t) async {
    await t.pumpWidget(_wrap(_data()));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Team Moran'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
  });

  testWidgets('tapping a team opens golfers, phantom and best ball', (t) async {
    await t.pumpWidget(_wrap(_data()));
    await t.tap(find.text('Team Brandt'));
    await t.pumpAndSettle();
    expect(find.text('Kelly Brandt'), findsOneWidget);
    expect(find.text('Phantom'), findsOneWidget);
    expect(find.text('Best ball'), findsOneWidget);
    expect(find.text('Hole by hole ›'), findsOneWidget);
  });

  testWidgets('the scorecard names no donor until the server sends them', (t) async {
    await t.pumpWidget(_wrap(_data()));
    await t.tap(find.text('Team Brandt'));
    await t.pumpAndSettle();
    await t.tap(find.text('Hole by hole ›'));
    await t.pumpAndSettle();
    expect(find.text('OUT'), findsOneWidget);
    expect(find.text('IN'), findsOneWidget);
    expect(find.text('Index'), findsNWidgets(2));
    expect(find.text('WU'), findsNothing);
    expect(find.text('◂ Back to the totals'), findsOneWidget);
  });

  testWidgets('once final, the donor initials sit under the phantom', (t) async {
    await t.pumpWidget(_wrap(_data(donors: true)));
    await t.tap(find.text('Team Brandt'));
    await t.pumpAndSettle();
    await t.tap(find.text('Hole by hole ›'));
    await t.pumpAndSettle();
    expect(find.text('WU'), findsOneWidget);
    expect(find.text('PRI'), findsOneWidget);
  });

  testWidgets('by player lists the band and sorts by score or name', (t) async {
    await t.pumpWidget(_wrap(_data()));
    await t.tap(find.text('By player'));
    await t.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
    expect(find.text('Team Brandt'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
  });

  testWidgets('the stacked scorecard fits a 390pt phone without overflow', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_wrap(_data(donors: true)));
    await t.tap(find.text('Team Brandt'));
    await t.pumpAndSettle();
    await t.tap(find.text('Hole by hole ›'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
