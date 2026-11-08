import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/receipt_send.dart';
import '../widgets/receipt_ticket.dart';

/// Round over — the scorer's surface after Finish round
/// (`~/Downloads/design_handoff_settle_up` §1, "roundover").
///
/// The full ticket scrolling under a pinned footer, a note saying who has it
/// in Halved, and one mint button. §1 is explicit about what is NOT here:
/// **no Share image and no Mark as settled.** The first would hand out a
/// picture when the link carries the picture and the page; the second would
/// ask the scorer to confirm something the app does not track — payment is
/// not tracked, and a tick that meant nothing is worse than no tick.
///
/// **The button is hidden when nobody needs a text**, rather than shown and
/// disabled: on a round where every golfer is on Halved the receipts have
/// already gone, and a dead button invites a tap that cannot do anything.
class RoundOverScreen extends StatelessWidget {
  final ReceiptTicket receipt;

  const RoundOverScreen({super.key, required this.receipt});

  @override
  Widget build(BuildContext context) {
    final round = context.select<RoundProvider, Round?>((rp) => rp.round);
    final label = textReceiptLabel(receipt);

    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        // Nothing was settled on a round played for fun, so the screen is
        // not named after settling it.
        title: Text(receipt.forFun ? 'Round over' : 'Settle up',
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                children: [
                  ReceiptTicketCard(receipt: receipt),
                  if (receipt.note.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _Note(text: receipt.note),
                  ],
                ],
              ),
            ),
            if (label != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
                child: SizedBox(
                  height: 52,
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Halved.brightMint,
                      foregroundColor: Halved.deepPine,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      textStyle: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    onPressed: () => textReceipt(context, receipt, round),
                    child: Text(label),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// §2.5's note, rendered as the server wrote it.
///
/// The bold run is the first sentence — who already has it — because that is
/// the half that means "you need do nothing about these golfers".
class _Note extends StatelessWidget {
  final String text;
  const _Note({required this.text});

  @override
  Widget build(BuildContext context) {
    final cut = text.indexOf('. ');
    final head = cut < 0 ? text : text.substring(0, cut + 1);
    final rest = cut < 0 ? '' : text.substring(cut + 1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FAF6),
        border: Border.all(color: const Color(0xFFC9E3D4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
                color: Halved.pine, shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 17, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: head,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Halved.deepPine)),
                TextSpan(text: rest),
              ]),
              style: const TextStyle(
                  fontSize: 12.5, height: 1.45, color: Color(0xFF38564A)),
            ),
          ),
        ],
      ),
    );
  }
}
