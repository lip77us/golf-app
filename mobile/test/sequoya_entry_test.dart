import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/sequoya_entry.dart';

/// Sequoya 3s score entry — `~/Downloads/handoff-sequoya-score-entry`.
///
/// **The fixtures are REAL engine output**, written by
/// `REGEN_SEQUOYA_FIXTURES=1 manage.py test
/// scoring.tests.test_sequoya_hole_card`. A match can carry three bets, each
/// settling over its own holes, so a tray tested against hand-written JSON
/// would be tested against what somebody thought the server sends. The
/// engine is covered there; these are about what the tray DRAWS, and the
/// source guards about what a dedicated play screen has to keep doing.

SequoyaHoleCard _card(String name, {Map<String, dynamic> over = const {}}) =>
    SequoyaHoleCard.fromJson({
      ...jsonDecode(File('test/fixtures/sequoya_$name.json')
          .readAsStringSync()) as Map<String, dynamic>,
      ...over,
    });

Future<void> _pump(WidgetTester t, SequoyaHoleCard card,
    {void Function(int side)? onPress,
    VoidCallback? onNext,
    bool gettingResult = false,
    Size size = const Size(390, 900)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: SequoyaHoleTray(
        card: card,
        onEdit: () {},
        onNext: onNext ?? () {},
        onPrev: () {},
        onPress: onPress,
        gettingResult: gettingResult,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// The text of every `Text` / `Text.rich` on screen, joined — chips and the
/// standing line are rich text, which `find.text` does not see into.
String _all(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join('\n');

void main() {
  group('the card parses what the server sends', () {
    test('a won first hole and the promise of an auto press', () {
      final c = _card('hole7_auto_press_starts');
      expect(c.hole, 7);
      expect(c.matchIndex, 3);
      expect(c.label, 'Hole 7 · Match 3');
      expect(c.stakeLabel, '\$5 a bet');
      expect(c.sides.map((s) => s.label), ['Paul + Mike', 'Dave + Sam']);
      expect(c.result!.winner, 2);
      expect(c.result!.nets, 'net 3 v 2');
      expect(c.bets.map((b) => b.text), ['Match', 'Auto press starts 8']);
      expect(c.bets.last.isPending, isTrue);
      expect(c.standing, 'Dave + Sam 1 UP');
      expect(c.standingTail, '2 to play');
      expect(c.press, isNull);
      expect(c.nextLabel, 'Hole 8');
      expect(c.money.length, 4);
    });

    test('the keypad reads its strokes off the card', () {
      final c = _card('hole8_halved');
      final strokes = {for (final p in c.players) p.name: p.strokes};
      expect(strokes['Sam Reid'], 1);
      expect(strokes['Mike Alvarez'], 1);
      expect(strokes['Paul Lipkin'], 0);
      expect(c.playerById(c.players.first.playerId), isNotNull);
    });

    test('an empty map is not a card worth drawing', () {
      final c = SequoyaHoleCard.fromJson(const {});
      expect(c.hole, 0);
      expect(c.bets, isEmpty);
      expect(c.result, isNull);
    });
  });

  group('the tray', () {
    testWidgets('names the hole, the stake, both sides and the result',
        (t) async {
      await _pump(t, _card('hole7_auto_press_starts'));
      final all = _all(t);
      expect(find.text('All 4 scores in'), findsOneWidget);
      expect(all, contains('HOLE 7 · MATCH 3'));
      expect(all, contains('\$5 A BET'));
      expect(find.text('Paul + Mike'), findsOneWidget);
      expect(find.text('Dave + Sam'), findsOneWidget);
      expect(all, contains('Won hole 7  net 3 v 2'));
      expect(all, contains('Match 1 UP'));
      expect(all, contains('Auto press starts 8'));
      expect(all, contains('Dave + Sam 1 UP · 2 to play'));
    });

    testWidgets('money is per golfer, with a true minus and a muted zero',
        (t) async {
      await _pump(t, _card('hole7_auto_press_starts'));
      expect(find.text('EACH · NOW'), findsOneWidget);
      expect(find.text('THRU 7'), findsOneWidget);
      expect(find.text('+\$5'), findsNWidgets(2));
      expect(find.text('−\$5'), findsNWidgets(2));
      // Highest first: the two who are up head the list.
      final dave = t.getTopLeft(find.text('Dave Kim')).dy;
      final paul = t.getTopLeft(find.text('Paul Lipkin')).dy;
      expect(dave, lessThan(paul));
    });

    testWidgets('a halved hole is not coloured for either side', (t) async {
      await _pump(t, _card('hole8_halved'));
      expect(_all(t), contains('Halved  net 4 v 4'));
      expect(_all(t), contains('Auto press AS'));
    });

    testWidgets('no Press button unless the card offers one', (t) async {
      // The engine refuses a press over a level auto press, so this hole —
      // which the handoff draws WITH a button — has none.
      var pressed = 0;
      await _pump(t, _card('hole8_halved'), onPress: (_) => pressed++);
      expect(find.text('Press'), findsNothing);
      expect(pressed, 0);
    });

    testWidgets('an offered press is called for the side that is down',
        (t) async {
      int? side;
      await _pump(t, _card('hole2_press_offered'), onPress: (s) => side = s);
      expect(find.text('Press'), findsOneWidget);
      expect(_all(t), contains('Only Paul + Dave can call it, once a match.'));
      await t.tap(find.text('Press'));
      expect(side, 1);
    });

    testWidgets('an offer with nobody to post it draws no button', (t) async {
      await _pump(t, _card('hole2_press_offered'));
      expect(find.text('Press'), findsNothing);
      expect(_all(t).contains('Only Paul + Dave'), isFalse);
    });

    testWidgets('a called press is a promise, and the offer is gone',
        (t) async {
      await _pump(t, _card('hole2_press_called'), onPress: (_) {});
      expect(find.text('Press'), findsNothing);
      expect(_all(t), contains('Press · Paul + Dave starts 3'));
    });

    testWidgets('the last hole of a match shows who you are with next',
        (t) async {
      await _pump(t, _card('hole9_partners_change'));
      final all = _all(t);
      expect(all, contains('NEXT · PARTNERS CHANGE'));
      expect(all, contains('REPEATS MATCH 1'));
      expect(find.text('Match 4 from 10'), findsOneWidget);
      expect(find.text('Paul + Dave'), findsOneWidget);
      expect(find.text('Sam + Mike'), findsOneWidget);
      expect(all, contains('Match 3 halved · no carry'));
      expect(find.text('Match 4 · hole 10 ›'), findsOneWidget);
    });

    testWidgets('a closed match says so and names the live press', (t) async {
      await _pump(t, _card('hole11_closed_early'));
      final all = _all(t);
      expect(all, contains('Match 2&1'));
      expect(all, contains(
          'Paul + Dave win 2&1 · match 4 over · press live on 12'));
      expect(find.text('Hole 12 ›'), findsOneWidget);
    });

    testWidgets('the eighteenth finishes the round', (t) async {
      var finished = 0;
      await _pump(t, _card('hole18_round_over'), onNext: () => finished++);
      final all = _all(t);
      expect(all, contains('ROUND OVER'));
      expect(all.contains('HOLE 18 · MATCH 6'), isFalse);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('MONEY'), findsOneWidget);
      await t.tap(find.text('Finish round ›'));
      expect(finished, 1);
    });

    testWidgets('while the result is on its way it shows nothing stale',
        (t) async {
      await _pump(t, _card('hole7_auto_press_starts'), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('EACH · NOW'), findsNothing);
      // The arrows stay: a card that never lands must not strand a group.
      expect(find.text('Hole 8 ›'), findsOneWidget);
    });

    testWidgets('long names and a small phone do not overflow', (t) async {
      final c = _card('hole9_partners_change', over: {
        'sides': [
          {'side': 1, 'label': 'Bartholomew + Maximilian', 'best': 4},
          {'side': 2, 'label': 'Christopher + Sebastian', 'best': 5},
        ],
        'standing': {
          'text': 'Bartholomew + Maximilian win 2&1',
          'leader': 1,
          'tail': 'match 3 over · press live on 9',
        },
      });
      await _pump(t, c, size: const Size(320, 568));
      expect(t.takeException(), isNull);
      // The buttons are outside the scrolling part, so they are on screen.
      expect(find.text('Match 4 · hole 10 ›').hitTestable(), findsOneWidget);
    });
  });

  group('nothing in the tray is a rule', () {
    final src = File('lib/widgets/sequoya_entry.dart').readAsStringSync();
    // Comments describe the rules; the code must not implement them.
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('it draws the shared header and label, not its own', () {
      expect(code, contains('TrayEditHeader('));
      expect(code, contains('TrayLabel('));
      expect(code.contains("'Edit scores'"), isFalse);
    });

    test('it never works out a margin, a close-out or who may press', () {
      for (final word in ['margin', 'toPlay', 'closedOn', 'calledSide']) {
        expect(code.contains(word), isFalse,
            reason: 'the tray is deriving `$word` — that is the engine\'s');
      }
    });

    test('the sides are the shared blue and orange', () {
      expect(code, contains('sideColour('));
      expect(code.contains('Halved.pine'), isFalse);
      expect(code.contains('teamClay'), isFalse);
    });
  });

  group('the screen keeps what a dedicated screen loses', () {
    final src =
        File('lib/screens/sequoya_threes_screen.dart').readAsStringSync();

    String keypad() {
      final at = src.indexOf('FortyBallsKeypad(');
      expect(at, greaterThan(0), reason: 'no keypad on the Sequoya screen');
      // Bounded by the pager that follows it, not a character count.
      final end = src.indexOf('_pager(', at);
      expect(end, greaterThan(at));
      return src.substring(at, end);
    }

    test('there is one keypad, and it is the shared one', () {
      expect('FortyBallsKeypad('.allMatches(src).length, 1);
    });

    test('the keypad takes its strokes from the card', () {
      expect(keypad(), contains('card.playerById(m.player.id)?.strokes'));
    });

    test('the keypad posts the hole on its last score', () {
      final k = keypad();
      expect(k, contains('_allScored(players, now)'));
      expect(k, contains('_saveHole(ctx, hole, players)'));
    });

    test('Clear passes the sentinel, not a score of zero', () {
      expect(keypad(), contains('_selectScore(m, -1, _selectedHole)'));
    });

    test('the pager survives under the keypad', () {
      final at = src.indexOf('FortyBallsKeypad(');
      final ret = src.indexOf('return SafeArea(', at);
      expect(src.substring(at, ret), contains('_pager('));
    });

    test('the tray is asked for on the cursor alone', () {
      final at = src.indexOf('if (allDone &&');
      expect(at, greaterThan(0), reason: 'the tray gate moved');
      final line = src.substring(at, src.indexOf('\n', at));
      expect(line, contains('_editingPlayerId == null'));
      expect(line.contains('_trayEditing'), isFalse);
    });

    test('the press button posts what the CARD offers', () {
      // The tray hands back the side the server named; the screen must not
      // work one out for it.
      final at = src.indexOf('SequoyaHoleTray(');
      final end = src.indexOf('onPrev:', at);
      final body = src.substring(at, end);
      expect(body, contains('(side) => _callPress(match, side)'));
    });

    test('a pressed button goes with the response, not a second request', () {
      expect(src, contains('if (r.hole != null) rp.setSequoyaHole(r.hole!);'));
    });

    test('a missing card is asked for', () {
      expect(src, contains('_ensureCard(rp);'));
      expect(src, contains('loadSequoyaHole(widget.foursomeId, _selectedHole)'));
    });

    test('the rows keep the combo-tee chip and the Spots button', () {
      expect(src, contains('ComboTeeChip(tee: comboTee)'));
      expect(src, contains('SpotsButton('));
      expect(src, contains('greenieCards('));
    });

    test('scores still merge the sync queue', () {
      expect(src, contains('queued: context.read<RoundProvider>()'
          '.localPendingByHole'));
    });

    test('one press control at a time', () {
      // Once the tray is up its button is the offer; the card in the body
      // stands down unless a press is already called.
      final at = src.indexOf('_PressOffer(');
      final gate = src.substring(src.lastIndexOf('if (match != null', at), at);
      expect(gate, contains('holeScored'));
      expect(gate, contains("b.kind == 'manual_press'"));
    });
  });
}
