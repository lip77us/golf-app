/// screens/swat_teams_screen.dart
/// ------------------------------
/// Oakmont SWAT's teams and stake, reached from the round hub's Game setup
/// card — the same step the wizard shows, over the round's own golfers.
///
/// It starts from the teams AS THEY STAND (the round's groups) rather than the
/// snake order, so opening it never silently re-deals; "Reset to snake" is the
/// step's own control. Saving rewrites the groups and redraws the phantom
/// order, which the server refuses once a score is in — so the hub only offers
/// this before the first hole, and the refusal is shown if it is reached late.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/swat_step.dart';

class SwatTeamsScreen extends StatefulWidget {
  final int roundId;
  const SwatTeamsScreen({super.key, required this.roundId});

  @override
  State<SwatTeamsScreen> createState() => _SwatTeamsScreenState();
}

class _SwatTeamsScreenState extends State<SwatTeamsScreen> {
  bool _loading = true;
  Object? _error;
  String? _saveError;
  bool _saving = false;

  List<int> _playerIds = const [];
  final Map<int, int> _tees = {};
  List<List<int>>? _teams;            // the arrangement; null = snake
  double _stake = 6;
  bool _five = false;
  Map<String, dynamic>? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = context.read<AuthProvider>().client;
    try {
      final round = await client.getRound(widget.roundId);
      final setup = await client.getSwatSetup(widget.roundId);
      final groups = <List<int>>[];
      final ids = <int>[];
      for (final f in round.foursomes) {
        final g = <int>[];
        for (final m in f.memberships) {
          if (m.player.isPhantom) continue;
          g.add(m.player.id);
          ids.add(m.player.id);
          if (m.tee != null) _tees[m.player.id] = m.tee!.id;
        }
        if (g.isNotEmpty) groups.add(g);
      }
      if (!mounted) return;
      setState(() {
        _playerIds = ids;
        _teams = groups;
        _stake = (setup['stake'] as num?)?.toDouble() ?? 6;
        _five = setup['allow_fivesomes'] == true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  bool get _canSave =>
      !_saving && _preview != null && _preview!['problem'] == null &&
      _stake >= 0;

  Future<void> _save() async {
    setState(() { _saving = true; _saveError = null; });
    final client = context.read<AuthProvider>().client;
    try {
      final teams = [
        for (final t in (_preview!['teams'] as List))
          [for (final p in (t as Map)['players'] as List) (p as Map)['id'] as int]
      ];
      await client.postSwatSetup(widget.roundId,
          stake: _stake, allowFivesomes: _five);
      await client.postSwatTeams(widget.roundId, teams: teams, tees: _tees);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() { _saving = false; _saveError = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SWAT teams')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: '$_error', onRetry: () {
                  setState(() { _loading = true; _error = null; });
                  _load();
                })
              : Column(children: [
                  Expanded(
                    child: SwatStep(
                      playerIds: _playerIds,
                      stake: _stake,
                      allowFivesomes: _five,
                      teams: _teams,
                      onStake: (v) => setState(() => _stake = v),
                      onAllowFivesomes: (v) => setState(() {
                        _five = v;
                        _teams = null;
                      }),
                      onTeams: (t) => setState(() => _teams = t),
                      onPreview: (p) => setState(() => _preview = p),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (_saveError != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(_saveError!,
                                style: const TextStyle(color: Colors.red)),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _canSave ? _save : null,
                            child: Text(_saving ? 'Saving…' : 'Save teams'),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ]),
    );
  }
}
