// The solo card — the hole line, the chips and the Won row.
//
// `handoff-solo-games`. One golfer, and the opponent is par: the three pieces
// here are the whole read-out, and the two things easy to get wrong are the
// perspective (every reading is from the GOLFER's side, because par has no
// side to read from) and the Won row's two chips, which are both the letter
// P and are told apart by colour alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/widgets/solo_board.dart';

Map<String, dynamic> _hole(int n,
        {int par = 4, int? gross, int strokes = 0, String? result}) =>
    {
      'hole': n,
      'par': par,
      'stroke_index': n,
      'gross': gross,
      'strokes': strokes,
      'net': gross == null ? null : gross - strokes,
      'to_par': gross == null ? null : gross - strokes - par,
      'result': result,
    };

Map<String, dynamic> _solo(String variant,
        {List<Map<String, dynamic>>? holes, Map<String, dynamic>? reading}) =>
    {
      'configured': true,
      'variant': variant,
      'net_percent': 100,
      'player_id': 7,
      'player_name': 'Paul',
      'holes': holes ?? [for (var n = 1; n <= 18; n++) _hole(n)],
      'stroke': {'to_par': 0, 'net_total': 0, 'thru': 0},
      'for_fun': true,
      if (variant == 'nassau')
        'nassau': reading ??
            {
              'auto_press': false,
              'front': {'up': 0, 'decided': null, 'thru': 0, 'holes': 9,
                        'presses': []},
              'back': {'up': 0, 'decided': null, 'thru': 0, 'holes': 9,
                       'presses': []},
              'overall': {'up': 0, 'decided': null, 'thru': 0, 'holes': 18,
                          'presses': []},
            },
      if (variant == 'match')
        'match': reading ??
            {'up': 0, 'decided': null, 'thru': 0, 'to_play': 18},
    };

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));

