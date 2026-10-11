// A game switched on and never configured said "No data yet".
//
// Reported from a 40 Balls round with 128 scores in it. The tab exists for
// every game in `active_games`, but the server only sends a block once the
// game is CONFIGURED — `forty_balls_summary` returns {} with no config and
// `if summary:` drops it — so the board described the wrong thing entirely.
// It was never that game's problem: every game left unconfigured said it.
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';

void main() {
  group('the empty state has to name the cause', () {
    test('every game that can be a tab has a display name', () {
      // The message leads with the game's name, so a slug leaking through
      // would read as "forty_balls is not set up yet".
      for (final id in [
        GameIds.fortyBalls,
        GameIds.hotSpot,
        GameIds.betterBall,
        GameIds.irishRumble,
        GameIds.skins,
        GameIds.pinkBall,
      ]) {
        final name = gameDisplayName(id);
        expect(name, isNotEmpty, reason: '$id has no display name');
        expect(name, isNot(contains('_')),
            reason: '$id fell through to its slug');
        expect(name, isNot(equals(id)), reason: '$id fell through to its slug');
      }
    });
  });
}
