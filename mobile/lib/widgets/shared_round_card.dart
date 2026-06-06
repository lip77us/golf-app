import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';

/// Card for a round shared with me — a tournament or multi-group skins game a
/// friend/TD added me to. Shown in a "Shared with you" section on the Active
/// tournament + casual lists. Tapping opens the round (score my group + read the
/// leaderboard); the caller wires that via [onTap] (see `openSharedRound`).
class SharedRoundCard extends StatelessWidget {
  final ScoringRound round;
  final VoidCallback onTap;

  const SharedRoundCard({super.key, required this.round, required this.onTap});

  String _fmt(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final games =
        round.activeGames.isEmpty ? '' : '  ·  ${round.activeGames.join(", ")}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.tertiaryContainer,
                foregroundColor: theme.colorScheme.onTertiaryContainer,
                child: Icon(round.isTournament
                    ? Icons.emoji_events
                    : Icons.sports_golf),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(round.courseName,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(
                      '${round.groupLabel}  ·  ${_fmt(round.date)}$games',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (round.status == 'in_progress')
                const Chip(
                  label: Text('Live', style: TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                )
              else
                const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
