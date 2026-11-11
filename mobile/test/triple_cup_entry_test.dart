import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/side_colour.dart';
import 'package:golf_mobile/widgets/tray_result_row.dart';
import 'package:golf_mobile/widgets/triple_cup_entry.dart';

/// Triple Cup score entry — `handoff-triple-cup-score-entry` (11 Nov 2026).
///
/// The engine is covered in `scoring/tests/test_triple_cup_hole_card.py`,
/// which also WRITES the fixtures these draw (`REGEN_TC_FIXTURES=1`), so the
/// tray is tested against what the server really sends. The source guards
/// are about what the shared score-entry screen has to keep doing.

TripleCupHoleCard _card(String name) => TripleCupHoleCard.fromJson(
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>);

Future<void> _pump(WidgetTester t, TripleCupHoleCard card, {
  Size size = const Size(390, 1100),
  int? nextHole = 7,
  bool gettingResult = false,
  VoidCallback? onNext,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: TripleCupHoleTray(
          card: card,
          onEdit: () {},
          onPrev: () {},
          onNext: onNext ?? () {},
          nextHole: nextHole,
          gettingResult: gettingResult,
        ),
      ),
    ),
  ));
}

void main() {
  group('the cup strip', () {
    test('team 1 fills from the left and team 2 from the right', () {
      // 1½ – ½ of four: a cell and a half of blue, half a cell of orange.
      final f = [
        for (var i = 0; i < 4; i++) CupStrip.fills(1.5, 0.5, 4, i),
      ];
      expect(f, [(1.0, 0.0), (0.5, 0.0), (0.0, 0.0), (0.0, 0.5)]);
    });

    test('nothing scored fills nothing', () {
      for (var i = 0; i < 4; i++) {
        expect(CupStrip.fills(0, 0, 4, i), (0.0, 0.0));
      }
    });

    test('a finished cup leaves no cell out', () {
      // 3½ – ½: the halves meet in the last cell.
      final f = [
        for (var i = 0; i < 4; i++) CupStrip.fills(3.5, 0.5, 4, i),
      ];
      expect(f, [(1.0, 0.0), (1.0, 0.0), (1.0, 0.0), (0.5, 0.5)]);
      for (final (a, b) in f) {
        expect(a + b, 1.0);
      }
    });

    test('it does not follow play order', () {
      // Team 2 took the FIRST match: its point is still on the right.
      expect(CupStrip.fills(0, 1, 4, 0), (0.0, 0.0));
      expect(CupStrip.fills(0, 1, 4, 3), (0.0, 1.0));
    });
  });

  group('a side\'s colour', () {
    test('a casual cup is the app\'s blue and orange', () {
      expect(tripleCupSideColour(null, 1), sideColour(1));
      expect(tripleCupSideColour(null, 2, onDark: true),
          sideColour(2, onDark: true));
    });

    test('a team cup wears its own colours, lifted for the tray', () {
      final light = tripleCupSideColour('red', 2);
      final dark = tripleCupSideColour('red', 2, onDark: true);
      expect(light, resolveTripleCupTeamColor('red', kTripleCupTeam2Color));
      expect(HSLColor.fromColor(dark).lightness,
          greaterThanOrEqualTo(0.69));
      expect(dark, isNot(sideColour(2, onDark: true)));
    });
  });

  group('the tray', () {
    testWidgets('the fourball ends: the hole, the match, the cup, what next',
        (t) async {
      await _pump(t, _card('triple_cup_hole6_fourball_ends'));
      expect(find.text('All 4 scores in'), findsOneWidget);
      expect(find.text('HOLE 6 · BEST BALL'), findsOneWidget);
      expect(find.text('FOURBALL · HOLES 1–6'), findsOneWidget);
      expect(find.byType(TrayResultRow), findsOneWidget);
      expect(find.text('Paul + Hal win'), findsOneWidget);
      expect(find.text('2 UP'), findsOneWidget);
      expect(find.text('1 point to Team 1'), findsOneWidget);
      expect(find.text('THE CUP'), findsOneWidget);
      expect(find.text('of 4'), findsOneWidget);
      expect(find.text('3 points still out · 2½ wins'), findsOneWidget);
      expect(find.text('NEXT · FOURSOMES'), findsOneWidget);
      expect(find.text('One ball a side from 7'), findsOneWidget);
      // The forward button names the SEGMENT, which a pager cannot.
      expect(find.text('Foursomes · hole 7 ›'), findsOneWidget);
    });

    testWidgets('six tiles, one a hole', (t) async {
      await _pump(t, _card('triple_cup_hole6_fourball_ends'));
      for (final n in ['1', '2', '3', '4', '5', '6']) {
        expect(find.text(n), findsWidgets);
      }
    });

    testWidgets('one ball a side is two balls, not four scores', (t) async {
      await _pump(t, _card('triple_cup_hole8_foursomes'), nextHole: 9);
      expect(find.text('Both balls in'), findsOneWidget);
      expect(find.text('HOLE 8 · ONE BALL A SIDE'), findsOneWidget);
      expect(find.text('All square'), findsOneWidget);
      expect(find.text('AS'), findsOneWidget);
      expect(find.text('thru 2 of 6 · 4 to play'), findsOneWidget);
      expect(find.text('Halved'), findsOneWidget);
      expect(find.text('Hole 9 ›'), findsOneWidget);
      expect(find.textContaining('NEXT'), findsNothing);
    });

    testWidgets('the singles are a line a match, and no tiles', (t) async {
      await _pump(t, _card('triple_cup_hole16_singles'), nextHole: 17);
      expect(find.text('HOLE 16 · SINGLES'), findsOneWidget);
      expect(find.byType(TrayResultRow), findsNWidgets(2));
      expect(find.text('1 UP'), findsOneWidget);
      expect(find.text('2 UP'), findsOneWidget);
      // Two strips of six would double the tray.
      expect(find.text('13'), findsNothing);
      expect(find.text('1½'), findsOneWidget);
      expect(find.text('½'), findsOneWidget);
    });

    testWidgets('round over: the cup, and one stake a man', (t) async {
      await _pump(t, _card('triple_cup_hole18_round_over'), nextHole: null);
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('Team 1 wins the cup'), findsOneWidget);
      expect(find.text('FINAL · WINNERS TAKE ALL'), findsOneWidget);
      expect(find.text('\$25 A MAN'), findsOneWidget);
      expect(find.text('Paul & Hal'), findsOneWidget);
      expect(find.text('+\$25 each'), findsOneWidget);
      expect(find.text('Pete and Wendy pay \$25 each'), findsOneWidget);
      expect(find.text('Finish round ›'), findsOneWidget);
    });

    testWidgets('a team cup finishes onto the cup leaderboard', (t) async {
      final j = jsonDecode(File(
              'test/fixtures/triple_cup_hole18_round_over.json')
          .readAsStringSync()) as Map<String, dynamic>;
      j['tournament'] = true;
      j['money'] = null;
      j['team_names'] = ['Blue Team', 'Red Team'];
      j['team_colours'] = ['blue', 'red'];
      j['cup'] = {...j['cup'] as Map<String, dynamic>, 'label': 'This group',
        'line': 'Group final · Blue Team 3½, Red Team ½'};
      j['cup_total'] = {
        'name': 'Tilden Cup', 'team1_points': 6.5, 'team2_points': 4.5,
        'team1': '6½', 'team2': '4½', 'total': 24.0,
        'to_win': '12½ to win',
        'line': 'Blue Team need 6 more, Red Team 8 · 3 groups still out',
      };
      await _pump(t, TripleCupHoleCard.fromJson(j), nextHole: null);
      expect(find.text('THIS GROUP'), findsOneWidget);
      expect(find.text('TILDEN CUP'), findsOneWidget);
      expect(find.text('12½ to win'), findsOneWidget);
      expect(find.byType(CupStrip), findsOneWidget);
      expect(find.byType(CupNeedle), findsOneWidget);
      expect(find.textContaining('A MAN'), findsNothing);
      expect(find.text('Finish round · cup leaderboard ›'), findsOneWidget);
    });

    testWidgets('a halved cup says nothing changes hands', (t) async {
      final j = jsonDecode(File(
              'test/fixtures/triple_cup_hole18_round_over.json')
          .readAsStringSync()) as Map<String, dynamic>;
      j['money'] = {
        'label': 'Final · winners take all', 'stake': '\$25 a man',
        'winner': null, 'head': '', 'amount': '',
        'line': 'Cup halved · no money changes hands',
      };
      await _pump(t, TripleCupHoleCard.fromJson(j), nextHole: null);
      expect(find.text('Cup halved · no money changes hands'),
          findsOneWidget);
      expect(find.textContaining('\$0'), findsNothing);
      expect(find.textContaining('each'), findsNothing);
    });

    testWidgets('it holds its figures back while the result is on its way',
        (t) async {
      await _pump(t, _card('triple_cup_hole6_fourball_ends'),
          gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('THE CUP'), findsNothing);
      // The arrows stay: a group on a bad signal must be able to move on.
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    });

    testWidgets('the forward button is the one it is given', (t) async {
      var taps = 0;
      await _pump(t, _card('triple_cup_hole8_foursomes'),
          nextHole: 9, onNext: () => taps++);
      await t.tap(find.text('Hole 9 ›'));
      expect(taps, 1);
    });

    testWidgets('it survives a narrow, short phone', (t) async {
      await _pump(t, _card('triple_cup_hole6_fourball_ends'),
          size: const Size(320, 568));
      expect(t.takeException(), isNull);
      // The buttons are outside the scrolling box, so they are on screen.
      expect(find.text('Foursomes · hole 7 ›').hitTestable(), findsOneWidget);
    });
  });

  group('the shared screen keeps doing its job', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    String body(String signature) {
      final at = src.indexOf(signature);
      expect(at, greaterThan(0), reason: signature);
      return src.substring(at, src.indexOf('\n  }\n', at));
    }

    test('Triple Cup enters on the keypad', () {
      expect(body('bool _keypadRound(RoundProvider rp)'),
          contains('primary == GameIds.tripleCup'));
    });

    test('its hole ends in a tray, so it posts itself and stays', () {
      final at = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      expect(src.substring(at, src.indexOf(';', at)),
          contains('_tripleCupCard(rp) != null'));
    });

    test('the keypad takes its strokes from the card', () {
      expect(
          RegExp(r'final tc = _tripleCupCard\(rp\);\s*'
                  r'if \(tc != null\) \{\s*'
                  r'final s = tc\.strokesFor\(m\.player\.id\);\s*'
                  r'if \(s != null\) return s;')
              .hasMatch(body('int _keypadStrokes(Membership m, Scorecard sc)')),
          isTrue);
    });

    test('the pager hides under the tray', () {
      final at = src.indexOf('if (!sixTray');
      expect(at, greaterThan(0));
      expect(src.substring(at, src.indexOf(')', at)), contains('!tcTray'));
    });

    test('the card is fetched for the hole on screen', () {
      expect(body('void _ensureTripleCupCard(RoundProvider rp)'),
          contains('.loadTripleCupHole(widget.foursomeId, _selectedHole)'));
      expect(src, contains('_ensureTripleCupCard(rp);'));
    });

    test('the last hole finishes the round from the tray', () {
      final at = src.indexOf('TripleCupHoleTray(');
      final call = src.substring(at, src.indexOf('else if (fourTray)', at));
      expect(call, contains('_completeRound(ctx, players, par)'));
      expect(call, contains('nextHole: _nextHoleInOrder(rp)'));
    });

    test('the cup and the segment cards left the screen', () {
      expect(src, isNot(contains('_TripleCupMatchGrid')));
      expect(src, isNot(contains('_tripleCupRibbon')));
      expect(src, isNot(contains('tripleCupCardHoles(')));
    });
  });
}
