/// settlement_receipt_screen.dart
///
/// One golfer's receipt (handoff-settlement-receipt).
///
/// Settlement answers the TD's question — do the pools balance. This answers
/// the golfer's: what do I owe, to whom, and what for. Same data one level
/// down, addressed to one man.
///
/// **A golfer disputes a line, never a total**, so the lines are the point.
/// Entries are listed individually rather than rolled into "$120 staked" —
/// six lines against seven is itself the answer to "why did he stake less than
/// me". Prizes carry the group and the number of ways, because the share is
/// the only part he can check himself.
///
/// Nothing here composes the message. The server does that (rule 1), so the
/// screen and the text cannot disagree.
library;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

class SettlementReceiptScreen extends StatelessWidget {
  const SettlementReceiptScreen({
    super.key,
    required this.eventName,
    required this.golfer,
    required this.excludedNote,
    this.stamp,
  });

  /// One entry from the receipt payload's `golfers` list.
  final Map<String, dynamic> golfer;
  final String eventName;

  /// Why foursome side bets are absent. Shown, because the omission would
  /// otherwise read as a bug.
  final String excludedNote;

  /// "Texted 6:12 PM to 14 golfers", when a send has been recorded. A receipt
  /// with no issuer is a screenshot.
  final String? stamp;

  double get _net => (golfer['net'] as num?)?.toDouble() ?? 0;

  static String money(num? value, {bool signed = false}) {
    final v = (value ?? 0).toDouble();
    final a = v.abs();
    final body = a == a.roundToDouble()
        ? a.toStringAsFixed(0)
        : a.toStringAsFixed(2);
    if (!signed) return '\$$body';
    return v < 0 ? '−\$$body' : '+\$$body';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final entries = (golfer['entries'] as List? ?? const []);
    final prizes = (golfer['prizes'] as List? ?? const []);
    final collects = _net >= 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipt'),
        actions: [
          IconButton(
            tooltip: 'Share this receipt',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _share(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(eventName.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          letterSpacing: .6,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(golfer['name']?.toString() ?? '—',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),

                  // One net number, then every line that produced it.
                  const SizedBox(height: 12),
                  Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic, children: [
                    Text(money(_net),
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: collects
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                        )),
                    const SizedBox(width: 8),
                    Text(collects ? 'to collect' : 'to pay',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: muted,
                                       fontWeight: FontWeight.w600)),
                  ]),

                  if (entries.isNotEmpty) ...[
                    _sectionLabel(context, 'Entries (${entries.length})'),
                    for (final e in entries)
                      _line(context,
                          e['game']?.toString() ?? '',
                          -((e['amount'] as num?)?.toDouble() ?? 0)),
                  ],
                  if (prizes.isNotEmpty) ...[
                    _sectionLabel(context, 'Prizes'),
                    for (final p in prizes)
                      _line(context,
                          p['game']?.toString() ?? '',
                          (p['amount'] as num?)?.toDouble() ?? 0,
                          // The group and the number of ways: the share is the
                          // only part he can check himself.
                          detail: p['detail']?.toString()),
                  ],

                  const Divider(height: 22),
                  Row(children: [
                    Expanded(
                        child: Text('Net',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700))),
                    Text(money(_net, signed: true),
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ]),

                  if (stamp != null && stamp!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 9),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer
                            .withValues(alpha: .35),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text(stamp!,
                          style: theme.textTheme.bodySmall),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Same rule as settlement: the TD never collected for foursome side
          // bets, so they cannot appear on a receipt he issued.
          if (excludedNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(excludedNote, style: theme.textTheme.bodySmall
                  ?.copyWith(color: muted)),
            ),

          // What would actually go to him, shown before it can.  Plain text,
          // no formatting, no link back into the app — it has to be readable
          // by a man who has not installed it.
          if ((golfer['message']?.toString() ?? '').isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('The text he would get',
                style: theme.textTheme.labelMedium?.copyWith(color: muted)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Text(golfer['message'].toString(),
                  style: const TextStyle(fontFamily: 'monospace', height: 1.45)),
            ),
            const SizedBox(height: 6),
            Text(_segmentLabel(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _segments() > 3 ? Colors.orange.shade800 : muted,
                )),
          ],
        ],
      ),
    );
  }

  int _segments() =>
      ((golfer['segments'] as Map?)?['segments'] as int?) ?? 0;

  /// Length as MESSAGES, not characters — 306 characters means nothing,
  /// "3 messages" means something, and on a metered plan it means money.
  String _segmentLabel() {
    final n = _segments();
    final enc = (golfer['segments'] as Map?)?['encoding']?.toString() ?? '';
    final base = '$n message${n == 1 ? '' : 's'}';
    return enc == 'UCS-2' ? '$base · non-standard characters cost more' : base;
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await Share.share(
      golfer['message']?.toString() ?? '',
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 2),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: .5,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )),
      );

  Widget _line(BuildContext context, String label, double amount,
      {String? detail}) {
    final theme = Theme.of(context);
    final positive = amount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.bodyMedium),
            if (detail != null && detail.isNotEmpty)
              Text(detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 10),
        Text(money(amount, signed: true),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: positive ? FontWeight.w700 : FontWeight.w600,
              color: positive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            )),
      ]),
    );
  }
}
