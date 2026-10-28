import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/theme/halved_brand.dart';
import 'package:golf_mobile/utils/skins_board_model.dart';
import 'package:golf_mobile/widgets/skins_board.dart';

SkinsSummary _skins({
  required List<Map<String, dynamic>> players,
  required List<Map<String, dynamic>> holes,
  bool carryover = true,
  double betUnit = 1.0,
  String rules = '',
  String note = '',
  String minimum = 'none',
  bool steal = false,
  String payoutStyle = 'per_point',
}) =>
    SkinsSummary.fromJson({
      'status': 'in_progress',
      'handicap': {'mode': 'net', 'net_percent': 100},
      'carryover': carryover,
      'allow_junk': true,
      'skin_rules': rules,
      // The CONSEQUENCE is the server's sentence now, not derived here.
      'skin_rules_note': note,
      'skin_minimum': minimum,
      'birdie_steal': steal,
      'payout_style': payoutStyle,
      'players': players,
      'holes': holes,
      'money': {'bet_unit': betUnit, 'pool': 4.0, 'total_skins': 0},
    });

Map<String, dynamic> _p(int id, String name,
        {int won = 0, int junk = 0, double net = 0}) =>
    {'player_id': id, 'name': name, 'short_name': name,
     'skins_won': won, 'junk_skins': junk, 'total_skins': won + junk,
     'payout': net, 'net': net};

Map<String, dynamic> _won(int h, int w, {int value = 1}) =>
    {'hole': h, 'par': 4, 'winner_id': w, 'skins_value': value,
     'is_carry': false};
Map<String, dynamic> _carried(int h, int pot) =>
    {'hole': h, 'par': 4, 'winner_id': null, 'skins_value': pot,
     'is_carry': true};
Map<String, dynamic> _unplayed(int h) =>
    {'hole': h, 'par': 3, 'winner_id': null, 'skins_value': 0,
     'is_carry': false};

Future<void> _pump(WidgetTester t, SkinsBoardData d) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: SkinsBoard(data: d)),
        ),
      ),
    );

