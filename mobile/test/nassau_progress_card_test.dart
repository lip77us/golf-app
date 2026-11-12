import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/hole_grid_scorecard.dart';
import 'package:golf_mobile/widgets/nassau_progress_card.dart';
import 'package:golf_mobile/widgets/strokes_table.dart';

/// The Nassau progress grid, on the leaderboard (Paul, 10 Nov 2026: *"move
/// the Nassau progress grid to the leaderboard and remove the scorecard and
/// the strokes table"*).

const _blue = Color(0xFF1565C0);
const _orange = Color(0xFFE65100);

NassauSummary _nassau({
  String variant = 'none',
  List<Map<String, dynamic>> holes = const [],
  bool singles = false,
}) =>
    NassauSummary.fromJson({
      'status': 'in_progress',
      'variant': variant,
      'bet_unit': 10.0,
      'press_unit': 5.0,
      'teams': {
        'team1': [
          {'player_id': 1, 'name': 'Paul Lipkin', 'short_name': 'Paul'},
          if (!singles)
            {'player_id': 2, 'name': 'Dave Moran', 'short_name': 'Dave'},
        ],
        'team2': [
          {'player_id': 3, 'name': 'Sam Reid', 'short_name': 'Sam'},
          if (!singles)
            {'player_id': 4, 'name': 'Mike Naylor', 'short_name': 'Mike'},
        ],
      },
      'front9': {'result': null, 'margin': 0, 'holes_played': 0},
      'back9': {'result': null, 'margin': 0, 'holes_played': 0},
      'overall': {'result': null, 'margin': 0, 'holes_played': 0},
      'presses': const [],
      'holes': holes,
      'payouts': {'total': 0.0, 'total_capped': 0.0},
    });

const _players = <Map<String, dynamic>>[
  {'player_id': 1, 'short_name': 'Paul', 'team': 1},
  {'player_id': 2, 'short_name': 'Dave', 'team': 1},
  {'player_id': 3, 'short_name': 'Sam', 'team': 2},
  {'player_id': 4, 'short_name': 'Mike', 'team': 2},
];

/// Three holes: Paul's side wins the 1st, the 2nd is halved, Sam's side
/// wins the 3rd. Paul strokes on the 2nd and on the unplayed 5th.
List<Map<String, dynamic>> _card() => [
      for (var h = 1; h <= 9; h++)
        {
          'hole': h,
          'par': 4,
          'stroke_index': h,
          'winner_team': h == 1 ? 1 : (h == 3 ? 2 : null),
          'scores': [
            for (final p in _players)
              {
                'player_id': p['player_id'],
                'gross': h <= 3 ? 4 + ((p['player_id'] as int) % 2) : null,
                'strokes': p['player_id'] == 1 && (h == 2 || h == 5) ? 1 : 0,
              },
          ],
        },
    ];

const _holes = <Map<String, dynamic>>[
  {'hole': 1, 'winner': 'team1', 'bottom_delta': 2},
  {'hole': 2, 'winner': 'halved', 'bottom_delta': 0},
  {'hole': 3, 'winner': 'team2', 'bottom_delta': -1},
];

