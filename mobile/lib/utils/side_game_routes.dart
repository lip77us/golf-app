/// utils/side_game_routes.dart
/// ---------------------------
/// Where a side game is configured. Lived privately in `round_screen.dart`
/// for the hub's "Add side game" flow; Annandale Friday's third setup step
/// opens the same screens, and two tables of one mapping is how a side game
/// ends up configurable from one place and not the other.
library;

import '../game_catalog.dart';

/// Setup route + args for a side game added from the hub.  Per-foursome games
/// take the foursome id; round-level games (Stroke Play / Stableford) take the
/// round id.  match_18 is configured through the Nassau setup (overall-only).
(String, Map<String, dynamic>)? sideGameSetupRoute(
    String game, int foursomeId, int roundId) {
  switch (game) {
    case GameIds.skins:
      return ('/skins-setup', {'id': foursomeId, 'returnToHub': true});
    case GameIds.nassau:
      return ('/nassau-setup', {'id': foursomeId, 'returnToHub': true});
    case GameIds.match18:
      // Singles Match = Overall-only Nassau; its own route sets game_type.
      return ('/nassau-setup-18', {'id': foursomeId, 'returnToHub': true});
    case GameIds.spots:
      return ('/spots-setup', {'id': foursomeId, 'returnToHub': true});
    case GameIds.honors:
      return ('/honors-setup', {'id': foursomeId, 'returnToHub': true});
    case GameIds.stableford:
      return ('/stableford-setup', {'id': roundId, 'returnToHub': true});
    case GameIds.strokePlay:
      return ('/low-net-setup', {'id': roundId, 'returnToHub': true});
  }
  return null;
}

