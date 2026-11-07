import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'halved_mark.dart';

/// The D1 receipt ticket — `~/Downloads/design_handoff_settle_up` §1.
///
/// **One object, three surfaces.** The server draws this same payload as the
/// web page at `/r/<code>` and as the 1080x1350 link preview; this is the
/// in-app one. The place to change the ticket is the payload and the three
/// renderers, never one of them.
///
/// **It renders and computes nothing.** Every net, transfer and row arrives
/// decided; a client that re-derived one would be a second opinion about
/// money in front of four golfers.
class ReceiptTicketCard extends StatelessWidget {
  final ReceiptTicket receipt;

  /// The colour BEHIND the ticket. The perforation notches are holes punched
  /// through it, so they are filled in the surface the ticket sits on — get
  /// this wrong and they read as two grey dots stuck to the edge.
  final Color behind;

  const ReceiptTicketCard({
    super.key,
    required this.receipt,
    this.behind = Halved.surface,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          _ticketPadX, 18, _ticketPadX, 16),
      decoration: BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Halved.ink.withValues(alpha: 0.35),
            blurRadius: 50,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Header(),
          const SizedBox(height: 12),
          Text(receipt.title,
              style: const TextStyle(
                  fontSize: 23,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: Halved.cream)),
          if (receipt.sub.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(receipt.sub,
                style: const TextStyle(fontSize: 12.5, color: _muted)),
          ],
          if (receipt.nets.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Chips(nets: receipt.nets),
          ],
          _Perforation(behind: behind),
          _SectionLabel(receipt.paysLabel),
          const SizedBox(height: 9),
          for (final t in receipt.pays) _TransferRow(transfer: t),
          for (final section in receipt.games) ...[
            _Perforation(behind: behind),
            _SectionLabel(section.label),
            const SizedBox(height: 9),
            _Rows(rows: section.rows),
          ],
        ],
      ),
    );
  }
}

/// The ticket's own horizontal padding. The perforation reads it so the
/// notches land on the edges; changing one without the other puts them
/// inside the ticket or off it.
const double _ticketPadX = 20;
const double _notchR = 11;

const _muted = Color(0xFF9BAAA0);
const _mutedDeep = Color(0xFF7C8C82);

/// §2.4: `+$26`, `−$18` (a true minus, U+2212) and `$0` when level, with
/// cents shown only when they are non-zero.
///
/// **The client formats because the payload carries CENTS**, which is §3's
/// contract and what keeps the arithmetic exact. That makes this the one
/// place the rule is written on this side — a second one is how `$26` and
/// `+$26` end up on the same screen.
///
/// `signed` is false for a transfer: the two names and the arrow already
/// carry the direction, so a sign would state it twice.
String receiptMoney(int cents, {bool signed = false}) {
  final negative = cents < 0;
  final abs = cents.abs();
  final whole = abs ~/ 100;
  final rest = abs % 100;
  final body = rest == 0
      ? '$whole'
      : '$whole.${rest.toString().padLeft(2, '0')}';
  if (negative) return '−\$$body';
  // Level is a direction, not a gain, so `$0` is never signed.
  return (signed && abs != 0) ? '+\$$body' : '\$$body';
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => const Row(
        children: [
          HalvedMark(size: 18, tooltip: 'Halved'),
          SizedBox(width: 8),
          Text('HALVED',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2.2,
                  color: Halved.cream)),
          Spacer(),
          Text('RECEIPT',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2.0,
                  color: _mutedDeep)),
        ],
      );
}

class _Chips extends StatelessWidget {
  final List<ReceiptChip> nets;
  const _Chips({required this.nets});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 8.0;
      final w = (c.maxWidth - gap) / 2;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final chip in nets) SizedBox(width: w, child: _Chip(chip: chip)),
        ],
      );
    });
  }
}

class _Chip extends StatelessWidget {
  final ReceiptChip chip;
  const _Chip({required this.chip});

