import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/golf_text_field.dart';

/// Staff-only screen for Pink Ball round-level configuration:
///   • Ball colour label (e.g. "Pink", "Red", "Yellow")
///   • Entry fee per foursome + explicit payout structure
///
/// The per-foursome hole rotation is set by each foursome on the Pink Ball
/// scoring screen before they start entering scores.
///
/// Route: /pink-ball-setup   arguments: int roundId
class PinkBallSetupScreen extends StatefulWidget {
  final int roundId;
  const PinkBallSetupScreen({super.key, required this.roundId});

  @override
  State<PinkBallSetupScreen> createState() => _PinkBallSetupScreenState();
}

class _PinkBallSetupScreenState extends State<PinkBallSetupScreen> {
  bool    _loading    = true;
  bool    _saving     = false;
  bool    _configured = false;
  String? _error;

  final _colorCtrl = TextEditingController(text: 'Pink');
  final _entryCtrl = TextEditingController(text: '0');

  // Payout rows: one controller per paid place.  Values are GROUP TOTALS —
  // the prize for finishing in that place, before splitting among the
  // winning group's members.  Per-player amounts are shown as derived
  // helper text under each field so users see what each group size pays.
  final List<TextEditingController> _payoutCtrls = [];
  int _payoutPlaces = 0;
  int _numPlayers = 0;
  /// Player count per foursome (e.g. [4, 3]) — drives the per-group-size
  /// per-player breakdown shown under each payout field.
  List<int> _groupSizes = const [];

  @override
  void initState() {
    super.initState();
    _entryCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _colorCtrl.dispose();
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

  bool get _poolBalanced {
    if (_numPlayers == 0) return true;
    if (_pool <= 0) return true;
    if (_payoutPlaces == 0) return _pool == 0;
    return (_pool - _allocated).abs() < 0.01;
  }

  /// Distinct foursome sizes in this round, sorted descending (foursome,
  /// threesome, …).  Used to compute the per-player payout breakdown.
  List<int> get _distinctGroupSizes {
    final set = _groupSizes.where((n) => n > 0).toSet().toList()..sort((a, b) => b.compareTo(a));
    return set;
  }

  /// Friendly noun for a group of [n] players ("foursome", "threesome", etc.).
  static String _groupSizeLabel(int n) {
    switch (n) {
      case 1: return 'solo';
      case 2: return 'twosome';
      case 3: return 'threesome';
      case 4: return 'foursome';
      default: return '$n-some';
    }
  }

  /// Helper-text line under a payout field showing the per-player split for
  /// each distinct group size, e.g. "Splits to $8.75/player (foursome) or
  /// $11.67/player (threesome)."  Returns null when the round has no
  /// configured groups yet, when the amount is zero, or when every group is
  /// the same size and the per-player number is just amount/N (still useful
  /// — we show that too).
  String? _perPlayerHelperFor(double amount) {
    if (amount <= 0) return null;
    final sizes = _distinctGroupSizes;
    if (sizes.isEmpty) return null;
    final parts = sizes
        .map((s) => '\$${(amount / s).toStringAsFixed(2)}/player '
            '(${_groupSizeLabel(s)})')
        .join(' • ');
    return 'Splits to $parts.';
  }

  TextEditingController _makePayoutCtrl(String text) {
    final c = TextEditingController(text: text.isEmpty ? '0' : text);
    c.addListener(() => setState(() {}));
    return c;
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getPinkBallSetup(widget.roundId);

      final payouts = (data['payouts'] as List? ?? []);
      final ctrls   = <TextEditingController>[];
      for (final p in payouts) {
        // Stored and displayed as the GROUP TOTAL prize for that place.
        // The per-player split is shown as helper text in the UI.
        final amt = double.tryParse(p['amount']?.toString() ?? '') ?? 0.0;
        ctrls.add(_makePayoutCtrl(_fmtAmount(amt)));
      }

      final fee = (data['entry_fee'] as num?) ?? 0.0;
      // Derive group sizes from the foursomes array so the per-player
      // breakdown helper text knows how to split each prize.
      final foursomes = (data['foursomes'] as List? ?? []);
      final groupSizes = foursomes
          .map((fs) {
            final players = (fs as Map<String, dynamic>)['players'] as List? ?? [];
            return players.length;
          })
          .cast<int>()
          .toList();
      setState(() {
        _colorCtrl.text = data['ball_color'] as String? ?? 'Pink';
        _entryCtrl.text = _fmtAmount(fee);
        _numPlayers     = data['num_players'] as int? ?? 0;
        _groupSizes     = groupSizes;
        _payoutPlaces   = ctrls.length;
        _configured     = ctrls.isNotEmpty || fee > 0;
        for (final c in _payoutCtrls) c.dispose();
        _payoutCtrls
          ..clear()
          ..addAll(ctrls);
        _loading = false;
      });
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
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

  /// Apply a quick-fill preset.  [ratios] must sum to 1.0.
  /// Amounts are calculated from the total pool as group-total prizes; the
  /// last place gets the remainder so rounding never leaves the pool
  /// unbalanced.
  void _applyPreset(List<double> ratios) {
    final fee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
    if (fee <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an entry fee first.')),
      );
      return;
    }
    if (_numPlayers == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No players registered yet — pool cannot be calculated. '
              'You can still set payouts manually.'),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }
    final pool = _pool;
    setState(() {
      final n = ratios.length;
      while (_payoutCtrls.length < n) _payoutCtrls.add(_makePayoutCtrl('0'));
      while (_payoutCtrls.length > n) _payoutCtrls.removeLast().dispose();
      _payoutPlaces = n;
      double remaining = pool;
      for (int i = 0; i < n; i++) {
        final amt = i < n - 1 ? (pool * ratios[i]) : remaining;
        remaining -= amt;
        _payoutCtrls[i].text = _fmtAmount(amt);
      }
    });
  }

