/// screens/banker_settlement_screen.dart
///
/// Banker — settle up, and one golfer's receipt
/// (docs/design-review/handoff-banker/banker-settlement.html).
///
/// **Banker's debts really are pairwise, and this is the only game in the set
/// that can say so.** Every bet was one named golfer against one named golfer
/// for an agreed number, so the itemisation under the handovers is real rather
/// than a reconstruction — unlike Sequoya 3s, where nothing in the format
/// assigns a loser's money to a particular winner.
///
/// Which makes the collapse to the fewest handovers an explicit convenience
/// rather than the only honest answer. Nobody settles fifty-four exchanges in
/// a car park, so the three are shown and the detail is one tap away.
///
/// **The app does not move money, and it does not keep track of who paid.**
/// The payments were ticked off here once; the checkbox came out because a
/// box beside a handover reads as a ledger, and a ledger is a promise this
/// app cannot keep — it never learns whether the note changed hands.
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
/// Gold marks the ROLE here as it does everywhere else in this game — the
/// holes a golfer banked, and nothing besides.
const Color _gold     = Color(0xFFB8860B);
const Color _goldFill = Color(0xFFFBF0D6);

String _money(double v) {
  if (v == 0) return '—';
  return '${v > 0 ? '+' : '−'}\$${v.abs().toStringAsFixed(0)}';
}

const _words = [
  'no', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen',
];

String _word(int n) => (n >= 0 && n < _words.length) ? _words[n] : '$n';

String _modeLabel(String mode) => switch (mode) {
      'strokes_off' => 'strokes off',
      'net'         => 'net',
      _             => 'gross',
    };

class BankerSettlementScreen extends StatefulWidget {
  const BankerSettlementScreen({super.key, required this.foursomeId});
  final int foursomeId;

  @override
  State<BankerSettlementScreen> createState() =>
      _BankerSettlementScreenState();
}

