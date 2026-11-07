import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/receipt_send.dart';
import 'package:golf_mobile/widgets/receipt_ticket.dart';

/// The settle-up receipt on the phone — `~/Downloads/design_handoff_settle_up`.
///
/// The payload here is the handoff's own casual example, so these pin the
/// SPEC rather than the implementation.

ReceiptTicket _ticket({
  List<int> textIds = const [],
  List<ReceiptChip>? nets,
  List<ReceiptTransfer>? pays,
  String note = '',
}) =>
    ReceiptTicket(
      code: '7KQ2ABCD',
      url: 'https://halved.golf/r/7KQ2ABCD/',
      title: 'Nassau + Skins',
      sub: 'Tilden Park GC · Nov 4 · \$10 a match',
      nets: nets ??
          const [
            ReceiptChip(golferId: 1, name: 'Paul', net: 2600,
                caption: '88 · net 76'),
            ReceiptChip(golferId: 2, name: 'Dave', net: 1000,
                caption: '84 · net 76'),
            ReceiptChip(golferId: 3, name: 'Sam', net: -1800,
                caption: '90 · net 75'),
            ReceiptChip(golferId: 4, name: 'Mike', net: -1800,
                caption: '86 · net 76'),
          ],
      pays: pays ??
          const [
            ReceiptTransfer(from: 'Sam', to: 'Paul', amountCents: 1800),
            ReceiptTransfer(from: 'Mike', to: 'Dave', amountCents: 1000),
            ReceiptTransfer(from: 'Mike', to: 'Paul', amountCents: 800),
          ],
      paysLabel: 'Simplest way to settle',
      games: const [
        ReceiptSection(label: 'The games', rows: [
          ['Nassau', 'Lipkin/Kim 1 UP'],
          ['Skins', 'Lipkin 4 · Kim 2'],
        ]),
      ],
      note: note,
      pushIds: const [],
      textIds: textIds,
      noneIds: const [],
    );

