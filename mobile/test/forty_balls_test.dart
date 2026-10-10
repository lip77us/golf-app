/// test/forty_balls_test.dart
/// -------------------------
/// 40 Balls on the client: the picker, the board, and the two places a wiring
/// mistake would make the game unreachable.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/widgets/forty_balls_board.dart';
import 'package:golf_mobile/widgets/hole_grid_scorecard.dart';
import 'package:golf_mobile/widgets/forty_balls_picker.dart';

FortyBallsPickerState picker({
  int groupSize = 4,
  int activeHere = 4,
  int lo = 0,
  int hi = 4,
  int left = 40,
  int spent = 0,
  int holesAfter = 17,
  int capacity = 72,
  int slack = 32,
  int? count,
  bool canPick = true,
  bool scoresIn = true,
  bool locked = false,
  bool dq = false,
  Map<int, int> nets = const {1: 3, 2: 4, 3: 5, 4: 6},
}) =>
    FortyBallsPickerState.fromJson({
      'hole': 11, 'group_size': groupSize, 'active_here': activeHere,
      'budget': groupSize * 10, 'spent': spent, 'left': left,
      'holes_after': holesAfter, 'capacity': capacity, 'lo': lo, 'hi': hi,
      'dq': dq, 'count': count, 'app_set': false, 'slack': slack, 'can_pick': canPick, 'scores_in': scoresIn,
      'locked': locked, 'handicap_mode': 'net', 'net_percent': 100,
      'cap': true,
      'par': 4,
      'nets': {for (final e in nets.entries) '${e.key}': e.value},
    });

const _names = {1: 'Alan', 2: 'Aldo', 3: 'Alex', 4: 'Anna'};

