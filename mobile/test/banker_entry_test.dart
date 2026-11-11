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

  group('nothing shows a number nobody chose', () {
    // Paul, 10 Nov 2026: "no way to make bets register without hitting plus
    // and then back to -." The row drew `$5` beside a golfer who had not
    // bet, with the minus dead at the floor, under a button reading `2 bets
    // to go`.
    testWidgets('an unplaced bet is a button, not a figure', (t) async {
      await _pumpCard(t, _summary(current: _hole(maxBet: 20, lines: [
        _line(2, 'Dave', 10),
      ])));
      // Sam and Lee have not bet: two offers, and no bare `$5` anywhere.
      expect(find.text('Bet \$5'), findsNWidgets(2));
      expect(find.text('\$5'), findsNothing);
    });

    testWidgets('one tap places the floor', (t) async {
      final sent = <(int, double)>[];
      await _pumpCard(t, _summary(current: _hole(maxBet: 20, lines: [
        _line(2, 'Dave', 10),
      ])), onBet: (p, a) => sent.add((p, a)));
      await t.tap(find.text('Bet \$5').first);
      await t.pump();
      expect(sent, [(3, 5.0)], reason: 'Sam, at the floor, in one tap');
    });

    testWidgets('the plus beside it places a step above', (t) async {
      final sent = <(int, double)>[];
      await _pumpCard(t, _summary(current: _hole(maxBet: 20)),
          onBet: (p, a) => sent.add((p, a)));
      await t.tap(find.byIcon(Icons.add).first);
      await t.pump();
      expect(sent, [(2, 10.0)]);
    });

    testWidgets('a placed bet is the plain figure', (t) async {
      await _pumpCard(t, _summary(current: _hole(maxBet: 20, lines: [
        _line(2, 'Dave', 5), _line(3, 'Sam', 5), _line(4, 'Lee', 5),
      ])));
      expect(find.textContaining('Bet '), findsNothing);
      expect(find.text('\$5'), findsNWidgets(3));
    });

    testWidgets('the steppers do not move when a bet lands', (t) async {
      // The amount slot is one width in both states.
      await _pumpCard(t, _summary(current: _hole(maxBet: 20)));
      final before = t.getTopLeft(find.byIcon(Icons.remove).first).dx;
      await _pumpCard(t, _summary(current: _hole(maxBet: 20, lines: [
        _line(2, 'Dave', 5),
      ])));
      expect(t.getTopLeft(find.byIcon(Icons.remove).first).dx, before);
    });

    Iterable<Ink> litChips(WidgetTester t) => t
        .widgetList<Ink>(find.byType(Ink))
        .where((i) => (i.decoration as BoxDecoration?)?.color == kBankGold);

    testWidgets('no max chip is lit until the banker names one', (t) async {
      // A hole opens with no maximum. The round's ceiling used to light up
      // as though it were the hole's.
      await _pumpCard(t, _summary(current: _hole()));
      expect(litChips(t), isEmpty);
      await _pumpCard(t, _summary(current: _hole(maxBet: 20)));
      expect(litChips(t), hasLength(1));
    });

    testWidgets('and no bet can be placed before it', (t) async {
      // The server refuses one; a control that answers with an error is
      // worse than one that waits.
      final sent = <(int, double)>[];
      await _pumpCard(t, _summary(current: _hole()),
          onBet: (p, a) => sent.add((p, a)));
      await t.tap(find.text('Bet \$5').first, warnIfMissed: false);
      await t.tap(find.byIcon(Icons.add).first, warnIfMissed: false);
      await t.pump();
      expect(sent, isEmpty);
      expect(find.text('Set the max first'), findsOneWidget);
      expect(find.textContaining('to go'), findsNothing);
    });

    testWidgets('the sub line takes the room the title leaves', (t) async {
      // Two loose Flexibles split the row evenly, so the sub was ellipsised
      // beside empty space. Measured wide, where half the row and the rest
      // of the row are far apart.
      await _pumpCard(t, _summary(current: _hole(maxBet: 20)),
          size: const Size(700, 900));
      final sub = t.getSize(find.text('sets the max, then the three bet'));
      expect(sub.width, greaterThan(360),
          reason: 'half the row is about 310');
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
    });

    testWidgets('no bare score sits among the money', (t) async {
      // `Paul on the hole  5` in gold under three dollar figures, and
      // `BANKER 5` in the label above them, both read as five dollars. The
      // line is gone; the label says what its number IS, in the word the
      // rows under it use (`net 5 v 4`).
      await _pumpTray(t, _settled());
      expect(find.textContaining('on the hole'), findsNothing);
      expect(find.text('BANKER 4'), findsNothing);
      expect(find.text('BANKER NET 4'), findsOneWidget);
      expect(find.textContaining('net 5 v 4'), findsWidgets);
    });

    test('a banker holding different nets shows each, in row order', () {
      // Strokes are settled inside each one-on-one, so he can be net 5
      // against one opponent and net 4 against another. The figures follow
      // the rows beneath the label, so the first is his net against the
      // first golfer listed.
      final h = _summary(
        current: _hole(
          locked: true, resolved: true, bankerGross: 5,
          lines: [
            _line(2, 'Dave', 10, net: 5, bankerNet: 5),
            _line(3, 'Sam', 10, net: 5, bankerNet: 4),
            _line(4, 'Lee', 10, net: 6, bankerNet: 5),
          ],
        ),
      ).current!;
      expect(bankerScoreLabel(h), 'banker net 5/4/5');
    });

    test('the order is the ROWS\', not sorted', () {
      // 4/5/5 and 5/4/5 are different statements about who gave whom a
      // stroke; a sorted or de-duplicated list would lose which is which.
      final h = _summary(
        current: _hole(
          locked: true, resolved: true, bankerGross: 5,
          lines: [
            _line(2, 'Dave', 10, net: 5, bankerNet: 4),
            _line(3, 'Sam', 10, net: 5, bankerNet: 5),
            _line(4, 'Lee', 10, net: 6, bankerNet: 5),
          ],
        ),
      ).current!;
      expect(bankerScoreLabel(h), 'banker net 4/5/5');
    });

    test('the same net in every match is one number', () {
      final h = _summary(
        current: _hole(
          locked: true, resolved: true, bankerGross: 5,
          lines: [
            _line(2, 'Dave', 10, net: 5, bankerNet: 5),
            _line(3, 'Sam', 10, net: 5, bankerNet: 5),
            _line(4, 'Lee', 10, net: 6, bankerNet: 5),
          ],
        ),
      ).current!;
      expect(bankerScoreLabel(h), 'banker net 5');
    });

    test('his gross is the fallback only when no row has a net', () {
      final h = _summary(
        current: _hole(locked: true, bankerGross: 5,
            lines: [_line(2, 'Dave', 10)]),
      ).current!;
      expect(bankerScoreLabel(h), 'banker gross 5');
    });

    test('and with no score at all the label says nothing', () {
      final h = _summary(
        current: _hole(locked: true, lines: [_line(2, 'Dave', 10)]),
      ).current!;
      expect(bankerScoreLabel(h), isNull);
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
      // The SERVER's word. This asserted `holed-out-first`, which the tray
      // had made up and the server refuses — so the test agreed with the
      // bug. See `the tie reasons are the server's` below.
      expect(picked, [(3, kBankerTieHoledFirst)]);
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
  group('the bets come before the scores', () {
    // Paul, 10 Nov 2026: "The score entry screen appears before setting the
    // bets. Also, I don't want the scorecard showing underneath when we get
    // to the bet entry stage." The bets card sat UNDER the golfers, behind a
    // keypad that was up from the moment the hole opened.
    final src =
        File('lib/screens/score_entry_screen.dart').readAsStringSync();

    String body(String signature) {
      final at = src.indexOf(signature);
      expect(at, greaterThan(0), reason: signature);
      return src.substring(at, src.indexOf('\n  }\n', at));
    }

    test('betting is open until the bets are LOCKED', () {
      final b = body('bool _bankerBetsOpen(RoundProvider rp, '
          'Map<int, int> scores)');
      expect(b, contains('h.locked'));
      expect(b, contains('h.resolved'));
      expect(b, contains('h.hole != _selectedHole'),
          reason: 'only the hole being bought — an earlier hole reopened to '
              'fix a score has nothing to bet');
    });

    test('a score already on the hole ends it', () {
      // A round under way from a build that let scores in first must not be
      // left with a keypad that never comes.
      expect(body('bool _bankerBetsOpen(RoundProvider rp, '
          'Map<int, int> scores)'), contains('return scores.isEmpty;'));
    });

    test('and while it is open there is no keypad', () {
      expect(src, contains('final betting = _bankerBetsOpen(rp, scores);'));
      expect(src, contains(
          'var fbIdx = fbActive && !betting ? _hotSpotIdx(players, scores)'
          ' : -1;'));
      // The tap-a-row override must not put one back.
      expect(src, contains('if (fbActive && !betting && _editHotPid != null)'));
    });

    test('the line under the pager says what is being waited for', () {
      // `4 scores to go` over a screen with no way to enter one reads as a
      // fault.
      expect(body('Widget _missingScoresNote('),
          contains("'Lock the bets on hole \$_selectedHole to enter scores'"));
    });

    test('the bets card is ABOVE the golfers', () {
      // Handed to the hole card's slot…
      final at = src.indexOf('aboveRows: (_bankerRound(rp)');
      expect(at, greaterThan(0));
      // Bounded by the slot's own `: null,` — a window measured in
      // characters reports edits, not regressions.
      expect(src.substring(at, src.indexOf(': null,', at)),
          contains('BankerBetsCard('),
          reason: 'the slot is handed the bets card');
      expect('BankerBetsCard('.allMatches(src).length, 1,
          reason: 'and it is drawn nowhere else on this screen');
      // …which draws it before the first golfer's row.
      final slot = src.indexOf('if (aboveRows != null) aboveRows!,');
      final rows = src.indexOf('...players.asMap().entries.expand(', slot);
      expect(slot, greaterThan(0));
      expect(rows, greaterThan(slot));
    });

    test('nothing sits under the golfers at the betting stage', () {
      final at = src.indexOf('BankerEntryStrip(');
      expect(at, greaterThan(0));
      final gate = src.lastIndexOf('if (', at);
      expect(src.substring(gate, at), contains('!_bankerBetsOpen(rp, scores)'));
    });

    test('and no Banker scorecard is drawn on score entry at all', () {
      // There were two: the round's grid above the bets and a second inside
      // the strip. Both are the leaderboard's.
      expect(src.contains('rp.bankerSummary!.grid'), isFalse);
      final strip =
          File('lib/widgets/banker_entry_strip.dart').readAsStringSync();
      expect(strip.contains('HoleGridScorecard('), isFalse);
      expect(strip.contains('hole_grid_scorecard.dart'), isFalse);
    });

    test('the leaderboard still draws it', () {
      // The other half of a move: without this the round's hole-by-hole
      // card would exist on no screen at all.
      expect(File('lib/widgets/banker_board.dart').readAsStringSync(),
          contains('HoleGridScorecard('));
    });
  });
  group('one screen, however you arrive', () {
    // Paul, 10 Nov 2026: "you get to 2 different screens if you come from
    // the hub or just finish entering the score and going to the next hole."
    // The hub and setup still opened the old `/banker` board.
    String read(String f) => File(f).readAsStringSync();

    test('the hub opens score entry for a configured Banker round', () {
      final src = read('lib/screens/round_screen.dart');
      final at = src.indexOf("} else if (fsGames.contains('banker')) {");
      expect(at, greaterThan(0));
      final branch = src.substring(at, src.indexOf('} else if', at + 10));
      expect(branch, contains("route = '/score-entry';"));
    });

    test('and so does finishing setup', () {
      final src = read('lib/screens/banker_setup_screen.dart');
      expect(
          RegExp(r"pushReplacementNamed\('/score-entry',\s*"
                  r'arguments: widget\.foursomeId\)')
              .hasMatch(src),
          isTrue);
    });

    test('nothing in the app opens the old board', () {
      // The route stays registered in main.dart; no screen pushes it.
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') &&
              !f.path.endsWith('main.dart'))) {
        expect(RegExp(r"Named\(\s*'/banker'").hasMatch(f.readAsStringSync()),
            isFalse, reason: f.path);
        expect(f.readAsStringSync().contains("route = '/banker'"), isFalse,
            reason: f.path);
      }
    });

    final entry = read('lib/screens/score_entry_screen.dart');

    test('it lands on the hole the bank is on', () {
      // Not the first hole without scores: a scored hole is still in play
      // until the bank has passed, and the hole after it has no banker.
      final at = entry.indexOf('void _jumpToFirstUnplayed(RoundProvider rp)');
      expect(at, greaterThan(0));
      final body = entry.substring(at, entry.indexOf('\n  }\n', at));
      expect(
          RegExp(r'if \(_bankerRound\(rp\)\) \{\s*'
                  r'final hole = rp\.bankerSummary\?\.currentHole;\s*'
                  r'if \(hole != null\) \{\s*'
                  r'setState\(\(\) => _selectedHole = hole\);\s*'
                  r'return;')
              .hasMatch(body),
          isTrue);
      // BEFORE the walk for the first unscored hole.
      expect(body.indexOf('bankerSummary?.currentHole'),
          lessThan(body.indexOf('for (final h in order)')));
    });

    test('and waits for the summary that says which', () {
      expect(entry,
          contains('final waitForBanker = '
              '_bankerRound(rp) && rp.bankerSummary == null;'));
      final at = entry.indexOf('if (!_initialJumpDone &&');
      expect(entry.substring(at, entry.indexOf('{', at)),
          contains('!waitForBanker'));
    });
  });

  group('the Banker screen', () {
    test('its scorecard draws no strokes table', () {
      // Paul, 10 Nov 2026: "remove the strokes table from the first banker
      // screen." The dots are on the cells.
      final src = File('lib/screens/banker_screen.dart').readAsStringSync();
      expect('HoleGridScorecard('.allMatches(src).length, 1);
      final at = src.indexOf('HoleGridScorecard(');
      expect(RegExp(r'showStrokes:\s*false')
          .hasMatch(src.substring(at, src.indexOf(');', at))), isTrue);
    });
  });
  group('the tie reasons are the server\'s', () {
    // Paul, 10 Nov 2026: "I seem to have gotten stuck." Picking who holed
    // out first sent `holed-out-first`; `BankerAdvanceSerializer` is a
    // choice field and answered 400, so a tied bank could not be confirmed
    // and the round could not move on. The widget test above it asserted
    // what the tray SENT, which is how a made-up word passed.
    //
    // So this reads the serializer. The two halves are in different
    // languages and nothing else checks them against each other.
    // Read inside each test: an `expect` at group-declaration time is
    // outside any test and fails the whole file to load.
    Set<String> choices() {
      final src = File('../api/serializers.py').readAsStringSync();
      final at = src.indexOf('tie_reason = serializers.ChoiceField(');
      expect(at, greaterThan(0), reason: 'the field moved — find it again');
      final list = RegExp(r'choices=\[([^\]]*)\]')
          .firstMatch(src.substring(at))!
          .group(1)!;
      return RegExp(r"'([^']+)'").allMatches(list).map((m) => m.group(1)!)
          .toSet();
    }

    test('the server still accepts a closed list', () {
      expect(choices(), containsAll(['holed_first', 'drawn']));
    });

    test('everything the app can send is on it', () {
      expect(choices(), contains(kBankerTieHoledFirst));
      expect(choices(), contains(kBankerTieDrawn));
    });

    test('no screen spells a reason of its own', () {
      // Three places send one: the tray, the score screen's default, and
      // the Banker screen. A literal in any of them is how this happened.
      for (final f in [
        'lib/widgets/banker_entry.dart',
        'lib/screens/score_entry_screen.dart',
        'lib/screens/banker_screen.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src.contains("'holed-out-first'"), isFalse, reason: f);
        expect(RegExp(r"tieReason:[^,;]*'[a-z_-]+'").hasMatch(src), isFalse,
            reason: '$f passes a literal tie reason');
        expect(RegExp(r"onPick\([^)]*'[a-z_-]+'\)").hasMatch(src), isFalse,
            reason: '$f picks with a literal tie reason');
      }
    });
  });
}
