import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/nassau_board_model.dart';
import 'package:golf_mobile/widgets/dashed_border.dart';
import 'package:golf_mobile/widgets/nassau_board.dart';

Map<String, dynamic> _bet({
  String? result, int margin = 0, int holesPlayed = 0,
  int? decidedMargin, int? decidedRemaining,
}) => {
      'result': result, 'margin': margin, 'holes_played': holesPlayed,
      'decided_margin': decidedMargin, 'decided_remaining': decidedRemaining,
    };

NassauSummary _nassau({
  Map<String, dynamic>? front,
  Map<String, dynamic>? back,
  Map<String, dynamic>? overall,
  List<Map<String, dynamic>> presses = const [],
  List<Map<String, dynamic>> holes = const [],
  String variant = 'none',
  bool single = false,
  Map<String, dynamic>? payouts,
  Map<String, dynamic>? bottomFront,
  Map<String, dynamic>? bottomOverall,
}) =>
    NassauSummary.fromJson({
      'status': 'in_progress',
      'variant': variant,
      'single_match': single,
      'bet_unit': 10.0,
      'press_unit': 5.0,
      'teams': {
        'team1': [
          {'player_id': 1, 'name': 'Paul L', 'short_name': 'Paul'},
          {'player_id': 2, 'name': 'Mike N', 'short_name': 'Mike'},
        ],
        'team2': [
          {'player_id': 3, 'name': 'Dave M', 'short_name': 'Dave'},
          {'player_id': 4, 'name': 'Sam R', 'short_name': 'Sam'},
        ],
      },
      'front9': front ?? _bet(),
      'back9': back ?? _bet(),
      'overall': overall ?? _bet(),
      'presses': presses,
      'bottom_front9': bottomFront,
      'bottom_overall': bottomOverall,
      'bottom_presses': const [],
      'holes': holes,
      'payouts': payouts ?? {'total': 0.0, 'total_capped': 0.0},
    });

Future<void> _pump(WidgetTester t, NassauBoardData d) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: NassauBoard(data: d))),
      ),
    );

