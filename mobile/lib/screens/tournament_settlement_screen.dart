/// screens/tournament_settlement_screen.dart
/// -----------------------------------------
/// Where every money decision in the individual-play spec lands.
/// See docs/design-review/handoff-individual-play/SPEC.md §9.
///
/// Seven pots over two days, entries taken at signup and prizes that only
/// resolved when the last card came in — and what a golfer wants is **one
/// number**: does he pay or does he collect. So the row is the answer and the
/// card is the proof. Open it and every line that produced the number is
/// there: each entry a debit, each prize a credit, each naming the game that
/// caused it.
///
/// **By game** is the TD's check, not the golfer's: entries in, prizes out,
/// and the difference. A game that does not balance blocks the whole
/// settlement and says WHICH ONE — the mistake is always in a payout table,
/// and it is found faster by naming the game than by naming a dollar figure.
///
/// Foursome side bets are deliberately absent. The TD did not set them, does
/// not know the stakes and is not collecting for them.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/inline_message.dart';
import '../widgets/section_card.dart';
import 'settlement_receipt_screen.dart';

class TournamentSettlementScreen extends StatefulWidget {
  final int    tournamentId;
  final String tournamentName;

  const TournamentSettlementScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<TournamentSettlementScreen> createState() =>
      _TournamentSettlementScreenState();
}

