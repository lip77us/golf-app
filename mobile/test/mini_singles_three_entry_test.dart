import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/mini_singles_three_entry.dart';

/// Mini Singles, a group of three —
/// `~/Downloads/handoff-mini-singles-three-score-entry` (11 Nov 2026).
///
/// The engine is covered in `scoring/tests/test_three_person_hole_card.py`,
/// which also WRITES the fixtures these draw (`REGEN_M3_FIXTURES=1`): the
/// handoff's worked example played through the real engine.

MiniSinglesThreeCard _card(String name) => MiniSinglesThreeCard.fromJson(
    jsonDecode(File('test/fixtures/mini_singles_three_$name.json')
        .readAsStringSync()) as Map<String, dynamic>);

Future<void> _tray(WidgetTester t, MiniSinglesThreeCard card, {
  Size size = const Size(390, 1500),
  VoidCallback? onNext,
  bool gettingResult = false,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MediaQuery(
          data: MediaQueryData(size: Size(size.width, size.height + 400)),
          child: MiniSinglesThreeTray(
            card: card,
            onEdit: () {},
            onPrev: () {},
            onNext: onNext ?? () {},
            gettingResult: gettingResult,
          ),
        ),
      ),
    ),
  ));
}

void main() {
  group('the model', () {
    test('strokes are the phase\'s, by golfer', () {
      final c = _card('hole14');
      expect(c.isFinals, isTrue);
      final sam = c.players.firstWhere((p) => p.first == 'Sam');
      expect(c.strokesFor(sam.playerId), 1);
      final dave = c.players.firstWhere((p) => p.first == 'Dave');
      expect(c.strokesFor(dave.playerId), 0);
      expect(c.strokesFor(-1), isNull);
    });

    test('the third man is out of the match', () {
      final roles = {
        for (final p in _card('hole14').players) p.first: p.role
      };
      expect(roles, {'Paul': 'finalist', 'Dave': 'third', 'Sam': 'finalist'});
    });
  });

  group('the points tray', () {
    testWidgets('one row a golfer by total, ties sharing a place', (t) async {
      await _tray(t, _card('hole9'));
      expect(find.text('HOLE 9 · POINTS'), findsOneWidget);
      expect(find.text('T2'), findsNWidgets(2));
      expect(find.text('33'), findsOneWidget);
      expect(find.text('24'), findsNWidgets(2));
      expect(find.textContaining('level for 2nd'), findsOneWidget);
      expect(find.text('Points play on from 10'), findsOneWidget);
    });

    testWidgets('while points play on the finals sits beside it, dashed',
        (t) async {
      await _tray(t, _card('hole10'));
      expect(find.text('Paul v Dave'), findsOneWidget);
      expect(find.text('Paul v Sam'), findsOneWidget);
      expect(find.text('Paul 1 UP'), findsNWidgets(2));
      expect(find.text('from the 10th, against either'), findsOneWidget);
    });

    testWidgets('once 2nd is clear the line names the finalists', (t) async {
      await _tray(t, _card('hole11'));
      expect(find.textContaining('Paul and Sam play the finals'),
          findsOneWidget);
      expect(find.text('from the 10th, against either'), findsNothing);
    });

    testWidgets('the forward button is the next hole', (t) async {
      var n = 0;
      await _tray(t, _card('hole5'), onNext: () => n++);
      await t.tap(find.text('Hole 6 ›'));
      expect(n, 1);
    });

    testWidgets('a hole waiting for its result draws no blocks', (t) async {
      await _tray(t, _card('hole5'), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('POINTS'), findsNothing);
    });
  });

  group('the finals tray', () {
    testWidgets('the hole line, the standing and the tiles', (t) async {
      await _tray(t, _card('hole14'));
      expect(find.text('HOLE 14 · FINALS'), findsOneWidget);
      expect(find.text('Halved'), findsOneWidget);
      expect(find.text('1 UP'), findsOneWidget);
      expect(find.text('thru 5 of 9 · 4 to play'), findsOneWidget);
      for (var h = 10; h <= 18; h++) {
        expect(find.text('$h'), findsOneWidget);
      }
    });

    testWidgets('round over: the winner and the money', (t) async {
      await _tray(t, _card('hole18'));
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('Sam Reid'), findsNWidgets(2)); // winner + result row
      expect(find.textContaining('Sam wins the finals 1 UP'), findsOneWidget);
      expect(find.text('+\$10'), findsOneWidget);
      expect(find.text('−\$10'), findsOneWidget);
      expect(find.text('\$30 POT'), findsOneWidget);
      expect(find.text('Finish round ›'), findsOneWidget);
    });

    testWidgets('fits a 320pt phone', (t) async {
      await _tray(t, _card('hole18'), size: const Size(320, 1500));
      expect(t.takeException(), isNull);
    });
  });

  group('the screen', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('the keypad round and the tray gate include the three-man card', () {
      expect(src, contains('_threeRound(rp) ||'));
      expect(src, contains('_threeCard(rp) != null ||'));
    });

    test('the pager hides under the tray', () {
      expect(src, contains('!msTray && !m3Tray'));
    });

    test('Stroke Play stands down for a group of three', () {
      expect(src, contains('_miniSinglesRound(rp) || _threeRound(rp)'));
    });

    test('the keypad takes its strokes from the card', () {
      expect(src, contains('m3.strokesFor(m.player.id)'));
    });

    test('a three-man round is not the four-man bracket', () {
      final at = src.indexOf('bool _threeRound(');
      final body = src.substring(at, src.indexOf('int? _threeCardAsked', at));
      expect(body, contains('realPlayers.length != 3'));
    });
  });

  group('the leaderboard card', () {
    final lb = File('lib/screens/leaderboard_screen.dart').readAsStringSync();

    test('shows the play-on, not a sudden death', () {
      expect(lb, contains('class _TpmPlayOnSection'));
      expect(lb, isNot(contains('class _TpmTiebreakSection')));
      expect(lb, isNot(contains("Text('Sudden Death'")));
      expect(lb, contains("statusLabel = 'Points play on'"));
    });

    test('is named for the game the setup and score screen call it', () {
      expect(lb, contains("'Mini Singles — \${_hcapLabel(hcap)}'"));
    });
  });

  group('the board\'s scorecard', () {
    test('is the shared card with points, as Stableford draws it', () {
      final lb = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      final at = lb.indexOf("summary['scorecard'] as Map<String, dynamic>?;\n"
          "            final scHoles");
      expect(at, greaterThan(0));
      final body = lb.substring(at, at + 1600);
      expect(body, contains('HoleGridScorecard('));
      expect(body, contains('showPoints: true'));
      expect(body, contains('showStrokes: false'));
    });
  });

  group('Points plays on the shared screen', () {
    // **Points' tray was built on `points_531_screen`, which nothing opens**
    // (setup and the hub send the group to `/score-entry`), so the sim kept
    // showing the old inline picker (Paul, 11 Nov 2026). It lives here now.
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('the keypad round, the tray gate and the pager include it', () {
      expect(src, contains('_pointsRound(rp);'));
      expect(src, contains('_pointsCard(rp) != null ||'));
      expect(src, contains('&& !ptsTray)'));
    });

    test('the tray is PointsHoleTray, fed the screen\'s own card', () {
      expect(src, contains('PointsHoleTray('));
      expect(src, contains('rp.pointsHole(_selectedHole)'));
    });

    test('the keypad takes the strokes Points issues', () {
      expect(src, contains('pts.playerById(m.player.id)?.strokes'));
    });

    test('only when Points is the round\'s game, with three golfers', () {
      final at = src.indexOf('bool _pointsRound(');
      final body = src.substring(at, src.indexOf('int? _pointsCardAsked', at));
      expect(body, contains('!= GameIds.points531'));
      expect(body, contains('realPlayers.length == 3'));
    });
  });
}
