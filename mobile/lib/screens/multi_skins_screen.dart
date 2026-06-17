/// screens/multi_skins_screen.dart
/// -------------------------------
/// Read-only summary screen for the round-level Multi-Foursome Skins
/// pool.  Players enter scores from their own foursome's regular score-
/// entry screen; this screen displays standings.
///
/// Sections:
///   • Money summary (pool, total skins, status)
///   • Player leaderboard (skins won + payout)
///   • Per-hole grid (winner short_name or "—" for a dead skin)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/round_chat_button.dart';

class MultiSkinsScreen extends StatefulWidget {
  final int roundId;
  const MultiSkinsScreen({super.key, required this.roundId});

  @override
  State<MultiSkinsScreen> createState() => _MultiSkinsScreenState();
}

class _MultiSkinsScreenState extends State<MultiSkinsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RoundProvider>().loadMultiSkins(widget.roundId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rp      = context.watch<RoundProvider>();
    final summary = rp.multiSkinsSummary;

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Multi-Group Skins',
        actions: [
          IconButton(
            tooltip: 'Refresh scores',
            icon: const Icon(Icons.refresh),
            onPressed: rp.loadingMultiSkins
                ? null
                : () => rp.loadMultiSkins(widget.roundId),
          ),
          RoundChatButton(roundId: widget.roundId),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Edit setup',
            onPressed: () => Navigator.of(context).pushNamed(
              '/multi-skins-setup',
              arguments: widget.roundId,
            ),
          ),
        ],
      ),
      body: rp.loadingMultiSkins && summary == null
          ? const Center(child: CircularProgressIndicator())
          : summary == null
              ? ErrorView(
                  message: 'No data',
                  onRetry: () => rp.loadMultiSkins(widget.roundId),
                )
              : RefreshIndicator(
                  onRefresh: () => rp.loadMultiSkins(widget.roundId),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _MoneyCard(summary: summary),
                      const SizedBox(height: 16),
                      _PlayerLeaderboard(summary: summary),
                      const SizedBox(height: 16),
                      _HolesGrid(summary: summary),
                    ],
                  ),
                ),
    );
  }
}

class _MoneyCard extends StatelessWidget {
  final MultiSkinsSummary summary;
  const _MoneyCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    String label(String s) => switch (s) {
      'pending'     => 'Not started',
      'in_progress' => 'In progress',
      'complete'    => 'Complete',
      _             => s,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pool — \$${summary.pool.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${summary.players.length} players × '
            '\$${summary.betUnit.toStringAsFixed(2)}   •   '
            '${summary.totalSkins} skin(s) won   •   '
            '${label(summary.status)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            'Mode: ${summary.handicapMode.toUpperCase()}'
            '${summary.isNet && summary.netPercent != 100
                  ? " (${summary.netPercent}%)" : ""}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

class _PlayerLeaderboard extends StatelessWidget {
  final MultiSkinsSummary summary;
  const _PlayerLeaderboard({required this.summary});

  @override
  Widget build(BuildContext context) {
    // Group participants by foursome so each group can show its scorecard
    // icon once at the section header.
    final byGroup = <int, List<MultiSkinsPlayerTotal>>{};
    for (final p in summary.players) {
      byGroup.putIfAbsent(p.groupNumber, () => []).add(p);
    }
    final groupNums = byGroup.keys.toList()..sort();

    return Card(
      child: Column(
        children: [
          const ListTile(
            dense: true,
            title: Text('Standings',
                style: TextStyle(fontWeight: FontWeight.bold)),
            trailing: SizedBox(
              width: 140,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(width: 36,
                      child: Text('Thru', textAlign: TextAlign.right,
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  SizedBox(width: 8),
                  SizedBox(width: 36,
                      child: Text('Skins', textAlign: TextAlign.right,
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  SizedBox(width: 8),
                  SizedBox(width: 52,
                      child: Text('Payout', textAlign: TextAlign.right,
                          style: TextStyle(fontWeight: FontWeight.bold))),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          for (final gn in groupNums) ...[
            // Section header per group with a tappable scorecard icon
            // that opens the foursome's full scorecard.
            _GroupHeader(
              groupNumber: gn,
              foursomeId : byGroup[gn]!.first.foursomeId,
            ),
            for (final p in byGroup[gn]!)
              ListTile(
                dense: true,
                title: Text(p.name),
                trailing: SizedBox(
                  width: 140,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(width: 36,
                          child: Text(p.thru == 0 ? '—' : '${p.thru}',
                              textAlign: TextAlign.right)),
                      const SizedBox(width: 8),
                      SizedBox(width: 36,
                          child: Text('${p.skinsWon}',
                              textAlign: TextAlign.right)),
                      const SizedBox(width: 8),
                      SizedBox(width: 52,
                          child: Text('\$${p.payout.toStringAsFixed(2)}',
                              textAlign: TextAlign.right)),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final int groupNumber;
  final int foursomeId;
  const _GroupHeader({required this.groupNumber, required this.foursomeId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(children: [
        Text('Group $groupNumber',
            style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold)),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.assignment, size: 20),
          tooltip: 'View scorecard',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => Navigator.of(context).pushNamed(
            '/scorecard',
            arguments: {'foursomeId': foursomeId, 'readOnly': true},
          ),
        ),
      ]),
    );
  }
}

class _HolesGrid extends StatelessWidget {
  final MultiSkinsSummary summary;
  const _HolesGrid({required this.summary});

  @override
  Widget build(BuildContext context) {
    final byHole = {for (final h in summary.holes) h.hole: h};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Hole-by-hole', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _NineRow(start: 1,  byHole: byHole, label: 'Front'),
          const SizedBox(height: 8),
          _NineRow(start: 10, byHole: byHole, label: 'Back'),
          const SizedBox(height: 8),
          Text('— = no clear winner (dead)',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _NineRow extends StatelessWidget {
  final int start;
  final String label;
  final Map<int, MultiSkinsHole> byHole;
  const _NineRow({
    required this.start,
    required this.label,
    required this.byHole,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
          width: 40,
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.bold))),
      const SizedBox(width: 4),
      Expanded(
        child: Row(
          children: [
            for (int h = start; h < start + 9; h++)
              Expanded(
                child: Column(children: [
                  Text('$h', style: const TextStyle(fontSize: 10)),
                  Container(
                    height: 22,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _cellText(byHole[h]),
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ),
          ],
        ),
      ),
    ]);
  }

  String _cellText(MultiSkinsHole? h) {
    if (h == null)         return '';
    if (h.isDead)          return '—';
    return h.winnerShort ?? '?';
  }
}
