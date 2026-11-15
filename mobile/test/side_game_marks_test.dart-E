import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/side_game_marks.dart';

/// `design_handoff_stroke_play_side_games` — the two marks a field-wide side
/// game puts on score entry, and the rules that decide whether they appear.
///
/// The ball block is drawn against REAL engine output
/// (`stroke_play_hole4_side_games.json`, written by
/// `REGEN_STROKE_PLAY_FIXTURES=1`), because a hand-written one would be a
/// test of what somebody thought the server sends.

StrokePlayHoleCard _sideGamesCard() => StrokePlayHoleCard.fromJson(
      (jsonDecode(File('test/fixtures/stroke_play_hole4_side_games.json')
              .readAsStringSync()) as Map)
          .cast<String, dynamic>(),
    );

Future<void> _pump(WidgetTester t, Widget w) async {
  await t.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
      home: Scaffold(backgroundColor: Halved.card, body: Center(child: w))));
  await t.pumpAndSettle();
}

String _allText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? '')
    .join('\n');

void main() {
  group('what the server sends', () {
    test('the fixture carries both blocks, and the rotation picked Sam',
        () {
      final card = _sideGamesCard();
      // Hole 4 is the group's FOURTH, so the rotation is on the last name in
      // the order — not index 0, which any wrong subscript would also give.
      //
      // Named rather than asserted as a pk: the fixture's ids move whenever a
      // test class is inserted above the regen, which is how the Sixes anchor
      // test came to pass against its own bug.
      expect(card.player(card.ball!.carrierId!)!.name, 'Sam Reid');
      expect(card.ball!.carrierShort, 'SR');
      expect(card.ball!.gameName, 'Pink Ball');
      expect(card.ball!.liveHere, isTrue);
      expect(card.rumble!.count, 2);
      expect(card.rumble!.of, 4);
      expect(card.rumble!.allCount, isFalse);
    });

    test('neither block is invented when the round does not play them', () {
      final card = StrokePlayHoleCard.fromJson(
          const {'hole': 4, 'players': [], 'standing': []});
      expect(card.ball, isNull);
      expect(card.rumble, isNull);
    });

    test('an older server with no live_here falls back to alive', () {
      // `live_here` arrived with the switch. Before it, `alive` was the gate,
      // and that is what it meant — so a card from a server that predates it
      // still draws a badge rather than none.
      final alive = BallOnHole.fromJson(
          const {'game_name': 'Devil Ball', 'alive': true});
      expect(alive.liveHere, isTrue);
      final gone = BallOnHole.fromJson(
          const {'game_name': 'Devil Ball', 'alive': false});
      expect(gone.liveHere, isFalse);
    });

    test('withBall replaces the ball and nothing else', () {
      final card = _sideGamesCard();
      final lost = card.withBall(BallOnHole.fromJson({
        'game_name': 'Pink Ball',
        'alive': false,
        'live_here': true,
        'lost_on_hole': 4,
        'lost_here': true,
        'carrier_id': card.ball!.carrierId,
        'carrier_short': 'SR',
      }));
      expect(lost.ball!.lostHere, isTrue);
      // Losing the ball ranks nobody differently, which is why the switch
      // patches one block instead of refetching the hole.
      expect(lost.standing.length, card.standing.length);
      expect(lost.rumble!.count, card.rumble!.count);
      expect(lost.capNotes, card.capNotes);
      expect(lost.hole, card.hole);
      expect(lost.field, card.field);
    });
  });

  group('the ball badge', () {
    testWidgets('reads the organiser\'s own name for the game', (t) async {
      await _pump(t, const BallBadge(gameName: 'Devil Ball'));
      expect(_allText(t), contains('Devil Ball'));
    });

    testWidgets('is deep pine — a role, not a result', (t) async {
      // Green is this app's voice for something you WON. Carrying the ball is
      // whose score the group is relying on, which is a different fact, so it
      // wears the same neutral-authority treatment Hot Seat's anchor does.
      await _pump(t, const BallBadge(gameName: 'Pink Ball'));
      final box = t
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.borderRadius != null);
      expect(box.color, Halved.deepPine);
      expect(box.color, isNot(Halved.brightMint));
    });

    testWidgets('draws a ball, not a bullet', (t) async {
      // Three circles: white, the pill's ground, white again. The ring is
      // what makes it read as a golf ball — on deep pine a plain white dot is
      // a list bullet.
      await _pump(t, const BallBadge(gameName: 'Pink Ball'));
      final circles = t
          .widgetList<Widget>(find.byType(Container))
          .map((w) => (w as Container).decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.shape == BoxShape.circle)
          .toList();
      expect(circles.length, 3,
          reason: 'white outer, the ground ring, then a white core');
      expect(circles.first.color, Colors.white);
      expect(circles[1].color, Halved.deepPine);
      expect(circles[2].color, Colors.white);
    });
  });

  group('the rumble strip', () {
    testWidgets('names the game, the count and the group', (t) async {
      await _pump(t, const RumbleCountStrip(count: 2));
      final text = _allText(t);
      expect(text, contains('YOUR GROUP'));
      expect(text, contains('IRISH RUMBLE'));
      expect(text, contains('2'));
      expect(text, contains('COUNT'));
      expect(text, isNot(contains('ALL COUNT')));
    });

    testWidgets('says ALL COUNT when no ball is idle', (t) async {
      // The words answer whether anybody can take a risk, which is a
      // different question from the number — so they change rather than
      // repeating it.
      await _pump(t, const RumbleCountStrip(count: 4, allCount: true));
      expect(_allText(t), contains('ALL COUNT'));
    });

    testWidgets('the count sits in the design\'s own 26x18 box', (t) async {
      // The number is the one thing on the strip read at a glance, and the
      // box is what separates it from the words either side of it.
      await _pump(t, const RumbleCountStrip(count: 4, allCount: true));
      expect(t.takeException(), isNull, reason: 'it has to fit a phone');
      final box = _countBox(t);
      expect(box.width, 26);
      expect(box.height, 18);
    });
  });
}

/// The strip's deep pine count box.
Size _countBox(WidgetTester t) {
  final c = t
      .widgetList<Container>(find.byType(Container))
      .firstWhere((w) =>
          (w.decoration as BoxDecoration?)?.color == Halved.deepPine);
  return Size(c.constraints!.maxWidth, c.constraints!.maxHeight);
}
