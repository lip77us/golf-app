import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/survivor_entry.dart';

/// `~/Downloads/handoff-survivor-score-entry`.
///
/// The fixtures are REAL engine output, written by
/// `REGEN_SURVIVOR_FIXTURES=1 manage.py test scoring.tests.test_survivor`.
/// A screen tested against hand-written JSON is tested against what somebody
/// THOUGHT the server sends.
SurvivorHoleCard _card(String name) => SurvivorHoleCard.fromJson(
      (jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
              as Map)
          .cast<String, dynamic>(),
    );

Future<void> _pump(WidgetTester t, Widget w) async {
  await t.binding.setSurfaceSize(const Size(390, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: w))));
}

String _allText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join(' | ');

void main() {
  group('the hole header', () {
    testWidgets('names the phase and what is at stake', (t) async {
      await _pump(t, SurvivorHoleHeader(card: _card('survivor_hole11_decider')));
      final text = _allText(t);
      expect(text, contains('11'));
      expect(text, contains('The Duel'));
      // The pair is named on a decider — a bare pot says nothing about who
      // is playing for it.
      expect(text, contains('\$15 pot'));
      expect(text, contains('PL v DK'));
    });

    testWidgets('an elimination names no pair', (t) async {
      await _pump(t, SurvivorHoleHeader(card: _card('survivor_hole10_out')));
      final text = _allText(t);
      expect(text, contains('The Island'));
      expect(text.contains(' v '), isFalse);
    });
  });

  group('the players card', () {
    testWidgets('bands the golfers still in and Zombieville', (t) async {
      await _pump(t, SurvivorPlayersCard(
          card: _card('survivor_hole11_decider'), netStyle: true));
      final text = _allText(t);
      expect(text, contains('THE DUEL · PL V DK'));
      expect(text, contains('LOW TAKES IT'));
      expect(text, contains('ZOMBIEVILLE'));
      expect(text, contains('LOW OUTRIGHT COMES BACK'));
      expect(text, contains('Zombie'));
    });

    testWidgets('a fresh Survivor has no Zombieville band', (t) async {
      await _pump(t, SurvivorPlayersCard(
          card: _card('survivor_hole10_out'), netStyle: true));
      final text = _allText(t);
      expect(text, contains('THE ISLAND · ALL THREE IN'));
      expect(text.contains('ZOMBIEVILLE'), isFalse);
    });

    testWidgets('rows follow the standing the hole started under', (t) async {
      // Zombieville last, and it does NOT move when somebody goes out on
      // this hole — the tray says what happened and the rows reorder on the
      // next hole, which is the one they describe.
      final card = _card('survivor_hole11_decider');
      expect(card.players.last.isZombie, isTrue);
      expect(card.players.last.short, 'SR');
    });

    testWidgets('a typed score shows before the hole is posted', (t) async {
      // The card is SERVER state and only moves when a hole is posted, so
      // without this the rows stay empty while the scorer looks at numbers
      // he has just entered.
      final card = _card('survivor_hole11_decider');
      final sam = card.players.last.playerId;
      await _pump(t, SurvivorPlayersCard(
          card: card, netStyle: true, scores: {sam: 6}));
      expect(_allText(t), contains('6'));
    });
  });

  group('the tray', () {
    testWidgets('a won decider names the winner, the money and the next',
        (t) async {
      await _pump(t, SurvivorHoleTray(
          card: _card('survivor_hole11_won'), nextHole: 12, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('All 3 scores in'));
      expect(text, contains('PL takes it'));
      expect(text, contains('net 4 v 5'));
      expect(text, contains('Paul Lipkin wins Survivor 5'));
      expect(text, contains('+\$10'));
      expect(text, contains('Won on 11'));
      expect(text, contains('Survivor 6 from 12 · all three in'));
      expect(text, contains('Survivor 6 · hole 12 ›'));
    });

    testWidgets('an elimination says what brings him back', (t) async {
      await _pump(t, SurvivorHoleTray(
          card: _card('survivor_hole10_out'), nextHole: 11, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('SR out'));
      expect(text, contains('net 6, worst'));
      expect(text, contains('SR goes to Zombieville.'));
      expect(text, contains('brings SR back'));
      // The Survivor runs on, so there is no next card and the button is a
      // plain hole.
      expect(text, contains('Hole 11 ›'));
    });

    testWidgets('a Zombie coming back sends a decider out', (t) async {
      await _pump(t, SurvivorHoleTray(
          card: _card('survivor_hole11_swap'), nextHole: 12, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('SR low outright'));
      expect(text, contains('SR is back in.'));
      expect(text, contains('goes to Zombieville'));
      expect(text, contains('The Duel'));
    });

    testWidgets('the sentences are the SERVER\'s, verbatim', (t) async {
      final card = _card('survivor_hole11_won');
      await _pump(t, SurvivorHoleTray(
          card: card, nextHole: 12, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains(card.result!.lineRest));
      expect(text, contains(card.result!.chip));
    });

    testWidgets('the last hole offers Complete Round, not a dead Done',
        (t) async {
      var finished = false;
      await _pump(t, SurvivorHoleTray(
          card: _card('survivor_hole11_won'),
          nextHole: null,
          onEdit: () {},
          onNext: () => finished = true));
      expect(find.text('Complete Round'), findsOneWidget);
      await t.tap(find.text('Complete Round'));
      expect(finished, isTrue,
          reason: 'the tray covers the pager, so this is the only way out');
    });

    testWidgets('Edit scores asks which golfer rather than choosing',
        (t) async {
      await _pump(t, SurvivorHoleTray(
          card: _card('survivor_hole11_won'),
          nextHole: 12,
          onEdit: () {},
          picking: true));
      final text = _allText(t);
      expect(text, contains('PL takes it'), reason: 'the summary stays up');
      expect(text, contains('Tap a score above to change it'));
      expect(text.contains('Edit scores'), isFalse);
    });

    testWidgets('a result still coming says so', (t) async {
      await _pump(t, SurvivorHoleTray(
          card: _card('survivor_hole11_won'),
          nextHole: 12,
          onEdit: () {},
          gettingResult: true));
      expect(_allText(t), contains('Getting result…'));
    });
  });

  _screenGuards();
}

/// What a dedicated play screen LOSES when its entry card is swapped out.
///
/// Survivor has its own screen, so none of this comes for free the way it
/// does on the shared one — and these four are exactly what went missing the
/// last three times a game was moved onto the keypad and tray.
void _screenGuards() {
  group('the screen keeps what a dedicated screen loses', () {
    final src = File('lib/screens/survivor_screen.dart').readAsStringSync();

    test('the row still carries the combo-tee chip and the Spots button', () {
      final at = src.indexOf('Widget? _rowExtras(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('\n  }', at));
      expect(body, contains('ComboTeeChip('));
      expect(body, contains('SpotsButton('));
    });

    test('the keypad POSTS the hole on its last score', () {
      // The tray reports the SERVER's result, so a hole left unsent raises a
      // tray with nothing in it. Annandale hit this, then Sixes.
      final at = src.indexOf('onScore: (n) {');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('onClear:', at));
      expect(body, contains('_allScored(players, now)'));
      expect(body, contains('_saveHole('));
    });

    test('the keypad takes its strokes from the CARD', () {
      // A strokes-off Survivor spreads its allowance off the low man, so the
      // strokes on a hole are the game's answer rather than the round's.
      final at = src.indexOf('FortyBallsKeypad(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('onScore:', at));
      expect(body, contains('card.players'));
      expect(body.contains('handicapStrokes'), isFalse);
    });

    test('the keypad does not take the pager away', () {
      // A hole with nothing entered must not leave the group without a way
      // back (Rabbit, 30 Oct 2026).
      final at = src.indexOf('final m = _keypadMember(');
      final end = src.indexOf('return SafeArea(child: _pager(', at);
      expect(at, greaterThan(0));
      expect(end, greaterThan(at), reason: 'the fallback return moved');
      expect(src.substring(at, end), contains('_pager('));
    });

    test('the by-hole grid and the rail are the BOARD\'s', () {
      // Both drew here as well and both are on the leaderboard already — two
      // drawings of one thing, crushed under the tray where nobody could
      // read them (Paul, 31 Oct 2026). The tray says what the hole did; the
      // board says what the round looks like.
      // The CALL form, not the name — the comment explaining the removal
      // mentions all three, so a bare name test matches its own prose.
      expect(src.contains('_SurvivorGrid('), isFalse);
      expect(src.contains('SurvivorRail.'), isFalse);
      // …and the outcome line with them: the tray reports the same hole in
      // more words.
      expect(src.contains('_OutcomeLine('), isFalse);
    });

    test('a clear is sent as a null gross, not a score of zero', () {
      expect(src, contains('_kCleared ? null'));
      expect(src, contains('clearedSentinel: _kCleared'));
    });
  });
}
