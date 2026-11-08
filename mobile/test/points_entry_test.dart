import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/points_entry.dart';

/// The Points 5-3-1 dark tray — `~/Downloads/handoff-points-score-entry`.
///
/// The engine is covered in `scoring/tests/test_points_531_hole_card.py`;
/// these are about what the tray DRAWS, and the source guards are about what
/// a dedicated play screen loses when a keypad is bolted onto it.

PointsHoleCard _card({
  bool roundOver = false,
  List<List<dynamic>> awards = const [
    [1, 'Paul', 4, 5.0, false],
    [2, 'Dave', 5, 3.0, false],
    [3, 'Sam', 6, 1.0, false],
  ],
  List<List<dynamic>> standing = const [
    [1, 'Paul', 27.0, 6.0, 6.0],
    [2, 'Dave', 20.0, -1.0, -1.0],
    [3, 'Sam', 16.0, -5.0, -5.0],
  ],
}) =>
    PointsHoleCard.fromJson(<String, dynamic>{
      'hole': 7, 'par': 4, 'stroke_index': 5, 'yards': 376,
      'nine': 'front nine', 'thru': 7, 'target': 21, 'par_per_hole': 3,
      'stake': 1.0,
      'players': [
        {'player_id': 1, 'name': 'Paul L', 'short': 'Paul',
         'course_handicap': 8, 'strokes': 0, 'gross': 4, 'net': 4,
         'points': 5.0},
      ],
      'points_rows': [
        for (final a in awards)
          {'player_id': a[0], 'short': a[1], 'net': a[2], 'points': a[3],
           'tied': a[4]},
      ],
      'standing': [
        for (final s in standing)
          {'player_id': s[0], 'short': s[1], 'points': s[2],
           'v_target': s[3], 'money': s[4]},
      ],
      'hole_complete': true,
      'round_over': roundOver,
      'winner': roundOver
          ? {'short': 'Paul', 'points': 62.0, 'money': 8.0,
             'target': 54, 'settles': 'vs Average'}
          : null,
    });

Future<void> _pump(WidgetTester t, PointsHoleCard card) async {
  await t.binding.setSurfaceSize(const Size(390, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: PointsHoleTray(
        card: card,
        colours: const {1: Halved.onDark1, 2: Halved.onDark2,
                        3: Halved.onDark3},
        onEdit: () {},
        nextHole: card.roundOver ? null : 8,
        onNext: () {},
        onPrev: () {},
      ),
    ),
  ));
}

void main() {
  group('the tray', () {
    testWidgets('reports the hole and the standing', (t) async {
      await _pump(t, _card());
      expect(find.text('All 3 scores in'), findsOneWidget);
      expect(find.text('HOLE 7 · NET TO POINTS'), findsOneWidget);
      expect(find.text('EACH · NOW'), findsOneWidget);
      expect(find.text('net 4'), findsOneWidget);
      expect(find.text('Hole 8 ›'), findsOneWidget);
    });

    testWidgets('a whole number of points shows no decimal', (t) async {
      // Points are halves at most — a tied hole splits 5 and 3 into 4 and 4
      // — so `5.0` must read `5` and only a real half shows a `.5`.
      await _pump(t, _card());
      expect(find.text('5'), findsWidgets);
      expect(find.text('5.0'), findsNothing);
    });

    testWidgets('a tied row says so', (t) async {
      // Tied points are not 5, 3 or 1, and nothing else on the row explains
      // why a golfer has 4.
      await _pump(t, _card(awards: const [
        [1, 'Paul', 4, 4.0, true],
        [3, 'Sam', 4, 4.0, true],
        [2, 'Dave', 5, 1.0, false],
      ]));
      expect(find.text('tied'), findsNWidgets(2));
    });

    testWidgets('level against target reads E, never +0', (t) async {
      await _pump(t, _card(standing: const [
        [1, 'Paul', 21.0, 0.0, 0.0],
        [2, 'Dave', 21.0, 0.0, 0.0],
        [3, 'Sam', 21.0, 0.0, 0.0],
      ]));
      expect(find.text('E'), findsNWidgets(3));
      expect(find.text('+0'), findsNothing);
      expect(find.text('\$0'), findsNWidgets(3));
    });

    testWidgets('a true minus, not a hyphen', (t) async {
      await _pump(t, _card());
      expect(find.text('−1'), findsOneWidget);
      expect(find.text('-1'), findsNothing);
    });

    testWidgets('the last hole finishes the round', (t) async {
      // The tray covers the screen's pager, so a forward button that only
      // advanced left the 18th a dead end — reported on Rabbit, whose tray
      // has the identical shape.
      await _pump(t, _card(roundOver: true));
      expect(find.text('Finish round ›'), findsOneWidget);
      expect(find.text('Round over'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.textContaining('Paul wins with 62 pts'), findsOneWidget);
      expect(find.textContaining('Target 54'), findsOneWidget);
    });

    testWidgets('it fits a phone without overflowing', (t) async {
      // A RenderFlex overflow is reported through the binding, and the
      // framework fails the test on it by itself — so this asserts the
      // exception is absent rather than DRAINING it, which is what the
      // first version did and would have hidden the very thing it is for.
      await _pump(t, _card(roundOver: true));
      expect(t.takeException(), isNull);
      // ...and at the narrowest phone the app supports.
      await t.binding.setSurfaceSize(const Size(320, 900));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('the screen keeps what a dedicated play screen loses', () {
    final src = File('lib/screens/points_531_screen.dart').readAsStringSync();

    test('the keypad posts the hole on its last score', () {
      // A hole left unsent raises a tray with nothing in it — the bug
      // Annandale hit, and then Sixes.
      final onScore = src.substring(src.indexOf('onScore: (n) {'));
      final body = onScore.substring(0, onScore.indexOf('onClear:'));
      expect(body, contains('_saveAndAdvance'));
    });

    test('the keypad reads the strokes off the CARD', () {
      // Not the round's stored full-net allocation, which is a different
      // number whenever the game is strokes-off.
      expect(src, contains('card.playerById(m.player.id)?.strokes'));
      final k = src.substring(src.indexOf('FortyBallsKeypad('));
      expect(k.substring(0, k.indexOf('onScore:')),
          isNot(contains('handicapStrokes')));
    });

    test('Clear passes the sentinel, never a zero', () {
      // `_selectScore` reads anything but −1 as a score, so 0 writes a gross
      // of zero: the row reads as scored and the hole counts as complete.
      final c = src.substring(src.indexOf('onClear:'));
      expect(c.substring(0, c.indexOf('\n')), contains('-1'));
    });

    test('the pager walks PLAY ORDER, not hole numbers', () {
      // A shotgun group starting on the 7th plays 7..18,1..6, so `+1` walks
      // off the end of its own round and 18 is not its last hole.
      expect(src, contains('nextInOrder('));
      expect(src, contains('prevInOrder('));
      expect(src, isNot(contains('_selectedHole < 18')));
      expect(src, isNot(contains('_selectedHole > 1 ? _retreat')));
    });

    test('it still carries the combo chip and Spots', () {
      expect(src, contains('ComboTeeChip'));
      expect(src, contains('SpotsCaptureMixin'));
    });
  });
}
