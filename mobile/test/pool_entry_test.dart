import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/widgets/skins_entry.dart';

/// Multi-Group Skins on the keypad and the Skins tray (Paul, 10 Nov 2026:
/// *"Multi-group skins needs the new score entry model, yes remove the table
/// from score entry, remove the strokes table from the leaderboard"*).
///
/// **There is no pool tray.** The server sends the Skins card's shape over
/// the whole field and `SkinsHoleTray` draws it; these pin the handful of
/// things a pool changes on it, and the wiring that puts it on the screen.
///
/// The fixtures are REAL engine output, written by
/// `REGEN_POOL_FIXTURES=1 manage.py test
/// scoring.tests.test_multi_skins_hole_card`.

SkinsHoleCard _card(String name, {Map<String, dynamic> over = const {}}) =>
    SkinsHoleCard.fromJson({
      ...(jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
          as Map<String, dynamic>),
      ...over,
    });

Future<void> _pump(WidgetTester t, SkinsHoleCard card,
    {Size size = const Size(390, 900)}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: SkinsHoleTray(
        card: card, onEdit: () {}, onNext: () {}, onPrev: () {},
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// The swatch beside a ledger name — the first decorated box in its row.
Color? _swatch(WidgetTester t, String name) {
  final row = find.ancestor(
      of: find.text(name).last, matching: find.byType(Row)).first;
  final box = t.widgetList<Container>(
      find.descendant(of: row, matching: find.byType(Container)))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .first;
  return box.color;
}

void main() {
  group('the model', () {
    test('a pool card says it is one, and what the field has done', () {
      final c = _card('pool_hole2_waiting');
      expect(c.acrossGroups, isTrue);
      expect(c.settled, isFalse);
      expect(c.outcome, 'waiting');
      expect(c.isPool, isTrue);
    });

    test('a round-skins card defaults to none of it', () {
      // The same model reads both, so every pool key has to default to what
      // round skins means — or a Skins tray starts drawing a pool's words.
      final c = _card('skins_hole7_outright');
      expect(c.acrossGroups, isFalse);
      expect(c.settled, isTrue);
      expect(c.trayTrailing, isEmpty);
      expect(c.footer, isEmpty);
      expect(c.worthSub, isEmpty);
      expect(c.players.every((p) => p.inPool), isTrue);
    });
  });

  group('a hole waiting on the field', () {
    testWidgets('says who leads so far and how many are in', (t) async {
      await _pump(t, _card('pool_hole2_waiting'));
      expect(find.text('Leading so far: Paul, net 3'), findsOneWidget);
      expect(find.text('4 of 6 in'), findsOneWidget);
    });

    testWidgets('lights nobody up as the winner', (t) async {
      // Leading with two golfers still to play is not a skin.
      await _pump(t, _card('pool_hole2_waiting'));
      expect(find.text('1 skin'), findsNothing);
    });

    testWidgets('the label carries the pot, not "1 riding"', (t) async {
      // Nothing rides in a pool, so the Skins wording would say the same
      // thing on all eighteen holes.
      await _pump(t, _card('pool_hole2_waiting'));
      expect(find.text('\$10 ANTE · \$60 POOL'), findsOneWidget);
      expect(find.textContaining('RIDING'), findsNothing);
    });

    testWidgets('the footer is the server\'s', (t) async {
      final c = _card('pool_hole2_waiting');
      await _pump(t, c);
      expect(c.footer, contains('waiting on other groups'));
      expect(find.text(c.footer), findsOneWidget);
      expect(find.textContaining('holes left'), findsNothing);
    });
  });

  group('a settled hole', () {
    testWidgets('a winner on this card takes the tag', (t) async {
      await _pump(t, _card('pool_hole1_won'));
      expect(find.text('Paul takes the skin with net 3'), findsOneWidget);
      expect(find.text('1 skin'), findsOneWidget);
    });

    testWidgets('a winner in another group is named and tags no row',
        (t) async {
      await _pump(t, _card('pool_hole1_won_elsewhere'));
      expect(find.text('Larry takes the skin with net 3'), findsOneWidget);
      expect(find.text('1 skin'), findsNothing);
    });
  });

  group('the ledger is this card\'s', () {
    // Paul, 10 Nov 2026: "there could be a lot of players in the match —
    // just show the status of the players in the group."
    testWidgets('a winner from another group is named and given no row',
        (t) async {
      final c = _card('pool_hole1_won_elsewhere');
      await _pump(t, c);
      expect(c.ledger.map((e) => e.first), isNot(contains('Larry')));
      // Named once, in the result line — and nowhere in the ledger.
      expect(find.textContaining('Larry'), findsOneWidget);
    });

    testWidgets('every row is a golfer on this card, in his own colour',
        (t) async {
      final c = _card('pool_hole1_won_elsewhere');
      await _pump(t, c);
      final onCard = c.players.map((p) => p.playerId).toSet();
      for (final e in c.ledger) {
        expect(onCard, contains(e.playerId));
        expect(_swatch(t, e.first), Halved.onDarkFor(e.rosterIndex!));
      }
    });

    testWidgets('the footer says the skin went to another group', (t) async {
      // Four `$0` rows under `Won 1 of 1` would otherwise look like a fault.
      final c = _card('pool_hole1_won_elsewhere');
      await _pump(t, c);
      expect(c.footer, contains('1 to other groups'));
      expect(find.text(c.footer), findsOneWidget);
    });
  });

  group('a golfer on the card who is not in the pool', () {
    testWidgets('has a row that says so', (t) async {
      final c = _card('pool_hole1_mixed_card');
      await _pump(t, c);
      final gil = c.players.firstWhere((p) => p.first == 'Gil');
      expect(gil.inPool, isFalse);
      expect(find.text('gross ${gil.gross} · not in the pool'),
          findsOneWidget);
    });

    testWidgets('and the title still counts his score', (t) async {
      await _pump(t, _card('pool_hole1_mixed_card'));
      expect(find.text('All 4 scores in'), findsOneWidget);
    });
  });

  group('a card of one', () {
    testWidgets('reads as a sentence', (t) async {
      // Everybody on his own card is where a casual pool STARTS.
      final j = jsonDecode(File('test/fixtures/pool_hole1_won.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final one = [(j['players'] as List).first];
      await _pump(t, SkinsHoleCard.fromJson(
          {...j, 'players': one, 'scored': 1}));
      expect(find.text('Score in'), findsOneWidget);
      expect(find.textContaining('All 1'), findsNothing);
    });
  });

  group('the worth header', () {
    testWidgets('says what a pool does instead of what carried', (t) async {
      final c = _card('pool_hole2_waiting');
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SkinsHoleWorth(card: c))));
      expect(find.text('6 in the pool · a tie kills it'), findsOneWidget);
      expect(find.text('none carried'), findsNothing);
    });
  });

  group('it fits a phone', () {
    for (final name in [
      'pool_hole2_waiting', 'pool_hole1_won', 'pool_hole1_won_elsewhere',
      'pool_hole1_mixed_card',
    ]) {
      testWidgets('$name overflows nothing at 320pt', (t) async {
        await _pump(t, _card(name), size: const Size(320, 900));
        expect(t.takeException(), isNull);
      });
    }
  });

  group('the screen', () {
    final se = File('lib/screens/score_entry_screen.dart').readAsStringSync();

    String body(String signature) {
      final at = se.indexOf(signature);
      expect(at, greaterThan(0), reason: signature);
      return se.substring(at, se.indexOf('\n  }\n', at));
    }

    test('the pool as primary enters on the keypad', () {
      expect(body('bool _keypadRound(RoundProvider rp)'),
          contains('primary == GameIds.multiSkins'));
    });

    test('and is handed the pool\'s card in the Skins slot', () {
      // One slot is what gives it the tray, the auto-post and the hidden
      // pager for free: `_raisesTray` and the tray branch read `_skinsCard`.
      final b = body('SkinsHoleCard? _skinsCard(RoundProvider rp)');
      expect(b, contains('GameIds.multiSkins'));
      expect(b, contains('rp.poolHole(_selectedHole)'));
    });

    test('the card is fetched for a hole that has none', () {
      // No card, no keypad — the shape Sixes, Rabbit and Points each hit.
      final b = body('void _ensureSkinsCard(RoundProvider rp)');
      expect(b, contains('loadPoolHole('));
      expect(b, contains('_poolIsPrimary(rp)'));
    });

    test('a pool that is NOT the primary changes nothing here', () {
      // On a tournament it rides beside Stroke Play, which owns the entry.
      expect(body('bool _poolIsPrimary(RoundProvider rp)'),
          contains('resolvePrimary('));
    });

    test('a row takes its stroke dots from the pool\'s card', () {
      // Strokes-off in a pool is off the POOL's low man, usually in another
      // group; the generic allocation anchors on this foursome's. The
      // keypad reads the card, so a row that did not would disagree with
      // the keypad directly under it.
      final at = se.indexOf('int _strokesForHole(Membership m, ScorecardHole? h) {');
      final gross = se.indexOf("handicapMode == 'gross') return 0;", at);
      final b = se.substring(at, gross);
      expect(b, contains('pool.acrossGroups'));
      expect(b, contains('return p.strokes;'),
          reason: 'and BEFORE the gross return — a gross round can host a '
              'net pool');
    });

    test('the standings table is gone from score entry', () {
      expect(se.contains('_MultiSkinsStandingsCard('), isFalse);
      expect(se.contains('class _MultiSkinsStandingsCard'), isFalse);
    });
  });

  group('the provider', () {
    final rp = File('lib/providers/round_provider.dart').readAsStringSync();

    test('takes the card that comes back with the save', () {
      expect(rp, contains("response['multi_skins_hole']"));
    });

    test('and drops stale ones when a save brings none', () {
      // The server sends it only where it can tell the pool is the primary.
      final at = rp.indexOf("response['multi_skins_hole']");
      final end = rp.indexOf("response['nassau_hole']", at);
      expect(rp.substring(at, end), contains('else if (_poolHoles.isNotEmpty)'));
    });

    test('a new round starts with none', () {
      expect('_poolHoles.clear();'.allMatches(rp).length,
          greaterThanOrEqualTo(4));
    });
  });

  group('the leaderboard', () {
    test('the pool\'s scorecard draws no strokes table', () {
      final lb = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      final at = lb.indexOf('SkinsBoardData.fromPool(');
      expect(at, greaterThan(0));
      final call = lb.indexOf('HoleGridScorecard(', at);
      final end = lb.indexOf('\nclass ', at);
      expect(call, lessThan(end), reason: 'the pool card still draws it');
      expect(RegExp(r'showStrokes:\s*false')
          .hasMatch(lb.substring(call, end)), isTrue);
    });
  });
}
