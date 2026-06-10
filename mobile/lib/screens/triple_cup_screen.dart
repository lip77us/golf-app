/// screens/triple_cup_screen.dart
/// -------------------------------
/// Live standings + per-match detail for the One-Round Ryder Cup.
///
/// Layout:
///   • AppBar with title + handicap-mode badge.
///   • Top card: overall cup score (Team 1: x.x — Team 2: y.y of N).
///   • One card per match (Fourball / Foursomes / Singles 1 / Singles 2):
///       segment header, team rosters, live status ("2 UP thru 4",
///       "Halved", etc.), and the per-hole grid scored so far.
///   • Money totals at the bottom (running $$$ per player).
///   • FAB jumps to the universal /score-entry screen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_colors.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';

class TripleCupScreen extends StatefulWidget {
  final int foursomeId;
  const TripleCupScreen({super.key, required this.foursomeId});

  @override
  State<TripleCupScreen> createState() => _TripleCupScreenState();
}

class _TripleCupScreenState extends State<TripleCupScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RoundProvider>().loadTripleCup(widget.foursomeId);
    });
  }

  Future<void> _refresh() async {
    await context.read<RoundProvider>().loadTripleCup(widget.foursomeId);
  }

  @override
  Widget build(BuildContext context) {
    final rp      = context.watch<RoundProvider>();
    final summary = rp.tripleCupSummary;
    final loading = rp.loadingTripleCup;

    return Scaffold(
      appBar: GolfAppBar(
        title: 'One-Round Triple Cup',
        actions: [
          if (summary != null) _HandicapBadge(summary: summary),
          const SizedBox(width: 8),
        ],
      ),
      body: loading && summary == null
          ? const Center(child: CircularProgressIndicator())
          : summary == null
              ? ErrorView(
                  message: 'No Triple Cup game set up yet.',
                  onRetry: _refresh,
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    children: [
                      _OverallScoreCard(summary: summary),
                      const SizedBox(height: 16),
                      ...summary.matches.map((m) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _MatchCard(match: m),
                          )),
                      if (summary.money.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _MoneyCard(summary: summary),
                      ],
                    ],
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          context.read<RoundProvider>().loadScorecard(widget.foursomeId);
          Navigator.of(context).pushNamed(
            '/score-entry',
            arguments: widget.foursomeId,
          ).then((_) {
            if (mounted) _refresh();
          });
        },
        icon: const Icon(Icons.edit),
        label: const Text('Enter scores'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _HandicapBadge extends StatelessWidget {
  final TripleCupSummary summary;
  const _HandicapBadge({required this.summary});

  @override
  Widget build(BuildContext context) {
    final mode = summary.handicapMode;
    final label = switch (mode) {
      'gross'       => 'GROSS',
      'strokes_off' => 'SO',
      _             => 'NET ${summary.netPercent}%',
    };
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onPrimaryContainer)),
      ),
    );
  }
}

class _OverallScoreCard extends StatelessWidget {
  final TripleCupSummary summary;
  const _OverallScoreCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _scorePill(theme, 'Orange', summary.team2Points,
                    isLeader: summary.team2Points > summary.team1Points),
                Text('—',
                    style: theme.textTheme.headlineSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                _scorePill(theme, 'Blue', summary.team1Points,
                    isLeader: summary.team1Points > summary.team2Points),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'of ${summary.pointsAvailable} possible'
              ' • ${summary.team1Wins}W / ${summary.team2Wins}W / ${summary.halves}H',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scorePill(ThemeData theme, String label, double points,
      {required bool isLeader}) {
    final teamColor = label == 'Team 1' || label == 'Blue'
        ? kTripleCupTeam1Color
        : kTripleCupTeam2Color;
    return Column(
      children: [
        Text(label,
            style: theme.textTheme.labelMedium?.copyWith(
                color: teamColor, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(_formatPoints(points),
            style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: teamColor)),
      ],
    );
  }
}

String _formatPoints(double p) {
  if (p == p.truncateToDouble()) return p.toStringAsFixed(0);
  return p.toStringAsFixed(1);
}

// ---------------------------------------------------------------------------

class _MatchCard extends StatelessWidget {
  final TripleCupMatch match;
  const _MatchCard({required this.match});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segmentLabel = switch (match.segment) {
      'fourball'  => 'Fourball',
      'foursomes' => 'Foursomes',
      _           => 'Singles',
    };
    final winner = match.winnerLabel;
    final statusColor = match.result == 'team1'
        ? kTripleCupTeam1Color
        : match.result == 'team2'
            ? kTripleCupTeam2Color
            : theme.colorScheme.onSurfaceVariant;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(segmentLabel,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer)),
              ),
              const SizedBox(width: 8),
              Text(match.label.isEmpty ? segmentLabel : match.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('Holes ${match.startHole}–${match.displayEndHole}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),

            const SizedBox(height: 12),

            // Team rosters + status line — Orange (team 2) left, Blue (team 1)
            // right, per the app convention (blue renders second).
            Row(children: [
              Expanded(child: _teamLine(theme, 'Orange', match.team2.players,
                  highlight: match.result == 'team2',
                  color: kTripleCupTeam2Color)),
              const SizedBox(width: 8),
              SizedBox(
                width: 92,
                child: Center(
                  child: Text(
                    match.statusDisplay,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: statusColor),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _teamLine(theme, 'Blue', match.team1.players,
                  highlight: match.result == 'team1',
                  alignRight: true,
                  color: kTripleCupTeam1Color)),
            ]),

            if (match.holes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _holesGrid(theme),
            ],

            if (match.result != null) ...[
              const SizedBox(height: 8),
              Text(
                'Result: $winner',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _teamLine(ThemeData theme, String label, List<String> players,
      {bool highlight = false, bool alignRight = false, required Color color}) {
    final text = players.isEmpty ? '—' : players.join(' & ');
    return Column(
      crossAxisAlignment:
          alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: color, fontWeight: FontWeight.bold)),
        Text(text,
            textAlign: alignRight ? TextAlign.right : TextAlign.left,
            style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: highlight ? FontWeight.bold : FontWeight.w600,
                color: color)),
      ],
    );
  }

  Widget _holesGrid(ThemeData theme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: match.holes.map((h) {
          final bg = switch (h.winner) {
            'T1'     => GameColors.team1Bg,
            'T2'     => GameColors.team2Bg,
            _        => theme.colorScheme.surfaceContainerHighest,
          };
          final fg = switch (h.winner) {
            'T1' => GameColors.team1,
            'T2' => GameColors.team2,
            _    => theme.colorScheme.onSurfaceVariant,
          };
          return Container(
            width: 44,
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${h.hole}',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: fg)),
                Text(
                  '${h.t1Net ?? '—'} / ${h.t2Net ?? '—'}',
                  style: TextStyle(fontSize: 10, color: fg),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _MoneyCard extends StatelessWidget {
  final TripleCupSummary summary;
  const _MoneyCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('Money',
                  style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
              const Spacer(),
              Text('Unit: \$${summary.betUnit.toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 8),
            ...summary.money.map((m) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Expanded(child: Text(m.name)),
                    Text(
                      _formatMoney(m.amount),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: m.amount > 0
                            ? Colors.green.shade700
                            : m.amount < 0
                                ? Colors.red.shade700
                                : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ]),
                )),
          ],
        ),
      ),
    );
  }

  String _formatMoney(double v) {
    final sign = v > 0 ? '+\$' : v < 0 ? '−\$' : '\$';
    return '$sign${v.abs().toStringAsFixed(2)}';
  }
}