Future<void> pumpPicker(WidgetTester tester, FortyBallsPickerState s,
    {void Function(int)? onPick}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(
      child: FortyBallsPicker(
        state: s, names: _names, onPick: onPick ?? (_) {}),
    )),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('the picker', () {
    testWidgets('one button per count, 0 to the group size', (tester) async {
      await pumpPicker(tester, picker());
      for (final n in ['0', '1', '2', '3', '4']) {
        expect(find.text(n), findsOneWidget);
      }
    });

    testWidgets('a threesome tops out at 3', (tester) async {
      await pumpPicker(tester, picker(groupSize: 3, activeHere: 3, hi: 3,
          left: 30, capacity: 54, slack: 24));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsNothing);
    });

    testWidgets('there is NO default, and the pager says what is missing',
        (tester) async {
      // The same pattern a missing score uses, because it is the same gap.
      await pumpPicker(tester, picker());
      expect(find.text('Pick how many balls count to move on'), findsOneWidget);
    });

    testWidgets('the counts are DRAWN on a hole nobody has played yet',
        (tester) async {
      // Reported from testing: hiding them behind `Waiting on the last score`
      // read as an error on arriving at a fresh hole. The counts stand there
      // dim, like the score boxes above them.
      final taps = <int>[];
      await pumpPicker(tester, picker(scoresIn: false, nets: const {}),
          onPick: taps.add);
      expect(find.text('Waiting on the last score'), findsNothing);
      for (final n in ['0', '1', '2', '3', '4']) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.text('Pick once every score on the hole is in'),
          findsOneWidget);
      // Drawn, but dead — there is nothing yet to choose between.
      await tester.tap(find.text('2'));
      expect(taps, isEmpty);
    });

    testWidgets('it waits on a MISSING NET, not on the hole being posted',
        (tester) async {
      // **The rule moved.** It used to wait for the server to have the scores,
      // which meant it showed nothing while the group was entering. Now it
      // waits for the nets — from wherever they are — so three of four is
      // still not enough to choose on, but four unposted ones are.
      final taps = <int>[];
      await pumpPicker(tester,
          picker(scoresIn: false, nets: const {1: 3, 2: 4, 3: 5}),
          onPick: taps.add);
      await tester.tap(find.text('2'));
      expect(taps, isEmpty);
    });

    testWidgets('four UNPOSTED nets are enough to pick on', (tester) async {
      final taps = <int>[];
      await pumpPicker(tester, picker(scoresIn: false), onPick: taps.add);
      for (final n in ['0', '1', '2', '3', '4']) {
        expect(find.text(n), findsOneWidget);
      }
      await tester.tap(find.text('2'));
      expect(taps, [2]);
    });

    test('the pager and the picker share one readiness rule', () {
      // Written twice they would drift, and the pager would name a pick the
      // card was not offering.
      final s = picker(scoresIn: false, nets: const {});
      expect(fortyBallsReady(s, const {}), isFalse);
      expect(fortyBallsReady(s, const {1: 3, 2: 4, 3: 5}), isFalse);
      expect(fortyBallsReady(s, const {1: 3, 2: 4, 3: 5, 4: 6}), isTrue);
    });

    testWidgets('the hole in front of you is one of the holes to play',
        (tester) async {
      // Reported from the 1st tee: `2.4 a hole, 17 to play` before a ball had
      // been struck. The figure counted the holes AFTER this one while the
      // slack beside it counted this one — two tiles, two moments.
      await pumpPicker(tester, picker(holesAfter: 17, left: 40, capacity: 72));
      expect(find.text('2.2 a hole'), findsOneWidget);
      expect(find.text('18 to play'), findsOneWidget);
      expect(find.text('32'), findsOneWidget);   // slack 4 x 18 - 40
    });

    testWidgets('a pick steps BOTH figures forward', (tester) async {
      // 40 - 2 = 38 balls over the 17 holes after this one, and the slack
      // loses the two balls this hole did not take.
      await pumpPicker(tester,
          picker(holesAfter: 17, left: 40, capacity: 72, count: 2));
      expect(find.text('2.2 a hole'), findsOneWidget);
      expect(find.text('17 to play'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);   // 68 - 38
    });

    testWidgets('a settled hole says so and offers nothing', (tester) async {
      await pumpPicker(tester,
          picker(count: 2, canPick: false, locked: true));
      expect(find.text('Settled'), findsOneWidget);
      expect(find.textContaining('fixed at 2'), findsOneWidget);
    });

    testWidgets('counts outside lo..hi cannot be tapped', (tester) async {
      final taps = <int>[];
      // No slack: 4 is the only legal count.
      await pumpPicker(tester, picker(lo: 4, hi: 4, left: 12, holesAfter: 2,
          capacity: 12, slack: 0), onPick: taps.add);
      await tester.tap(find.text('1'));
      await tester.tap(find.text('4'));
      expect(taps, [4]);
    });

    testWidgets('a pick names the counted golfers and the hole result',
        (tester) async {
      // Best two of 3,4,5,6 on a par 4 is −1.
      await pumpPicker(tester, picker(count: 2));
      expect(find.textContaining('Alan'), findsOneWidget);
      expect(find.textContaining('Aldo'), findsOneWidget);
      // The house minus (U+2212), via the shared `toParLabel`.
      expect(find.textContaining('\u22121'), findsOneWidget);
    });

    testWidgets('zero balls says the hole is level, not that it is −0',
        (tester) async {
      await pumpPicker(tester, picker(count: 0));
      expect(find.textContaining('level'), findsOneWidget);
    });

    testWidgets('slack 0 is amber and says every ball counts', (tester) async {
      await pumpPicker(tester, picker(lo: 4, hi: 4, left: 12, holesAfter: 2,
          capacity: 12, slack: 0));
      expect(find.text('every ball counts from here'), findsOneWidget);
      expect(find.textContaining('No slack left'), findsOneWidget);
    });

    testWidgets('a spent budget reads – on both figures', (tester) async {
      await pumpPicker(tester, picker(lo: 0, hi: 0, left: 0, spent: 40,
          capacity: 28, slack: 0));
      expect(find.text('–'), findsNWidgets(2));
      expect(find.textContaining('budget spent'), findsWidgets);
      expect(find.textContaining('Budget spent'), findsOneWidget);
    });

    testWidgets('a group that is OUT says so and offers no buttons',
        (tester) async {
      await pumpPicker(tester,
          picker(dq: true, left: 20, capacity: 16, canPick: false));
      expect(find.text('Out of 40 Balls'), findsOneWidget);
      expect(find.textContaining('championship'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });
  });

  group('the board', () {
    Map<String, dynamic> group({
      int number = 1, int size = 4, int spent = 34, int total = -5,
      double? ranking = -5, bool dq = false, int? rank = 1,
      int slack = 6, int left = 6, int capacity = 12, String? factor,
      int? thru = 2, List<int> holesInPlay = const [1, 2],
    }) => {
          'foursome_id': number, 'group_number': number, 'group_size': size,
          'budget': size * 10, 'spent': spent, 'left': left, 'slack': slack,
          'capacity': capacity, 'holes_left': 3, 'thru': thru,
          'total': total, 'factor': factor, 'ranking_total': ranking,
          'dq': dq, 'rank': rank, 'tied': false,
          'payout': rank == 1 ? 150.0 : 0.0,
          'per_person_payout': rank == 1 ? 37.5 : 0.0, 'split_ways': size,
          'players': [
            for (final e in _names.entries)
              {'player_id': e.key, 'short_name': e.value, 'name': e.value},
          ],
          'holes': [
            {'hole': 1, 'par': 4, 'stroke_index': 7,
             'count': 2, 'app_set': false, 'result': -1,
             'counted_ids': [1, 2],
             'scores': {'1': 3, '2': 4, '3': 5, '4': 6},
             'gross': {'1': 3, '2': 5, '3': 5, '4': 6},
             'strokes': {'1': 0, '2': 1, '3': 0, '4': 0}},
            {'hole': 2, 'par': 4, 'stroke_index': 11,
             'count': 4, 'app_set': true, 'result': 2,
             'counted_ids': [1, 2, 3, 4],
             'scores': {'1': 4, '2': 4, '3': 5, '4': 5},
             'gross': {'1': 4, '2': 4, '3': 5, '4': 5},
             'strokes': {'1': 0, '2': 0, '3': 0, '4': 0}},
          ],
          'holes_in_play': holesInPlay,
        };

    Future<void> pumpBoard(WidgetTester tester,
        List<Map<String, dynamic>> groups) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FortyBallsBoard(
          data: {'handicap_mode': 'net', 'net_percent': 100,
                 'net_max_double_bogey': true, 'entry_fee': 10.0,
                 'pool': 80.0, 'payouts': [], 'n_groups': groups.length,
                 'results': groups},
          names: _names,
        )),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('every row carries its budget, not just the reader\'s',
        (tester) async {
      // A group at −5 with slack 12 is in a different position from one at −5
      // with slack 0, and that comparison is the point.
      await pumpBoard(tester, [group(), group(number: 2, rank: 2, slack: 0)]);
      expect(find.text('34 of 40'), findsNWidgets(2));
      expect(find.text('slack 6'), findsOneWidget);
      expect(find.text('slack 0 · all count'), findsOneWidget);
    });

    testWidgets('thru sits beside the group name', (tester) async {
      // Reported from the board: the budget line answers what a group has
      // left to SPEND, and nothing on the row answered how far round they
      // are — which is what a reader compares one row against another with.
      await pumpBoard(tester, [
        group(thru: 9, holesInPlay: const [
          1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        ]),
      ]);
      expect(find.text('Thru 9'), findsOneWidget);
      // Not F — there are nine to come.
      expect(find.text('F'), findsNothing);
    });

    testWidgets('it is to the RIGHT of the name and LEFT of the total',
        (tester) async {
      // "Next to the team name" is a position, so it is measured. Between the
      // name and the figures is the only slot where it reads as belonging to
      // the group rather than to the money.
      await pumpBoard(tester, [
        group(thru: 9, total: -5, ranking: -5, holesInPlay: const [
          1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        ]),
      ]);
      final name  = tester.getTopRight(find.text('Group 1')).dx;
      final thru  = tester.getTopLeft(find.text('Thru 9')).dx;
      final total = tester.getTopLeft(find.text('−5')).dx;
      expect(thru, greaterThan(name));
      expect(thru, lessThan(total));
    });

    testWidgets('it is NOT 18 minus holes_left', (tester) async {
      // A hole can be fully scored and still carry no committed count, so
      // the budget's `pending` and a golfer's `thru` are different
      // questions. `holes_left` is 3 in this fixture; thru is 1.
      await pumpBoard(tester, [group(thru: 1)]);
      expect(find.text('Thru 1'), findsOneWidget);
      expect(find.text('Thru 15'), findsNothing);
    });

    testWidgets('every hole in play reads F, not Thru 18', (tester) async {
      // Measured against the holes IN PLAY, because this board has the list
      // and a nine-hole round would otherwise never finish.
      await pumpBoard(tester, [
        group(thru: 9, holesInPlay: const [1, 2, 3, 4, 5, 6, 7, 8, 9]),
      ]);
      expect(find.text('F'), findsOneWidget);
      expect(find.textContaining('Thru'), findsNothing);
    });

    testWidgets('a group that has not started shows nothing', (tester) async {
      // An empty slot rather than `Thru 0`.
      await pumpBoard(tester, [group(thru: null)]);
      expect(find.textContaining('Thru'), findsNothing);
      expect(find.text('F'), findsNothing);
      // The row is still there.
      expect(find.text('Group 1'), findsOneWidget);
    });

    testWidgets('a finished group drops the slack', (tester) async {
      await pumpBoard(tester, [group(spent: 40, left: 0, slack: 0)]);
      expect(find.text('40 of 40'), findsOneWidget);
      expect(find.textContaining('slack'), findsNothing);
    });

    testWidgets('a threesome shows the raw total and the factor',
        (tester) async {
      await pumpBoard(tester, [
        group(size: 3, total: -4, ranking: -5.333333, factor: '4/3'),
      ]);
      expect(find.textContaining('−4 on 30 balls × 4/3'), findsOneWidget);
      // One decimal, and only when the factor made it fractional.
      expect(find.text('−5.3'), findsOneWidget);
    });

    testWidgets('a whole number keeps no decimal', (tester) async {
      await pumpBoard(tester, [group(total: -6, ranking: -6)]);
      expect(find.text('−6'), findsOneWidget);
    });

    testWidgets('a DQd group reads OUT with no rank and no total',
        (tester) async {
      await pumpBoard(tester,
          [group(dq: true, rank: null, ranking: null, left: 20, capacity: 16)]);
      expect(find.text('OUT'), findsOneWidget);
      expect(find.textContaining('20 owed, room for 16'), findsOneWidget);
    });

    testWidgets('the card is the STANDARD card, named and indexed',
        (tester) async {
      // Reported from the course: four anonymous rows, no index, no dots, and
      // the Balls row a column off the scores it described.
      await pumpBoard(tester, [group()]);
      await tester.tap(find.text('Group 1'));
      await tester.pumpAndSettle();
      final card = find.byType(HoleGridScorecard);
      expect(card, findsOneWidget);
      // The golfers are named — the board used to pass no roster at all.
      for (final n in _names.values) {
        // The label column draws a RichText (name + playing handicap), so the
        // finder has to be told to look inside one.
        expect(
            find.descendant(
                of: card, matching: find.text(n, findRichText: true)),
            findsOneWidget);
      }
      // Par and Index bands, and the GROSS digit rather than the net.
      expect(find.descendant(of: card, matching: find.text('Index')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('7')),
          findsWidgets);
      // Aldo made 5 gross on the 1st and netted 4; the card prints the 5.
      expect(find.descendant(of: card, matching: find.text('5')),
          findsWidgets);
    });

    testWidgets('Balls and Group live INSIDE the grid', (tester) async {
      // They were a second scroller underneath with their own label width and
      // their own offset, so they neither lined up nor scrolled along.
      await pumpBoard(tester, [group()]);
      await tester.tap(find.text('Group 1'));
      await tester.pumpAndSettle();
      final card = find.byType(HoleGridScorecard);
      expect(find.descendant(of: card, matching: find.text('Balls')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Group')),
          findsOneWidget);
    });

    testWidgets('the card marks app-set counts apart from the group\'s',
        (tester) async {
      await pumpBoard(tester, [group()]);
      await tester.tap(find.text('Group 1'));
      await tester.pumpAndSettle();
      expect(find.text('Balls'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
    });
  });

  group('the game is reachable', () {
    // Two wiring mistakes would ship a game nobody can start, and this repo has
    // made the second one twice before.
    test('the exclusion is stated in ALL THREE directions', () {
      // The wizard removes what the game being turned ON excludes, so a
      // one-way edge lets the pair through from the other side.
      for (final pair in [
        [GameIds.fortyBalls, GameIds.irishRumble],
        [GameIds.fortyBalls, GameIds.betterBall],
        [GameIds.irishRumble, GameIds.fortyBalls],
        [GameIds.betterBall, GameIds.fortyBalls],
        [GameIds.irishRumble, GameIds.betterBall],
        [GameIds.betterBall, GameIds.irishRumble],
      ]) {
        expect(gameMeta(pair[0])?.excludes, contains(pair[1]),
            reason: '${pair[0]} must exclude ${pair[1]}');
      }
    });

    test('the hub\'s Game Setup card counts 40 Balls among its games', () {
      // `hasSetupGames` gates the whole card. A round playing ONLY 40 Balls
      // would otherwise hide it, and the Configure button with it — the same
      // shape as the casual receipt nothing could open.
      final src = File('lib/screens/round_screen.dart').readAsStringSync();
      final gate = RegExp(r'final hasSetupGames\s*=([^;]+);', dotAll: true)
          .firstMatch(src)!
          .group(1)!;
      expect(gate.contains('hasFortyBalls'), isTrue,
          reason: 'add every game with a Configure button to this list');
    });

    test('score entry RENDERS the picker', () {
      // **The miss this test exists for.** The picker widget was built, the
      // board was built, the setup screen was built — and nothing rendered the
      // picker, so a scorer entered a hole and was never asked how many balls
      // counted. A widget with no call site is not a feature.
      final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();
      expect(src.contains('FortyBallsPickerCard('), isTrue,
          reason: 'score entry must render the picker — it IS the game');
      expect(src.contains("games.contains('forty_balls')"), isTrue,
          reason: 'and only when the round plays it');
    });

    test('both ENTRY-POINT widgets are reached from a screen', () {
      // The general form of the same mistake, stated at the right level: the
      // two widgets a SCREEN is supposed to render. `FortyBallsPicker` itself
      // is deliberately not in this list — it is presentational and its only
      // caller is `FortyBallsPickerCard` in the same file, which is a sound
      // arrangement rather than a gap.
      for (final w in ['FortyBallsPickerCard', 'FortyBallsBoard']) {
        final used = Directory('lib/screens')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .any((f) => f.readAsStringSync().contains('$w('));
        expect(used, isTrue,
            reason: '$w is built but no screen renders it');
      }
    });

    test('the count rides WITH the hole, not after it', () {
      // **What testing asked for.** Scores are held locally until the hole is
      // left, so a picker gated on the server having them showed nothing while
      // the group was entering — and after a `Post the hole` step the buttons
      // flashed up and vanished as the card reloaded.
      //
      // The group picks while it is entering; the count is held by hole and
      // sent right after the scores land, before the screen moves on.
      final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();
      expect(src.contains('_fbPending'), isTrue);
      expect(src.contains('_flushFortyBalls('), isTrue);
      expect(src.contains('_fbLocalNets('), isTrue,
          reason: 'the picker needs the nets as ENTERED, not only as posted');
      // And there is no longer a post-first step to get past.
      expect(src.contains("'Post the hole'"), isTrue,
          reason: "Banker still uses it — only 40 Balls dropped it");
      expect(src.contains('final posted = st?.scoresIn'), isFalse,
          reason: 'the pager must not gate the pick on the hole being posted');
    });

    test('score entry gates the pager on the pick', () {
      // **The flow the game needs, and the one testing found missing.** Scores
      // are held locally until the hole is left, so a picker that reads the
      // server can never see them: the scorer entered four scores, saw
      // `Waiting on the last score`, pressed next, and only found the picker
      // by stepping BACK a hole.
      //
      // So the pager posts first, then names the pick, then advances — the
      // same three-step shape Banker already uses, and for the same reason.
      final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();
      expect(src.contains('_fortyBallsRound('), isTrue);
      // **The button always names the next hole.** It used to relabel itself
      // `Pick how many balls count`, which wrapped to two lines and changed
      // the words under the thumb; the picker card is what says the pick is
      // outstanding, and the pager just goes grey.
      expect(src.contains("label: const Text('Pick how many balls count')"),
          isFalse,
          reason: 'the pager names the destination, not the gap');
      expect(src.contains('fortyBallsReady(st,'), isTrue,
          reason: 'the pick only blocks once every net on the hole is in');
      expect(src.contains('allDone && !needsPick && !rp.submitting'), isTrue,
          reason: 'an outstanding pick disables `Hole N`, it does not rename it');
      expect(src.contains("hole < 18 && !_fortyBallsRound(rp)"), isTrue,
          reason: 'auto-advance must not carry the scorer past the pick');
    });

    test('the setup screen has no ListTile inside its bordered cards', () {
      // A ListTile paints its background and ink splash on the nearest
      // Material ancestor, and `_Card` is a decorated Container — so the
      // splash lands behind the card and Flutter asserts on every build.
      // Reported from a hot restart. A Row and a Switch instead.
      final src =
          File('lib/screens/forty_balls_setup_screen.dart').readAsStringSync();
      expect(src.contains('SwitchListTile('), isFalse,
          reason: 'use a Row + Switch inside _Card — see the note there');
      expect(src.contains('ListTile('), isFalse);
    });

    test('the leaderboard dispatches the tab', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect(src.contains("case 'forty_balls':"), isTrue);
      expect(src.contains('FortyBallsBoard'), isTrue);
    });
  });
}
