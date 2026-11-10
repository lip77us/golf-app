import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/nassau_entry.dart';

/// Nassau score entry — `~/Downloads/handoff-nassau-score-entry`.
///
/// **The fixtures are REAL engine output**, written by
/// `REGEN_NASSAU_FIXTURES=1 manage.py test scoring.tests.test_nassau_hole_card`.
/// The press rules are the sharpest thing in the app, so a tray tested
/// against hand-written JSON would be tested against what somebody thought
/// the server sends. The engine itself is covered in
/// `scoring/tests/test_nassau_hole_card.py`; these are about what the tray
/// DRAWS, and the source guards about what the shared screen has to keep
/// doing.

Map<String, dynamic> _fixture(String name) => jsonDecode(
        File('test/fixtures/$name.json').readAsStringSync())
    as Map<String, dynamic>;

NassauHoleCard _card(String name, {Map<String, dynamic> over = const {}}) =>
    NassauHoleCard.fromJson({..._fixture(name), ...over});

Future<void> _pump(WidgetTester t, NassauHoleCard card,
    {void Function(String side)? onPress, bool gettingResult = false,
     Size size = const Size(390, 900)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: NassauHoleTray(
        card: card,
        onEdit: () {},
        onNext: () {},
        onPrev: () {},
        onPress: onPress,
        gettingResult: gettingResult,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the card parses what the server sends', () {
    test('the 2nd-ball hole and its auto press', () {
      final c = _card('nassau_hole2_press');
      expect(c.winner, 'team1');
      expect(c.reason, '2nd ball 4 v 5');
      expect(c.claremont, isFalse);
      expect(c.singles, isFalse);
      expect(c.players.length, 4);
      final front = c.lines.firstWhere((l) => l.key == 'front');
      expect(front.chips.map((x) => x.text),
          ['Front 2 UP', 'P1 starts 3']);
      // A press called on this hole has not reached its first hole, so it is
      // a promise rather than a bet.
      expect(front.chips.last.isPending, isTrue);
      expect(front.chips.first.leader, 1);
    });

    test('a manual press in play is labelled as one', () {
      final c = _card('nassau_hole7_manual');
      final chips =
          c.lines.firstWhere((l) => l.key == 'front').chips;
      expect(chips.map((x) => x.text), ['Front AS', 'P1 manual 1 UP']);
      expect(chips.first.leader, isNull, reason: 'AS belongs to nobody');
      expect(chips.last.manual, isTrue);
    });

    test('Claremont carries the balls grid and its own lines', () {
      final c = _card('nassau_hole7_claremont');
      expect(c.claremont, isTrue);
      final b = c.bottom!;
      expect(b.balls.map((x) => x.low), [4, 4]);
      expect(b.balls.map((x) => x.high), [4, 5]);
      expect(b.balls[0].highWon, isTrue);
      expect(b.balls[0].lowWon, isFalse);
      expect(b.points, 1);
      expect(b.lines.firstWhere((l) => l.key == 'front').chips.first.text,
          'Front +1');
    });

    test('an empty hole has no winner and no bet', () {
      final c = _card('nassau_hole1_empty');
      expect(c.winner, isNull);
      expect(c.sides.every((s) => s.best == null), isTrue);
      expect(
          c.lines.firstWhere((l) => l.key == 'front').chips.first.isPending,
          isTrue);
    });
  });

  group('the tray', () {
    testWidgets('it names both sides and why the hole went that way',
        (t) async {
      await _pump(t, _card('nassau_hole2_press'));
      expect(find.text('All 4 scores in'), findsOneWidget);
      expect(find.text('HOLE 2 · NASSAU'), findsOneWidget);
      expect(find.text('FRONT NINE'), findsOneWidget);
      expect(find.text('Won'), findsOneWidget);
      expect(find.text('2nd ball 4 v 5'), findsOneWidget);
    });

    testWidgets('every bet in play is a chip', (t) async {
      await _pump(t, _card('nassau_hole2_press'));
      for (final s in ['FRONT', 'BACK', 'OVERALL']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(find.text('Front 2 UP'), findsOneWidget);
      expect(find.text('P1 starts 3'), findsOneWidget);
      expect(find.text('Back starts 10'), findsOneWidget);
    });

    testWidgets('a halved hole reads Halved, not Won', (t) async {
      await _pump(t, _card('nassau_hole7_claremont'));
      expect(find.text('Halved'), findsOneWidget);
      expect(find.text('Won'), findsNothing);
    });

    testWidgets('two golfers read Both scores in', (t) async {
      final c = _card('nassau_hole2_press', over: {
        'singles': true,
        'scored': 2,
        'players': _fixture('nassau_hole2_press')['players'].sublist(0, 2),
      });
      await _pump(t, c);
      expect(find.text('Both scores in'), findsOneWidget);
      expect(find.text('All 2 scores in'), findsNothing);
    });

    testWidgets('the money is EACH · NOW while a bet is live', (t) async {
      await _pump(t, _card('nassau_hole2_press'));
      expect(find.text('EACH · NOW'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsNothing);
      expect(find.text('+\$20'), findsOneWidget);
      expect(find.text('−\$20'), findsOneWidget);
    });

    testWidgets('and FINAL, EACH once the round is over', (t) async {
      await _pump(t, _card('nassau_hole2_press',
          over: {'round_over': true, 'next_hole': null}));
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('ROUND OVER'), findsOneWidget);
    });

    testWidgets('the last hole finishes the round, because the tray IS the '
        'bottom bar', (t) async {
      await _pump(t, _card('nassau_hole2_press', over: {'next_hole': null}));
      expect(find.text('Complete Round ›'), findsOneWidget);
    });

    testWidgets('a hole still syncing says so and draws no result',
        (t) async {
      await _pump(t, _card('nassau_hole2_press'), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('Front 2 UP'), findsNothing,
          reason: 'the chips would be the bets BEFORE this hole');
    });
  });

  group('Claremont', () {
    testWidgets('the balls grid names both sides and what the hole paid',
        (t) async {
      await _pump(t, _card('nassau_hole7_claremont'));
      expect(find.text('LOW'), findsOneWidget);
      expect(find.text('HIGH'), findsOneWidget);
      expect(find.text('HOLE'), findsOneWidget);
      expect(find.text('TOP'), findsOneWidget);
      expect(find.text('BOTTOM'), findsOneWidget);
      expect(find.text('low v low · 1 pt · press at 2 down'), findsOneWidget);
      expect(find.text('low + high · 2 pts · press at 4 down'),
          findsOneWidget);
      // Pine took the high ball, so the hole paid them one point.
      expect(find.text('+1'), findsWidgets);
    });

    testWidgets('the bottom game reads in POINTS', (t) async {
      await _pump(t, _card('nassau_hole7_claremont'));
      expect(find.text('Front +1'), findsOneWidget);
      expect(find.text('Overall +1'), findsOneWidget);
    });

    testWidgets('the money note splits the figure above it', (t) async {
      await _pump(t, _card('nassau_hole7_claremont'));
      expect(find.text('top \$0 · bottom +\$20, for Paul + Dave'),
          findsOneWidget);
    });

    testWidgets('and a plain Nassau draws no bottom game', (t) async {
      await _pump(t, _card('nassau_hole2_press'));
      expect(find.text('TOP'), findsNothing);
      expect(find.text('BOTTOM'), findsNothing);
      expect(find.text('LOW'), findsNothing);
    });
  });

  group('the press button', () {
    testWidgets('it is offered only when the SERVER says so', (t) async {
      // The flag is the engine's whole answer — whether a manual press is
      // allowed, which game it is on, and on which nine. Offering a button
      // the server refuses is how the day bet's off switch went missing.
      await _pump(t, _card('nassau_hole7_manual'), onPress: (_) {});
      expect(find.text('Press'), findsNothing);

      await _pump(t, _card('nassau_hole7_manual', over: {'can_press': true}),
          onPress: (_) {});
      expect(find.text('Press'), findsOneWidget);
    });

    testWidgets('it names the game it presses', (t) async {
      final sides = <String>[];
      await _pump(t, _card('nassau_hole7_manual', over: {'can_press': true}),
          onPress: sides.add);
      await t.tap(find.text('Press'));
      await t.pump();
      expect(sides, ['top']);
    });

    testWidgets('Claremont offers one a game, at its own band', (t) async {
      // Two separate bets: the top is 1 point a hole and autos at 2, the
      // bottom is 2 points and autos at 4 — so they are rarely pressable at
      // the same moment, and never interchangeably.
      final sides = <String>[];
      await _pump(
          t,
          _card('nassau_hole7_claremont',
              over: {'can_press': true, 'can_press_bottom': true}),
          onPress: sides.add);
      expect(find.text('Press'), findsNWidgets(2));
      // The tray scrolls when the content is taller than its cap, so the
      // bottom game's button can start off-screen — bring it in, which is
      // what a thumb does. A bare `tap` silently misses.
      for (final f in [find.text('Press').first, find.text('Press').last]) {
        await t.ensureVisible(f);
        await t.pumpAndSettle();
        await t.tap(f);
      }
      await t.pump();
      expect(sides, ['top', 'bottom'],
          reason: 'the first button belongs to the TOP block');
    });

    testWidgets('and only the bottom one when only it is in its window',
        (t) async {
      final sides = <String>[];
      await _pump(
          t,
          _card('nassau_hole7_claremont',
              over: {'can_press': false, 'can_press_bottom': true}),
          onPress: sides.add);
      expect(find.text('Press'), findsOneWidget);
      await t.ensureVisible(find.text('Press'));
      await t.pumpAndSettle();
      await t.tap(find.text('Press'));
      await t.pump();
      expect(sides, ['bottom']);
    });
  });

  group('it fits a phone', () {
    testWidgets('nothing overflows at 320pt, Claremont included', (t) async {
      await _pump(t, _card('nassau_hole7_claremont'),
          size: const Size(320, 900));
      expect(t.takeException(), isNull);
    });

    testWidgets('nor with four long names', (t) async {
      await _pump(
          t,
          _card('nassau_hole2_press', over: {
            'sides': [
              {'side': 1, 'label': 'Bartholomew + Christopher',
               'player_ids': [1, 2], 'best': 4,
               'sub': '', 'result': 'won'},
              {'side': 2, 'label': 'Maximilian + Alexandria',
               'player_ids': [3, 4], 'best': 5,
               'sub': '', 'result': 'lost'},
            ],
            'money': [
              {'side': 1, 'label': 'Bartholomew + Christopher',
               'amount': 20.0},
              {'side': 2, 'label': 'Maximilian + Alexandria',
               'amount': -20.0},
            ],
          }),
          size: const Size(320, 900));
      expect(t.takeException(), isNull);
    });
  });

  group('the screen keeps what a game of its own would lose', () {
    final src =
        File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('Nassau enters on the shared keypad', () {
      expect(src, contains('primary == GameIds.nassau'));
    });

    test('its hole raises a tray, so the hole posts itself', () {
      // `_raisesTray` is the one gate — a hand-written list of games is what
      // left Las Vegas unposted, three packets running.
      final i = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      expect(i, greaterThan(0));
      final body = src.substring(i, src.indexOf(';', i));
      expect(body, contains('_nassauCard(rp) != null'));
    });

    test('the keypad takes its strokes from the CARD', () {
      // Nassau carries its own handicap mode and allowance, so the round's
      // stored full-net strokes would tell the low man he gets dots he does
      // not — the bug Sixes reported from the course.
      final i = src.indexOf('int _keypadStrokes(');
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('_nassauCard(rp)'));
    });

    test('the pager hides under the tray', () {
      expect(src, contains('!vgTray && !fourTray && !nasTray'));
    });

    test('the presses strip and the hole banner go quiet', () {
      // Both say what the tray says, shorter and higher up. Rabbit's grid
      // and Survivor's outcome line came off for the same reason.
      expect(src, contains('if (nasCard == null &&\n          nas != null &&'));
      expect(src, contains('if (nassauCard == null &&'));
    });
  });

  /// `~/Downloads/handoff-nassau-nine-score-entry`: the Nassau card over ONE
  /// match. Fixtures are real engine output, written by
  /// `REGEN_NASSAU_FIXTURES=1 manage.py test
  /// scoring.tests.test_nassau_nine_hole_card`.
  group('Nassau Nine', () {
    test('the card names the game, the span and its one line', () {
      final c = _card('nassau_nine_hole7_press');
      expect(c.title, 'Nassau Nine');
      expect(c.pressLine, 'match');
      expect(c.nine, 'holes 1–9');
      expect(c.lines.map((l) => l.key), ['match']);
      expect(c.lines.single.chips.map((x) => x.text),
          ['Match 2 UP', 'P1 starts 8']);
    });

    test('a card from an older server is a full Nassau', () {
      final c = _card('nassau_hole2_press',
          over: {'title': null, 'press_line': null});
      expect(c.title, 'Nassau');
      expect(c.pressLine, 'overall');
    });

    testWidgets('the tray is labelled for the game and its holes', (t) async {
      await _pump(t, _card('nassau_nine_hole7_press'));
      expect(find.text('HOLE 7 · NASSAU NINE'), findsOneWidget);
      expect(find.text('HOLES 1–9'), findsOneWidget);
      expect(find.text('MATCH'), findsOneWidget);
      for (final gone in ['FRONT', 'BACK', 'OVERALL']) {
        expect(find.text(gone), findsNothing);
      }
      expect(find.text('Match 2 UP'), findsOneWidget);
      expect(find.text('P1 starts 8'), findsOneWidget);
    });

    testWidgets('Press sits on the one line, when the engine offers it',
        (t) async {
      String? side;
      await _pump(t, _card('nassau_nine_hole1_press_offered'),
          onPress: (s) => side = s);
      expect(find.text('Press'), findsOneWidget);
      await t.tap(find.text('Press'));
      expect(side, 'top');
    });

    testWidgets('no Press when it does not', (t) async {
      await _pump(t, _card('nassau_nine_hole7_press'), onPress: (_) {});
      expect(find.text('Press'), findsNothing);
    });

    testWidgets('the ninth is the end, and still says which holes',
        (t) async {
      await _pump(t, _card('nassau_nine_hole9_final'));
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('HOLES 1–9'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('Complete Round ›'), findsOneWidget);
      expect(find.text('+\$20'), findsOneWidget);
    });

    testWidgets('Claremont is one MATCH line a game', (t) async {
      await _pump(t, _card('nassau_nine_claremont_hole7'));
      expect(find.text('MATCH'), findsNWidgets(2));
      expect(find.text('TOP'), findsOneWidget);
      expect(find.text('BOTTOM'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('the screen gives it the Nassau card, keypad and tray', () {
      final src =
          File('lib/screens/score_entry_screen.dart').readAsStringSync();
      // The card: fetched for it, and handed over when it is the primary.
      final ensure = src.indexOf('void _ensureNassauCard(');
      expect(src.substring(ensure, src.indexOf('\n  }', ensure)),
          contains('GameIds.nassauNine'));
      final card = src.indexOf('NassauHoleCard? _nassauCard(');
      expect(src.substring(card, src.indexOf('\n  }', card)),
          contains('primary != GameIds.nassauNine'));
      // The keypad.
      final pad = src.indexOf('bool _keypadRound(');
      expect(src.substring(pad, src.indexOf('\n  }', pad)),
          contains('primary == GameIds.nassauNine'));
    });

    test('the tray takes the game and the press line from the card', () {
      final src = File('lib/widgets/nassau_entry.dart').readAsStringSync();
      expect(src, contains(r"'Hole ${card.hole} · ${card.title}'"));
      expect(src, contains('line.key == card.pressLine'));
      expect(src.contains("line.key == 'overall'"), isFalse);
    });
  });
}
