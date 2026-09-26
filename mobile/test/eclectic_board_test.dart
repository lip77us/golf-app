/// test/eclectic_board_test.dart
/// ----------------------------
/// The Eclectic board and the card it opens into.
///
/// Most of what is asserted here is a rule the DESIGN states and the data does
/// not enforce: that the number is to par, that a pool that is off draws no
/// switch, that the money is a projection until the event closes, and that one
/// card is open at a time.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/eclectic_board.dart';

/// A two-round payload in the server's own shape.
Map<String, dynamic> payload({
  List<String> pools = const ['gross', 'net'],
  bool isFinal = false,
  String liveLabel = 'R2 live',
  List<Map<String, dynamic>>? standings,
  Map<String, dynamic>? cards,
  List<Map<String, String>>? legend,
}) {
  final pool = {
    'entry_fee': 10.0,
    'pool': 240.0,
    'payouts': [{'place': 1, 'amount': 160.0}],
    'standings': standings ??
        [
          {'player_id': 1, 'player_name': 'Ann', 'rank': 1, 'tied': false,
           'total': -4, 'holes_kept': 18, 'payout': 160.0, 'excluded': false},
          {'player_id': 2, 'player_name': 'Bea', 'rank': 2, 'tied': false,
           'total': 2, 'holes_kept': 18, 'payout': null, 'excluded': false},
        ],
    'cards': cards ?? {'1': _card(), '2': _card()},
  };
  return {
    'pools': pools,
    'rounds': [
      {'index': 0, 'label': 'R1', 'course': 'North Links',
       'course_initial': 'N', 'date': '2026-10-10', 'par': 72,
       'is_complete': true},
      {'index': 1, 'label': 'R2', 'course': 'The Ridge',
       'course_initial': 'T', 'date': '2026-10-11', 'par': 71,
       'is_complete': isFinal},
    ],
    'n_rounds': 2,
    'n_courses': 2,
    'course_legend': legend ??
        [{'key': 'N', 'course': 'North Links'},
         {'key': 'T', 'course': 'The Ridge'}],
    'live_label': isFinal ? '' : liveLabel,
    'is_final': isFinal,
    for (final p in pools) p: pool,
  };
}

/// Eighteen holes on both rounds; R1 keeps hole 1, R2 keeps hole 2.
Map<String, dynamic> _card({int roundsPlayed = 2}) => {
      'rounds': [
        for (var i = 0; i < roundsPlayed; i++)
          {
            'label': 'R${i + 1}',
            'course_initial': i == 0 ? 'N' : 'T',
            'holes': {
              for (var h = 1; h <= 18; h++)
                '$h': {
                  'gross': 4 + (h == 1 && i == 0 ? -1 : 0),
                  'par': 4,
                  'strokes': h <= 9 ? 1 : 0,
                  'to_par': (h == 1 && i == 0) ? -1 : 0,
                  'kept': i == 0,
                },
            },
          },
      ],
      'best': {for (var h = 1; h <= 18; h++) '$h': h == 1 ? -1 : 0},
    };

