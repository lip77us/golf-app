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
import 'package:golf_mobile/widgets/annandale_friday.dart';

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
        void Function(AnnandaleFridayMatch, int)? onPress}) async {
      t.view.physicalSize = const Size(1200, 2400);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(
          child: AnnandaleHoleTray(
            summary: _fixture(), hole: hole, nextHole: next,
            playerCount: 6, onEdit: () {},
            onPress: onPress ?? (_, __) {},
          ),
        )),
      ));
    }

    testWidgets('says why a tied best ball was won', (t) async {
      await mount(t, hole: 1, next: 2);
      expect(find.text('2nd ball 5 v 6'), findsOneWidget);
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
      expect(find.text('Waiting for this hole to sync…'), findsOneWidget);
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