Future<void> _pump(WidgetTester t, NassauSummary nas,
    {List<Map<String, dynamic>>? players}) async {
  await t.binding.setSurfaceSize(const Size(390, 500));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: NassauProgressCard(
        nassau: nas,
        holes: _card(),
        players: players ?? _players,
        holesInPlay: const [1, 2, 3, 4, 5, 6, 7, 8, 9],
        side0Colour: _blue,
        side1Colour: _orange,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Color? _colourOf(WidgetTester t, String text) =>
    t.widget<Text>(find.text(text).first).style?.color;

void main() {
  group('the grid', () {
    testWidgets('is titled for the game, not "Scorecard"', (t) async {
      await _pump(t, _nassau(holes: _holes));
      expect(find.text('Nassau progress'), findsOneWidget);
      expect(find.text('Scorecard'), findsNothing);
    });

    testWidgets('draws NO strokes table', (t) async {
      // Paul strokes on two holes here, so the table WOULD draw if it were
      // left on — its own gate is "does anybody stroke". The dots are on
      // the cells, the unplayed 5th included.
      await _pump(t, _nassau(holes: _holes));
      expect(find.byType(StrokesTable), findsNothing);
    });

    testWidgets('names each golfer in his side\'s colour', (t) async {
      await _pump(t, _nassau(holes: _holes));
      Color? nameColour(String name) {
        // `startsWith`: a golfer who strokes reads `Paul gets 2`.
        final rich = t.widgetList<RichText>(find.byType(RichText)).firstWhere(
            (r) => r.text.toPlainText().startsWith(name));
        return (rich.text as TextSpan).style?.color;
      }
      expect(nameColour('Paul'), _blue);
      expect(nameColour('Dave'), _blue);
      expect(nameColour('Sam'), _orange);
      expect(nameColour('Mike'), _orange);
    });

    testWidgets('says who won each hole, in that side\'s colour',
        (t) async {
      await _pump(t, _nassau(holes: _holes));
      expect(find.text('Won by'), findsOneWidget);
      // The side's initials: Paul + Dave, Sam + Mike.
      expect(_colourOf(t, 'PD'), _blue);
      expect(_colourOf(t, 'SM'), _orange);
      expect(find.text('='), findsOneWidget, reason: 'the halved 2nd');
      // Six holes nobody has played yet.
      expect(find.text('·'), findsNWidgets(6));
    });

    testWidgets('the score cells carry no winning-side tint', (t) async {
      // The row underneath names the winner; two marks for one fact is one
      // too many. The shared card tints off `winner_team`, so it must not
      // reach it.
      await _pump(t, _nassau(holes: _holes));
      final card =
          t.widget<HoleGridScorecard>(find.byType(HoleGridScorecard));
      expect(card.holes.any((h) => h.containsKey('winner_team')), isFalse);
    });

    testWidgets('a 1-v-1 names the winner instead of initials', (t) async {
      await _pump(t, _nassau(holes: _holes, singles: true), players: const [
        {'player_id': 1, 'short_name': 'Paul', 'team': 1},
        {'player_id': 3, 'short_name': 'Sam', 'team': 2},
      ]);
      // Once as the row's name, once under the hole he won.
      expect(find.text('Paul'), findsOneWidget);
      expect(find.text('Sam'), findsOneWidget);
    });
  });

  group('Claremont', () {
    testWidgets('has a Top row and a Bottom row', (t) async {
      await _pump(t, _nassau(variant: 'claremont', holes: _holes));
      expect(find.text('Top'), findsOneWidget);
      expect(find.text('Bottom'), findsOneWidget);
      expect(find.text('Won by'), findsNothing);
    });

    testWidgets('the Bottom row says how many points went, and which way',
        (t) async {
      await _pump(t, _nassau(variant: 'claremont', holes: _holes));
      // By colour, not `.first`: the hole header also reads `2`.
      final twos = t
          .widgetList<Text>(find.text('2'))
          .map((w) => w.style?.color)
          .where((c) => c == _blue || c == _orange)
          .toList();
      expect(twos, [_blue], reason: 'both balls on the 1st, to side 1');
      // `1` appears twice in a side colour: the Top point on the 1st (blue)
      // and on the 3rd (orange), plus the Bottom point on the 3rd (orange).
      final ones = t
          .widgetList<Text>(find.text('1'))
          .map((w) => w.style?.color)
          .where((c) => c == _blue || c == _orange)
          .toList();
      expect(ones.where((c) => c == _orange).length, 2);
      expect(ones.where((c) => c == _blue).length, 1);
    });
  });

  group('one Nassau grid, and it is on the leaderboard', () {
    final lb = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
    final se = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('every Nassau card on the board draws it', () {
      // The casual match, the cup match, the Singles Match — and Triple
      // Nassau's, which draws one a pair.
      expect('NassauProgressCard('.allMatches(lb).length, 4);
    });

    test('no Nassau card still draws the plain scorecard', () {
      // Each `NassauBoard(` that feeds a group card is followed by the
      // progress card, not by `HoleGridScorecard(` — bounded by the next
      // class, not a character count.
      for (final cls in ['class _MatchLeaderboardCardState',
                         'class _NassauGroupCard']) {
        final at = lb.indexOf(cls);
        expect(at, greaterThan(0), reason: cls);
        final end = lb.indexOf('\nclass ', at + 10);
        expect(lb.substring(at, end).contains('HoleGridScorecard('), isFalse,
            reason: '$cls still draws the scorecard it was meant to lose');
      }
    });

    test('score entry draws no Nassau grid', () {
      // The CALL and the class, not the bare name: two neighbouring grids
      // still say in a comment that they were modelled on it.
      expect(se.contains('_NassauProgressGrid('), isFalse);
      expect(se.contains('class _NassauProgressGrid'), isFalse);
      expect(se.contains("'Nassau progress'"), isFalse);
    });
  });
}