void main() {
  group('§2.4 money', () {
    test('the ticket signs a gain and never a level figure', () {
      // "+$26, −$18 … $0 when level" — level is a direction, not a gain.
      expect(receiptMoney(2600, signed: true), '+\$26');
      expect(receiptMoney(-1800, signed: true), '−\$18');
      expect(receiptMoney(0, signed: true), '\$0');
    });

    test('a transfer is unsigned — the arrow already says which way', () {
      expect(receiptMoney(1800), '\$18');
    });

    test('cents show only when they are non-zero', () {
      expect(receiptMoney(4687, signed: true), '+\$46.87');
      expect(receiptMoney(4600, signed: true), '+\$46');
      expect(receiptMoney(-5, signed: true), '−\$0.05');
    });

    test('a true minus sign, not a hyphen', () {
      // At 15px beside a '+' the hyphen is visibly the wrong length.
      expect(receiptMoney(-100)[0], '−');
      expect(receiptMoney(-100).contains('-'), isFalse);
    });
  });

  group('§3 parsing', () {
    test('a string amount survives as a string', () {
      // "2 × $80": one prize split several ways. A total would lose the
      // per-man figure the golfers actually collect.
      final t = ReceiptTransfer.fromJson(
          {'from': 'TD', 'to': 'Cho / Lopez', 'amount': '2 × \$80'});
      expect(t.amountText, '2 × \$80');
      expect(t.amountCents, isNull);
    });

    test('a missing paysLabel falls back to the §3 default', () {
      final t = ReceiptTicket.fromJson({
        'code': 'X', 'url': 'u',
        'payload': {'title': 'T', 'nets': [], 'pays': []},
      });
      expect(t.paysLabel, 'Simplest way to settle');
    });

    test('recipients parse into three lists', () {
      final t = ReceiptTicket.fromJson({
        'code': 'X', 'url': 'u',
        'payload': {
          'recipients': {'push': [1, 2], 'text': [3], 'none': [4]},
        },
      });
      expect(t.pushIds, [1, 2]);
      expect(t.textIds, [3]);
      expect(t.noneIds, [4]);
    });
  });

  group('§1 the text button', () {
    test('no label when nobody needs a text', () {
      // §1 hides the button rather than showing a dead one: on a round where
      // every golfer is on Halved the receipts have already gone.
      expect(textReceiptLabel(_ticket()), isNull);
    });

    test('it names one golfer, and two', () {
      expect(textReceiptLabel(_ticket(textIds: [3])), 'Text receipt to Sam');
      expect(textReceiptLabel(_ticket(textIds: [3, 4])),
          'Text receipt to Sam and Mike');
    });

    test('past two it counts instead of listing', () {
      expect(textReceiptLabel(_ticket(textIds: [1, 2, 3])),
          'Text receipt to 3 golfers');
    });

    test('the names come from the ticket, not a roster', () {
      // A golfer shown as "Sam" on the ticket and "Sam Reid" on the button
      // reads as two people.
      expect(textRecipientNames(_ticket(textIds: [3, 1])), ['Sam', 'Paul']);
    });

    test('a phone never comes from the payload', () {
      // The receipt is served publicly at /r/<code>; a phone number in it
      // would be a phone number on the internet.
      expect(textRecipientPhones(_ticket(textIds: [3]), null), isEmpty);
    });
  });

  group('the ticket draws', () {
    testWidgets('chips, transfers and the games rows', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReceiptTicketCard(receipt: _ticket()),
          ),
        ),
      ));
      expect(find.text('Nassau + Skins'), findsOneWidget);
      expect(find.text('HALVED'), findsOneWidget);
      expect(find.text('RECEIPT'), findsOneWidget);
      expect(find.text('+\$26'), findsOneWidget);
      expect(find.text('−\$18'), findsNWidgets(2));
      expect(find.text('SIMPLEST WAY TO SETTLE'), findsOneWidget);
      expect(find.text('\$18'), findsOneWidget);
      expect(find.text('THE GAMES'), findsOneWidget);
      expect(find.text('Lipkin/Kim 1 UP'), findsOneWidget);
    });

    testWidgets('it fits a phone without overflowing', (t) async {
      await t.binding.setSurfaceSize(const Size(375, 1200));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ReceiptTicketCard(
                receipt: _ticket(nets: const [
                  ReceiptChip(golferId: 1, name: 'Bartholomew Fotheringay',
                      net: 123456, caption: 'Championship 1st · 8 men'),
                  ReceiptChip(golferId: 2, name: 'Mike', net: -123456,
                      caption: ''),
                ]),
              ),
            ),
          ),
        ),
      ));
      expect(t.takeException(), isNull);
    });
  });

  group('every screen that closes a round shows Round over', () {
    // The receipt reachable from one screen and not the others is this
    // codebase's most repeated failure: the casual receipt no round could
    // open, the setup-edit button gated on the rule it replaced, the force
    // itself, the day bet's picker, Hot Seat on the Road Trip sheet.
    //
    // The nine dedicated play screens call `completeRound` DIRECTLY and are
    // right to — they are single-foursome casual games with no force to
    // offer — but that makes them exactly the rounds that produce a receipt.
    test('no screen completes a round without it', () {
      final offenders = <String>[];
      for (final f in Directory('lib/screens').listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        if (!src.contains('completeRound(')) continue;
        final covered = src.contains('showRoundOverIfAny') ||
            src.contains('completeRoundOrOfferForce');
        if (!covered) offenders.add(f.uri.pathSegments.last);
      }
      expect(offenders, isEmpty,
          reason: 'these close a round and never show the receipt');
    });

    test('the opener lives in one place', () {
      // Nine copies of "push RoundOverScreen" is how they come to disagree
      // about when it appears.
      var pushes = 0;
      for (final f in Directory('lib').listSync(recursive: true)
          .whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.readAsStringSync().contains('RoundOverScreen(')) pushes++;
      }
      expect(pushes, 2,
          reason: 'only round_complete.dart pushes it, and its own file '
              'declares it');
    });
  });
}
