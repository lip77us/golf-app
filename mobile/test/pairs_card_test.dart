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
import 'package:golf_mobile/screens/team_play_score_entry_screen.dart';
import 'package:golf_mobile/widgets/team_scorecard.dart';

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

  group('two pairs share a playing group, so the foursome id is not a key', () {
    TeamPlayTeam boardRow(int foursomeId, int slot) =>
        TeamPlayTeam.fromJson({
          'foursome_id': foursomeId, 'slot': slot,
          'group_number': 1, 'name': 'Pair $slot', 'colour': 'Pine',
          'real_player_count': 2, 'has_phantom': false, 'seats_open': 0,
          'members': const [], 'team_handicap': 4,
          'team_handicap_raw': '4.25',
          'allowance': const {}, 'drive': const {}, 'thru': 0,
        });

    test('two rows in one group have different keys', () {
      // Keyed on the foursome alone, opening one pair's row on the board
      // opened the other pair's with it — a twosome expanded into the whole
      // foursome.
      expect(boardRow(7, 1).rowKey, isNot(boardRow(7, 2).rowKey));
    });

    test('the same row is the same key', () {
      expect(boardRow(7, 1).rowKey, boardRow(7, 1).rowKey);
    });

    test('a foursome event sits at slot 1 and keys off it unchanged', () {
      expect(boardRow(7, 1).slot, 1);
      expect(boardRow(7, 1).rowKey, '7:1');
    });
  });

  group('the rule binds a pair rather than splitting it', () {
    // `total` puts a rule ABOVE, which is right when the row sums the rows
    // over it. On a card carrying two teams it fell between a pair's score row
    // and that pair's own net row — splitting the thing it was meant to bind.
    test('a summing row rules above by default', () {
      const r = TeamScorecardRow(label: 'Net', scores: {}, total: true);
      expect(r.drawsRuleAbove, isTrue);
      expect(r.ruleBelow, isFalse);
    });

    test('asking for a rule below suppresses the one above', () {
      // Two lines around one row is a box, not a separator.
      const r = TeamScorecardRow(
          label: 'Net', scores: {}, total: true, ruleBelow: true);
      expect(r.drawsRuleAbove, isFalse);
      expect(r.ruleBelow, isTrue);
    });

    test('the LAST pair on a two-team card takes neither rule', () {
      // It gets no rule below because the card ends there — and the derived
      // default would then put one back ABOVE its net, which is the same
      // split one row further down. Saying so outright is the only way to get
      // neither.
      const r = TeamScorecardRow(
          label: 'Net', scores: {}, total: true, ruleAbove: false);
      expect(r.drawsRuleAbove, isFalse);
      expect(r.ruleBelow, isFalse);
    });

    test('an ordinary row rules neither way', () {
      const r = TeamScorecardRow(label: 'B & P', scores: {});
      expect(r.drawsRuleAbove, isFalse);
      expect(r.ruleBelow, isFalse);
    });
  });

  group('one picker for the playing group, not one per pair', () {
    // Four golfers on one card is one person entering four scores. Keyed per
    // pair, best ball opened a picker in each pair's block and put two on
    // screen at once — which no other entry screen in the app does.
    test('with nothing entered it opens on the first golfer', () {
      expect(activeGolferAcross([1, 2, 3, 4], {}, null), 1);
    });

    test('it advances past golfers who already have a score', () {
      // Including past the whole first pair — the group is one list, so the
      // picker crosses from one pair into the next on its own.
      expect(activeGolferAcross([1, 2, 3, 4], {1, 2}, null), 3);
    });

    test('a tap wins over the advance', () {
      expect(activeGolferAcross([1, 2, 3, 4], {}, 4), 4);
    });

    test('a tap on a golfer no longer on the card is ignored', () {
      // The group can shrink between the tap and the reload.
      expect(activeGolferAcross([1, 2], {}, 9), 1);
    });

    test('a full card keeps the picker on the first row', () {
      expect(activeGolferAcross([1, 2, 3, 4], {1, 2, 3, 4}, null), 1);
    });

    test('an empty card opens nothing', () {
      expect(activeGolferAcross([], {}, 3), isNull);
    });
  });

  group('what a team gets, across all five pairs formats', () {
    // Verified against Seder 19 / Carson 24 and Bird 35 / Schroeder 40 —
    // the pair whose net nobody could account for, because the figure was on
    // neither the card nor the board.
    TeamPlayTeam row({required int? teamHandicap, List<int?> own = const []}) =>
        TeamPlayTeam.fromJson({
          'foursome_id': 1, 'slot': 1, 'group_number': 1,
          'name': 'B & S', 'colour': 'Pine', 'real_player_count': 2,
          'has_phantom': false, 'seats_open': 0,
          'team_handicap': teamHandicap, 'team_handicap_raw': '0',
          'allowance': const {}, 'drive': const {}, 'thru': 0,
          'members': [
            for (final o in own)
              {'player_id': 1, 'name': 'X', 'course_handicap': 0, 'pct': 0,
               'strokes': '0', 'is_phantom': false, 'own_ball_handicap': o},
          ],
        });

    test('a one-ball format shows the ONE team figure', () {
      // Scramble 18, alternate shot 38, Scotch and Chapman 37 — all one ball
      // off one figure, so one number is the whole truth.
      expect(row(teamHandicap: 38, own: const [null, null]).getsLabel,
             'gets 38');
    });

    test('best ball shows each golfer, never the team total', () {
      // The total (64 for Bird and Schroeder) is a BALANCE number the strip
      // uses to stack one pair against another. Printing it would invite
      // subtracting 64 from a ball played off 30.
      expect(row(teamHandicap: 64, own: const [30, 34]).getsLabel,
             'gets 30 / 34');
    });

    test('a team still being built says nothing', () {
      // The figure moves when a golfer moves, so there is nothing honest to
      // print until the pair is full.
      expect(row(teamHandicap: null).getsLabel, '');
      expect(row(teamHandicap: 0).getsLabel, '');
    });

    test('the phantom is not one of the golfers who gets strokes', () {
      final t = TeamPlayTeam.fromJson({
        'foursome_id': 1, 'slot': 1, 'group_number': 1, 'name': 'Dune',
        'colour': 'Pine', 'real_player_count': 3, 'has_phantom': true,
        'seats_open': 0, 'team_handicap': 40, 'team_handicap_raw': '0',
        'allowance': const {}, 'drive': const {}, 'thru': 0,
        'members': const [
          {'player_id': 1, 'name': 'A', 'course_handicap': 0, 'pct': 0,
           'strokes': '0', 'is_phantom': false, 'own_ball_handicap': 9},
          {'player_id': 2, 'name': 'Phantom 4th', 'course_handicap': 0,
           'pct': 0, 'strokes': '0', 'is_phantom': true,
           'own_ball_handicap': 14},
        ],
      });
      expect(t.getsLabel, 'gets 9');
    });
  });
}
