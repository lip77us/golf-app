/// screens/team_play_settlement_screen.dart
/// ----------------------------------------
/// Settlement — one pool
/// (docs/design-review/handoff-team-play/SPEC.md §10.4).
///
/// Individual settlement reconciles seven pots against sixteen golfers. This
/// reconciles **one pot against twenty-three**, and the screen should look as
/// different as the problem is: no tabs, no per-game sections, no balance
/// check across games. One number in, three payments out.
///
/// Everyone paid the same and nothing was optional, so **the entry side has
/// nothing to explain** — one line for it, and the whole screen is the three
/// prizes and who is in them.
///
/// Three rules meet here:
///   * **A tie is one prize**, drawn as one block with both teams inside it.
///     Two rows each reading $143.75 would hide that it was one prize.
///   * **A three-man team splits three ways and takes more each** — the
///     phantom 4th earned the strokes and cannot be paid.
///   * **Odd cents go to the team's highest course handicap**, so the pool
///     balances to zero rather than leaving an unexplained $71.89 next to
///     three $71.87s.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/error_view.dart';
import '../widgets/team_play/team_play_bits.dart';

class TeamPlaySettlementScreen extends StatefulWidget {
  final int tournamentId;
  final String tournamentName;

  const TeamPlaySettlementScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<TeamPlaySettlementScreen> createState() =>
      _TeamPlaySettlementScreenState();
}

class _TeamPlaySettlementScreenState extends State<TeamPlaySettlementScreen> {
  TeamPlaySettlement? _s;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<AuthProvider>().client
          .getTeamPlaySettlement(widget.tournamentId);
      if (!mounted) return;
      setState(() { _s = s; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  static String _money(double v) => '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        title: Text('Settlement', style: Halved.appBarTitle()),
      ),
      body: _error != null
          ? ErrorView(message: '$_error', onRetry: _load)
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    _PoolHead(s: s),
                    const SizedBox(height: 16),
                    Text('Payouts', style: Halved.sectionHead()),
                    const SizedBox(height: 10),
                    for (final block in s.blocks)
                      if (block.teams.any((t) => t.amount > 0))
                        _Block(block: block, projected: !s.canSettle),
                    if (s.outOfMoney.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _OutOfMoney(s: s),
                    ],
                    const SizedBox(height: 16),
                    _Balance(s: s),
                  ],
                ),
    );
  }
}

class _PoolHead extends StatelessWidget {
  final TeamPlaySettlement s;
  const _PoolHead({required this.s});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Halved.deepPine,
          borderRadius: BorderRadius.circular(Halved.rCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_TeamPlaySettlementScreenState._money(s.pool),
                style: Halved.emptyTitle()
                    .copyWith(color: Halved.cream, fontSize: 38)),
            Text('IN THE POOL',
                style: Halved.label(color: Halved.cream.withValues(alpha: .7))),
            const SizedBox(height: 8),
            // One line for the entry side: everyone paid the same and nothing
            // was optional.
            Text(
              '\$${s.entryFee.toStringAsFixed(0)} flat × ${s.golfers} golfers, '
              'taken at signup. No side games.',
              style: Halved.body(color: Halved.cream.withValues(alpha: .75))
                  .copyWith(fontSize: 13),
            ),
          ],
        ),
      );
}

/// One prize. A tie is ONE block with both teams inside it.
class _Block extends StatelessWidget {
  final TeamPlayPrizeBlock block;
  final bool projected;

  const _Block({required this.block, required this.projected});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(Halved.rCard),
        border: Border.all(
          color: block.tied ? Halved.mint : Halved.cardBorder,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: Halved.pine,
                  borderRadius: BorderRadius.circular(Halved.rPill),
                ),
                child: Text(block.label,
                    style: Halved.label(color: Halved.cream)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  block.tied ? block.shareNote : 'The prize',
                  style: Halved.body(color: Halved.muted).copyWith(fontSize: 13),
                ),
              ),
              Text(_TeamPlaySettlementScreenState._money(block.total),
                  style: Halved.sectionHead().copyWith(fontSize: 20)),
            ],
          ),
          const Divider(height: 18),
          for (final team in block.teams) _PaidTeam(team: team),
        ],
      ),
    );
  }
}