  Future<void> _save() async {
    if (!_poolBalanced) {
      setState(() {
        _error = 'Payouts total \$${_allocated.toStringAsFixed(2)}, '
            'pool is \$${_pool.toStringAsFixed(2)}.';
      });
      return;
    }
    final entryFee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
    final color    = _colorCtrl.text.trim().isEmpty ? 'Pink' : _colorCtrl.text.trim();
    final payouts  = <Map<String, dynamic>>[];
    for (int i = 0; i < _payoutCtrls.length; i++) {
      // Stored as the group total prize for that place — split among the
      // winning group's members at payout time.
      final groupTotal = double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0;
      payouts.add({'place': i + 1, 'amount': groupTotal});
    }

    setState(() { _saving = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.postPinkBallSetup(
        widget.roundId,
        ballColor: color,
        entryFee:  entryFee,
        payouts:   payouts,
      );
      if (!mounted) return;
      context.read<RoundProvider>().loadRound(widget.roundId);
      // Pop with `true` so the wizard's _Step6GameSetup knows to flip
      // the Configure Pink Ball icon from empty-circle to filled-flag.
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() { _saving = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pink Ball Setup'),
      ),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Ball colour + entry fee ──────────────────────────────
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Game Settings',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),

                        GolfTextField(
                          controller: _colorCtrl,
                          label: 'Ball Colour',
                          hint: 'e.g. Pink, Red, Yellow',
                          textCapitalization: TextCapitalization.words,
                        ),
                        const SizedBox(height: 12),

                        GolfTextField(
                          controller: _entryCtrl,
                          label: 'Entry fee per player (\$)',
                          hint: '0',
                          prefixText: '\$ ',
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Collected from each player. '
                          'Total pool = entry fee × number of players.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── Payout structure ─────────────────────────────────────
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Payouts',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('Places paid',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 8),

                        LayoutBuilder(builder: (context, constraints) {
                          final segW = ((constraints.maxWidth - 7) / 6).floorToDouble();
                          return ToggleButtons(
                            borderRadius: BorderRadius.circular(8),
                            constraints: BoxConstraints.tightFor(
                                width: segW, height: 40),
                            isSelected:
                                List.generate(6, (i) => i == _payoutPlaces),
                            onPressed: _setPayoutPlaces,
                            children: const [
                              Text('0'), Text('1'), Text('2'),
                              Text('3'), Text('4'), Text('5'),
                            ],
                          );
                        }),

                        // ── Suggested payout presets ─────────────────────
                        const SizedBox(height: 10),
                        _PayoutPresetsRow(onPreset: _applyPreset),

                        if (_payoutPlaces > 0) ...[
                          const SizedBox(height: 14),
                          ...List.generate(_payoutPlaces, (i) {
                            final ordinal =
                                ['1st', '2nd', '3rd', '4th', '5th'][i];
                            final amount = double.tryParse(
                                _payoutCtrls[i].text.trim()) ?? 0.0;
                            final helper = _perPlayerHelperFor(amount);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  GolfTextField(
                                    controller: _payoutCtrls[i],
                                    label: '$ordinal place payout',
                                    prefixIcon: Icons.emoji_events_outlined,
                                    keyboardType: const TextInputType
                                        .numberWithOptions(decimal: true),
                                  ),
                                  if (helper != null) ...[
                                    const SizedBox(height: 4),
                                    Padding(
                                      padding: const EdgeInsets.only(left: 12),
                                      child: Text(
                                        helper,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                                color: theme.colorScheme
                                                    .onSurfaceVariant),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }),
                          const SizedBox(height: 4),
                        ],

                        if (_numPlayers == 0 && (double.tryParse(_entryCtrl.text.trim()) ?? 0) > 0) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            Icon(Icons.info_outline, size: 16,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Pool depends on number of players — set payouts manually '
                                'or use presets after players register.',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ]),
                        ] else if (_numPlayers > 0 && _pool > 0) ...[
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
                ),

                const SizedBox(height: 16),

                // ── Info note ────────────────────────────────────────────
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Icon(Icons.info_outline,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Each group sets their own ball rotation when '
                          'they open the scoring screen for the first time.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ]),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: TextStyle(
                                color: theme.colorScheme.onErrorContainer)),
                      ),
                    ]),
                  ),
                ],

                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Suggested payout preset row
