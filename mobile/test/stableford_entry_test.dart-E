import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/forty_balls_keypad.dart';
import 'package:golf_mobile/widgets/stroke_play_entry.dart';

/// Stableford score entry — `~/Downloads/handoff-stableford-score-entry`.
///
/// **Stableford score entry is Stroke Play score entry with points**: one
/// model ([StrokePlayHoleCard]) and one tray ([StrokePlayHoleTray]). These
/// are about what differs. The fixtures are real engine output
/// (`REGEN_STABLEFORD_FIXTURES=1`).

StrokePlayHoleCard _card(String name) => StrokePlayHoleCard.fromJson(
    jsonDecode(File('test/fixtures/stableford_$name.json').readAsStringSync())
        as Map<String, dynamic>);

Future<void> _pump(WidgetTester t, StrokePlayHoleCard card,
    {double width = 390}) async {
  await t.binding.setSurfaceSize(Size(width, 700));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: StrokePlayHoleTray(
            card: card, nextHole: 3,
            onEdit: () {}, onPrev: () {}, onNext: () {}),
      ),
    ),
  ));
}

/// The Pts boxes, top to bottom: (text, fill). Found by the box's own
/// minimum width, because a `5` is also somebody's gross on the same tray.
List<(String, Color)> _totals(WidgetTester t) => [
      for (final c in t.widgetList<Container>(find.byType(Container)))
        if (c.constraints == const BoxConstraints(minWidth: 42) &&
            c.child is Text)
          ((c.child as Text).data!, (c.decoration as BoxDecoration).color!),
    ];