void main() {
  group('which variant a round is', () {
    test('each solo game names itself', () {
      expect(soloVariantOf([GameIds.soloStroke]), 'stroke');
      expect(soloVariantOf([GameIds.soloNassau]), 'nassau');
      expect(soloVariantOf([GameIds.soloMatch]), 'match');
    });

    test('a round that is not solo is null', () {
      // Score entry asks this of EVERY round, so a default would put a
      // vs-par board on every skins game in the app.
      expect(soloVariantOf(['skins', 'stableford']), isNull);
    });
  });

  group('the margin reads from the golfer', () {
    test('up, down and level', () {
      expect(soloUpLabel(0), 'AS');
      expect(soloUpLabel(2), '2 UP');
      expect(soloUpLabel(-3), '3 DN');
    });
  });

  group('the hole line', () {
    test('stroke play names the score and the par', () {
      // The handoff's own example.
      expect(soloHoleLine(_hole(3, par: 3, gross: 3, result: 'halved'),
              'stroke'),
          'Par on a par 3.');
      expect(soloHoleLine(_hole(1, gross: 3, result: 'won'), 'stroke'),
          'Birdie on a par 4.');
    });

    test('a match game says what the score DID', () {
      // Two sentences, because in these two the second one is the game and
      // the first is only how it was arrived at.
      expect(soloHoleLine(_hole(1, gross: 4, result: 'halved'), 'match'),
          'Par. Hole halved.');
      expect(soloHoleLine(_hole(1, gross: 3, result: 'won'), 'nassau'),
          'Birdie. Hole won.');
      expect(soloHoleLine(_hole(1, gross: 5, result: 'lost'), 'match'),
          'Bogey. Hole lost.');
    });

    test('a stroke is in the net it reads', () {
      // Gross 5 with a stroke is a net par, so the line says Par — the whole
      // reason the allowance exists.
      expect(soloHoleLine(_hole(1, gross: 5, strokes: 1, result: 'halved'),
              'match'),
          'Par. Hole halved.');
    });

    test('an unplayed hole says nothing', () {
      expect(soloHoleLine(_hole(7), 'match'), isNull);
      expect(soloHoleLine(null, 'stroke'), isNull);
    });
  });

  group('the status chips', () {
    testWidgets('stroke play shows the net and how far through', (t) async {
      await _pump(t, SoloStatusBar(solo: _solo('stroke')));
      expect(find.text('Net'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);   // never "EVEN", never "+0"
      expect(find.text('Thru'), findsOneWidget);
    });

    testWidgets('match play shows the match AND what is left', (t) async {
      // A margin with no holes remaining cannot be read: 3 up is a win on
      // the 16th and nothing on the 4th.
      await _pump(
          t,
          SoloStatusBar(
              solo: _solo('match',
                  reading: {'up': 3, 'decided': null, 'thru': 6,
                            'to_play': 12})));
      expect(find.text('3 UP'), findsOneWidget);
      expect(find.text('To play'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('a decided match shows its closing score', (t) async {
      await _pump(
          t,
          SoloStatusBar(
              solo: _solo('match',
                  reading: {'up': 6, 'decided': '6&5', 'thru': 13,
                            'to_play': 5})));
      expect(find.text('6&5'), findsOneWidget);
      expect(find.text('6 UP'), findsNothing);
    });

    testWidgets('nassau shows all three', (t) async {
      await _pump(t, SoloStatusBar(solo: _solo('nassau')));
      for (final c in ['F9', 'B9', 'ALL']) {
        expect(find.text(c), findsOneWidget);
      }
    });

    testWidgets('a press gets its own chip', (t) async {
      await _pump(
          t,
          SoloStatusBar(
              solo: _solo('nassau', reading: {
            'auto_press': true,
            'front': {
              'up': -2, 'decided': null, 'thru': 2, 'holes': 9,
              'presses': [
                {'index': 1, 'trigger_hole': 2, 'start': 3, 'end': 9,
                 'holes': 7, 'up': 1, 'decided': null, 'thru': 1},
              ],
            },
            'back': {'up': 0, 'decided': null, 'thru': 0, 'holes': 9,
                     'presses': []},
            'overall': {'up': -2, 'decided': null, 'thru': 2, 'holes': 18,
                        'presses': []},
          })));
      expect(find.text('F9 Press 1'), findsOneWidget);
      expect(find.text('1 UP'), findsOneWidget);   // the press, from his side
      expect(find.text('2 DN'), findsNWidgets(2)); // the nine, and the overall
    });
  });

  group('the golfer\'s mark', () {
    // The handoff draws `P` against `P` and explains it as "Paul / Par" —
    // which reads as a rule about the letter and is really a fact about that
    // golfer. Dave gets a D.
    test('it is the first letter of his own name', () {
      expect(soloGolferMark('Dave Moran'), 'D');
      expect(soloGolferMark('ben'), 'B');
    });

    test('a golfer called Paul still collides with par, and that is fine', () {
      expect(soloGolferMark('Paul'), 'P');
    });

    test('an unnamed golfer is You', () {
      // Which is what the setup screen calls him.
      expect(soloGolferMark(null), 'Y');
      expect(soloGolferMark('  '), 'Y');
    });
  });

  group('the Won row', () {
    testWidgets('a match game marks who took each hole', (t) async {
      await _pump(
          t,
          SoloScorecard(
              solo: _solo('match', holes: [
            _hole(1, gross: 3, result: 'won'),
            _hole(2, gross: 6, result: 'lost'),
            _hole(3, gross: 4, result: 'halved'),
            for (var n = 4; n <= 18; n++) _hole(n),
          ])));
      expect(find.text('Won'), findsOneWidget);
      // The golfer's own initial where he won, par's P where it did — and
      // this fixture's golfer is Paul, the collision the handoff draws, so
      // both chips read P and only the colours separate them. A halved hole
      // is blank: "AS" would be a third mark for the thing that happens on
      // most holes.
      expect(find.text('P'), findsNWidgets(2));
    });

    testWidgets('a golfer who is not a P gets his own letter', (t) async {
      await _pump(
          t,
          SoloScorecard(
              solo: {
                ..._solo('nassau', holes: [
                  _hole(1, gross: 3, result: 'won'),
                  _hole(2, gross: 6, result: 'lost'),
                ]),
                'player_name': 'Dave',
              }));
      expect(find.text('D'), findsOneWidget);
      expect(find.text('P'), findsOneWidget);
    });

    testWidgets('stroke play has no Won row', (t) async {
      // There are no holes to win in it.
      await _pump(
          t,
          SoloScorecard(
              solo: _solo('stroke',
                  holes: [_hole(1, gross: 3, result: 'won')])));
      expect(find.text('Won'), findsNothing);
      expect(find.text('P'), findsNothing);
    });

    testWidgets('the two chips carry the two sides\' colours', (t) async {
      await _pump(
          t,
          SoloScorecard(
              solo: {
                ..._solo('nassau', holes: [
                  _hole(1, gross: 3, result: 'won'),
                  _hole(2, gross: 6, result: 'lost'),
                ]),
                'player_name': 'Paul',
              }));
      // Paul's initial IS par's, so this pair is the hardest case — and the
      // colours are what carry it.
      final colours = t
          .widgetList<Text>(find.text('P'))
          .map((w) => w.style?.color)
          .toList();
      expect(colours, containsAll(<Color>[soloGolfer, soloPar]));
    });
  });
}
