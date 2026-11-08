import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/fourball_entry.dart';
import 'package:golf_mobile/widgets/forty_balls_keypad.dart';

/// Fourball score entry — `~/Downloads/handoff-fourball-score-entry`.
///
/// The engine is covered in `scoring/tests/test_fourball_hole_card.py`;
/// these are about what the side header and the tray DRAW, and the source
/// guards are about what the shared score-entry screen has to keep doing.

Map<String, dynamic> _json({
  String kind = 'best ball',
  double stake = 20,
  int scored = 4,
  bool countsForCard = false,
  bool closedOut = false,
  int? finishedOnHole,
  Map<String, dynamic>? match,
  List<List<dynamic>>? sides,
  List<Map<String, dynamic>>? money,
  List<Map<String, dynamic>>? strip,
  int? nextHole = 6,
  List<int?> gross = const [4, 5, 5, 5],
}) =>
    <String, dynamic>{
      'hole': 5, 'par': 4, 'stroke_index': 7, 'yards': 388,
      'nine': 'front nine', 'thru': 5, 'stake': stake,
      'kind': kind,
      'players': [
        for (final p in [
          [1, 'Paul Lipkin', 'PL', 'Paul', 12, 0, gross[0], gross[0], 1, true],
          [2, 'Larry Sanders', 'LS', 'Larry', 14, 1,
           gross[1], gross[1] == null ? null : gross[1]! - 1, 1, true],
          [3, 'Jim Diederich', 'JD', 'Jim', 10, 0, gross[2], gross[2], 2, true],
          [4, 'Ryan Lipkin', 'RL', 'Ryan', 6, 0, gross[3], gross[3], 2, false],
        ])
          {'player_id': p[0], 'name': p[1], 'short': p[2], 'first': p[3],
           'course_handicap': p[4], 'strokes': p[5], 'gross': p[6],
           'net': p[7], 'side': p[8],
           'counted': countsForCard ? false : p[9]},
      ],
      'sides': [
        for (final s in sides ??
            const [
              [1, 'Paul + Larry', 4, 'counts: Paul · Larry', 'won'],
              [2, 'Jim + Ryan', 5, 'counts: Jim · Ryan', 'lost'],
            ])
          {'side': s[0], 'label': s[1],
           'player_ids': s[0] == 1 ? [1, 2] : [3, 4],
           'best': s[2], 'sub': s[3], 'result': s[4]},
      ],
      'scored': scored,
      'hole_complete': scored == 4,
      'counts_for_card': countsForCard,
      'closed_out': closedOut,
      'finished_on_hole': finishedOnHole,
      'match': match ??
          const {'leader': 1, 'margin': 1, 'headline': 'Paul + Larry',
                 'figure': '1 UP', 'line': 'thru 5 · 13 to play',
                 'state': 'Paul + Larry 1 UP', 'is_final': false},
      'strip': strip ??
          [
            for (var h = 1; h <= 9; h++)
              {'hole': h, 'played': h <= 5,
               'result': h == 5 ? 'T1' : (h <= 4 ? 'Halved' : null),
               'dead': false},
          ],
      'money': money ??
          (stake > 0
              ? [
                  {'side': 1, 'label': 'Paul + Larry', 'amount': stake},
                  {'side': 2, 'label': 'Jim + Ryan', 'amount': -stake},
                ]
              : <Map<String, dynamic>>[]),
      'round_over': nextHole == null,
      'next_hole': nextHole,
    };

FourballHoleCard _card({
  String kind = 'best ball',
  double stake = 20,
  int scored = 4,
  bool countsForCard = false,
  bool closedOut = false,
  int? finishedOnHole,
  Map<String, dynamic>? match,
  List<List<dynamic>>? sides,
  List<Map<String, dynamic>>? strip,
  int? nextHole = 6,
  List<int?> gross = const [4, 5, 5, 5],
}) =>
    FourballHoleCard.fromJson(_json(
      kind: kind, stake: stake, scored: scored, countsForCard: countsForCard,
      closedOut: closedOut, finishedOnHole: finishedOnHole, match: match,
      sides: sides, strip: strip, nextHole: nextHole, gross: gross,
    ));

