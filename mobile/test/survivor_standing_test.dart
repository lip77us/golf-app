/// test/survivor_standing_test.dart
/// --------------------------------
/// The standing ribbon's strings on a Survivor round.
///
/// **Survivor is measured in whether you are still in it**, so the subject
/// here is a word rather than a number — and the two rules that decide which
/// word: the state is read at the hole on screen, and a Zombie is not merely
/// out.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/survivor_standing.dart';

const _me = 11;
const _b = 12;
const _c = 13;
const _all = [_me, _b, _c];

SurvivorHoleEntry _entry(int id, {bool alive = true, bool zombie = false,
                                  bool resurrected = false}) =>
    SurvivorHoleEntry(
      playerId: id, shortName: 'P$id', name: 'P$id',
      netScore: 4, gross: 4, strokes: 0,
      isAlive: alive, isZombie: zombie, isResurrected: resurrected,
      isEliminated: !alive, isWinner: false,
    );

/// `isScored` is derived from `event`, so an unscored hole is one with none.
SurvivorHole _hole(int n, {int survivor = 1, List<int> out = const [],
                           int? resurrected, bool scored = true}) =>
    SurvivorHole(
      hole: n, survivor: survivor, role: null, par: 4,
      eliminatedId: out.firstOrNull, eliminatedShort: null,
      winnerId: null, winnerShort: null,
      event: scored ? 'eliminated' : null,
      resurrectedId: resurrected, resurrectedShort: null,
      entries: [
        for (final id in _all)
          _entry(id,
              alive: !out.contains(id),
              zombie: out.contains(id),
              resurrected: id == resurrected),
      ],
    );

SurvivorSummary _summary({
  List<SurvivorHole> holes = const [],
  List<SurvivorLeg> survivors = const [],
  Map<int, double> money = const {},
  bool zombie = false,
  int currentSurvivor = 1,
  List<int> currentAlive = _all,
  int? currentZombieId,
}) =>
    SurvivorSummary(
      status: 'in_progress', handicapMode: 'gross', netPercent: 100,
      zombieOption: zombie,
      survivors: survivors,
      players: [
        for (final id in _all)
          SurvivorPlayerTotal(playerId: id, name: 'P$id', shortName: 'P$id',
              money: money[id] ?? 0, survivorsWon: 0, phcpInPlay: 0),
      ],
      holes: holes,
      scorecard: const {},
      currentSurvivor: currentSurvivor,
      currentAliveIds: currentAlive,
      currentZombieId: currentZombieId,
      currentRole: currentAlive.length == 2 ? 'decider' : 'elimination',
      betUnit: 5, pot: 15, maxLiability: 45,
    );

SurvivorStanding? _st(SurvivorSummary? s, {int who = _me, int hole = 1,
                                           bool last = false}) =>
    survivorStanding(s, who, hole: hole, playerIds: _all, isLastHole: last);

