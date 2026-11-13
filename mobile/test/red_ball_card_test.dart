// The ball game's scorecard is the leaderboard's, with the carrier in gold.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final board = _read('lib/screens/leaderboard_screen.dart');
  final i = board.indexOf('class _RedBallViewState');
  final red = board.substring(i, board.indexOf('// ---- Low Net ----', i));

  group('the board', () {
    test('draws each group\'s card through the shared scorecard', () {
      expect(red.contains('HoleGridScorecard('), isTrue);
      expect(red.contains("'role_id': h['role_id']"), isTrue);
    });

    test('opens a lone group, and lets a field tap its own open', () {
      expect(red.contains('results.length == 1'), isTrue);
      expect(red.contains('_open.remove(g)'), isTrue);
    });

    test('says what the gold means and marks the hole it was lost on', () {
      expect(red.contains('this score counts'), isTrue);
      expect(red.contains("'Lost'"), isTrue);
    });

    test('draws no strokes table under it', () {
      expect(red.contains('showStrokes: false'), isTrue);
    });
  });

  group('score entry', () {
    test('the shared screen draws no group card on a ball round', () {
      final src = _read('lib/screens/score_entry_screen.dart');
      expect(src.contains("!games.contains('pink_ball')"), isTrue);
    });

    test('the old ball screen draws none either', () {
      final src = _read('lib/screens/pink_ball_screen.dart');
      expect(src.contains('StrokePlayProgressGrid('), isFalse);
    });
  });
}