void main() {
  group('the card', () {
    test('it is the Stroke Play model, marked as points', () {
      final c = _card('hole2_tray');
      expect(c.points, isTrue);
      expect(c.label, 'Stableford');
      expect(c.tableLabel, 'standard points');
      expect(c.cap, isFalse);
    });

    test('a Stroke Play payload is not a points card', () {
      final c = StrokePlayHoleCard.fromJson(const {'hole': 1});
      expect(c.points, isFalse);
      expect(c.label, 'Stroke Play');
    });

    test('before a score, a row reads – pts', () {
      final c = _card('hole1_empty');
      expect(c.players.every((p) => p.pointsText == '– pts'), isTrue);
      expect(c.players.first.floorText, contains('pts from'));
    });

    test('the ball block is carried across a patch', () {
      final c = _card('hole2_tray').withBall(null);
      expect(c.points, isTrue);
      expect(c.label, 'Stableford');
    });
  });

  group('the tray', () {
    testWidgets('it names the game and ranks on points', (t) async {
      await _pump(t, _card('hole2_tray'));
      expect(find.text('HOLE 2 · STABLEFORD'), findsOneWidget);
      expect(find.text('NET'), findsOneWidget);
      expect(find.text('PTS'), findsOneWidget);
      expect(find.text('TOT'), findsNothing);
      // The hole: the shape, `net N`, then the points it scored.
      expect(find.text('net 3'), findsOneWidget);
      expect(find.text('pts'), findsNWidgets(4));
    });

    testWidgets('the nets line up down the card', (t) async {
      // `1 pt` is narrower than `3 pts`; the net beside it must not move.
      final j = jsonDecode(File('test/fixtures/stableford_hole2_tray.json')
          .readAsStringSync()) as Map<String, dynamic>;
      // The fixture's points happen to be the same width; force a narrow
      // one, or this agrees with a row that simply hugs its text.
      ((j['standing'] as List)[1] as Map)['points_text'] = '1 pt';
      await _pump(t, StrokePlayHoleCard.fromJson(j));
      final lefts = {
        for (final e in find.textContaining('net ').evaluate())
          t.getTopLeft(find.byWidget(e.widget)).dx,
      };
      expect(find.textContaining('net ').evaluate().length, 4);
      expect(lefts.length, 1, reason: '$lefts');
      // …and the points line up on the FIGURE: the unit is its own cell.
      final units = {
        for (final e in find.textContaining(RegExp(r'^pts?$')).evaluate())
          t.getTopLeft(find.byWidget(e.widget)).dx,
      };
      expect(find.text('pt'), findsOneWidget);
      expect(units.length, 1, reason: '$units');
    });

    testWidgets('the total is coloured against par pace', (t) async {
      await _pump(t, _card('hole2_tray'));
      // Two holes at two a hole is four: 5 is ahead, 4 on it, 1 behind.
      expect(_totals(t), [
        ('5', Halved.brightMint),
        ('5', Halved.brightMint),
        ('4', Colors.white),
        ('1', const Color(0x24FFFFFF)),
      ]);
    });

    testWidgets('past the bottom of the table is a sentence, not a cap',
        (t) async {
      await _pump(t, _card('hole2_tray'));
      expect(
          find.text('Mike’s 9 scores 0 pts, the same as a 7. '
              'The card keeps the 9.'),
          findsOneWidget);
    });

    testWidgets('a Modified table is signed', (t) async {
      await _pump(t, _card('hole2_modified'));
      expect(find.text('GROSS'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('−6'), findsOneWidget);
      expect(find.text('−3'), findsOneWidget);
      // A gross game shows the shape and the points only.
      expect(find.textContaining('net '), findsNothing);
      // Par pace is nothing a hole: +2 is ahead.
      expect(_totals(t).first, ('+2', Halved.brightMint));
    });

    testWidgets('it survives a narrow phone', (t) async {
      await _pump(t, _card('hole2_tray'), width: 320);
      expect(t.takeException(), isNull);
    });

    testWidgets('a Stroke Play card still reads TOT', (t) async {
      final j = jsonDecode(File('test/fixtures/stableford_hole2_tray.json')
          .readAsStringSync()) as Map<String, dynamic>;
      j['points'] = false;
      j['label'] = 'Stroke Play';
      for (final r in (j['standing'] as List)) {
        (r as Map)['to_par'] = 0;
      }
      await _pump(t, StrokePlayHoleCard.fromJson(j));
      expect(find.text('HOLE 2 · STROKE PLAY'), findsOneWidget);
      expect(find.text('TOT'), findsOneWidget);
      expect(find.text('PTS'), findsNothing);
    });
  });

  group('the keypad', () {
    testWidgets('it says where the table bottoms out, not a maximum',
        (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(
        body: FortyBallsKeypad(
          playerName: 'Paul Lipkin', par: 4, strokes: 0,
          floorText: '0 pts from 6',
          onScore: (_) {}, onClear: () {},
        ),
      )));
      expect(find.textContaining('0 pts from 6'), findsOneWidget);
      expect(find.textContaining('max'), findsNothing);
    });
  });

  group('the shared screen keeps doing its job', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    String body(String signature) {
      final at = src.indexOf(signature);
      expect(at, greaterThan(0), reason: signature);
      return src.substring(at, src.indexOf('\n  }\n', at));
    }

    test('Stableford enters on the keypad', () {
      expect(body('bool _keypadRound(RoundProvider rp)'),
          contains('primary == GameIds.stableford'));
    });

    test('its card rides the Stroke Play slot, so the tray and the '
        'auto-post need no second branch', () {
      final b = body('StrokePlayHoleCard? _strokePlayCard(RoundProvider rp)');
      expect(b, contains('if (_stablefordPrimary(rp)) {'));
      expect(b, contains('return rp.stablefordHole(_selectedHole);'));
    });

    test('the card is fetched from its own endpoint', () {
      expect(body('void _ensureStrokePlayCard(RoundProvider rp)'),
          contains('.loadStablefordHole(widget.foursomeId, _selectedHole)'));
    });

    test('the keypad is handed the floor', () {
      expect(src, contains(
          'floorText : spCard?.player(fbMember.player.id)?.floorText,'));
    });

    test('the points grid left the screen', () {
      expect(src, isNot(contains('_StablefordProgressGrid')));
    });

    test('the board draws no strokes table under its scorecard', () {
      final lb =
          File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      final at = lb.indexOf('class _StablefordView');
      final card = lb.indexOf('HoleGridScorecard(', at);
      expect(lb.substring(card, lb.indexOf('),', card)),
          contains('showStrokes: false'));
    });
  });
}
