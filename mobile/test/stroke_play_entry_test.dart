import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/stroke_play_entry.dart';

/// The Stroke Play score-entry tray (`~/Downloads/handoff-stroke-play`).
///
/// Drawn against REAL engine output: the fixtures are written by
/// `REGEN_STROKE_PLAY_FIXTURES=1 manage.py test
/// scoring.tests.test_stroke_play_hole_card`.

StrokePlayHoleCard _card(String name) => StrokePlayHoleCard.fromJson(
      (jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map)
          .cast<String, dynamic>());

Future<void> _pump(WidgetTester t, Widget w,
    {Size size = const Size(390, 844)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
        backgroundColor: Halved.surface,
        body: Align(alignment: Alignment.bottomCenter, child: w)),
  ));
  await t.pumpAndSettle();
}

String _allText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join('\n');

StrokePlayHoleTray _tray(StrokePlayHoleCard card,
        {int? nextHole = 4,
        bool gettingResult = false,
        bool notSynced = false,
        bool picking = false,
        void Function(bool)? onBallLost,
        bool? ballLostPending}) =>
    StrokePlayHoleTray(
      card: card,
      nextHole: nextHole,
      onEdit: () {},
      onPrev: () {},
      onNext: () {},
      gettingResult: gettingResult,
      notSynced: notSynced,
      picking: picking,
      onBallLost: onBallLost,
      ballLostPending: ballLostPending,
    );

/// The side-games card, with the ball in whatever state the test needs.
StrokePlayHoleCard _withBall(
        {bool alive = true,
        bool liveHere = true,
        bool lostHere = false,
        int? lostOn}) =>
    _card('stroke_play_hole4_side_games').withBall(BallOnHole.fromJson({
      'game_name': 'Pink Ball',
      'alive': alive,
      'live_here': liveHere,
      'lost_on_hole': lostOn,
      'lost_here': lostHere,
      // Whichever golfer the fixture's rotation landed on — the tray draws
      // the game and the hole, never a pk.
      'carrier_id': _card('stroke_play_hole4_side_games').ball!.carrierId,
      'carrier_short': 'SR',
    }));

