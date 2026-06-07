/// screens/stableford_setup_screen.dart
/// Casual Stableford setup: handicap (Net% or Gross — no Strokes-Off), an
/// editable 6-bucket points table with three presets, and Low-Net-style money
/// (entry fee + paid places via the shared PayoutConfigField).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/payout_config_field.dart';

// Bucket order, top (best) to bottom.
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

class StablefordSetupScreen extends StatefulWidget {
  final int roundId;
  const StablefordSetupScreen({super.key, required this.roundId});

  @override
  State<StablefordSetupScreen> createState() => _StablefordSetupScreenState();
}

class _StablefordSetupScreenState extends State<StablefordSetupScreen> {
  int _step = 0; // 0 = handicap + points, 1 = payout
  String _mode = 'net';
  final _netPctCtrl = TextEditingController(text: '100');

  String _payoutStyle = 'pool';        // 'pool' | 'per_point'
  final _entryCtrl  = TextEditingController(text: '5');
  final _rateCtrl   = TextEditingController(text: '1'); // $/point (per_point)
  int _numPlayers = 0;

  final _points = {for (final b in _kBuckets) b: TextEditingController()};

  final _payoutCtrls =
      List<TextEditingController>.generate(4, (_) => TextEditingController());
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
    _netPctCtrl.dispose();
    _entryCtrl.dispose();
    _rateCtrl.dispose();
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
          .getStablefordConfig(widget.roundId);
      if (!mounted) return;
      setState(() {
        _numPlayers = cfg['num_players'] as int? ?? 0;
        final mode = (cfg['handicap_mode']?.toString() ?? 'net');
        _mode = (mode == 'gross') ? 'gross' : 'net';
        _netPctCtrl.text = '${cfg['net_percent'] ?? 100}';
        _payoutStyle = (cfg['payout_style']?.toString() == 'per_point')
            ? 'per_point' : 'pool';
        _rateCtrl.text   = _fmt(cfg['per_point_rate'] as num? ?? 1);
        _entryCtrl.text  = _fmt(cfg['entry_fee'] as num? ?? 5);
        for (final b in _kBuckets) {
          _points[b]!.text = '${cfg['pts_$b'] ?? _kPresets['Standard']![b]}';
        }
        final payouts = (cfg['payouts'] as List? ?? []);
        if (payouts.isEmpty) {
          // Fresh round → default to winner-take-all so the pool is visibly
          // allocated; the user bumps places / re-suggests from there.
          final pool = (double.tryParse(_entryCtrl.text.trim()) ?? 0) * _numPlayers;
          _numPayouts = 1;
          _payoutCtrls[0].text = _fmt(pool);
          for (var i = 1; i < 4; i++) _payoutCtrls[i].text = '0';
        } else {
          _numPayouts = payouts.length.clamp(0, 4);
          for (var i = 0; i < 4; i++) {
            _payoutCtrls[i].text = i < payouts.length
                ? _fmt(double.tryParse(payouts[i]['amount']?.toString() ?? '') ?? 0)
                : '0';
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  String _fmt(num n) => n == n.roundToDouble() ? n.toInt().toString() : '$n';

  void _applyPreset(Map<String, int> table) {
    setState(() {
      for (final b in _kBuckets) _points[b]!.text = '${table[b]}';
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
      await context.read<AuthProvider>().client.postStablefordSetup(
        widget.roundId,
        handicapMode: _mode,
        netPercent: int.tryParse(_netPctCtrl.text.trim()) ?? 100,
        payoutStyle: _payoutStyle,
        perPointRate: double.tryParse(_rateCtrl.text.trim()) ?? 0.0,
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
      appBar: AppBar(title: Text(
          _step == 0 ? 'Stableford · Scoring' : 'Stableford · Payout')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && !_saving)
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load)
              : Column(children: [
                  Expanded(child: _step == 0 ? _scoringBody() : _payoutBody()),
                  SafeArea(top: false, child: _nav()),
                ]),
    );
  }

  Widget _nav() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(children: [
        if (_step == 1)
          OutlinedButton(
            onPressed: _saving ? null : () => setState(() => _step = 0),
            child: const Text('Back'),
          ),
        const Spacer(),
        if (_step == 0)
          FilledButton(
            onPressed: () => setState(() => _step = 1),
            child: const Text('Next'),
          )
        else
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Save Setup',
                    style: TextStyle(fontWeight: FontWeight.bold)),
          ),
      ]),
    );
  }

  // ── Step 1: handicap + points table ──
  Widget _scoringBody() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Handicap ──
        Text('Handicap', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'net', label: Text('Net')),
            ButtonSegment(value: 'gross', label: Text('Gross')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        if (_mode == 'net') ...[
          const SizedBox(height: 12),
          SizedBox(
            width: 160,
            child: TextField(
              controller: _netPctCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Handicap %', suffixText: '%',
                border: OutlineInputBorder(), isDense: true),
            ),
          ),
        ],
        const SizedBox(height: 24),

        // ── Points table ──
        Text('Points table', style: theme.textTheme.titleMedium),
        Text('Points awarded per hole by score vs par. Negatives allowed.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in _kPresets.entries)
              ActionChip(
                label: Text(entry.key),
                onPressed: () => _applyPreset(entry.value),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (final b in _kBuckets)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(_kBucketLabels[b]!)),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _points[b],
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
                    ],
                    decoration: const InputDecoration(
                        border: OutlineInputBorder(), isDense: true),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── Step 2: payout ──
  Widget _payoutBody() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('How is the money settled?', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'pool', label: Text('Pool')),
            ButtonSegment(value: 'per_point', label: Text('Per point')),
          ],
          selected: {_payoutStyle},
          onSelectionChanged: (s) => setState(() => _payoutStyle = s.first),
        ),
        const SizedBox(height: 16),

        if (_payoutStyle == 'pool') ...[
          Text('Everyone antes the entry fee; the pool is split among the '
              'paid places.', style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
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
          const SizedBox(height: 12),
          PayoutConfigField(
            pool: _pool.round(),
            numPayouts: _numPayouts,
            payoutCtrls: _payoutCtrls,
            onNumPayoutsChanged: (n) => setState(() => _numPayouts = n),
            onPayoutChanged: () => setState(() {}),
            onSuggest: _suggest,
          ),
        ] else ...[
          Text('No pool — you pay everyone above you (and collect from everyone '
              'below) at this rate per point of difference.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          SizedBox(
            width: 180,
            child: TextField(
              controller: _rateCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Rate per point', prefixText: '\$ ',
                border: OutlineInputBorder(), isDense: true),
            ),
          ),
        ],
      ],
    );
  }
}
