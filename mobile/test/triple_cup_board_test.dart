import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/hole_grid_scorecard.dart';
import 'package:golf_mobile/widgets/triple_cup_board.dart';
import 'package:golf_mobile/widgets/triple_cup_entry.dart';

/// TripleCupBoard — `handoff-triple-cup-score-entry` (11 Nov 2026).
///
/// The fixtures are the leaderboard GROUP as the server sends it (summary +
/// board), written by `scoring/tests/test_triple_cup_hole_card.py` under
/// `REGEN_TC_FIXTURES=1`.

Map<String, dynamic> _g(String n) =>
    jsonDecode(File('test/fixtures/$n.json').readAsStringSync())
        as Map<String, dynamic>;

Future<void> _pump(WidgetTester t, Widget child,
    {Size size = const Size(390, 1400)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child))));
}

void main() {
  group('the board', () {
    testWidgets('thru 9: the cup, the matches, one line of money', (t) async {
      await _pump(t, TripleCupBoard(group: _g('triple_cup_group_thru9')));
      expect(find.text('THE CUP · THRU 9'), findsOneWidget);
      expect(find.text('1 OF 4 DECIDED'), findsOneWidget);
      expect(find.text('TEAM 1'), findsOneWidget);
      expect(find.text('TEAM 2'), findsOneWidget);
      expect(find.byType(CupStrip), findsOneWidget);
      expect(find.text('3 points still out · 2½ wins'), findsOneWidget);
      expect(find.text('MATCHES'), findsOneWidget);
      expect(find.text('FINAL'), findsOneWidget);
      expect(find.text('PLAYING'), findsOneWidget);
      expect(find.text('TO COME'), findsOneWidget);
      expect(find.text('Paul + Hal win 2 UP'), findsOneWidget);
      expect(find.text('Paul + Hal 1 UP'), findsOneWidget);
      expect(find.text('thru 3 of 6 · 3 to play'), findsOneWidget);
      // Both Singles, a line and a strip each, before either has started.
      expect(find.text('starts 13'), findsNWidgets(2));
      expect(find.text('\$100'), findsOneWidget);
      expect(find.textContaining('Winners take all.'), findsOneWidget);
    });

    testWidgets('every segment carries six tiles a match', (t) async {
      await _pump(t, TripleCupBoard(group: _g('triple_cup_group_thru9')));
      // From the 2nd: `1` is also Team 1's cup score on this board.
      for (var h = 2; h <= 12; h++) {
        expect(find.text('$h'), findsOneWidget, reason: 'hole $h');
      }
      // The Singles run two matches over the same six holes.
      for (var h = 13; h <= 18; h++) {
        expect(find.text('$h'), findsNWidgets(2), reason: 'hole $h');
      }
    });

    testWidgets('the finish: the cup is won and each winner nets a stake',
        (t) async {
      await _pump(t, TripleCupBoard(group: _g('triple_cup_group_final')));
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('3½'), findsOneWidget);
      expect(find.text('½'), findsOneWidget);
      expect(find.text('Team 1 wins the cup'), findsOneWidget);
      expect(find.text('FINAL · WINNERS TAKE ALL'), findsOneWidget);
      expect(find.text('Paul & Hal'), findsOneWidget);
      expect(find.text('+\$25 each'), findsOneWidget);
      expect(find.text('Pete and Wendy pay \$25 each'), findsOneWidget);
      expect(find.text('Match halved ½'), findsOneWidget);
    });

    testWidgets('a team cup draws no money and names the group', (t) async {
      final g = _g('triple_cup_group_thru9');
      final b = (g['board'] as Map).cast<String, dynamic>();
      b['money'] = null;
      b['tournament'] = true;
      b['team_names'] = ['Blue Team', 'Red Team'];
      b['team_colours'] = ['blue', 'red'];
      await _pump(t, TripleCupBoard(
          group: g, heading: 'Group 1 · 8:20 AM', mine: true));
      expect(find.text('Group 1 · 8:20 AM'), findsOneWidget);
      expect(find.text('YOUR GROUP'), findsOneWidget);
      expect(find.text('BLUE TEAM'), findsOneWidget);
      expect(find.textContaining('Winners take all'), findsNothing);
    });

    test('an older server\'s group cannot draw one', () {
      expect(TripleCupBoard.canDraw({'summary': {}}), isFalse);
      expect(TripleCupBoard.canDraw(_g('triple_cup_group_thru9')), isTrue);
    });

    testWidgets('it survives a narrow phone', (t) async {
      await _pump(t, TripleCupBoard(group: _g('triple_cup_group_final')),
          size: const Size(320, 1600));
      expect(t.takeException(), isNull);
    });
  });

  group('the scorecard blocks', () {
    final blocks = tripleCupScorecardBlocks(
        (_g('triple_cup_group_thru14')['summary'] as Map)
            .cast<String, dynamic>());

    test('three blocks of six, in segment order', () {
      expect([for (final b in blocks) b.title], [
        'Fourball · holes 1–6',
        'Foursomes · holes 7–12',
        'Singles · holes 13–18',
      ]);
      expect([for (final b in blocks) b.holes.length], [6, 6, 6]);
    });

    test('Fourball is a row a golfer; Foursomes a row a SIDE', () {
      expect([for (final p in blocks[0].players) p['name']],
          ['Paul', 'Hal', 'Pete', 'Wendy']);
      expect([for (final p in blocks[1].players) p['name']],
          ['Paul & Hal', 'Pete & Wendy']);
    });

    test('the Singles run in match order', () {
      expect([for (final p in blocks[2].players) p['name']],
          ['Paul', 'Pete', 'Hal', 'Wendy']);
    });

    test('a side\'s row carries the side\'s ball', () {
      final hole7 = blocks[1].rows.first;
      final scores = (hole7['scores'] as List).cast<Map>();
      expect(scores.length, 2);
      expect(scores.every((s) => s['gross'] != null), isTrue);
    });

    List<int?> wonOn(int block, int hole) {
      final row = blocks[block].rows.firstWhere((r) => r['hole'] == hole);
      return [
        for (final s in (row['scores'] as List).cast<Map>())
          s['won_team'] as int?,
      ];
    }

    test('only the ball that won the hole is marked', () {
      // Hole 1: Team 1 on Paul's ball — not Hal's.
      expect(wonOn(0, 1), [1, null, null, null]);
      // Hole 3: Team 2 on Pete's.
      expect(wonOn(0, 3), [null, null, 2, null]);
    });

    test('a halved hole marks nothing', () {
      expect(wonOn(0, 2), [null, null, null, null]);
      expect(wonOn(1, 7), [null, null]);
    });

    test('two Singles on one hole can be won by different sides', () {
      // Hole 13: Pete beats Paul, and Hal beats Wendy.
      expect(wonOn(2, 13), [null, 2, 1, null]);
    });

    test('an unplayed hole still carries its strokes', () {
      final row = blocks[2].rows.firstWhere((r) => r['hole'] == 18);
      for (final s in (row['scores'] as List).cast<Map>()) {
        expect(s['gross'], isNull);
        expect(s.containsKey('strokes'), isTrue);
      }
    });
  });

  group('the Scorecard tab', () {
    testWidgets('three of the app\'s own scorecards, and the key',
        (t) async {
      await t.binding.setSurfaceSize(const Size(390, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(home: Scaffold(
          body: TripleCupScorecard(group: _g('triple_cup_group_thru14')))));
      expect(find.byType(HoleGridScorecard), findsNWidgets(3));
      expect(find.text('SCORECARD'), findsOneWidget);
      expect(find.text('THRU 14'), findsOneWidget);
      expect(find.textContaining('A shaded score won the hole'),
          findsOneWidget);
      // A segment is six holes: no OUT after the 9th.
      expect(find.text('OUT'), findsNothing);
      expect(find.text('TOT'), findsNothing);
    });
  });

  group('the leaderboard uses them', () {
    final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();

    test('a group draws the board where the server sends one', () {
      expect(src, contains('TripleCupBoard.canDraw(group)'));
      expect(src, contains(': _TripleCupGroupCard(group: group)'));
    });

    test('the Scorecard is a tab straight after the board', () {
      expect(src, contains(
          "games.insert(games.indexOf('triple_cup') + 1, _kTcScorecardTab)"));
      expect(src, contains("if (g == _kTcScorecardTab) return 'Scorecard';"));
    });

    test('a casual cup\'s tab is the game\'s name', () {
      expect(src, contains(
          "return lb?.tournamentId == null ? 'Triple Cup' : 'Cup Detail';"));
    });

    test('a spectator with no group gets no Scorecard tab', () {
      final at = src.indexOf(
          'Map<String, dynamic>? _tripleCupScorecardGroup(Leaderboard lb)');
      final body = src.substring(at, src.indexOf('\n  }\n', at));
      expect(body, contains('return groups.length == 1 ? groups.first : null;'));
    });
  });
}
