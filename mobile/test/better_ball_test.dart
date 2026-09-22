/// test/better_ball_test.dart
/// --------------------------
/// The two things that follow the ball count, and the rule that keeps Better
/// Ball and Irish Rumble off the same round.
///
/// The name and the allowance are mirrored from `services/better_ball.py` so
/// the setup screen's readback moves on the tap rather than after a round
/// trip. A mirror that drifts is worse than no mirror — it shows a TD one
/// number and saves another — so these tests are the mirror's own check.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/utils/better_ball.dart';
import 'package:golf_mobile/utils/team_allowance.dart';

void main() {
  group('the name follows the count', () {
    test('each count has its own name', () {
      expect(betterBallName(1), 'Better Ball');
      expect(betterBallName(2), 'Best 2 of 4');
      expect(betterBallName(3), 'Best 3 of 4');
    });

    test('four is worth its own word', () {
      // `Best 4 of 4` describes the arithmetic and misses the point: when
      // every net counts, nobody can have a bad hole quietly.
      expect(betterBallName(4), 'Aggregate');
    });

    test('a count off the end falls back rather than showing nothing', () {
      expect(betterBallName(0), 'Best 2 of 4');
      expect(betterBallName(9), 'Best 2 of 4');
    });
  });

  group('the allowance follows the count', () {
    test('it is the published table', () {
      expect(betterBallAllowance(1), 75);
      expect(betterBallAllowance(2), 85);
      expect(betterBallAllowance(3), 95);
      expect(betterBallAllowance(4), 100);
    });

    test('it reads the shared ladder rather than restating it', () {
      // One ladder, not two. Two would agree on the day they were written and
      // eventually pay different money for one format.
      for (final e in kShamblePctByBalls.entries) {
        expect(betterBallAllowance(e.key), e.value);
      }
    });
  });

  group('the preview is one line, not eighteen', () {
    test('it states the count rather than drawing a grid', () {
      expect(betterBallPreview(2), 'Holes 1–18 · Best 2 nets per group');
    });

    test('one ball reads as one net', () {
      expect(betterBallPreview(1), contains('Best 1 net '));
    });

    test('aggregate says what it costs rather than counting', () {
      expect(betterBallPreview(4), 'Every net counts — nothing dropped');
    });
  });

  group('one round runs one of them', () {
    test('each game excludes the other', () {
      // Both directions: the TD reaches the two setups in either order, and a
      // rule enforced on one side only holds until somebody picks the other
      // one first. The server guards both too.
      expect(gameMeta(GameIds.betterBall)!.excludes,
          contains(GameIds.irishRumble));
      expect(gameMeta(GameIds.irishRumble)!.excludes,
          contains(GameIds.betterBall));
    });

    test('Better Ball is a multi-group tournament game', () {
      final meta = gameMeta(GameIds.betterBall)!;
      expect(meta.tournament, isTrue);
      expect(meta.requiresMultiFoursome, isTrue);
    });

    test('it resolves a display name for every surface', () {
      expect(gameDisplayName(GameIds.betterBall), 'Better Ball');
    });
  });
}
