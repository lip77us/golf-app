import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/round_leaderboard_route.dart';

/// Reported from a finished scramble, 30 Oct 2026: *"the leaderboard went away
/// when I completed the round. It says No Championship game configured."*
///
/// A Foursome Play round has no round-level games, so the generic board builds
/// no tabs, falls through to the championship view and says that about an
/// event that is configured. The hub's own helper routed around it — and the
/// completion handler did not go through the helper.

void main() {
  group('where a round board lives', () {
    test('a Foursome Play round goes to the team board', () {
      final r = roundLeaderboardRoute(
          roundId: 493, isTeamPlayRound: true, tournamentId: 70);
      expect(r.route, '/team-play-leaderboard');
      expect((r.arguments as Map)['tournamentId'], 70);
    });

    test('every other round goes to its own board', () {
      final r = roundLeaderboardRoute(
          roundId: 205, isTeamPlayRound: false, tournamentId: 70);
      expect(r.route, '/leaderboard');
      expect(r.arguments, 205);
    });

    test('a casual round has no tournament and is unaffected', () {
      final r = roundLeaderboardRoute(
          roundId: 205, isTeamPlayRound: false, tournamentId: null);
      expect(r.route, '/leaderboard');
      expect(r.arguments, 205);
    });

    test('team play with no tournament falls back rather than opening empty',
        () {
      // The team board is keyed on the tournament, so there is nothing to
      // send anyone to — pushing it anyway would trade one empty screen for
      // another.
      final r = roundLeaderboardRoute(
          roundId: 7, isTeamPlayRound: true, tournamentId: null);
      expect(r.route, '/leaderboard');
    });
  });

  group('one place decides it', () {
    final src = File('lib/screens/round_screen.dart').readAsStringSync();

    test('the hub pushes no leaderboard route by hand', () {
      // The bug was a second answer written inline. The helper's own docstring
      // claimed both entry points went through it; the third could not, since
      // `_CompleteRoundButton` never holds the round.
      for (final literal in ["'/leaderboard'", "'/team-play-leaderboard'"]) {
        expect(src.contains('pushNamed($literal'), isFalse,
            reason: '$literal is pushed directly in round_screen.dart');
      }
    });

    test('and the completion handler uses the shared decision', () {
      final i = src.indexOf('completeRound(roundId)');
      expect(i, greaterThan(0));
      expect(src.substring(i, i + 600), contains('roundLeaderboardRoute('),
          reason: 'the push after a round closes must go through it');
    });
  });
}
