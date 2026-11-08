import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/widgets/banker_entry.dart';

/// Banker score entry — `~/Downloads/handoff-banker-score-entry`, which folds
/// the betting into the score screen.
///
/// `services/banker.py` owns the sequence and the arithmetic — what a call
/// reaches, who won each one-on-one, the chain under every line, who banks
/// next. These are about what the two widgets DRAW, and the source guards
/// about what the shared screen has to keep doing.

const _roster = <({int id, String first})>[
  (id: 1, first: 'Paul'), (id: 2, first: 'Dave'),
  (id: 3, first: 'Sam'),  (id: 4, first: 'Lee'),
];

Map<String, dynamic> _line(int id, String name, double bet, {
  int mult = 1, bool countered = false, bool birdie = false,
  double stake = 0, String outcome = 'open', double amount = 0,
  int? net, int? bankerNet, String chain = '',
}) => {
      'player_id': id, 'name': name, 'short_name': name,
      'bet': bet, 'own_multiplier': mult, 'countered': countered,
      'capped': false, 'birdie': birdie, 'stake': stake == 0 ? bet : stake,
      'chain': chain.isEmpty ? '\$${bet.toInt()} bet = \$${bet.toInt()}'
                             : chain,
      'outcome': outcome, 'amount': amount,
      'handicap_index': 0.0, 'playing_handicap': 0, 'strokes': 0,
      'stroke_note': '', 'banker_net': bankerNet, 'net': net,
      'gross': net,
    };

Map<String, dynamic> _hole({
  int hole = 7, int par = 4, bool isPar3 = false, bool locked = false,
  bool countered = false, bool resolved = false,
  double? maxBet, int? bankerGross, double exposure = 0,
  List<Map<String, dynamic>> lines = const [],
  Map<String, dynamic> holeMoney = const {}, int? lowNet,
}) => {
      'hole': hole, 'par': par, 'stroke_index': 5, 'is_par_3': isPar3,
      'banker_id': 1, 'banker_gross': bankerGross, 'banker_handicap': 0,
      'max_bet': maxBet, 'locked': locked, 'countered': countered,
      'tie_reason': '', 'hole_capped': false, 'lines': lines,
      'banker_delta': 0, 'resolved': resolved, 'exposure': exposure,
      'exposure_if_max': exposure, 'outstanding': const [], 'cut_off': const [],
      'hole_money': holeMoney, if (lowNet != null) 'low_net': lowNet,
    };

BankerSummary _summary({
  Map<String, dynamic>? current,
  int? awaitingTie,
  List<Map<String, dynamic>> tieCandidates = const [],
  int? nextBankerId,
  double minBet = 5, double maxBet = 50,
  bool playerDouble = true, bool counter = true, bool par3Triples = true,
  List<Map<String, dynamic>>? players,
}) =>
    BankerSummary.fromJson({
      'status': 'in_progress',
      'handicap_mode': 'strokes_off', 'net_percent': 100,
      'min_bet': minBet, 'max_bet': maxBet, 'rotation_rule': 'low_net',
      'rules': {'player_double': playerDouble, 'counter': counter,
                'par3_triples': par3Triples, 'birdie_bonus': true},
      'exposure_ladder': const [], 'hole_cap': null,
      'players': players ?? [
        for (final r in _roster)
          {'player_id': r.id, 'name': r.first, 'short_name': r.first,
           'banking': 0, 'betting': 0, 'total': 0},
      ],
      'holes': current == null ? const [] : [current],
      'current_hole': current?['hole'],
      'current': current,
      'awaiting_tie': awaitingTie,
      'tie_candidates': tieCandidates,
      'next_banker_id': nextBankerId,
      'next_banker_name': '',
      'biggest_swings': const [], 'bets_settled': 0,
      'stroke_plan': const {}, 'grid': const [], 'grid_players': const [],
      'money': {'transfers': const [], 'nets': const []},
    });

