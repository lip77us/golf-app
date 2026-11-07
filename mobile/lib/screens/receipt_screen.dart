import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import '../widgets/receipt_ticket.dart';

/// A settled receipt, opened from its link — the "web" surface, in the app
/// (`~/Downloads/design_handoff_settle_up` §1).
///
/// **The same ticket, and no composer.** Round over is the SCORER's screen
/// and carries the button that texts the link; this is what the golfers he
/// texted and pushed actually open, so it has nothing to act on. A receipt
/// is a record.
///
/// It deliberately does not offer "Mark as settled" either: payment is not
/// tracked, and §1 leaves the Venmo and Cash App handoff out for the same
/// reason. A tick that meant nothing would be worse than no tick.
class ReceiptScreen extends StatelessWidget {
  final ReceiptTicket receipt;

  const ReceiptScreen({super.key, required this.receipt});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Halved.surface,
        appBar: AppBar(
          backgroundColor: Halved.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: const Text('Receipt',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            children: [ReceiptTicketCard(receipt: receipt)],
          ),
        ),
      );
}
