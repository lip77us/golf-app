/// screens/stableford_setup_screen.dart
/// Casual Stableford setup: handicap (Net% or Gross — no Strokes-Off), an
/// editable 6-bucket points table with three presets, and Low-Net-style money
/// (entry fee + paid places via the shared PayoutConfigField).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../utils/primary_handicap.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/inherited_handicap_note.dart';
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

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const StablefordSetupScreen({
    super.key,
    required this.roundId,
    this.returnToHub = false,
  });

  @override
  State<StablefordSetupScreen> createState() => _StablefordSetupScreenState();
}

class _StablefordSetupScreenState extends State<StablefordSetupScreen> {
  int _step = 0; // 0 = handicap + points, 1 = payout
  String _mode = 'net';
  int _netPercent = 100;

  String _payoutStyle = 'pool';        // 'pool' | 'per_point'
  String _perPointMode = 'average';    // 'average' | 'all' | 'first'
  final _entryCtrl  = TextEditingController(text: '5');
  final _rateCtrl   = TextEditingController(text: '1'); // $/point (per_point)
  bool _noStakes = false;
  int _numPlayers = 0;

  // Optional per-player loss cap (per_point only). Off by default — unlike
  // 5-3-1 the points table is editable, so there's no fixed "max loss" to
  // pre-fill; the player opts in and sets an amount.
  bool _capEnabled = false;
  final _capCtrl = TextEditingController();

  final _points = {for (final b in _kBuckets) b: TextEditingController()};

  final _payoutCtrls =
      List<TextEditingController>.generate(4, (_) => TextEditingController());
  int _numPayouts = 0;

  bool _loading = true;
  bool _saving  = false;
  /// True when editing an already-configured game (drives Save label + title).
  bool _editing = false;
  Object? _error;

  /// True when Stableford is a SECONDARY side game (another game owns entry).
  /// Side games inherit the primary's handicap — no own selector.
  bool get _isSideGame {
    final round = context.read<RoundProvider>().round;
    final games = round?.activeGames ?? const <String>[];
    return games.contains('stableford') &&
        resolvePrimary(round?.primaryGame, games) != 'stableford';
  }

  @override
  void initState() {
    super.initState();
    _entryCtrl.addListener(_onStakeChanged);
    _rateCtrl.addListener(_onStakeChanged);
    _load();
  }

  /// Re-evaluate the Start gate as the active stake field changes; entering a
  /// real amount clears the "no stakes" opt-in.
  void _onStakeChanged() {
    final ctrl = _payoutStyle == 'pool' ? _entryCtrl : _rateCtrl;
    if ((double.tryParse(ctrl.text.trim()) ?? 0) > 0 && _noStakes) {
      _noStakes = false;
    }
    setState(() {});
  }

