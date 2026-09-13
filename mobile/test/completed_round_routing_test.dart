/// A finished round never opens a setup screen.
///
/// Reported from a completed Sixes match: "View Scorecard" landed on the
/// team-picker slot machine. The hub's Enter Scores / View Scorecard button
/// runs one routing chain, and fourteen of its branches can choose a `*-setup`
/// route — each asking only whether the game is CONFIGURED, none asking
/// whether the round is over.
///
/// On a live round that is right: an unconfigured game has to be set up before
/// it can be scored. On a finished one there is nothing to set up, the button
/// says View Scorecard, and drawing teams for a match already played and
/// settled is the one thing it must not offer.
///
/// The routing itself lives inside a closure in `round_screen.dart`, so this
/// pins the RULE rather than the widget: any route ending `-setup` is wrong
/// once the round is complete.
import 'package:flutter_test/flutter_test.dart';

/// Every setup destination the hub's chain can pick, read off round_screen.
const _setupRoutes = <String>[
  '/three-person-match-setup',
  '/match-play-setup',
  '/sixes-setup',
  '/points-531-setup',
  '/triple-nassau-setup',
  '/nassau-setup',
  '/nassau-setup-18',
  '/nassau-nine-setup',
  '/vegas-setup',
  '/fourball-setup',
  '/skins-setup',
  '/wolf-setup',
  '/rabbit-setup',
  '/survivor-setup',
  '/banker-setup',
  '/triple-cup-setup',
];

/// The guard as written in `round_screen.dart`.
/// `contains`, not `endsWith`: `/nassau-setup-18` ends in its hole count, and
/// a suffix test let the Singles Match picker through. No play route contains
/// `-setup`, so this cannot over-match — which the play-screen test pins.
String routeForCompleted(String route, {required bool isComplete}) =>
    isComplete && route.contains('-setup') ? '/score-entry' : route;

void main() {
  group('a completed round', () {
    test('never lands on a setup screen, whichever game it is', () {
      for (final r in _setupRoutes) {
        expect(routeForCompleted(r, isComplete: true), '/score-entry',
            reason: '$r is a setup screen and the round is over');
      }
    });

    test('the reported case: Sixes goes to the card, not the team picker', () {
      expect(routeForCompleted('/sixes-setup', isComplete: true),
          '/score-entry');
    });

    test('a play screen is left alone — it IS the card for that game', () {
      for (final r in ['/wolf', '/rabbit', '/survivor', '/banker',
                       '/triple-nassau', '/score-entry', '/nassau',
                       '/quota-nassau', '/pink-ball']) {
        expect(routeForCompleted(r, isComplete: true), r);
      }
    });
  });

  group('a live round is untouched', () {
    test('an unconfigured game still opens its setup screen', () {
      for (final r in _setupRoutes) {
        expect(routeForCompleted(r, isComplete: false), r,
            reason: 'a game has to be set up before it can be scored');
      }
    });
  });

  test('the guard keys off the SUFFIX, so a new game inherits it', () {
    // The next game added will get a branch written like the other fourteen.
    expect(routeForCompleted('/some-future-game-setup', isComplete: true),
        '/score-entry');
  });
}