void main() {
  _notStartedTests();

  group('claremont balls', () {
    /// Reported 28 Oct 2026: *"I think I selected Claremont on the
    /// leaderboard, but I don't see the bottom row with the high and low
    /// balls."* The points line was there; the balls it is made of were not.
    Map<String, dynamic> hole(int h, int t1, int t1b, int t2, int t2b,
            int delta) =>
        {
          'hole': h, 'winner': t1 < t2 ? 'team1' : (t2 < t1 ? 'team2' : 'halved'),
          't1_net': t1, 't1_2nd_net': t1b,
          't2_net': t2, 't2_2nd_net': t2b, 'bottom_delta': delta,
        };

    NassauBoardData claremont() => NassauBoardData.fromSummary(_nassau(
          variant: 'claremont',
          front: _bet(margin: 1, holesPlayed: 1),
          overall: _bet(margin: 1, holesPlayed: 1),
          bottomFront: _bet(margin: 1, holesPlayed: 1),
          bottomOverall: _bet(margin: 1, holesPlayed: 1),
          holes: [hole(1, 4, 6, 5, 5, 0)],
        ));

    testWidgets('the block is drawn, labelled with what the numbers are',
        (t) async {
      await _pump(t, claremont());
      // Without the label `4/5` is two numbers nobody can decode.
      expect(find.text('BALLS · LOW / 2ND'), findsWidgets);
    });

    testWidgets('both sides\' balls are drawn for a played hole', (t) async {
      await _pump(t, claremont());
      // Text.rich, so the whole run is one widget: `4` `/` `6`.
      expect(find.textContaining('4', findRichText: true), findsWidgets);
      expect(find.textContaining('6', findRichText: true), findsWidgets);
    });

    testWidgets('a standard Nassau draws no balls block at all', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
        front: _bet(margin: 1, holesPlayed: 1),
        holes: [hole(1, 4, 6, 5, 5, 0)],
      )));
      expect(find.text('BALLS · LOW / 2ND'), findsNothing);
    });

    testWidgets('the Points line still reads above it', (t) async {
      await _pump(t, claremont());
      expect(find.text('Points'), findsWidgets);
    });
  });

  group('the sides', () {
    testWidgets('named from short names, with vs between', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau()));
      expect(find.text('Paul & Mike'), findsOneWidget);
      expect(find.text('Dave & Sam'), findsOneWidget);
      expect(find.text('vs'), findsOneWidget);
    });

    testWidgets('hidden where the screen already names the match', (t) async {
      await _pump(t,
          NassauBoardData.fromSummary(_nassau(), showSides: false));
      expect(find.text('vs'), findsNothing);
    });
  });

  group('a nine', () {
    testWidgets('a live nine reads N UP and thru', (t) async {
      await _pump(t, NassauBoardData.fromSummary(
          _nassau(front: _bet(margin: 3, holesPlayed: 7))));
      expect(find.text('Front'), findsOneWidget);
      expect(find.text('3 UP'), findsOneWidget);
      expect(find.text('thru 7'), findsOneWidget);
    });

    testWidgets('a nine that has not started says starts 10', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau()));
      expect(find.text('starts 10'), findsOneWidget);
    });

    testWidgets('a close-out reads N&M · Final', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'team1', margin: 3, holesPlayed: 7,
                      decidedMargin: 3, decidedRemaining: 2))));
      expect(find.text('3&2'), findsOneWidget);
      expect(find.text('Final'), findsWidgets);
    });

    testWidgets('a level finish reads Push', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'halved', margin: 0, holesPlayed: 9))));
      expect(find.text('AS'), findsWidgets);
      expect(find.text('Push'), findsOneWidget);
    });

    testWidgets('a single match draws ONE card over both nines', (t) async {
      await _pump(t, NassauBoardData.fromSummary(
          _nassau(single: true, overall: _bet(margin: 2, holesPlayed: 12))));
      expect(find.text('Match'), findsOneWidget);
      expect(find.text('Front'), findsNothing);
      expect(find.text('Back'), findsNothing);
    });
  });

  group('presses', () {
    testWidgets('a press names its holes and its status', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(presses: [
        {'nine': 'front', 'press_type': 'auto', 'start_hole': 3,
         'end_hole': 9, 'result': 'team1', 'margin': 2,
         'holes_remaining': 1},
      ])));
      expect(find.text('Press 3–9'), findsOneWidget);
      expect(find.text('2&1 · Final'), findsOneWidget);
    });

    testWidgets('a back-nine press draws on the BACK card only', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(presses: [
        {'nine': 'back', 'press_type': 'manual', 'start_hole': 12,
         'end_hole': 18, 'result': null, 'margin': 0,
         'holes_remaining': 0},
      ])));
      expect(find.text('Press 12–18'), findsOneWidget);
    });
  });

  group('the money card', () {
    testWidgets('names the side that is UP, each, and the terms', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
          overall: _bet(margin: 3, holesPlayed: 12),
          payouts: {'total': 43.0, 'total_capped': 43.0, 'loss_cap': 200.0})));
      expect(find.text('Paul & Mike, each · now'), findsOneWidget);
      expect(find.text('+\$43'), findsOneWidget);
      expect(find.text('Overall · thru 12'), findsOneWidget);
      expect(find.text('Bet \$10', findRichText: true), findsOneWidget);
      expect(find.text('Press \$5', findRichText: true), findsOneWidget);
      expect(find.text('Cap \$200', findRichText: true), findsOneWidget);
    });

    testWidgets('level money says All square, not \$0 for somebody',
        (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau()));
      expect(find.text('All square · now'), findsOneWidget);
      expect(find.text('\$0'), findsOneWidget);
    });

    testWidgets('a cup tab hides the money entirely', (t) async {
      await _pump(t, NassauBoardData.fromSummary(
          _nassau(overall: _bet(margin: 2, holesPlayed: 9)), noMoney: true));
      expect(find.textContaining('each'), findsNothing);
      expect(find.text('Bet \$10', findRichText: true), findsNothing);
      // ...but the match is still reported.
      expect(find.textContaining('Overall'), findsOneWidget);
    });

    testWidgets('a finished match says won rather than now', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
          front: _bet(result: 'team1', margin: 2, holesPlayed: 9),
          back: _bet(result: 'team1', margin: 1, holesPlayed: 9),
          overall: _bet(result: 'team1', margin: 3, holesPlayed: 18),
          payouts: {'total': 30.0, 'total_capped': 30.0})));
      expect(find.text('Paul & Mike won, each'), findsOneWidget);
    });
  });

  group('Claremont', () {
    testWidgets('the points row sits under the tiles', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
          variant: 'claremont',
          front: _bet(result: 'team1', margin: 3, holesPlayed: 9,
                      decidedMargin: 3, decidedRemaining: 2),
          bottomFront: {'result': 'team1', 'margin': 6, 'holes_played': 9},
          bottomOverall: {'result': null, 'margin': 4, 'holes_played': 12},
          payouts: {'total': 43.0, 'total_capped': 43.0})));
      expect(find.text('Points'), findsOneWidget);
      expect(find.text('+6'), findsOneWidget);
      expect(find.text('Points overall'), findsOneWidget);
      expect(find.text('+4'), findsOneWidget);
    });

    testWidgets('a decided bottom bet says how many holes were left',
        (t) async {
      // Two points a hole: +6 with 2 to play cannot be caught.
      //
      // The top front bet carries the same holes played: the two bets share
      // the HOLES, so a bottom bet seven holes in on a nine that has not
      // started is not a state the engine can produce — and since a
      // not-started nine now draws as absent, a fixture saying both would
      // be testing a screen nobody can reach.
      await _pump(t, NassauBoardData.fromSummary(_nassau(
          variant: 'claremont',
          front: _bet(margin: 3, holesPlayed: 7),
          bottomFront: {'result': null, 'margin': 6, 'holes_played': 7,
                        'decided_margin': 6, 'decided_remaining': 2},
          payouts: {'total': 10.0, 'total_capped': 10.0})));
      expect(find.text('Final · 2 to play'), findsOneWidget);
    });

    testWidgets('a plain Nassau shows no points rows', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau()));
      expect(find.text('Points'), findsNothing);
      expect(find.text('Points overall'), findsNothing);
    });
  });

  group('there is only one Nassau table', () {
    test('the leaderboard renders NassauBoard', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect(src.contains('NassauBoard('), isTrue,
          reason: 'the Nassau tab must use the one board');
    });
  });
}