  @override
  Widget build(BuildContext context) {
    final up = chip.net > 0;
    final down = chip.net < 0;
    final fill = up
        ? Halved.brightMint.withValues(alpha: 0.12)
        : down
            ? Halved.owe.withValues(alpha: 0.10)
            : Halved.cream.withValues(alpha: 0.06);
    final line = up
        ? Halved.brightMint.withValues(alpha: 0.35)
        : down
            ? Halved.owe.withValues(alpha: 0.32)
            : Halved.cream.withValues(alpha: 0.18);
    final figure =
        up ? Halved.brightMint : (down ? Halved.owe : Halved.cream);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(chip.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Halved.cream)),
                if (chip.caption.isNotEmpty)
                  Text(chip.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: _muted)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // The figure SHRINKS rather than wrapping or being clipped: it is
          // the one thing on the chip that must survive, and a big enough
          // net ($1,234.56 on a tournament) is wider than half a phone.
          // The name beside it already ellipsises, so the name gives first
          // and this only moves at the extreme.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(receiptMoney(chip.net, signed: true),
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: figure,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  final ReceiptTransfer transfer;
  const _TransferRow({required this.transfer});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          children: [
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(transfer.from,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _payStyle),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 9),
                    child: Icon(Icons.arrow_forward,
                        size: 18, color: Halved.brightMint),
                  ),
                  Flexible(
                    child: Text(transfer.to,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _payStyle),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Text(
              transfer.amountText ??
                  receiptMoney(transfer.amountCents ?? 0),
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Halved.brightMint,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      );
}

const _payStyle = TextStyle(
    fontSize: 15.5, fontWeight: FontWeight.w600, color: Halved.cream);

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.7,
            color: _mutedDeep),
      );
}

class _Rows extends StatelessWidget {
  final List<List<String>> rows;
  const _Rows({required this.rows});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.isNotEmpty ? r[0] : '',
                      style: const TextStyle(fontSize: 13, color: _muted)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(r.length > 1 ? r[1] : '',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Halved.cream)),
                  ),
                ],
              ),
            ),
        ],
      );
}

/// The dashed rule with a round notch punched through each end.
///
/// The notches are holes: they show the page behind the ticket, so they are
/// filled in [behind] rather than in any colour of their own. It bleeds past
/// the ticket's padding on both sides, which is what puts the notches on the
/// edge rather than inside it.
class _Perforation extends StatelessWidget {
  final Color behind;
  const _Perforation({required this.behind});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: LayoutBuilder(builder: (context, c) {
          // The TICKET's width, not the content's: the notches are punched
          // through its edges, which sit a padding outside this column.
          //
          // The LayoutBuilder is OUTSIDE the OverflowBox deliberately. Inside
          // it, the box's own infinite maxWidth is what the builder measures,
          // and the painter is handed Size(Infinity, 22) — which is not a
          // size and throws.
          final full = c.maxWidth + _ticketPadX * 2;
          return SizedBox(
            height: 2,
            child: OverflowBox(
              minWidth: full,
              maxWidth: full,
              minHeight: _notchR * 2,
              maxHeight: _notchR * 2,
              child: CustomPaint(
                size: Size(full, _notchR * 2),
                painter: _PerforationPainter(behind: behind),
              ),
            ),
          );
        }),
      );
}


class _PerforationPainter extends CustomPainter {
  final Color behind;
  _PerforationPainter({required this.behind});

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final dash = Paint()
      ..color = Halved.cream.withValues(alpha: 0.22)
      ..strokeWidth = 2;
    const on = 7.0, off = 6.0;
    // Inset by the notch radius so the dashes do not run under the holes.
    double x = _notchR;
    while (x < size.width - _notchR) {
      canvas.drawLine(
          Offset(x, y),
          Offset((x + on).clamp(0, size.width - _notchR), y), dash);
      x += on + off;
    }
    final hole = Paint()..color = behind;
    canvas.drawCircle(Offset(0, y), _notchR, hole);
    canvas.drawCircle(Offset(size.width, y), _notchR, hole);
  }

  @override
  bool shouldRepaint(_PerforationPainter old) => old.behind != behind;
}