void main() {
  group('the lost ball switch', () {
    testWidgets('names the game and the hole, and what turning it on does',
        (t) async {
      await _pump(t, _tray(_withBall(), onBallLost: (_) {}));
      final text = _allText(t);
      expect(text, contains('Pink Ball lost on 4'));
      expect(text, contains('Ends Pink Ball for the group'));
    });

    testWidgets('once on, it says Stroke Play is untouched', (t) async {
      // That is the reassurance a group wants at the moment it loses the
      // ball: the round they are actually being ranked on is intact.
      await _pump(
          t, _tray(_withBall(alive: false, lostHere: true, lostOn: 4),
              onBallLost: (_) {}));
      expect(_allText(t),
          contains('Over for the group. Scores still count for Stroke Play.'));
    });

    testWidgets('there is no switch once the ball is gone', (t) async {
      // From the NEXT hole on: `liveHere` false. The one gate, and it is the
      // server's — the row's badge reads the same field.
      await _pump(
          t, _tray(_withBall(alive: false, liveHere: false, lostOn: 4),
              onBallLost: (_) {}));
      expect(_allText(t), isNot(contains('Pink Ball')));
    });

    testWidgets('and none at all on a round with no ball game', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3'), onBallLost: (_) {}));
      expect(_allText(t), isNot(contains('lost on')));
    });

    testWidgets('a tap reports the OPPOSITE of what is showing', (t) async {
      bool? got;
      await _pump(t, _tray(_withBall(), onBallLost: (v) => got = v));
      await t.tap(find.text('Pink Ball lost on 4'));
      await t.pumpAndSettle();
      expect(got, isTrue);

      got = null;
      await _pump(
          t,
          _tray(_withBall(alive: false, lostHere: true, lostOn: 4),
              onBallLost: (v) => got = v));
      await t.tap(find.text('Pink Ball lost on 4'));
      await t.pumpAndSettle();
      expect(got, isFalse, reason: 'the undo is the point of the route');
    });

    testWidgets('the value in flight wins over the card', (t) async {
      // Otherwise the toggle sits on its old value waiting for the server and
      // reads as broken.
      await _pump(t,
          _tray(_withBall(), onBallLost: (_) {}, ballLostPending: true));
      expect(_allText(t),
          contains('Over for the group. Scores still count for Stroke Play.'));
    });

    testWidgets('it is drawn even while the board is stale', (t) async {
      // The switch is about the HOLE, not about the places. A scorer who has
      // just lost a ball should not have to wait for a sync to say so.
      await _pump(t,
          _tray(_withBall(), onBallLost: (_) {}, notSynced: true));
      expect(_allText(t), contains('Pink Ball lost on 4'));
    });

    testWidgets('no switch when nothing can act on it', (t) async {
      await _pump(t, _tray(_withBall()));
      expect(_allText(t), isNot(contains('lost on')));
    });
  });

  group('the board', () {
    testWidgets('names every golfer, his place and his total', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3')));
      final text = _allText(t);
      expect(text, contains('HOLE 3 · STROKE PLAY'));
      for (final n in ['Paul Lipkin', 'Dave Kim', 'Sam Reid', 'Mike Ruiz']) {
        expect(text, contains(n));
      }
      expect(text, contains('POS'));
      expect(text, contains('TOT'));
    });

    testWidgets('a shared place carries the server’s own T', (t) async {
      final card = _card('stroke_play_hole4_capped');
      expect(card.standing.first.placeText, 'T2',
          reason: 'the fixture is the subject');
      await _pump(t, _tray(card));
      expect(_allText(t), contains('T2'));
    });

    testWidgets('movement reads as places GAINED, with a direction',
        (t) async {
      final card = _card('stroke_play_hole4_capped');
      // Sam gained one and Mike lost one on this hole.
      expect(card.standing.map((r) => r.moved).toList(), [0, 1, 0, -1]);
      await _pump(t, _tray(card));
      final text = _allText(t);
      expect(text, contains('▲1'));
      expect(text, contains('▼1'));
    });

    testWidgets('the rows are the server’s order, best first', (t) async {
      final card = _card('stroke_play_hole3');
      await _pump(t, _tray(card));
      final names = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s.contains(' '))
          .where((s) => card.standing.any((r) => r.name == s))
          .toList();
      expect(names, card.standing.map((r) => r.name).toList(),
          reason: 'a board that re-sorts is a second ranking');
    });
  });

  group('the hole', () {
    testWidgets('shows the gross in its shape and the counted net beside it',
        (t) async {
      await _pump(t, _tray(_card('stroke_play_hole4_capped')));
      expect(find.byType(TrayScoreMark), findsNWidgets(4));
      // Mike's 12 counts 7, so the net beside the mark is the COUNTED one.
      expect(_allText(t), contains('12'));
      expect(_allText(t), contains('7'));
    });

    testWidgets('a gross round draws no net column', (t) async {
      // Mike's 12 counts 7, and `7` appears nowhere else on this card — so
      // it is the net column, and in gross it should be gone.
      const raw = 'test/fixtures/stroke_play_hole4_capped.json';
      final net = _card('stroke_play_hole4_capped');
      expect(net.showNet, isTrue);
      await _pump(t, _tray(net));
      expect(_allText(t), contains('7'));

      // A coherent gross round: no strokes to report, so no cap and no net,
      // and a field of four with nobody outside the card.
      final gross = StrokePlayHoleCard.fromJson({
        ...jsonDecode(File(raw).readAsStringSync()) as Map<String, dynamic>,
        'show_net': false,
        'cap': false,
        'cap_notes': <String>[],
        'field': 4,
        'leader': null,
      });
      await _pump(t, _tray(gross));
      expect(find.byType(TrayScoreMark), findsNWidgets(4),
          reason: 'the marks stay — the gross IS the figure');
      expect(_allText(t), contains('GROSS'));
      expect(_allText(t), isNot(contains('7')));
    });
  });

  group('the cap', () {
    testWidgets('states the server’s sentence, not one of its own', (t) async {
      final card = _card('stroke_play_hole4_capped');
      await _pump(t, _tray(card));
      expect(_allText(t), contains(card.capNotes.single));
    });

    testWidgets('says nothing on a hole nobody blew up', (t) async {
      final card = _card('stroke_play_hole3');
      expect(card.capNotes, isEmpty);
      await _pump(t, _tray(card));
      expect(_allText(t), isNot(contains('net double bogey')));
    });
  });

  group('the leader', () {
    testWidgets('is named when he is off this card', (t) async {
      final card = _card('stroke_play_hole3');
      expect(card.leader?.name, 'Ben Ortiz');
      await _pump(t, _tray(card));
      final text = _allText(t);
      expect(text, contains('Ben Ortiz'));
      expect(text, contains('thru 6'));
      expect(text, contains('FIELD OF 5'));
    });

    testWidgets('is silent when there is none — no empty slot', (t) async {
      final card = StrokePlayHoleCard.fromJson({
        ...jsonDecode(
                File('test/fixtures/stroke_play_hole3.json').readAsStringSync())
            as Map<String, dynamic>,
        'leader': null,
        'field': 4,
      });
      await _pump(t, _tray(card));
      final text = _allText(t);
      expect(text, isNot(contains('Leader')));
      // With no field beyond the card the slot carries the basis instead.
      expect(text, contains('NET'));
    });
  });

  group('the way on', () {
    testWidgets('names the next hole', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3')));
      expect(_allText(t), contains('Hole 4 ›'));
    });

    testWidgets('is Complete Round on the last hole', (t) async {
      // The tray COVERS the screen's pager, so a dead forward button here
      // would leave the round with no way to finish — the hole Rabbit's and
      // Sixes' trays both showed on a phone.
      await _pump(t, _tray(_card('stroke_play_hole3'), nextHole: null));
      expect(_allText(t), contains('Complete Round'));
    });

    testWidgets('a back arrow is always there', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3')));
      expect(find.text('‹'), findsOneWidget);
    });
  });

  group('waiting', () {
    testWidgets('draws no board while the result is on its way', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3'), gettingResult: true));
      final text = _allText(t);
      expect(text, contains('Getting result…'));
      // The places predate the score just entered, so none are shown.
      expect(text, isNot(contains('Ben Ortiz')));
      expect(find.byType(TrayScoreMark), findsNothing);
      // …and the way on still works, so a bad signal cannot strand a group.
      expect(text, contains('Hole 4 ›'));
    });

    testWidgets('says so when the hole is saved but unsent', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3'), notSynced: true));
      expect(_allText(t), contains('once this hole syncs'));
    });
  });

  group('editing', () {
    testWidgets('picking chooses nobody and says to tap a score', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3'), picking: true));
      final text = _allText(t);
      expect(text, contains('Done'));
      expect(text, contains('Tap a score above to change it'));
    });

    testWidgets('otherwise it offers Edit scores', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole3')));
      expect(_allText(t), contains('Edit scores'));
    });
  });

  group('nothing entered yet', () {
    testWidgets('claims no place for a golfer who has not teed off',
        (t) async {
      final card = _card('stroke_play_hole1_empty');
      expect(card.standing.every((r) => r.place == null), isTrue);
      await _pump(t, _tray(card, nextHole: 2));
      expect(find.byType(TrayScoreMark), findsNothing);
      expect(_allText(t), contains('—'));
    });

    testWidgets('the strokes are there before a score is', (t) async {
      // The keypad is coded against par plus them, so the card has to carry
      // them for a hole nobody has played.
      // The 1st is stroke index 7, so all four of 8 / 12 / 15 / 18 get one,
      // and each ceiling is par 4 + 2 + that stroke.
      final card = _card('stroke_play_hole1_empty');
      expect(card.players.map((p) => p.strokes).toList(), [1, 1, 1, 1]);
      expect(card.players.map((p) => p.capMax).toList(), [7, 7, 7, 7]);
    });
  });

  group('the score mark on a dark tray', () {
    testWidgets('a capped hole is outlined, and nothing else is', (t) async {
      await _pump(t, _tray(_card('stroke_play_hole4_capped')));
      final marks = t.widgetList<TrayScoreMark>(find.byType(TrayScoreMark));
      expect(marks.where((m) => m.capped).length, 1);
    });

    testWidgets('a mark with no par is a plain digit', (t) async {
      await _pump(
          t,
          const TrayScoreMark(score: 5, par: null),
          size: const Size(200, 200));
      expect(_allText(t), contains('5'));
    });
  });

  // ── the screen ─────────────────────────────────────────────────────────────
  //
  // Stroke Play plays through `score_entry_screen`, which is where the sync
  // queue, the combo-tee chip, Spots capture, withdrawal and the landscape
  // scorecard live — so it inherits all of it rather than losing it the way
  // a dedicated screen would. What these guard is the wiring that broke on
  // Annandale Friday and then AGAIN on Sixes the day each joined the keypad.
  group('one carrier badge, both screens', () {
    // The ball badge was drawn two different ways for one fact — a
    // secondary-coloured pill on Pink Ball's own play screen, the design's
    // deep-pine one with the ball on score entry. *The games with their own
    // play screen are the ones that get missed*, so this is checked at both.
    for (final f in const [
      'lib/screens/score_entry_screen.dart',
      'lib/screens/pink_ball_screen.dart',
    ]) {
      test('$f draws the shared BallBadge', () {
        final src = File(f).readAsStringSync();
        expect(src, contains('BallBadge('));
        expect(src, contains("widgets/side_game_marks.dart"));
      });
    }

    test('the row draws the Rumble strip', () {
      // Nothing is entered for Irish Rumble. This strip is the whole of what
      // the game needs on score entry, so a screen without it plays the game
      // with no way to know how many balls count.
      final src = File('lib/screens/score_entry_screen.dart')
          .readAsStringSync();
      expect(src, contains('RumbleCountStrip('));
    });
  });

  group('the screen wires it', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('the keypad posts the hole on its last score', () {
      // Annandale's tray rose over a hole that had never been sent, and
      // Sixes repeated it because the gate still read `af != null`. A tray
      // reports the SERVER's result, so the hole has to go.
      final at = src.indexOf('if (n > 0 && !_fortyBallsRound(rp)');
      expect(at, greaterThan(0), reason: 'the post-on-last-score gate moved');
      expect(src.substring(at, src.indexOf('{', at + 40)),
          contains('spCard != null'));
    });

    test('the keypad takes the strokes and the ceiling from the CARD', () {
      // The round's stored strokes are full net; Stroke Play carries its own
      // handicap mode and allowance, so a gross game inside a net round
      // would otherwise show the round's dots. Same bug Sixes had.
      final at = src.indexOf('final sp = _strokePlayCard(rp);');
      expect(at, greaterThan(0), reason: '_keypadStrokes stopped asking');
      expect(src.substring(at, src.indexOf('return', at)), contains('strokes'));
      expect(src, contains('capMax    : spCard?.player('));
    });

    test('the switch is wired, and reads the value in flight', () {
      // A switch the screen draws and never posts looks identical until
      // somebody plays a round. Bounded to the tray's own argument list.
      final at = src.indexOf('StrokePlayHoleTray(');
      expect(at, greaterThan(0));
      final args = src.substring(at, src.indexOf('\n            )', at));
      expect(args, contains('onBallLost:'));
      expect(args, contains('ballLostPending:'));
      expect(src, contains('.setPinkBallLost(widget.foursomeId'));
    });

    test('the pending value is keyed to the hole it belongs to', () {
      // The scorer can move on while the request is in flight, and a bare
      // bool would show the NEXT hole's switch a loss from the one behind it.
      final at = src.indexOf('_ballLostPending?.hole');
      expect(at, greaterThan(0),
          reason: 'the pending value stopped carrying its hole');
      expect(src.substring(at, src.indexOf(';', at)),
          contains('== _selectedHole'));
    });

    test('both side-game blocks reach the hole card', () {
      // The badge and the strip are the whole of what these games add to
      // score entry; the card cannot draw either without being handed them.
      final at = src.indexOf('_HoleScoreCard(');
      expect(at, greaterThan(0));
      final args = src.substring(at, src.indexOf('\n              ),', at));
      expect(args, contains('ball:'));
      expect(args, contains('rumble:'));
    });

    test('the screen hides its own pager under the tray', () {
      // The tray IS the bottom bar while it is up, and it carries its own
      // arrows — two sets at the bottom is what a phone showed on Sixes.
      final at =
          src.indexOf('padding: const EdgeInsets.fromLTRB(12, 4, 12, 8)');
      expect(at, greaterThan(0), reason: 'the pager row moved');
      expect(src.substring(at - 120, at), contains('!spTray'));
    });

    test('the tray finishes the round on the last hole', () {
      // It covers the pager, so a dead forward button there leaves no way to
      // finish. Reported on Rabbit and fixed on Sixes the same day.
      final at = src.indexOf('StrokePlayHoleTray(');
      expect(at, greaterThan(0));
      // Bounded to the `onNext` argument alone — `onPrev` legitimately
      // disables itself on the first hole, and a span covering both would
      // read that as the defect this guards.
      final from = src.indexOf('onNext:', at);
      final body = src.substring(from, src.indexOf('gettingResult:', from));
      expect(body, contains('_completeRound('));
      expect(RegExp(r'==\s*null\s*\?\s*null').hasMatch(body), isFalse);
    });

    test('the tray waits for the SERVER, not just the local queue', () {
      final at = src.indexOf('StrokePlayHoleTray(');
      expect(src.substring(at, src.indexOf('onEdit:', at)),
          contains('trayResultPending'));
    });

    test('a hole with no card asks for one, so the keypad comes back', () {
      // A save drops every other hole's card because they can be stale, and
      // that races the fetch the forward button started — without this the
      // keypad is simply not drawn. Rabbit and Sixes both showed it.
      expect(src, contains('_ensureStrokePlayCard(rp)'));
      expect(src, contains('_strokePlayCardAsked'));
    });

    test('a saved hole drops the cards held for every OTHER hole', () {
      final prov =
          File('lib/providers/round_provider.dart').readAsStringSync();
      final at = prov.indexOf("response['stroke_play_hole']");
      expect(at, greaterThan(0));
      final body = prov.substring(at, prov.indexOf('notifyListeners', at));
      expect(body, contains('_strokePlayHoles.clear()'));
      expect(body, contains('_annandaleResults.answer('),
          reason: 'the card IS the answer — the hold ends here');
    });
  });
}
