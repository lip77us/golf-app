/// test/annandale_friday_test.dart
/// -------------------------------
/// Annandale Friday on the phone: the team rules (which must say what the
/// server says), the summary the server actually sends, the tray, and the
/// wiring that makes the game reachable at all.
///
/// The fixture `fixtures/annandale_friday_hole2.json` is REAL engine output
/// (six golfers, gross, two holes in): on hole 1 match 1 is decided by the
/// 2nd ball (4 v 4, then 5 v 6), and every match has an auto press starting
/// on 3. Hand-written JSON would agree with the client by construction.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/utils/annandale_teams.dart';
import 'package:golf_mobile/utils/nassau_board_model.dart';
import 'package:golf_mobile/widgets/annandale_friday.dart';
import 'package:golf_mobile/widgets/nassau_board.dart';

AnnandaleFridaySummary _fixture() => AnnandaleFridaySummary.fromJson(
    jsonDecode(File('test/fixtures/annandale_friday_hole2.json')
        .readAsStringSync()) as Map<String, dynamic>);

String _src(String path) => File(path).readAsStringSync();

void main() {
  group('the team rules say what the server says', () {
    // Word for word: these are services.annandale_friday.shape_problem's.
    test('six as three pairs plays', () {
      expect(shapeProblem([[1, 2], [3, 4], [5, 6]]), isNull);
    });
    test('six any other way', () {
      expect(shapeProblem([[1, 2], [3, 4, 5, 6]]),
          'Six golfers play as three pairs.');
    });
    test('five as a pair and a three plays, in either order', () {
      expect(shapeProblem([[1, 2], [3, 4, 5]]), isNull);
      expect(shapeProblem([[3, 4, 5], [1, 2]]), isNull);
    });
    test('five any other way', () {
      expect(shapeProblem([[1, 2], [3, 4], [5]]),
          'Five golfers play as a pair and a three.');
    });
    test('a golfer on two teams', () {
      expect(shapeProblem([[1, 2], [2, 3], [4, 5]]),
          'A golfer is on two teams.');
    });
    test('a golfer on no team', () {
      expect(shapeProblem([[1, 2], [3, 4, 5]], roster: [1, 2, 3, 4, 5, 6]),
          '1 golfer is not on a team.');
    });
    test('placed in order', () {
      expect(defaultTeams([1, 2, 3, 4, 5, 6]), [[1, 2], [3, 4], [5, 6]]);
      expect(defaultTeams([1, 2, 3, 4, 5]), [[1, 2], [3, 4, 5]]);
    });
    test('the matches in the server\'s order', () {
      // Records compare their lists by identity, so read them as text.
      String show(List<(List<int>, List<int>)> ms) =>
          ms.map((m) => '${m.$1} v ${m.$2}').join(', ');
      expect(show(matchesFor([[1, 2], [3, 4], [5, 6]])),
          '[1, 2] v [3, 4], [1, 2] v [5, 6], [3, 4] v [5, 6]');
      expect(show(matchesFor([[1, 2], [3, 4, 5]])),
          '[1, 2] v [3, 4], [1, 2] v [3, 5], [1, 2] v [4, 5]');
    });
  });

  group('the summary the server sends', () {
    test('parses teams, golfers and three matches', () {
      final s = _fixture();
      expect(s.teams.length, 3);
      expect(s.players.length, 6);
      expect(s.matches.map((m) => m.number), [1, 2, 3]);
      expect(s.matches.first.side1Team, 0);
      expect(s.matches.first.side2Team, 1);
      expect(s.orderedIds, s.players.map((p) => p.playerId));
      expect(s.secondBallTiebreak, isTrue);
      expect(s.manualPress, isTrue);
    });
  });

  group('the tray', () {
    Future<void> mount(WidgetTester t, {int hole = 2, int? next = 3,
        void Function(AnnandaleFridayMatch, int)? onPress,
        bool gettingResult = false, bool notSynced = false}) async {
      t.view.physicalSize = const Size(1200, 2400);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(
          child: AnnandaleHoleTray(
            summary: _fixture(), hole: hole, nextHole: next,
            playerCount: 6, onEdit: () {},
            onPress: onPress ?? (_, __) {},
            gettingResult: gettingResult,
            notSynced: notSynced,
          ),
        )),
      ));
    }

    testWidgets('an edit in flight does not draw the old result', (t) async {
      // Hole 1 is in the summary, so without this the tray would state the
      // result of the number that was just replaced.
      await mount(t, hole: 1, next: 2, gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('2nd ball 5 v 6'), findsNothing);
    });

    testWidgets('an unsynced hole says so and does not draw the old result',
        (t) async {
      await mount(t, hole: 1, next: 2, notSynced: true);
      expect(find.text('Saved. The result shows once this hole syncs.'),
          findsOneWidget);
      expect(find.text('2nd ball 5 v 6'), findsNothing);
    });

    testWidgets('says why a tied best ball was won', (t) async {
      await mount(t, hole: 1, next: 2);
      expect(find.text('2nd ball 5 v 6'), findsOneWidget);
    });

    testWidgets('says the HOLE was won, not the match', (t) async {
      // A bare "Won" read as though the match were over.
      await mount(t, hole: 1, next: 2);
      expect(find.text('Won'), findsNothing);
      expect(find.text('Wins hole'), findsWidgets);
    });

    testWidgets('announces the press that starts on the next hole',
        (t) async {
      await mount(t);
      expect(find.text('Press starts 3'), findsNWidgets(3));
    });

    testWidgets('offers no Press at two down', (t) async {
      // can_press is false in all three: 2 down is the auto press's.
      await mount(t);
      expect(find.text('Press'), findsNothing);
    });

    testWidgets('waits rather than invents a hole the server has not got',
        (t) async {
      await mount(t, hole: 7, next: 8);
      expect(find.text('Saved. The result shows once this hole syncs.'),
          findsOneWidget);
    });

    testWidgets('says nothing about the skin until the server has the hole',
        (t) async {
      // Found on the phone: an unplayed hole's skins row has no winner, and
      // the tray read it as "No skin" while the hole was still unsent.
      t.view.physicalSize = const Size(1200, 2400);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final skins = SkinsSummary.fromJson({
        'holes': [
          {'hole': 7, 'winner_id': null, 'skins_value': 1, 'is_carry': false},
        ],
      });
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: AnnandaleHoleTray(
          summary: _fixture(), hole: 7, nextHole: 8, playerCount: 6,
          skins: skins, onEdit: () {}, onPress: (_, __) {},
        )),
      ));
      expect(find.text('No skin'), findsNothing);
    });
  });

  group('found on the phone', () {
    test('the keypad posts the hole on its last score', () {
      // It never did: 40 Balls posts with its count, and this game has no
      // count, so the hole sat unsent under a tray with nothing in it.
      final src = _src('lib/screens/score_entry_screen.dart');
      final at = src.indexOf('Annandale Friday posts the hole on its last');
      expect(at, greaterThan(0));
      expect(src.substring(at, at + 1400), contains('_saveCurrentHole('));
    });

    test("the keypad's strokes are the game's, not full handicap", () {
      // It said "1 stroke" to the low man, who plays off scratch.
      expect(_fixture().players.every((p) => p.strokesInPlay == 0), isTrue,
          reason: 'the fixture is gross, so nobody strokes');
      final src = _src('lib/screens/score_entry_screen.dart');
      final at = src.indexOf('int _keypadStrokes(');
      expect(src.substring(at, at + 900), contains('strokesInPlay'));
    });

    test('the ledger shows the live figure until the round is final', () {
      // Two holes in, nothing has settled, but Bill & Tom are up.
      final s = _fixture();
      final bill = s.players.first;
      expect(bill.net, 0);
      expect(bill.liveNet, greaterThan(0));
      expect(s.players.fold<double>(0, (a, p) => a + p.liveNet).abs(),
          lessThan(0.005));
      expect(_src('lib/screens/leaderboard_screen.dart'),
          contains('final total = done ? p.net : p.liveNet;'));
    });

    test("the keypad codes keys against the golfer's own par", () {
      // Kim's tee plays hole 1 as a par 5; the keypad said "par 4".
      final src = _src('lib/screens/score_entry_screen.dart');
      final at = src.indexOf('FortyBallsKeypad(');
      expect(src.substring(at, at + 500),
          contains('?.scoreFor(fbMember.player.id)?.par'));
    });

    test('a closed nine reads as its result on the pill', () {
      // Paul's round: front won 4&2 on the 7th, the 8th played for the
      // presses. The pill said "5 UP · front · thru 8" under a board saying
      // "4&2 Final". Fixture is the engine's output for those holes.
      final s = AnnandaleFridaySummary.fromJson(jsonDecode(
          File('test/fixtures/annandale_friday_front_closed.json')
              .readAsStringSync()) as Map<String, dynamic>);
      final f = s.matches.first.summary.front9;
      expect(f.margin, 5);
      expect((f.decidedMargin, f.decidedRemaining), (4, 2));
      final src = _src('lib/screens/leaderboard_screen.dart');
      expect(src, contains('annandaleNineAt(bet, bet.margin'));
      expect(src, contains("'\$nine · final'"));
    });

    test('the tray reads a closed nine and press as their result', () {
      // Same round, the tray on the 8th: the front showed "5 UP" and P1
      // "3 UP", though the front closed 4&2 on the 7th and P1 3&1 on the 8th.
      final s = AnnandaleFridaySummary.fromJson(jsonDecode(
          File('test/fixtures/annandale_friday_front_closed.json')
              .readAsStringSync()) as Map<String, dynamic>);
      final m = s.matches.first.summary;
      String at(int hole) {
        final pos = m.holes.indexWhere((x) => x.hole == hole);
        final h = m.holes[pos];
        final b = annandaleNineAt(m.front9, h.front9Margin ?? 0, pos,
            front: true);
        return b.closedWith != null
            ? '${b.margin}&${b.closedWith}' : '${b.margin}';
      }
      expect(at(6), '3');      // before it closed: the running margin
      expect(at(7), '4&2');    // the hole it closed on
      expect(at(8), '4&2');    // not "5"
      final p1 = m.presses.firstWhere((p) => p.startHole == 5);
      final p2 = m.presses.firstWhere((p) => p.startHole == 8);
      expect(annandalePressAt(p1, 7, front: true).closedWith, 1);  // 8th
      expect(annandalePressAt(p1, 6, front: true).closedWith, isNull);
      expect(annandalePressAt(p2, 7, front: true).closedWith, isNull);
    });

    test('the 18 is on the tray and the pills', () {
      // It was in neither: the tray showed the nine and its presses, the
      // pill the nine alone.
      final s = AnnandaleFridaySummary.fromJson(jsonDecode(
          File('test/fixtures/annandale_friday_front_closed.json')
              .readAsStringSync()) as Map<String, dynamic>);
      final m = s.matches.first.summary;
      expect(annandaleOverallAt(m.overall, m.overall.margin, 7).margin, 5);
      expect(annandaleOverallAt(m.overall, m.overall.margin, 7).closedWith,
          isNull);   // 5 up with ten to play is not closed
      expect(_src('lib/widgets/annandale_friday.dart'),
          contains("_status('18', annandaleOverallAt("));
      expect(_src('lib/screens/leaderboard_screen.dart'),
          contains('annandaleOverallAt(n.overall'));
    });

    test('one place for money, and the totals show what they are made of',
        () {
      // Paul: "+$40 on the board, +$70 in net position, $10 bet, $10 press
      // — a lot of numbers that are confusing."
      final src = _src('lib/screens/leaderboard_screen.dart');
      expect(src, contains('noMoney: true'));          // board: status only
      expect(src, contains('for (final m in p.byMatch)'));
      final s = _fixture();
      for (final p in s.players) {
        expect(p.byMatch.length, 2);
        expect((p.byMatch.fold<double>(0, (a, m) => a + m.liveNet)
                - p.liveNet).abs(), lessThan(0.005));
      }
    });

    test('a live press says how much is left, not "live"', () {
      // Paul's round: Press 8–9, 1 up with the 9th to play, read "1 UP ·
      // live". A lead equal to what is left is dormie.
      final closed = AnnandaleFridaySummary.fromJson(jsonDecode(
          File('test/fixtures/annandale_friday_front_closed.json')
              .readAsStringSync()) as Map<String, dynamic>);
      final b1 = NassauBoardData.fromSummary(closed.matches.first.summary);
      final p2 = b1.presses.firstWhere((p) => p.from == 8);
      expect((p2.view.headline, p2.view.sub), ('1 UP', 'dormie'));
      // Two holes in, the press from the 3rd is level with seven to play.
      final b2 = NassauBoardData.fromSummary(_fixture().matches.first.summary);
      final p1 = b2.presses.firstWhere((p) => p.from == 3);
      expect((p1.view.headline, p1.view.sub), ('AS', '7 to play'));
    });

    testWidgets('the 18 is a light card that names who is up', (t) async {
      // The dark card held only "Overall · 3 UP" once the money left it:
      // the loudest thing on the board, and a swatch was all that said
      // whose lead it was.
      t.view.physicalSize = const Size(1200, 3000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final s = AnnandaleFridaySummary.fromJson(jsonDecode(
          File('test/fixtures/annandale_friday_front_closed.json')
              .readAsStringSync()) as Map<String, dynamic>);
      final data = NassauBoardData.fromSummary(s.matches.first.summary,
          showSides: false, noMoney: true);
      await t.pumpWidget(MaterialApp(home: Scaffold(
          body: SingleChildScrollView(child: NassauBoard(data: data)))));
      // "18" is also the back nine's last tile, so assert the label pair:
      // the card's own label and the leader it names.
      expect(find.text('18'), findsNWidgets(2));
      expect(find.text('${data.sides[0].name} '), findsOneWidget);
      expect(find.text('5 UP'), findsOneWidget);
      expect(find.textContaining('each'), findsNothing);   // no money line
    });

    test('a setup step opens at its top', () {
      expect(_src('lib/screens/annandale_friday_setup_screen.dart'),
          contains('key: ValueKey(_step)'));
    });
  });

  group('the game is reachable', () {
    test('picked from 5–6, the only primary there', () {
      final m = gameMeta(GameIds.annandaleFriday)!;
      expect(m.enabled, isTrue);
      expect(m.supportsSize(5) && m.supportsSize(6), isTrue);
      // Stroke Play and Stableford take any count, but on a foursome's card;
      // offering them here would split six golfers into two groups.
      expect(
          casualGames.where((g) => !g.sideGameOnly && fitsFiveOrSix(g))
              .map((g) => g.id),
          [GameIds.annandaleFriday]);
      expect(_src('lib/screens/casual_round_screen.dart'),
          contains('return fitsFiveOrSix(m);'));
    });

    test('side games are Skins, Spots and Stroke Play, at five and six', () {
      for (final n in [5, 6]) {
        expect(sideGamesFor(GameIds.annandaleFriday, size: n)
            .map((g) => g.id).toSet(),
            {GameIds.skins, GameIds.spots, GameIds.strokePlay});
      }
      expect(sideGamesForFilter(GameIds.annandaleFriday, kFiveOrSix)
          .map((g) => g.id).toSet(),
          {GameIds.skins, GameIds.spots, GameIds.strokePlay});
    });

    test('create, hub, route table, score entry and board all know it', () {
      expect(_src('lib/utils/create_casual_round.dart'),
          contains("'/annandale-friday-setup'"));
      expect(_src('lib/main.dart'), contains("case '/annandale-friday-setup'"));
      final hub = _src('lib/screens/round_screen.dart');
      expect(hub, contains("route = '/annandale-friday-setup'"));
      expect(hub, contains("'annandale_friday': '/annandale-friday-setup'"));
      final entry = _src('lib/screens/score_entry_screen.dart');
      expect(entry, contains('rp.loadAnnandaleFriday('));
      expect(entry, contains('AnnandaleHoleTray('));
      // One keypad gate for both games that use it, so they cannot drift.
      expect(entry, contains('useKeypad: _keypadRound(rp)'));
      expect(entry, contains('final fbActive = _keypadRound(rp)'));
      expect(_src('lib/screens/leaderboard_screen.dart'),
          contains("case 'annandale_friday':"));
    });

    test('Skins and Spots setups seat the whole card', () {
      for (final f in ['lib/screens/skins_setup_screen.dart',
                       'lib/screens/spots_setup_screen.dart']) {
        expect(_src(f), contains('n <= _cardSize'), reason: f);
      }
    });
  });

  test('one set of team colours', () {
    expect(annandaleTeamColour(0), kAnnandaleTeamColours[0]);
    expect(annandaleTeamColour(2), kAnnandaleTeamColours[2]);
    for (final f in ['lib/screens/annandale_friday_setup_screen.dart',
                     'lib/screens/score_entry_screen.dart',
                     'lib/screens/leaderboard_screen.dart']) {
      expect(_src(f).contains('const List<Color> kAnnandaleTeamColours'),
          isFalse, reason: '$f must not keep its own copy');
    }
  });
}
