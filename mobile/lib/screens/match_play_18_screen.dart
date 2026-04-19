import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';

class MatchPlay18Screen extends StatefulWidget {
  final int foursomeId;

  const MatchPlay18Screen({super.key, required this.foursomeId});

  @override
  State<MatchPlay18Screen> createState() => _MatchPlay18ScreenState();
}

class _MatchPlay18ScreenState extends State<MatchPlay18Screen> {
  @override
  void initState() {
    super.initState();
    // Refresh match play 18 data when opening the screen
    context.read<RoundProvider>().loadMatchPlay18(widget.foursomeId);
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    final summary = rp.matchPlay18Summary;

    if (rp.loadingMatchPlay18 && summary == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (rp.error != null && summary == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('18-Hole Match Play')),
        body: ErrorView(
          message: rp.error!,
          onRetry: () => rp.loadMatchPlay18(widget.foursomeId),
        ),
      );
    }

    if (summary == null) {
      return const Scaffold(
        body: Center(child: Text('No match found.')),
      );
    }

    final theme = Theme.of(context);
    final is1v1 = summary.team1.length == 1 && summary.team2.length == 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('18-Hole Match Play'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => rp.loadMatchPlay18(widget.foursomeId),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).pushNamed('/scorecard', arguments: widget.foursomeId);
        },
        icon: const Icon(Icons.edit_note),
        label: const Text('Enter Scores'),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    summary.statusDisplay,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _TeamScore(
                        title: is1v1 ? 'Player 1' : 'Team 1',
                        players: summary.team1,
                        isWinner: summary.result == 'team1',
                      ),
                      const Text('vs', style: TextStyle(color: Colors.grey)),
                      _TeamScore(
                        title: is1v1 ? 'Player 2' : 'Team 2',
                        players: summary.team2,
                        isWinner: summary.result == 'team2',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Handicap: ${summary.isNet ? 'Net (${summary.netPercent}%)' : 'Gross'}',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                  if (summary.finishedOnHole != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        'Match finished on hole ${summary.finishedOnHole}',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: Divider(thickness: 1, height: 1),
          ),
          if (summary.holes.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No holes played yet.')),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final hole = summary.holes[index];
                  return _HoleResultRow(hole: hole);
                },
                childCount: summary.holes.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _TeamScore extends StatelessWidget {
  final String title;
  final List<String> players;
  final bool isWinner;

  const _TeamScore({
    required this.title,
    required this.players,
    required this.isWinner,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: isWinner ? theme.colorScheme.primary : null,
          ),
        ),
        const SizedBox(height: 4),
        ...players.map((p) => Text(p, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

class _HoleResultRow extends StatelessWidget {
  final MatchPlay18HoleResult hole;

  const _HoleResultRow({required this.hole});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    String winnerText = 'Halved';
    Color winnerColor = Colors.grey;
    if (hole.winner == 'team1') {
      winnerText = 'Team 1 Wins';
      winnerColor = theme.colorScheme.primary;
    } else if (hole.winner == 'team2') {
      winnerText = 'Team 2 Wins';
      winnerColor = theme.colorScheme.tertiary;
    }

    String marginText = hole.margin == 0
        ? 'All Square'
        : '${hole.margin.abs()} UP';

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 50,
              child: Text(
                'Hole ${hole.hole}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('${hole.t1Net ?? "-"}'),
                  const SizedBox(width: 16),
                  Text(winnerText, style: TextStyle(color: winnerColor, fontSize: 12)),
                  const SizedBox(width: 16),
                  Text('${hole.t2Net ?? "-"}'),
                ],
              ),
            ),
            SizedBox(
              width: 70,
              child: Text(
                marginText,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
