import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/stableford_standings.dart';

/// The Stableford board's order — place, points and `thru N` (Paul, 11 Nov
/// 2026). The rows are the server's `results`, which arrive ranked.

Map<String, dynamic> _r(int rank, String name, int pts, int thru,
        {num? payout, bool excluded = false}) =>
    {'rank': rank, 'player_name': name, 'total_points': pts,
     'holes_played': thru, 'payout': payout, 'excluded': excluded};

Future<void> _pump(WidgetTester t, List<Map<String, dynamic>> rows,
    {double width = 390, int holes = 18}) async {
  await t.binding.setSurfaceSize(Size(width, 500));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: Scaffold(
      body: StablefordStandings(results: rows, holesInRound: holes))));
}

void main() {
  testWidgets('each row is the place, the points and how far round',
      (t) async {
    await _pump(t, [
      _r(1, 'Paul Lipkin', 21, 9),
      _r(2, 'Dave Moran', 18, 12),
    ]);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('21'), findsOneWidget);
    expect(find.text('pts'), findsNWidgets(2));
    expect(find.text('thru 9'), findsOneWidget);
    expect(find.text('thru 12'), findsOneWidget);
  });

  testWidgets('it keeps the server\'s order and does not sort', (t) async {
    await _pump(t, [_r(1, 'Zed', 5, 3), _r(2, 'Abe', 9, 3)]);
    expect(t.getTopLeft(find.text('Zed')).dy,
        lessThan(t.getTopLeft(find.text('Abe')).dy));
  });

  testWidgets('a shared rank reads T', (t) async {
    await _pump(t, [
      _r(1, 'Ann', 20, 9), _r(2, 'Ben', 18, 9), _r(2, 'Cal', 18, 9),
    ]);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('T2'), findsNWidgets(2));
  });

  testWidgets('a finished card reads F', (t) async {
    await _pump(t, [_r(1, 'Ann', 36, 18), _r(2, 'Ben', 20, 9)]);
    expect(find.text('F'), findsOneWidget);
    expect(find.text('thru 9'), findsOneWidget);
    // …and on a nine-hole round nine holes IS finished.
    await _pump(t, [_r(1, 'Ann', 18, 9)], holes: 9);
    expect(find.text('F'), findsOneWidget);
  });

  testWidgets('a golfer who has not started holds no place', (t) async {
    await _pump(t, [_r(1, 'Ann', 6, 3), _r(2, 'Ben', 0, 0)]);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('not started'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.text('pts'), findsOneWidget);
  });

  testWidgets('money and an excluded golfer are marked', (t) async {
    await _pump(t, [
      _r(1, 'Ann', 36, 18, payout: 40),
      _r(2, 'Ben', 30, 18, excluded: true),
    ]);
    expect(find.text('\$40'), findsOneWidget);
    expect(find.text('NOT PAID'), findsOneWidget);
  });

  testWidgets('the points line up, whoever is paid', (t) async {
    // One paid, one excluded, one not started, and totals of different
    // widths: every points figure and every `thru` shares one right edge.
    await _pump(t, [
      _r(1, 'Ann', 36, 18, payout: 40),
      _r(2, 'Bartholomew Featherstonehaugh', 9, 7, excluded: true),
      _r(3, 'Cal', 1, 12),
    ]);
    // The FIGURES share a right edge — including the `1`, whose unit is
    // `pt` and a letter narrower than the rest.
    final pts = {
      // `.last`: a `1` is also Ann's PLACE, further left on the first row.
      for (final x in ['36', '9', '1'])
        t.getTopRight(find.text(x).last).dx,
    };
    expect(pts.length, 1, reason: '$pts');
    expect(find.text('pt'), findsOneWidget);
    final units = {
      for (final e in find.textContaining(RegExp(r'^pts?$')).evaluate())
        t.getTopLeft(find.byWidget(e.widget)).dx,
    };
    expect(units.length, 1, reason: '$units');
    final thru = {
      for (final x in ['F', 'thru 7', 'thru 12'])
        t.getTopRight(find.text(x)).dx,
    };
    expect(thru.length, 1, reason: '$thru');
  });

  testWidgets('no money column on a round nobody is paid on', (t) async {
    await _pump(t, [_r(1, 'Ann', 6, 3), _r(2, 'Ben', 4, 3)]);
    // `thru` runs to the card's right edge: no empty column beside it.
    final card = t.getTopRight(find.byType(StablefordStandings)).dx;
    expect(card - t.getTopRight(find.text('thru 3').first).dx,
        lessThan(20));
  });

  testWidgets('it survives a narrow phone and a long name', (t) async {
    await _pump(t, [
      _r(1, 'Bartholomew Featherstonehaugh', 21, 9, payout: 12.5),
    ], width: 320);
    expect(t.takeException(), isNull);
  });

  test('the Stableford tab draws it above the scorecard', () {
    final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
    final at = src.indexOf('class _StablefordView');
    final st = src.indexOf('StablefordStandings(', at);
    final card = src.indexOf('HoleGridScorecard(', at);
    expect(st, greaterThan(at));
    expect(st, lessThan(card));
  });
}
