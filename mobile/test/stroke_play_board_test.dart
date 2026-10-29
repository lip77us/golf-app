import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/stroke_play_board_model.dart';
import 'package:golf_mobile/widgets/stroke_play_board.dart';

/// `~/Downloads/handoff-stroke-play-leaderboard` — one widget for every
/// stroke play leaderboard, casual and tournament.

StrokePlayRow _row({
  required int rank,
  required String name,
  int? toPar,
  int? gross,
  int thru = 18,
  double? payout,
  String hcap = '8.2',
  List<Map<String, dynamic>> holes = const [],
}) =>
    StrokePlayRow(
      playerId: rank * 10,
      rank: rank,
      name: name,
      handicapLabel: hcap,
      toPar: toPar,
      grossTotal: gross,
      thru: thru,
      holes: holes,
      payout: payout,
    );

StrokePlayBoardData _board({
  required List<StrokePlayRow> rows,
  double entryFee = 0,
  bool hasPot = false,
  String basis = 'Net',
  String counting = 'single round',
}) =>
    StrokePlayBoardData(
      rows: rows,
      basisLabel: basis,
      countingLabel: counting,
      entryFee: entryFee,
      hasPot: hasPot,
      holePars: {for (var h = 1; h <= 18; h++) h: 4},
      holesInPlay: [for (var h = 1; h <= 18; h++) h],
    );

Future<void> _pump(WidgetTester t, StrokePlayBoardData d,
        {Widget? selector}) =>
    t.pumpWidget(MaterialApp(
      home: Scaffold(body: StrokePlayBoard(data: d, selector: selector)),
    ));

