import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/hole_grid_scorecard.dart';
import 'package:golf_mobile/widgets/strokes_table.dart';

/// The universal strokes table (Paul, 8 Nov 2026).
///
/// A scorecard's stroke DOTS answer "this score was made with a shot"; a
/// golfer asking "where do I stroke" is looking at holes that have no score
/// yet, and had to pick the dots out of a grid of numbers. Sixes and Sequoya
/// each grew a table of their own; this is that table once, for every board.

Map<String, dynamic> _hole(int h, Map<int, int> strokes, {int par = 4}) => {
      'hole': h, 'par': par, 'stroke_index': h,
      'scores': [
        for (final e in strokes.entries)
          {'player_id': e.key, 'gross': null, 'strokes': e.value},
      ],
    };

const _people = [
  {'player_id': 1, 'short_name': 'Paul'},
  {'player_id': 2, 'short_name': 'Dave'},
];

Future<void> _pump(WidgetTester t, Widget w,
    {Size size = const Size(390, 900)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: w))));
  await t.pumpAndSettle();
}

/// Every filled dot the table drew. **Both sizes** — a single stroke keeps
/// the 9px dot and only a doubled hole shrinks to 7, so a finder pinned to
/// one size counts half of them.
int _dots(WidgetTester t) => t
    .widgetList<Container>(find.byType(Container))
    .where((c) =>
        (c.constraints?.maxWidth == 7 || c.constraints?.maxWidth == 9) &&
        (c.decoration as BoxDecoration?)?.shape == BoxShape.circle)
    .length;

