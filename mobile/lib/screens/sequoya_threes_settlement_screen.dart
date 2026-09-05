/// screens/sequoya_threes_settlement_screen.dart
///
/// Sequoya 3s — settle up, and one golfer's receipt
/// (docs/design-review/handoff-sequoya-threes/sequoya-threes-settlement.html).
///
/// **Nets are real; pairwise debts are not.** The stake is a man a match, so
/// two losers owe twenty and two winners are owed ten each — and nothing in
/// the format says WHICH winner a given ten dollars belongs to. So the
/// payments under the nets are presented as what they are: the shortest way
/// to make four numbers true, never a record of who beat whom.
///
/// The app does not move money and does not pretend to. Ticking a payment
/// records that the golfers said it happened.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';

const Color _kWin  = Color(0xFF388E3C);
const Color _kOwe  = Color(0xFF8A5216);

String _money(double v) {
  if (v == 0) return '—';
  return '${v > 0 ? '+' : '−'}\$${v.abs().toStringAsFixed(0)}';
}

class SequoyaThreesSettlementScreen extends StatefulWidget {
  const SequoyaThreesSettlementScreen({super.key, required this.foursomeId});
  final int foursomeId;

  @override
  State<SequoyaThreesSettlementScreen> createState() =>
      _SequoyaThreesSettlementScreenState();
}

