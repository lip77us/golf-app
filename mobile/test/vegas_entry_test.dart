import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/game_colors.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/vegas_entry.dart';

/// Las Vegas score entry — `~/Downloads/handoff-vegas-score-entry`.
///
/// The engine is covered in `scoring/tests/test_vegas_hole_card.py`; these
/// are about what the side header and the tray DRAW, and the source guards
/// are about what the shared score-entry screen has to keep doing.

Map<String, dynamic> _json({
  String? winner = 'team1',
  int points = 12,
  String note = '',
  String tieNote = '',
  bool roundOver = false,
  bool holeComplete = true,
  List<List<dynamic>> sides = const [
    // side, label, nets, raw, number, flipped, capped, result
    [1, 'Paul + Dave', [4, 5], 45, 45, false, false, 'won'],
    [2, 'Sam + Lee', [5, 7], 57, 57, false, false, 'lost'],
  ],
  List<List<dynamic>> standing = const [
    // side, label, hole, points, money
    [1, 'Paul + Dave', 12, 47, 11.75],
    [2, 'Sam + Lee', -12, -47, -11.75],
  ],
  Map<String, dynamic>? winnerBox,
  int? nextHole = 8,
}) =>
    <String, dynamic>{
      'hole': 7, 'par': 4, 'stroke_index': 5, 'yards': 376,
      'nine': 'front nine', 'thru': 7, 'stake': 0.25,
      'carryover': true, 'birdie_mode': 'flip',
      'players': [
        for (final p in const [
          [1, 'Paul Lipkin', 'PL', 'Paul', 8, 0, 4, 4, 1],
          [2, 'Dave Kim', 'DK', 'Dave', 12, 0, 5, 5, 1],
          [3, 'Sam Reid', 'SR', 'Sam', 15, 1, 6, 5, 2],
          [4, 'Lee Nash', 'LN', 'Lee', 18, 1, 8, 7, 2],
        ])
          {'player_id': p[0], 'name': p[1], 'short': p[2], 'first': p[3],
           'course_handicap': p[4], 'strokes': p[5], 'gross': p[6],
           'net': p[7], 'side': p[8]},
      ],
      'sides': [
        for (final s in sides)
          {'side': s[0], 'label': s[1],
           'player_ids': s[0] == 1 ? [1, 2] : [3, 4],
           'nets': s[2], 'raw': s[3], 'number': s[4],
           'flipped': s[5], 'capped': s[6], 'result': s[7]},
      ],
      'winner': winner,
      'points': points,
      'note': note,
      'tie_note': tieNote,
      'margin_before': 35,
      'margin_after': 47,
      'standing': [
        for (final s in standing)
          {'side': s[0], 'label': s[1], 'hole_points': s[2],
           'points': s[3], 'money': s[4]},
      ],
      'hole_complete': holeComplete,
      'round_over': roundOver,
      'winner_box': winnerBox,
      'next_hole': nextHole,
    };

VegasHoleCard _card({
  String? winner = 'team1',
  int points = 12,
  String note = '',
  String tieNote = '',
  bool roundOver = false,
  List<List<dynamic>>? sides,
  List<List<dynamic>>? standing,
  Map<String, dynamic>? winnerBox,
  int? nextHole = 8,
}) =>
    VegasHoleCard.fromJson(_json(
      winner: winner, points: points, note: note, tieNote: tieNote,
      roundOver: roundOver,
      sides: sides ??
          const [
            [1, 'Paul + Dave', [4, 5], 45, 45, false, false, 'won'],
            [2, 'Sam + Lee', [5, 7], 57, 57, false, false, 'lost'],
          ],
      standing: standing ??
          const [
            [1, 'Paul + Dave', 12, 47, 11.75],
            [2, 'Sam + Lee', -12, -47, -11.75],
          ],
      winnerBox: winnerBox, nextHole: nextHole,
    ));

