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
  bool dq = false,
  double? average = 2.4,
  Map<int, int> nets = const {1: 3, 2: 4, 3: 5, 4: 6},
}) =>
    FortyBallsPickerState.fromJson({
      'hole': 11, 'group_size': groupSize, 'active_here': activeHere,
      'budget': groupSize * 10, 'spent': spent, 'left': left,
      'holes_after': holesAfter, 'capacity': capacity, 'lo': lo, 'hi': hi,
      'dq': dq, 'count': count, 'app_set': false, 'average': average,
      'slack': slack, 'can_pick': canPick, 'scores_in': scoresIn,
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

    testWidgets('it waits for the last score rather than showing dead buttons',
        (tester) async {
      await pumpPicker(tester, picker(scoresIn: false));
      expect(find.text('Waiting on the last score'), findsOneWidget);
      expect(find.text('0'), findsNothing);
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
          capacity: 28, slack: 0, average: null));
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
    }) => {
          'foursome_id': number, 'group_number': number, 'group_size': size,
          'budget': size * 10, 'spent': spent, 'left': left, 'slack': slack,
          'capacity': capacity, 'holes_left': 3,
          'total': total, 'factor': factor, 'ranking_total': ranking,
          'dq': dq, 'rank': rank, 'tied': false,
          'payout': rank == 1 ? 150.0 : 0.0,
          'per_person_payout': rank == 1 ? 37.5 : 0.0, 'split_ways': size,
          'holes': [
            {'hole': 1, 'par': 4, 'count': 2, 'app_set': false, 'result': -1,
             'counted_ids': [1, 2],
             'scores': {'1': 3, '2': 4, '3': 5, '4': 6}},
            {'hole': 2, 'par': 4, 'count': 4, 'app_set': true, 'result': 2,
             'counted_ids': [1, 2, 3, 4],
             'scores': {'1': 4, '2': 4, '3': 5, '4': 5}},
          ],
          'holes_in_play': [1, 2],
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

    test('score entry POSTS the hole and waits for the pick', () {
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
      expect(src.contains('Pick how many balls count'), isTrue,
          reason: 'the pager must NAME what is missing, not go grey');
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
