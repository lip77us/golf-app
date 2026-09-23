/// utils/survivor_standing.dart
/// ----------------------------
/// What the standing ribbon says on a Survivor round.
///
/// **Survivor is measured in whether you are still in it**, which is the
/// reading the lock-screen card arrived at and the reason its headline is a
/// WORD where every other card carries a number. The row follows it:
///
///   * **the standing** is what the hole does while all three are in, and the
///     reader's own state once two are — `Low golfer out`, then `Alive · finals`
///   * **the figure** is what has been won — `+$4 so far`, settled legs only
///
/// ## On an elimination hole, `Alive` is not news
///
/// All three are in — that is what makes it an elimination hole — so saying so
/// tells the reader nothing he could not work out from the fact that he is
/// standing on the tee. The row states what the HOLE does instead:
/// **`Low golfer out`**. Once two are left it inverts: being in the finals is
/// the whole question, and the word earns its place.
///
/// That is why the two states read differently rather than being one template
/// with a phase swapped in. `Alive · elimination` was the template version, and
/// it spent the loud half of the row on a word that was true of everybody.
///
/// `Surv. 2` is the quiet slot — the same role `F9` plays on Nassau. A round
/// yields up to nine Survivors, so the leg number is the identity the rest of
/// the screen is about, and it is abbreviated because the sentence beside it is
/// the part worth the width.
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
///
/// **An elimination hole is grey too**, because `Low golfer out` is a fact
/// about the hole and not about the reader. Mint on it would read as *you are
/// fine*, which is not what the sentence says. The colour arrives when the
/// finals do, which makes its arrival mean something.
library;

import '../api/models.dart';
import 'match_notation.dart';

class SurvivorStanding {
  /// `Surv. 3` — the leg the hole on screen belongs to. Grey.
  final String label;

  /// `Low golfer out`, `Alive · finals`, `Zombie · finals`, `Tee off`.
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
  final label = 'Surv. ${at.survivor}';

  // **Before the first score the row still draws.** The pill is the way in,
  // and losing it here gives the feature up exactly when a first-time player
  // goes looking for the leaderboard.
  if (!summary.holes.any((h) => h.isScored)) {
    return SurvivorStanding(label, kTeeOff, money, SurvivorTint.none);
  }

  // **All three in — so the row is about the HOLE, not about the reader.**
  // Everybody is alive on an elimination hole by definition; what he does not
  // already know is what it costs.
  if (at.aliveIds.length > 2) {
    // The LAST hole can host no elimination: there is no hole left to decide
    // on afterwards, so it settles outright and nobody goes out. Saying `Low
    // golfer out` there would name a consequence the hole cannot have.
    return SurvivorStanding(
        label, isLastHole ? 'Low ball wins' : 'Low golfer out', money,
        SurvivorTint.none);
  }

  // Two left. Now whether the reader is one of them IS the question, so the
  // word leads and the phase follows it.
  //
  // `finals`, not the engine's `decider`: the reader's question is whether he
  // made it, and *the finals* is how a golfer says that. `decider` describes
  // the hole's job, which was the right word on a banner explaining the rules
  // and the wrong one on a row reporting where he stands.
  const phase = 'finals';

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
