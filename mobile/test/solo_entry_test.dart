import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/solo_entry.dart';

/// Solo games' score entry — `~/Downloads/handoff-solo-score-entry`
/// (11 Nov 2026). The engine is covered in
/// `scoring/tests/test_solo_hole_card.py`, which also WRITES the fixtures
/// these draw (`REGEN_SOLO_FIXTURES=1`).

SoloHoleCard _card(String name) => SoloHoleCard.fromJson(jsonDecode(
        File('test/fixtures/solo_$name.json').readAsStringSync())
    as Map<String, dynamic>);

Future<void> _tray(WidgetTester t, SoloHoleCard card,
    {Size size = const Size(390, 1500), VoidCallback? onNext,
    bool gettingResult = false}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MediaQuery(
          data: MediaQueryData(size: Size(size.width, size.height + 400)),
          child: SoloHoleTray(
            card: card,
            onEdit: () {},
            onPrev: () {},
            onNext: onNext ?? () {},
            gettingResult: gettingResult,
          ),
        ),
      ),
    ),
  ));
}

void main() {
  group('the header', () {
    testWidgets('names the strokes and the index range', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SoloHeader(card: _card('stroke12')))));
      expect(find.text('SOLO'), findsOneWidget);
      expect(find.text('12 STROKES · SI 1–12'), findsOneWidget);
    });
  });

  group('stroke play', () {
    testWidgets('the hole, the bubble and net to par', (t) async {
      await _tray(t, _card('stroke12'));
      expect(find.text('HOLE 12 · STROKE PLAY'), findsOneWidget);
      expect(find.text('VS PAR'), findsOneWidget);
      expect(find.text('gross 3 · net 3'), findsOneWidget);
      expect(find.text('Net par'), findsOneWidget);
      expect(find.text('Net to par'), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('gross 56 · net 48 · thru 12'), findsOneWidget);
    });

    testWidgets('round over: net total, the final card and the note',
        (t) async {
      await _tray(t, _card('stroke18'));
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('Net total'), findsOneWidget);
      expect(find.text('−2'), findsOneWidget);
      expect(find.text('Net 70 · −2'), findsOneWidget);
      expect(find.textContaining('nothing to settle'), findsOneWidget);
      expect(find.text('Finish round ›'), findsOneWidget);
    });
  });

  group('nassau', () {
    testWidgets('the hole line and the three bets', (t) async {
      await _tray(t, _card('nassau12'));
      expect(find.text('HOLE 12 · NASSAU'), findsOneWidget);
      expect(find.text('Halved'), findsOneWidget);
      for (final s in ['Front Par 1 UP', 'Back AS', 'Overall Par 1 UP']) {
        expect(
            find.byWidgetPredicate(
                (w) => w is RichText && w.text.toPlainText() == s),
            findsOneWidget,
            reason: s);
      }
    });

    testWidgets('round over: the count and what each bet did', (t) async {
      await _tray(t, _card('nassau18'));
      expect(find.text('2 won · 1 lost'), findsOneWidget);
      expect(find.textContaining('front lost, back won, overall won'),
          findsOneWidget);
    });
  });

  group('match play', () {
    testWidgets('decided early: the closing score and the tiles', (t) async {
      await _tray(t, _card('match16'));
      expect(find.text('Paul wins 3&2'), findsOneWidget);
      expect(find.textContaining('holes 17–18 played out for the card'),
          findsOneWidget);
      expect(find.text('Won'), findsOneWidget);
      for (var h = 1; h <= 18; h++) {
        expect(find.text('$h'), findsOneWidget, reason: 'hole $h');
      }
    });

    testWidgets('the holes after a close-out say so in one line', (t) async {
      await _tray(t, _card('match18'));
      expect(find.text('MATCH Paul won 3&2 · hole 18 is played out'),
          findsOneWidget);
    });
  });

  group('the tray', () {
    testWidgets('the forward button is the next hole', (t) async {
      var n = 0;
      await _tray(t, _card('stroke12'), onNext: () => n++);
      await t.tap(find.text('Hole 13 ›'));
      expect(n, 1);
    });

    testWidgets('a hole waiting for its result draws no blocks', (t) async {
      await _tray(t, _card('nassau12'), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('HOLE 12 · NASSAU'), findsNothing);
    });

    testWidgets('fits a 320pt phone', (t) async {
      for (final n in ['stroke18', 'nassau18', 'match16']) {
        await _tray(t, _card(n), size: const Size(320, 1500));
        expect(t.takeException(), isNull, reason: n);
      }
    });
  });

  group('the screen', () {
    final src = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('solo is on the keypad, the tray gate and the pager', () {
      expect(src, contains('_soloRound(rp);'));
      expect(src, contains('_soloCard(rp) != null ||'));
      expect(src, contains('&& !soloTray)'));
    });

    test('the keypad takes the strokes from the card', () {
      expect(src, contains('if (solo != null) return solo.strokes;'));
    });

    test('the scorecard leaves score entry once the card is there', () {
      final at = src.indexOf('SoloHoleLine(');
      final before = src.substring(at - 400, at);
      expect(before, contains('rp.soloHoleCard(_selectedHole) == null'));
    });
  });
}
