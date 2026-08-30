/// round_receipt_screen.dart
///
/// The casual-round receipt (handoff-settlement-receipt, adapted).
///
/// A different document from the tournament one. There is no pot and no TD
/// holding money — four golfers settle among themselves — so the sentence that
/// matters is not the net but **"Ben owes you $12"**. The net is still the
/// headline, because it is what a man checks first, but the transfers are what
/// he acts on, and they are what belong in a group thread.
///
/// Lines are per GAME, because that is what a casual golfer disputes: not "why
/// did I stake that" but "I thought I won the skin on 7".
///
/// Every message is composed on the SERVER. This screen renders the payload and
/// shares the string; it never builds one, so the view and the text cannot
/// disagree.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/inline_message.dart';

class RoundReceiptScreen extends StatefulWidget {
  const RoundReceiptScreen({super.key, required this.roundId});

  final int roundId;

  @override
  State<RoundReceiptScreen> createState() => _RoundReceiptScreenState();
}

class _RoundReceiptScreenState extends State<RoundReceiptScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  String _note = '';
  final Set<int> _open = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data = await client.getRoundReceipt(widget.roundId, note: _note);
      if (!mounted) return;
      setState(() { _data = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  static String _money(num? v, {bool signed = true}) {
    final d = (v ?? 0).toDouble();
    final a = d.abs();
    final body = a == a.roundToDouble() ? a.toStringAsFixed(0)
                                        : a.toStringAsFixed(2);
    if (!signed) return '\$$body';
    return d < 0 ? '−\$$body' : '+\$$body';
  }

  Future<void> _share(String message) async {
    if (message.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    await Share.share(
      message,
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
  }

  /// Share the group message, then record that it went — but only if it did.
  /// A dismissed sheet is not a send, and a stamp that lies is worse than none.
  Future<void> _sendField() async {
    final summary = (_data?['field_summary'] as Map?) ?? const {};
    final message = summary['message']?.toString() ?? '';
    if (message.isEmpty) return;

    final box = context.findRenderObject() as RenderBox?;
    final result = await Share.share(
      message,
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
    if (!mounted || result.status != ShareResultStatus.success) return;
    try {
      await context.read<AuthProvider>().client.recordRoundSettlementSend(
            widget.roundId,
            mode: 'field',
            recipients: (summary['recipients'] as int?) ?? 0,
          );
    } catch (_) {
      // The text is already gone; failing to record it must not read as a
      // failed send.
    }
    if (mounted) await _load();
  }

  String? _stamp() {
    final last = _data?['last_send'] as Map?;
    if (last == null) return null;
    final when = DateTime.tryParse(last['sent_at']?.toString() ?? '')?.toLocal();
    final t = when == null
        ? '' : ' ${TimeOfDay.fromDateTime(when).format(context)}';
    return 'Texted$t to the group'
        '${(last['sent_by']?.toString() ?? '').isEmpty
            ? '' : ' by ${last['sent_by']}'}.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _load)
              : _data == null
                  // A round with no money in it has no receipt, and an empty
                  // one would be worse than saying so.
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Nothing to settle in this round.',
                            textAlign: TextAlign.center),
                      ),
                    )
                  : _body(),
    );
  }

  Widget _body() {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final data = _data!;
    final golfers =
        (data['golfers'] as List? ?? const []).cast<Map<String, dynamic>>();
    final summary = (data['field_summary'] as Map?) ?? const {};
    final blocking = (data['blocking'] as List? ?? const []).cast<String>();
    final canSend = data['can_send'] == true;
    final segments = ((summary['segments'] as Map?)?['segments'] as int?) ?? 0;
    final stamp = _stamp();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(data['event_name']?.toString() ?? '',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),

          for (final reason in blocking) ...[
            InlineMessage(kind: InlineMessageKind.warn, text: reason),
            const SizedBox(height: 8),
          ],

          // ── Each golfer: net, the games that made it, and who he settles
          //    with. Expanded in place — for a four-ball you want all four at
          //    once, not four pushes and four backs.
          for (final g in golfers) _golferCard(g),

          const SizedBox(height: 14),
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Text the group',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Every net, then who pays whom — one message. This is '
                       'the useful one for a casual round: what the group '
                       'needs is the list of payments.',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  const SizedBox(height: 10),

                  TextFormField(
                    initialValue: _note,
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                      hintText: 'Venmo @paul-lipkin by Friday',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    // Recomposed on the server, never stitched on here.
                    onFieldSubmitted: (v) { _note = v.trim(); _load(); },
                  ),
                  const SizedBox(height: 10),

                  _preview(summary['message']?.toString() ?? ''),
                  const SizedBox(height: 6),
                  // Messages, not characters. Amber over three — it never
                  // blocks the send, it just stops the surprise.
                  Text('$segments message${segments == 1 ? '' : 's'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: segments > 3
                              ? Colors.orange.shade800 : muted)),
                  if (stamp != null) ...[
                    const SizedBox(height: 8),
                    Text(stamp, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: canSend ? _sendField : null,
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: Text(stamp == null
                          ? 'Send to the group'
                          : 'Resend to the group'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if ((data['excluded_note']?.toString() ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            // Named, because the omission would otherwise read as a bug.
            InlineMessage(
              kind: InlineMessageKind.info,
              text: data['excluded_note'].toString(),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _golferCard(Map<String, dynamic> g) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final pid = g['player_id'] as int? ?? -1;
    final isOpen = _open.contains(pid);
    final net = (g['net'] as num?)?.toDouble() ?? 0;
    final collects = net >= 0;
    final games = (g['games'] as List? ?? const []);
    final transfers = (g['transfers'] as List? ?? const []);

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      child: Column(children: [
        ListTile(
          onTap: () => setState(() =>
              isOpen ? _open.remove(pid) : _open.add(pid)),
          title: Text(g['name']?.toString() ?? '—',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(collects ? 'to collect' : 'to pay',
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_money(net),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: collects ? Colors.green.shade700 : muted,
                )),
            Icon(isOpen ? Icons.expand_less : Icons.expand_more,
                size: 18, color: muted),
          ]),
        ),
        if (isOpen)
          Container(
            width: double.infinity,
            color: theme.colorScheme.surfaceContainerLowest,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The lines he would dispute.
                for (final line in games)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text(line['label']?.toString() ?? '',
                          style: theme.textTheme.bodyMedium)),
                      Text(_money(line['amount'] as num?),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ]),
                  ),
                if (transfers.isNotEmpty) ...[
                  const Divider(height: 18),
                  // The instruction, not the arithmetic.
                  for (final t in transfers)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        t['owes_me'] == true
                            ? '${t['other']} pays you '
                              '${_money(t['amount'] as num?, signed: false)}'
                            : 'Pay ${t['other']} '
                              '${_money(t['amount'] as num?, signed: false)}',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
                const SizedBox(height: 10),
                _preview(g['message']?.toString() ?? ''),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _share(g['message']?.toString() ?? ''),
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: const Text('Send his receipt'),
                  ),
                ),
              ],
            ),
          ),
      ]),
    );
  }

  /// Plain text, shown before it can go. No formatting and no link back into
  /// the app — it has to be readable by a man who has not installed it.
  Widget _preview(String message) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Text(message,
          style: const TextStyle(fontFamily: 'monospace', height: 1.45)),
    );
  }
}
