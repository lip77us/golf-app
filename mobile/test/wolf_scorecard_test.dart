import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_colors.dart';
import 'package:golf_mobile/widgets/hole_grid_scorecard.dart';
import 'package:golf_mobile/widgets/wolf_scorecard.dart';

/// The Wolf scorecard moved from the play screen to the leaderboard (Paul,
/// 10 Nov 2026: *"move the Wolf scorecard from the score entry board to the
/// leaderboard. Remove the strokes table and the scorecard from the
/// leaderboard. Keep the colors … and add the gets"*).
///
/// The fixture is REAL engine output — three holes: the Wolf's side wins the
/// 1st, the opponents the 2nd, the 3rd is tied — written by
/// `REGEN_WOLF_FIXTURES=1 manage.py test
/// scoring.tests.test_wolf_scorecard_sides`.

Map<String, dynamic> _summary() => jsonDecode(
        File('test/fixtures/wolf_board_summary.json').readAsStringSync())
    as Map<String, dynamic>;

Future<void> _pump(WidgetTester t, Map<String, dynamic> summary) async {
  await t.binding.setSurfaceSize(const Size(900, 500));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: WolfScorecard(summary: summary)),
    ),
  ));
  await t.pumpAndSettle();
}

Map<String, dynamic> _hole(Map<String, dynamic> s, int n) =>
    ((s['scorecard'] as Map)['holes'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((h) => h['hole'] == n);

/// The fill behind golfer [pid]'s gross on hole [n] — the cell is the
/// decorated 32x26 box around a digit.
Color? _tint(WidgetTester t, Map<String, dynamic> s, int n, int pid) {
  final score = (_hole(s, n)['scores'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((x) => x['player_id'] == pid);
  final players = ((s['scorecard'] as Map)['players'] as List)
      .cast<Map<String, dynamic>>();
  final row = players.indexWhere((p) => p['player_id'] == pid);
  final cells = t.widgetList<Container>(find.byWidgetPredicate((w) =>
      w is Container &&
      w.constraints?.maxWidth == 32 &&
      w.constraints?.maxHeight == 26 &&
      w.decoration is BoxDecoration &&
      w.child is Stack)).toList();
  // Group the cells into rows by their top edge, then take this golfer's
  // row and the hole's column. The digit is checked at the end, so a cell
  // found by position that is not the one meant fails rather than passing.
  final want = '${score['gross']}';
  final rows = <double, List<Container>>{};
  for (final c in cells) {
    final dy = t.getTopLeft(find.byWidget(c)).dy;
    rows.putIfAbsent(dy, () => []).add(c);
  }
  final ys = rows.keys.toList()..sort();
  final mine = rows[ys[row]]!;
  final holeX = <double>{
    for (final c in mine) t.getTopLeft(find.byWidget(c)).dx,
  }.toList()..sort();
  // The played holes are the first columns in every row of this fixture.
  final cell = mine.firstWhere(
      (c) => t.getTopLeft(find.byWidget(c)).dx == holeX[n - 1]);
  expect(find.descendant(of: find.byWidget(cell), matching: find.text(want)),
      findsOneWidget, reason: 'found the wrong cell');
  return (cell.decoration as BoxDecoration).color;
}

void main() {
  final s = _summary();
  final players = ((s['scorecard'] as Map)['players'] as List)
      .cast<Map<String, dynamic>>();
  int pid(String short) => players
      .firstWhere((p) => (p['name'] as String).startsWith(short))['player_id']
      as int;

  group('the fixture is the three cases', () {
    test('the Wolf\'s side, the opponents, and a tie', () {
      expect(_hole(s, 1)['winner_team'], 1);
      expect(_hole(s, 2)['winner_team'], 2);
      expect(_hole(s, 3)['winner_team'], isNull);
      expect(_hole(s, 3)['scores'].every((x) => x['gross'] != null), isTrue,
          reason: 'the 3rd is PLAYED and tied, not unplayed');
    });
  });

  group('the colours are the play screen\'s', () {
    testWidgets('the Wolf\'s side wears blue on the hole it won', (t) async {
      await _pump(t, s);
      // 1st: Sam took Paul and won.
      expect(_tint(t, s, 1, pid('Sam')), GameColors.team1Bg);
      expect(_tint(t, s, 1, pid('Paul')), GameColors.team1Bg);
      expect(_tint(t, s, 1, pid('Dave')), isNull);
      expect(_tint(t, s, 1, pid('Lee')), isNull);
    });

    testWidgets('the opponents wear orange on the hole they won', (t) async {
      await _pump(t, s);
      // 2nd: Lee went alone and lost.
      expect(_tint(t, s, 2, pid('Lee')), isNull);
      for (final n in ['Paul', 'Dave', 'Sam']) {
        expect(_tint(t, s, 2, pid(n)), GameColors.team2Bg, reason: n);
      }
    });

    testWidgets('a tie tints nobody', (t) async {
      // Both sides drew it: tinting both would say two sides won.
      await _pump(t, s);
      for (final n in ['Paul', 'Dave', 'Sam', 'Lee']) {
        expect(_tint(t, s, 3, pid(n)), isNull, reason: n);
      }
    });

    testWidgets('it is never the win GREEN', (t) async {
      // Everywhere else green means this BALL won, and a Wolf hole is won
      // by a side.
      await _pump(t, s);
      final greens = t.widgetList<Container>(find.byType(Container)).where(
          (c) => (c.decoration is BoxDecoration) &&
              (c.decoration as BoxDecoration).color == Colors.green.shade100);
      expect(greens, isEmpty);
    });

    testWidgets('both colours are keyed', (t) async {
      // With one keyed, the other reads as a second unexplained state.
      await _pump(t, s);
      expect(find.text('Wolf side won'), findsOneWidget);
      expect(find.text('opponents won'), findsOneWidget);
    });
  });

  group('the Wolf row', () {
    testWidgets('names who held the Wolf, above the golfers', (t) async {
      await _pump(t, s);
      final label = find.text('Wolf');
      expect(label, findsOneWidget);
      final firstGolfer = find.byWidgetPredicate((w) =>
          w is RichText &&
          w.text.toPlainText().startsWith(
              (players.first['short_name'] as String)));
      expect(t.getTopLeft(label).dy,
          lessThan(t.getTopLeft(firstGolfer.first).dy));
    });

    testWidgets('on holes not yet played too', (t) async {
      // The rotation is known up front; the hole ahead is the one a group
      // asks about.
      await _pump(t, s);
      final w = (_hole(s, 4)['wolf_short'] as String);
      expect(w, isNotEmpty);
      expect(find.text(w.characters.take(3).toString()), findsWidgets);
    });
  });

  group('gets, and no strokes table', () {
    testWidgets('each golfer says what he gets; the low man says nothing',
        (t) async {
      await _pump(t, s);
      String label(String short) => t
          .widgetList<RichText>(find.byType(RichText))
          .map((r) => r.text.toPlainText())
          .firstWhere((x) => x.startsWith(short));
      for (final p in players) {
        final gets = (p['phcp_in_play'] as num).toInt();
        final short = p['short_name'] as String;
        expect(label(short), gets > 0 ? '$short gets $gets' : short);
      }
      expect(players.any((p) => p['phcp_in_play'] == 0), isTrue,
          reason: 'the fixture has a low man');
    });

    testWidgets('the card passes showStrokes: false', (t) async {
      await _pump(t, s);
      final card = t.widget<HoleGridScorecard>(find.byType(HoleGridScorecard));
      expect(card.showStrokes, isFalse);
    });
  });

  group('the points are at the bottom', () {
    // They came off with the old card and Paul asked for them back the same
    // afternoon: "add the points on the bottom of the table".
    testWidgets('a points row a golfer, under the scores', (t) async {
      await _pump(t, s);
      for (final p in players) {
        final short = p['short_name'] as String;
        final pts = find.text('$short pts');
        expect(pts, findsOneWidget);
        final name = find.byWidgetPredicate((w) =>
            w is RichText && w.text.toPlainText().startsWith(short));
        expect(t.getTopLeft(pts).dy,
            greaterThan(t.getTopLeft(name.first).dy));
      }
    });

    testWidgets('the figures are the server\'s, hole for hole', (t) async {
      // 1st: Sam took Paul and won — +1 each, −1 each. Read off the payload
      // rather than typed, so the test follows the fixture.
      await _pump(t, s);
      final pts = (_hole(s, 1)['scores'] as List)
          .map((x) => (x['points'] as num).toDouble())
          .toList();
      expect(pts.where((v) => v > 0), isNotEmpty);
      expect(pts.where((v) => v < 0), isNotEmpty);
      expect(pts.reduce((a, b) => a + b), 0);
      expect(find.text('+1'), findsWidgets);
    });
  });

  group('where it lives', () {
    final lb = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
    final ws = File('lib/screens/wolf_screen.dart').readAsStringSync();

    String wolfCard() {
      final at = lb.indexOf('class _WolfGroupCard');
      expect(at, greaterThan(0));
      return lb.substring(at, lb.indexOf('\nclass ', at + 10));
    }

    test('the leaderboard\'s Wolf card draws it', () {
      expect(wolfCard(), contains('WolfScorecard(summary: summary)'));
    });

    test('the Wolf-by-hole chips are gone', () {
      // A chip a hole naming its Wolf, tinted by the side that won — which
      // is the scorecard's `Wolf` row and its tints, said a second time.
      // The DRAWN form: the comment explaining the removal names it too,
      // and a bare-name test matches its own prose.
      expect(wolfCard().contains("Text('Wolf by hole'"), isFalse);
      expect(lb.contains('_wolfChip('), isFalse);
    });

    test('and no other scorecard beside it', () {
      // The gross card with its points block and strokes table is what this
      // replaced; both at once is the two-drawings-of-one-thing shape.
      expect(wolfCard().contains('HoleGridScorecard('), isFalse);
    });

    test('the play screen draws none', () {
      expect(ws.contains('_WolfGrid('), isFalse);
      expect(ws.contains('class _WolfGrid'), isFalse);
      expect(ws.contains('PinnedHoleGrid('), isFalse);
    });

    test('and no longer decides which side won', () {
      // The server marks `winner_team` and `team`; a second copy of the rule
      // on the phone is how the board and the tray come to disagree.
      expect(ws.contains('wolfWonTheHole'), isFalse);
      expect(File('lib/widgets/wolf_scorecard.dart').readAsStringSync()
          .contains('winning_side'), isFalse);
    });
  });
}
