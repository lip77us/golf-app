import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/receipt_send.dart';
import 'package:golf_mobile/widgets/receipt_ticket.dart';

/// Play for fun — the receipt becomes RESULTS.
///
/// Nothing in such a round was played for money, so every slot that names
/// money has to go: the corner word, the settle block, the button's noun and
/// the figure on each chip. These pin that the client renders what the
/// server sent and invents none of it.

ReceiptTicket _forFun({
  List<int> textIds = const [],
  List<ReceiptChip>? nets,
}) =>
    ReceiptTicket(
      code: '9MW4ABCD',
      url: 'https://halved.golf/r/9MW4ABCD/',
      title: 'Nassau + Skins',
      sub: 'Tilden Park GC · Nov 4 · for fun',
      nets: nets ??
          const [
            ReceiptChip(golferId: 1, name: 'Dave', net: 0, result: '1 UP',
                tone: 'up', caption: '88 · net 76 · 4 skins'),
            ReceiptChip(golferId: 2, name: 'Paul', net: 0, result: '1 UP',
                tone: 'up', caption: '84 · net 76 · 2 skins'),
            ReceiptChip(golferId: 3, name: 'Sam', net: 0, result: '1 DN',
                tone: 'dn', caption: '90 · net 75 · 1 skin'),
            ReceiptChip(golferId: 4, name: 'Mike', net: 0, result: '1 DN',
                tone: 'dn', caption: '86 · net 76 · 1 skin'),
          ],
      pays: const [],
      paysLabel: 'Simplest way to settle',
      games: const [
        ReceiptSection(label: 'The games', rows: [
          ['Nassau', 'Lipkin/Kim 1 UP'],
          ['Skins', 'Kim 4 · Lipkin 2'],
        ]),
      ],
      note: '',
      forFun: true,
      pushIds: const [],
      textIds: textIds,
      noneIds: const [],
    );

ReceiptTicket _parse(Map<String, dynamic> payload) =>
    ReceiptTicket.fromJson(<String, dynamic>{
      'code': 'ABC12345',
      'url': 'https://halved.golf/r/ABC12345/',
      'payload': <String, dynamic>{
        'code': 'ABC12345',
        'title': 'Stroke Play',
        'sub': 'Tilden Park GC · Nov 7 · for fun',
        'nets': <dynamic>[],
        'pays': <dynamic>[],
        'games': <dynamic>[],
        ...payload,
      },
    });

Future<void> _pump(WidgetTester t, ReceiptTicket r) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: ReceiptTicketCard(receipt: r)),
    ),
  ));
}

void main() {
  group('the wire', () {
    test('a string net is a RESULT, not a figure', () {
      // §3 types the field `Cents | string`. Read as a number it would
      // silently become 0 and every chip would say "$0".
      final t = _parse({
        'forFun': true,
        'nets': [
          {'golferId': 1, 'name': 'Ann', 'net': '1st', 'tone': 'up',
           'caption': '70 gross'},
        ],
      });
      expect(t.forFun, isTrue);
      expect(t.nets.single.isResult, isTrue);
      expect(t.nets.single.result, '1st');
      expect(t.nets.single.tone, 'up');
      expect(t.nets.single.net, 0);
    });

    test('a money chip is unchanged and carries no result', () {
      final t = _parse({
        'nets': [
          {'golferId': 1, 'name': 'Ann', 'net': 2600, 'caption': 'x'},
        ],
      });
      expect(t.forFun, isFalse);
      expect(t.nets.single.isResult, isFalse);
      expect(t.nets.single.net, 2600);
      expect(t.nets.single.tone, isNull);
    });

    test('an older server sending no flag is a money receipt', () {
      expect(_parse({}).forFun, isFalse);
    });
  });

  group('the ticket', () {
    testWidgets('the corner says RESULTS', (t) async {
      await _pump(t, _forFun());
      expect(find.text('RESULTS'), findsOneWidget);
      expect(find.text('RECEIPT'), findsNothing);
    });

    testWidgets('a money receipt still says RECEIPT', (t) async {
      const money = ReceiptTicket(
        code: 'A', url: 'u', title: 'Skins', sub: 'x',
        nets: [ReceiptChip(name: 'Ann', net: 100, caption: '')],
        pays: [ReceiptTransfer(from: 'Bea', to: 'Ann',
            amountCents: 100)],
        paysLabel: 'Simplest way to settle', games: [], note: '',
        pushIds: [], textIds: [], noneIds: []);
      await _pump(t, money);
      expect(find.text('RECEIPT'), findsOneWidget);
      expect(find.text('SIMPLEST WAY TO SETTLE'), findsOneWidget);
    });

    testWidgets('there is no settle block to head', (t) async {
      await _pump(t, _forFun());
      // NOTE the case: `_SectionLabel` uppercases, so asserting the
      // lowercase form would pass whatever the widget drew.
      expect(find.text('SIMPLEST WAY TO SETTLE'), findsNothing);
    });

    testWidgets('each chip draws its result, and no money', (t) async {
      await _pump(t, _forFun());
      expect(find.text('1 UP'), findsNWidgets(2));
      expect(find.text('1 DN'), findsNWidgets(2));
      expect(find.textContaining('\$'), findsNothing);
    });

    testWidgets('the caption carries the side games', (t) async {
      await _pump(t, _forFun());
      expect(find.text('88 · net 76 · 4 skins'), findsOneWidget);
    });
  });

  group('the button', () {
    test('it offers RESULTS, not a receipt', () {
      final r = _forFun(textIds: const [3, 4]);
      // The names come from the chips, which carry the golfer ids.
      expect(textReceiptLabel(r), 'Text results to Sam and Mike');
    });

    test('a staked round still says receipt', () {
      const r = ReceiptTicket(
        code: 'A', url: 'u', title: 'Skins', sub: 'x',
        nets: [ReceiptChip(golferId: 3, name: 'Sam', net: -100,
            caption: '')],
        pays: [], paysLabel: 'Simplest way to settle',
        games: [], note: '',
        pushIds: [], textIds: [3], noneIds: []);
      expect(textReceiptLabel(r), 'Text receipt to Sam');
    });

    test('nobody to text means no button either way', () {
      expect(textReceiptLabel(_forFun()), isNull);
    });
  });
}
