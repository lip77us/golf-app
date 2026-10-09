/// Hot Spot setup.
///
/// Follows the Irish Rumble shape the handoff asks for: rules first, money
/// last, one Save. Three organiser choices and no more — Scoring, Handicap
/// with its allowance, and what happens over the last two holes.
///
/// **The anchor order is NOT here.** Each group sets its own on the first tee,
/// so it is a per-foursome write from the score-entry screen. An organiser
/// cannot set it the night before because he does not know who will be in
/// which cart, and a screen that let him would be writing something the
/// group then has to undo.
///
/// The money card is the standard one — `PayoutConfigField`, the same widget
/// Irish Rumble and Better Ball use, paying the winning GROUP and splitting
/// among its real golfers. There is deliberately no Hot Spot version of it.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/payout_config_field.dart';
import '../widgets/section_card.dart';

class HotSpotSetupScreen extends StatefulWidget {
  final int roundId;
  const HotSpotSetupScreen({super.key, required this.roundId});

  @override
  State<HotSpotSetupScreen> createState() => _HotSpotSetupScreenState();
}

class _HotSpotSetupScreenState extends State<HotSpotSetupScreen> {
  // ── The three rules ───────────────────────────────────────────────────────
  String _scoring = 'to_par';
  String _mode = 'net';
  /// 85% is the handoff's default, not a carried-forward round value — the
  /// anchor has to be carried, so the field plays off less than full.
  int _netPercent = 85;
  String _finish = 'keep_rotating';

  // ── Money ─────────────────────────────────────────────────────────────────
  final _entryCtrl = TextEditingController(text: '10');
  bool _noStakes = false;
  final List<TextEditingController> _payoutCtrls =
      List.generate(4, (_) => TextEditingController());
  int _payoutPlaces = 1;

  int _numPlayers = 0;
  List<int> _groupSizes = const [];

