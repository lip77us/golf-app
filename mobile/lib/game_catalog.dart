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
  static const String sixes      = 'sixes';
  static const String points531  = 'points_531';
  static const String nassau     = 'nassau';
  /// Las Vegas — 2v2 team game; each team's two net scores form a number
  /// (low=tens, high=ones), lower number wins by the difference.  Owns the
  /// 2-digit scoring model, so it's mutually exclusive with the other games.
  static const String vegas      = 'vegas';
  /// Fourball — a 4-player 2v2 best-ball match-play game over 18 holes.
  /// Two fixed teams of two; the better of each team's two net/gross balls
  /// wins the hole; the match is decided by holes up/down (dormie, "3&2")
  /// and a single match bet.  Owns the foursome's match structure, so it's
  /// mutually exclusive with the other casual games.
  static const String fourball   = 'fourball';
  /// UI-only shortcut: an "18-Hole Match" — a Nassau with only the Overall bet.
  /// Translated to `nassau` (Overall-only) when the round is created.
  static const String match18    = 'match_18';
  static const String skins      = 'skins';
  static const String spots      = 'spots';
  static const String multiSkins = 'multi_skins';
  static const String tripleCup  = 'triple_cup';
  /// Wolf — 3- or 4-player rotating-wolf game.  Each hole one player is the
  /// Wolf (a rotation the group sets), tees last, then takes a partner
  /// (4-player only), goes Lone Wolf, or Blind Wolf.  Owns its own
  /// per-hole decision + score-entry screen, so it's mutually exclusive
  /// with the other casual games.
  static const String wolf       = 'wolf';
  /// Rabbit — 3-player "catch the rabbit" game.  First to win a hole
  /// outright catches it and runs ahead; held until beaten.  Owns its own
  /// per-hole score-entry screen, so mutually exclusive with other games.
  static const String rabbit     = 'rabbit';
  /// Match Play single-elimination bracket — 4-person foursome plays
  /// two 9-hole semi-finals on holes 1–9, then Final + 3rd-place
  /// consolation on holes 10–18.  Casual + tournament side game.
  static const String matchPlay  = 'match_play';
  /// 3-player tournament foursome.  Phase 1 (holes 1–9) = Points 5-3-1
  /// to seed.  Phase 2 (holes 10–18) = 1v1 match play between the top
  /// two finishers, with documented tie-break rules.
  static const String threePersonMatch = 'three_person_match';

  // Casual + Tournament (can accumulate across days)
  static const String strokePlay  = 'low_net_round'; // display: "Stroke Play"
  static const String stableford  = 'stableford';

  // Tournament-only, multi-foursome
  static const String irishRumble    = 'irish_rumble';
  // Cup singles formats — two 1v1 matches per foursome.
  // singlesNassau: each match has F9/B9/Overall (pv × 6/foursome).
  // singles18:     each match is 18-hole overall only  (pv × 2/foursome).
  static const String singlesNassau  = 'singles_nassau';
  static const String singles18      = 'singles_18';
  static const String pinkBall    = 'pink_ball';
  static const String scramble    = 'scramble';

  // Tournament-level championship game IDs (sent to createTournament).
  // These accumulate totals across rounds rather than being per-round games.
  // Match Play is NOT here — it runs per-round like Irish Rumble, not as a
  // cross-day accumulator.
  static const String championshipStrokePlay  = 'low_net';
  static const String championshipStableford  = 'stableford_championship';

  // Team Cup (Ryder Cup style).  Stored in tournament.active_games so the
  // tournament list screen can detect it and show cup-specific buttons.
  // Not a per-round game — the cup layer sits on top of regular games.
  static const String teamCup = 'team_cup';
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

  /// Explicit set of supported player counts (e.g. Nassau = {2, 4}, which
  /// min/max can't express). Overrides exact/min/max when non-null.
  final Set<int>? sizes;

  /// A game played ACROSS multiple foursomes/groups (e.g. Multi-Group Skins).
  /// Surfaced under the "Across foursomes" group-size filter rather than 2/3/4.
  final bool acrossGroups;

  /// IDs of games that cannot be active simultaneously with this one.
  /// Exclusion is enforced symmetrically — if A excludes B, B also excludes A.
  /// (Used by the TOURNAMENT picker. Casual rounds use the primary/side-game
  /// model below instead — see [canBeSideGame] / [allowsSideGames].)
  final Set<String> excludes;

  /// CASUAL model: this game can be added as a SECONDARY "side game" — a pure
  /// leaderboard overlay computed from the entered scores, with no effect on
  /// the score-entry screen. Side games only appear as leaderboard tabs.
  final bool canBeSideGame;

  /// CASUAL model: when this game is the PRIMARY, the user may add side games
  /// alongside it. False for games that own the whole round structure
  /// (Sixes / Vegas / Nassau / Triple Cup / Multi-Group Skins).
  final bool allowsSideGames;

  /// CASUAL model: a "capture add-on" side game that needs a per-hole manual
  /// input in score entry (it can't be derived from gross scores). Unlike a
  /// pure overlay (Skins/Stableford), its capture widget renders in score
  /// entry even though it isn't the primary. (Spots; later Snake.)
  final bool capturesInScoreEntry;

  /// CASUAL model: this game is ONLY ever an add-on — never offered as the
  /// primary. (Spots/Snake: a pure side bet with no main game of its own.)
  /// Skins/Stableford/Low Net are NOT side-game-only — they can be a primary too.
  final bool sideGameOnly;

  /// TOURNAMENT model: a Cup-only match format (the two 1v1 cup-singles formats).
  /// These are configured through the cup-design step, not as generic per-round
  /// side games, so they're excluded from [tournamentRoundGames].
  final bool cupOnly;

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
    this.sizes,
    this.acrossGroups         = false,
    this.excludes             = const {},
    this.canBeSideGame        = false,
    this.allowsSideGames      = true,
    this.capturesInScoreEntry = false,
    this.sideGameOnly         = false,
    this.cupOnly              = false,
  });

  /// True if this game can be played with exactly [n] real players.
  bool supportsSize(int n) {
    if (sizes != null)        return sizes!.contains(n);
    if (exactPlayers != null) return n == exactPlayers;
    if (minPlayers != null && n < minPlayers!) return false;
    if (maxPlayers != null && n > maxPlayers!) return false;
    return true;
  }
}