/// A nine that has not started draws as ABSENT (Design, 28 Oct 2026):
/// dashed card, no fill, dashed tiles, and no Claremont ball rows — the
/// empty 2x9 grid was the tallest thing on the screen and said nothing.
void _notStartedTests() {
  group('a nine that has not started', () {
    testWidgets('says when it starts and draws no balls', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
        variant: 'claremont',
        front: _bet(margin: 2, holesPlayed: 4),
        bottomFront: {'result': null, 'margin': 2, 'holes_played': 4},
        bottomOverall: {'result': null, 'margin': 2, 'holes_played': 4},
        holes: [
          for (var h = 1; h <= 4; h++)
            {'hole': h, 'winner': 'team1', 't1_net': 4, 't1_2nd_net': 5,
             't2_net': 5, 't2_2nd_net': 5, 'bottom_delta': 2},
        ],
      )));
      expect(find.text('starts 10'), findsOneWidget);
      // The front nine is under way, so ONE balls block is drawn — the back
      // nine's is withheld rather than drawn empty.
      expect(find.text('BALLS · LOW / 2ND'), findsOneWidget);
    });

    testWidgets('both nines waiting draws no balls at all', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
        variant: 'claremont',
        bottomFront: {'result': null, 'margin': 0, 'holes_played': 0},
      )));
      expect(find.text('BALLS · LOW / 2ND'), findsNothing);
    });

    testWidgets('it is dashed, and a live nine is not', (t) async {
      await _pump(t, NassauBoardData.fromSummary(_nassau(
        front: _bet(margin: 1, holesPlayed: 3),
      )));
      // One dashed frame per waiting element: the back nine's card plus its
      // nine tiles. The live front nine contributes none.
      final dashed = t.widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((w) => w.painter is DashedRRect)
          .length;
      expect(dashed, 10);
    });
  });
}
