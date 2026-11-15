import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/hole_grid_scorecard.dart';

/// `gets 10` beside each golfer on a scorecard, and nothing for a golfer who
/// gets none (Paul, 10 Nov 2026: *"add the gets 1, gets 10, or leave it blank
/// if they are low golfer and they get 0"*).

/// Nine holes. Gil strokes on holes 1, 2 and 5; nobody else does.
List<Map<String, dynamic>> _holes({Set<int> gil = const {1, 2, 5}}) => [
      for (var h = 1; h <= 9; h++)
        {
          'hole': h,
          'par': 4,
          'stroke_index': h,
          'scores': [
            for (final pid in [1, 2])
              {
                'player_id': pid,
                // Only the first three holes are PLAYED: the total has to
                // count the strokes still to come.
                'gross': h <= 3 ? 5 : null,
                'strokes': pid == 2 && gil.contains(h) ? 1 : 0,
              },
          ],
        },
    ];

Future<void> _pump(WidgetTester t, List<Map<String, dynamic>> players,
    {List<int> holesInPlay = const [1, 2, 3, 4, 5, 6, 7, 8, 9]}) async {
  await t.binding.setSurfaceSize(const Size(390, 400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: HoleGridScorecard(
        holes: _holes(),
        participants: players,
        holesInPlay: holesInPlay,
        legend: null,
        showStrokes: false,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// The label a golfer's row draws, as plain text.
String _label(WidgetTester t, String name) => t
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText())
    .firstWhere((s) => s.startsWith(name));

void main() {
  testWidgets('a golfer who strokes says how many he gets', (t) async {
    await _pump(t, const [
      {'player_id': 1, 'short_name': 'Paul'},
      {'player_id': 2, 'short_name': 'Gil'},
    ]);
    expect(_label(t, 'Gil'), 'Gil gets 3');
  });

  testWidgets('the low man is blank, not "gets 0"', (t) async {
    await _pump(t, const [
      {'player_id': 1, 'short_name': 'Paul'},
      {'player_id': 2, 'short_name': 'Gil'},
    ]);
    expect(_label(t, 'Paul'), 'Paul');
    expect(find.textContaining('gets 0', findRichText: true), findsNothing);
  });

  testWidgets('it counts the strokes still to come, not only those played',
      (t) async {
    // Three holes are in; Gil's third stroke is on the unplayed 5th.
    await _pump(t, const [
      {'player_id': 2, 'short_name': 'Gil'},
    ]);
    expect(_label(t, 'Gil'), 'Gil gets 3');
  });

  testWidgets('only the holes in play are counted', (t) async {
    // A card showing holes 3-9 has one of Gil's strokes on it.
    await _pump(t, const [
      {'player_id': 2, 'short_name': 'Gil'},
    ], holesInPlay: const [3, 4, 5, 6, 7, 8, 9]);
    expect(_label(t, 'Gil'), 'Gil gets 1');
  });

  testWidgets('the game\'s own figure wins where it states one', (t) async {
    // `phcp_in_play` is what THIS game gives him after its allowance; eight
    // games send it. It used to draw as a bare `(6)`.
    await _pump(t, const [
      {'player_id': 1, 'short_name': 'Paul', 'phcp_in_play': 0},
      {'player_id': 2, 'short_name': 'Gil', 'phcp_in_play': 6},
    ]);
    expect(_label(t, 'Gil'), 'Gil gets 6');
    expect(_label(t, 'Paul'), 'Paul');
    expect(find.textContaining('(6)', findRichText: true), findsNothing);
  });

  testWidgets('a card that only knows the holes played says nothing',
      (t) async {
    // Hole 9 has no entry for Gil at all: the card cannot know what he gets
    // on it, so a total of the rest would be a figure that grows all day.
    await t.binding.setSurfaceSize(const Size(390, 400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final holes = _holes()
      ..last['scores'] = [
        {'player_id': 1, 'gross': null, 'strokes': 0},
      ];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HoleGridScorecard(
          holes: holes,
          participants: const [
            {'player_id': 2, 'short_name': 'Gil'},
          ],
          holesInPlay: const [1, 2, 3, 4, 5, 6, 7, 8, 9],
          legend: null,
          showStrokes: false,
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(_label(t, 'Gil'), 'Gil');
  });

  // **Whether `Larry gets 10` FITS is not tested here**, on purpose: the
  // Flutter test font is one square per glyph, so thirteen characters measure
  // 154px against a 92px column and a fit test would be measuring the font.
  // The column width was checked by rendering the card with a real font.
}