// ── Full catalogue ────────────────────────────────────────────────────────────

const List<GameMeta> kGameCatalog = [
  // ── Casual-only ───────────────────────────────────────────────────────────

  GameMeta(
    id           : GameIds.sixes,
    displayName  : 'Sixes',
    casual       : true,
    exactPlayers : 4,
    // Sixes owns the foursome's rotating-team structure — no side games.
    allowsSideGames: false,
    // Sixes owns its own handicap allocation (per-segment SO spreading) and
    // cannot be combined with any other game — the stroke colors and
    // calculations would conflict.
    excludes     : {GameIds.nassau, GameIds.points531,
                    GameIds.skins, GameIds.strokePlay, GameIds.stableford},
  ),
  GameMeta(
    id           : GameIds.vegas,
    displayName  : 'Las Vegas',
    casual       : true,
    exactPlayers : 4,
    allowsSideGames: false,
    // Vegas owns the 2-digit team-number scoring model for the whole
    // foursome, so it can't share the entry flow with another game.
    excludes     : {GameIds.sixes, GameIds.nassau, GameIds.points531,
                    GameIds.skins, GameIds.strokePlay, GameIds.stableford,
                    GameIds.match18},
  ),
  GameMeta(
    id           : GameIds.fourball,
    displayName  : 'Fourball',
    casual       : true,
    exactPlayers : 4,
    // A single 18-hole 2v2 best-ball match owns the foursome's match
    // structure, so — like Sixes / Vegas / Triple Cup — it can't share the
    // entry flow with another game.  Exclusion is symmetric (gamesCompatible
    // checks both sides), so listing the peers here is sufficient.
    excludes     : {GameIds.sixes, GameIds.vegas, GameIds.nassau,
                    GameIds.points531, GameIds.skins, GameIds.match18,
                    GameIds.strokePlay, GameIds.stableford, GameIds.tripleCup,
                    GameIds.matchPlay, GameIds.threePersonMatch,
                    GameIds.wolf, GameIds.rabbit},
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
    // Owns the F9/B9/Overall team-bet structure — no side games.
    allowsSideGames: false,
    // Heads-up (2) or 2-v-2 best-ball (4) — three players doesn't form sides.
    minPlayers  : 2,
    maxPlayers  : 4,
    sizes       : {2, 4},
    // Nassau and Sixes are mutually exclusive (both are team-bet games that
    // own the front-9 / back-9 structure).  Skins can run alongside Nassau.
    excludes    : {GameIds.sixes, GameIds.points531},
  ),
  GameMeta(
    id          : GameIds.match18,
    displayName : 'Singles Match',
    casual      : true,
    // A straight heads-up 18-hole match — runs on Nassau (Overall bet only).
    sizes       : {2},
    excludes    : {GameIds.nassau, GameIds.sixes, GameIds.points531},
  ),
  GameMeta(
    id          : GameIds.skins,
    displayName : 'Skins',
    casual      : true,
    minPlayers  : 2,
    maxPlayers  : 4,
    // Skins is a pure scoring overlay — usable as a leaderboard-only side game
    // (no junk in that mode, since junk is entered hole-by-hole).
    canBeSideGame: true,
    // Skins CAN combine with Nassau or Sixes.  Only Points 5-3-1 is excluded
    // because it completely owns the three-player entry model.  Spots is
    // excluded too — Skins has its own per-hole extras (junk).
    excludes    : {GameIds.points531, GameIds.spots},
  ),
  GameMeta(
    id          : GameIds.spots,
    displayName : 'Spots',
    casual      : true,
    minPlayers  : 2,
    maxPlayers  : 4,
    // A capture add-on: a separate-payout side game whose per-hole tallies are
    // entered by hand in score entry (one-putt, sandy, barky, …).
    canBeSideGame       : true,
    capturesInScoreEntry: true,
    sideGameOnly        : true,   // never a primary — always an add-on
    // Excludes Skins (junk is the Skins way), and the team/round-wide games we
    // deliberately don't host Spots on (Vegas, Triple Cup, Multi-Skins).
    excludes    : {GameIds.skins, GameIds.vegas, GameIds.tripleCup,
                   GameIds.multiSkins},
  ),
  GameMeta(
    id          : GameIds.wolf,
    displayName : 'Wolf',
    casual      : true,
    minPlayers  : 3,
    maxPlayers  : 4,
    // Wolf owns its own per-hole decision + score-entry screen (who's the
    // Wolf, partner/lone/blind), so — like Points 5-3-1 — it can't share a
    // foursome's entry flow with another per-foursome game.
    excludes    : {GameIds.sixes, GameIds.points531, GameIds.nassau,
                   GameIds.skins, GameIds.strokePlay, GameIds.stableford,
                   GameIds.tripleCup, GameIds.matchPlay,
                   GameIds.threePersonMatch},
  ),
  GameMeta(
    id          : GameIds.rabbit,
    displayName : 'Rabbit',
    casual      : true,
    exactPlayers: 3,
    // Rabbit owns its own per-hole score-entry screen, so — like Points
    // 5-3-1 — it can't share a foursome's entry flow with another game.
    excludes    : {GameIds.sixes, GameIds.points531, GameIds.nassau,
                   GameIds.skins, GameIds.wolf, GameIds.strokePlay,
                   GameIds.stableford, GameIds.tripleCup, GameIds.matchPlay,
                   GameIds.threePersonMatch},
  ),
  GameMeta(
    id           : GameIds.tripleCup,
    displayName  : 'One-Round Triple Cup',
    casual       : true,
    // Owns the foursome's 3-segment match structure — no side games.
    allowsSideGames: false,
    // Casual requires exactly 4 — 2v1 needs cross-foursome donors (cup
    // only) and 1v1 lacks the fourball/foursomes-match structure that
    // makes Triple Cup interesting.  Cup-mode 3-player foursomes go
    // through the cup wizard, which doesn't consult this rule.
    exactPlayers : 4,
    // Triple Cup owns the foursome's match structure (3 segments × match
    // play), so it can't combine with Nassau / Sixes / Points / Skins.
    excludes     : {GameIds.nassau, GameIds.sixes, GameIds.points531,
                    GameIds.skins,  GameIds.strokePlay, GameIds.stableford,
                    GameIds.matchPlay, GameIds.threePersonMatch},
  ),
  GameMeta(
    id           : GameIds.matchPlay,
    displayName  : 'Mini Singles Bracket',
    // Single user-facing pick that auto-dispatches per foursome:
    //   4-player groups → single-elimination bracket (two semis on
    //                     holes 1–9, Final + 3rd-place on holes 10–18).
    //   3-player groups → Three-Person Match (Points 5-3-1 phase 1 on
    //                     holes 1–9, 1v1 match play between top two on
    //                     holes 10–18, tie-break rules per service).
    // Available as both a casual single-foursome game (3 or 4 players)
    // and a per-foursome tournament side game alongside Stroke Play.
    casual       : true,
    tournament   : true,
    minPlayers   : 3,
    maxPlayers   : 4,
    // Match Play owns the foursome's 9-hole match structure so it can't
    // combine with games that own the same hole ranges.  Skins and
    // Nassau read the same per-hole gross scores independently and so
    // can coexist; gross/stroke-play accumulators do too.
    excludes     : {GameIds.sixes, GameIds.points531, GameIds.tripleCup},
  ),
  GameMeta(
    id           : GameIds.threePersonMatch,
    displayName  : 'Three-Person Match',
    // Not directly selectable — the system reaches the 3-person variant
    // via Match Play when a foursome has 3 real players.  Kept in the
    // catalog so gameDisplayName() resolves the slug (for leaderboards,
    // breadcrumbs, etc.) and so excludes references resolve.
    enabled      : false,
    tournament   : true,
    exactPlayers : 3,
    excludes     : {GameIds.sixes, GameIds.points531, GameIds.nassau,
                    GameIds.skins, GameIds.tripleCup, GameIds.matchPlay,
                    GameIds.strokePlay, GameIds.stableford},
  ),
  GameMeta(
    id          : GameIds.multiSkins,
    displayName : 'Multi-Group Skins',
    casual      : true,
    // A round-wide pool is its own thing — no per-foursome side games.
    // (Using it AS a side game on another primary needs cross-group score
    // linkage, which is deferred.)
    allowsSideGames: false,
    // Round-level pool that crosses foursomes.  Needs at least 2 participants;
    // there's no upper limit — the round may have any number of groups.
    minPlayers  : 2,
    acrossGroups: true,
    // Multi-Group Skins is the only multi-foursome game in the casual flow;
    // mutually exclusive with other multi-foursome games as they're added.
    // It CAN combine with per-foursome side games (sixes / nassau / points
    // / single-foursome skins) which run independently inside each group.
    excludes    : const {},
  ),

  // ── Casual + Tournament ───────────────────────────────────────────────────

  GameMeta(
    id           : GameIds.strokePlay,
    displayName  : 'Stroke Play',
    casual       : true,
    tournament   : true,
    canBePrimary : true,
    minPlayers   : 2,
    // Pure scoring overlay (low net / low gross) — also usable as a
    // leaderboard-only side game alongside another primary.
    canBeSideGame: true,
    // Stroke Play can combine with any per-foursome side game.
    excludes     : {GameIds.points531},
  ),
  GameMeta(
    id           : GameIds.stableford,
    displayName  : 'Stableford',
    // Casual Stableford is live (editable points table + Low-Net-style money).
    // Tournament-side use is the separate `stableford_championship` entry in
    // kChampionshipGames (still deferred — casual first).
    casual       : true,
    tournament   : false,
    canBePrimary : false,
    enabled      : true,
    minPlayers   : 2,
    // Pure scoring overlay — usable as a leaderboard-only side game.
    canBeSideGame: true,
    excludes     : {GameIds.points531},
  ),

  // ── Tournament-only ───────────────────────────────────────────────────────

  GameMeta(
    id          : GameIds.singlesNassau,
    displayName : 'Singles Nassau',
    tournament  : true,
    cupOnly     : true,   // configured via the cup-design step, not a side game
    exactPlayers: 4,
  ),
  GameMeta(
    id          : GameIds.singles18,
    displayName : '18-Hole Singles',
    tournament  : true,
    cupOnly     : true,   // configured via the cup-design step, not a side game
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

/// Display labels for slugs that aren't in [kGameCatalog] (catalog is for
/// picker-eligible games only).  Sourced from the Django GameType enum where
/// available; cup-specific aliases (cup_singles, cup_singles_18) live here.
const Map<String, String> _kExtraGameLabels = {
  'quota_nassau'           : 'Quota Nassau',
  'cup_singles'            : 'Singles-Nassau',
  'cup_singles_18'         : 'Singles-18',
  // Hidden from the picker (see kChampionshipGames) but kept here so existing
  // tournaments using it still display a friendly name rather than the slug.
  'stableford_championship': 'Stableford Championship',
};

/// Display name for [gameId], falling back to the raw ID if unknown.
/// Single source of truth for every chip, badge, page title, and leaderboard
/// tab — picker games come from [kGameCatalog], other slugs from
/// [_kExtraGameLabels].
String gameDisplayName(String gameId) =>
    _kGameById[gameId]?.displayName
    ?? _kExtraGameLabels[gameId]
    ?? gameId;

/// Joined display label for a round's [activeGames]. An Overall-only Nassau is
/// stored as `nassau` but is really the "18-Hole Match" shortcut, so when
/// [isEighteenHoleMatch] is set we show that name instead of the generic
/// "Nassau".
String gamesDisplayLabel(Iterable<String> activeGames,
        {bool isEighteenHoleMatch = false}) =>
    activeGames
        .map((g) => (g == GameIds.nassau && isEighteenHoleMatch)
            ? gameDisplayName(GameIds.match18)
            : gameDisplayName(g))
        .join(' • ');

/// Games shown in the casual-round picker (enabled only).
List<GameMeta> get casualGames =>
    kGameCatalog.where((g) => g.casual && g.enabled).toList();

/// Games shown in the per-round side-game picker inside the tournament wizard
/// (enabled only).  Cup-only match formats (Singles Nassau / 18-Hole Singles)
/// are excluded — they're configured through the cup-design step, not as generic
/// side games, so they only make sense in a Cup tournament.
List<GameMeta> get tournamentRoundGames =>
    kGameCatalog.where((g) => g.tournament && g.enabled && !g.cupOnly).toList();

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
  (GameIds.teamCup,                'Team (Cup) Play'),
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

// ── Casual primary / side-game model ──────────────────────────────────────────

/// True if [gameId] can be added as a secondary "side game" (leaderboard-only
/// overlay) in a casual round.
bool canBeSideGame(String gameId) => _kGameById[gameId]?.canBeSideGame ?? false;

/// True if, when [gameId] is the PRIMARY casual game, the user may add side
/// games alongside it.
bool allowsSideGames(String gameId) =>
    _kGameById[gameId]?.allowsSideGames ?? true;

/// Priority order used to pick the primary when a casual round contains only
/// side-game-eligible games (e.g. a Skins-only or Stableford-only round).
const List<String> _kSidePrimaryPriority = [
  GameIds.skins,
  GameIds.stableford,
  GameIds.strokePlay,
  GameIds.multiSkins,
];

/// The PRIMARY game in a casual round's active-games set — the one that owns
/// the score-entry experience. It's the first active game that is NOT a
/// side-game type; if every active game is side-game-eligible (e.g. a
/// Skins-only round), it's the highest-priority one. Returns null for an
/// empty set.
String? primaryGameOf(Iterable<String> active) {
  final list = active.toList();
  if (list.isEmpty) return null;
  bool sideOnly(String g) => _kGameById[g]?.sideGameOnly ?? false;
  // Prefer an entry-owning game (not side-game-eligible). A side-game-only
  // add-on (Spots) is never a primary.
  for (final g in list) {
    if (!canBeSideGame(g) && !sideOnly(g)) return g;
  }
  // All side-game types — pick by priority, else the first non-add-on.
  for (final p in _kSidePrimaryPriority) {
    if (list.contains(p)) return p;
  }
  return list.firstWhere((g) => !sideOnly(g), orElse: () => list.first);
}

/// The side games selectable alongside [primaryId] for a [size]-player round.
///
/// Overlay accumulators (Skins/Stableford/Low Net) are offered only when the
/// primary `allowsSideGames`. A CAPTURE add-on (Spots — `capturesInScoreEntry`)
/// is orthogonal to the main game's scoring, so it's offered even on a
/// structure-owning primary that disallows overlays (Sixes/Nassau) — gated only
/// by the per-game `excludes` (e.g. Spots excludes Vegas / Triple Cup).
List<GameMeta> sideGamesFor(String primaryId,
    {required int size, bool multiGroup = false}) {
  final allowOverlays = allowsSideGames(primaryId);
  return kGameCatalog.where((g) {
    if (!g.enabled || !g.canBeSideGame) return false;
    if (g.id == primaryId) return false;
    // Honor mutual exclusion vs the primary (e.g. Spots ⊥ Skins / Vegas).
    if (!gamesCompatible(primaryId, g.id)) return false;
    // Structure-owning primaries still accept capture add-ons, but not overlays.
    if (!allowOverlays && !g.capturesInScoreEntry) return false;
    if (g.acrossGroups) return multiGroup;     // round-wide pools only in multi-group
    return g.supportsSize(size);
  }).toList();
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
