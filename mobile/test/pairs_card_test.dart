/// test/pairs_card_test.dart
/// -------------------------
/// What the score-entry card draws for each format
/// (docs/design-review/handoff-team-pairs/SPEC.md §6.1).
///
/// **Six formats, two cards**, and the split is which one the format takes —
/// not what the format is CALLED. Testing the name is how alternate shot,
/// Scotch and Chapman ended up on the own-ball branch: each plays a single
/// ball off a single team figure exactly as a scramble does, but a
/// `format == 'scramble'` check sent them to iterate a per-golfer list the
/// server correctly sends empty, so the card under the entry lost its score
/// line and its dots and showed nothing but the net.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';

TeamPlayCard _card(String format, {int teamSize = 2}) =>
    TeamPlayCard.fromJson({
      'format'       : format,
      'team_size'    : teamSize,
      'hole'         : 1,
      'play_order'   : [for (var h = 1; h <= 18; h++) h],
      'par'          : 4,
      'stroke_index' : 1,
      // The team's strokes across the round — what the dots are drawn from on
      // any format that ends in one ball.
      'strokes_by_hole': {for (var h = 1; h <= 4; h++) '$h': 1},
      'golfer_strokes' : const {},
      // Empty for a one-ball format, and correctly so: there is no per-golfer
      // ball to show.
      'golfers_by_hole': const [],
      'round'          : {'thru': 1, 'by_hole': {'1': {'gross': 5}}},
      'drive'          : const {},
    });

void main() {
  group('the four one-ball formats all draw the team line', () {
    for (final format in ['scramble', 'alternate_shot', 'scotch', 'chapman']) {
      test('$format is a one-ball card', () {
        expect(_card(format).isOneBall, isTrue, reason: format);
      });

      test("$format's dots come off the team figure", () {
        // golferId is null on a one-ball card, so a per-golfer lookup would
        // return empty and the dots would vanish.
        expect(_card(format).strokesFor(null), isNotEmpty, reason: format);
        expect(_card(format).strokesFor(null)[1], 1, reason: format);
      });
    }
  });

  group('the own-ball formats keep strokes per golfer', () {
    test('best ball is not a one-ball card', () {
      expect(_card('best_ball').isOneBall, isFalse);
    });

    test('a shamble is not either', () {
      expect(_card('shamble', teamSize: 4).isOneBall, isFalse);
    });

    test('an own-ball card looks its strokes up by player', () {
      final card = TeamPlayCard.fromJson({
        'format'         : 'best_ball',
        'team_size'      : 2,
        'hole'           : 1,
        'play_order'     : [1],
        'strokes_by_hole': {'1': 9},          // ignored — not the team's
        'golfer_strokes' : {'7': {'1': 1}},
        'round'          : const {},
        'drive'          : const {},
      });
      expect(card.strokesFor(7), {1: 1});
      expect(card.strokesFor(null), isEmpty);
    });
  });

  group('the drive control the card draws', () {
    ({String control, bool chips}) shape(String format, String control) {
      final card = TeamPlayCard.fromJson({
        'format': format, 'team_size': 2, 'hole': 1, 'play_order': [1],
        'drive_control': control,
        'drive_options': control == 'record' || control == 'instruction'
            ? [{'player_id': 1, 'name': 'Anna Maiolini', 'picked': false}]
            : const [],
        'round': const {}, 'drive': const {},
      });
      return (control: card.driveControl, chips: card.showsDriveChips);
    }

    test('a scramble records and a Scotch instructs — both tap', () {
      expect(shape('scramble', 'record').chips, isTrue);
      expect(shape('scotch', 'instruction').chips, isTrue);
    });

    test('a rota states who is up — there is nothing to tap', () {
      expect(shape('alternate_shot', 'rota').chips, isFalse);
    });

    test('best ball and Chapman have no control at all', () {
      expect(shape('best_ball', 'none').chips, isFalse);
      expect(shape('chapman', 'none').chips, isFalse);
    });
  });
}
