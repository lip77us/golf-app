import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_colors.dart';
import 'package:golf_mobile/widgets/hole_grid_scorecard.dart';

/// The scorecard tints the BALL that won a hole, not the side that did.
///
/// Reported from a Fourball board (Paul, 10 Nov 2026): Larry's 6 and Jim's 5
/// were both orange on a hole Jim's ball won — *"only highlight the winner or
/// winners, not the winning team."* The server marks each score `won`; a
/// payload that sends no flag still tints the whole side, as Nassau-family
/// cards always have.

const _players = <Map<String, dynamic>>[
  {'player_id': 1, 'short_name': 'Paul', 'team': 1},
  {'player_id': 2, 'short_name': 'Gil', 'team': 1},
  {'player_id': 3, 'short_name': 'Larry', 'team': 2},
  {'player_id': 4, 'short_name': 'Jim', 'team': 2},
];

/// One hole, won by side 2. Grosses are all different so a cell can be found
/// by its number: Paul 7, Gil 8, Larry 6, Jim 5.
List<Map<String, dynamic>> _hole({Map<int, bool>? won}) => [
      {
        'hole': 1,
        'par': 4,
        'stroke_index': 1,
        'winner_team': 2,
        'scores': [
          for (final (pid, gross) in [(1, 7), (2, 8), (3, 6), (4, 5)])
            {
              'player_id': pid,
              'gross': gross,
              'strokes': 0,
              if (won != null) 'won': won[pid] ?? false,
            },
        ],
      },
    ];

Future<void> _pump(WidgetTester t, List<Map<String, dynamic>> holes) async {
  await t.binding.setSurfaceSize(const Size(390, 400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: HoleGridScorecard(
        holes: holes,
        participants: _players,
        holesInPlay: const [1],
        legend: null,
        showStrokes: false,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// The fill behind a score cell, found by the score it shows.
Color? _fillOf(WidgetTester t, String gross) {
  final cell = t.widget<Container>(find
      .ancestor(of: find.text(gross), matching: find.byType(Container))
      .first);
  return (cell.decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('only the ball that won is tinted', (t) async {
    await _pump(t, _hole(won: {4: true}));
    expect(_fillOf(t, '5'), GameColors.team2Bg, reason: 'Jim won it');
    expect(_fillOf(t, '6'), isNull, reason: 'Larry is on the side, not the ball');
    expect(_fillOf(t, '7'), isNull);
    expect(_fillOf(t, '8'), isNull);
  });

  testWidgets('partners who tie for it are both tinted', (t) async {
    await _pump(t, _hole(won: {3: true, 4: true}));
    expect(_fillOf(t, '5'), GameColors.team2Bg);
    expect(_fillOf(t, '6'), GameColors.team2Bg);
  });

  testWidgets('a payload with no flag tints the whole side, as before',
      (t) async {
    // Every card that is not Fourball: nothing changes for them.
    await _pump(t, _hole());
    expect(_fillOf(t, '5'), GameColors.team2Bg);
    expect(_fillOf(t, '6'), GameColors.team2Bg);
    expect(_fillOf(t, '7'), isNull, reason: 'the losing side');
  });

  testWidgets('the flag never tints the losing side', (t) async {
    // `won` on a golfer whose side did not take the hole is a server bug,
    // and the card must not turn it into a win.
    await _pump(t, _hole(won: {1: true, 4: true}));
    expect(_fillOf(t, '7'), isNull);
    expect(_fillOf(t, '5'), GameColors.team2Bg);
  });
}
