/// utils/round_leaderboard_route.dart
///
/// Where a round's board lives — asked once, answered once.
///
/// **A Foursome Play round carries no round-level games.** Its board is the
/// tournament's own six-row team table, not the generic round leaderboard:
/// that one builds its tabs from the round's games, finds none, falls through
/// to the championship view and draws *"No championship games configured."*
/// over an event that is configured perfectly well.
///
/// Reported from a finished scramble, 30 Oct 2026: *"the leaderboard went away
/// when I completed the round."* The hub already had a helper for this whose
/// docstring said **"Both entry points on this hub go through here so they
/// cannot disagree"** — and there were THREE. The completion handler lives in
/// a separate widget that holds only a round id, so it could not reach the
/// helper and pushed `/leaderboard` by hand.
///
/// So the decision moved out of the screen and takes FACTS rather than a round
/// object, which is what lets every caller use it — including one that never
/// had the round. A screen-private helper is only shared by the call sites
/// that happen to be in that screen.
library;

/// The named route and arguments for [roundId]'s leaderboard.
({String route, Object? arguments}) roundLeaderboardRoute({
  required int roundId,
  required bool isTeamPlayRound,
  required int? tournamentId,
}) {
  // `tournamentId` is required as well as the flag: the team board is keyed on
  // the tournament, so a team-play round that somehow carries no tournament id
  // has no board to send anyone to and falls back rather than pushing a route
  // that would open empty.
  if (isTeamPlayRound && tournamentId != null) {
    return (
      route: '/team-play-leaderboard',
      // The name is looked up by the board itself; the hub does not hold one.
      arguments: {'tournamentId': tournamentId, 'tournamentName': ''},
    );
  }
  return (route: '/leaderboard', arguments: roundId);
}
