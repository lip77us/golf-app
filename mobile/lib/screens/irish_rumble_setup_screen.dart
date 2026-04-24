/// screens/irish_rumble_setup_screen.dart
/// ----------------------------------------
/// Setup screen for the Irish Rumble tournament game (round-level).
///
/// Knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + Net % allowance
///   • Bet unit (winner-take-all dollar amount)
///
/// The segment structure is always the standard Irish Rumble format:
///   Holes 1–6   → best 1 net per group
///   Holes 7–12  → best 2 nets per group
///   Holes 13–17 → best 3 nets per group
///   Hole 18     → all 4 nets per group
///
/// A double-bogey cap (par + 2 max per hole) is always applied server-side.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

class IrishRumbleSetupScreen extends StatefulWidget {
  final int roundId;
  const IrishRumbleSetupScreen({super.key, required this.roundId});

  @override
  State<IrishRumbleSetupScreen> createState() => _IrishRumbleSetupScreenState();
}

class _IrishRumbleSetupScreenState extends State<IrishRumbleSetupScreen> {
  String _mode       = 'net';
  int    _netPercent = 100;
  final  _betCtrl    = TextEditingController(text: '5');

  bool    _loading         = true;
  bool    _saving          = false;
  Object? _error;
  bool    _configured      = false;
  /// True when this is a tournament round — handicap mode is locked at
  /// the round level and the picker is hidden in favour of a read-only chip.
  bool    _isTournamentRound = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final cfg    = await client.getIrishRumbleConfig(widget.roundId);
      if (!mounted) return;
      setState(() {
        _configured        = cfg['configured'] as bool? ?? false;
        _isTournamentRound = cfg['is_tournament_round'] as bool? ?? false;
        // For tournament rounds use the round-level mode; otherwise use the
        // stored game config value (which may differ for casual rounds).
        _mode       = (cfg['round_handicap_mode'] ?? cfg['handicap_mode'])
                          ?.toString() ?? 'net';
        _netPercent = (cfg['round_net_percent'] ?? cfg['net_percent']) as int? ?? 100;
        _betCtrl.text = _fmtAmount(cfg['bet_unit'] as num? ?? 5.0);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final betUnit = double.tryParse(_betCtrl.text.trim()) ?? 1.0;
      await client.postIrishRumbleSetup(
        widget.roundId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        betUnit:      betUnit,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true); // signal success to caller
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Irish Rumble — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _loading == false && !_saving
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : _buildBody(),
      bottomNavigationBar: _loading ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(
                      _configured ? 'Save Changes' : 'Save Setup',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Segment structure (read-only info) ──────────────────────────
          _SectionCard(
            title: 'Segment Structure',
            child: Column(
              children: [
                _SegmentRow('Holes 1–6',   'Best 1 net per group'),
                _SegmentRow('Holes 7–12',  'Best 2 nets per group'),
                _SegmentRow('Holes 13–17', 'Best 3 nets per group'),
                _SegmentRow('Hole 18',     'All 4 nets count'),
                const SizedBox(height: 8),
                Text(
                  'A double-bogey cap (par + 2 max) is applied to every '
                  'score before the best-N selection.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Handicap mode ───────────────────────────────────────────────
          // For tournament rounds the mode is locked at the round level.
          if (_isTournamentRound)
            _LockedHandicapChip(mode: _mode, netPercent: _netPercent)
          else
            _HandicapCard(
              mode:             _mode,
              netPercent:       _netPercent,
              onModeChanged:    (m) => setState(() => _mode = m),
              onPercentChanged: (p) => setState(() => _netPercent = p),
              soNote: 'Strokes are based on the lowest handicap across all '
                  'players in the tournament round — not just within each group.',
            ),

          const SizedBox(height: 16),

          // ── Bet unit ────────────────────────────────────────────────────
          _SectionCard(
            title: 'Bet',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _betCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Bet unit (\$)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                    isDense: true,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 8),
                Text(
                  'Winner-take-all. The group with the lowest cumulative '
                  'net-to-par total across all four segments wins.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          if (_error != null && _saving == false) ...[
            const SizedBox(height: 16),
            _ErrorBanner(message: friendlyError(_error!)),
          ],

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ── Low Net setup screen ─────────────────────────────────────────────────────

class LowNetSetupScreen extends StatefulWidget {
  final int roundId;
  const LowNetSetupScreen({super.key, required this.roundId});

  @override
  State<LowNetSetupScreen> createState() => _LowNetSetupScreenState();
}

class _LowNetSetupScreenState extends State<LowNetSetupScreen> {
  String _mode       = 'net';
  int    _netPercent = 100;
  final  _entryCtrl  = TextEditingController(text: '5');

  // Payout rows: each is a {place, amount} controller pair
  final List<TextEditingController> _payoutCtrls = [];
  int _payoutPlaces = 0;
  int _numPlayers   = 0; // fetched from API for pool-balance validation

  bool    _loading           = true;
  bool    _saving            = false;
  Object? _error;
  bool    _configured        = false;
  bool    _isTournamentRound = false;

  @override
  void initState() {
    super.initState();
    // Rebuild whenever entry fee changes so pool balance recalculates live.
    _entryCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  // ── Pool balance helpers ──────────────────────────────────────────────────

  double get _pool {
    final fee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
    return fee * _numPlayers;
  }

  double get _allocated =>
      _payoutCtrls.fold(0.0, (s, c) => s + (double.tryParse(c.text.trim()) ?? 0.0));

  /// True when payouts balance the pool (or there is no pool to balance).
  bool get _poolBalanced {
    if (_numPlayers == 0) return true;           // round not yet set up
    if (_pool <= 0) return true;                 // no entry fee → skip check
    if (_payoutPlaces == 0) return _pool == 0;   // no places → must be free
    return (_pool - _allocated).abs() < 0.01;
  }

  TextEditingController _makePayoutCtrl(String text) {
    final c = TextEditingController(text: text.isEmpty ? '0' : text);
    c.addListener(() => setState(() {})); // live pool-balance rebuild
    return c;
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final cfg    = await client.getLowNetConfig(widget.roundId);
      if (!mounted) return;

      final payouts = (cfg['payouts'] as List? ?? []);
      final ctrls   = <TextEditingController>[];
      for (final p in payouts) {
        // amount comes back as either num or String (depending on how it was
        // saved); parse defensively to avoid type-cast crashes.
        final amt = double.tryParse(p['amount']?.toString() ?? '') ?? 0.0;
        ctrls.add(_makePayoutCtrl(_fmtAmount(amt)));
      }

      setState(() {
        _configured        = cfg['configured'] as bool? ?? false;
        _isTournamentRound = cfg['is_tournament_round'] as bool? ?? false;
        // For tournament rounds the mode is locked at the round level;
        // fall back to the stored game config value for casual rounds.
        _mode              = (cfg['round_handicap_mode'] ?? cfg['handicap_mode'])
                                 ?.toString() ?? 'net';
        _netPercent        = (cfg['round_net_percent'] ?? cfg['net_percent']) as int? ?? 100;
        _numPlayers        = cfg['num_players'] as int? ?? 0;
        _entryCtrl.text    = _fmtAmount(cfg['entry_fee'] as num? ?? 5.0);
        _payoutPlaces      = ctrls.length;
        for (final c in _payoutCtrls) c.dispose();
        _payoutCtrls
          ..clear()
          ..addAll(ctrls);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  void _setPayoutPlaces(int n) {
    setState(() {
      while (_payoutCtrls.length < n) {
        _payoutCtrls.add(_makePayoutCtrl('0'));
      }
      while (_payoutCtrls.length > n) {
        _payoutCtrls.removeLast().dispose();
      }
      _payoutPlaces = n;
    });
  }

  Future<void> _save() async {
    if (!_poolBalanced) {
      setState(() {
        _error = Exception(
          'Payouts (\$${_allocated.toStringAsFixed(2)}) must equal the pool '
          '(\$${_pool.toStringAsFixed(2)}).',
        );
      });
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final client   = context.read<AuthProvider>().client;
      final entryFee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
      final payouts  = <Map<String, dynamic>>[];
      for (int i = 0; i < _payoutCtrls.length; i++) {
        final amt = double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0;
        // Send as a number, not a string, so the server round-trips it correctly.
        payouts.add({'place': i + 1, 'amount': amt});
      }
      await client.postLowNetSetup(
        widget.roundId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        entryFee:     entryFee,
        payouts:      payouts,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Low Net — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && !_loading && !_saving
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : _buildBody(),
      bottomNavigationBar: _loading ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: (_saving || !_poolBalanced) ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(
                      _configured ? 'Save Changes' : 'Save Setup',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Handicap mode ───────────────────────────────────────────────
          // For tournament rounds the mode is locked at the round level.
          if (_isTournamentRound)
            _LockedHandicapChip(mode: _mode, netPercent: _netPercent)
          else
            _HandicapCard(
              mode:             _mode,
              netPercent:       _netPercent,
              onModeChanged:    (m) => setState(() => _mode = m),
              onPercentChanged: (p) => setState(() => _netPercent = p),
              soNote: 'Strokes are based on the lowest handicap across all '
                  'players in the tournament round.',
            ),

          const SizedBox(height: 16),

          // ── Entry fee ───────────────────────────────────────────────────
          _SectionCard(
            title: 'Entry Fee',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _entryCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Entry fee per player (\$)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                    isDense: true,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 6),
                Text(
                  'Collected from each player before the round.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Payout structure ────────────────────────────────────────────
          _SectionCard(
            title: 'Payouts',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Places paid',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                // Place selector: 0–5
                // Use a Row of ToggleButtons so each segment gets equal
                // flex and the widget never overflows on narrow screens.
                LayoutBuilder(builder: (context, constraints) {
                  final segW = constraints.maxWidth / 6;
                  return ToggleButtons(
                    borderRadius: BorderRadius.circular(8),
                    constraints: BoxConstraints.tightFor(
                        width: segW, height: 40),
                    isSelected: List.generate(6, (i) => i == _payoutPlaces),
                    onPressed: _setPayoutPlaces,
                    children: const [
                      Text('0'), Text('1'), Text('2'),
                      Text('3'), Text('4'), Text('5'),
                    ],
                  );
                }),

                if (_payoutPlaces > 0) ...[
                  const SizedBox(height: 14),
                  ...List.generate(_payoutPlaces, (i) {
                    final ordinal = ['1st', '2nd', '3rd', '4th', '5th'][i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TextFormField(
                        controller: _payoutCtrls[i],
                        decoration: InputDecoration(
                          labelText: '$ordinal place payout (\$)',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.emoji_events_outlined),
                          isDense: true,
                        ),
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                      ),
                    );
                  }),
                  const SizedBox(height: 4),
                ],
                // ── Pool balance status ──────────────────────────────────
                if (_numPlayers > 0 && _pool > 0) ...[
                  const SizedBox(height: 8),
                  _PoolBalanceRow(
                    pool:      _pool,
                    allocated: _allocated,
                    balanced:  _poolBalanced,
                  ),
                ],
              ],
            ),
          ),

          if (_error != null && !_saving) ...[
            const SizedBox(height: 16),
            _ErrorBanner(message: friendlyError(_error!)),
          ],

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers + widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Format a monetary amount without unnecessary decimal places.
/// Whole numbers display as "5" not "5.00"; fractional as "5.50".
String _fmtAmount(num value) {
  final d = value.toDouble();
  return d == d.truncateToDouble() ? d.toInt().toString() : d.toStringAsFixed(2);
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 10),
          child,
        ]),
      ),
    );
  }
}

class _SegmentRow extends StatelessWidget {
  final String holes;
  final String rule;
  const _SegmentRow(this.holes, this.rule);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 100,
          child: Text(holes,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(rule,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

/// Read-only card shown instead of the handicap picker when this game is part
/// of a tournament round (the mode is locked at the round level).
class _LockedHandicapChip extends StatelessWidget {
  final String mode;
  final int    netPercent;

  const _LockedHandicapChip({required this.mode, required this.netPercent});

  String get _label {
    switch (mode) {
      case 'gross':       return 'Gross';
      case 'strokes_off': return 'Strokes Off Low';
      default:            return 'Net ($netPercent%)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Handicap',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.lock_outline,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Chip(
              label: Text(_label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              backgroundColor: theme.colorScheme.secondaryContainer,
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Set at the tournament round level — edit the round to change.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}

class _HandicapCard extends StatelessWidget {
  final String mode;
  final int    netPercent;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<int>    onPercentChanged;
  final String soNote;

  const _HandicapCard({
    required this.mode,
    required this.netPercent,
    required this.onModeChanged,
    required this.onPercentChanged,
    required this.soNote,
  });

  static const _presets = <int>[100, 90, 80, 75];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Handicap',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'net',         label: Text('Net')),
              ButtonSegment(value: 'gross',       label: Text('Gross')),
              ButtonSegment(value: 'strokes_off', label: Text('SO')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onModeChanged(s.first),
          ),
          if (mode == 'net') ...[
            const SizedBox(height: 12),
            Text('Handicap allowance',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8, runSpacing: 4,
              children: _presets.map((p) => ChoiceChip(
                label: Text('$p%'),
                selected: p == netPercent,
                onSelected: (_) => onPercentChanged(p),
              )).toList(),
            ),
          ] else if (mode == 'gross') ...[
            const SizedBox(height: 8),
            Text('No strokes given — raw gross scores are used.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ] else ...[
            const SizedBox(height: 8),
            Text(soNote,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }
}

class _PoolBalanceRow extends StatelessWidget {
  final double pool;
  final double allocated;
  final bool   balanced;

  const _PoolBalanceRow({
    required this.pool,
    required this.allocated,
    required this.balanced,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = pool - allocated;
    final color = balanced
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    final icon  = balanced ? Icons.check_circle_outline : Icons.error_outline;
    final label = balanced
        ? 'Pool balanced  (\$${pool.toStringAsFixed(2)})'
        : remaining > 0
            ? '\$${remaining.toStringAsFixed(2)} still unallocated  '
                '(pool \$${pool.toStringAsFixed(2)})'
            : '\$${(-remaining).toStringAsFixed(2)} over pool  '
                '(pool \$${pool.toStringAsFixed(2)})';

    return Row(children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 6),
      Expanded(
        child: Text(label,
            style: theme.textTheme.bodySmall?.copyWith(color: color)),
      ),
    ]);
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message,
              style: TextStyle(
                  color: theme.colorScheme.onErrorContainer)),
        ),
      ]),
    );
  }
}
