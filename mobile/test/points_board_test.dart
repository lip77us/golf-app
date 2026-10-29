import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/utils/points_board_model.dart';
import 'package:golf_mobile/widgets/points_board.dart';

const _paul = 1, _sam = 2, _dave = 3;

Map<String, dynamic> _entry(int id, String short, int net, double pts) => {
      'player_id': id,
      'name': {_paul: 'Paul Lipkin', _sam: 'Sam Reid', _dave: 'Dave Moran'}[id],
      'short_name': short,
      'net_score': net,
      'gross': net,
      'strokes': 0,
      'points': pts,
    };

/// The worked example in the packet: $1 a point, vs Average, Paul/Sam/Dave.
/// Paul low outright on every hole in play, Sam second, Dave third.
Map<String, dynamic> _summary({
  required int thru,
  List<int>? holesInPlay,
  String status = 'in_progress',
  List<Map<String, dynamic>>? players,
  List<Map<String, dynamic>>? holes,
}) {
  final order = holesInPlay ?? [for (var i = 1; i <= 18; i++) i];
  final played = order.take(thru).toList();
  return {
    'status': status,
    'handicap': {'mode': 'strokes_off', 'net_percent': 100},
    'players': players ??
        [
          {'player_id': _paul, 'name': 'Paul Lipkin', 'short_name': 'Paul',
           'points': 5.0 * thru, 'holes_played': thru, 'money': 2.0 * thru},
          {'player_id': _dave, 'name': 'Dave Moran', 'short_name': 'Dave',
           'points': 3.0 * thru, 'holes_played': thru, 'money': 0.0},
          {'player_id': _sam, 'name': 'Sam Reid', 'short_name': 'Sam',
           'points': 1.0 * thru, 'holes_played': thru, 'money': -2.0 * thru},
        ],
    'holes': holes ??
        [
          for (final h in played)
            {
              'hole': h,
              'par': h == 7 ? 3 : 4,
              'entries': [
                _entry(_paul, 'Paul', 3, 5),
                _entry(_sam, 'Sam', 4, 3),
                _entry(_dave, 'Dave', 5, 1),
              ],
            },
        ],
    'holes_in_play': order,
    'current_hole': played.isEmpty ? 0 : played.last,
    'scorecard': {
      'players': [
        {'player_id': _paul, 'name': 'Paul Lipkin', 'short_name': 'Paul'},
        {'player_id': _sam, 'name': 'Sam Reid', 'short_name': 'Sam'},
        {'player_id': _dave, 'name': 'Dave Moran', 'short_name': 'Dave'},
      ],
      'holes': [
        for (final h in order) {'hole': h, 'par': h == 7 ? 3 : 4},
      ],
      'holes_in_play': order,
    },
    'money': {
      'bet_unit': 1.0,
      'par_per_hole': 3,
      'loss_cap': null,
      'payout_style': 'per_point',
      'per_point_mode': 'average',
    },
  };
}

