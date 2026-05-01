/// game_catalog.dart
/// -----------------
/// Single source of truth for every game type in the app:
/// display names, availability rules (casual vs tournament),
/// player-count requirements, and mutual-exclusion constraints.
///
/// All pickers — CasualRoundScreen, NewRoundWizard, _GameSelectionSheet —
/// should read from here instead of duplicating rules inline.

// ── Backend game-type identifiers ────────────────────────────────────────────
// These must match the string values of core.GameType on the Django side.

class GameIds {
  // Casual-only
  static const String sixes     = 'sixes';
  static const String points531 = 'points_531';
  static const String nassau    = 'nassau';
  static const String skins     = 'skins';

  // Casual + Tournament (can accumulate across days)
  static const String strokePlay  = 'low_net_round'; // display: "Stroke Play"
  static const String stableford  = 'stableford';

  // Tournament-only, multi-foursome
  static const String matchPlay   = 'match_play';
  static const String irishRumble = 'irish_rumble';
  static const String pinkBall    = 'pink_ball';
  static const String scramble    = 'scramble';

  // Tournament-level championship game IDs (sent to createTournament).
  // These accumulate totals across rounds rather than being per-round games.
  // Match Play is NOT here — it runs per-round like Irish Rumble, not as a
  // cross-day accumulator.
  static const String championshipStrokePlay  = 'low_net';
  static const String championshipStableford  = 'stableford_championship';
}

// ── Per-game metadata ─────────────────────────────────────────────────────────

class GameMeta {
  final String id;
  final String displayName;

  /// Appears in the casual-round (no tournament) picker.
  final bool casual;

  /// Appears in the tournament-round picker.
  final bool tournament;

  /// Accumulates totals across multiple rounds; required as primary game
  /// when a tournament spans more than one day.
  final bool canBePrimary;

  /// Cannot be selected unless the round has ≥ 2 foursomes.
  final bool requiresMultiFoursome;

  /// False = greyed out / not yet implemented.
  final bool enabled;

  /// Minimum number of real players required (null = no lower limit).
  final int? minPlayers;

  /// Maximum number of real players allowed (null = no upper limit).
  final int? maxPlayers;

  /// Exact player count required; overrides min/max when non-null.
  final int? exactPlayers;

  /// IDs of games that cannot be active simultaneously with this one.
  /// Exclusion is enforced symmetrically — if A excludes B, B also excludes A.
  final Set<String> excludes;

  const GameMeta({
    required this.id,
    required this.displayName,
    this.casual               = false,
    this.tournament           = false,
    this.canBePrimary         = false,
    this.requiresMultiFoursome = false,
    this.enabled              = true,
    this.minPlayers,
    this.maxPlayers,
    this.exactPlayers,
    this.excludes             = const {},
  });
}

// ── Full catalogue ────────────────────────────────────────────────────────────

