/// screens/tournament_stableford_setup_screen.dart
/// Stableford Championship setup — handicap (Net%/Gross), the editable 6-bucket
/// points table (3 presets), and pool payout (entry fee + paid places). Pool-
/// only (no per-point); mirrors the casual Stableford setup, tournament-scoped.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/payout_config_field.dart';

const _kBuckets = ['albatross', 'eagle', 'birdie', 'par', 'bogey', 'double'];
const _kBucketLabels = {
  'albatross': 'Albatross or better',
  'eagle': 'Eagle',
  'birdie': 'Birdie',
  'par': 'Par',
  'bogey': 'Bogey',
  'double': 'Double bogey or worse',
};
const _kPresets = <String, Map<String, int>>{
  'Standard':       {'albatross': 5, 'eagle': 4, 'birdie': 3, 'par': 2, 'bogey': 1,  'double': 0},
  'Modified (pro)': {'albatross': 8, 'eagle': 5, 'birdie': 2, 'par': 0, 'bogey': -1, 'double': -3},
  'Reward birdies': {'albatross': 6, 'eagle': 4, 'birdie': 3, 'par': 1, 'bogey': 0,  'double': -1},
};

class TournamentStablefordSetupScreen extends StatefulWidget {
  final int tournamentId;
  const TournamentStablefordSetupScreen({super.key, required this.tournamentId});

  @override
  State<TournamentStablefordSetupScreen> createState() =>
      _TournamentStablefordSetupScreenState();
}

class _TournamentStablefordSetupScreenState
    extends State<TournamentStablefordSetupScreen> {
  String _mode = 'net';
  int _netPercent = 100;
  final _entryCtrl = TextEditingController(text: '0');
  int _numPlayers = 0;

  final _points = {for (final b in _kBuckets) b: TextEditingController()};
  final _payoutCtrls =
      List<TextEditingController>.generate(4, (_) => TextEditingController(text: '0'));
  int _numPayouts = 0;

  bool _loading = true;
  bool _saving  = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _entryCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    for (final c in _points.values) c.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  double get _pool {
    final fee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
    return fee * _numPlayers;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final cfg = await context.read<AuthProvider>().client
          .getTournamentStablefordSetup(widget.tournamentId);
      if (!mounted) return;
      setState(() {
        _numPlayers = cfg['num_players'] as int? ?? 0;
        _mode = (cfg['handicap_mode']?.toString() == 'gross') ? 'gross' : 'net';
        _netPercent = cfg['net_percent'] as int? ?? 100;
        _entryCtrl.text = _fmt(cfg['entry_fee'] as num? ?? 0);
        for (final b in _kBuckets) {
          _points[b]!.text = '${cfg['pts_$b'] ?? _kPresets['Standard']![b]}';
        }
        final payouts = (cfg['payouts'] as List? ?? []);
        _numPayouts = payouts.length.clamp(0, 4);
        for (var i = 0; i < 4; i++) {
          _payoutCtrls[i].text = i < payouts.length
              ? _fmt(double.tryParse(payouts[i]['amount']?.toString() ?? '') ?? 0)
              : '0';
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  String _fmt(num n) => n == n.roundToDouble() ? n.toInt().toString() : '$n';

  void _applyPreset(Map<String, int> t) =>
      setState(() { for (final b in _kBuckets) _points[b]!.text = '${t[b]}'; });

  void _applyPoolPreset(List<double> ratios) {
    final pool = _pool.round();
    setState(() {
      _numPayouts = ratios.length;
      var remaining = pool;
      for (var i = 0; i < 4; i++) {
        if (i >= ratios.length) { _payoutCtrls[i].text = '0'; continue; }
        final amt = i == ratios.length - 1 ? remaining : (pool * ratios[i]).round();
        remaining -= amt;
        _payoutCtrls[i].text = '$amt';
      }
    });
  }

  void _suggest() {
    final amounts = suggestPayouts(_pool.round(), _numPayouts);
    setState(() {
      for (var i = 0; i < 4; i++) _payoutCtrls[i].text = '${amounts[i]}';
    });
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final payouts = <Map<String, dynamic>>[
        for (var i = 0; i < _numPayouts; i++)
          {'place': i + 1,
           'amount': double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0},
      ];
      await context.read<AuthProvider>().client.postTournamentStablefordSetup(
        widget.tournamentId,
        handicapMode: _mode,
        netPercent: _netPercent,
        entryFee: double.tryParse(_entryCtrl.text.trim()) ?? 0.0,
        payouts: payouts,
        pointsTable: {
          for (final b in _kBuckets) b: int.tryParse(_points[b]!.text.trim()) ?? 0,
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stableford Championship')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && !_saving)
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load)
              : Column(children: [
                  Expanded(child: _body()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity, height: 52,
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Text('Save',
                                  style: TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _body() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Total Stableford points across every round determine the winner.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        HandicapModeSelector(
          mode: _mode,
          netPercent: _netPercent,
          allowStrokesOff: false,
          onModeChanged: (m) => setState(() => _mode = m),
          onPercentChanged: (p) => setState(() => _netPercent = p),
        ),
        const SizedBox(height: 24),

        Text('Points table', style: theme.textTheme.titleMedium),
        Text('Points per hole by score vs par. Negatives allowed.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final entry in _kPresets.entries)
            ActionChip(
              label: Text(entry.key),
              onPressed: () => _applyPreset(entry.value)),
        ]),
        const SizedBox(height: 8),
        for (final b in _kBuckets)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text(_kBucketLabels[b]!)),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _points[b],
                  textAlign: TextAlign.center,
                  keyboardType:
                      const TextInputType.numberWithOptions(signed: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
                  ],
                  decoration: const InputDecoration(
                      border: OutlineInputBorder(), isDense: true),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 24),

        Text('Payout (pool)', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _entryCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Entry fee per player', prefixText: '\$ ',
            border: OutlineInputBorder(), isDense: true),
        ),
        const SizedBox(height: 6),
        Text('Pool: \$${_pool.toStringAsFixed(0)}  ($_numPlayers players)',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        PayoutPresetsRow(onPreset: _applyPoolPreset),
        const SizedBox(height: 8),
        PayoutConfigField(
          pool: _pool.round(),
          numPayouts: _numPayouts,
          payoutCtrls: _payoutCtrls,
          onNumPayoutsChanged: (n) => setState(() => _numPayouts = n),
          onPayoutChanged: () => setState(() {}),
          onSuggest: _suggest,
        ),
      ],
    );
  }
}
