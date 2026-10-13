// Solo is reachable, and the three solo games appear ONLY there.
//
// `handoff-solo-games`: Who's playing? becomes Solo · 2 · 3 · 4 · Across
// groups, with Solo first; the chips become Stroke Play, Nassau and Match
// Play; side games are hidden; and the note reads "Solo games are played
// against par."
//
// The sharp edge is the NAMES. The solo games are called Stroke Play, Nassau
// and Match Play — the same as three multi-player games — because a golfer on
// his own is still playing Stroke Play. What keeps them apart is `sizes: {1}`,
// matched by no other filter, so this is what stops a duplicate chip showing
// up in a foursome's picker.
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';

void main() {
  GameMeta meta(String id) => gameMeta(id)!;
  const soloIds = [GameIds.soloStroke, GameIds.soloNassau, GameIds.soloMatch];

  group('the three solo games', () {
    test('are one golfer and one golfer only', () {
      for (final id in soloIds) {
        final m = meta(id);
        expect(m.minPlayers, 1, reason: '$id');
        expect(m.maxPlayers, 1, reason: '$id');
        expect(m.supportsSize(1), isTrue, reason: '$id');
      }
    });

    test('match NO other group size', () {
      // The whole mechanism: a foursome's picker filters on supportsSize(4)
      // and must never offer these.
      for (final id in soloIds) {
        for (final n in [2, 3, 4]) {
          expect(meta(id).supportsSize(n), isFalse,
              reason: '$id offered itself to a group of $n');
        }
      }
    });

    test('carry the names a golfer already knows', () {
      expect(meta(GameIds.soloStroke).displayName, 'Stroke Play');
      expect(meta(GameIds.soloNassau).displayName, 'Nassau');
      expect(meta(GameIds.soloMatch).displayName, 'Match Play');
    });

    test('the shared names cannot collide in one picker', () {
      // Stroke Play and Nassau exist twice in the catalog on purpose. No size
      // filter may match both, or a picker shows the same word twice.
      for (final id in soloIds) {
        final name = meta(id).displayName;
        final twins = kGameCatalog.where(
            (m) => m.displayName == name && m.id != id);
        for (final twin in twins) {
          expect(twin.supportsSize(1), isFalse,
              reason: '${twin.id} shares the name "$name" and also fits a '
                  'solo round — they would both show');
        }
      }
    });

    test('every one can explain itself', () {
      for (final id in soloIds) {
        expect(meta(id).blurb, isNotNull, reason: '$id has no blurb');
        expect(meta(id).blurb, contains('par'),
            reason: '$id never mentions the opponent');
      }
    });

    test('none of them carries a money line', () {
      // Always for fun. A money note would be the first thing to argue with.
      for (final id in soloIds) {
        expect(meta(id).moneyNote, isNull, reason: '$id has a money note');
      }
    });
  });
}