const List<GameMeta> kGameCatalog = [
  // ── Casual-only ───────────────────────────────────────────────────────────

  GameMeta(
    id           : GameIds.sixes,
    displayName  : "Six's",
    casual       : true,
    exactPlayers : 4,
    // Sixes owns its own handicap allocation (per-segment SO spreading) and
    // cannot be combined with any other game — the stroke colors and
    // calculations would conflict.
    excludes     : {GameIds.nassau, GameIds.points531,
                    GameIds.skins, GameIds.strokePlay, GameIds.stableford},
  ),
  GameMeta(
    id           : GameIds.points531,
    displayName  : 'Points (5-3-1)',
    casual       : true,
    exactPlayers : 3,
    // Exclusive with everything: owns the hole-by-hole entry screen.
    excludes     : {GameIds.sixes, GameIds.nassau, GameIds.skins,
                    GameIds.strokePlay, GameIds.stableford},
  ),
  GameMeta(
    id          : GameIds.nassau,
    displayName : 'Nassau',
    casual      : true,
    minPlayers  : 2,
    maxPlayers  : 4,
    // Nassau and Six's are mutually exclusive (both are team-bet games that
    // own the front-9 / back-9 structure).  Skins can run alongside Nassau.
    excludes    : {GameIds.sixes, GameIds.points531},
  ),
  GameMeta(
    id          : GameIds.skins,
    displayName : 'Skins',
    casual      : true,
    minPlayers  : 2,
    maxPlayers  : 4,
    // Skins CAN combine with Nassau or Six's.  Only Points 5-3-1 is excluded
    // because it completely owns the three-player entry model.
    excludes    : {GameIds.points531},
  ),

  // ── Casual + Tournament ───────────────────────────────────────────────────

  GameMeta(
    id           : GameIds.strokePlay,
    displayName  : 'Stroke Play',
    casual       : true,
    tournament   : true,
    canBePrimary : true,
    minPlayers   : 2,
    // Stroke Play can combine with any per-foursome side game.
    excludes     : {GameIds.points531},
  ),
  GameMeta(
    id           : GameIds.stableford,
    displayName  : 'Stableford',
    casual       : true,
    tournament   : true,
    canBePrimary : true,
    minPlayers   : 2,
    excludes     : {GameIds.points531},
  ),

  // ── Tournament-only ───────────────────────────────────────────────────────

  GameMeta(
    id          : GameIds.matchPlay,
    displayName : 'Match Play',
    tournament  : true,
    exactPlayers: 4,
  ),
  GameMeta(
    id                   : GameIds.irishRumble,
    displayName          : 'Irish Rumble',
    tournament           : true,
    requiresMultiFoursome: true,
    minPlayers           : 2,
  ),
  GameMeta(
    id                   : GameIds.pinkBall,
    displayName          : 'Pink Ball',
    tournament           : true,
    requiresMultiFoursome: true,
    minPlayers           : 2,
  ),
  GameMeta(
    id                   : GameIds.scramble,
    displayName          : 'Scramble',
    tournament           : true,
    requiresMultiFoursome: true,
    enabled              : false,   // not yet implemented
  ),
];

// ── Lookup helpers ────────────────────────────────────────────────────────────

/// Look up metadata by game ID.  Returns null for unknown IDs.
GameMeta? gameMeta(String id) => _kGameById[id];

final Map<String, GameMeta> _kGameById = {
  for (final g in kGameCatalog) g.id: g,
};

/// Display name for [gameId], falling back to the raw ID if unknown.
String gameDisplayName(String gameId) =>
    _kGameById[gameId]?.displayName ?? gameId;

/// Games shown in the casual-round picker (enabled only).
List<GameMeta> get casualGames =>
    kGameCatalog.where((g) => g.casual && g.enabled).toList();

/// Games shown in the per-round game picker inside the tournament wizard
/// (enabled only).
List<GameMeta> get tournamentRoundGames =>
    kGameCatalog.where((g) => g.tournament && g.enabled).toList();

/// Games eligible as the primary accumulator for multi-day tournaments.
List<GameMeta> get primaryGames =>
    kGameCatalog.where((g) => g.canBePrimary && g.enabled).toList();

/// Championship (tournament-level) game options shown in Step 0 of the
/// wizard.  These accumulate totals across all rounds.
/// Match Play is intentionally excluded — it is a per-round side game
/// (like Irish Rumble) rather than a cross-day accumulator.
const List<(String, String)> kChampionshipGames = [
  (GameIds.championshipStrokePlay, 'Stroke Play Championship'),
  (GameIds.championshipStableford, 'Stableford Championship'),
];

// ── Combination logic ─────────────────────────────────────────────────────────

/// Returns true if [gameA] and [gameB] can be active simultaneously.
bool gamesCompatible(String gameA, String gameB) {
  if (gameA == gameB) return true;
  final a = _kGameById[gameA];
  final b = _kGameById[gameB];
  if (a == null || b == null) return true;
  return !a.excludes.contains(gameB) && !b.excludes.contains(gameA);
}

/// Returns the updated active-games set after toggling [gameId].
///
/// When [on] is true: adds [gameId] then removes every incompatible peer.
/// When [on] is false: removes [gameId] (the caller is responsible for the
/// "refuse to deselect the last game" guard).
Set<String> applyGameToggle(Set<String> current, String gameId, bool on) {
  final result = Set<String>.from(current);
  if (on) {
    result.add(gameId);
    result.removeWhere((g) => g != gameId && !gamesCompatible(gameId, g));
  } else {
    result.remove(gameId);
  }
  return result;
}
