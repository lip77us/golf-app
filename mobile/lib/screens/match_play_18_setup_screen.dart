import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/round_provider.dart';

class MatchPlay18SetupScreen extends StatefulWidget {
  final int foursomeId;
  const MatchPlay18SetupScreen({super.key, required this.foursomeId});

  @override
  State<MatchPlay18SetupScreen> createState() => _MatchPlay18SetupScreenState();
}

class _MatchPlay18SetupScreenState extends State<MatchPlay18SetupScreen> {
  bool _loading = false;
  bool _checkingSetup = true;

  // The ordered players
  List<Membership> _orderedPlayers = [];

  // Handicap config
  String _handicapMode = 'net'; // 'net' or 'gross'
  int _netPercent = 100;

  @override
  void initState() {
    super.initState();
    _checkExistingSetup();
  }

  Future<void> _checkExistingSetup() async {
    final rp = context.read<RoundProvider>();
    try {
      if (rp.round == null) await rp.loadRound(rp.round!.id); // Load the round if missing

      if (!rp.matchPlay18IsStarted(widget.foursomeId)) {
        await rp.loadMatchPlay18(widget.foursomeId);
      }

      if (rp.matchPlay18IsStarted(widget.foursomeId)) {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/match-play-18', arguments: widget.foursomeId);
        return;
      }

      await rp.loadScorecard(widget.foursomeId);

      if (!mounted) return;

      final fs = rp.round!.foursomes.firstWhere((f) => f.id == widget.foursomeId);
      setState(() {
        _orderedPlayers = List.from(fs.realPlayers);
        _checkingSetup = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _checkingSetup = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading setup: $e')));
      }
    }
  }

  void _onReorder(int oldIdx, int newIdx) {
    if (newIdx > oldIdx) newIdx -= 1;
    setState(() {
      final p = _orderedPlayers.removeAt(oldIdx);
      _orderedPlayers.insert(newIdx, p);
    });
  }

  Future<void> _startMatch() async {
    setState(() => _loading = true);
    final rp = context.read<RoundProvider>();

    List<int> team1Ids = [];
    List<int> team2Ids = [];

    if (_orderedPlayers.length == 2) {
      team1Ids = [_orderedPlayers[0].player.id];
      team2Ids = [_orderedPlayers[1].player.id];
    } else if (_orderedPlayers.length == 4) {
      team1Ids = [_orderedPlayers[0].player.id, _orderedPlayers[1].player.id];
      team2Ids = [_orderedPlayers[2].player.id, _orderedPlayers[3].player.id];
    } else {
      // 3 players not strictly supported for 1v1 or 2v2 here without resting
      // For now, let's just make it a 2v1 if they really want, but warn them
      team1Ids = [_orderedPlayers[0].player.id, _orderedPlayers[1].player.id];
      team2Ids = [_orderedPlayers[2].player.id];
    }

    final ok = await rp.setupMatchPlay18(
      widget.foursomeId,
      team1Ids: team1Ids,
      team2Ids: team2Ids,
      handicapMode: _handicapMode,
      netPercent: _netPercent,
    );

    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pushReplacementNamed('/match-play-18', arguments: widget.foursomeId);
    } else {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(rp.error ?? 'Error starting match.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSetup) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final theme = Theme.of(context);
    final bool is1v1 = _orderedPlayers.length == 2;

    return Scaffold(
      appBar: AppBar(title: const Text('18-Hole Match Play Setup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Set Teams',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              is1v1 ? 'Drag players to set the 1v1 match.' : 'Drag players to set Team 1 and Team 2.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: _orderedPlayers.length * 60.0,
              child: ReorderableListView(
                physics: const NeverScrollableScrollPhysics(),
                onReorder: _onReorder,
                children: _orderedPlayers.asMap().entries.map((e) {
                  final idx = e.key;
                  final player = e.value.player;
                  final teamLabel = is1v1
                      ? (idx == 0 ? 'Player 1' : 'Player 2')
                      : (idx < 2 ? 'Team 1' : 'Team 2');

                  return Card(
                    key: ValueKey(player.id),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: const Icon(Icons.drag_handle),
                      title: Text(player.name),
                      trailing: Text(teamLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Handicap Configuration',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'net', label: Text('Net')),
                ButtonSegment(value: 'gross', label: Text('Gross')),
              ],
              selected: {_handicapMode},
              onSelectionChanged: (s) => setState(() => _handicapMode = s.first),
            ),
            if (_handicapMode == 'net') ...[
              const SizedBox(height: 16),
              Text('Handicap Allowance', style: theme.textTheme.bodySmall),
              Wrap(
                spacing: 8,
                children: [100, 90, 80, 75, 50].map((p) {
                  return ChoiceChip(
                    label: Text('$p%'),
                    selected: _netPercent == p,
                    onSelected: (_) => setState(() => _netPercent = p),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _loading ? null : _startMatch,
              child: _loading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Start Match'),
            ),
          ],
        ),
      ),
    );
  }
}
