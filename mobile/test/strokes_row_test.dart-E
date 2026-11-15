// "Where we get strokes": one row on the leaderboard, opening the grid's own
// stroke plan as the shared table.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final board = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
  final grid = File('lib/widgets/scorecard_grid.dart').readAsStringSync();

  test('every board has the row, above the games', () {
    expect(board.contains('_strokesRow(context, rp),'), isTrue);
    expect(board.contains('Where we get strokes'), isTrue);
    expect(board.contains('strokesOnly: true'), isTrue);
  });

  test('it is the grid\'s own stroke plan, not a second one', () {
    final i = grid.indexOf('Widget _strokesOnlyView');
    final body = grid.substring(i, grid.indexOf('Widget build(', i));
    expect(body.contains('_strokesForHole(m, h)'), isTrue);
    expect(body.contains('StrokesTable('), isTrue);
  });

  test('a game with no strokes says so rather than drawing a blank grid', () {
    expect(grid.contains('Nobody gets a stroke in this game.'), isTrue);
  });
}
