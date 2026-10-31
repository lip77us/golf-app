import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/forty_balls_keypad.dart';
import 'package:golf_mobile/widgets/sixes_entry.dart';
import 'package:golf_mobile/widgets/stroke_dots.dart';

/// The Sixes score-entry surfaces (`~/Downloads/handoff-sixes-score-entry`).
///
/// Drawn against REAL engine output: the fixtures are written by
/// `REGEN_SIXES_FIXTURES=1 manage.py test scoring.tests.test_sixes`, so these
/// test what the server sends rather than what somebody thought it sends.

SixesHoleCard _card(String name) => SixesHoleCard.fromJson(
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


/// The scorecard under score entry is the BOARD's.
///
/// It drew on both — the same widget and the same payload — which is two
/// drawings of one thing, and under the tray it is the one nobody can read
/// (Paul, 31 Oct 2026). Rabbit's grid and Survivor's rail came off their
/// screens for the same reason.
void _scorecardIsTheBoards() {
  test('score entry draws no Sixes scorecard', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();
    final at = src.indexOf("if (games.contains('sixes'))");
    expect(at, -1,
        reason: 'the Sixes block in the status section is back: '
            '${at > 0 ? src.substring(at, at + 120) : ''}');
  });
}

void main() {
  _scorecardIsTheBoards();
  group('the hole header', () {
    testWidgets('states the standing in the leader\'s colour', (t) async {
      final card = _card('sixes_hole10_live');
      await _pump(t, SixesHoleHeader(card: card));
      final text = _allText(t);
      // Standing BEFORE the hole: the packet's 2 UP on the 10th.
      expect(text, contains('2 UP'));
      expect(text, contains('3 to play'));
      expect(text, contains(card.match.team1.short));
      expect(text, contains('SI ${card.strokeIndex}'));
      expect(text, contains('back nine'));
    });

    testWidgets('a match with no sides asks rather than reporting',
        (t) async {
      await _pump(t, SixesHoleHeader(card: _card('sixes_hole7_noteams')));
      final text = _allText(t);
      expect(text, contains('Teams?'));
      expect(text, contains('match 2'));
      // Never "AS", which would claim a standing in a match nobody is
      // playing yet.
      expect(text, isNot(contains('AS')));
      expect(text, isNot(contains('to play')));
    });
  });

  group('the golfers', () {
    testWidgets('are grouped by side, and every row carries its colour',
        (t) async {
      final card = _card('sixes_hole10_live');
      await _pump(t, SixesPlayersCard(card: card, netStyle: true));
      final text = _allText(t);
      expect(text, contains(card.match.team1.short.toUpperCase()));
      expect(text, contains(card.match.team2.short.toUpperCase()));

      // A 4pt bar per row in that side's colour — four rows, two colours.
      final bars = t
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.constraints?.maxWidth == 4)
          .toList();
      expect(bars.length, 4);
    });

    testWidgets('are UNGROUPED while the sides are unset', (t) async {
      await _pump(t, SixesPlayersCard(
          card: _card('sixes_hole7_noteams'), netStyle: true));
      expect(_allText(t), contains('MATCH 2 · SIDES NOT SET'));
      // No side bars — there are no sides to mark.
      final bars = t
          .widgetList<Container>(find.byType(Container))
          .where((c) =>
              c.constraints?.maxWidth == 4 &&
              (c.decoration as BoxDecoration?)?.color != Colors.transparent)
          .toList();
      expect(bars, isEmpty);
    });

    testWidgets('the best ball marks BOTH when a side ties', (t) async {
      // The strokes fixture: Paul makes 4 and Sam's 5 nets to 4, so the side
      // has two counting balls and both chips fill.
      final card = _card('sixes_hole10_strokes');
      expect(card.side(1).where((p) => p.isBest).length, 2,
          reason: 'the fixture is the tie this test is about');
      await _pump(t, SixesPlayersCard(card: card, netStyle: true));
      expect(_allText(t), contains('net 4'));
    });

    testWidgets('a stroke is drawn on the box, one dot per stroke', (t) async {
      final card = _card('sixes_hole10_strokes');
      await _pump(t, SixesPlayersCard(card: card, netStyle: true));
      final caps = t.widgetList<StrokeDotCap>(find.byType(StrokeDotCap));
      // Two golfers stroke on this hole in the fixture; the other two draw a
      // cap of zero, which renders nothing.
      expect(caps.where((c) => c.strokes > 0).length,
          card.players.where((p) => p.strokes > 0).length);
      expect(card.players.where((p) => p.strokes > 0), isNotEmpty);
    });
  });

  group('the tray', () {
    testWidgets('the last hole offers Complete Round, not a dead Done',
        (t) async {
      var finished = false;
      await _pump(t, SixesHoleTray(
          card: _card('sixes_hole10_closed'),
          nextHole: null,
          onEdit: () {},
          onNext: () => finished = true));
      expect(find.text('Complete Round'), findsOneWidget);
      await t.tap(find.text('Complete Round'));
      expect(finished, isTrue,
          reason: 'the tray covers the pager, so this is the only way out');
    });

    testWidgets('names the side that WON THE HOLE, not the standing',
        (t) async {
      // The strokes fixture is the packet's own phone 3: Lee's net birdie
      // takes the hole. Under gross the same scoreline HALVES, which is the
      // test below.
      final card = _card('sixes_hole10_strokes');
      await _pump(t, SixesHoleTray(
          card: card, nextHole: 11, onEdit: () {}));
      final text = _allText(t);
      // "Won hole 10" is worded so it cannot be read as the match score,
      // which is the line directly underneath.
      expect(text, contains('Won hole 10'));
      expect(text, contains('net ${card.result!.t1Net} v ${card.result!.t2Net}'));
      expect(text, contains('2 to play'));
      expect(text, contains('Hole 11 ›'));
    });

    testWidgets('a closed match says so, and names the next pairing',
        (t) async {
      final card = _card('sixes_hole10_closed');
      await _pump(t, SixesHoleTray(
          card: card, nextHole: 11, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('win 3&2'));
      expect(text, contains('match 2 over'));
      expect(text, contains('\$5 each'));
      expect(text, contains('PARTNERS CHANGE'));
      expect(text, contains('Match 3 from 11'));
      // The forward button names the MATCH as well as the hole — the thing
      // that changes at 11 is who you are playing with, which the screen's
      // generic pager has no way to know. That is what the tray's own pager
      // buys, and why it covers the one underneath.
      expect(text, contains('Match 3 · hole 11 ›'));
    });

    testWidgets('it drives the hole, and still can while the result is out',
        (t) async {
      // The screen's pager is hidden under this tray, so these are the only
      // arrows on screen — and they have to work even when the result has
      // not landed, or a bad signal strands the group on a hole.
      var back = 0, fwd = 0;
      await _pump(t, SixesHoleTray(
          card: _card('sixes_hole10_closed'),
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

    testWidgets('a live match offers no next pairing', (t) async {
      await _pump(t, SixesHoleTray(
          card: _card('sixes_hole10_live'), nextHole: 11, onEdit: () {}));
      expect(_allText(t), isNot(contains('PARTNERS CHANGE')));
    });

    testWidgets('a halved hole is neutral, and says halved', (t) async {
      // Gross: Paul and Lee both make 4, so the sides tie on best ball.
      final card = _card('sixes_hole10_live');
      expect(card.result!.halved, isTrue, reason: 'the fixture is the subject');
      await _pump(t, SixesHoleTray(
          card: card, nextHole: 11, onEdit: () {}));
      final text = _allText(t);
      expect(text, contains('Hole 10 halved'));
      expect(text, isNot(contains('Won hole')));
      // A halve leaves the standing where it was.
      expect(text, contains('2 UP · 2 to play'));
    });

    testWidgets('a hole still syncing shows no result at all', (t) async {
      // A stale result after an edit is worse than none — Annandale's tray
      // learnt this on a phone.
      await _pump(t, SixesHoleTray(
          card: _card('sixes_hole10_closed'),
          nextHole: 11,
          onEdit: () {},
          gettingResult: true));
      final text = _allText(t);
      expect(text, contains('Getting result…'));
      expect(text, isNot(contains('win 3&2')));
    });
  });

  group('teams not set', () {
    testWidgets('the band names the match before, and what it is asking for',
        (t) async {
      final card = _card('sixes_hole7_noteams');
      await _pump(t, SixesTeamsBand(
          card: card, onPick: () {}, onSpin: () {}, backHole: 6));
      final text = _allText(t);
      expect(text, contains('Match 1 · '));
      expect(text, contains(card.previousMatch!.result!));
      expect(text, contains('holes 1–6'));
      expect(text, contains('Set teams for Match 2 before entering scores.'));
      // Both ways in, and the way back to fix a score first.
      expect(text, contains('Pick the teams'));
      expect(text, contains('Spin for partners'));
      expect(text, contains('back to hole 6'));
    });

    testWidgets('both buttons answer', (t) async {
      var picked = 0, spun = 0;
      await _pump(t, SixesTeamsBand(
          card: _card('sixes_hole7_noteams'),
          onPick: () => picked++,
          onSpin: () => spun++));
      await t.tap(find.text('Pick the teams'));
      await t.tap(find.text('Spin for partners'));
      await t.pumpAndSettle();
      expect(picked, 1);
      expect(spun, 1);
    });
  });

  group('net style entry', () {
    test('a stroke moves the baseline, it does not move the score', () {
      // A golfer with one stroke who makes 5 on a par 4 is drawn as a par.
      expect(shapeForScore(5, 4, strokes: 1), ScoreShape.par);
      // ...and as a bogey with the setting off, which is the same 5.
      expect(shapeForScore(5, 4), ScoreShape.bogey);
      // Two strokes and a 6 is still a par; a 4 off one stroke is a birdie.
      expect(shapeForScore(6, 4, strokes: 2), ScoreShape.par);
      expect(shapeForScore(4, 4, strokes: 1), ScoreShape.birdie);
    });

    testWidgets('the keypad recodes its keys for the golfer on screen',
        (t) async {
      Widget pad(bool netStyle) => FortyBallsKeypad(
            playerName: 'Lee Moss',
            par: 4,
            strokes: 1,
            netStyle: netStyle,
            onScore: (_) {},
            onClear: () {},
          );
      await _pump(t, Align(alignment: Alignment.bottomCenter, child: pad(true)));
      ScoreShape shapeOfKey(int n) => t
          .widgetList<ScoreNotation>(find.byType(ScoreNotation))
          .firstWhere((w) => w.score == n)
          .let((w) => shapeForScore(w.score, w.par, strokes: w.strokes));
      expect(shapeOfKey(5), ScoreShape.par);

      await _pump(t, Align(alignment: Alignment.bottomCenter, child: pad(false)));
      expect(shapeOfKey(5), ScoreShape.bogey);
    });
  });

  group('it stays in the shared screen', () {
    // Sixes plays through `score_entry_screen`, which is where the sync
    // queue, the combo-tee chip, Spots capture, withdrawal and the landscape
    // card live. A dedicated screen is how a game loses all five — this repo
    // has that lesson three times over.
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('the shared screen draws the band and the tray', () {
      expect(src, contains('SixesTeamsBand('));
      expect(src, contains('SixesHoleTray('));
    });

    test('the keypad POSTS a tray game\'s hole on its last score', () {
      // Reported from a phone, 30 Oct 2026: "getting results is taking many
      // seconds". The gate read `af != null`, so a Sixes hole entered on the
      // keypad was never posted — the tray waited for a result from a save
      // that had not happened. Annandale hit exactly this when IT joined the
      // keypad; the gate has to name every tray game, not one of them.
      final at = src.indexOf('if (n > 0 && ');
      expect(at, greaterThan(0));
      final gate = src.substring(at, at + 120);
      expect(gate, contains('af != null'));
      expect(gate, contains('six != null'));
      // 40 Balls still posts with its count, not with the last score.
      expect(gate, contains('!_fortyBallsRound(rp)'));
    });

    test('Edit scores is a session, not one score', () {
      // Plural, and it used to let you change exactly one: the flag cleared
      // the moment a key landed and the tray came straight back (Paul, 30
      // Oct 2026). Tapping a golfer from the inline picker stays a one-shot
      // — that is a different control with a different promise.
      final at = src.indexOf('onScore   : (n) {');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('onClear   :', at));
      expect(body.contains('_trayEditing = false'), isFalse,
          reason: 'a score must not end the session');
      expect(body, contains('_editHotPid = null'));   // the one-shot stays
      final kp = src.indexOf('FortyBallsKeypad(');
      expect(src.substring(kp, at), contains('onDone'));
    });

    test('auto-advance does not carry the scorer past the tray', () {
      // Sixes had the same defect Rabbit reported: the hole completes, the
      // screen jumps to the next one, and the tray that reports the hole is
      // never seen. 40 Balls already had this carve-out; it is widened to
      // every game that ends its hole in a tray.
      final at = src.indexOf('_saveAndAdvance(ctx, players, par);');
      expect(at, greaterThan(0));
      expect(src.substring(at - 400, at), contains('!_raisesTray(rp)'));
    });

    test('a hole with no card asks for one, so the keypad comes back', () {
      final at = src.indexOf('void _ensureSixesCard(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('\n  }', at));
      expect(body, contains('loadSixesHole('));
      expect(body, contains('_sixesCardAsked = null'));
      expect(src, contains('_ensureSixesCard(rp);'));
    });

    test('the screen hides its own pager under the tray', () {
      // Two sets of arrows at the bottom is what a phone showed. The design
      // has the tray overlaying that row, and the tray's forward button can
      // name the next MATCH — so the generic one is the half that goes.
      expect(src, contains('if (!sixTray)'));
    });

    test('the Sixes tray waits for the SERVER, not just the local queue', () {
      // Without the hold it draws the card from before this score.
      // Bounded by the CALL — a window of 400 broke the day the tray grew
      // its pager back, which is the fourth time today a character count
      // reported an edit as a regression.
      final at = src.indexOf('SixesHoleTray(');
      expect(at, greaterThan(0));
      expect(src.substring(at, src.indexOf('onEdit:', at)),
          contains('trayResultPending'));
    });

    test('the keypad takes its strokes from the CARD, not the scorecard', () {
      // A strokes-off match spreads its allowance across the three matches,
      // so the strokes on a hole are the game's answer and not a function of
      // the stroke index. The fallback is the ROUND's full-net allocation —
      // which is what the keypad showed on a strokes-off round while the
      // rows beside it were right (30 Oct 2026).
      final at = src.indexOf('int _keypadStrokes(');
      expect(at, greaterThan(0));
      final body = src.substring(at, src.indexOf('handicapStrokes ?? 0', at));
      final sixAt = body.indexOf('_sixesCard(');
      final afAt  = body.indexOf('annandaleFridaySummary');
      expect(sixAt, greaterThan(0), reason: 'Sixes must state its own');
      expect(sixAt, lessThan(afAt),
          reason: 'and before the fallbacks, not after them');
    });

    test('a card cannot survive the sides being set', () {
      // Reported after a spin (30 Oct 2026): the group came back to hole 7
      // and the teams-not-set band was still over it, because that hole's
      // card had been fetched while the sides were unset. Setting them also
      // REPOSITIONS the matches, so every held card can be describing a
      // match that no longer exists.
      final prov =
          File('lib/providers/round_provider.dart').readAsStringSync();
      final at = prov.indexOf('postSixesSegmentTeams(');
      expect(at, greaterThan(0));
      expect(prov.substring(at, prov.indexOf('return true;', at)),
          contains('_sixesHoles.clear()'));
    });

    test('and the hole it lands on is fetched before you get there', () {
      final at = src.indexOf('Start the group on the match they have just');
      expect(at, greaterThan(0));
      expect(src.substring(at, src.indexOf('\n  }', at)),
          contains('loadSixesHole('));
    });

    test('there is no dedicated Sixes score screen', () {
      final screens = Directory('lib/screens')
          .listSync()
          .map((e) => e.path.split('/').last)
          .where((n) => n.startsWith('sixes_'))
          .toSet();
      expect(screens, {'sixes_setup_screen.dart', 'sixes_segment_draw_screen.dart'},
          reason: 'a sixes play screen would miss Spots, the combo-tee chip, '
              'the sync queue, withdrawal and the landscape card');
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
