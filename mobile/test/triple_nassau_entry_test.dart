import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/triple_nassau_entry.dart';

/// Triple Nassau score entry —
/// `~/Downloads/handoff-triple-nassau-score-entry` (11 Nov 2026).
///
/// The engine is covered in `scoring/tests/test_triple_nassau_hole_card.py`,
/// which also WRITES the fixtures these draw (`REGEN_TN_FIXTURES=1`): the
/// handoff's worked example played through the real engine.

TripleNassauHoleCard _card(String name) => TripleNassauHoleCard.fromJson(
    jsonDecode(File('test/fixtures/triple_nassau_$name.json')
        .readAsStringSync()) as Map<String, dynamic>);

Future<void> _tray(WidgetTester t, TripleNassauHoleCard card, {
  Size size = const Size(390, 1500),
  void Function(TripleNassauCardMatch)? onPress,
  VoidCallback? onNext,
  bool gettingResult = false,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MediaQuery(
          data: MediaQueryData(size: Size(size.width, size.height + 400)),
          child: TripleNassauHoleTray(
            card: card,
            onEdit: () {},
            onPrev: () {},
            onNext: onNext ?? () {},
            onPress: onPress,
            gettingResult: gettingResult,
          ),
        ),
      ),
    ),
  ));
}

Future<void> _players(WidgetTester t, TripleNassauHoleCard card,
    {int? active, void Function(int)? onTap}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TripleNassauPlayersCard(
          card: card,
          scores: {
            for (final p in card.players)
              if (p.gross != null) p.playerId: p.gross!
          },
          activePlayerId: active,
          onTapPlayer: onTap ?? (_) {},
        ),
      ),
    ),
  ));
}

void main() {
  group('the golfer card', () {
    testWidgets('names a pill per match he gets strokes in', (t) async {
      await _players(t, _card('hole3'));
      expect(find.text('plays off scratch'), findsOneWidget);
      expect(find.text('5 v Paul'), findsOneWidget); // Dave's
      expect(find.text('5 v Dave'), findsOneWidget); // Sam's
      expect(find.text('10 v Paul'), findsOneWidget);
      expect(find.text('YOUR GROUP'), findsOneWidget);
      expect(find.text('STROKES BY MATCH'), findsOneWidget);
    });

    testWidgets('draws no net — it differs by match', (t) async {
      await _players(t, _card('hole3'));
      expect(find.textContaining('net'), findsNothing);
    });

    testWidgets('a tap names the golfer', (t) async {
      int? got;
      final c = _card('hole3');
      await _players(t, c, onTap: (id) => got = id);
      await t.tap(find.text('Dave Gabe'));
      expect(got, c.players[1].playerId);
    });

    test('a golfer carries a dot per match, against that opponent', () {
      final c = _card('hole3_entry');
      // Hole 3 is SI 13 — nobody strokes — so the fixture has none; the
      // stroke arithmetic is the server's and is pinned there.
      expect(c.players.every((p) => p.dots.isEmpty), isTrue);
    });
  });

  group('the tray', () {
    testWidgets('is one block per match, in the engine\'s order', (t) async {
      final c = _card('hole3');
      await _tray(t, c);
      expect(find.text('All 3 scores in'), findsOneWidget);
      expect(find.text('HOLE 3 · TRIPLE NASSAU'), findsOneWidget);
      expect(find.text('Front '), findsNothing); // spans, not plain text
      expect(c.matches.map((m) => m.names.join(' v ')),
          ['Paul v Dave', 'Paul v Sam', 'Dave v Sam']);
      expect(find.byType(TripleNassauHoleTray), findsOneWidget);
    });

    testWidgets('a halved match says Halved', (t) async {
      await _tray(t, _card('hole3'));
      expect(find.text('Halved'), findsOneWidget);
      expect(find.text('Won'), findsNWidgets(2));
    });

    testWidgets('a press that starts next hole is a dashed chip', (t) async {
      final c = _card('hole3');
      await _tray(t, c);
      expect(
          find.byWidgetPredicate((w) =>
              w is RichText && w.text.toPlainText() == 'P1 starts 4'),
          findsNWidgets(2));
    });

    testWidgets('money: highest first, up in mint, level muted', (t) async {
      await _tray(t, _card('hole3'));
      expect(find.text('EACH · NOW'), findsOneWidget);
      expect(find.text('thru 3'), findsOneWidget);
      expect(find.text('+\$40'), findsOneWidget);
      expect(find.text('−\$20'), findsNWidgets(2));
      final ys = ['Paul Lipkin', 'Dave Gabe', 'Sam White']
          .map((n) => t.getTopLeft(find.text(n)).dy)
          .toList();
      expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue);
    });

    testWidgets('the last hole finishes the round and says who pays',
        (t) async {
      await _tray(t, _card('hole18'));
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('Finish round ›'), findsOneWidget);
      expect(find.text('Sam pays Paul \$30'), findsOneWidget);
      expect(find.text('Paul and Dave are square'), findsOneWidget);
    });

    testWidgets('the forward button is the next hole', (t) async {
      var n = 0;
      await _tray(t, _card('hole3'), onNext: () => n++);
      await t.tap(find.text('Hole 4 ›'));
      expect(n, 1);
    });

    testWidgets('a hole waiting for its result draws no blocks', (t) async {
      await _tray(t, _card('hole3'), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('EACH · NOW'), findsNothing);
    });

    testWidgets('a Press button only where the engine offers one',
        (t) async {
      final c = _card('hole7');
      final offered = c.matches.where((m) => m.pressStart != null).toList();
      expect(offered, isNotEmpty);
      TripleNassauCardMatch? got;
      await _tray(t, c, onPress: (m) => got = m);
      expect(find.text('Press'), findsNWidgets(offered.length));
      await t.tap(find.text('Press').first);
      expect(got!.gameType, offered.first.gameType);
    });

    testWidgets('no onPress, no buttons', (t) async {
      await _tray(t, _card('hole7'));
      expect(find.text('Press'), findsNothing);
    });

    testWidgets('the back nine drops the front bets', (t) async {
      final c = _card('hole14');
      for (final m in c.matches) {
        expect(m.chips.map((x) => x.label), isNot(contains('Front')));
      }
    });

    testWidgets('fits a 320pt phone', (t) async {
      await _tray(t, _card('hole7'), size: const Size(320, 1500),
          onPress: (_) {});
      expect(t.takeException(), isNull);
    });
  });

  group('wiring', () {
    final screen =
        File('lib/screens/triple_nassau_screen.dart').readAsStringSync();

    test('the keypad posts the hole on its last score', () {
      final at = screen.indexOf('FortyBallsKeypad(');
      expect(at, greaterThan(0));
      final body = screen.substring(at, screen.indexOf('_pager(ctx', at));
      expect(body, contains('_saveHole(ctx, hole, players)'));
      expect(body, contains('_kCleared'));
    });

    test('a clear goes out as a null gross', () {
      expect(screen, contains("e.value == _kCleared ? null : e.value"));
    });

    test('the keypad names the opponents the strokes are against', () {
      expect(screen, contains('strokeNote: cp?.strokeText'));
    });

    test('a press brings its card back with it', () {
      expect(screen, contains('pressTripleNassau('));
      expect(screen, contains('setTripleNassauHole(card)'));
    });

    test('the old matrix and call-press are the fallback only', () {
      expect(screen, contains('if (card == null) ...['));
      expect(screen, contains('if (s != null && card == null) ...['));
    });
  });
}