class _SequoyaThreesSettlementScreenState
    extends State<SequoyaThreesSettlementScreen> {
  SequoyaSettlement? _s;
  bool    _loading = true;
  Object? _error;
  /// Ticked payments. **Local and cosmetic** — no money moves here, and the
  /// app must not imply that it does, so this is deliberately not persisted.
  final Set<int> _settled = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final s = await client.getSequoyaThreesSettlement(widget.foursomeId);
      if (!mounted) return;
      setState(() { _s = s; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _textTheGroup() async {
    final s = _s;
    if (s == null) return;
    await Share.share(s.groupText, subject: 'Sequoya 3s — settling up');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const GolfAppBar(title: 'Settle up'),
      bottomNavigationBar: (_s == null) ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _textTheGroup,
              icon: const Icon(Icons.ios_share, size: 20),
              label: const Text('Text the group',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: friendlyError(_error!), onRetry: _load)
              : _body(theme),
    );
  }

  Widget _body(ThemeData theme) {
    final s = _s!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          _Block(
            title: 'Sequoya 3s',
            trailing: '\$${s.betAmount.toStringAsFixed(0)} a man, every bet',
            note: s.headline,
            child: Column(children: [
              for (final p in s.players) _netRow(theme, p),
              const Divider(height: 18, thickness: 1.5),
              Row(children: [
                Text('Balances to zero',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const Spacer(),
                Icon(s.balances ? Icons.check : Icons.error_outline,
                    size: 16,
                    color: s.balances
                        ? _kWin : theme.colorScheme.error),
              ]),
            ]),
          ),
          const SizedBox(height: 12),

          _Block(
            title: s.transfers.length == 1
                ? 'One payment' : '${s.transfers.length} payments',
            trailing: 'fewest handovers',
            note: 'The shortest set of transfers that makes those four '
                  'numbers true. Not a record of who beat whom — nothing in '
                  'the format assigns one golfer’s loss to another’s win.',
            child: Column(children: [
              if (s.transfers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('Everyone is square. Nothing to hand over.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                )
              else
                for (var i = 0; i < s.transfers.length; i++)
                  _payRow(theme, i, s.transfers[i]),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 11, vertical: 9),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.06),
                  border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Ticking one marks it done in the app only. No money moves '
                  'here — this is the four of you agreeing what happened.',
                  style: theme.textTheme.labelSmall?.copyWith(height: 1.45),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),

          _Block(
            title: 'Receipts',
            note: 'One golfer’s net, and every match that produced it.',
            child: Column(children: [
              for (final r in s.receipts)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(r.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(r.owedLine,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_money(r.money),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: r.money > 0
                                ? _kWin
                                : r.money < 0
                                    ? _kOwe
                                    : theme.colorScheme.onSurfaceVariant)),
                    const Icon(Icons.chevron_right),
                  ]),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _ReceiptScreen(
                        receipt: r, betAmount: s.betAmount),
                  )),
                ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _netRow(ThemeData theme, SequoyaNet p) {
    final sub = [
      p.recordLabel,
      if (p.bestPartner != null) 'best with ${p.bestPartner}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text(p.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(sub,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        if (p.gross != null) ...[
          Text('gross ${p.gross}',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 12),
        ],
        SizedBox(
          width: 62,
          child: Text(_money(p.money),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold,
                color: p.money > 0
                    ? _kWin
                    : p.money < 0
                        ? _kOwe
                        : theme.colorScheme.onSurfaceVariant,
              )),
        ),
      ]),
    );
  }

  Widget _payRow(ThemeData theme, int i, SequoyaTransfer t) {
    final done = _settled.contains(i);
    final initials = t.fromName.split(' ')
        .where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join();
    return InkWell(
      onTap: () => setState(() =>
          done ? _settled.remove(i) : _settled.add(i)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Container(
            width: 34, height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(initials.toUpperCase(),
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13,
                    color: theme.colorScheme.primary)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: t.fromName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const TextSpan(text: ' pays '),
                TextSpan(text: t.toName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ]), style: const TextStyle(fontSize: 13.5)),
              Text('Clears both in one',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: 8),
          Text('\$${t.amount.toStringAsFixed(0)}',
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(width: 10),
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
              color: done ? theme.colorScheme.primary : Colors.transparent,
              border: Border.all(
                  color: done
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                  width: 1.5),
              borderRadius: BorderRadius.circular(7),
            ),
            child: done
                ? const Icon(Icons.check, size: 14, color: Colors.white)
                : null,
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// One golfer's receipt — the argument-ender
// ===========================================================================

/// One net at the top, then **every match that produced it**, with its
/// pairing, its result and the bets it carried.
///
/// A halved match stays here at zero: six matches were played, and a receipt
/// showing five invites the very question the receipt exists to prevent.
class _ReceiptScreen extends StatelessWidget {
  const _ReceiptScreen({required this.receipt, required this.betAmount});
  final SequoyaReceipt receipt;
  final double         betAmount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = receipt;
    return Scaffold(
      appBar: const GolfAppBar(title: 'Receipt'),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: () => Share.share(r.text,
                  subject: 'Sequoya 3s — ${r.name}'),
              icon: const Icon(Icons.ios_share, size: 20),
              label: const Text('Text this receipt',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          _Block(
            title: r.name,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic, children: [
                Text(_money(r.money),
                    style: TextStyle(
                      fontSize: 38, fontWeight: FontWeight.bold,
                      color: r.money > 0
                          ? _kWin
                          : r.money < 0
                              ? _kOwe
                              : theme.colorScheme.onSurfaceVariant,
                    )),
                const SizedBox(width: 8),
                Text(r.money > 0
                        ? 'to collect'
                        : r.money < 0 ? 'to pay' : 'square',
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 4),
              Text(r.owedLine, style: theme.textTheme.bodySmall),
            ]),
          ),
          const SizedBox(height: 12),

          _Block(
            title: 'The six matches',
            child: Column(children: [
              for (final m in r.matches) _matchLine(theme, m),
            ]),
          ),

          if (r.calledPresses.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Block(
              title: 'Presses called by hand — ${r.calledPresses.length}',
              note: 'An auto press has no author and no decision in it, so it '
                    'is counted in the match line as a second bet. A press '
                    'somebody called is named with who called it, when, and '
                    'which holes it covered.',
              child: Column(children: [
                for (final p in r.calledPresses)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(p.hole == null
                                  ? 'Press' : 'Hole ${p.hole}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 12.5)),
                          Text(p.line,
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  height: 1.4)),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      Text('In match ${p.matchIndex}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
              ]),
            ),
          ],

          const SizedBox(height: 12),
          Text(
            'Every press is a separate \$${betAmount.toStringAsFixed(0)} bet '
            'at the same stake, never a doubling.',
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _matchLine(ThemeData theme, SequoyaReceiptMatch m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text('Match ${m.index} · with ${m.partner}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 12.5)),
            Text('v. ${m.opponents} · ${m.line} · ${m.holes}',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.4)),
          ]),
        ),
        const SizedBox(width: 8),
        // The bet count is on the line because in this format the dispute is
        // nearly always about a press.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('${m.betCount} bet${m.betCount == 1 ? '' : 's'}',
              style: const TextStyle(
                  fontSize: 9.5, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 46,
          child: Text(_money(m.money),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: m.money > 0
                    ? _kWin
                    : m.money < 0
                        ? _kOwe
                        : theme.colorScheme.onSurfaceVariant,
              )),
        ),
      ]),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.title, this.trailing, this.note, required this.child,
  });
  final String  title;
  final String? trailing;
  final String? note;
  final Widget  child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          if (trailing != null)
            Text(trailing!,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
        ]),
        if (note != null) ...[
          const SizedBox(height: 3),
          Text(note!,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.5)),
        ],
        const SizedBox(height: 8),
        child,
      ]),
    );
  }
}