void main() {
  group('it gates itself on the STROKES, not a list of games', () {
    testWidgets('a gross round draws nothing at all', (t) async {
      // The alternative was a list of non-gross games to keep in step, and
      // eighteen blank cells on every scratch round.
      await _pump(t, StrokesTable(
        holes: [for (var h = 1; h <= 3; h++) _hole(h, {1: 0, 2: 0})],
        participants: _people,
      ));
      expect(find.text('STROKES'), findsNothing);
    });

    testWidgets('one stroke anywhere is enough to draw it', (t) async {
      await _pump(t, StrokesTable(
        holes: [_hole(1, {1: 0, 2: 1}), _hole(2, {1: 0, 2: 0})],
        participants: _people,
      ));
      expect(find.text('STROKES'), findsOneWidget);
      expect(_dots(t), 1);
    });

    testWidgets('and no holes at all draws nothing', (t) async {
      await _pump(t, const StrokesTable(holes: [], participants: _people));
      expect(find.text('STROKES'), findsNothing);
    });
  });

  group('the grid', () {
    testWidgets('one row a golfer, with his total', (t) async {
      await _pump(t, StrokesTable(
        holes: [_hole(1, {1: 0, 2: 1}), _hole(2, {1: 1, 2: 1})],
        participants: _people,
      ));
      expect(find.text('Paul'), findsOneWidget);
      expect(find.text('Dave'), findsOneWidget);
      expect(find.text('1'), findsWidgets);   // Paul's total and hole 1
      expect(find.text('2'), findsWidgets);   // Dave's total and hole 2
      expect(_dots(t), 3);
    });

    testWidgets('two strokes on a hole are TWO dots', (t) async {
      // A golfer who gets two there needs to see two.
      await _pump(t, StrokesTable(
        holes: [_hole(1, {1: 2, 2: 0})],
        participants: _people,
      ));
      expect(_dots(t), 2);
    });

    testWidgets('the columns follow PLAY order', (t) async {
      // Off a shotgun the group's first hole is not hole 1.
      await _pump(t, StrokesTable(
        holes: [_hole(1, {1: 1, 2: 0}), _hole(10, {1: 1, 2: 0})],
        participants: _people,
        holesInPlay: const [10, 1],
      ));
      final table = t.widget<StrokesTable>(find.byType(StrokesTable));
      expect(table.holesInPlay, [10, 1]);
      final tens = t.getTopLeft(find.text('10'));
      final ones = t.getTopLeft(find.text('1').first);
      expect(tens.dx, lessThan(ones.dx), reason: 'the 10th is played first');
    });

    testWidgets('sides are split by a rule, and a footer can name them',
        (t) async {
      await _pump(t, StrokesTable(
        holes: [_hole(1, {1: 0, 2: 1})],
        participants: _people,
        sides: const [[1], [2]],
        footer: 'Paul gets 0 · Dave gets 1 in this match',
        trailing: 'THIS MATCH',
      ));
      expect(find.byType(Divider), findsOneWidget);
      expect(find.text('THIS MATCH'), findsOneWidget);
      expect(find.text('Paul gets 0 · Dave gets 1 in this match'),
          findsOneWidget);
    });

    testWidgets('one block when there are no sides', (t) async {
      await _pump(t, StrokesTable(
        holes: [_hole(1, {1: 0, 2: 1})],
        participants: _people,
      ));
      expect(find.byType(Divider), findsNothing);
      expect(find.text('THIS ROUND'), findsOneWidget);
    });
  });

  group('every board gets one', () {
    testWidgets('a scorecard draws it underneath, by default', (t) async {
      await _pump(t, HoleGridScorecard(
        holes: [for (var h = 1; h <= 3; h++) _hole(h, {1: 0, 2: 1})],
        participants: _people,
        holesInPlay: const [1, 2, 3],
      ));
      expect(find.byType(StrokesTable), findsOneWidget);
      expect(find.text('STROKES'), findsOneWidget);
    });

    testWidgets('…and a gross round still draws none', (t) async {
      await _pump(t, HoleGridScorecard(
        holes: [for (var h = 1; h <= 3; h++) _hole(h, {1: 0, 2: 0})],
        participants: _people,
        holesInPlay: const [1, 2, 3],
      ));
      expect(find.text('STROKES'), findsNothing);
    });

    testWidgets('a score-entry grid opts OUT', (t) async {
      // There the grid is a progress read-out under a keypad, and a second
      // table would push the entry card off the screen.
      await _pump(t, HoleGridScorecard(
        holes: [for (var h = 1; h <= 3; h++) _hole(h, {1: 0, 2: 1})],
        participants: _people,
        holesInPlay: const [1, 2, 3],
        showStrokes: false,
      ));
      expect(find.byType(StrokesTable), findsNothing);
    });
  });

  group('the entry screens keep opting out', () {
    for (final f in const [
      'lib/screens/score_entry_screen.dart',
      'lib/screens/points_531_screen.dart',
      'lib/screens/sequoya_threes_screen.dart',
      'lib/widgets/banker_entry_strip.dart',
    ]) {
      test('$f passes showStrokes: false on every grid', () {
        // **Default ON is deliberate** — a board added tomorrow is covered
        // without anybody remembering. The cost is that a screen which does
        // NOT want one has to say so, and this is what keeps it said.
        // **Code lines only.** The name appears in prose too — one of
        // these files explains `HoleGridScorecard(showPoints: true)` in a
        // comment — and counting those made the test demand an opt-out for
        // a call that does not exist.
        final lines = File(f).readAsLinesSync();
        var calls = 0, flags = 0;
        for (final l in lines) {
          final code = l.split('//').first;
          if (code.contains('HoleGridScorecard(')) calls++;
          if (code.contains('showStrokes: false')) flags++;
        }
        expect(flags, calls,
            reason: '$calls grids, $flags opt-outs — a new one was added '
                'without the flag');
      });
    }
  });

  test('the Survivor board draws no strokes table', () {
    // Paul, 11 Nov 2026. The dots are on the cells and `gets N` is beside
    // each name, the call Stroke Play, Nassau, Las Vegas, Fourball, Skins
    // and Wolf each got.
    final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
    final at = src.indexOf('class _SurvivorGroupCardState');
    final end = src.indexOf('\nclass ', at + 1);
    final card = src.substring(at, end);
    final grid = card.indexOf('HoleGridScorecard(');
    expect(grid, greaterThan(0));
    final call = card.substring(grid, card.indexOf('),', grid));
    expect(call, matches(RegExp(r'showStrokes:\s*false')));
  });
}