Future<void> _pumpCard(WidgetTester t, BankerSummary s, {
  bool scoreIn = false,
  void Function(double)? onMax,
  void Function(int, double)? onBet,
  VoidCallback? onLock,
  void Function(int, bool)? onDouble,
  void Function(bool)? onCounter,
  Size size = const Size(390, 900),
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: BankerBetsCard(
          summary: s, roster: _roster, scoreIn: scoreIn,
          onMax: onMax ?? (_) {},
          onBet: onBet ?? (_, __) {},
          onLock: onLock ?? () {},
          onDouble: onDouble ?? (_, __) {},
          onCounter: onCounter ?? (_) {},
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _pumpTray(WidgetTester t, BankerSummary s, {
  int? tiePick,
  void Function(int, String)? onPick,
  VoidCallback? onNext,
  bool roundOver = false,
  int? nextHole = 8,
  Size size = const Size(390, 900),
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      bottomNavigationBar: BankerHoleTray(
        summary: s, roster: _roster,
        onEdit: () {}, onPrev: () {}, onNext: onNext,
        tiePick: tiePick, onPickTie: onPick ?? (_, __) {},
        roundOver: roundOver, nextHole: nextHole,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the max chips', () {
    test('they are the house rungs inside the round band', () {
      expect(maxChipsFor(_summary(minBet: 5, maxBet: 50)), [10, 20, 50]);
    });

    test('and the round ceiling when it is not one of them', () {
      // Otherwise a group playing to $35 is offered a chip the server
      // refuses.
      expect(maxChipsFor(_summary(minBet: 5, maxBet: 35)), [10, 20, 35]);
    });

    test('a low ceiling drops the rungs above it', () {
      expect(maxChipsFor(_summary(minBet: 5, maxBet: 10)), [10]);
    });
  });

  group('on the tee', () {
    testWidgets('the banker sets the max, then the three bet', (t) async {
      await _pumpCard(t, _summary(current: _hole(maxBet: 20)));
      expect(find.text('Paul banks'), findsOneWidget);
      expect(find.text('sets the max, then the three bet'), findsOneWidget);
      expect(find.text('\$10'), findsOneWidget);
      expect(find.text('\$20'), findsWidgets);
      expect(find.text('\$50'), findsOneWidget);
      // Three rows, one a golfer who is NOT the banker.
      for (final n in ['Dave', 'Sam', 'Lee']) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.text('Paul'), findsNothing);
    });

    testWidgets('the lock names what it does, not who tees off', (t) async {
      // The app cannot know when anybody swings, and naming one golfer
      // asserts an order the format does not have — the board's own note.
      await _pumpCard(t, _summary(current: _hole(maxBet: 20, lines: [
        _line(2, 'Dave', 10), _line(3, 'Sam', 20), _line(4, 'Lee', 5),
      ])));
      expect(find.text('Lock the bets — increases only from here'),
          findsOneWidget);
      expect(find.textContaining('tees off'), findsNothing);
    });

    testWidgets('and counts the bets that are missing', (t) async {
      await _pumpCard(t, _summary(current: _hole(maxBet: 20, lines: [
        _line(2, 'Dave', 10),
      ])));
      expect(find.text('2 bets to go'), findsOneWidget);
    });

    testWidgets('a step sends the new amount', (t) async {
      final sent = <(int, double)>[];
      await _pumpCard(t, _summary(current: _hole(maxBet: 20, lines: [
        _line(2, 'Dave', 10),
      ])), onBet: (p, a) => sent.add((p, a)));
      await t.tap(find.byIcon(Icons.add).first);
      await t.pump();
      expect(sent.first.$2, 15, reason: r'$5 steps');
    });
  });

  group('in the air', () {
    testWidgets('the calls are a double, and a triple on a par 3', (t) async {
      await _pumpCard(t, _summary(current: _hole(
          locked: true, maxBet: 20, exposure: 70,
          lines: [_line(2, 'Dave', 10)])));
      expect(find.text('Double ×2'), findsOneWidget);
      expect(find.text('Triple ×3'), findsNothing);

      await _pumpCard(t, _summary(current: _hole(
          locked: true, isPar3: true, par: 3, maxBet: 20,
          lines: [_line(2, 'Dave', 10)])));
      expect(find.text('Triple ×3'), findsOneWidget);
      expect(find.text('Double ×2'), findsNothing);
    });

    testWidgets('the banker sees what the hole can cost him', (t) async {
      await _pumpCard(t, _summary(current: _hole(
          locked: true, maxBet: 20, exposure: 70,
          lines: [_line(2, 'Dave', 10)])));
      expect(find.text('at stake \$70'), findsOneWidget);
      expect(find.text('Paul banks · max \$20'), findsOneWidget);
    });

    testWidgets('the counter is one control over every bet', (t) async {
      final sent = <bool>[];
      await _pumpCard(t, _summary(current: _hole(
          locked: true, maxBet: 20, lines: [_line(2, 'Dave', 10)])),
          onCounter: sent.add);
      expect(find.text('Paul counter-doubles · every bet ×2'), findsOneWidget);
      await t.tap(find.text('Paul counter-doubles · every bet ×2'));
      await t.pump();
      expect(sent, [true]);
    });

    testWidgets('…and says so when it is on', (t) async {
      await _pumpCard(t, _summary(current: _hole(
          locked: true, countered: true, maxBet: 20,
          lines: [_line(2, 'Dave', 10)])));
      expect(find.text('Paul countered · every bet ×2'), findsOneWidget);
    });

    testWidgets('the first score closes the calls', (t) async {
      final sent = <(int, bool)>[];
      await _pumpCard(t, _summary(current: _hole(
          locked: true, maxBet: 20, lines: [_line(2, 'Dave', 10)])),
          scoreIn: true, onDouble: (p, on) => sent.add((p, on)));
      expect(find.text('Calls are closed — the first score is in.'),
          findsOneWidget);
      await t.tap(find.text('Double ×2'));
      await t.pump();
      expect(sent, isEmpty, reason: 'the engine refuses it too');
    });

    testWidgets('a rule that is off is not offered', (t) async {
      await _pumpCard(t, _summary(
          playerDouble: false, counter: false,
          current: _hole(locked: true, maxBet: 20,
              lines: [_line(2, 'Dave', 10)])));
      expect(find.textContaining('counter-doubles'), findsNothing);
      // The row is still drawn — the bet is real; only the call is gone.
      expect(find.text('Dave'), findsOneWidget);
    });
  });

  group('the tray', () {
    BankerSummary _settled({int? lowNet = 4, int? nextBankerId = 1}) =>
        _summary(
          nextBankerId: nextBankerId,
          current: _hole(
            locked: true, countered: true, resolved: true, maxBet: 20,
            bankerGross: 4, lowNet: lowNet,
            holeMoney: {'1': 90, '2': -40, '3': -40, '4': -10},
            lines: [
              _line(2, 'Dave', 10, mult: 2, countered: true, stake: 40,
                  outcome: 'lost', amount: 40, net: 5, bankerNet: 4,
                  chain: '\$10 bet · ×2 his double · ×2 counter = \$40'),
              _line(3, 'Sam', 20, countered: true, stake: 40,
                  outcome: 'lost', amount: 40, net: 5, bankerNet: 4,
                  chain: '\$20 bet · ×2 counter = \$40'),
              _line(4, 'Lee', 5, countered: true, stake: 10,
                  outcome: 'lost', amount: 10, net: 5, bankerNet: 4,
                  chain: '\$5 bet · ×2 counter = \$10'),
            ],
          ),
        );

    testWidgets('it names the hole and the bank', (t) async {
      await _pumpTray(t, _settled());
      expect(find.text('HOLE 7 · PAUL BANKS'), findsOneWidget);
      expect(find.text('BANKER 4'), findsOneWidget);
      expect(find.text('Paul on the hole'), findsOneWidget);
    });

    testWidgets('each bet carries the SERVER\'s chain', (t) async {
      // Re-composing it here would be a second opinion about arithmetic
      // somebody is going to be paid on.
      await _pumpTray(t, _settled());
      expect(find.text('\$10 bet · ×2 his double · ×2 counter = \$40'),
          findsOneWidget);
      expect(find.text('net 5 v 4 · lost'), findsNWidgets(3));
      // Twice in the bets block and twice again in the standing below it —
      // the same two golfers, which is the tray saying one thing in two
      // places on purpose.
      expect(find.text('−\$40'), findsNWidgets(4));
    });

    testWidgets('a tie is no action, whatever the bet reached', (t) async {
      await _pumpTray(t, _summary(nextBankerId: 1, current: _hole(
          resolved: true, bankerGross: 4, lowNet: 4,
          lines: [
            _line(2, 'Dave', 20, mult: 2, stake: 40, outcome: 'tied',
                net: 4, bankerNet: 4,
                chain: '\$20 bet · ×2 his double · void'),
          ])));
      expect(find.text('net 4 v 4 · tied, no action'), findsOneWidget);
      expect(find.text('\$0'), findsWidgets);
      expect(find.textContaining('void'), findsOneWidget);
    });

    testWidgets('an outright low net says who banks next', (t) async {
      await _pumpTray(t, _settled(nextBankerId: 3));
      expect(find.textContaining('Low net 4:'), findsOneWidget);
      expect(find.text('banks 8'), findsOneWidget);
    });

    testWidgets('…and says again when it does not change hands', (t) async {
      await _pumpTray(t, _settled(nextBankerId: 1));
      expect(find.text('banks again'), findsOneWidget);
      expect(find.text('Hole 8 · Paul banks ›'), findsOneWidget);
    });

    testWidgets('a tie for the bank asks, and the button waits', (t) async {
      final picked = <(int, String)>[];
      await _pumpTray(t,
          _summary(
            awaitingTie: 7,
            tieCandidates: const [
              {'player_id': 1, 'short_name': 'Paul'},
              {'player_id': 3, 'short_name': 'Sam'},
            ],
            current: _hole(resolved: true, bankerGross: 4, lowNet: 4,
                lines: [_line(2, 'Dave', 10, outcome: 'lost', amount: 10,
                    net: 5, bankerNet: 4)]),
          ),
          onNext: null, onPick: (i, r) => picked.add((i, r)));
      expect(find.text('Tied low on net 4 · who holed out first?'),
          findsOneWidget);
      expect(find.text('Draw'), findsOneWidget);
      expect(find.text('Confirm the banker'), findsOneWidget);

      // Two widgets read `Sam` — the pill and his standing row — so the
      // tap has to name the pill.
      await t.tap(find.descendant(
          of: find.byType(InkWell), matching: find.text('Sam')).first);
      await t.pump();
      expect(picked, [(3, 'holed-out-first')]);
    });

    testWidgets('Draw picks one of the tied, and says it was drawn',
        (t) async {
      final picked = <(int, String)>[];
      await _pumpTray(t,
          _summary(
            awaitingTie: 7,
            tieCandidates: const [
              {'player_id': 1, 'short_name': 'Paul'},
              {'player_id': 3, 'short_name': 'Sam'},
            ],
            current: _hole(resolved: true, bankerGross: 4, lowNet: 4,
                lines: [_line(2, 'Dave', 10, outcome: 'lost', amount: 10)]),
          ),
          onNext: null, onPick: (i, r) => picked.add((i, r)));
      await t.tap(find.text('Draw'));
      await t.pump();
      expect(picked.single.$2, 'drawn',
          reason: 'the reason travels to the receipt');
      expect([1, 3], contains(picked.single.$1));
    });

    testWidgets('the standing is this hole against the round', (t) async {
      await _pumpTray(t, _settled());
      expect(find.text('EACH · NOW'), findsOneWidget);
      expect(find.text('HOLE'), findsOneWidget);
      expect(find.text('ROUND'), findsOneWidget);
      expect(find.text('+\$90'), findsOneWidget,
          reason: 'the banker only appears in the standing');
      // Lee: once on his bet line, once on his standing row.
      expect(find.text('−\$10'), findsNWidgets(2));
    });

    testWidgets('and reads FINAL on the last hole', (t) async {
      await _pumpTray(t, _settled(), roundOver: true, nextHole: null);
      expect(find.text('ROUND OVER'), findsOneWidget);
      expect(find.text('FINAL, EACH'), findsOneWidget);
      expect(find.text('Finish round ›'), findsOneWidget);
    });

    testWidgets('it holds its figures while the result is on its way',
        (t) async {
      await t.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: BankerHoleTray(
            summary: _settled(), roster: _roster,
            onEdit: () {}, onPickTie: (_, __) {}, gettingResult: true,
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Getting result…'), findsOneWidget);
      expect(find.textContaining('= \$40'), findsNothing);
    });

    testWidgets('nothing overflows at 320pt', (t) async {
      await _pumpTray(t, _settled(), size: const Size(320, 900));
      expect(t.takeException(), isNull);
    });
  });

  group('the screen keeps what the two-screen loop had', () {
    final src =
        File('lib/screens/score_entry_screen.dart').readAsStringSync();

    test('Banker enters on the shared keypad', () {
      // **Bounded by `_keypadRound`'s own body.** `primary ==
      // GameIds.banker` appears elsewhere in this file (the handicap
      // params), so an unbounded search passes with the gate removed.
      final i = src.indexOf('bool _keypadRound(RoundProvider rp) {');
      expect(i, greaterThan(0));
      expect(src.substring(i, src.indexOf('\n  }', i)),
          contains('primary == GameIds.banker'));
    });

    test('its hole raises a tray, so the hole posts itself', () {
      // **The loose test, not the resolved one.** A hole resolves only once
      // its scores are posted, so asking `_bankerTrayState` here would have
      // held the two halves shut against each other.
      final i = src.indexOf('bool _raisesTray(RoundProvider rp) =>');
      expect(i, greaterThan(0));
      final body = src.substring(i, src.indexOf(';', i));
      expect(body, contains('_bankerHoleOpen(rp)'));
      expect(body, isNot(contains('_bankerTrayState')));
    });

    test('the pager hides under the tray', () {
      final i = src.indexOf('if (!sixTray');
      expect(i, greaterThan(0));
      expect(src.substring(i, src.indexOf(')', i)), contains('!bkTray'));
    });

    test('it no longer pops back to the banker screen', () {
      // The two-screen loop is what this packet folds into one.
      final i = src.indexOf('if (_bankerRound(rp)) {');
      expect(i, greaterThan(0));
      expect(src.substring(i, i + 1200), isNot(contains('Navigator.of(ctx).pop()')));
    });

    test('the banker wears the gold role tag on his row', () {
      // The same gold as the Hot Seat anchor: a ROLE, never a result, so it
      // must not borrow the win green. The two never meet — a round plays
      // one of those games.
      expect(src, contains("isBank ? 'BANK' : 'HOT SEAT'"));
      expect(src, contains('bankerCardId:'));
    });

    test('a changed score clears a tie pick', () {
      // The pick answers a result that no longer stands.
      expect(src, contains('_bankerTiePick = null'));
    });
  });
}