Future<void> _pump(WidgetTester t, FourballHoleCard card,
    {VoidCallback? onFinishNow, bool gettingResult = false}) async {
  await t.binding.setSurfaceSize(const Size(390, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: FourballHoleTray(
        card: card,
        onEdit: () {},
        onNext: () {},
        onPrev: () {},
        onFinishNow: onFinishNow,
        gettingResult: gettingResult,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// The rendered width of a keypad key, measured on the `Material` the key
/// is built from — the `Expanded` above it has no box of its own.
double _keyWidth(WidgetTester t, String label) => t.getSize(find.ancestor(
      of: find.text(label), matching: find.byType(Material)).first).width;

void main() {
  group('the side header', () {
    testWidgets('it carries the side\'s best ball', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = _card();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            FourballSideHeader(side: c.sides[0]),
            FourballSideHeader(side: c.sides[1]),
          ]),
        ),
      ));
      expect(find.text('PAUL + LARRY'), findsOneWidget);
      expect(find.text('BEST'), findsNWidgets(2));
      expect(find.text('4'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('an unfinished side reads a dash', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = _card(sides: const [
        [1, 'Paul + Larry', null, '', null],
        [2, 'Jim + Ryan', 5, 'counts: Jim', null],
      ]);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: FourballSideHeader(side: c.sides[0])),
      ));
      expect(find.text('–'), findsOneWidget);
    });
  });

  group('the tray', () {
    testWidgets('best ball names whose ball counted', (t) async {
      await _pump(t, _card());
      expect(find.text('HOLE 5 · BEST BALL'), findsOneWidget);
      expect(find.text('\$20 A GOLFER'), findsOneWidget);
      expect(find.text('counts: Paul · Larry'), findsOneWidget);
      expect(find.text('won'), findsOneWidget);
      expect(find.text('lost'), findsOneWidget);
    });

    testWidgets('no stakes says so and draws no money', (t) async {
      await _pump(t, _card(stake: 0));
      expect(find.text('NO STAKES'), findsOneWidget);
      expect(find.text('EACH · NOW'), findsNothing);
      expect(find.text('MONEY'), findsNothing);
    });

    testWidgets('the match card and the nine strip', (t) async {
      await _pump(t, _card());
      expect(find.text('Paul + Larry'), findsWidgets);
      expect(find.text('1 UP'), findsOneWidget);
      expect(find.text('thru 5 · 13 to play'), findsOneWidget);
      // Nine tiles, numbered.
      for (var h = 1; h <= 9; h++) {
        expect(find.text('$h'), findsWidgets, reason: 'tile $h');
      }
    });

    testWidgets('money is two rows, the leading side first', (t) async {
      await _pump(t, _card());
      expect(find.text('EACH · NOW'), findsOneWidget);
      expect(find.text('+\$20'), findsOneWidget);
      expect(find.text('−\$20'), findsOneWidget);
      final a = t.getTopLeft(find.text('+\$20')).dy;
      final b = t.getTopLeft(find.text('−\$20')).dy;
      expect(a, lessThan(b));
    });

    testWidgets('a close-out offers play on AND a way out', (t) async {
      var finished = 0;
      await _pump(
        t,
        _card(closedOut: true, finishedOnHole: 16, nextHole: 17,
              match: const {
                'leader': 1, 'margin': 3, 'headline': 'Paul + Larry win',
                'figure': '3&2',
                'line': 'Closed out on 16. Holes 17–18 don’t count.',
                'state': 'Paul + Larry win 3&2', 'is_final': true}),
        onFinishNow: () => finished++,
      );
      expect(find.text('Hole 17 · play on ›'), findsOneWidget);
      expect(find.text('3&2'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      await t.tap(find.text('Finish round now'));
      expect(finished, 1);
    });

    testWidgets('a hole past the close-out is for the card only', (t) async {
      await _pump(t, _card(
        countsForCard: true, closedOut: true, finishedOnHole: 16,
        scored: 3, nextHole: 18, gross: const [5, null, 4, 5],
        match: const {
          'leader': 1, 'margin': 3, 'headline': 'Paul + Larry won',
          'figure': '3&2',
          'line': 'Closed out on 16. Scores here go on the card only.',
          'state': 'Paul + Larry won 3&2', 'is_final': true},
      ));
      expect(find.text('HOLE 5 · FOR THE CARD'), findsOneWidget);
      expect(find.text('MATCH OVER'), findsOneWidget);
      // Golfers, not sides.
      expect(find.text('Paul Lipkin'), findsOneWidget);
      expect(find.text('Larry Sanders'), findsOneWidget);
      expect(find.text('no score'), findsOneWidget);
      expect(find.text('counts: Paul · Larry'), findsNothing);
    });

    testWidgets('3 of 4 scored is not a failure state', (t) async {
      await _pump(t, _card(countsForCard: true, scored: 3,
                           gross: const [5, null, 4, 5]));
      expect(find.text('3 of 4 scored'), findsOneWidget);
      expect(find.text('All 4 scores in'), findsNothing);
    });

    testWidgets('the last hole finishes the round', (t) async {
      await _pump(t, _card(
        nextHole: null,
        match: const {'leader': 1, 'margin': 1,
                      'headline': 'Paul + Larry win', 'figure': '1 UP',
                      'line': 'Final after 18',
                      'state': 'Paul + Larry 1 UP', 'is_final': true},
      ));
      expect(find.text('Finish round ›'), findsOneWidget);
      expect(find.text('Final after 18'), findsOneWidget);
      expect(find.text('Finish round now'), findsNothing,
          reason: 'the pill already finishes it');
    });

    testWidgets('a level 18 is a push', (t) async {
      await _pump(t, _card(
        nextHole: null,
        match: const {'leader': null, 'margin': 0,
                      'headline': 'Match halved', 'figure': 'AS',
                      'line': 'Level after 18 · a push',
                      'state': 'All square', 'is_final': true},
        strip: const [],
      ));
      expect(find.text('Match halved'), findsOneWidget);
      expect(find.text('AS'), findsOneWidget);
    });

    testWidgets('it holds its figures back while the result is on its way',
        (t) async {
      await _pump(t, _card(), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('1 UP'), findsNothing);
      expect(find.text('+\$20'), findsNothing);
    });

    testWidgets('it survives a narrow phone', (t) async {
      await _pump(t, _card());
      await t.binding.setSurfaceSize(const Size(320, 900));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('the keypad grows a No score key, and only here', () {
    testWidgets('three equal keys when it is offered', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => t.binding.setSurfaceSize(null));
      var marked = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FortyBallsKeypad(
            playerName: 'Larry Sanders', par: 4, strokes: 0,
            onScore: (_) {}, onClear: () {},
            onNoScore: () => marked++,
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('No score'), findsOneWidget);
      expect(_keyWidth(t, '10+'), closeTo(_keyWidth(t, 'Clear'), 1));
      expect(_keyWidth(t, 'No score'), closeTo(_keyWidth(t, '10+'), 1));
      await t.tap(find.text('No score'));
      expect(marked, 1);
    });

    testWidgets('and nowhere else', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FortyBallsKeypad(
            playerName: 'Larry Sanders', par: 4, strokes: 0,
            onScore: (_) {}, onClear: () {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('No score'), findsNothing);
      // `Clear` keeps its double width, so the two destructive-ish keys are
      // never adjacent at the same size.
      expect(_keyWidth(t, 'Clear'),
          greaterThan(_keyWidth(t, '10+') * 1.5));
    });
  });

  group('the shared screen keeps doing its job', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('Fourball enters on the keypad', () {
      expect(src, contains('primary == GameIds.fourball'));
    });

    test('a tray game posts and STAYS', () {
      final at = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      final body = src.substring(at, src.indexOf(';', at));
      expect(body, contains('_fourballCard(rp)'));
    });

    test('the hole posts itself once it is complete', () {
      // See `mobile/test/auto_post_test.dart` for the decision and the race
      // it closes; this only checks the screen asks it, with the Fourball
      // carve-out for a golfer who picked up.
      final at = src.indexOf('void _ensureHolePosted(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('\n  }', at));
      expect(body, contains('shouldAutoPost('));
      expect(body, contains('_holeReady('));
      expect(body, contains('_saveCurrentHole('));
    });

    test('the pager hides under the tray', () {
      expect(src, contains('if (!sixTray && !spTray && !vgTray && !fourTray)'));
    });

    test('the card is fetched for the hole on screen', () {
      expect(src, contains('_ensureFourballCard(rp);'));
      expect(src,
          contains('loadFourballHole(widget.foursomeId, _selectedHole)'));
    });

    test('the side headers are hidden past the close-out', () {
      // There is no team score for a ball to be the best of.
      expect(src, contains('(_fourballCard(rp)?.countsForCard ?? true)'));
    });

    test('No score is offered only past a close-out', () {
      final at = src.indexOf('onNoScore :');
      expect(at, greaterThan(0));
      final line = src.substring(at, src.indexOf('onScore   :', at));
      expect(line, contains('countsForCard'));
    });

    test('a digit or Clear takes a pick-up mark off', () {
      // The only way back for a golfer marked by mistake.
      for (final key in ['onScore   : (n) {', 'onClear   : () {']) {
        final at = src.indexOf(key);
        expect(at, greaterThan(0), reason: key);
        final body = src.substring(at, at + 400);
        expect(body, contains('_noScore[_selectedHole]?.remove'),
            reason: key);
      }
    });
  });
}
