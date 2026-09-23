/// test/skins_standing_test.dart
/// -----------------------------
/// The standing ribbon's two strings on a Skins round.
///
/// **A skin count is not a place**, and that is the whole subject here. Every
/// other ranked game on this row leads with one; Skins does not rank, because
/// the pot is divided by skins won and two men on three each take the same
/// share.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/skins_standing.dart';

const _me = 11;
const _b = 12;

SkinsHole _hole(int n, {int? winnerId}) => SkinsHole(
      hole: n, winnerId: winnerId, winnerShort: winnerId == null ? null : 'W',
      skinsValue: 1, isCarry: winnerId == null, junk: const [],
    );

SkinsSummary _summary({
  Map<int, int> skins = const {},
  Map<int, int> junk = const {},
  Map<int, double> net = const {},
  List<SkinsHole> holes = const [],
}) =>
    SkinsSummary(
      status: 'in_progress', handicapMode: 'net', netPercent: 100,
      carryover: true, allowJunk: true,
      players: [
        for (final id in const [_me, _b])
          SkinsPlayerTotal(
            playerId: id, name: 'P$id', shortName: 'P$id',
            skinsWon: skins[id] ?? 0, junkSkins: junk[id] ?? 0,
            totalSkins: (skins[id] ?? 0) + (junk[id] ?? 0),
            payout: 0, net: net[id] ?? 0,
          ),
      ],
      holes: holes,
      betUnit: 1, pool: 4, totalSkins: 0,
    );

void main() {
  group('the standing is the count', () {
    test('several reads plural', () {
      final s = _summary(skins: {_me: 3}, holes: [_hole(1, winnerId: _me)]);
      expect(skinsStanding(s, _me)!.standing, '3 skins');
    });

    test('**one reads singular**', () {
      // `1 skins` is the kind of thing a reader trusts less for, on a row
      // whose whole job is to be believed at a glance.
      final s = _summary(skins: {_me: 1}, holes: [_hole(1, winnerId: _me)]);
      expect(skinsStanding(s, _me)!.standing, '1 skin');
    });

    test('**none is a STATE, not a gap**', () {
      // Carryovers mean a golfer can play nine holes and hold nothing, which
      // is ordinary. Silence would read as a row that did not arrive.
      final s = _summary(skins: {_b: 2}, holes: [_hole(1, winnerId: _b)]);
      expect(skinsStanding(s, _me)!.standing, 'No skins');
    });

    test('**junk counts, because the pot pays it**', () {
      // A junk skin is won by hand rather than by score, but it takes a share
      // of the same pot — so counting only `skinsWon` would name a smaller
      // number than the money beside it is paying for.
      final s = _summary(
          skins: {_me: 2}, junk: {_me: 1}, holes: [_hole(1, winnerId: _me)]);
      expect(skinsStanding(s, _me)!.standing, '3 skins');
    });

    test('and it never claims a place, because Skins does not rank', () {
      // The pot is divided by skins won, so two men on three each take the
      // same share and neither is ahead of the other.
      final s = _summary(
          skins: {_me: 3, _b: 3}, holes: [_hole(1, winnerId: _me)]);
      final st = skinsStanding(s, _me)!.standing;
      expect(st, '3 skins');
      expect(st.contains('of'), isFalse);
      expect(st.contains('T-'), isFalse);
    });
  });

  group('the money', () {
    test('it rides in the quiet slot, signed', () {
      final s = _summary(
          skins: {_me: 3}, net: {_me: 12, _b: -12},
          holes: [_hole(1, winnerId: _me)]);
      expect(skinsStanding(s, _me)!.figure, '+\$12 so far');
      expect(skinsStanding(s, _b)!.figure, '−\$12 so far');
    });

    test('square is silent, not \$0', () {
      final s = _summary(skins: {_me: 1}, holes: [_hole(1, winnerId: _me)]);
      expect(skinsStanding(s, _me)!.figure, '');
    });
  });

  group('when there is nothing to say', () {
    test('**before a hole is decided the row still draws**', () {
      // A carried first hole is the commonest opening in the game, so the
      // pill has to survive it.
      final s = _summary(holes: [_hole(1), _hole(2)]);
      expect(skinsStanding(s, _me)!.standing, 'Tee off');
    });

    test('a watcher is not in the pool', () {
      final s = _summary(skins: {_me: 1}, holes: [_hole(1, winnerId: _me)]);
      expect(skinsStanding(s, 999), isNull);
    });

    test('no summary, no row', () {
      expect(skinsStanding(null, _me), isNull);
    });
  });
}
