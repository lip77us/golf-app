/// scoring_rounds_screen.dart
/// "Scoring" — rounds in other accounts a Tournament Director designated me to
/// score (Friends Phase 2b). Tapping opens the round so I can enter my
/// foursome's scores and see the whole-field leaderboard.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

class ScoringRoundsScreen extends StatefulWidget {
  const ScoringRoundsScreen({super.key});

  @override
  State<ScoringRoundsScreen> createState() => _ScoringRoundsScreenState();
}

class _ScoringRoundsScreenState extends State<ScoringRoundsScreen> {
  List<ScoringRound> _rounds = [];
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
      final rounds =
          await context.read<AuthProvider>().client.getScoringForMe();
      if (mounted) setState(() { _rounds = rounds; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  String _fmt(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scoring'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(message: 'Could not load your scoring rounds.',
          onRetry: _load);
    }
    if (_rounds.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [
          SizedBox(height: 120),
          Icon(Icons.edit_note_outlined, size: 56, color: Colors.grey),
          SizedBox(height: 12),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              "When a tournament organizer makes you the scorer for a group, "
              "it shows up here so you can enter scores for your foursome.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _rounds.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = _rounds[i];
          final games = r.activeGames.isEmpty
              ? '' : '  ·  ${r.activeGames.join(", ")}';
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
              child: const Icon(Icons.edit_note),
            ),
            title: Text(r.courseName,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${r.groupLabel}  ·  ${_fmt(r.date)}$games',
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: r.status == 'in_progress'
                ? const Chip(
                    label: Text('Live', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact)
                : const Icon(Icons.chevron_right),
            // Open the round; the scorer enters their foursome + sees the
            // whole-field leaderboard. RoundScreen loads via round_for_scorer.
            onTap: () =>
                Navigator.of(context).pushNamed('/round', arguments: r.id),
          );
        },
      ),
    );
  }
}