class _TournamentSettlementScreenState
    extends State<TournamentSettlementScreen> {
  Map<String, dynamic>? _data;
  bool    _loading = true;
  String? _error;
  bool    _byGame  = false;
  final Set<int> _open = {};

  /// The golfer-facing payload: itemised receipts, the field-summary text and
  /// the send record.  Kept separate from the settlement data because it is a
  /// different question — the TD's is "do the pools balance", this is "what
  /// does each man owe".
  Map<String, dynamic>? _receipt;
  /// Free text that appends to both payloads — "Venmo @paul-lipkin by Friday".
  /// The actual reason a TD wants to text at all; without a field for it he
  /// retypes it sixteen times.
  String _note = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getTournamentSettlement(widget.tournamentId);
      Map<String, dynamic>? receipt;
      try {
        receipt = await client.getSettlementReceipt(widget.tournamentId,
                                                    note: _note);
      } catch (_) {
        // The receipt is an extra on this screen, not the screen — a TD must
        // still be able to settle if composing the text fails.
        receipt = null;
      }
      if (!mounted) return;
      setState(() { _data = data; _receipt = receipt; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  /// Open one golfer's receipt.
  ///
  /// The expander on the row is a peek; the receipt is the proof — with the
  /// stamp, the exclusion note, and the exact text that would go to him.
  void _openReceipt(Map<String, dynamic> golfer) {
    final r = _receipt;
    if (r == null) return;
    final pid = golfer['player_id'];
    final full = ((r['golfers'] as List? ?? const [])
            .cast<Map<String, dynamic>>())
        .firstWhere((g) => g['player_id'] == pid, orElse: () => golfer);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettlementReceiptScreen(
        eventName: r['event_name']?.toString() ?? widget.tournamentName,
        golfer: full,
        excludedNote: r['excluded_note']?.toString() ?? '',
        stamp: _stamp(),
      ),
    ));
  }

  /// "Texted 6:12 PM to 14 golfers" — a TD who is not sure whether it went out
  /// will send twice.
  String? _stamp() {
    final last = _receipt?['last_send'] as Map?;
    if (last == null) return null;
    final when = DateTime.tryParse(last['sent_at']?.toString() ?? '')?.toLocal();
    final t = when == null
        ? ''
        : ' ${TimeOfDay.fromDateTime(when).format(context)}';
    final n = last['recipients'] as int? ?? 0;
    final who = last['mode'] == 'field'
        ? 'the group thread'
        : '$n golfer${n == 1 ? '' : 's'}';
    return 'Texted$t to $who'
        '${(last['sent_by']?.toString() ?? '').isEmpty
            ? '' : ' by ${last['sent_by']}'}.';
  }

  /// Share the field summary into one group thread, then record that it went.
  ///
  /// It leaves through the phone's own share sheet, from the TD's number —
  /// the same user-initiated route the invite flow uses, and the reason this
  /// half could ship while the personal-receipt transport is still open.
  Future<void> _sendFieldSummary() async {
    final r = _receipt;
    if (r == null) return;
    final summary = (r['field_summary'] as Map?) ?? const {};
    final message = summary['message']?.toString() ?? '';
    if (message.isEmpty) return;

    final box = context.findRenderObject() as RenderBox?;
    final result = await Share.share(
      message,
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
    if (!mounted) return;
    // Only record what actually left. A dismissed sheet is not a send, and a
    // false stamp is worse than none.
    if (result.status != ShareResultStatus.success) return;
    try {
      await context.read<AuthProvider>().client.recordSettlementSend(
            widget.tournamentId,
            mode: 'field',
            recipients: (summary['recipients'] as int?) ?? 0,
          );
    } catch (_) {
      // The text is already gone; failing to record it must not read as a
      // failed send.
    }
    if (mounted) await _load();
  }

  static String _money(num v) {
    final abs = v.abs();
    return '\$${abs.toStringAsFixed(abs == abs.roundToDouble() ? 0 : 2)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settle up'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _load)
              : _body(),
      bottomNavigationBar: _data == null ? null : _settleBar(),
    );
  }

  Widget _body() {
    final data     = _data!;
    final golfers  = (data['golfers'] as List? ?? []).cast<Map<String, dynamic>>();
    final games    = (data['games']   as List? ?? []).cast<Map<String, dynamic>>();
    final blocking = (data['blocking'] as List? ?? []).cast<String>();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                  value: false,
                  label: Text('By golfer  ·  ${golfers.length}')),
              ButtonSegment(
                  value: true,
                  label: Text('By game  ·  ${games.length}')),
            ],
            selected: {_byGame},
            onSelectionChanged: (s) => setState(() => _byGame = s.first),
          ),
          const SizedBox(height: 12),

          // Every blocker, named. The Settle button below reads the same list,
          // but a reason belongs where it can be read rather than only in a
          // disabled control.
          for (final reason in blocking) ...[
            InlineMessage(kind: InlineMessageKind.warn, text: reason),
            const SizedBox(height: 8),
          ],

          if (_byGame) ..._byGameRows(games) else ..._byGolferRows(golfers),

          const SizedBox(height: 16),
          InlineMessage(
            kind: InlineMessageKind.info,
            text: data['excluded_note']?.toString() ??
                'Foursome side bets settle in the group.',
          ),

          const SizedBox(height: 16),
          ..._textTheFieldSection(),
        ],
      ),
    );
  }

  // ── Texting the field ─────────────────────────────────────────────────
  // One message to the group thread: every net, sorted, collectors first, no
  // itemisation. A man's itemised card in a sixteen-man thread is the wrong
  // default — the personal receipt is one thread each, and its transport is
  // still an open question, so only this half ships.
  List<Widget> _textTheFieldSection() {
    final r = _receipt;
    if (r == null) return const [];
    final theme    = Theme.of(context);
    final muted    = theme.colorScheme.onSurfaceVariant;
    final summary  = (r['field_summary'] as Map?) ?? const {};
    final canSend  = r['can_send'] == true;
    final n        = (summary['recipients'] as int?) ?? 0;
    final segments = ((summary['segments'] as Map?)?['segments'] as int?) ?? 0;
    final stamp    = _stamp();

    return [
      SectionCard(
        title: 'Text the field',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Every golfer\u2019s net, sorted, collectors first \u2014 one '
               'message to the group thread. No itemisation: a man disputes '
               'his own lines with you, not in front of fifteen people.',
               style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 10),

          // The note is the actual reason a TD wants to text at all.
          TextFormField(
            initialValue: _note,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'Venmo @paul-lipkin by Friday',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onFieldSubmitted: (v) {
              _note = v.trim();
              _load();          // recomposed on the server, never here
            },
          ),
          const SizedBox(height: 10),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Text(summary['message']?.toString() ?? '',
                style: const TextStyle(fontFamily: 'monospace', height: 1.45)),
          ),
          const SizedBox(height: 6),
          // Messages, not characters. Amber over three: it never blocks the
          // send, it just stops the surprise.
          Text('$segments message${segments == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: segments > 3 ? Colors.orange.shade800 : muted)),

          if (stamp != null) ...[
            const SizedBox(height: 8),
            Text(stamp, style: theme.textTheme.bodySmall),
          ],

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: canSend ? _sendFieldSummary : null,
              icon: const Icon(Icons.ios_share, size: 18),
              label: Text(stamp == null
                  ? 'Send to group thread'
                  : 'Resend to group thread'),
            ),
          ),
          if (!canSend) ...[
            const SizedBox(height: 8),
            // Shown as a condition, not an invisible disable: provisional
            // money must not leave the app, and a texted receipt is treated as
            // final by everyone who receives one.
            const InlineMessage(
              kind: InlineMessageKind.warn,
              text: 'Nothing can be texted until the tournament can settle — '
                    'a receipt that goes out is treated as final.',
            ),
          ],
          if (canSend && n > 0) ...[
            const SizedBox(height: 6),
            Text('$n golfer${n == 1 ? '' : 's'} on the summary.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
        ]),
      ),
    ];
  }

  // ── By golfer ─────────────────────────────────────────────────────────
  // Collects first, green, sorted by amount — the man owed the most wants to
  // see it first. Pays are muted, and his total is always exactly what he
  // staked.
  List<Widget> _byGolferRows(List<Map<String, dynamic>> golfers) {
    final theme = Theme.of(context);
    return [
      for (final g in golfers) ...[
        Builder(builder: (_) {
          final net     = (g['net'] as num?)?.toDouble() ?? 0;
          final collects = net > 0;
          final pid     = g['player_id'] as int? ?? -1;
          final isOpen  = _open.contains(pid);
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            elevation: 0,
            child: Column(children: [
              ListTile(
                onTap: () => setState(() =>
                    isOpen ? _open.remove(pid) : _open.add(pid)),
                title: Text(g['name']?.toString() ?? '—',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  'Staked ${_money(g['staked'] as num? ?? 0)}'
                  '${(g['won'] as num? ?? 0) > 0
                      ? ' · won ${_money(g['won'] as num? ?? 0)}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (_receipt != null)
                    IconButton(
                      tooltip: 'Receipt',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.receipt_long, size: 19),
                      onPressed: () => _openReceipt(g),
                    ),
                  Text(
                    net == 0
                        ? '—'
                        : '${collects ? "+" : "−"}${_money(net)}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: collects
                          ? Colors.green.shade700
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Icon(isOpen ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                ]),
              ),
              // The card is the proof: every line that produced the number.
              if (isOpen)
                Container(
                  width: double.infinity,
                  color: theme.colorScheme.surfaceContainerLowest,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final e in (g['entries'] as List? ?? []))
                        _line(e['game']?.toString() ?? '',
                            -((e['amount'] as num?)?.toDouble() ?? 0)),
                      for (final p in (g['prizes'] as List? ?? []))
                        _line(
                          // Group prizes show the golfer's SHARE with the
                          // group named — a share is the only part he can
                          // check.
                          p['detail']?.toString().isNotEmpty == true
                              ? p['detail'].toString()
                              : p['game']?.toString() ?? '',
                          (p['amount'] as num?)?.toDouble() ?? 0,
                        ),
                    ],
                  ),
                ),
            ]),
          );
        }),
      ],
      const SizedBox(height: 8),
      _sumZeroFooter(),
    ];
  }

  Widget _line(String label, double amount) {
    final theme = Theme.of(context);
    final credit = amount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
        Text(
          '${credit ? "+" : "−"}${_money(amount)}',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: credit ? FontWeight.w700 : FontWeight.w500,
            color: credit
                ? Colors.green.shade700
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ]),
    );
  }

  // ── By game — the TD's check ──────────────────────────────────────────
  List<Widget> _byGameRows(List<Map<String, dynamic>> games) {
    final theme = Theme.of(context);
    return [
      for (final g in games)
        Card(
          margin: const EdgeInsets.only(bottom: 6),
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(g['label']?.toString() ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Icon(
                    (g['balanced'] == true)
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18,
                    color: (g['balanced'] == true)
                        ? Colors.green.shade700
                        : theme.colorScheme.error,
                  ),
                ]),
                const SizedBox(height: 6),
                _line('Entries in',  (g['entries_in'] as num?)?.toDouble() ?? 0),
                _line('Prizes out', -((g['prizes_out'] as num?)?.toDouble() ?? 0)),
                // The carve-out is why the championship shows the full pool in
                // and the full pool out with part of it leaving for another
                // game's table.
                if (((g['transfer_out'] as num?)?.toDouble() ?? 0) > 0)
                  Text(
                    'Includes ${_money(g['transfer_out'] as num)} carved out '
                    'for the Mini Singles day-2 pot.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                if (((g['transfer_in'] as num?)?.toDouble() ?? 0) > 0)
                  Text(
                    'Funded by the championship carve-out — no entry is '
                    'charged for it.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                if (g['balanced'] != true)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Out by ${_money(g['difference'] as num? ?? 0)} — the '
                      'mistake is in this game\'s payout table.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 8),
      _sumZeroFooter(),
    ];
  }

  /// The one number that proves the whole screen. It is a closed system — the
  /// golfers fund it entirely — so any answer but zero is an arithmetic bug,
  /// not a rounding preference.
  Widget _sumZeroFooter() {
    final theme     = Theme.of(context);
    final collected = (_data!['total_collected'] as num?)?.toDouble() ?? 0;
    final paid      = (_data!['total_paid'] as num?)?.toDouble() ?? 0;
    final zero      = _data!['sum_zero'] == true;
    return SectionCard(
      title: 'Balance',
      trailing: Icon(
        zero ? Icons.check_circle : Icons.error_outline,
        size: 18,
        color: zero ? Colors.green.shade700 : theme.colorScheme.error,
      ),
      child: Column(children: [
        _line('Collected', collected),
        _line('Paid', -paid),
        const Divider(height: 14),
        Row(children: [
          const Expanded(child: Text('Sums to',
              style: TextStyle(fontWeight: FontWeight.w600))),
          Text(
            _money(collected - paid),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: zero
                  ? theme.colorScheme.onSurface : theme.colorScheme.error,
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _settleBar() {
    final canSettle = _data!['can_settle'] == true;
    final blocking  = (_data!['blocking'] as List? ?? []).cast<String>();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            // Nothing is disabled without saying why — and the day bet cannot
            // resolve until the championship does, so the button holds until
            // every round is closed and every pot balances.
            onPressed: canSettle ? () => _confirmSettle() : null,
            child: Text(
              canSettle
                  ? 'Settle'
                  : (blocking.isEmpty ? 'Settle' : _shortBlocker(blocking.first)),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  static String _shortBlocker(String reason) {
    if (reason.contains('does not balance')) {
      return '${reason.split(' does not balance').first} does not balance';
    }
    if (reason.contains('closed')) return 'Close every round first';
    return 'Cannot settle yet';
  }

  Future<void> _confirmSettle() async {
    // Drawn as all-at-once: the TD marks the tournament settled, not each
    // golfer as cash changes hands.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Settle the tournament?'),
        content: const Text(
            'Every pot balances and every round is closed. This records the '
            'tournament as settled.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Settle')),
        ],
      ),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tournament settled.')),
      );
    }
  }
}