  bool _loading = true;
  bool _saving = false;
  bool _configured = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _entryCtrl.addListener(() => setState(() {
          if ((double.tryParse(_entryCtrl.text.trim()) ?? 0) > 0 && _noStakes) {
            _noStakes = false;
          }
        }));
    _load();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    for (final c in _payoutCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  double get _pool =>
      (double.tryParse(_entryCtrl.text.trim()) ?? 0.0) * _numPlayers;

  double get _allocated => _payoutCtrls
      .take(_payoutPlaces)
      .fold(0.0, (s, c) => s + (double.tryParse(c.text.trim()) ?? 0.0));

  bool get _stakeChosen =>
      _noStakes || (double.tryParse(_entryCtrl.text.trim()) ?? 0) > 0;

  bool get _poolBalanced {
    if (_numPlayers == 0 || _pool <= 0) return true;
    return _pool.round() == _allocated.round();
  }

  /// The same levelling guard the server applies: a threesome borrows a 4th
  /// only when some other group has four to level up to.
  bool get _hasLeveledThreesome =>
      _groupSizes.contains(3) && _groupSizes.any((n) => n >= 4);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cfg = await context
          .read<AuthProvider>()
          .client
          .getHotSpotConfig(widget.roundId);
      if (!mounted) return;
      setState(() {
        _configured = cfg['configured'] == true;
        _scoring = cfg['scoring'] as String? ?? 'to_par';
        _mode = cfg['handicap_mode'] as String? ?? 'net';
        _netPercent = (cfg['net_percent'] as num?)?.toInt() ?? 85;
        _finish = cfg['finish_rule'] as String? ?? 'keep_rotating';
        _numPlayers = (cfg['num_players'] as num?)?.toInt() ?? 0;
        _groupSizes = ((cfg['group_sizes'] as List?) ?? [])
            .map((e) => (e as num).toInt())
            .toList();
        if (_configured) {
          final fee = (cfg['entry_fee'] as num?)?.toDouble() ?? 0.0;
          _entryCtrl.text =
              fee.toStringAsFixed(fee == fee.roundToDouble() ? 0 : 2);
          _noStakes = fee == 0;
          final payouts = (cfg['payouts'] as List?) ?? [];
          _payoutPlaces = payouts.isEmpty ? 1 : payouts.length.clamp(1, 4);
          for (var i = 0; i < _payoutCtrls.length; i++) {
            _payoutCtrls[i].text = i < payouts.length
                ? ((payouts[i] as Map)['amount'] as num).toStringAsFixed(0)
                : '';
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _suggest() {
    final pool = _pool.round();
    if (pool <= 0) return;
    final amts = suggestPayouts(pool, _payoutPlaces);
    setState(() {
      for (var i = 0; i < _payoutPlaces; i++) {
        _payoutCtrls[i].text = amts[i] == 0 ? '' : '${amts[i]}';
      }
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final payouts = <Map<String, dynamic>>[
        for (var i = 0; i < _payoutPlaces; i++)
          {
            'place': i + 1,
            'amount': double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0,
          },
      ];
      await context.read<AuthProvider>().client.postHotSpotSetup(
            widget.roundId,
            scoring: _scoring,
            handicapMode: _mode,
            netPercent: _netPercent,
            finishRule: _finish,
            entryFee: double.tryParse(_entryCtrl.text.trim()) ?? 0.0,
            payouts: payouts,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _saving = false;
        });
      }
    }
  }

  /// Why Save cannot fire, as the button's own label — nothing is disabled
  /// without saying why.
  String? get _saveBlocker {
    if (!_stakeChosen) return 'Set the entry to save';
    if (!_poolBalanced) return 'Places must add to the pot';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hot Spot')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && !_saving && !_configured)
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : Column(children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _rulesSection(),
                          const SizedBox(height: 24),
                          _moneySection(),
                        ],
                      ),
                    ),
                  ),
                  SafeArea(top: false, child: _nav()),
                ]),
    );
  }

  Widget _nav() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: (_saving || _saveBlocker != null) ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_saveBlocker ?? 'Save'),
          ),
        ),
      );

  Widget _rulesSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'How it plays',
          child: Text(
            'One golfer anchors each hole and his score counts whatever it is. '
            'The team adds the best net of the other three. Each group sets '
            'its own anchor order on the first tee.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 16),

        // ── Scoring ──────────────────────────────────────────────────────────
        SectionCard(
          title: 'Scoring',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'to_par', label: Text('Strokes to par')),
                  ButtonSegment(value: 'stableford', label: Text('Stableford')),
                ],
                selected: {_scoring},
                onSelectionChanged: (v) =>
                    setState(() => _scoring = v.first),
              ),
              const SizedBox(height: 8),
              Text(
                _scoring == 'to_par'
                    ? 'The board reads net to par, lowest first.'
                    : 'The board reads points, highest first. The same '
                      'competition either way — the cap means a point is '
                      'always a stroke, so the order never differs.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── Handicap ─────────────────────────────────────────────────────────
        HandicapModeSelector(
          mode: _mode,
          netPercent: _netPercent,
          onModeChanged: (m) => setState(() => _mode = m),
          onPercentChanged: (p) => setState(() => _netPercent = p),
          // Strokes off the low golfer needs ONE low golfer, and a field of
          // groups does not have one. The server refuses it too.
          allowStrokesOff: false,
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'The cap',
          child: Text(
            'Every score counts as net double bogey at worst, the anchor\'s '
            'included. It is a rule of the game rather than a setting: '
            'carrying the anchor\'s bad hole is the format, and uncapped one '
            'hole would decide the field.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 16),

        // ── The last two holes ───────────────────────────────────────────────
        SectionCard(
          title: 'Holes 17 and 18',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final opt in const [
                ['keep_rotating', 'Keep rotating',
                 'The rotation carries on, so the first two in each group\'s '
                     'order anchor five holes and the other two four.'],
                ['best_2', 'Best 2',
                 'No anchor. The best two nets count on both holes.'],
                ['three_then_four', '3 then 4',
                 'No anchor. Three count on the 17th and all four on the '
                     '18th, the way Irish Rumble finishes.'],
              ])
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: opt[0],
                  groupValue: _finish,
                  onChanged: (v) => setState(() => _finish = v ?? _finish),
                  title: Text(opt[1]),
                  subtitle: Text(opt[2],
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
        if (_hasLeveledThreesome) ...[
          const SizedBox(height: 16),
          SectionCard(
            title: 'Threesomes',
            child: Text(
              'A group of three borrows a fourth ball from the field, as in '
              'Irish Rumble. The borrowed ball can be the best net of the '
              'others; it never anchors.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  Widget _moneySection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Entry',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _entryCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Entry per golfer',
                  prefixText: '\$',
                ),
              ),
              if (_numPlayers > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Pot \$${_pool.toStringAsFixed(0)} '
                    'from $_numPlayers golfers',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Play for fun — no stakes'),
                value: _noStakes,
                onChanged: (v) => setState(() {
                  _noStakes = v ?? false;
                  if (_noStakes) _entryCtrl.text = '0';
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Payouts',
          child: PayoutConfigField(
            pool: _pool.round(),
            numPayouts: _payoutPlaces,
            payoutCtrls: _payoutCtrls,
            onNumPayoutsChanged: (n) => setState(() => _payoutPlaces = n),
            onPayoutChanged: () => setState(() {}),
            onSuggest: _suggest,
            placeSubtitle: (i) => _perPlayerHelperFor(
                double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0),
          ),
        ),
        if (_error != null && !_saving) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(friendlyError(_error!),
                style: TextStyle(color: theme.colorScheme.onErrorContainer)),
          ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }

  /// A group prize splits among the group's REAL golfers, so a levelled
  /// threesome splits three ways and a foursome four. The borrowed ball is
  /// not a person and cannot be paid.
  String? _perPlayerHelperFor(double groupTotal) {
    if (groupTotal <= 0) return null;
    final sizes = _groupSizes.where((n) => n > 0).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    if (sizes.isEmpty) return null;
    return sizes
        .map((n) => '\$${(groupTotal / n).toStringAsFixed(2)} each '
            '($n ${n == 1 ? "way" : "ways"})')
        .join(' · ');
  }
}
