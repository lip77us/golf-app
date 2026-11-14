/// Which primary games New Round offers, and which one starts selected.
///
/// `handoff-game-selection-more-games`, confirmed 14 Nov 2026. The rules, in
/// the order they apply:
///
///  1. **Last game** — the primary of the golfer's most recent FINISHED round,
///     if it fits the group. It goes first.
///  2. **Most played** — then the games he has finished most often, among
///     those that fit; a tie goes to the more recently played. A round counts
///     whatever size the group was when it was played.
///  3. **Most likely** — any slot still open is filled from the default list
///     for the group size, skipping games already shown.
///
/// Four chips (three for Across groups), no game twice. Selected is the last
/// game if it fits, otherwise the first chip, so a primary is always chosen.
///
/// **Pure on purpose.** It takes the history as a list of game ids, newest
/// first, and a `fits` question, so the whole rule is testable without a
/// screen — and so the screen cannot grow a second copy of it.
///
/// "Fits" is the SCREEN's own filter (group size, partial rounds, side-game
/// only) rather than a re-derivation here: the catalog is the source of
/// truth for player ranges, and the handoff says so in as many words.
library;

import '../game_catalog.dart';

/// The Who's-playing key for Across groups (`'groups'`), solo (`'solo'`),
/// five or six ([kFiveOrSix]), or a plain count (`'2'`, `'3'`, `'4'`).
const String kAcrossGroupsKey = 'groups';

/// The games in the order they are offered, per group size — Paul's list of the
/// best-known games first (14 Nov 2026).
///
/// It does two jobs from one list, so they cannot drift apart: the first four
/// that fit fill any chip the history cannot (rule 3), and the All games sheet
/// shows the games that fit in this order, with anything it does not name after
/// them in catalog order.
///
/// A game the catalog says does not fit a size is skipped like any other, so
/// the list can be written as the golfer thinks of it and the registry still
/// has the last word on player ranges.
const Map<String, List<String>> kGameOrder = {
  'solo': [
    GameIds.soloStroke,
    GameIds.soloNassau,
    GameIds.soloMatch,
  ],
  '2': [
    GameIds.skins,
    GameIds.nassau,
    GameIds.nassauNine,
    GameIds.match18,
    GameIds.strokePlay,
    GameIds.stableford,
  ],
  '3': [
    GameIds.points531,
    GameIds.skins,
    GameIds.rabbit,
    GameIds.survivor,
    GameIds.wolf,
    GameIds.tripleNassau,
    GameIds.banker,
    GameIds.matchPlay,
    GameIds.match18,
    GameIds.strokePlay,
    GameIds.stableford,
  ],
  '4': [
    GameIds.skins,
    GameIds.nassau,
    GameIds.fourball,
    GameIds.sixes,
    GameIds.wolf,
    GameIds.sequoyaThrees,
    GameIds.vegas,
    GameIds.banker,
    GameIds.tripleCup,
    GameIds.matchPlay,
    GameIds.strokePlay,
    GameIds.stableford,
    GameIds.match18,
    GameIds.nassauNine,
  ],
  kFiveOrSix: [
    GameIds.annandaleFriday,
  ],
  kAcrossGroupsKey: [
    GameIds.multiSkins,
  ],
};

/// Where [gameId] sits in the list for [sizeKey]; games the list does not name
/// sort after it (by [fallback], so catalog order is kept among them).
int orderRank(String sizeKey, String gameId, int fallback) {
  final i = (kGameOrder[sizeKey] ?? const <String>[]).indexOf(gameId);
  return i >= 0 ? i : 1000 + fallback;
}

/// How many primary chips a group size shows. Across groups offers fewer
/// games than there is room for, so it shows three.
int chipCountFor(String sizeKey) => sizeKey == kAcrossGroupsKey ? 3 : 4;

class GameSuggestion {
  /// The chips, in order, never more than [chipCountFor].
  final List<String> chips;

  /// The game that starts selected, or null only when nothing fits at all.
  final String? selected;

  /// Why each chip is where it is, for the rules page's calculator and for
  /// tests. Never shown to a golfer.
  final Map<String, String> why;

  const GameSuggestion(this.chips, this.selected, this.why);
}

/// Work out the chips and the selection.
///
/// [history] is the primary game of each finished round, **newest first**.
/// [fits] answers whether a game is offered for this group. [sizeKey] picks
/// the default list and the chip count.
GameSuggestion suggestGames({
  required String sizeKey,
  required List<String> history,
  required bool Function(String gameId) fits,
}) {
  final cap = chipCountFor(sizeKey);
  final chips = <String>[];
  final why = <String, String>{};

  void add(String id, String reason) {
    if (chips.length >= cap || chips.contains(id) || !fits(id)) return;
    chips.add(id);
    why[id] = reason;
  }

  // Rule 1 — the last game.
  final last = history.isEmpty ? null : history.first;
  if (last != null) add(last, 'last game');

  // Rule 2 — most played. `history` is newest first, so the first time a
  // game is seen is its most recent play, which is the tie-break.
  final count = <String, int>{};
  final firstSeen = <String, int>{};
  for (var i = 0; i < history.length; i++) {
    final g = history[i];
    count[g] = (count[g] ?? 0) + 1;
    firstSeen.putIfAbsent(g, () => i);
  }
  final ranked = count.keys.where(fits).toList()
    ..sort((a, b) {
      final byCount = count[b]!.compareTo(count[a]!);
      return byCount != 0 ? byCount : firstSeen[a]!.compareTo(firstSeen[b]!);
    });
  for (final g in ranked) {
    add(g, 'played ${count[g]}×');
  }

  // Rule 3 — most likely.
  for (final g in kGameOrder[sizeKey] ?? const <String>[]) {
    add(g, 'most likely');
  }

  final selected = (last != null && fits(last))
      ? last
      : (chips.isEmpty ? null : chips.first);
  return GameSuggestion(chips, selected, why);
}

/// The chips with a sheet pick folded in.
///
/// A game chosen from the All games sheet that is not showing **takes the
/// fourth slot** and never adds a fifth chip. A game that is already a chip
/// just becomes selected, so the chips are untouched.
List<String> chipsWithPick(List<String> chips, String? pick, int cap) {
  if (pick == null || chips.contains(pick)) return chips;
  final kept = chips.take(cap - 1).toList();
  return [...kept, pick];
}

/// The side games that get a chip of their own on New Round. Everything else
/// that is eligible sits behind **More side games** (Paul, 14 Nov 2026) — Skins
/// and Spots are what groups reach for, and a row of seven chips buries them.
///
/// **Except under Skins**, where Skins cannot be its own side game, so the pair
/// is Spots and Stroke Play instead: the row never has a hole where the
/// favourite would have been.
List<String> pinnedSideGamesFor(String? primaryId) =>
    primaryId == GameIds.skins
        ? const [GameIds.spots, GameIds.strokePlay]
        : const [GameIds.skins, GameIds.spots];

/// [eligible] split into the pinned chips and the rest, each in the order it
/// arrived. The pinned ones follow [pinnedSideGamesFor]'s own order, not the
/// eligible list's, so the favourite is always ahead.
({List<GameMeta> pinned, List<GameMeta> other}) splitSideGames(
    List<GameMeta> eligible, String? primaryId) {
  final want = pinnedSideGamesFor(primaryId);
  final pinned = <GameMeta>[
    for (final id in want)
      for (final m in eligible)
        if (m.id == id) m,
  ];
  final other = [
    for (final m in eligible)
      if (!want.contains(m.id)) m,
  ];
  return (pinned: pinned, other: other);
}