class _BankerSettlementScreenState extends State<BankerSettlementScreen> {
  BankerSettlement? _s;
  bool    _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final s = await client.getBankerSettlement(widget.foursomeId);
      if (!mounted) return;
      setState(() { _s = s; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _textTheGroup() async {
    final s = _s;
    if (s == null) return;
    await Share.share(s.groupText, subject: 'Banker — settling up');
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
            title: 'Banker',
            trailing: '\$${s.minBet.round()}–\$${s.maxBet.round()} band, '
                      '${_modeLabel(s.handicapMode)}',
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
                    color: s.balances ? _kWin : theme.colorScheme.error),
              ]),
            ]),
          ),
          const SizedBox(height: 12),

          _Block(
            title: s.transfers.isEmpty
                ? 'No payments'
                : s.transfers.length == 1
                    ? 'One payment'
                    : '${_word(s.transfers.length).substring(0, 1).toUpperCase()}'
                      '${_word(s.transfers.length).substring(1)} payments',
            trailing: 'fewest handovers',
            // The claim this game can make and no other can.
            note: 'Every bet here was one golfer against one golfer, so the '
                  'detail behind these is real rather than a reconstruction. '
                  '${s.betCount} exchange${s.betCount == 1 ? '' : 's'} '
                  'collapse to '
                  '${s.transfers.isEmpty ? 'none' : _word(s.transfers.length)}.',
            child: Column(children: [
              if (s.transfers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('Everyone is square. Nothing to hand over.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                )
              else
                for (final t in s.transfers) _payRow(theme, t),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.06),
                  border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'The app does not move money and does not keep track of '
                  'who has paid. This is the shortest set of handovers that '
                  'clears the table — the pairwise detail behind it is one '
                  'tap away if anybody wants to check it.',
                  style: theme.textTheme.labelSmall?.copyWith(height: 1.45),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),

          _Block(
            title: 'Receipts',
            note: 'One golfer’s net, the holes he banked in full, and the '
                  'ones he played grouped by whose bank he was betting into.',
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
                    Text(_money(r.total),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: r.total > 0
                                ? _kWin
                                : r.total < 0
                                    ? _kOwe
                                    : theme.colorScheme.onSurfaceVariant)),
                    const Icon(Icons.chevron_right),
                  ]),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _ReceiptScreen(receipt: r, settlement: s),
                  )),
                ),
            ]),
          ),
        ],
      ),
    );
  }

  /// **Banking and betting are different games**, and the row says so before
  /// it says anything else. A golfer reads that pair and knows what kind of
  /// day he had.
  Widget _netRow(ThemeData theme, BankerNet p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('banking ${_money(p.banking)} · '
                 'betting ${_money(p.betting)}',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        if (p.holesBanked > 0) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _goldFill,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
                '${p.holesBanked} HOLE${p.holesBanked == 1 ? '' : 'S'}',
                style: const TextStyle(
                    fontSize: 9.5, fontWeight: FontWeight.bold,
                    letterSpacing: 0.4, color: _gold)),
          ),
          const SizedBox(width: 10),
        ],
        SizedBox(
          width: 62,
          child: Text(_money(p.total),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold,
                color: p.total > 0
                    ? _kWin
                    : p.total < 0
                        ? _kOwe
                        : theme.colorScheme.onSurfaceVariant,
              )),
        ),
      ]),
    );
  }

  /// **No tick.** A checkbox beside a payment reads as a ledger, and the app
  /// keeps no ledger: it does not move money, does not know whether anybody
  /// paid, and must not imply that it is watching. What it can honestly say
  /// is who hands what to whom, which is the row itself.
  Widget _payRow(ThemeData theme, BankerTransfer t) {
    final initials = t.fromName.split(' ')
        .where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join();
    // Whether this single handover clears him, which is what the group wants
    // to know before anybody reaches for a wallet.
    final onlyOne =
        _s!.transfers.where((x) => x.fromId == t.fromId).length == 1;
    return Padding(
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
              Text(onlyOne
                      ? 'Clears ${t.fromName} in one'
                      : 'Part of what ${t.fromName} owes',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: 8),
          Text('\$${t.amount.toStringAsFixed(0)}',
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ]),
    );
  }
}

// ===========================================================================
// One golfer's receipt — the argument-ender
// ===========================================================================