class _PaidTeam extends StatelessWidget {
  final TeamPlayPaidTeam team;
  const _PaidTeam({required this.team});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TeamColourBlock(colour: team.colour, size: 9),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(team.name,
                      style: Halved.body(weight: FontWeight.w700)),
                  // "3 ways" on the row, so nobody has to work out why the
                  // figure is larger.
                  Text('Net ${team.net ?? '—'} · gross ${team.gross ?? '—'} · '
                       '${team.ways} ways',
                       style: Halved.label()),
                ],
              ),
            ),
            Text(_TeamPlaySettlementScreenState._money(team.amount),
                style: Halved.body(weight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 6),
        // The team wins; the golfers get paid. A row saying "Fern — $287.50"
        // is unactionable at the scoring table.
        for (final g in team.golfers)
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2, bottom: 2),
            child: Row(
              children: [
                Expanded(child: Text(g.name, style: Halved.body())),
                if (g.oddCents)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text('· odd cents', style: Halved.label()),
                  ),
                Text(_TeamPlaySettlementScreenState._money(g.amount),
                     style: Halved.body(weight: FontWeight.w600)),
              ],
            ),
          ),
        if (team.phantom)
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text('Phantom 4th',
                      style: Halved.body(color: Halved.muted)
                          .copyWith(fontStyle: FontStyle.italic)),
                ),
                Text('—', style: Halved.body(color: Halved.muted)),
              ],
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _OutOfMoney extends StatelessWidget {
  final TeamPlaySettlement s;
  const _OutOfMoney({required this.s});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Halved.surface,
          borderRadius: BorderRadius.circular(Halved.rCard),
          border: Border.all(color: Halved.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('OUT OF THE MONEY — ${s.outOfMoney.length} TEAMS',
                style: Halved.label()),
            const SizedBox(height: 8),
            for (final t in s.outOfMoney)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.name,
                              style: Halved.body(weight: FontWeight.w600)),
                          Text(
                            'Net ${t.net ?? '—'} · ${t.rank}'
                            '${t.driveShortfall > 0
                                ? ' · ${t.driveShortfall} drive'
                                  '${t.driveShortfall == 1 ? '' : 's'} short'
                                : ''}',
                            style: Halved.label(),
                          ),
                        ],
                      ),
                    ),
                    Text('−\$${(-t.perMan).toStringAsFixed(0)} each',
                         style: Halved.body(color: Halved.owe)),
                  ],
                ),
              ),
          ],
        ),
      );
}

class _Balance extends StatelessWidget {
  final TeamPlaySettlement s;
  const _Balance({required this.s});

  @override
  Widget build(BuildContext context) {
    final balanced = s.balance.abs() < 0.005;
    return Column(
      children: [
        const TeamNote(
          "Odd cents go to the team's highest course handicap, so the pool "
          'balances to zero rather than losing them.',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text('Pool balance',
                  style: Halved.body(weight: FontWeight.w700)),
            ),
            Text('\$${s.balance.toStringAsFixed(2)}',
                style: Halved.body(weight: FontWeight.w700).copyWith(
                    color: balanced ? Halved.pine : Halved.warning)),
          ],
        ),
        const SizedBox(height: 14),
        // Money does not move while a score can.
        HalvedCtaButton(
          label: s.canSettle
              ? 'Settle & text receipts'
              : 'Waiting on ${s.waitingOn.length} team'
                '${s.waitingOn.length == 1 ? '' : 's'}',
          onPressed: s.canSettle && balanced ? () {} : null,
        ),
        const SizedBox(height: 8),
        Text(
          s.canSettle
              ? 'Every team has signed for 18.'
              : 'Still out: ${s.waitingOn.join(', ')}.',
          textAlign: TextAlign.center,
          style: Halved.body(color: Halved.muted).copyWith(fontSize: 13),
        ),
      ],
    );
  }
}
