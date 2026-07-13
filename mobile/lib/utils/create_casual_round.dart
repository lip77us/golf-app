/// utils/create_casual_round.dart
/// -------------------------------
/// Shared casual-round creation path: build a standalone round, set up its
/// foursome(s), preload it into [RoundProvider], and work out where to send
/// the user next (the per-game setup screen, or the /round hub for combos).
///
/// Both [CasualRoundScreen] (the full picker) and [OnboardingWizard] (the
/// guided first-run flow) call this so the create + route-dispatch logic can't
/// drift between them.

import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/round_provider.dart';

/// Result of creating + setting up a casual round, plus where to route next.
class CasualRoundLaunch {
  final Round round;
  final Foursome? firstFoursome;

  /// Direct route to the single game's setup screen (e.g. '/skins-setup'), or
  /// null for a multi-game combo where the user should land on the /round hub.
  final String? route;
  final Object? args;

  const CasualRoundLaunch({
    required this.round,
    required this.firstFoursome,
    required this.route,
    required this.args,
  });

  /// Where to navigate — falls back to the /round hub when there's no single
  /// game to drop straight into.
  String get effectiveRoute => route ?? '/round';
  Object get effectiveArgs => args ?? round.id;
}

/// Direct game-setup route for a single-game casual round.  Returns
/// (null, null) for multi-game combos (caller falls back to the /round hub).
///
/// [activeGames] is the ORIGINAL selection (still carrying the `match_18`
/// shortcut); the round itself is created with `match_18` translated to
/// `nassau`, but the route dispatch keys off the user's pick.
(String?, Object?) casualGameRoute(
  Set<String> activeGames,
  Round round,
  Foursome? firstFs, {
  String? primaryGame,
}) {
  if (firstFs == null) return (null, null);
  // Route to the PRIMARY game's setup — side games are configured later from
  // the /round hub and don't drive entry.  Honor the user's explicit pick
  // (primaryGame) over the derived one, since a two-overlay set like
  // {low_net_round, skins} can't be disambiguated from the flat set alone.
  final primary = resolvePrimary(primaryGame, activeGames);
  if (primary == null) return (null, null);
  // returnToHub: after configuring, land on the /round launch page (Enter
  // Scores / Edit Tee Boxes / Edit Configuration) instead of jumping straight
  // into score entry.  Per-foursome games key off the foursome id, round-level
  // games off the round id.
  Object fsArg() => {'id': firstFs.id, 'returnToHub': true};
  Object roundArg() => {'id': round.id, 'returnToHub': true};
  switch (primary) {
    case GameIds.sixes:
      return ('/sixes-setup', fsArg());
    case GameIds.points531:
      return ('/points-531-setup', fsArg());
    case GameIds.vegas:
      return ('/vegas-setup', fsArg());
    case GameIds.fourball:
      return ('/fourball-setup', fsArg());
    case GameIds.skins:
      return ('/skins-setup', fsArg());
    case GameIds.wolf:
      return ('/wolf-setup', fsArg());
    case GameIds.rabbit:
      return ('/rabbit-setup', fsArg());
    case GameIds.tripleCup:
      return ('/triple-cup-setup', fsArg());
    case GameIds.multiSkins:
      return ('/multi-skins-setup', roundArg());
    case GameIds.nassau:
      return ('/nassau-setup', fsArg());
    case GameIds.match18:
      return ('/nassau-setup-18', fsArg()); // Overall-only Nassau
    case GameIds.nassauNine:
      return ('/nassau-nine-setup', fsArg()); // single match over played holes
    case GameIds.strokePlay:
      return ('/low-net-setup', roundArg());
    case GameIds.stableford:
      return ('/stableford-setup', roundArg());
    case GameIds.matchPlay:
      // Match Play auto-dispatches by foursome size: 3 → Three-Person Match,
      // 4 → single-elimination bracket.
      final realCount = firstFs.realPlayers.length;
      return (
        realCount == 3 ? '/three-person-match-setup' : '/match-play-setup',
        fsArg(),
      );
    default:
      return (null, null);
  }
}

/// Creates a standalone casual round, sets up its foursome(s) with the given
/// per-player tees, preloads it into [roundProvider], and returns where to
/// route next.
///
/// [playerGroups] is consulted only for Multi-Group Skins (passes an explicit
/// `group_number` per player so the server respects the user's groups).
Future<CasualRoundLaunch> createCasualRound({
  required ApiClient client,
  required RoundProvider roundProvider,
  required int courseId,
  required Map<int, int> playerTees,
  required Set<String> activeGames,
  String? primaryGame,
  Map<int, int>? playerGroups,
  int numHoles = 18,
  int startingHole = 1,
}) async {
  final multiGroup = activeGames.contains(GameIds.multiSkins);
  final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

  // match_18 (Singles Match) is now its OWN slug + game_type, so it can coexist
  // with a team Nassau in the same round (the "Larry case").
  final storedPrimary = primaryGame;

  final round = await client.createRound(
    courseId: courseId,
    date: dateStr,
    activeGames: activeGames.toList(),
    primaryGame: storedPrimary,
    numHoles: numHoles,
    startingHole: startingHole,
  );

  final playersSetup = playerTees.entries.map((e) {
    final entry = <String, int>{'player_id': e.key, 'tee_id': e.value};
    if (multiGroup) entry['group_number'] = playerGroups?[e.key] ?? 1;
    return entry;
  }).toList();

  final fullRound = await client.setupRound(
    round.id,
    players: playersSetup,
    // Don't randomise in multi-group mode — the user picked the groups.
    randomise: !multiGroup,
    autoSetupGames: false,
  );

  await roundProvider.loadRound(fullRound.id);

  final firstFs =
      fullRound.foursomes.isNotEmpty ? fullRound.foursomes.first : null;
  // Pass the ORIGINAL pick (still carrying the match_18 shortcut) so the route
  // dispatch keys off it, matching how activeGames is passed here.
  final (route, args) =
      casualGameRoute(activeGames, fullRound, firstFs, primaryGame: primaryGame);

  return CasualRoundLaunch(
    round: fullRound,
    firstFoursome: firstFs,
    route: route,
    args: args,
  );
}

/// Default tee id for a player at [courseId]: the lowest-priority tee that
/// matches the player's [sex] (or is unisex), sorted by (priority, name).
/// Returns null when no tee matches (an unseeded course — shouldn't happen for
/// catalog courses).
int? defaultTeeIdFor(List<TeeInfo> tees, int courseId, String sex) {
  final matching = tees
      .where((t) => t.course.id == courseId && (t.sex == null || t.sex == sex))
      .toList()
    ..sort((a, b) {
      final pc = a.sortPriority.compareTo(b.sortPriority);
      return pc != 0 ? pc : a.teeName.compareTo(b.teeName);
    });
  return matching.isEmpty ? null : matching.first.id;
}
