/// Typing in a paper scorecard.
///
/// Paul, 3 Nov 2026, of a 60-player event run in Golf Genius: *"In the Ryder
/// Cup, there were a number of groups not using the app and it would have
/// been nice to enter the scores as they came in so the group on the course
/// had an accurate leaderboard."*
///
/// The TD could always enter another group's scores — the server has always
/// authorised him and the hub has always drawn him the button. What he could
/// not do is do it QUICKLY, and what the board never did is say that a third
/// of the field was missing from it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/field_progress_bar.dart';

void main() {
  group('the model reads the flag', () {
    test('paper_card comes through', () {
      final fs = Foursome.fromJson(const {
        'id': 1, 'group_number': 3, 'has_phantom': false,
        'pink_ball_order': <dynamic>[], 'memberships': <dynamic>[],
        'paper_card': true,
      });
      expect(fs.paperCard, isTrue);
    });

    test('and defaults false on a payload that predates it', () {
      // An older server sends nothing, and the honest reading of that is
      // "not on paper" rather than a badge on every group.
      final fs = Foursome.fromJson(const {
        'id': 1, 'group_number': 3, 'has_phantom': false,
        'pink_ball_order': <dynamic>[], 'memberships': <dynamic>[],
      });
      expect(fs.paperCard, isFalse);
    });
  });

  group('the card screen', () {
    final src = File('lib/screens/enter_card_screen.dart').readAsStringSync();

    test('posts the whole card in one request', () {
      // The reason the screen exists. Eighteen posts is what made
      // transcribing eight paper groups impractical.
      expect(src, contains('postFoursomeCard('));
      expect(src.contains("_post('/foursomes"), isFalse);
    });

    test('one Save covers every golfer typed', () {
      // The TD types a column, taps the next name, types that one, saves
      // once — so the pending map is keyed by player AND hole.
      expect(src, contains('final Map<int, Map<int, int>> _typed'));
    });

    test('+10 is explicit, not a timer', () {
      // Digits 1-9 write and advance, which is every score a transcriber
      // meets. 10 and up are one extra tap rather than an ambiguity about
      // whether a `1` is a 1 or the start of a 12.
      expect(src, contains('onTens'));
      expect(src.toLowerCase(), isNot(contains('timer(')));
    });

    test('it can skip a hole, because a partial card is normal', () {
      expect(src, contains('onSkip'));
    });

    test('it names the pool members whose cards must be complete', () {
      // The trap: a skins hole counts only once EVERY participant has a
      // score, so a pool member left half-entered removes those holes from
      // the pool for everybody — including the golfers who entered them
      // themselves.
      expect(src, contains('_poolIds'));
      expect(src, contains('_PoolNote'));
    });

    test('a nine subtotal is an em dash until it is whole', () {
      // The rule every card in this app uses, so a partial subtotal never
      // reads as a finished one.
      expect(src, contains("whole ? '\$sub' : '—'"));
    });
  });

  group('the hub', () {
    final src = File('lib/screens/round_screen.dart').readAsStringSync();

    test('offers the card screen on every group, not just paper ones', () {
      // A card handed over mid-round is the commonest case and nobody has
      // marked anything yet.
      final i = src.indexOf("pushNamed('/enter-card'");
      expect(i, greaterThan(0));
      // The gate above it is the TD, and nothing about paperCard.
      final gate = src.lastIndexOf('if (canManage) ...[', i);
      expect(gate, greaterThan(0));
      expect(src.substring(gate, i), isNot(contains('paperCard')));
    });

    test('the paper toggle is the TD\'s and is reversible', () {
      expect(src, contains("value: 'paper_card'"));
      expect(src, contains('Not on paper after all'));
      expect(src, contains('_togglePaperCard'));
    });

    test('and the card shows which groups he has marked', () {
      expect(src, contains('if (foursome.paperCard) ...['));
      expect(src, contains("Text('On paper'"));
    });
  });

  group('the leaderboard says what it is missing', () {
    test('the board feeds the bar from the server\'s own block', () {
      final src =
          File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect(src, contains("lb.games['field_progress']"));
      expect(src, contains('FieldProgressBar('));
    });

    test('and it is a top-level banner, not a tab', () {
      // A fact about the round, not a competition — the server skips it in
      // `active_games` for the same reason, so an older client cannot draw
      // it as a junk tab.
      final src =
          File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      final i = src.indexOf('FieldProgressBar(');
      expect(i, greaterThan(0));
      // It sits in the body Column beside the Final Results banner, which is
      // the other thing on this screen that is about the round rather than a
      // game.
      expect(src.lastIndexOf('return Column(', i), greaterThan(0));
    });
  });

  group('the progress bar', () {
    // **The real widget**, not a copy of its logic in this file. The first
    // version of these four reimplemented it here, which proves nothing: the
    // copy agrees with itself whatever the screen does. That is why
    // `FieldProgressBar` lives in `widgets/`.
    Widget host(Object? data) =>
        MaterialApp(home: Scaffold(body: FieldProgressBar(data: data)));

    testWidgets('is silent once the field is in', (t) async {
      await t.pumpWidget(host(const {
        'groups': 3, 'complete': 3, 'paper': 1, 'paper_awaiting': 0,
        'awaiting': <dynamic>[],
      }));
      expect(find.textContaining('not final'), findsNothing);
    });

    testWidgets('and absent entirely on a one-group round', (t) async {
      // The server sends null there — there is no field to be missing from.
      await t.pumpWidget(host(null));
      expect(find.textContaining('not final'), findsNothing);
    });

    testWidgets('names the groups while there are few enough to read',
        (t) async {
      await t.pumpWidget(host(const {
        'groups': 4, 'complete': 2, 'paper': 1, 'paper_awaiting': 1,
        'awaiting': [
          {'group_number': 2, 'name': 'Group 2', 'thru': 9, 'expected': 18,
           'paper_card': true},
          {'group_number': 4, 'name': 'Group 4', 'thru': 14, 'expected': 18,
           'paper_card': false},
        ],
      }));
      expect(find.textContaining('1 group on paper'), findsOneWidget);
      expect(find.textContaining('1 still out'), findsOneWidget);
      expect(find.textContaining('Group 2 (thru 9)'), findsOneWidget);
    });

    testWidgets('but not eleven of them', (t) async {
      // A list that long is not something anybody reads, and the count
      // already said it.
      await t.pumpWidget(host({
        'groups': 12, 'complete': 1, 'paper': 0, 'paper_awaiting': 0,
        'awaiting': [
          for (var g = 2; g <= 12; g++)
            {'group_number': g, 'name': 'Group $g', 'thru': 5,
             'expected': 18, 'paper_card': false},
        ],
      }));
      expect(find.textContaining('11 still out'), findsOneWidget);
      expect(find.textContaining('(thru 5)'), findsNothing);
    });

    testWidgets('paper leads, because it is the half somebody must act on',
        (t) async {
      await t.pumpWidget(host(const {
        'groups': 5, 'complete': 1, 'paper': 2, 'paper_awaiting': 2,
        'awaiting': [
          {'group_number': 2, 'name': 'Group 2', 'thru': 0, 'expected': 18,
           'paper_card': true},
          {'group_number': 3, 'name': 'Group 3', 'thru': 4, 'expected': 18,
           'paper_card': true},
          {'group_number': 5, 'name': 'Group 5', 'thru': 9, 'expected': 18,
           'paper_card': false},
        ],
      }));
      final line = t.widget<Text>(find.textContaining('of 5')).data!;
      expect(line.indexOf('on paper'), lessThan(line.indexOf('still out')));
      expect(line, contains('2 groups on paper'));
    });
  });
}
