/// utils/survivor_standing.dart
/// ----------------------------
/// What the standing ribbon says on a Survivor round.
///
/// **Survivor is measured in whether you are still in it**, which is the
/// reading the lock-screen card arrived at and the reason its headline is a
/// WORD where every other card carries a number. The row follows it:
///
///   * **the standing** is the reader's own state and the hole's job —
///     `Alive · decider`, `Zombie · elimination`, `Out · last hole`
///   * **the figure** is what has been won — `+$4 so far`, settled legs only
///
/// ## Two facts, and the quiet one is which Survivor
///
/// A round yields up to nine Survivors, so `Survivor 3` is the identity the
/// rest of the screen is about — the same role `F9` plays on Nassau, and it
/// goes in the same quiet slot. The news is not which leg is running; it is
/// whether the reader is still in it and what this hole does about that.
///
/// **The phase rides with the state rather than with the number** because the
/// two are read together: alive on an elimination hole means somebody is going
/// out, and alive on a decider means it can be won right now. Splitting them
/// across the two slots would put half the sentence in the grey half of the
/// row.
///
/// ## Out is grey, not red
///
/// The play screen washes an eliminated row in the out-of-play grey and saves
/// its reds for the HOLE that knocked him out — an event, not a state. The row
/// says the same thing the same way. A red `Out` would read as an alarm about
/// something that has already happened and cannot be acted on.
///
/// Mint is alive and plum is the Zombie, which is the vocabulary of the player
/// rows six lines below and of the track on the lock screen. Three surfaces,
/// one meaning per colour.
library;

import '../api/models.dart';
import 'match_notation.dart';

class SurvivorStanding {
  /// `Survivor 3` — the leg the hole on screen belongs to. Grey.
  final String label;

  /// `Alive · decider`, `Zombie · elimination`, `Out · last hole`, `Tee off`.
  final String standing;

  /// `+$4 so far` — settled Survivors only. Empty until one settles.
  final String figure;

  /// How the standing is coloured: mint alive, plum Zombie, grey otherwise.
  final SurvivorTint tint;

  const SurvivorStanding(this.label, this.standing, this.figure, this.tint);
}

/// The row's three colours, named rather than passed as `Color`s so the util
/// stays free of the widget layer and the test can assert the MEANING.
enum SurvivorTint { alive, zombie, none }

/// `+$4 so far` / `−$2 so far`, or empty at nothing.
///
/// **Settled, never a forecast.** A Survivor in progress contributes nothing,
/// which is what lets the row say `so far` and mean it.
String survivorMoney(SurvivorSummary s, int playerId) {
  final me = s.players.where((p) => p.playerId == playerId).firstOrNull;
  final v = me?.money ?? 0;
  if (v.abs() < 0.005) return '';
  final n = v.abs();
  final amount =
      n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
  // U+2212, not a hyphen — beside a `+` at this size the hyphen is visibly
  // the wrong length.
  return '${v > 0 ? "+" : "−"}\$$amount so far';
}

/// Who is alive at [hole], which Survivor it belongs to, and who is out of it.
///
/// A scored hole carries its own state. An UNSCORED one is the hole the group
/// is standing on, and the ENGINE already knows what they are playing it
/// under — so this reads `current`, it does not walk backwards.
///
/// **That distinction is load-bearing.** The walk-back version was wrong after
/// a resurrection: once the Zombie goes low outright and sends a decider to
/// Zombieville, the Zombie is the DECIDER he displaced, not the man who came
/// back. Reported from the course — a golfer won a hole as the Zombie and was
/// still drawn as the Zombie on the next one.
///
/// Extracted from the Survivor screen, which computed exactly this for its row
/// tints and now shares it. Two copies would disagree about who is plum, on
/// the one screen showing both.
({int survivor, Set<int> aliveIds, int? outId}) survivorStateAt(
    SurvivorSummary summary, int hole, List<int> playerIds) {
  final info = summary.holeFor(hole);
  if (info != null && info.isScored) {
    return (
      survivor: info.survivor ?? summary.currentSurvivor,
      aliveIds: info.entries.where((e) => e.isAlive)
          .map((e) => e.playerId).toSet(),
      outId: info.entries.where((e) => !e.isAlive)
          .map((e) => e.playerId).firstOrNull,
    );
  }
  final alive = summary.currentAliveIds.toSet();
  return (
    survivor: summary.currentSurvivor,
    aliveIds: alive,
    outId: summary.currentZombieId ??
        playerIds.where((pid) => !alive.contains(pid)).firstOrNull,
  );
}

/// The row's strings, or null when the reader is not playing this game.
///
/// [hole] is the hole on screen, so backing up to an earlier one reports the
/// Survivor as it stood then — the rule every game on this row follows, for
/// the same reason: everything else on the screen has backed up with it.
///
/// [isLastHole] is the group's own last hole in PLAY ORDER, which only the
/// screen knows. It cannot host an elimination and a decider both, so it
/// settles whatever is standing — a different hole from the one in front of
/// it, and worth saying before they play it.
SurvivorStanding? survivorStanding(SurvivorSummary? summary, int? playerId,
                                   {required int hole,
                                    required List<int> playerIds,
                                    required bool isLastHole}) {
  if (summary == null || playerId == null) return null;
  // A watcher is not in the game, and Survivor is exactly three men.
  if (!summary.players.any((p) => p.playerId == playerId)) return null;

  final money = survivorMoney(summary, playerId);
  final at = survivorStateAt(summary, hole, playerIds);
  final label = 'Survivor ${at.survivor}';

  // **Before the first score the row still draws.** The pill is the way in,
  // and losing it here gives the feature up exactly when a first-time player
  // goes looking for the leaderboard.
  if (!summary.holes.any((h) => h.isScored)) {
    return SurvivorStanding(label, kTeeOff, money, SurvivorTint.none);
  }

  // What this hole does. `elimination` and `decider` are the engine's own
  // words and the banner's; the last hole is the screen's, because only it
  // knows the group's play order.
  final phase = isLastHole
      ? 'last hole'
      : (at.aliveIds.length == 2 ? 'decider' : 'elimination');

  // **A resurrection outranks the state it produced.** He is alive, but on
  // this hole the news is that he came back — and the Survivor carries on
  // rather than being won, which `Alive` alone would not hint at.
  final info = summary.holeFor(hole);
  if (info != null && info.isScored && info.resurrectedId == playerId) {
    return SurvivorStanding(label, 'Back in · $phase', money,
        SurvivorTint.alive);
  }

  if (at.aliveIds.contains(playerId)) {
    return SurvivorStanding(label, 'Alive · $phase', money,
        SurvivorTint.alive);
  }

  // Out. With the option on he is not merely out — he is in the seat, still
  // hitting shots, one low-outright hole from being back in.
  final isZombie = summary.zombieOption && at.outId == playerId;
  return SurvivorStanding(
      label,
      isZombie ? 'Zombie · $phase' : 'Out · $phase',
      money,
      isZombie ? SurvivorTint.zombie : SurvivorTint.none);
}
