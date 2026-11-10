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
  group('the round\'s card is the leaderboard\'s', () {
    test('score entry draws no Skins scorecard', () {
      // It sat under the hole, behind the tray; the Skins board draws the
      // same card (Paul, 10 Nov 2026).
      final se = File('lib/screens/score_entry_screen.dart').readAsStringSync();
      expect(se.contains('skins!.scorecardHoles'), isFalse);
    });

    test('the Skins board still draws it', () {
      // The other half of a move: without this the round's hole-by-hole
      // card would exist on no screen at all, which is what happened to
      // Rabbit's for a few hours.
      final lb = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      final at = lb.indexOf('class _SkinsGroupCard');
      expect(at, greaterThan(0));
      final end = lb.indexOf('\nclass ', at + 10);
      expect(lb.substring(at, end).contains('HoleGridScorecard('), isTrue);
    });
  });

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

    testWidgets('a gross birdie is named beside the golfer', (t) async {
      await _pump(t, _card('skins_hole1_steal'));
      expect(find.text('gross 3 · birdie'), findsOneWidget);
      expect(find.text('gross 4'), findsOneWidget);
    });

    testWidgets('the gross is on the same line as the name', (t) async {
      // It sat on a second line under the name, which made the nets box
      // four two-line rows tall (Paul, 10 Nov 2026: "put it on the same
      // line as the name and shrink that top box").
      final card = _card('skins_hole1_steal');
      await _pump(t, card);
      for (final p in card.players) {
        if (p.gross == null) continue;
        final name = t.getRect(find.text(p.first).first);
        final gross = t.getRect(find.text(
            'gross ${p.gross}${p.birdie ? ' · birdie' : ''}').first);
        expect((name.center.dy - gross.center.dy).abs(), lessThan(3),
            reason: '${p.first}: one line');
        expect(gross.left, greaterThan(name.right),
            reason: '${p.first}: the name first');
      }
    });

    testWidgets('a row is one line tall', (t) async {
      // The point of the change, measured: a two-line row was ~40pt. The
      // 19pt net is the tallest thing left on it.
      final card = _card('skins_hole1_steal');
      await _pump(t, card);
      final p = card.players.firstWhere((x) => x.gross != null);
      final name = t.getRect(find.text(p.first).first);
      final net = t.getRect(find.text('${p.net}').first);
      expect((name.center.dy - net.center.dy).abs(), lessThan(3));
      final rows = [
        for (final x in card.players) t.getRect(find.text(x.first).first)
      ]..sort((a, b) => a.top.compareTo(b.top));
      expect(rows[1].top - rows[0].top, lessThan(34),
          reason: 'row pitch — it was about 42 with the gross underneath');
    });

    testWidgets('a long name on a narrow phone overflows nothing', (t) async {
      // Nothing in the name-and-gross run is rigid: a fixed gross beside a
      // flexible name overflowed by 80px here. Whether either CLIPS is not
      // asserted — the test font is one square a glyph, so it would be
      // measuring the font.
      final j = _fixture('skins_hole1_steal');
      final players = [
        for (final p in (j['players'] as List))
          {...(p as Map).cast<String, dynamic>(),
           'first': 'Bartholomew-Maximilian'},
      ];
      await _pump(t, SkinsHoleCard.fromJson({...j, 'players': players}),
          size: const Size(320, 900));
      expect(t.takeException(), isNull);
      expect(find.text('gross 3 · birdie'), findsOneWidget);
    });

    testWidgets('the name yields before the gross does', (t) async {
      // `gross 3 · birdie` is what says why a net lost to a natural birdie;
      // a clipped name is still a name.
      final j = _fixture('skins_hole1_steal');
      final players = [
        for (final p in (j['players'] as List))
          {...(p as Map).cast<String, dynamic>(),
           'first': 'Bartholomew-Maximilian'},
      ];
      await _pump(t, SkinsHoleCard.fromJson({...j, 'players': players}),
          size: const Size(320, 900));
      final name = t.getSize(find.text('Bartholomew-Maximilian').first);
      final gross = t.getSize(find.text('gross 3 · birdie'));
      expect(gross.width, greaterThan(name.width));
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

  group('the ledger\'s money is one column', () {
    // Found from the Wolf tray's wobble (10 Nov 2026): the ticks were a
    // loose `Flexible` beside the `Expanded` name, so whatever they did not
    // use was left at the END of the row and the money sat mid-row, further
    // left the fewer skins a golfer held.
    for (final name in ['skins_hole7_outright', 'skins_hole1_steal']) {
      testWidgets('$name: every figure ends where the heading does',
          (t) async {
        final card = _card(name);
        await _pump(t, card);
        final col = find.byWidgetPredicate(
            (w) => w is SizedBox && w.width == 76.0 && w.child != null);
        expect(col, findsNWidgets(card.ledger.length + 1));
        final edges = {
          for (final e in col.evaluate())
            t.getTopRight(find.byWidget(e.widget)).dx.round(),
        };
        expect(edges, hasLength(1), reason: 'the money drifts: $edges');
      });
    }

    testWidgets('the fixture has golfers with different skin counts',
        (t) async {
      // Equal counts would line up under either layout.
      final counts =
          _card('skins_hole7_outright').ledger.map((e) => e.totalSkins).toSet();
      expect(counts.length, greaterThan(1));
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
