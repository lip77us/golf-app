/// The per-round side games, and the scopes they must not be confused with.
///
/// Round 1's games were chosen by seven hardcoded cards in the tournament
/// wizard while every later round drew bare chips from the catalog, so the
/// two lists drifted in BOTH directions — the wizard never offered Stroke
/// Play or Hot Spot, and the chips never carried the blurb. These pin the one
/// list, and the two games that are deliberately not on it.
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/widgets/side_games_picker.dart';

void main() {
  group('the per-round list', () {
    final ids = perRoundSideGames(multiFoursome: true).map((g) => g.id).toSet();

    test('Dream Round is NOT a round-level side game', () {
      // Its config is a OneToOne on the TOURNAMENT and its board is built by
      // TournamentLeaderboardView, so a round carrying the slug has no block
      // to draw — it came up as an empty lowercase `dream_round` tab and the
      // server strips it back out. It belongs to the event, not the round.
      expect(ids, isNot(contains(GameIds.dreamRound)));
    });

    test('it carries the games a round really does play', () {
      expect(ids, containsAll(<String>[
        GameIds.irishRumble,
        GameIds.betterBall,
        GameIds.hotSpot,
        GameIds.fortyBalls,
        GameIds.pinkBall,
        GameIds.strokePlay,
      ]));
    });

    test('Hot Spot is on it — the gap that started this', () {
      expect(ids, contains(GameIds.hotSpot));
    });

    test('every game on it can explain itself', () {
      // The blurb and the money note live in the catalog so all three pickers
      // say the same thing. A game added without them would draw a bare card.
      for (final g in perRoundSideGames(multiFoursome: true)) {
        expect(g.blurb, isNotNull, reason: '${g.id} has no blurb');
        expect(g.blurb, isNotEmpty, reason: '${g.id} has an empty blurb');
      }
    });

    test('nothing cup-only or disabled leaks in', () {
      for (final g in perRoundSideGames(multiFoursome: true)) {
        expect(g.cupOnly, isFalse, reason: '${g.id} is cup-only');
        expect(g.enabled, isTrue, reason: '${g.id} is disabled');
        expect(g.tournament, isTrue, reason: '${g.id} is not a tournament game');
      }
    });

    test('a single-group round drops the ones that rank groups', () {
      final solo = perRoundSideGames(multiFoursome: false).map((g) => g.id);
      expect(solo, isNot(contains(GameIds.irishRumble)));
    });
  });
}