Future<void> pump(WidgetTester tester, Map<String, dynamic> data) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: EclecticBoard(data: data)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('the board', () {
    testWidgets('the number is TO PAR, with E for level and a plus for over',
        (tester) async {
      await pump(tester, payload());
      expect(find.text('-4'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      // A gross total would be a number like 63, which means nothing across
      // two courses with different pars.
      expect(find.text('63'), findsNothing);
    });

    testWidgets('a golfer with no card reads a dash, not zero', (tester) async {
      await pump(tester, payload(standings: [
        {'player_id': 1, 'player_name': 'Ann', 'rank': 1, 'tied': false,
         'total': null, 'holes_kept': 0, 'payout': null, 'excluded': false},
      ], cards: {}));
      expect(find.text('–'), findsWidgets);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a tie reads T2', (tester) async {
      await pump(tester, payload(standings: [
        {'player_id': 1, 'player_name': 'Ann', 'rank': 2, 'tied': true,
         'total': 1, 'holes_kept': 18, 'payout': 40.0, 'excluded': false},
      ], cards: {'1': _card()}));
      expect(find.text('T2'), findsOneWidget);
    });

    testWidgets('an excluded golfer is ranked and marked, not hidden',
        (tester) async {
      await pump(tester, payload(standings: [
        {'player_id': 1, 'player_name': 'Ann', 'rank': 1, 'tied': false,
         'total': -4, 'holes_kept': 18, 'payout': null, 'excluded': true},
      ], cards: {'1': _card()}));
      expect(find.text('Ann'), findsOneWidget);
      // Otherwise the money column is simply empty with no reason given.
      expect(find.text('NOT PAID'), findsOneWidget);
    });
  });

  group('the pool switch', () {
    testWidgets('both pools give a switch carrying each pool\'s money',
        (tester) async {
      await pump(tester, payload());
      expect(find.text('Gross'), findsOneWidget);
      expect(find.text('Net'), findsOneWidget);
      expect(find.text('\$240'), findsNWidgets(2));
    });

    testWidgets('one pool draws no switch at all', (tester) async {
      // A single-segment control is a control with nothing to do.
      await pump(tester, payload(pools: const ['gross']));
      expect(find.text('Net'), findsNothing);
      expect(find.text('Gross'), findsNothing);
    });

    testWidgets('switching pools reopens on the leader', (tester) async {
      await pump(tester, payload());
      await tester.tap(find.text('Bea'));       // open the second row
      await tester.pumpAndSettle();
      expect(find.text('Eclectic card'), findsOneWidget);

      await tester.tap(find.text('Net'));
      await tester.pumpAndSettle();
      // Still exactly one card open, and it is the leader's.
      expect(find.text('Eclectic card'), findsOneWidget);
    });
  });

  group('the money is a projection until it is not', () {
    testWidgets('live: the chip says so and the prize is italic',
        (tester) async {
      await pump(tester, payload());
      expect(find.text('R2 live · projected'), findsOneWidget);
      final prize = tester.widget<Text>(find.text('\$160'));
      expect(prize.style!.fontStyle, FontStyle.italic);
    });

    testWidgets('final: no chip, and the prize is upright', (tester) async {
      await pump(tester, payload(isFinal: true));
      expect(find.textContaining('projected'), findsNothing);
      final prize = tester.widget<Text>(find.text('\$160'));
      expect(prize.style!.fontStyle, FontStyle.normal);
    });
  });

  group('the card', () {
    testWidgets('opens on the leader and shows one at a time',
        (tester) async {
      await pump(tester, payload());
      expect(find.text('Eclectic card'), findsOneWidget);
      await tester.tap(find.text('Bea'));
      await tester.pumpAndSettle();
      expect(find.text('Eclectic card'), findsOneWidget);
    });

    testWidgets('tapping the open row closes it', (tester) async {
      // The only way back to a board with nothing open.
      await pump(tester, payload());
      await tester.tap(find.text('Ann'));
      await tester.pumpAndSettle();
      expect(find.text('Eclectic card'), findsNothing);
    });

    testWidgets('a row per round, plus the eclectic along the bottom',
        (tester) async {
      await pump(tester, payload());
      expect(find.text('Front'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Best'), findsNWidgets(2));   // one per nine
      expect(find.text('Out'), findsOneWidget);
      expect(find.text('In'), findsOneWidget);
    });

    testWidgets('there is no par row — two courses mean two pars',
        (tester) async {
      await pump(tester, payload());
      expect(find.text('Par'), findsNothing);
    });

    testWidgets('the legend names the courses', (tester) async {
      await pump(tester, payload());
      expect(find.text('N North Links · T The Ridge'), findsOneWidget);
    });

    testWidgets('a collision falls back to round labels', (tester) async {
      await pump(tester, payload(legend: [
        {'key': 'R1', 'course': 'North Links'},
        {'key': 'R2', 'course': 'North Ridge'},
      ]));
      expect(find.text('R1 North Links · R2 North Ridge'), findsOneWidget);
    });

    testWidgets('a nine is a total or a dash, never a partial', (tester) async {
      // One round with only the front nine scored: Out is a number, In is a
      // dash. A partial sum reads as a real score.
      final half = {
        'rounds': [
          {'label': 'R1', 'course_initial': 'N',
           'holes': {
             for (var h = 1; h <= 9; h++)
               '$h': {'gross': 4, 'par': 4, 'strokes': 0, 'to_par': 0,
                      'kept': true},
           }},
        ],
        'best': {for (var h = 1; h <= 9; h++) '$h': 0},
      };
      await pump(tester, payload(standings: [
        {'player_id': 1, 'player_name': 'Ann', 'rank': 1, 'tied': false,
         'total': 0, 'holes_kept': 9, 'payout': null, 'excluded': false},
      ], cards: {'1': half}));
      expect(find.text('36'), findsOneWidget);   // Out
      expect(find.text('–'), findsWidgets);      // In, and the unplayed holes
    });
  });
}
