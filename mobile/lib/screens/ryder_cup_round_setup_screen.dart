/// ryder_cup_round_setup_screen.dart
///
/// Lets staff configure the Ryder Cup game for a single round:
///   • Set nassau_point_value and point_multiplier
///   • Assign a game_type to each foursome
///   • Assign team1 / team2 to each foursome
///
/// Entry: push with (roundId, tournamentId).
/// Returns true when the setup was saved successfully.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

class RyderCupRoundSetupScreen extends StatefulWidget {
  final int roundId;
  final int tournamentId;

  const RyderCupRoundSetupScreen({
    super.key,
    required this.roundId,
    required this.tournamentId,
  });

  @override
  State<RyderCupRoundSetupScreen> createState() =>
      _RyderCupRoundSetupScreenState();
}

class _RyderCupRoundSetupScreenState
    extends State<RyderCupRoundSetupScreen> {
  // ── Loaded data ────────────────────────────────────────────────────────────
  Round?                 _round;
  TeamTournamentSummary? _cupSummary;
  bool    _loading      = true;
  String? _error;
  bool    _networkError = false;
  bool    _saving       = false;

  // ── Form controllers ───────────────────────────────────────────────────────
  final _pointValueCtrl = TextEditingController(text: '1.0');
  final _multiplierCtrl = TextEditingController(text: '1.0');
  final _notesCtrl      = TextEditingController();

  // Per-foursome: keyed by foursome id
  final Map<int, String?> _gameType = {};
  final Map<int, int?>    _team1Id  = {};
  final Map<int, int?>    _team2Id  = {};

  static const _gameChoices = [
    ('nassau',          'Four Ball (Nassau)'),
    ('quota_nassau',    'Four Ball Quota (Nassau)'),
    ('irish_rumble',    'Irish Rumble'),
    ('singles_nassau',  'Singles Nassau (F9/B9/All)'),
    ('singles_18',      '18-Hole Singles'),
    ('skins',           'Skins'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pointValueCtrl.dispose();
    _multiplierCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  ApiClient get _client => context.read<AuthProvider>().client;

  // ── Data loading ───────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _client.getRound(widget.roundId),
        _client.getTeamTournament(widget.tournamentId),
        _client.getRyderCupRound(widget.roundId).catchError((_) => <String, dynamic>{}),
      ]);
      final round     = results[0] as Round;
      final cup       = results[1] as TeamTournamentSummary;
      final cupConfig = results[2] as Map<String, dynamic>;
      if (!mounted) return;

      // Pre-populate point config from existing DB values (if already configured)
      if (cupConfig.containsKey('nassau_point_value')) {
        final pv  = (cupConfig['nassau_point_value'] as num).toDouble();
        final mul = (cupConfig['point_multiplier']   as num? ?? 1).toDouble();
        _pointValueCtrl.text = pv  % 1 == 0 ? pv.toInt().toString()  : pv.toString();
        _multiplierCtrl.text = mul % 1 == 0 ? mul.toInt().toString() : mul.toString();
        if (cupConfig['notes'] != null && (cupConfig['notes'] as String).isNotEmpty) {
          _notesCtrl.text = cupConfig['notes'] as String;
        }
      }

      // Initialise per-foursome selectors with sensible defaults
      for (final fs in round.foursomes) {
        _gameType.putIfAbsent(fs.id, () => null);
        _team1Id .putIfAbsent(fs.id, () =>
            cup.teams.isNotEmpty ? cup.teams[0].teamId : null);
        _team2Id .putIfAbsent(fs.id, () =>
            cup.teams.length > 1 ? cup.teams[1].teamId : null);
      }

      setState(() { _round = round; _cupSummary = cup; });
    } catch (e) {
      if (mounted) setState(() {
        _error        = friendlyError(e);
        _networkError = isNetworkError(e);
      });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    // Validate
    for (final fs in _round!.foursomes) {
      if (_gameType[fs.id] == null) {
        _showSnack('Please set a game type for every group.');
        return;
      }
    }

    final nassauPv   = double.tryParse(_pointValueCtrl.text.trim()) ?? 1.0;
    final multiplier = double.tryParse(_multiplierCtrl.text.trim()) ?? 1.0;

    final foursomesPayload = _round!.foursomes.map((fs) {
      final body = <String, dynamic>{
        'foursome_id': fs.id,
        'game_type'  : _gameType[fs.id]!,
      };
      if (_team1Id[fs.id] != null) body['team1_id'] = _team1Id[fs.id];
      if (_team2Id[fs.id] != null) body['team2_id'] = _team2Id[fs.id];
      return body;
    }).toList();

    setState(() { _saving = true; });
    try {
      await _client.postRyderCupRoundSetup(
        widget.roundId,
        nassauPointValue : nassauPv,
        pointMultiplier  : multiplier,
        notes            : _notesCtrl.text.trim(),
        foursomes        : foursomesPayload,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Round configured ✓')));
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) _showSnack(friendlyError(e));
    } finally {
      if (mounted) setState(() { _saving = false; });
    }
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _round != null
            ? Text('R${_round!.roundNumber} · Cup Game Setup')
            : const Text('Cup Round Setup'),
        actions: [
          if (!_saving && _round != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(message: _error!, isNetwork: _networkError, onRetry: _load);
    }

    final round = _round!;
    final cup   = _cupSummary!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Points config ────────────────────────────────────────────────────
        Text('Points Config',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _pointValueCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Points per segment',
                hintText : '1.0',
                border   : OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _multiplierCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Multiplier',
                hintText : '1.0',
                border   : OutlineInputBorder(),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _notesCtrl,
          decoration: const InputDecoration(
            labelText : 'Notes (optional)',
            border    : OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),

        // ── Foursome configs ─────────────────────────────────────────────────
        Text('Foursome Game Setup',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        Text('Assign game type and teams to each group.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),

        ...round.foursomes.map((fs) => _FoursomeConfigCard(
          foursome   : fs,
          courseName : round.course.name,
          teams      : cup.teams,
          gameType   : _gameType[fs.id],
          team1Id    : _team1Id[fs.id],
          team2Id    : _team2Id[fs.id],
          gameChoices: _gameChoices,
          onGameType : (gt) => setState(() => _gameType[fs.id] = gt),
          onTeam1    : (id) => setState(() => _team1Id[fs.id]  = id),
          onTeam2    : (id) => setState(() => _team2Id[fs.id]  = id),
        )),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-foursome config card
// ---------------------------------------------------------------------------

class _FoursomeConfigCard extends StatelessWidget {
  final Foursome  foursome;
  final String    courseName;
  final List<CupTeam> teams;
  final String?   gameType;
  final int?      team1Id;
  final int?      team2Id;
  final List<(String, String)> gameChoices;
  final void Function(String?) onGameType;
  final void Function(int?)    onTeam1;
  final void Function(int?)    onTeam2;

  const _FoursomeConfigCard({
    required this.foursome,
    required this.courseName,
    required this.teams,
    required this.gameType,
    required this.team1Id,
    required this.team2Id,
    required this.gameChoices,
    required this.onGameType,
    required this.onTeam1,
    required this.onTeam2,
  });

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final realPlayers = foursome.realPlayers;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Text('Group ${foursome.groupNumber}',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (realPlayers.isNotEmpty)
            Text(
              realPlayers.map((m) => m.player.name).join(', '),
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 12),

          // Game type picker
          DropdownButtonFormField<String>(
            value: gameType,
            isExpanded: true,
            hint: const Text('Select game type'),
            decoration: const InputDecoration(
              labelText: 'Game type',
              border   : OutlineInputBorder(),
              isDense  : true,
            ),
            items: gameChoices.map((g) => DropdownMenuItem(
              value: g.$1,
              child: Text(g.$2),
            )).toList(),
            onChanged: onGameType,
          ),

          if (teams.length >= 2) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: team1Id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Team 1',
                    border   : OutlineInputBorder(),
                    isDense  : true,
                  ),
                  items: teams.map((t) => DropdownMenuItem(
                    value: t.teamId,
                    child: Text(t.name),
                  )).toList(),
                  onChanged: onTeam1,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: team2Id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Team 2',
                    border   : OutlineInputBorder(),
                    isDense  : true,
                  ),
                  items: teams.map((t) => DropdownMenuItem(
                    value: t.teamId,
                    child: Text(t.name),
                  )).toList(),
                  onChanged: onTeam2,
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