void main() {
  group('the word, and the hole it belongs to', () {
    test('still in it reads Alive, with what the hole does', () {
      final s = _summary(holes: [_hole(1)]);
      final st = _st(s)!;
      expect(st.standing, 'Alive · elimination');
      expect(st.label, 'Survivor 1');
      expect(st.tint, SurvivorTint.alive);
    });

    test('two left makes it a decider', () {
      final s = _summary(holes: [_hole(1, out: [_c])]);
      expect(_st(s)!.standing, 'Alive · decider');
    });

    test('**the last hole is its own phase**', () {
      // It can host neither an elimination nor a carry, so it settles whatever
      // is standing — a different hole from the one in front of it, and worth
      // saying before they play it.
      final s = _summary(holes: [_hole(1, out: [_c])]);
      expect(_st(s, last: true)!.standing, 'Alive · last hole');
    });

    test('the Survivor number is the quiet slot', () {
      final s = _summary(holes: [_hole(4, survivor: 3)], currentSurvivor: 3);
      expect(_st(s, hole: 4)!.label, 'Survivor 3');
    });
  });

  group('knocked out', () {
    test('**Out is grey, not red**', () {
      // The play screen washes an eliminated row in the out-of-play grey and
      // saves its reds for the HOLE that did it — an event, not a state.
      final s = _summary(holes: [_hole(1, out: [_me])]);
      final st = _st(s)!;
      expect(st.standing, 'Out · decider');
      expect(st.tint, SurvivorTint.none);
    });

    test('with the option on he is the Zombie, and plum', () {
      // Not merely out: still hitting shots, one low-outright hole from being
      // back in. The same plum the player row wears.
      final s = _summary(holes: [_hole(1, out: [_me])], zombie: true);
      final st = _st(s)!;
      expect(st.standing, 'Zombie · decider');
      expect(st.tint, SurvivorTint.zombie);
    });

    test('somebody ELSE being the Zombie leaves the reader alive', () {
      final s = _summary(holes: [_hole(1, out: [_c])], zombie: true);
      final st = _st(s)!;
      expect(st.standing, 'Alive · decider');
      expect(st.tint, SurvivorTint.alive);
    });

    test('**a resurrection outranks the state it produced**', () {
      // He is alive, but on this hole the news is that he came back — and the
      // Survivor CARRIES ON rather than being won, which `Alive` alone would
      // not hint at.
      final s = _summary(
        holes: [_hole(1, out: [_c], resurrected: _me)], zombie: true);
      final st = _st(s)!;
      expect(st.standing, 'Back in · decider');
      expect(st.tint, SurvivorTint.alive);
    });
  });

  group('**the state is read at the hole on screen**', () {
    test('backing up reports who was out then', () {
      // Everything else on the screen has backed up with it.
      final s = _summary(
        holes: [
          _hole(1, survivor: 1, out: [_me]),
          _hole(2, survivor: 2),
        ],
        currentSurvivor: 2);
      expect(_st(s, hole: 1)!.standing, 'Out · decider');
      expect(_st(s, hole: 2)!.standing, 'Alive · elimination');
    });

    test('an UNSCORED hole reads the engine, never a walk back', () {
      // The walk-back version was wrong after a resurrection: once the Zombie
      // goes low outright and sends a decider to Zombieville, the Zombie is
      // the DECIDER he displaced, not the man who came back. Reported from the
      // course.
      final s = _summary(
        holes: [
          _hole(1, out: [_me], resurrected: null),
          _hole(2, scored: false),
        ],
        zombie: true,
        currentAlive: [_me, _b], currentZombieId: _c);
      expect(_st(s, hole: 2)!.standing, 'Alive · decider');
      expect(_st(s, who: _c, hole: 2)!.standing, 'Zombie · decider');
    });

    test('the state read returns what the screen tints its rows with', () {
      final s = _summary(holes: [_hole(1, out: [_c])]);
      final at = survivorStateAt(s, 1, _all);
      expect(at.survivor, 1);
      expect(at.aliveIds, {_me, _b});
      expect(at.outId, _c);
    });
  });

  group('the money', () {
    test('settled Survivors only, and empty at nothing', () {
      expect(_st(_summary(holes: [_hole(1)]))!.figure, '');
    });

    test('a decided one puts it beside the word', () {
      final s = _summary(holes: [_hole(1)], money: {_me: 10, _b: -5});
      expect(_st(s)!.figure, '+\$10 so far');
      expect(_st(s, who: _b)!.figure, '−\$5 so far');
    });
  });

  group('when there is nothing to say', () {
    test('**before the first score the row still draws**', () {
      // The pill is the way in; losing it here gives the feature up exactly
      // when a first-time player goes looking for the leaderboard.
      final s = _summary(holes: [_hole(1, scored: false)]);
      expect(_st(s)!.standing, 'Tee off');
    });

    test('a watcher is not in the game', () {
      expect(_st(_summary(holes: [_hole(1)]), who: 999), isNull);
    });

    test('no summary, no row', () {
      expect(_st(null), isNull);
    });
  });
}