Future<void> _pump(WidgetTester t, Map<String, dynamic> j,
    {double width = 390}) async {
  await t.binding.setSurfaceSize(Size(width, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: PointsBoard(
            data: PointsBoardData.fromSummary(Points531Summary.fromJson(j)),
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the hole just played leads the board', (t) async {
    await _pump(t, _summary(thru: 7));
    expect(find.text('HOLE 7 · PAR 3'), findsOneWidget);
    expect(find.text('Next: 8 · par 4'), findsOneWidget);
    expect(find.text('11 holes left'), findsOneWidget);
  });

  testWidgets('the hole total is summed from the scores, not asserted',
      (t) async {
    await _pump(t, _summary(thru: 7));
    // 5 + 3 + 1. Summing says it from the awards rather than from a sentence
    // that would keep reading `9` if the prices ever changed.
    expect(find.textContaining('The hole pays'), findsOneWidget);
    expect(find.text('9'), findsWidgets);
  });

  testWidgets('a tied hole marks both golfers', (t) async {
    await _pump(t, _summary(thru: 13, holes: [
      {
        'hole': 13,
        'par': 4,
        'entries': [
          _entry(_sam, 'Sam', 4, 4),
          _entry(_dave, 'Dave', 4, 4),
          _entry(_paul, 'Paul', 5, 1),
        ],
      },
    ]));
    expect(find.text('tied'), findsNWidgets(2));
  });

  testWidgets('before the first tee it states the rule, not an empty hole',
      (t) async {
    await _pump(t, _summary(thru: 0));
    expect(find.text('Not started'), findsOneWidget);
    expect(find.textContaining('5 for low, 3 for second, 1 for third'),
        findsOneWidget);
  });

  testWidgets('the finish reports against target, not against par',
      (t) async {
    await _pump(t, _summary(
      thru: 18,
      status: 'complete',
      players: [
        {'player_id': _paul, 'name': 'Paul Lipkin', 'short_name': 'Paul',
         'points': 69.0, 'holes_played': 18, 'money': 15.0},
        {'player_id': _sam, 'name': 'Sam Reid', 'short_name': 'Sam',
         'points': 49.0, 'holes_played': 18, 'money': -5.0},
        {'player_id': _dave, 'name': 'Dave Moran', 'short_name': 'Dave',
         'points': 44.0, 'holes_played': 18, 'money': -10.0},
      ],
    ));
    expect(find.text('ROUND OVER'), findsOneWidget);
    expect(find.text('vs. Target'), findsOneWidget);
    // Twice: the headline and the ledger's own column, which is the thing
    // worth pinning — they are one fact and have to agree.
    expect(find.text('+15'), findsNWidgets(2));
    expect(find.text('69 points · 15 over target of 54 · wins \$15'),
        findsOneWidget);
    // "Target", never "par" — par is a number of strokes, and this card is
    // counting points.
    expect(find.textContaining('par'), findsNothing);
  });

  testWidgets('a nine-hole round plays to 27, not 54', (t) async {
    await _pump(t, _summary(
      thru: 9,
      status: 'complete',
      holesInPlay: [for (var h = 1; h <= 9; h++) h],
      players: [
        {'player_id': _paul, 'name': 'Paul Lipkin', 'short_name': 'Paul',
         'points': 35.0, 'holes_played': 9, 'money': 8.0},
        {'player_id': _sam, 'name': 'Sam Reid', 'short_name': 'Sam',
         'points': 25.0, 'holes_played': 9, 'money': -2.0},
        {'player_id': _dave, 'name': 'Dave Moran', 'short_name': 'Dave',
         'points': 21.0, 'holes_played': 9, 'money': -6.0},
      ],
    ));
    expect(find.textContaining('target of 27'), findsOneWidget);
    expect(find.text('Target 27 pts'), findsOneWidget);
  });

  group('points by hole', () {
    testWidgets('the back nine stays away until it is being played',
        (t) async {
      await _pump(t, _summary(thru: 7));
      expect(find.text('Out'), findsOneWidget);
      expect(find.text('In'), findsNothing);

      await _pump(t, _summary(thru: 11));
      expect(find.text('In'), findsOneWidget);
    });

    testWidgets('off a shotgun it is the FRONT nine that waits', (t) async {
      // The reference hides the back nine until hole 10, which assumes a
      // round that starts at the 1st. From the 10th tee the back nine is the
      // one being played.
      await _pump(t, _summary(
        thru: 4,
        holesInPlay: [
          for (var h = 10; h <= 18; h++) h,
          for (var h = 1; h <= 9; h++) h,
        ],
      ));
      expect(find.text('In'), findsOneWidget);
      expect(find.text('Out'), findsNothing);
    });

    testWidgets('and each nine reads in hole-number order', (t) async {
      // Play order for the walk, hole number for the grid — a scorecard is a
      // scorecard whatever order it was played in.
      await _pump(t, _summary(
        thru: 12,
        holesInPlay: [
          for (var h = 7; h <= 18; h++) h,
          for (var h = 1; h <= 6; h++) h,
        ],
      ));
      final numbers = t
          .widgetList<Text>(find.descendant(
              of: find.byType(PointsBoard), matching: find.byType(Text)))
          .map((w) => w.data)
          .toList();
      final out = numbers.indexOf('Out');
      final inn = numbers.indexOf('In');
      expect(out >= 0 && inn >= 0, isTrue);
      // The front block's header runs 1..9 before its "Out".
      expect(numbers.sublist(0, out).join(','), contains('1,2,3,4,5,6,7,8,9'));
    });

    testWidgets('the key names all three golfers\' colours', (t) async {
      await _pump(t, _summary(thru: 7));
      expect(find.text('Low · 5'), findsOneWidget);
      expect(find.text('Second · 3'), findsOneWidget);
      expect(find.text('Third · 1'), findsOneWidget);
    });
  });

  group('the ledger', () {
    testWidgets('leads on v. target, with the stake in the header',
        (t) async {
      await _pump(t, _summary(thru: 7));
      expect(find.text('V. TARGET'), findsOneWidget);
      expect(find.text('\$1 a point'), findsOneWidget);
      expect(find.text('Each · now'), findsOneWidget);
      expect(find.text('Target 21 pts'), findsOneWidget);
      expect(find.text('Left 11 holes'), findsOneWidget);
    });

    testWidgets('renders the server\'s money, cap and all', (t) async {
      // Foursome 257: 58 · 57 · 47 thru 18 with a $6 cap. The reference
      // formula would print +$4 / +$3 / −$7.
      await _pump(t, _summary(
        thru: 18,
        status: 'complete',
        players: [
          {'player_id': _paul, 'name': 'Will Glennon', 'short_name': 'Will',
           'points': 58.0, 'holes_played': 18, 'money': 3.43},
          {'player_id': _sam, 'name': 'Paul Lipkin', 'short_name': 'Paul',
           'points': 57.0, 'holes_played': 18, 'money': 2.57},
          {'player_id': _dave, 'name': 'Roger Bird', 'short_name': 'Roger',
           'points': 47.0, 'holes_played': 18, 'money': -6.00},
        ],
      ));
      expect(find.text('+\$3.43'), findsOneWidget);
      expect(find.text('+\$2.57'), findsOneWidget);
      expect(find.text('−\$6'), findsOneWidget);
      expect(find.text('+\$4'), findsNothing);
      expect(find.text('−\$7'), findsNothing);
    });

    testWidgets('the stake keeps the right edge of its header', (t) async {
      // Found on a device, not here: a bare `Flexible` defaults to flex 1,
      // so the label and the stake SPLIT the row and the stake lands in the
      // middle. Nothing overflows, so only a measurement catches it.
      //
      // **Measured WIDE on purpose.** At phone width the test font is wide
      // enough to fill the split half, which puts the box's right edge in
      // the same place either way — the first version of this test passed
      // against the bug for exactly that reason. With room to spare, a
      // loose Flexible shrink-wraps and falls short.
      await _pump(t, _summary(thru: 7), width: 900);
      final stake = t.getRect(find.text('\$1 a point'));
      // 16pt page margin plus the ledger's own 16pt padding.
      expect(stake.right, closeTo(900 - 32, 1));
      expect(t.getRect(find.text('Each · now')).left, closeTo(32, 1));
    });

    testWidgets('a golfer under target wears the clay ink', (t) async {
      await _pump(t, _summary(thru: 7));
      final under = t.widget<Text>(find.text('−14'));
      expect(under.style?.color, Halved.clayInk);
      final over = t.widget<Text>(find.text('+14'));
      expect(over.style?.color, Halved.pine);
    });

    testWidgets('and says Final rather than counting holes', (t) async {
      await _pump(t, _summary(
        thru: 18,
        status: 'complete',
        players: [
          {'player_id': _paul, 'name': 'Paul Lipkin', 'short_name': 'Paul',
           'points': 54.0, 'holes_played': 18, 'money': 0.0},
        ],
      ));
      expect(find.text('Final, each'), findsOneWidget);
      expect(find.text('Final'), findsOneWidget);
    });
  });

  testWidgets('it fits a phone without overflowing', (t) async {
    // An overflow raises during layout, so the pump itself is the assertion;
    // this only makes the claim explicit at the narrowest real width.
    await t.binding.setSurfaceSize(const Size(360, 1800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await _pump(t, _summary(thru: 13));
    expect(t.takeException(), isNull);
  });

  test('the leaderboard draws no Points table of its own', () {
    // The packet's scope line: "one widget used by every Points 5-3-1
    // leaderboard. Do not draw a second Points board."
    final src =
        File('lib/screens/leaderboard_screen.dart').readAsStringSync();
    final card = src.substring(
      src.indexOf('class _Points531GroupCard'),
      src.indexOf('/// Leaderboard card for a Wolf foursome'),
    );
    expect(card.contains('PointsBoard('), isTrue);
    for (final gone in ['_hcapLabel', '_modeLabel', 'par is', 'Bet unit']) {
      expect(card.contains(gone), isFalse, reason: '$gone survives');
    }
  });
}
