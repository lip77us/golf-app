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

    testWidgets('a typed score shows BEFORE the hole is posted', (t) async {
      // The card is server state and only moves when a hole is posted, so
      // with three of four in, the rows stayed empty while the scorer was
      // looking at the numbers he had just entered (30 Oct 2026).
      final card = _card('rabbit_hole9_live');
      final out = card.players.firstWhere((p) => p.gross == null);
      await _pump(t, RabbitPlayersCard(
          card: card, netStyle: true, scores: {out.playerId: 7}));
      final text = _allText(t);
      expect(text, contains('7'));
      // ...and his net follows it, rather than sitting stale beside it.
      expect(text, contains('net ${7 - out.strokes}'));
    });

    testWidgets('a cleared score empties the box again', (t) async {
      final card = _card('rabbit_hole9_lead_up');
      final scored = card.players.firstWhere((p) => p.gross != null);
      await _pump(t, RabbitPlayersCard(
          card: card, netStyle: true, scores: {scored.playerId: 0}));
      expect(_allText(t), contains('net –'));
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
      expect(text, contains('P extends'));
      expect(text, contains('net 4 v 5'));
      expect(text, contains('P holds the rabbit'));
      // The sentence is the SERVER's — every clause of it is a rule.
      expect(text, contains(card.result!.line));
      expect(text, contains('3 losses set it loose'));
      expect(text, contains('Hole 10 ›'));
    });

    testWidgets('the chip says so in full, not ellipsised', (t) async {
      // `Hole 4` was `Expanded` beside a `Flexible` chip and both default to
      // flex 1, so they split the row and the chip read `No outright ...`
      // over two words of white space (Paul, 30 Oct 2026). The measurement is
      // the claim: the label is laid out at its full intrinsic width.
      final card = _card('rabbit_hole8_halved');
      await _pump(t, RabbitHoleTray(card: card, nextHole: 9, onEdit: () {}));
      expect(_allText(t), contains('P keeps it'));
      expect(_allText(t), contains('net 4 v 4'));

      // Measured as geometry, not as fit: the test font is one square per
      // glyph, so nothing here can say whether a string fits a real phone.
      // What it CAN pin is that the chip is handed the row's whole slack
      // rather than half of it, which is what was wrong.
      final row = t.getSize(find.ancestor(
          of: find.text('Hole 8'), matching: find.byType(Row)).first);
      final label = t.getSize(find.text('Hole 8'));
      final chip = t.getSize(find
          .ancestor(
              of: find.text('P keeps it'),
              matching: find.byType(Container))
          .first);
      expect(chip.width, greaterThan(row.width / 2),
          reason: 'the chip was splitting the row with a six-character label');
      expect(chip.width, closeTo(row.width - label.width - 10, 1));
    });

    testWidgets('a freed rabbit leads with the rabbit, not the hole', (t) async {
      // Paul, 30 Oct 2026, twice about one hole: `No outright winner` is not
      // the relevant fact, and neither is `Paul wins hole 11` when he broke
      // the tie — what matters is that the rabbit went loose. Here Sam DID
      // win the hole outright and the chip still reports the rabbit.
      final card = _card('rabbit_hole8_loose');
      await _pump(t, RabbitHoleTray(card: card, nextHole: 9, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('P loses it'));
      expect(text.contains('wins hole'), isFalse);
      expect(text, contains('net 3 v 5'));
      expect(text, contains('knocked it loose'));
    });

    testWidgets('a loose rabbit wears nobody\'s colour', (t) async {
      // Neutral is the right fill rather than a fallback: it belongs to
      // nobody. A held rabbit wears the holder's.
      final loose = _card('rabbit_hole8_loose');
      await _pump(t, RabbitHoleTray(card: loose, nextHole: 9, onEdit: () {}));
      final neutral = t
          .widget<Container>(find
              .ancestor(
                  of: find.text('P loses it'),
                  matching: find.byType(Container))
              .first)
          .decoration as BoxDecoration;

      final held = _card('rabbit_hole9_lead_up');
      await _pump(t, RabbitHoleTray(card: held, nextHole: 10, onEdit: () {}));
      final owned = t
          .widget<Container>(find
              .ancestor(
                  of: find.text('P extends'),
                  matching: find.byType(Container))
              .first)
          .decoration as BoxDecoration;

      expect(neutral.color, isNot(owned.color));
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

    testWidgets('a rabbit that ran its window did not end early', (t) async {
      // Reported from a phone, 30 Oct 2026: rabbit 1 ran holes 1–6, was taken
      // on the 6th, and the card claimed it had ended early. It had not —
      // rabbit 2 starts on 7 because that is where it always started.
      final card = _card('rabbit_hole6_held_to_end');
      await _pump(t, RabbitHoleTray(card: card, nextHole: 7, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('Held to 6'));
      expect(text, isNot(contains('ended early')));
      expect(text, contains('ran all 6 holes'));
      expect(text, contains('Rabbit 2 from 7 · holes 7–12'));
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

    test('Edit scores is a session, not one score', () {
      // It is plural, and it used to let you change exactly one: the flag
      // cleared the moment a key landed and the tray came straight back
      // (Paul, 30 Oct 2026). The keypad stays until Done.
      final at = src.indexOf('onScore: (n) {');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('onClear:', at));
      expect(body.contains('_trayEditing = false'), isFalse,
          reason: 'a score must not end the session');
      // And there is a way out of it.
      final kp = src.indexOf('FortyBallsKeypad(');
      expect(src.substring(kp, at), contains('onDone:'));
    });

    test('the keypad does not take the pager away', () {
      // A hole with nothing entered returned the keypad and NO pager at all,
      // so a group that opened on hole 7 had no way back to 6 (Paul, 30 Oct
      // 2026). The tray is the one thing that replaces that row — it carries
      // its own arrows. Anchored on the fallback return, which is the next
      // thing in the method.
      final at = src.indexOf('final m = _keypadMember(');
      final end = src.indexOf('return SafeArea(child: _pager(', at);
      expect(at, greaterThan(0));
      expect(end, greaterThan(at), reason: 'the fallback return moved');
      expect(src.substring(at, end), contains('_pager('),
          reason: 'the keypad branch must draw the pager beneath it');
    });

    test('the round is completed by a button that is not called Done', () {
      // The keypad grows its own `Done` during an edit session, and two of
      // them stacked on the last hole — one ending the round.
      final at = src.indexOf('Widget _pager(');
      expect(at, greaterThan(0));
      final body = src.substring(at);
      expect(body, contains('_finishRound('));
      expect(body.contains("label: const Text('Done')"), isFalse);
    });

    test('auto-advance does not carry the scorer past the tray', () {
      // The tray IS the end of the hole; its forward button is the advance.
      final at = src.indexOf('autoAdvanceHole');
      expect(at, greaterThan(0));
      expect(src.substring(at - 700, at), contains('_card(context.read'));
    });

    test('and the rows draw what has been TYPED, not just what is saved', () {
      final at = src.indexOf('RabbitPlayersCard(');
      expect(at, greaterThan(0));
      expect(src.substring(at, src.indexOf('netStyle:', at)),
          contains('scores: scores'));
    });

    test('the by-hole grid is the board\'s, not the play screen\'s', () {
      // It was drawn in both. Under the keypad it was a half-visible table
      // nobody could read, and `RabbitBoard` already draws it across every
      // rabbit with one shared column width.
      expect(src.contains('_RabbitGrid('), isFalse);
      final board = File('lib/widgets/rabbit_board.dart').readAsStringSync();
      expect(board, contains('class RabbitBoard'));
    });

    test('a hole with no card asks for one, so the keypad comes back', () {
      // The drop races the fetch the forward button started: the next hole's
      // card can arrive first and then be thrown away by the response to an
      // earlier save, leaving a screen with no keypad at all.
      final at = src.indexOf('void _ensureCard(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('\n  }', at));
      expect(body, contains('_loadCard()'));
      // Asked once per hole, not once per frame — and the latch clears the
      // moment a card arrives, which is what lets it fire again if that card
      // is dropped.
      expect(body, contains('_cardAsked = null'));
      expect(src, contains('_ensureCard(rp);'));
    });

    test('a saved hole drops the cards held for every OTHER hole', () {
      // The banner said one golfer had it and the header chip beside it said
      // Loose, because that hole's card had been fetched before the hole
      // before it was scored.
      final prov =
          File('lib/providers/round_provider.dart').readAsStringSync();
      final at = prov.indexOf("response['rabbit_hole']");
      expect(at, greaterThan(0));
      expect(prov.substring(at, at + 600), contains('_rabbitHoles.clear()'));
    });

    test('nobody is told they have 0 strokes', () {
      final pad =
          File('lib/widgets/forty_balls_keypad.dart').readAsStringSync();
      final at = pad.indexOf('String _strokeWord(');
      expect(at, greaterThan(0));
      expect(pad.substring(at, at + 220), contains("'no stroke'"));
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

  group('the option is named for the rule', () {
    test('the setup switch and the board chip both say Rolls on', () {
      // It was "Extra rabbit" in both places — named after what falls out of
      // the rule rather than the rule, so a group that wanted rolls-on had to
      // find a switch named after the leftovers.
      final setup =
          File('lib/screens/rabbit_setup_screen.dart').readAsStringSync();
      expect(setup, contains("title: 'Rolls on'"));
      expect(setup.contains("title: 'Extra rabbit'"), isFalse);
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