/// **The receipt splits the round in two before it says anything else.**
/// Banking and betting are different games: −$80 as banker over six holes and
/// +$60 as a player over twelve is the only summary that survives being
/// repeated at the bar.
///
/// The holes he BANKED are itemised in full — he faced three opponents at
/// once and that is where the money and the arguments live. The ones he
/// merely played are grouped **by whose bank he was betting into**, because
/// twelve five-dollar lines would bury the six that matter, and the grouping
/// happens to answer the question a golfer actually asks: who took my money.
class _ReceiptScreen extends StatelessWidget {
  const _ReceiptScreen({required this.receipt, required this.settlement});
  final BankerReceipt    receipt;
  final BankerSettlement settlement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = receipt;
    final band = '\$${settlement.minBet.round()}–'
                 '\$${settlement.maxBet.round()}';
    return Scaffold(
      appBar: const GolfAppBar(title: 'Receipt'),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: () =>
                  Share.share(r.text, subject: 'Banker — ${r.name}'),
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
            trailing: [
              if (r.handicapIndex != null)
                'HI ${r.handicapIndex!.toStringAsFixed(1)}',
              _modeLabel(settlement.handicapMode),
              'band $band',
            ].join(' · '),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic, children: [
                Text(_money(r.total),
                    style: TextStyle(
                      fontSize: 38, fontWeight: FontWeight.bold,
                      color: r.total > 0
                          ? _kWin
                          : r.total < 0
                              ? _kOwe
                              : theme.colorScheme.onSurfaceVariant,
                    )),
                const SizedBox(width: 8),
                Text(r.total > 0
                        ? 'to collect'
                        : r.total < 0 ? 'to pay' : 'square',
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 4),
              Text(r.owedLine, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _half(theme, 'As banker', r.banking,
                    '${_word(r.holesBanked)} hole'
                    '${r.holesBanked == 1 ? '' : 's'} · '
                    '${r.betsFaced} bet${r.betsFaced == 1 ? '' : 's'} faced')),
                const SizedBox(width: 8),
                Expanded(child: _half(theme, 'As a player', r.betting,
                    '${_word(r.holesPlayed)} hole'
                    '${r.holesPlayed == 1 ? '' : 's'} · one bet each')),
              ]),
            ]),
          ),

          if (r.banked.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Block(
              title: 'The ${_word(r.holesBanked)} hole'
                     '${r.holesBanked == 1 ? '' : 's'} you banked',
              child: Column(children: [
                for (final h in r.banked) _bankedLine(theme, h),
              ]),
            ),
          ],

          if (r.byBank.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Block(
              title: 'The ${_word(r.holesPlayed)} you played',
              trailing: 'by whose bank',
              child: Column(children: [
                for (final g in r.byBank) _byBankLine(theme, g),
              ]),
            ),
          ],

          const SizedBox(height: 12),
          _Block(
            title: 'Net',
            child: Row(children: [
              Expanded(
                child: Text(
                    'Banking ${_money(r.banking)}, '
                    'betting ${_money(r.betting)}.',
                    style: theme.textTheme.bodySmall),
              ),
              Text(_money(r.total),
                  style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold,
                    color: r.total > 0
                        ? _kWin
                        : r.total < 0
                            ? _kOwe
                            : theme.colorScheme.onSurfaceVariant,
                  )),
            ]),
          ),

          const SizedBox(height: 12),
          Text(
            'A tie is no action: match the banker\u2019s net and the bet is '
            'void, whatever it had grown to, so a tied bet reads \$0 with the '
            'number it reached beside it. Ties for the low net are a separate '
            'question and only decide who banks the next hole.\n\n'
            'Bets between the other golfers on holes you did not bank are not '
            'listed. Those were their business.',
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _half(ThemeData theme, String label, double v, String sub) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: const TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.bold,
                letterSpacing: 0.3)),
        const SizedBox(height: 3),
        Text(_money(v),
            style: TextStyle(
              fontSize: 19, fontWeight: FontWeight.bold,
              color: v > 0
                  ? _kWin
                  : v < 0 ? _kOwe : theme.colorScheme.onSurfaceVariant,
            )),
        const SizedBox(height: 3),
        Text(sub,
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.35)),
      ]),
    );
  }

  /// A hole he banked. The three bets are written out because he faced them
  /// at once, and a hole that paid nobody **stays** when the stake was large:
  /// a golfer who remembers a $180 hole and cannot find it does not trust the
  /// receipt.
  Widget _bankedLine(ThemeData theme, BankerBankedHole h) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text('Hole ${h.hole}'
                 '${h.maxBet == null ? '' : ' · max \$${h.maxBet!.round()}'}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 12.5)),
            Text(h.detail,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.4)),
          ]),
        ),
        if (h.countered) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFF5E4CB),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('COUNTER',
                style: TextStyle(
                    fontSize: 9.5, fontWeight: FontWeight.bold,
                    color: _kOwe)),
          ),
        ],
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Text(_money(h.delta),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: h.delta > 0
                    ? _kWin
                    : h.delta < 0
                        ? _kOwe
                        : theme.colorScheme.onSurfaceVariant,
              )),
        ),
      ]),
    );
  }

  Widget _byBankLine(ThemeData theme, BankerByBank g) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text('v. ${g.bankerName.isEmpty ? g.banker : g.bankerName}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 12.5)),
            Text(g.note,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.4)),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Text(_money(g.subtotal),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: g.subtotal > 0
                    ? _kWin
                    : g.subtotal < 0
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
            Flexible(
              child: Text(trailing!,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
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