Future<void> _pumpTray(WidgetTester t, VegasHoleCard card,
    {bool gettingResult = false}) async {
  await t.binding.setSurfaceSize(const Size(390, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: VegasHoleTray(
        card: card,
        onEdit: () {},
        onNext: () {},
        onPrev: () {},
        gettingResult: gettingResult,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the side header', () {
    testWidgets('it carries the number as it builds', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final card = _card();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            VegasSideHeader(side: card.sides[0]),
            VegasSideHeader(side: card.sides[1]),
          ]),
        ),
      ));
      expect(find.text('PAUL + DAVE'), findsOneWidget);
      expect(find.text('45'), findsOneWidget);
      expect(find.text('57'), findsOneWidget);
    });

    testWidgets('an unfinished side reads a dash, not half a number',
        (t) async {
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final card = _card(sides: const [
        [1, 'Paul + Dave', <int>[], null, null, false, false, null],
        [2, 'Sam + Lee', [5, 7], 57, 57, false, false, null],
      ]);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: VegasSideHeader(side: card.sides[0])),
      ));
      expect(find.text('–'), findsOneWidget);
    });

    testWidgets('it shows the number BEFORE the flip', (t) async {
      // The tray is where the flip is explained; the header is what the two
      // nets beside it add up to.
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final card = _card(sides: const [
        [1, 'Paul + Dave', [3, 5], 35, 35, false, false, 'won'],
        [2, 'Sam + Lee', [5, 6], 56, 65, true, false, 'lost'],
      ]);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: VegasSideHeader(side: card.sides[1])),
      ));
      expect(find.text('56'), findsOneWidget);
      expect(find.text('65'), findsNothing);
    });
  });

  group('the tray', () {
    testWidgets('an ordinary hole is two numbers and a margin', (t) async {
      await _pumpTray(t, _card());
      expect(find.text('HOLE 7 · THE NUMBERS'), findsOneWidget);
      expect(find.text('25¢ A POINT'), findsOneWidget);
      expect(find.text('45'), findsOneWidget);
      expect(find.text('57'), findsOneWidget);
      expect(find.text('net 4 · 5'), findsOneWidget);
      expect(find.text('Paul + Dave by'), findsOneWidget);
      expect(find.text('12 pts'), findsOneWidget);
    });

    testWidgets('a flip strikes the old number through', (t) async {
      await _pumpTray(t, _card(
        points: 30,
        sides: const [
          [1, 'Paul + Dave', [3, 5], 35, 35, false, false, 'won'],
          [2, 'Sam + Lee', [5, 6], 56, 65, true, false, 'lost'],
        ],
      ));
      expect(find.text('FLIPPED'), findsOneWidget);
      expect(find.text('65'), findsOneWidget);
      final old = t.widget<Text>(find.text('56'));
      expect(old.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('a 9 cap is named on the side it held', (t) async {
      await _pumpTray(t, _card(
        points: 4,
        sides: const [
          [1, 'Paul + Dave', [4, 5], 45, 45, false, false, 'won'],
          [2, 'Sam + Lee', [4, 10], 49, 49, false, true, 'lost'],
        ],
      ));
      expect(find.text('9 CAP'), findsOneWidget);
      expect(find.text('FLIPPED'), findsNothing);
    });

    testWidgets('a tie says what the next hole is worth', (t) async {
      await _pumpTray(t, _card(
        winner: 'halved', points: 0, tieNote: 'hole 8 doubles',
        sides: const [
          [1, 'Paul + Dave', [4, 6], 46, 46, false, false, 'tied'],
          [2, 'Sam + Lee', [4, 6], 46, 46, false, false, 'tied'],
        ],
        standing: const [
          [1, 'Paul + Dave', 0, 35, 8.75],
          [2, 'Sam + Lee', 0, -35, -8.75],
        ],
      ));
      expect(find.text('Tied · hole 8 doubles'), findsOneWidget);
      expect(find.text('0 pts'), findsOneWidget);
      // Level reads `0`, not `+0` — a gain that is not one.
      expect(find.text('0'), findsNWidgets(2));
      expect(find.text('+0'), findsNothing);
    });

    testWidgets('a carried hole says what it was worth', (t) async {
      await _pumpTray(t, _card(points: 24, note: '×2 carried'));
      expect(find.text('×2 CARRIED'), findsOneWidget);
      expect(find.text('25¢ A POINT'), findsNothing,
          reason: 'the note takes the slot on the hole it is true of');
    });

    testWidgets('the standing is two rows, the leader first', (t) async {
      await _pumpTray(t, _card());
      expect(find.text('EACH · NOW'), findsOneWidget);
      expect(find.text('+12'), findsOneWidget);
      expect(find.text('−12'), findsOneWidget);
      expect(find.text('+\$11.75'), findsOneWidget);
      expect(find.text('−\$11.75'), findsOneWidget);
      final a = t.getTopLeft(find.text('+12')).dy;
      final b = t.getTopLeft(find.text('−12')).dy;
      expect(a, lessThan(b));
    });

    testWidgets('the last hole finishes the round', (t) async {
      await _pumpTray(t, _card(
        points: 11, roundOver: true, nextHole: null,
        winnerBox: const {'side': 1, 'label': 'Paul + Dave', 'points': 98,
                          'money': 24.5, 'stake': 0.25, 'level': false},
      ));
      expect(find.text('Finish round ›'), findsOneWidget);
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('All 4 scores in'), findsOneWidget,
          reason: 'the header does not say it a second time');
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('Paul + Dave win by 98 pts'), findsOneWidget);
      expect(find.text('+\$24.50'), findsOneWidget);
      expect(find.text('each · 25¢ a point'), findsOneWidget);
    });

    testWidgets('level is not a win', (t) async {
      await _pumpTray(t, _card(
        winner: 'halved', points: 0, roundOver: true, nextHole: null,
        sides: const [
          [1, 'Paul + Dave', [4, 6], 46, 46, false, false, 'tied'],
          [2, 'Sam + Lee', [4, 6], 46, 46, false, false, 'tied'],
        ],
        standing: const [
          [1, 'Paul + Dave', 0, 0, 0.0],
          [2, 'Sam + Lee', 0, 0, 0.0],
        ],
        winnerBox: const {'side': 1, 'label': 'Paul + Dave', 'points': 0,
                          'money': 0.0, 'stake': 0.25, 'level': true},
      ));
      expect(find.text('All square — nobody owes anybody'),
          findsOneWidget);
      expect(find.textContaining('win by'), findsNothing);
    });

    testWidgets('it holds its figures back while the result is on its way',
        (t) async {
      await _pumpTray(t, _card(), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('45'), findsNothing);
      expect(find.text('+\$11.75'), findsNothing);
    });

    testWidgets('it survives a narrow phone', (t) async {
      await _pumpTray(t, _card());
      await t.binding.setSurfaceSize(const Size(320, 900));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('…and so does the round-over frame, with big figures',
        (t) async {
      // The winner line and its money share one row, and a Vegas round has
      // no ceiling: three points digits and a four-figure sum are both
      // reachable.
      await t.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: VegasHoleTray(
            card: _card(
              points: 48, roundOver: true, nextHole: null,
              standing: const [
                [1, 'Paul + Dave', 148, 1248, 312.0],
                [2, 'Sam + Lee', -148, -1248, -312.0],
              ],
              winnerBox: const {'side': 1, 'label': 'Paul + Dave',
                                'points': 1248, 'money': 312.0,
                                'stake': 0.25, 'level': false},
            ),
            onEdit: () {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      // Once in the winner box and once in the standing — they are the
      // same money and must not disagree.
      expect(find.text('+\$312'), findsNWidgets(2));
    });
  });

  group('the sides are one colour top to bottom', () {
    test('blue and orange, the app\'s own team colours', () {
      // `docs/color-standard.md`: green / red / grey mean win, loss and
      // neutral and are never a team. The packet draws pine and clay; the
      // golfer rows under these headers have been blue and orange since the
      // game shipped, and the header must match the rows it heads.
      expect(vegasSideColour(1), GameColors.team1);
      expect(vegasSideColour(2), GameColors.team2);
      expect(vegasSideColour(1, onDark: true), Halved.onDark3);
      expect(vegasSideColour(2, onDark: true), Halved.onDark2);
    });

    test('the tray blue is the readable one', () {
      // `onDark3` exists because the packets' pale blue-grey is
      // indistinguishable from the tray's own label grey.
      expect(Halved.onDark3, const Color(0xFF8FB4FF));
    });
  });

  group('the shared screen keeps doing its job', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('Vegas enters on the keypad', () {
      expect(src, contains('primary == GameIds.vegas'));
    });

    test('a tray game posts and STAYS', () {
      // Auto-advance would carry the scorer straight past the tray.
      final at = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      final body = src.substring(at, src.indexOf(';', at));
      expect(body, contains('_vegasCard(rp)'));
    });

    test('the pager hides under the tray', () {
      // The tray IS the bottom bar while it is up, so its own arrows are the
      // only ones on screen — which is what lets the forward button finish
      // the round on the last hole.
      expect(src, contains('if (!sixTray && !spTray && !vgTray)'));
    });

    test('the card is fetched for the hole on screen', () {
      // Without one the keypad is not drawn at all.
      expect(src, contains('_ensureVegasCard(rp);'));
      expect(src, contains('loadVegasHole(widget.foursomeId, _selectedHole)'));
    });

    test('the side headers ride the slot Annandale already uses', () {
      expect(src, contains('VegasSideHeader(side:'));
      expect(src, contains('vegasHole: _vegasCard(rp)'));
    });

    test('the keypad is the only picker while it is up', () {
      // `useKeypad` already suppresses the inline one, and `_keypadRound`
      // now answers true for Vegas.
      expect(src, contains('useKeypad: _keypadRound(rp) &&'));
    });
  });
}
