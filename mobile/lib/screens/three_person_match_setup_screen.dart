/// screens/three_person_match_setup_screen.dart
/// -----------------------------------------------
/// Setup screen for the Three-Person Match tournament game.
///
/// Nine holes of Points 5-3-1 scoring.  Final standings are determined
/// by cumulative points after hole 9.  Ties stand as ties — there is no
/// play-off extension.
///
/// This screen collects:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + allowance %
///   • Per-player entry fee and place payouts (1st / 2nd / 3rd)
///
/// Redirects to /score-entry immediately if the game is already running.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';

class ThreePersonMatchSetupScreen extends StatefulWidget {
  final int foursomeId;
  const ThreePersonMatchSetupScreen({super.key, required this.foursomeId});

  @override
  State<ThreePersonMatchSetupScreen> createState() =>
      _ThreePersonMatchSetupScreenState();
}

class _ThreePersonMatchSetupScreenState
    extends State<ThreePersonMatchSetupScreen> {
  ThreePersonMatchSummary? _summary;
  bool    _loading = true;
  bool    _saving  = false;
  Object? _error;

  // Form state
  String _mode       = 'net';
  int    _netPercent = 100;

  final _entryFeeCtrl = TextEditingController(text: '0.00');
  final _payoutCtrls  = <String, TextEditingController>{
    '1st': TextEditingController(text: '0.00'),
    '2nd': TextEditingController(text: '0.00'),
    '3rd': TextEditingController(text: '0.00'),
  };

  @override
  void initState() {
    super.initState();
    _load();
    _entryFeeCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _entryFeeCtrl.dispose();
    for (final c in _payoutCtrls.values) c.dispose();
    super.dispose();
  }

  // ── Derived ───────────────────────────────────────────────────────────────

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  bool get _rosterValid => _realMembers.length == 3;

  double get _entryFee =>
      double.tryParse(_entryFeeCtrl.text.trim()) ?? 0.0;

  double get _pool => _entryFee * (_rosterValid ? 3 : 3);

  double get _payoutTotal => _payoutCtrls.values
      .map((c) => double.tryParse(c.text.trim()) ?? 0.0)
      .fold(0.0, (a, b) => a + b);

  // ── Load / Save ───────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      _summary = await client.getThreePersonMatch(widget.foursomeId);
      if (!mounted) return;

      // Already in progress — skip setup.
      if (_summary!.status != 'pending') {
        Navigator.of(context).pushReplacementNamed(
            '/score-entry', arguments: widget.foursomeId);
        return;
      }

      // Pre-populate from existing config.
      setState(() {
        _mode       = _summary!.handicapMode;
        _netPercent = _summary!.netPercent;
        final money = _summary!.money;
        final fee   = (money['entry_fee'] as num?)?.toDouble() ?? 0.0;
        if (fee > 0) {
          _entryFeeCtrl.text = fee.toStringAsFixed(2);
          final cfg = (money['payout_config'] as Map<String, dynamic>?) ?? {};
          for (final place in ['1st', '2nd', '3rd']) {
            final amt = (cfg[place] as num?)?.toDouble() ?? 0.0;
            _payoutCtrls[place]!.text = amt.toStringAsFixed(2);
          }
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404) {
        // Game not yet configured — show the setup form with defaults.
        setState(() { _loading = false; });
      } else {
        setState(() { _error = e; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  void _suggestPayouts() {
    if (_pool <= 0) return;
    // 60 / 30 / 10 split (3-player)
    _payoutCtrls['1st']!.text = (_pool * 0.60).toStringAsFixed(2);
    _payoutCtrls['2nd']!.text = (_pool * 0.30).toStringAsFixed(2);
    _payoutCtrls['3rd']!.text = (_pool * 0.10).toStringAsFixed(2);
    setState(() {});
  }

  Future<void> _save() async {
    if (!_rosterValid) return;
    setState(() { _saving = true; _error = null; });
    try {
      final payouts = <String, double>{};
      for (final e in _payoutCtrls.entries) {
        payouts[e.key] = double.tryParse(e.value.text.trim()) ?? 0.0;
      }

      final rp = context.read<RoundProvider>();
      final ok = await rp.setupThreePersonMatch(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        entryFee:     _entryFee,
        payoutConfig: payouts,
      );

      if (!mounted) return;
      if (ok) {
        // Reload round so configuredGames is up to date, then navigate.
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        // If this is a Pink Ball round, go to the pink ball screen.
        final round = rp.round;
        final dest  = (round?.activeGames.contains('pink_ball') == true)
            ? '/pink-ball'
            : '/score-entry';
        Navigator.of(context).pushReplacementNamed(dest,
            arguments: widget.foursomeId);
      } else {
        setState(() { _saving = false; _error = rp.error; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Three-Person Match — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _summary == null
              ? ErrorView(
                  message:   friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry:   _load,
                )
              : _buildBody(),
      bottomNavigationBar: _loading ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    friendlyError(_error!),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              SizedBox(
                width: double.infinity, height: 52,
                child: FilledButton(
                  onPressed: (_saving || !_rosterValid) ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Start Match',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
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
          _RosterCard(members: _realMembers),
          const SizedBox(height: 16),
          _HandicapCard(
            mode:             _mode,
            netPercent:       _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),
          const SizedBox(height: 16),
          _entryFeeCard(theme),
          const SizedBox(height: 16),
          _payoutsCard(theme),
          const SizedBox(height: 16),
          _rulesCard(theme),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  // ── Section widgets ───────────────────────────────────────────────────────

  Widget _entryFeeCard(ThemeData theme) => _section(
    theme, 'Entry Fee',
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextFormField(
        controller: _entryFeeCtrl,
        decoration: const InputDecoration(
          labelText:   'Per player (\$)',
          border:      OutlineInputBorder(),
          prefixIcon:  Icon(Icons.attach_money),
          isDense:     true,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
      if (_pool > 0) ...[
        const SizedBox(height: 6),
        Text(
          'Prize pool: \$${_pool.toStringAsFixed(2)} (3 players)',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    ]),
  );

  Widget _payoutsCard(ThemeData theme) {
    final remaining = _pool - _payoutTotal;
    final balanced  = remaining.abs() < 0.01 || _pool == 0;
    return _section(
      theme, 'Payouts',
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final place in ['1st', '2nd', '3rd']) ...[
          Row(children: [
            SizedBox(
              width: 32,
              child: Text(place,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _payoutCtrls[place],
                decoration: const InputDecoration(
                  prefixText: '\$ ',
                  border:     OutlineInputBorder(),
                  isDense:    true,
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          const SizedBox(height: 8),
        ],
        if (_pool > 0) ...[
          const Divider(height: 12),
          Row(children: [
            Expanded(
              child: Text(
                balanced
                    ? 'Payouts balance ✓'
                    : 'Remaining: \$${remaining.toStringAsFixed(2)}',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: balanced
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: _suggestPayouts,
              child: const Text('Auto-suggest (60/30/10)'),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _rulesCard(ThemeData theme) => _section(
    theme, 'How it works',
    Text(
      'Holes 1–9: Points 5-3-1 per hole (5 pts to best net score, '
      '3 to 2nd, 1 to 3rd; ties split evenly so every hole pays 9 pts total).\n\n'
      'After hole 9, the player with the most cumulative points finishes 1st, '
      'second-most finishes 2nd, fewest finishes 3rd.\n\n'
      'Ties stand as ties — tied players share the combined payout for '
      'their tied positions.',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    ),
  );

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _section(ThemeData theme, String title, Widget child) => Card(
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: theme.colorScheme.outline),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

// ===========================================================================
// _RosterCard
// ===========================================================================

class _RosterCard extends StatelessWidget {
  final List<Membership> members;
  const _RosterCard({required this.members});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok    = members.length == 3;
    final color = ok ? theme.colorScheme.primary : theme.colorScheme.error;

    return Card(
      elevation: 0,
      color: color.withOpacity(0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.people_alt_outlined : Icons.error_outline,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ok
                        ? 'Three-Person Match — ready to configure.'
                        : 'Three-Person Match requires exactly 3 real players.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600, color: color),
                  ),
                  if (members.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      members
                          .map((m) => '${m.player.displayShort} '
                              '(HCP ${m.playingHandicap})')
                          .join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Final standings determined by 9-hole 5-3-1 points.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// _HandicapCard
// ===========================================================================

class _HandicapCard extends StatelessWidget {
  final String mode;
  final int    netPercent;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<int>    onPercentChanged;

  const _HandicapCard({
    required this.mode,
    required this.netPercent,
    required this.onModeChanged,
    required this.onPercentChanged,
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
          const SizedBox(height: 8),
          Text(
            'Applies to all 9 holes of 5-3-1 scoring.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
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
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8, runSpacing: 4,
              children: _presets.map((p) => ChoiceChip(
                label:    Text('$p%'),
                selected: p == netPercent,
                onSelected: (_) => onPercentChanged(p),
              )).toList(),
            ),
          ] else if (mode == 'gross') ...[
            const SizedBox(height: 8),
            Text('No strokes given — raw gross scores compared.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              'Lowest-handicap player plays to 0.  Each other player receives '
              '(own HCP − low HCP) strokes, allocated by stroke index.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}
