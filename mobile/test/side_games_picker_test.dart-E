/// The per-round side games, and the scopes they must not be confused with.
///
/// Round 1's games were chosen by seven hardcoded cards in the tournament
/// wizard while every later round drew bare chips from the catalog, so the
/// two lists drifted in BOTH directions — the wizard never offered Stroke
/// Play or Hot Spot, and the chips never carried the blurb. These pin the one
/// list, and the two games that are deliberately not on it.
import 'dart:io';

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
    //
    // It is an ORDINARY switch: moved here, saved on Save, fee and prizes set
    // from the round's Configure button. The one difference is where it
    // appears — the final round of a multi-round event and nowhere else —
    // which is `dayBetOn == null` everywhere else.
    Future<void> pump(WidgetTester t, {bool? on, bool wire = true}) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SideGamesPicker(
                selected: const {},
                onToggle: (_, __) {},
                dayBetOn: on,
                onDayBetToggle: wire ? (_) {} : null,
                dayBetNote: on == true ? '\$4 a golfer, \$20 to the winner.' : null,
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

    testWidgets('it is drawn by the same card as the games', (t) async {
      // Not markup of its own: `_SideGameCard` takes its copy as strings
      // rather than a GameMeta precisely so the day bet — which has no
      // catalog entry — cannot come to look different from the games it sits
      // under.
      await pump(t, on: true);
      final games = perRoundSideGames(multiFoursome: true);
      expect(find.byType(Switch), findsNWidgets(games.length + 1));
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

  group('every caller offers the day bet', () {
    // The day bet was wired into the standalone side-games screen and NOT
    // into the setup wizard, which draws the same picker — so a TD going
    // through Edit Groups, which is how he reaches round 2, never saw it.
    // Reported exactly that way.
    //
    // `dayBetOn == null` means "no card", and that is also what a caller
    // that simply forgot looks like. There is no runtime difference between
    // declining to offer it and not knowing you could, which is why this is
    // checked at the source.
    //
    // The tournament wizard is the one exception and says so below.
    const exempt = {
      // Draws its own `_GameFeeCard` with the fee and the payout table
      // inline, which is right where the round does not exist yet — the
      // picker's card would be a second day bet control on one screen.
      'new_round_wizard.dart',
    };

    test('a caller either passes dayBetOn or is a named exception', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        final i = src.indexOf('SideGamesPicker(');
        if (i < 0) continue;
        final name = f.uri.pathSegments.last;
        if (name == 'side_games_picker.dart') continue;   // the widget itself
        if (exempt.contains(name)) continue;
        // The argument list of that call — far enough to cover it.
        final call = src.substring(i, (i + 900).clamp(0, src.length));
        if (!call.contains('dayBetOn')) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: 'These draw the side games and never offer the day bet, so '
              'it is invisible on the final round from that screen:\n'
              '  ${offenders.join('\n  ')}\n'
              'Pass dayBetOn/onDayBetToggle, or add the file to `exempt` '
              'with the reason.');
    });

    test('the exemption list names files that exist', () {
      // An exemption for a file that has been renamed is an exemption for
      // nothing, and it would hide the next miss.
      for (final name in exempt) {
        final found = Directory('lib').listSync(recursive: true).any(
            (f) => f is File && f.uri.pathSegments.last == name);
        expect(found, isTrue, reason: '$name is exempt but does not exist');
      }
    });
  });
}