void main() {
  group('up next', () {
    testWidgets('names the carried holes and what is riding', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave'), _p(3, 'Sam'), _p(4, 'Mike')],
        holes: [
          for (var h = 1; h <= 10; h++) _won(h, 1),
          _carried(11, 1), _carried(12, 2),
          for (var h = 13; h <= 18; h++) _unplayed(h),
        ],
      )));
      expect(find.text('Up next'), findsOneWidget);
      expect(find.text('11 and 12 carried in'), findsOneWidget);
      expect(find.text('3'), findsWidgets);          // 3 riding
      // 3 skins x $1 x (4 golfers - 1).
      expect(find.text('skins · \$9'), findsOneWidget);
    });

    testWidgets('one carried hole reads as a hole, not a list', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [_carried(1, 1), for (var h = 2; h <= 18; h++) _unplayed(h)],
      )));
      expect(find.text('Hole 1 carried in'), findsOneWidget);
    });

    testWidgets('no carry says so rather than nothing', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul'), _p(2, 'Dave')],
        holes: [_won(1, 1), for (var h = 2; h <= 18; h++) _unplayed(h)],
      )));
      expect(find.text('No carry'), findsOneWidget);
      expect(find.text('skin · \$1'), findsOneWidget);   // singular
    });

    testWidgets('a finished round reports the total, not a 19th hole',
        (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 18, net: 18)],
        holes: [for (var h = 1; h <= 18; h++) _won(h, 1)],
      )));
      expect(find.text('Round over'), findsOneWidget);
      expect(find.text('Every skin was won'), findsOneWidget);
      expect(find.text('skins won'), findsOneWidget);
      expect(find.text('Up next'), findsNothing);
    });

    testWidgets('skins left on the last hole are called unclaimed',
        (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 16, net: 16)],
        holes: [
          for (var h = 1; h <= 16; h++) _won(h, 1),
          _carried(17, 1), _carried(18, 2),
        ],
      )));
      expect(find.text('2 skins unclaimed on the last holes'), findsOneWidget);
    });
  });

  group('the ledger', () {
    testWidgets('shows the SERVER net, not the reference formula', (t) async {
      // Two golfers, $1 a skin, Paul 3 of 3: the design's formula says +$3.
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 3, net: 1.5), _p(2, 'Dave', net: -1.5)],
        holes: [for (var h = 1; h <= 3; h++) _won(h, 1)],
      )));
      expect(find.text('+\$1.50'), findsOneWidget);
      expect(find.text('−\$1.50'), findsOneWidget);   // U+2212, not a hyphen
      expect(find.text('+\$3'), findsNothing);
    });

    testWidgets('a golfer with nothing shows 0, not an empty cell',
        (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 1, net: 1), _p(2, 'Dave', net: -1)],
        holes: [_won(1, 1), for (var h = 2; h <= 18; h++) _unplayed(h)],
      )));
      expect(find.text('0'), findsOneWidget);
      expect(find.text('\$0'), findsNothing);
    });

    testWidgets('junk ticks are drawn, because junk is paid on', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 2, junk: 1, net: 3)],
        holes: [for (var h = 1; h <= 2; h++) _won(h, 1)],
      )));
      // 2 filled + 1 outlined = the 3 he is paid on.
      final ticks = t.widgetList<Container>(find.byType(Container))
          .where((c) => c.constraints?.maxHeight == 18 ||
                        (c.decoration is BoxDecoration &&
                         (c.decoration as BoxDecoration).borderRadius ==
                             BorderRadius.circular(3)))
          .length;
      expect(ticks, greaterThanOrEqualTo(3));
    });

    testWidgets('the footer counts skins against holes PLAYED', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 10, net: 14), _p(2, 'Dave', net: -2),
                  _p(3, 'Sam', net: -6), _p(4, 'Mike', net: -6)],
        holes: [
          for (var h = 1; h <= 10; h++) _won(h, 1),
          _carried(11, 1), _carried(12, 2),
          for (var h = 13; h <= 18; h++) _unplayed(h),
        ],
      )));
      // The footer is Text.rich, so the plain finder has to be told to look
      // inside the spans.
      // Text.rich: the finder matches the WHOLE widget's text, not a span.
      expect(find.text('Won 10 of 12', findRichText: true), findsOneWidget);
      expect(find.text('Left 6 holes', findRichText: true), findsOneWidget);
    });

    testWidgets('a finished round says Final on both lines', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul', won: 18, net: 18)],
        holes: [for (var h = 1; h <= 18; h++) _won(h, 1)],
      )));
      expect(find.text('Final, each'), findsOneWidget);
      expect(find.text('Final'), findsOneWidget);
    });
  });

  group('the holes grid', () {
    testWidgets('the rules sit under HOLES, as a footnote on the grid',
        (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        // The SLUGS as well as the phrase. This test used to name a minimum
        // in the phrase alone and still expect the minimum's consequence —
        // which passed only because that sentence was unconditional, so the
        // test agreed with the bug.
        rules: 'gross par or better to win · gross birdies steal',
        minimum: 'gross_par', steal: true,
        note: 'A hole where nobody qualifies goes unwon.',
        players: [_p(1, 'Paul')],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      )));
      expect(find.text('HOLES'), findsOneWidget);
      expect(find.textContaining('Gross par or better to win'), findsOneWidget);
      expect(find.text('A hole where nobody qualifies goes unwon.'),
             findsOneWidget);
    });

    testWidgets('plain skins draws no rules line at all', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul')],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      )));
      expect(find.text('A hole where nobody qualifies goes unwon.'),
             findsNothing);
    });

    testWidgets('the basis label says whether it carries', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: [_p(1, 'Paul')],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      )));
      expect(find.text('NET · CARRIES ON'), findsOneWidget);
    });

    testWidgets('carry off drops the carries-on half', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        carryover: false,
        players: [_p(1, 'Paul')],
        holes: [for (var h = 1; h <= 18; h++) _unplayed(h)],
      )));
      expect(find.text('NET'), findsOneWidget);
    });
  });

  group('there is only one skins table', () {
    // The packet's first instruction: "Do not draw a second skins table
    // anywhere."  Checked at the source, because a second one looks fine
    // until the two disagree about money.
    test('both skins boards render SkinsBoard', () {
      final src = File('lib/screens/leaderboard_screen.dart').readAsStringSync();
      expect('SkinsBoard('.allMatches(src).length, greaterThanOrEqualTo(2),
          reason: 'the per-foursome card AND the pool must both use it');
    });
  });

  group('golfer colours', () {
    test('six, and they wrap rather than running out', () {
      expect(Halved.golferColours.length, 6);
      expect(Halved.golfer(0), Halved.golfer(6));
      expect(Halved.golfer(1), isNot(Halved.golfer(0)));
    });
  });

  group('the rules footnote', () {
    /// Reported from the board, 28 Oct 2026: *"The leaderboard says, a hole
    /// where no one qualifies goes unwon, when there is no qualification
    /// checked."*
    ///
    /// The block is gated on the rules PHRASE being non-empty, and a gross
    /// steal puts a phrase there — so a round playing steal alone drew the
    /// minimum's consequence. The sentence was a `const`; `skinRuleNote`
    /// already decided it per rule and had no caller.
    final four = [_p(1, 'Paul'), _p(2, 'Dave'), _p(3, 'Sam'), _p(4, 'Mike')];
    final holes = [
      for (var h = 1; h <= 4; h++) _won(h, 1),
      for (var h = 5; h <= 18; h++) _unplayed(h),
    ];

    testWidgets('plain skins says nothing at all', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(
          _skins(players: four, holes: holes)));
      expect(find.textContaining('qualifies'), findsNothing);
      expect(find.textContaining('gross birdie'), findsNothing);
    });

    testWidgets('a steal alone never claims a hole can go unwon', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: four, holes: holes,
        rules: 'gross birdies steal', steal: true,
        note: 'A gross birdie beats a net birdie, not a net eagle.')));
      expect(find.text('Gross birdies steal'), findsOneWidget);
      expect(find.textContaining('qualifies'), findsNothing);
      // Design's wording, and the ENGINE's rule: a net eagle still wins.
      expect(find.text('A gross birdie beats a net birdie, not a net eagle.'),
          findsOneWidget);
    });

    testWidgets('a minimum does, because it can', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: four, holes: holes,
        rules: 'net par or better to win', minimum: 'net_par',
        note: 'A hole where nobody qualifies goes unwon.')));
      expect(find.text('Net par or better to win'), findsOneWidget);
      expect(find.text('A hole where nobody qualifies goes unwon.'),
          findsOneWidget);
    });

    testWidgets('both on: the minimum owns the consequence', (t) async {
      await _pump(t, SkinsBoardData.fromSkins(_skins(
        players: four, holes: holes,
        rules: 'net par or better to win · gross birdies steal',
        minimum: 'net_par', steal: true,
        // The server picks ONE sentence: the minimum outranks the steal,
        // because a natural clears any minimum and so can never be the
        // reason a hole goes unwon.
        note: 'A hole where nobody qualifies goes unwon.')));
      expect(find.text('Net par or better to win · Gross birdies steal'),
          findsOneWidget);
      expect(find.text('A hole where nobody qualifies goes unwon.'),
          findsOneWidget);
    });

    testWidgets('the sentence is not typed into the widget', (t) async {
      // It is chosen by `skinRuleNote`, so the board cannot drift from it.
      final src = File('lib/widgets/skins_board.dart').readAsStringSync();
      expect(src.contains("const Text('A hole where nobody"), isFalse);
      expect(src.contains('skinRuleNote('), isTrue);
      // And it is no longer derived either — the server writes it.
      expect(src.contains('goes unwon'), isFalse);
    });
  });
}
