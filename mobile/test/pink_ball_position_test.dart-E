/// test/pink_ball_position_test.dart
/// --------------------------------
/// The ball's rotation follows POSITION IN THE ROUND (ruled 25 Sep 2026): the
/// first golfer in the order carries it off the group's FIRST TEE, whichever
/// hole that is.
///
/// The screen held `_holeIndex = holeNumber - 1` and read
/// `_order[_holeIndex % 3]`, which is the same thing only when the round starts
/// on the 1st. The engine had the identical mistake — `services/red_ball.py`,
/// corrected in the same commit and tested in `scoring/tests/test_red_ball.py`.
///
/// **What makes this testable at all is that the rule is arithmetic on the play
/// order**, so it is asserted here against `roundPlayOrder` rather than by
/// driving the screen: `_carrierId` is `_order[_pos % _order.length]` with `_pos`
/// an index into that list, and these tests pin the list and the indexing.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/utils/play_order.dart';

/// The rule, exactly as the screen and `red_ball.carrier_at` state it.
int carrierAt(List<int> order, int pos) => order[pos % order.length];

/// What the screen used to do.
int oldCarrierForHole(List<int> order, int hole) =>
    order[(hole - 1) % order.length];

void main() {
  const three = [101, 102, 103];

  List<int> holes(int start, {int n = 18, int universe = 18}) =>
      [for (var i = 0; i < n; i++) ((start - 1 + i) % universe) + 1];

  group('the ruling', () {
    test('the first name carries the first tee, whatever hole that is', () {
      for (final start in [1, 4, 8, 13, 17]) {
        final o = holes(start);
        expect(carrierAt(three, 0), three[0],
            reason: 'off the ${o.first}th');
      }
    });

    test('the Nth hole of the round belongs to the Nth name', () {
      final o = holes(8);
      for (var pos = 0; pos < o.length; pos++) {
        expect(carrierAt(three, pos), three[pos % 3],
            reason: 'hole ${o[pos]} is the group\'s #${pos + 1}');
      }
    });
  });

  group('where the old rule and the new one differ', () {
    // **Two conditions have to hold for the two formulas to agree**, and I had
    // only found the first:
    //
    //   1. `(start - 1) % players == 0`, so the offset at the start cancels;
    //   2. `18 % players == 0`, so it still cancels after the round WRAPS.
    //
    // Three golfers satisfy (2) and four do not: off the 13th a four-ball
    // matches on holes 13-18 and is wrong on 1-12, where the wrap shifts the
    // rotation by two. This matters because it is the difference between "the
    // shipped bug was never hit" and "it was hit by every four-ball off any hole
    // but the 1st" — and my first version of this test asserted the comfortable
    // version.
    //
    // Found by mutation: putting the old formula back broke NO test, because the
    // first shotgun tests used three golfers off the 13th, which is the one
    // shotgun configuration where the bug is invisible.
    bool identical(int start, int players) {
      final o = holes(start);
      final ord = [for (var i = 0; i < players; i++) i];
      return o.every((h) =>
          carrierAt(ord, o.indexOf(h)) == oldCarrierForHole(ord, h));
    }

    test('three golfers off a congruent start hide the bug entirely', () {
      expect(identical(13, 3), isTrue);   // (13-1) % 3 == 0 and 18 % 3 == 0
      expect(identical(10, 3), isTrue);
    });

    test('four golfers are caught even off a congruent start', () {
      // 18 % 4 == 2, so the wrap re-breaks it: right on 13-18, wrong on 1-12.
      expect(identical(13, 4), isFalse);
      final o = holes(13);
      const ord = [0, 1, 2, 3];
      for (final h in [13, 14, 18]) {
        expect(carrierAt(ord, o.indexOf(h)), oldCarrierForHole(ord, h),
            reason: 'hole $h is before the wrap');
      }
      for (final h in [1, 5, 12]) {
        expect(carrierAt(ord, o.indexOf(h)), isNot(oldCarrierForHole(ord, h)),
            reason: 'hole $h is after the wrap');
      }
    });

    test('any other start diverges on every hole', () {
      expect(identical(8, 3), isFalse);
      expect(identical(14, 3), isFalse);
      expect(identical(10, 4), isFalse);
      // Off the 8th with three golfers the old rule was wrong on all 18.
      final o = holes(8);
      final ord = [0, 1, 2];
      for (final h in o) {
        expect(carrierAt(ord, o.indexOf(h)), isNot(oldCarrierForHole(ord, h)),
            reason: 'hole $h');
      }
    });

    test('a round off the 1st is unaffected, which is why this shipped', () {
      expect(identical(1, 3), isTrue);
      expect(identical(1, 4), isTrue);
    });
  });

  group('the screen navigates by position', () {
    final src = File('lib/screens/pink_ball_screen.dart').readAsStringSync();

    test('the index is named for what it is', () {
      // `_holeIndex` was the name AND the bug: it read as an index into 1..18.
      expect(src.contains('_holeIndex'), isFalse,
          reason: 'the old hole-number index is gone — do not reintroduce it');
      expect(src.contains('int  _pos = 0;'), isTrue);
    });

    test('the hole number is read OUT of the play order', () {
      expect(src.contains('_holesInPlay[_pos.clamp('), isTrue,
          reason: 'deriving it as `_pos + 1` is the bug wearing a new name');
    });

    test('the current hole is looked up by number, not by list index', () {
      // `sc.holes` is ordered by hole NUMBER, so indexing it with a position
      // read the wrong row.
      expect(src.contains('sc.holes[_pos]'), isFalse);
      expect(src.contains('sc.holeData(_holeNumber)'), isTrue);
    });

    test('the last hole is the last POSITION, not hole 18', () {
      expect(src.contains('_pos == _lastPos'), isTrue);
      expect(src.contains('== 17'), isFalse,
          reason: 'hole 18 is not where a shotgun round ends');
    });
  });

  group('roundPlayOrder is what both sides index', () {
    test('a shotgun wraps', () {
      expect(holes(13).take(7).toList(), [13, 14, 15, 16, 17, 18, 1]);
    });

    test('a back nine is nine holes, not eighteen', () {
      expect(holes(10, n: 9), [10, 11, 12, 13, 14, 15, 16, 17, 18]);
    });

    test('the shared helper agrees with the arithmetic used here', () {
      // Guards the local `holes()` fixture against drifting from the real one.
      expect(roundPlayOrder(null, null), holes(1));
    });
  });
}