void main() {
  group('the meta line', () {
    testWidgets('states the basis and the counting rule', (t) async {
      await _pump(t, _board(rows: [_row(rank: 1, name: 'Paul', toPar: -2)]));
      expect(find.text('Net · single round'), findsOneWidget);
    });

    testWidgets('names the entry, or says there is no pot', (t) async {
      await _pump(t, _board(
          rows: [_row(rank: 1, name: 'Paul', toPar: -2)], entryFee: 40));
      expect(find.text('Entry \$40'), findsOneWidget);

      await _pump(t, _board(rows: [_row(rank: 1, name: 'Paul', toPar: -2)]));
      expect(find.text('No pot'), findsOneWidget);
    });
  });

  group('the columns', () {
    testWidgets('one round: # · Player · Thru · Gross · Tot', (t) async {
      await _pump(t, _board(rows: [_row(rank: 1, name: 'Paul', toPar: -2)]));
      for (final c in ['#', 'PLAYER', 'THRU', 'GROSS', 'TOT']) {
        expect(find.text(c), findsOneWidget, reason: c);
      }
    });

    testWidgets('PRIZE only when there is a pot', (t) async {
      await _pump(t, _board(rows: [_row(rank: 1, name: 'Paul', toPar: -2)]));
      expect(find.text('PRIZE'), findsNothing);

      await _pump(t, _board(
          rows: [_row(rank: 1, name: 'Paul', toPar: -2, payout: 300)],
          hasPot: true));
      expect(find.text('PRIZE'), findsOneWidget);
      expect(find.text('\$300'), findsOneWidget);
    });

    testWidgets('no S-Off column — in that mode the value IS Tot', (t) async {
      await _pump(t, _board(rows: [_row(rank: 1, name: 'Paul', toPar: -2)]));
      expect(find.text('S-Off'), findsNothing);
      expect(find.text('S-OFF'), findsNothing);
    });

    testWidgets('Gross is the raw total, read against Thru', (t) async {
      // 48 thru 9 says as much as +3 does, and says a different thing.
      await _pump(t, _board(rows: [
        _row(rank: 1, name: 'Kev', toPar: 3, gross: 48, thru: 9),
      ]));
      expect(find.text('48'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
    });
  });

  group('Tot', () {
    test('E for level, a sign otherwise, an em dash for nothing', () {
      expect(strokeToPar(0), 'E');
      expect(strokeToPar(-2), '−2'.replaceAll('−', '-'));
      expect(strokeToPar(3), '+3');
      expect(strokeToPar(null), '—');
    });
  });

  group('thru', () {
    test('F when finished, an em dash before teeing off', () {
      expect(_row(rank: 1, name: 'A', thru: 18).thruLabel, 'F');
      expect(_row(rank: 1, name: 'A', thru: 9).thruLabel, '9');
      expect(_row(rank: 1, name: 'A', thru: 0).thruLabel, '—');
    });
  });

  group('ranks and ties', () {
    test('a shared rank reads T2', () {
      final rows = [
        _row(rank: 1, name: 'A'),
        _row(rank: 2, name: 'B'),
        _row(rank: 2, name: 'C'),
        _row(rank: 4, name: 'D'),
      ];
      expect(rows[0].rankLabel(rows), '1');
      expect(rows[1].rankLabel(rows), 'T2');
      expect(rows[2].rankLabel(rows), 'T2');
      expect(rows[3].rankLabel(rows), '4');
    });

    test('paid places are read off the ROWS, not the payout table', () {
      // A tie splits the places it occupies, so the number of paid rows is
      // not the number of paid places — and the server has already resolved
      // that. Two golfers sharing 2nd and 3rd are both paid.
      final d = _board(hasPot: true, rows: [
        _row(rank: 1, name: 'A', payout: 300),
        _row(rank: 2, name: 'B', payout: 140),
        _row(rank: 2, name: 'C', payout: 140),
        _row(rank: 4, name: 'D'),
      ]);
      expect(d.paidRanks, {1, 2});
    });

    test('with a pot the PAID rows are tinted; with none, the leader', () {
      final withPot = _board(hasPot: true, rows: [
        _row(rank: 1, name: 'A', payout: 300),
        _row(rank: 2, name: 'B', payout: 140),
        _row(rank: 3, name: 'C'),
      ]);
      expect(withPot.tintedRanks, {1, 2});

      final casual = _board(rows: [
        _row(rank: 1, name: 'A'),
        _row(rank: 2, name: 'B'),
      ]);
      expect(casual.tintedRanks, {1});
    });
  });

  group('the open card', () {
    final holes = [
      for (var h = 1; h <= 9; h++)
        {'hole': h, 'gross': h == 5 ? 3 : 4, 'par': 4,
         'net_adj': h == 5 ? 3 : 4, 'handicap_strokes': h == 1 ? 1 : 0},
    ];

    testWidgets('a row opens in place, and only one at a time', (t) async {
      await _pump(t, _board(rows: [
        _row(rank: 1, name: 'Paul', toPar: -1, gross: 35, thru: 9,
            holes: holes),
        _row(rank: 2, name: 'Sam', toPar: 1, gross: 37, thru: 9,
            holes: holes),
      ]));
      expect(find.textContaining('To par'), findsNothing);

      await t.tap(find.text('Paul'));
      await t.pumpAndSettle();
      expect(find.textContaining('To par'), findsOneWidget);

      await t.tap(find.text('Sam'));
      await t.pumpAndSettle();
      expect(find.textContaining('To par'), findsOneWidget,
          reason: 'opening one must close the other');
    });

    testWidgets('no chevrons — the row is the control', (t) async {
      await _pump(t, _board(rows: [
        _row(rank: 1, name: 'Paul', toPar: -1, holes: holes),
      ]));
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byIcon(Icons.expand_less), findsNothing);
    });

    testWidgets('the summary line, and a legend under the grid', (t) async {
      await _pump(t, _board(rows: [
        _row(rank: 1, name: 'Paul', toPar: -1, gross: 35, thru: 9,
            holes: holes),
      ]));
      await t.tap(find.text('Paul'));
      await t.pumpAndSettle();
      expect(find.textContaining('Gross 35'), findsOneWidget);
      expect(find.textContaining('Thru 9'), findsOneWidget);
      for (final l in ['Birdie', 'Bogey', 'Double', 'Stroke']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
    });

    testWidgets('a back-nine round draws IN alone', (t) async {
      final back = [
        for (var h = 10; h <= 18; h++)
          {'hole': h, 'gross': 4, 'par': 4, 'net_adj': 4},
      ];
      await _pump(t, StrokePlayBoardData(
        rows: [_row(rank: 1, name: 'Paul', toPar: 0, holes: back, thru: 9)],
        basisLabel: 'Net',
        countingLabel: 'single round',
        holePars: {for (var h = 1; h <= 18; h++) h: 4},
        holesInPlay: [for (var h = 10; h <= 18; h++) h],
      ));
      await t.tap(find.text('Paul'));
      await t.pumpAndSettle();
      expect(find.text('IN'), findsOneWidget);
      expect(find.text('OUT'), findsNothing);
    });
  });

  group('one table, not two', () {
    test('the leaderboard renders StrokePlayBoard and keeps no table', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect(src.contains('StrokePlayBoard('), isTrue);
      // The table this replaced lived only here, and two drawings of one
      // board is how the two come to disagree.
      expect(src.contains('_playerBlock('), isFalse);
      expect(src.contains('Widget _headerRow('), isFalse);
    });

    test('the board writes no money and no ranks of its own', () {
      final src = File('lib/widgets/stroke_play_board.dart').readAsStringSync();
      for (final banned in ['..sort(', 'rank =', 'payout ='])  {
        expect(src.contains(banned), isFalse, reason: banned);
      }
    });
  });

  group('multi-round columns', () {
    StrokePlayBoardData board(int n, {int live = 0, List<bool>? counts}) {
      return StrokePlayBoardData(
        rows: [
          StrokePlayRow(
            playerId: 1, rank: 1, name: 'Tom', handicapLabel: '14',
            toPar: -6, grossTotal: 150, thru: 9, holes: const [],
            roundToPar: [for (var i = 0; i < n; i++) -(i + 1)],
            roundCounts: counts ?? [for (var i = 0; i < n; i++) true],
            roundHoles: [
              for (var i = 0; i < n; i++)
                [
                  for (var h = 1; h <= 9; h++)
                    {'hole': h, 'gross': 4, 'par': 4, 'net_adj': 4},
                ],
            ],
          ),
        ],
        basisLabel: 'Net',
        countingLabel: n == 1 ? 'single round' : 'best of $n rounds',
        rounds: [
          for (var i = 0; i < n; i++)
            StrokeRoundCol(index: i, label: 'R${i + 1}', live: i == live),
        ],
        holePars: {for (var h = 1; h <= 18; h++) h: 4},
        holesInPlay: [for (var h = 1; h <= 18; h++) h],
      );
    }

    test('the layout follows the round count, and nothing else', () {
      expect(board(1).layout, StrokeLayout.single);
      expect(board(2).layout, StrokeLayout.twoRounds);
      expect(board(3).layout, StrokeLayout.prevAndLive);
      expect(board(6).layout, StrokeLayout.prevAndLive);
    });

    testWidgets('two rounds: R1 · R2 · Tot · Thru', (t) async {
      await _pump(t, board(2, live: 1));
      expect(find.text('R1'), findsOneWidget);
      expect(find.text('R2'), findsOneWidget);
      expect(find.text('TOT'), findsOneWidget);
      expect(find.text('THRU'), findsOneWidget);
      // Gross is a single-round column; with rounds it gives up its place.
      expect(find.text('GROSS'), findsNothing);
    });

    testWidgets('three or more: PREV and the live round', (t) async {
      await _pump(t, board(6, live: 4));
      expect(find.text('PREV'), findsOneWidget);
      expect(find.text('R5'), findsOneWidget);
      // Not a column each — that is the whole point of collapsing them.
      expect(find.text('R1'), findsNothing);
      expect(find.text('R2'), findsNothing);
    });

    test('Prev is the best COUNTED rounds so far', () {
      // Best 4 of 6, live round 5 (index 4): rounds 1 and 3 count, 2 does
      // not, so Prev is -1 + -3 and the -2 is left out.
      final d = board(6, live: 4,
          counts: [true, false, true, false, false, false]);
      expect(d.rows.first.prevToPar(4), -4);
    });

    test('Prev is NULL when nothing counts yet, which is not level par', () {
      final d = board(3, live: 2, counts: [false, false, true]);
      expect(d.rows.first.prevToPar(2), isNull);
    });

    testWidgets('a round that does not count is struck through, not hidden',
        (t) async {
      await _pump(t, board(2, live: 1, counts: [false, true]));
      final struck = t.widgetList<Text>(find.byType(Text)).where((w) =>
          w.style?.decoration == TextDecoration.lineThrough);
      expect(struck, isNotEmpty,
          reason: 'the golfer played it; hiding it invites the question '
                  'of where it went');
    });

    testWidgets('the open card tabs the rounds, live one first', (t) async {
      await _pump(t, board(2, live: 1));
      await t.tap(find.text('Tom'));
      await t.pumpAndSettle();
      expect(find.text('Round 1'), findsOneWidget);
      expect(find.text('Round 2'), findsOneWidget);
    });

    testWidgets('one round draws no tabs — a single tab is not a control',
        (t) async {
      await _pump(t, _board(rows: [
        _row(rank: 1, name: 'Paul', toPar: -1, holes: [
          for (var h = 1; h <= 9; h++)
            {'hole': h, 'gross': 4, 'par': 4, 'net_adj': 4},
        ]),
      ]));
      await t.tap(find.text('Paul'));
      await t.pumpAndSettle();
      expect(find.text('Round 1'), findsNothing);
    });
  });
}
