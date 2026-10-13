// Who shares a scorecard in a Multi-Group Skins round.
//
// The case these are written from is Paul's round of 12 Oct 2026: a
// 15-foursome shotgun whose skins pool was one full foursome playing
// together, two individuals and a twosome — 4, 1, 1, 2. Every selected
// golfer had been seated solo with no control to say otherwise.
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/skins_cards.dart';

/// 1-4 are on Halved; 5+ are guests.
bool _onApp(int id) => id <= 4;
String _name(int id) => 'G$id';

void main() {
  group('the cards', () {
    test('a golfer per card is the shipped default', () {
      expect(cardsOf({1: 1, 2: 2, 3: 3}),
          {1: [1], 2: [2], 3: [3]});
    });

    test('Paul\'s round — 4, 1, 1, 2', () {
      final cards = cardsOf({1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 3, 7: 4, 8: 4});
      expect(cards.values.map((v) => v.length).toList(), [4, 1, 1, 2]);
    });

    test('a gap in the numbers is kept, not closed', () {
      // Moving the last golfer off card 2 leaves 1 and 3. The DISPLAY label
      // comes from position, so the list still reads Group 1, Group 2.
      expect(cardsOf({1: 1, 2: 3}).keys.toList(), [1, 3]);
    });

    test('the next free number fills the gap', () {
      expect(nextFreeCard([1, 3]), 2);
      expect(nextFreeCard([1, 2, 3]), 4);
      expect(nextFreeCard(const []), 1);
    });
  });

  group('what blocks a round', () {
    test('nothing, when everyone is on Halved', () {
      expect(cardsProblem({1: 1, 2: 2}, isOnApp: _onApp, nameOf: _name),
          isNull);
    });

    test('a guest alone has nobody to keep his score', () {
      // Paul, 13 Oct 2026: "it is only when sharing a card with somebody on
      // halved". A guest cannot be handed a phone to score himself.
      final msg = cardsProblem({5: 1}, isOnApp: _onApp, nameOf: _name);
      expect(msg, contains('G5'));
      expect(msg, contains('Halved'));
    });

    test('a guest with a member is fine', () {
      expect(cardsProblem({1: 1, 5: 1}, isOnApp: _onApp, nameOf: _name),
          isNull);
    });

    test('two guests together are still stranded', () {
      // Neither can score the card, so sharing it changes nothing.
      final msg = cardsProblem({5: 1, 6: 1}, isOnApp: _onApp, nameOf: _name);
      expect(msg, contains('G5'));
      expect(msg, contains('G6'));
      expect(msg, contains('are not'));
    });

    test('it names only the stranded ones', () {
      final msg = cardsProblem({1: 1, 5: 1, 6: 2},
          isOnApp: _onApp, nameOf: _name);
      expect(msg, contains('G6'));
      expect(msg, isNot(contains('G5')));   // G5 shares a card with G1
    });

    test('five on one card is a foursome and a half', () {
      final msg = cardsProblem({1: 1, 2: 1, 3: 1, 4: 1, 5: 1},
          isOnApp: _onApp, nameOf: _name);
      expect(msg, contains('5 golfers'));
    });

    test('the size rule is reported before the scoring one', () {
      // Both are wrong here; the size is the one the golfer can see on
      // screen, so it is the one that gets named.
      final msg = cardsProblem({5: 1, 6: 1, 7: 1, 8: 1, 9: 1},
          isOnApp: _onApp, nameOf: _name);
      expect(msg, contains('5 golfers'));
    });
  });
}
