import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/payout_config_field.dart';

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
  final _entryCtrl = TextEditingController();

  // Payout rows: a fixed 4 controllers (only the first [_payoutPlaces] are
  // active), matching the shared PayoutConfigField. Values are GROUP TOTALS —
  // the prize for finishing in that place, before splitting among the winning
  // group's members. Per-player amounts show as a breakdown under each field.
  final List<TextEditingController> _payoutCtrls =
      List.generate(4, (_) => TextEditingController());
  int _payoutPlaces = 1;
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

  double get _allocated => _payoutCtrls
      .take(_payoutPlaces)
      .fold(0.0, (s, c) => s + (double.tryParse(c.text.trim()) ?? 0.0));

  bool get _poolBalanced {
    if (_numPlayers == 0) return true;
    if (_pool <= 0) return true;
    // Integer-dollar payouts (shared widget) — compare on rounded dollars.
    return _pool.round() == _allocated.round();
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

  /// Fill the active places with the shared suggested split of the pool.
  void _suggest() {
    final pool = _pool.round();
    if (pool <= 0) return;
    final amts = suggestPayouts(pool, _payoutPlaces);
    setState(() {
      for (int i = 0; i < _payoutPlaces; i++) {
        _payoutCtrls[i].text = amts[i] == 0 ? '' : '${amts[i]}';
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getPinkBallSetup(widget.roundId);

      final payouts = (data['payouts'] as List? ?? []);
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
        _entryCtrl.text = fee > 0 ? _fmtAmount(fee) : '';
        _numPlayers     = data['num_players'] as int? ?? 0;
        _groupSizes     = groupSizes;
        // Fill the fixed 4 controllers; derive the active place count from the
        // highest non-zero payout (group totals).
        int places = 0;
        for (int i = 0; i < 4; i++) {
          final amt = i < payouts.length
              ? (double.tryParse(payouts[i]['amount']?.toString() ?? '') ?? 0.0)
              : 0.0;
          _payoutCtrls[i].text = amt > 0 ? _fmtAmount(amt) : '';
          if (amt > 0) places = i + 1;
        }
        _payoutPlaces   = places.clamp(1, 4);
        _configured     = payouts.isNotEmpty || fee > 0;
        _loading = false;
      });
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
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
    for (int i = 0; i < _payoutPlaces; i++) {
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
                          label: 'Ball Color',
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
                        const SizedBox(height: 8),

                        // Shared payout construct. Each place is a GROUP TOTAL;
                        // the per-player breakdown shows under each field since
                        // Pink Ball is a foursome-vs-foursome/threesome game.
                        PayoutConfigField(
                          pool:                _pool.round(),
                          numPayouts:          _payoutPlaces,
                          payoutCtrls:         _payoutCtrls,
                          onNumPayoutsChanged: (n) =>
                              setState(() => _payoutPlaces = n),
                          onPayoutChanged:     () => setState(() {}),
                          onSuggest:           _suggest,
                          placeSubtitle:       (i) => _perPlayerHelperFor(
                              double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0),
                        ),

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

String _fmtAmount(num value) {
  final d = value.toDouble();
  return d == d.truncateToDouble() ? d.toInt().toString() : d.toStringAsFixed(2);
}
