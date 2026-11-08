import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/skins_entry.dart';

/// Skins score entry — `~/Downloads/handoff-skins-score-entry`.
///
/// **The fixtures are REAL engine output**, written by
/// `REGEN_SKINS_FIXTURES=1 manage.py test scoring.tests.test_skins_hole_card`.
/// The engine is covered in that file; these are about what the tray DRAWS,
/// and the source guards about what the shared screen has to keep doing.

Map<String, dynamic> _fixture(String name) => jsonDecode(
        File('test/fixtures/$name.json').readAsStringSync())
    as Map<String, dynamic>;

SkinsHoleCard _card(String name, {Map<String, dynamic> over = const {}}) =>
    SkinsHoleCard.fromJson({..._fixture(name), ...over});

Future<void> _pump(WidgetTester t, SkinsHoleCard card,
    {bool gettingResult = false,
     Size size = const Size(390, 900)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: SkinsHoleTray(
        card: card,
        onEdit: () {},
        onNext: () {},
        onPrev: () {},
        gettingResult: gettingResult,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the card parses what the server sends', () {
    test('an outright winner takes everything riding', () {
      final c = _card('skins_hole7_outright');
      expect(c.outcome, 'outright');
      expect(c.riding, 2);
      expect(c.carriedIn, 1);
      expect(c.carriedFrom, 6);
      expect(c.line, 'Paul takes 2 skins with net 4');
      expect(c.ridesTo, isEmpty);
    });

    test('the nets run low to high', () {
      final c = _card('skins_hole7_outright');
      final nets = [for (final p in c.players) p.net!];
      expect(nets, [...nets]..sort());
    });

    test('a tie carries and says where to', () {
      final c = _card('skins_hole2_carry');
      expect(c.outcome, 'carry');
      expect(c.winnerId, isNull);
      expect(c.line, startsWith('Tied on net'));
      expect(c.ridesTo, '2 ride to 3');
    });

    test('a gross birdie steal names both scores', () {
      final c = _card('skins_hole1_steal');
      expect(c.outcome, 'steal');
      expect(c.stealBy, isNotNull);
      expect(c.line, contains('Gross birdie steals'));
      final paul = c.players.firstWhere((p) => p.first == 'Paul');
      expect(paul.birdie, isTrue);
    });

    test('an open hole has no result and still knows what rides', () {
      final c = _card('skins_hole7_open');
      expect(c.outcome, 'pending');
      expect(c.riding, 2);
      expect(c.players.every((p) => p.gross == null), isTrue);
    });
  });

  group('the tray', () {
    testWidgets('it names the hole, what rides and the stake', (t) async {
      await _pump(t, _card('skins_hole7_outright'));
      expect(find.text('All 4 scores in'), findsOneWidget);
      expect(find.text('HOLE 7 · SKINS'), findsOneWidget);
      expect(find.text('2 RIDING · \$5 A SKIN'), findsOneWidget);
    });

    testWidgets('the winner carries a skins tag and the result line',
        (t) async {
      await _pump(t, _card('skins_hole7_outright'));
      expect(find.text('2 skins'), findsOneWidget);
      expect(find.text('Paul takes 2 skins with net 4'), findsOneWidget);
    });

    testWidgets('a gross birdie is named under the score', (t) async {
      await _pump(t, _card('skins_hole1_steal'));
      expect(find.text('gross 3 · birdie'), findsOneWidget);
      expect(find.text('gross 4'), findsOneWidget);
    });

    testWidgets('a carry says what rides, in the orange slot', (t) async {
      await _pump(t, _card('skins_hole2_carry'));
      expect(find.text('2 ride to 3'), findsOneWidget);
      expect(find.textContaining('Tied on net'), findsOneWidget);
    });

    testWidgets('the ledger footer counts the skins actually won', (t) async {
      await _pump(t, _card('skins_hole7_outright'));
      expect(find.textContaining('Won 7 of 7'), findsOneWidget);
      expect(find.textContaining('11 holes left'), findsOneWidget);
    });

    testWidgets('and says round over on the last hole', (t) async {
      await _pump(t, _card('skins_hole18_final'));
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('Complete Round ›'), findsOneWidget);
      expect(find.textContaining('round over'), findsOneWidget);
    });

    testWidgets('a hole still syncing draws no result', (t) async {
      await _pump(t, _card('skins_hole7_outright'), gettingResult: true);
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.text('Paul takes 2 skins with net 4'), findsNothing);
    });

    testWidgets('a pool quotes no per-skin price', (t) async {
      // One pot is divided among however many skins get won, so a per-skin
      // figure would stop being true the moment the next one is.
      await _pump(t, _card('skins_hole7_outright',
          over: {'is_pool': true, 'hole_value': 0.0, 'skin_worth': 0.0}));
      expect(find.text('2 RIDING · \$5 A SKIN'), findsNothing);
      expect(find.text('2 RIDING · \$5 ANTE'), findsOneWidget);
      expect(find.text('MONEY'), findsOneWidget);
    });
  });

  group('a golfer keeps one colour', () {
    /// Every 10x10 swatch in the tray, in tree order: one a golfer in the
    /// nets block, then one a golfer in the ledger.
    List<Color> swatches(WidgetTester t) => [
          for (final c in t.widgetList<Container>(find.byType(Container)))
            if (c.constraints?.maxWidth == 10 &&
                c.constraints?.maxHeight == 10 &&
                (c.decoration as BoxDecoration?)?.color != null)
              (c.decoration as BoxDecoration).color!,
        ];

    testWidgets('the nets block and the ledger agree, golfer for golfer',
        (t) async {
      // The ledger is sorted by SKINS and the nets by score, so the two
      // lists are in different orders — which is exactly how a colour
      // taken from a list position comes to mean two different golfers.
      final c = _card('skins_hole7_outright');
      await _pump(t, c);
      final all = swatches(t);
      expect(all.length, c.players.length * 2);
      final nets = all.sublist(0, c.players.length);
      final led  = all.sublist(c.players.length);
      for (var i = 0; i < c.players.length; i++) {
        final row = c.ledger.indexWhere(
            (e) => e.playerId == c.players[i].playerId);
        expect(nets[i], led[row],
            reason: '${c.players[i].first} wears two colours');
      }
    });

    testWidgets('and it is his place in the ROSTER, not his place here',
        (t) async {
      final c = _card('skins_hole7_outright');
      await _pump(t, c);
      final nets = swatches(t).sublist(0, c.players.length);
      for (var i = 0; i < c.players.length; i++) {
        expect(nets[i], Halved.onDarkFor(c.players[i].rosterIndex!),
            reason: 'otherwise a golfer changes colour the moment he wins');
      }
      expect(nets.toSet().length, c.players.length,
          reason: 'four golfers, four colours');
    });
  });

  group('the ticks', () {
    int outlined(WidgetTester t, Color border) => [
          for (final c in t.widgetList<Container>(find.byType(Container)))
            if (c.constraints?.maxWidth == 9 &&
                ((c.decoration as BoxDecoration?)?.border as Border?)
                        ?.top.color ==
                    border)
              c,
        ].length;

    testWidgets('the skins won on THIS hole are outlined in mint',
        (t) async {
      // Two riding, both taken here — so the whole of Paul's four reads as
      // two older and two fresh, and a reader can see what this hole did.
      final c = _card('skins_hole7_outright');
      await _pump(t, c);
      expect(outlined(t, Halved.brightMint), 2);
    });

    testWidgets('and a hole that won nothing outlines none', (t) async {
      await _pump(t, _card('skins_hole2_carry'));
      expect(outlined(t, Halved.brightMint), 0);
    });
  });

  group('the worth header', () {
    testWidgets('it says what the hole is worth and what carried in',
        (t) async {
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkinsHoleWorth(card: _card('skins_hole7_open')),
        ),
      ));
      expect(find.text('2 skins · \$30'), findsOneWidget);
      expect(find.text('1 carried from 6'), findsOneWidget);
    });

    testWidgets('…and skins only under a pool', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkinsHoleWorth(
              card: _card('skins_hole7_open',
                  over: {'is_pool': true, 'hole_value': 0.0})),
        ),
      ));
      expect(find.text('2 skins'), findsOneWidget);
    });

    testWidgets('a first hole says none carried', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 300));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SkinsHoleWorth(card: _card('skins_hole2_carry')),
        ),
      ));
      expect(find.text('none carried'), findsOneWidget);
    });
  });

  group('it fits a phone', () {
    testWidgets('nothing overflows at 320pt', (t) async {
      await _pump(t, _card('skins_hole18_final'),
          size: const Size(320, 900));
      expect(t.takeException(), isNull);
    });
  });

  group('the screen keeps what a game of its own would lose', () {
    final src =
        File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('Skins enters on the shared keypad', () {
      expect(src, contains('primary == GameIds.skins'));
    });

    test('its hole raises a tray, so the hole posts itself', () {
      final i = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      expect(i, greaterThan(0));
      expect(src.substring(i, src.indexOf(';', i)),
          contains('_skinsCard(rp) != null'));
    });

    test('the keypad takes its strokes from the CARD', () {
      // Skins carries its own handicap mode and allowance, so the round's
      // stored full-net strokes would tell the low man he gets dots he
      // does not — the bug Sixes reported from the course.
      final i = src.indexOf('int _keypadStrokes(');
      expect(src.substring(i, src.indexOf('\n  }', i)),
          contains('_skinsCard(rp)'));
    });

    test('the pager hides under the tray', () {
      final i = src.indexOf('if (!sixTray');
      expect(i, greaterThan(0));
      expect(src.substring(i, src.indexOf(')', i)), contains('!skTray'));
    });

    test('the hole banner and the carry chip go quiet', () {
      // Both say what the tray says, shorter and higher up.
      expect(src, contains('if (skinsCard == null &&\n              skinsHole'));
      expect(src, contains('if (skinsCard == null &&\n              skins !='));
    });
  });
}
