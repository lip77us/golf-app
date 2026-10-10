/// The per-round side games, and the scopes they must not be confused with.
///
/// Round 1's games were chosen by seven hardcoded cards in the tournament
/// wizard while every later round drew bare chips from the catalog, so the
/// two lists drifted in BOTH directions — the wizard never offered Stroke
/// Play or Hot Spot, and the chips never carried the blurb. These pin the one
/// list, and the two games that are deliberately not on it.
import 'package:flutter/material.dart';
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

  group('the day bet', () {
    // It is not an `active_games` game, so it cannot ride in `selected` and
    // for a while it was left out of this list entirely. The only way to turn
    // one off was then an action inside its own setup screen, under the Save
    // button — so a TD looking for a switch found none and reported that the
    // day bet could not be turned off. Shipped-and-unreachable, which is the
    // shape this codebase keeps hitting; these pin the switch's presence.
    Future<void> pump(WidgetTester t, {bool? on, bool wire = true}) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SideGamesPicker(
                selected: const {},
                onToggle: (_, __) {},
                dayBetOn: on,
                onDayBetToggle: wire ? (_) {} : null,
                dayBetNote: on == true ? '\$4 a golfer' : null,
              ),
            ),
          ),
        ));

    testWidgets('draws a card when the round can have one', (t) async {
      await pump(t, on: false);
      expect(find.text('Day bet'), findsOneWidget);
    });

    testWidgets('no card at all when the round cannot', (t) async {
      // Not the final round, or a one-round event. A struck row for something
      // that can never apply here would be worse than its absence.
      await pump(t, on: null);
      expect(find.text('Day bet'), findsNothing);
    });

    testWidgets('no card when the caller wired no handler', (t) async {
      // A switch that does nothing is worse than no switch.
      await pump(t, on: true, wire: false);
      expect(find.text('Day bet'), findsNothing);
    });

    testWidgets('the switch reflects whether it is set up', (t) async {
      await pump(t, on: true);
      final on = t.widgetList<Switch>(find.byType(Switch)).last;
      expect(on.value, isTrue);

      await pump(t, on: false);
      final off = t.widgetList<Switch>(find.byType(Switch)).last;
      expect(off.value, isFalse);
    });

    testWidgets('it is last, after every game', (t) async {
      await pump(t, on: false);
      final games = perRoundSideGames(multiFoursome: true);
      final lastGameY = t.getTopLeft(find.text(games.last.displayName)).dy;
      expect(t.getTopLeft(find.text('Day bet')).dy,
          greaterThan(lastGameY),
          reason: 'the day bet is the odd one — it goes at the end');
    });
  });
}
