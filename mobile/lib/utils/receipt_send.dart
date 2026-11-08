import 'package:flutter/material.dart';
import 'package:halved_sms/halved_sms.dart';

import '../api/models.dart';

/// Texting a settled receipt — `~/Downloads/design_handoff_settle_up` §1.
///
/// **One text, from the scorer's own phone, through the system composer, with
/// every recipient prefilled.** That is §1's answer to the question that
/// stopped the personal receipt being built at all: Halved deliberately never
/// sends golfer-facing SMS from the server, so "send 14 receipts" would have
/// been app-initiated bulk SMS to people who never opted in. The scorer taps
/// Send himself, which is the same route the invite flow uses and for the
/// same TCPA and App Store reasons.
///
/// **The body is just the link.** It unfurls into the 1080x1350 card, so a
/// message text as well would be the same facts twice — once as words the
/// recipient has to read and once as a picture they can see.
///
/// **Only golfers who are NOT on Halved get a text.** The rest already have a
/// push, and §2.5's note names anyone with no mobile on file.

/// Phone numbers for the golfers the receipt says should get a text.
///
/// **Resolved from the round, never from the payload.** A receipt is served
/// publicly at `/r/<code>`, so a phone number in it would be a phone number
/// on the internet; the payload carries ids and the client looks them up in
/// data it already holds.
List<String> textRecipientPhones(ReceiptTicket receipt, Round? round) {
  if (round == null) return const [];
  final wanted = receipt.textIds.toSet();
  final out = <String>[];
  for (final fs in round.foursomes) {
    for (final m in fs.memberships) {
      if (!wanted.contains(m.player.id)) continue;
      final cleaned = m.player.phone.replaceAll(RegExp(r'[^0-9+]'), '');
      if (cleaned.isNotEmpty && !out.contains(cleaned)) out.add(cleaned);
    }
  }
  return out;
}

/// The names behind [ReceiptTicket.textIds], in the receipt's own order.
///
/// Taken from the chips rather than the roster so the button says exactly
/// what the ticket above it says — a golfer shown as "Sam" on the ticket and
/// "Sam Reid" on the button reads as two people.
List<String> textRecipientNames(ReceiptTicket receipt) {
  final byId = {for (final c in receipt.nets) c.golferId: c.name};
  return [
    for (final id in receipt.textIds)
      if ((byId[id] ?? '').isNotEmpty) byId[id]!,
  ];
}

/// "Text receipt to Sam", "…to Sam and Mike", "…to 4 golfers".
///
/// On a round played for fun it is "Text RESULTS to …": there is no receipt
/// to send, and the link those golfers open says RESULTS when they open it.
///
/// Null when nobody needs one, which is §1's rule for hiding the button
/// rather than showing a dead one.
String? textReceiptLabel(ReceiptTicket receipt) {
  final names = textRecipientNames(receipt);
  if (names.isEmpty) return null;
  final what = receipt.forFun ? 'results' : 'receipt';
  if (names.length == 1) return 'Text $what to ${names.first}';
  if (names.length == 2) {
    return 'Text $what to ${names[0]} and ${names[1]}';
  }
  // Past two the names are longer than the button and say less than the
  // count; the note above already lists them.
  return 'Text $what to ${names.length} golfers';
}

/// Opens the composer. Returns false when it could not be opened, so the
/// caller can offer the link instead of leaving the tap unexplained.
Future<bool> sendReceiptText(ReceiptTicket receipt, Round? round) async {
  final phones = textRecipientPhones(receipt, round);
  if (phones.isEmpty || receipt.url.isEmpty) return false;
  if (!await canSendSms()) return false;
  return sendSms(message: receipt.url, recipients: phones);
}

/// The composer, with the fallback already wired.
Future<void> textReceipt(
  BuildContext context,
  ReceiptTicket receipt,
  Round? round,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await sendReceiptText(receipt, round);
  if (!ok) {
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 7),
      content: Text("Couldn't open Messages. Receipt link: ${receipt.url}"),
    ));
  }
}