// ---------------------------------------------------------------------------

class _PayoutPresetsRow extends StatelessWidget {
  final void Function(List<double> ratios) onPreset;
  const _PayoutPresetsRow({required this.onPreset});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final btnStyle = TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12),
    );

    Widget chip(String label, List<double> ratios) => TextButton(
          style: btnStyle,
          onPressed: () => onPreset(ratios),
          child: Text(label),
        );

    return Row(
      children: [
        Text('Suggested:', style: muted),
        const SizedBox(width: 2),
        chip('Winner takes all', [1.0]),
        Text('·', style: muted),
        chip('60/40', [0.6, 0.4]),
        Text('·', style: muted),
        chip('60/30/10', [0.6, 0.3, 0.1]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pool balance indicator
// ---------------------------------------------------------------------------

String _fmtAmount(num value) {
  final d = value.toDouble();
  return d == d.truncateToDouble() ? d.toInt().toString() : d.toStringAsFixed(2);
}

class _PoolBalanceRow extends StatelessWidget {
  final double pool;
  final double allocated;
  final bool   balanced;
  final bool   perPlayer;

  const _PoolBalanceRow({
    required this.pool,
    required this.allocated,
    required this.balanced,
    this.perPlayer = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final remaining = pool - allocated;
    final suffix    = perPlayer ? '/player' : '';
    final color = balanced
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    final icon  = balanced ? Icons.check_circle_outline : Icons.error_outline;
    final label = balanced
        ? 'Pool balanced  (\$${pool.toStringAsFixed(2)}$suffix)'
        : remaining > 0
            ? '\$${remaining.toStringAsFixed(2)}$suffix still unallocated  '
                '(pool \$${pool.toStringAsFixed(2)}$suffix)'
            : '\$${(-remaining).toStringAsFixed(2)}$suffix over pool  '
                '(pool \$${pool.toStringAsFixed(2)}$suffix)';

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
