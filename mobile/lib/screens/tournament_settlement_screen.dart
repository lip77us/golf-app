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

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/inline_message.dart';
import '../widgets/section_card.dart';

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
      if (!mounted) return;
      setState(() { _data = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
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
        ],
      ),
    );
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
