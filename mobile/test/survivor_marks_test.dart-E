/// test/survivor_marks_test.dart
/// -----------------------------
/// The colours a Survivor hole can wear, on both cards that draw them.
///
/// The rail and the by-hole grid sit one above the other on the same screen
/// and used to disagree: the grid drew a knocked-out hole RED whatever the
/// round's rules were, while the rail drew it plum whenever the Zombie Option
/// was on. Same hole, same screen, two colours — and only in the rounds where
/// the distinction carries money.
///
/// They read one palette now, so what is worth pinning is the MEANING of each
/// mark rather than the wiring: a hex that moves is a design change, but a
/// knock-out that goes red in a Zombie round is a lie about the rules.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/survivor_rail.dart';

/// Perceived lightness, which is what "the light plum" actually means.
double _lum(Color c) => c.computeLuminance();

/// How far the green channel sits above the red one — a crude saturation test
/// for a near-white green.
int _greenness(Color c) => (c.g * 255).round() - (c.r * 255).round();

/// Blue and red both above green — a crude hue test, enough to tell the plum
/// family from the red one.
bool _isPlumFamily(Color c) =>
    (c.b * 255).round() > (c.g * 255).round() &&
    (c.r * 255).round() > (c.g * 255).round();

void main() {
  group('**a knocked-out hole asks whether the round HAS a Zombieville**', () {
    test('with the option on it is plum, not red', () {
      // A man in Zombieville is out of the running and still hitting shots,
      // which is neither of the things red means.
      expect(SurvivorMarks.outFill(true), SurvivorMarks.zombFill);
      expect(SurvivorMarks.outLine(true), SurvivorMarks.zombLine);
      expect(_isPlumFamily(SurvivorMarks.outFill(true)), isTrue);
    });

    test('without one it is red, because he is simply gone', () {
      expect(SurvivorMarks.outFill(false), SurvivorMarks.knockFill);
      expect(SurvivorMarks.outLine(false), SurvivorMarks.knockLine);
    });

    test('the two are genuinely different marks', () {
      // The bug was one surface answering this question and the other not
      // asking it at all.
      expect(SurvivorMarks.outFill(true),
             isNot(equals(SurvivorMarks.outFill(false))));
    });
  });

  group('**dark plum is going out, light plum is coming back**', () {
    test('back in is lighter than Zombieville', () {
      // The grid had them at the same weight, so a resurrection and the
      // elimination that preceded it were the same colour.
      expect(_lum(SurvivorMarks.backFill),
             greaterThan(_lum(SurvivorMarks.zombFill)));
      expect(_lum(SurvivorMarks.backLine),
             greaterThan(_lum(SurvivorMarks.zombLine)));
    });

    test('and they are one family, not two unrelated marks', () {
      // Both mixed from the same plum, so the pair reads as out and back.
      expect(_isPlumFamily(SurvivorMarks.backFill), isTrue);
      expect(_isPlumFamily(SurvivorMarks.zombFill), isTrue);
      expect(SurvivorMarks.zombLine, Halved.zombie);
    });
  });

  group('green is for taking it, never for merely surviving', () {
    test('won and alive are different fills', () {
      // Surviving a hole is the default state of two men out of three; if it
      // wore the winner's green the card would be mostly green by the turn.
      //
      // The two separate on SATURATION, not lightness — they are within a
      // hundredth of each other in luminance, which is why the winner also
      // gets a border and the survivor does not.
      expect(SurvivorMarks.wonFill,
             isNot(equals(SurvivorMarks.aliveFill)));
      expect(_greenness(SurvivorMarks.wonFill),
             greaterThan(_greenness(SurvivorMarks.aliveFill)));
    });

    test('the won text reads against the won fill', () {
      // The grid puts a gross score inside this cell; the rail does not, which
      // is why the text colour lives here rather than in the screen.
      expect(_lum(SurvivorMarks.wonFill) - _lum(SurvivorMarks.wonText),
             greaterThan(0.4));
    });
  });
}
