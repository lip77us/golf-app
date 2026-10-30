import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/rabbit_entry.dart';
import 'package:golf_mobile/widgets/stroke_dots.dart';

/// The Rabbit score-entry surfaces (`~/Downloads/handoff-rabbit-score-entry`).
///
/// Drawn against REAL engine output: the fixtures are written by
/// `REGEN_RABBIT_FIXTURES=1 manage.py test scoring.tests.test_rabbit`.

RabbitHoleCard _card(String name) => RabbitHoleCard.fromJson(
      (jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map)
          .cast<String, dynamic>());

Future<void> _pump(WidgetTester t, Widget w,
    {Size size = const Size(390, 844)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(backgroundColor: Halved.surface, body: w),
  ));
  await t.pumpAndSettle();
}

String _allText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join('\n');

void main() {
  group('the hole header', () {
    testWidgets('names the holder, the lead, and what is riding', (t) async {
      await _pump(t, RabbitHoleHeader(card: _card('rabbit_hole9_lead_up')));
      final text = _allText(t);
      expect(text, contains('P +2'), reason: 'the state BEFORE the hole');
      expect(text, contains('\$5 riding'));
      expect(text, contains('4 to play'));
    });

    testWidgets('a carried rabbit says what is actually riding', (t) async {
      // Rabbit 1 went loose, so its stake carries: $10 on rabbit 2.
      final card = _card('rabbit_hole10_won_early');
      expect(card.rabbit.carriedIn, 5.0, reason: 'the fixture is the subject');
      await _pump(t, RabbitHoleHeader(card: card));
      expect(_allText(t), contains('\$10 riding'));
    });

    testWidgets('a loose rabbit is neutral, and claims no lead', (t) async {
      await _pump(t, RabbitHoleHeader(card: _card('rabbit_hole8_loose')));
      final text = _allText(t);
      expect(text, contains('P +1'),
          reason: 'he still held it going INTO the 8th');
      expect(text, isNot(contains('+0')));
    });
  });

  group('the golfers', () {
    testWidgets('are listed under their rabbit, each in their own colour',
        (t) async {
      final card = _card('rabbit_hole9_lead_up');
      await _pump(t, RabbitPlayersCard(card: card, netStyle: true));
      final text = _allText(t);
      expect(text, contains('RABBIT 2 · HOLES 7–12'));
      expect(text, contains('3 GOLFERS'));

      // A 4pt bar per row, three different colours — identity, not sides.
      final bars = t
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.constraints?.maxWidth == 4)
          .toList();
      expect(bars.length, 3);
      final colours = bars
          .map((c) => (c.decoration as BoxDecoration).color)
          .toSet();
      expect(colours.length, 3);
    });

    testWidgets('the holder is tagged with his lead', (t) async {
      await _pump(t, RabbitPlayersCard(
          card: _card('rabbit_hole9_lead_up'), netStyle: true));
      expect(_allText(t), contains('Rabbit +2'));
    });

    testWidgets('an outright low lights one chip, a tie would light none',
        (t) async {
      final card = _card('rabbit_hole9_lead_up');
      final lit = card.players.where((p) => p.isBest).toList();
      expect(lit.length, 1, reason: 'the fixture has an outright winner');
      await _pump(t, RabbitPlayersCard(card: card, netStyle: true));
      expect(_allText(t), contains('net 4'));
    });

    testWidgets('a hole still missing a score lights nothing', (t) async {
      final card = _card('rabbit_hole9_live');
      expect(card.holeComplete, isFalse);
      expect(card.players.where((p) => p.isBest), isEmpty);
      await _pump(t, RabbitPlayersCard(card: card, netStyle: true));
      expect(_allText(t), contains('net –'));
    });

    testWidgets('a stroke is drawn on the box, one dot per stroke', (t) async {
      final card = _card('rabbit_hole9_lead_up');
      await _pump(t, RabbitPlayersCard(card: card, netStyle: true));
      final caps = t.widgetList<StrokeDotCap>(find.byType(StrokeDotCap));
      expect(caps.where((c) => c.strokes > 0).length,
          card.players.where((p) => p.strokes > 0).length);
    });
  });

  group('the tray', () {
    testWidgets('says what the hole did and what is still at risk', (t) async {
      final card = _card('rabbit_hole9_lead_up');
      await _pump(t, RabbitHoleTray(
          card: card, nextHole: 10, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('P wins hole 9'));
      expect(text, contains('net 4 v 5'));
      expect(text, contains('P holds the rabbit'));
      // The sentence is the SERVER's — every clause of it is a rule.
      expect(text, contains(card.result!.line));
      expect(text, contains('3 losses set it loose'));
      expect(text, contains('Hole 10 ›'));
    });

    testWidgets('a hole nobody won is neutral and moves nothing', (t) async {
      final card = _card('rabbit_hole8_loose');
      await _pump(t, RabbitHoleTray(card: card, nextHole: 9, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('S wins hole 8'));
      expect(text, contains('Loose'));
      expect(text, contains('knocked it loose'));
    });

    testWidgets('a won rabbit names the money and the next one', (t) async {
      final card = _card('rabbit_hole10_won_early');
      await _pump(t, RabbitHoleTray(card: card, nextHole: 11, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('P wins rabbit 2'));
      expect(text, contains('Won on 10'));
      expect(text, contains("can't be caught"));
      // $10 was riding (a carry), so it is $10 from each and +$20.
      expect(text, contains('\$10 from each, +\$20'));
      expect(text, contains('Rabbit 3 from 11 · holes 11–16'));
      expect(text, contains('Rabbit 3 · hole 11 ›'));
    });

    testWidgets('a live rabbit offers no next one', (t) async {
      await _pump(t, RabbitHoleTray(
          card: _card('rabbit_hole9_lead_up'), nextHole: 10, onEdit: () {}));
      expect(_allText(t), isNot(contains('NEXT')));
    });

    testWidgets('a hole still syncing shows no result at all', (t) async {
      await _pump(t, RabbitHoleTray(
          card: _card('rabbit_hole10_won_early'),
          nextHole: 11,
          onEdit: () {},
          gettingResult: true));
      final text = _allText(t);
      expect(text, contains('Getting result…'));
      expect(text, isNot(contains('Won on 10')));
    });

    testWidgets('it drives the hole, and still can while the result is out',
        (t) async {
      var back = 0, fwd = 0;
      await _pump(t, RabbitHoleTray(
          card: _card('rabbit_hole10_won_early'),
          nextHole: 11,
          onEdit: () {},
          gettingResult: true,
          onPrev: () => back++,
          onNext: () => fwd++));
      await t.tap(find.text('‹'));
      await t.tap(find.text('Hole 11 ›'));
      await t.pumpAndSettle();
      expect(back, 1);
      expect(fwd, 1);
    });
  });

  group('the screen keeps what a dedicated screen loses', () {
    final src = File('lib/screens/rabbit_screen.dart').readAsStringSync();

    test('the row still carries the combo-tee chip and the Spots button', () {
      // Rabbit has its OWN play screen, so these do not come for free the way
      // they do on the shared one — and they are exactly what gets dropped
      // when an entry card is swapped out.
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
      // A strokes-off rabbit spreads its allowance across the legs, so the
      // strokes on a hole are the game's answer rather than the round's.
      final at = src.indexOf('FortyBallsKeypad(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('onScore:', at));
      expect(body, contains('card.players'));
      expect(body.contains('handicapStrokes'), isFalse);
    });

    test('the tray covers the pager rather than sitting above it', () {
      final at = src.indexOf('RabbitHoleTray(');
      expect(at, greaterThan(0));
      // It RETURNS the tray as the whole bottom bar.
      expect(src.substring(at - 220, at), contains('return SafeArea('));
    });

    test('and the old card is still there for a hole not yet fetched', () {
      // A group must never be stuck looking at nothing because a fetch is in
      // flight.
      expect(src, contains('if (card != null) ...['));
      expect(src, contains('_HoleScoreCard('));
    });
  });

  group('one dashed border in the app', () {
    test('both entry screens use the shared painter', () {
      for (final f in ['lib/widgets/rabbit_entry.dart',
                       'lib/widgets/sixes_entry.dart']) {
        final src = File(f).readAsStringSync();
        expect(src, contains('DashedRRect('), reason: '$f');
        expect(src.contains('class _DashedBorder'), isFalse,
            reason: '$f carries its own copy of one mark');
      }
    });
  });
}
