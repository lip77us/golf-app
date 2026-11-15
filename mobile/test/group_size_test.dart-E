import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:golf_mobile/game_catalog.dart';

/// How many golfers one card may hold. The server's
/// `services.round_setup.max_group_size` is what actually refuses a fifth
/// golfer; this is the client's copy of the same rule, read where the casual
/// screen seats a golfer, so the two must agree.
void main() {
  test('a group is a foursome', () {
    expect(maxGroupSizeFor(const []), 4);
    expect(maxGroupSizeFor(const [GameIds.skins, GameIds.nassau]), 4);
  });

  test('Annandale Friday seats six on one card', () {
    expect(maxGroupSizeFor(const [GameIds.annandaleFriday]), 6);
  });

  test('a side game riding on it does not shrink the card back to four', () {
    expect(maxGroupSizeFor(const [GameIds.annandaleFriday, GameIds.skins]), 6);
    expect(maxGroupSizeFor(const [GameIds.skins, GameIds.annandaleFriday]), 6);
  });

  test('it is a five-or-six game, and only that', () {
    final m = gameMeta(GameIds.annandaleFriday)!;
    expect(m.supportsSize(4), isFalse);
    expect(m.supportsSize(5), isTrue);
    expect(m.supportsSize(6), isTrue);
    expect(m.supportsSize(7), isFalse);
  });

  test('the casual screen asks the rule rather than counting to four', () {
    // Read the source: a `< 4` coming back is how a sixth golfer gets
    // spilled onto a second card before the server ever sees him.
    final src = File('lib/screens/casual_round_screen.dart').readAsStringSync();
    expect(src.contains('maxGroupSizeFor(_activeGames)'), isTrue);
    expect(src.contains('counts[g]! < 4'), isFalse);
  });
}