  /// Start gate: a positive entry fee (pool) or rate (per-point) entered, or
  /// "no stakes" ticked.
  bool get _stakeChosen {
    if (_noStakes) return true;
    final ctrl = _payoutStyle == 'pool' ? _entryCtrl : _rateCtrl;
    return (double.tryParse(ctrl.text.trim()) ?? 0) > 0;
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _rateCtrl.dispose();
    _capCtrl.dispose();
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
      final client = context.read<AuthProvider>().client;
      final cfg = await client.getStablefordConfig(widget.roundId);

      // Side games inherit the PRIMARY game's handicap. Stableford only does
      // net/gross, so a strokes-off primary degrades to net here.
      (String, int)? inherited;
      if (_isSideGame) {
        final round = context.read<RoundProvider>().round;
        final fsId = round?.foursomes.isNotEmpty == true
            ? round!.foursomes.first.id : null;
        if (round != null && fsId != null) {
          final h = await primaryHandicapFor(client, round, fsId);
          inherited = (h.$1 == 'gross' ? 'gross' : 'net', h.$2);
        }
      }
      if (!mounted) return;
      setState(() {
        _numPlayers = cfg['num_players'] as int? ?? 0;
        final mode = (cfg['handicap_mode']?.toString() ?? 'net');
        _mode = (mode == 'gross') ? 'gross' : 'net';
        _netPercent = cfg['net_percent'] as int? ?? 100;
        if (inherited != null) {
          _mode       = inherited.$1;
          _netPercent = inherited.$2;
        }
        _payoutStyle = (cfg['payout_style']?.toString() == 'per_point')
            ? 'per_point' : 'pool';
        final ppm = cfg['per_point_mode']?.toString();
        _perPointMode = (ppm == 'first' || ppm == 'all') ? ppm! : 'average';
        final cap = (cfg['loss_cap'] as num?)?.toDouble();
        _capEnabled = cap != null;
        if (cap != null) _capCtrl.text = _fmt(cap);
        _rateCtrl.text   = _fmt(cfg['per_point_rate'] as num? ?? 1);
        _entryCtrl.text  = _fmt(cfg['entry_fee'] as num? ?? 5);
        for (final b in _kBuckets) {
          _points[b]!.text = '${cfg['pts_$b'] ?? _kPresets['Standard']![b]}';
        }
        final payouts = (cfg['payouts'] as List? ?? []);
        // A configured Stableford game persists a payout structure; a fresh
        // round comes back with none. Non-empty payouts is the "already set
        // up" tell → enter edit mode (Save Configuration / "Edit Stableford").
        _editing = payouts.isNotEmpty;
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
      // Capture the provider before any await so we don't touch context
      // across the async gap in the returnToHub branch below.
      final rp = context.read<RoundProvider>();
      final payouts = <Map<String, dynamic>>[
        for (var i = 0; i < _numPayouts; i++)
          {'place': i + 1,
           'amount': double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0},
      ];
      await context.read<AuthProvider>().client.postStablefordSetup(
        widget.roundId,
        handicapMode: _mode,
        netPercent: _netPercent,
        payoutStyle: _payoutStyle,
        perPointRate: double.tryParse(_rateCtrl.text.trim()) ?? 0.0,
        perPointMode: _perPointMode,
        lossCap: (_payoutStyle == 'per_point' && _capEnabled)
            ? double.tryParse(_capCtrl.text.trim())
            : null,
        entryFee: double.tryParse(_entryCtrl.text.trim()) ?? 0.0,
        payouts: payouts,
        pointsTable: {
          for (final b in _kBuckets) b: int.tryParse(_points[b]!.text.trim()) ?? 0,
        },
      );
      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": return to the launch page
        // sitting below us. Reload the round first so the hub reflects the
        // freshly-saved game, then pop — popping (rather than pushing) keeps a
        // single hub on the stack.
        await rp.loadRound(widget.roundId);
        if (!mounted) return;
        Navigator.of(context).pop();
        return;
      }
      if (!mounted) return;
      // Jump straight to scoring, like the per-foursome games (5-3-1, Sixes…),
      // so the flow is consistent — there's no reconfigure step to come back
      // for. Stableford is round-level; a casual round has one foursome.
      final fs = rp.round?.foursomes;
      if (fs != null && fs.isNotEmpty) {
        Navigator.of(context)
            .pushReplacementNamed('/score-entry', arguments: fs.first.id);
      } else {
        Navigator.of(context).pop(true);   // fallback: no foursome loaded
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(
          _editing
              ? 'Edit Stableford'
              : (_step == 0 ? 'Stableford · Scoring' : 'Stableford · Payout'))),
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
            onPressed: (_saving || !_stakeChosen) ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_editing ? 'Save Configuration' : 'Save Setup',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
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
        // ── Handicap (Net%/Gross — shared slider widget, no Strokes-Off) ──
        // Side games inherit the primary game's handicap (no own selector).
        if (_isSideGame)
          InheritedHandicapNote(mode: _mode, netPercent: _netPercent)
        else
          HandicapModeSelector(
            mode: _mode,
            netPercent: _netPercent,
            allowStrokesOff: false,
            onModeChanged: (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),
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
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'pool', label: Text('Pool')),
            ButtonSegment(value: 'per_point', label: Text('Per point')),
          ],
          selected: {_payoutStyle},
          onSelectionChanged: (s) => setState(() => _payoutStyle = s.first),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Play for fun — no stakes'),
          value: _noStakes,
          onChanged: (v) => setState(() {
            _noStakes = v ?? false;
            if (_noStakes) { _entryCtrl.text = '0'; _rateCtrl.text = '0'; }
          }),
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
          const SizedBox(height: 8),
          PayoutConfigField(
            pool: _pool.round(),
            numPayouts: _numPayouts,
            payoutCtrls: _payoutCtrls,
            onNumPayoutsChanged: (n) => setState(() => _numPayouts = n),
            onPayoutChanged: () => setState(() {}),
            onSuggest: _suggest,
          ),
        ] else ...[
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'average', label: Text('vs Average')),
              ButtonSegment(value: 'all',     label: Text('Above you')),
              ButtonSegment(value: 'first',   label: Text('Just first')),
            ],
            selected: {_perPointMode},
            onSelectionChanged: (s) => setState(() => _perPointMode = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            switch (_perPointMode) {
              'first' => 'Only the leader collects — everyone else pays the '
                  'leader their points deficit at this rate per point.',
              'all' => 'You pay everyone above you (and collect from everyone '
                  'below) at this rate per point of difference.',
              _ => 'Standard: settle against the field average. Every point '
                  'above the average wins; every point below owes — at this '
                  'rate per point.',
            },
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
          const SizedBox(height: 12),
          // Optional per-player loss cap.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Cap losses'),
            subtitle: Text(
              _capEnabled
                  ? 'Nobody loses more than the amount below; winners share '
                    'what’s collected, pro-rata.'
                  : 'Off — per-point losses are uncapped.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            value: _capEnabled,
            onChanged: (v) => setState(() => _capEnabled = v),
          ),
          if (_capEnabled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: 180,
                child: TextField(
                  controller: _capCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Max loss per player', prefixText: '\$ ',
                    border: OutlineInputBorder(), isDense: true),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
