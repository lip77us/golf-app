/// The day bet — the final round's 18-hole side bet.
///
/// **What makes it different from every other pot is who it does not charge.**
/// The championship money winners play the round and appear on the board, but
/// cannot collect and get their entry back at settlement. The Mini Singles
/// day-2 finalists are not on it at all — they are playing a match, not
/// posting a stroke card.
///
/// Neither is a list the TD picks. Both are decided by the 36-hole result, so
/// a manual exclusion list could not express it: you would be asked to name
/// the winners before the round that decides them. That is exactly why Stroke
/// Play's Prize Exclusions cannot do this job.
///
/// The engine has existed since the individual-play build; this screen is the
/// way in. It was previously configurable only inside the create wizard, and
/// only if a fee above zero was set there — miss it and there was no way back.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/payout_config_field.dart';
import '../widgets/section_card.dart';

class DayBetSetupScreen extends StatefulWidget {
  final int roundId;
  const DayBetSetupScreen({super.key, required this.roundId});

  @override
  State<DayBetSetupScreen> createState() => _DayBetSetupScreenState();
}

class _DayBetSetupScreenState extends State<DayBetSetupScreen> {
  final _entryCtrl = TextEditingController(text: '5');
  final List<TextEditingController> _payoutCtrls =
      List.generate(4, (_) => TextEditingController());
  int _places = 3;

  bool _loading = true;
  bool _saving = false;
  bool _eligible = false;
  String? _reason;
  int _fieldSize = 0;
  int _roundNumber = 0;
  int _totalRounds = 0;
  List<Map<String, dynamic>> _champPayouts = const [];
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
    for (final c in _payoutCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  /// **An ESTIMATE, and the screen says so.** The eligible field is not known
  /// until the championship closes — the money winners' entries come back out
  /// — so this is the pot assuming the current leaders hold.
  double get _pool =>
      (double.tryParse(_entryCtrl.text.trim()) ?? 0.0) * _fieldSize;


  /// **There is deliberately no payouts-balance check.** Every other pot has
  /// one, because its pool is known. This pool is an estimate until the
  /// championship closes, so balancing against it would be balancing against
  /// a number that is about to move — and would block a table that is right.
  ///
  /// The last paying championship place. Day-bet 1st may not exceed it, or a
  /// golfer is better off DQ-ing the 36 holes than winning it — which is the
  /// one thing a side bet must never do.
  double get _floor {
    double lowest = 0;
    for (final p in _champPayouts) {
      final a = (p['amount'] as num?)?.toDouble() ?? 0;
      if (a > 0 && (lowest == 0 || a < lowest)) lowest = a;
    }
    return lowest;
  }

  double get _firstPrize =>
      double.tryParse(_payoutCtrls[0].text.trim()) ?? 0.0;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await context
          .read<AuthProvider>()
          .client
          .getDayBetSetup(widget.roundId);
      if (!mounted) return;
      setState(() {
        _eligible = d['eligible'] == true;
        _reason = d['reason'] as String?;
        _fieldSize = (d['field_size'] as num?)?.toInt() ?? 0;
        _roundNumber = (d['round_number'] as num?)?.toInt() ?? 0;
        _totalRounds = (d['total_rounds'] as num?)?.toInt() ?? 0;
        _champPayouts = ((d['championship_payouts'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (d['configured'] == true) {
          final fee = (d['entry_fee'] as num?)?.toDouble() ?? 0.0;
          _entryCtrl.text =
              fee.toStringAsFixed(fee == fee.roundToDouble() ? 0 : 2);
          final ps = (d['payouts'] as List?) ?? [];
          _places = ps.isEmpty ? 3 : ps.length.clamp(1, 4);
          for (var i = 0; i < _payoutCtrls.length; i++) {
            _payoutCtrls[i].text = i < ps.length
                ? ((ps[i] as Map)['amount'] as num).toStringAsFixed(0)
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
    final amts = suggestPayouts(pool, _places);
    setState(() {
      for (var i = 0; i < _places; i++) {
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
      await context.read<AuthProvider>().client.postDayBetSetup(
            widget.roundId,
            entryFee: double.tryParse(_entryCtrl.text.trim()) ?? 0.0,
            payouts: [
              for (var i = 0; i < _places; i++)
                {
                  'place': i + 1,
                  'amount':
                      double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0,
                },
            ],
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

  /// Why Save cannot fire, as the button's own label.
  String? get _blocker {
    if (!_eligible) return _reason ?? 'Not this round';
    if ((double.tryParse(_entryCtrl.text.trim()) ?? 0) <= 0) {
      return 'Set the entry to save';
    }
    if (_floor > 0 && _firstPrize > _floor) {
      return 'First must not beat \$${_floor.toStringAsFixed(0)}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Day bet')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && !_saving)
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : Column(children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (!_eligible) ...[
                          SectionCard(
                            title: 'Not this round',
                            child: Text(
                              _reason ?? '',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        SectionCard(
                          title: 'Who plays for it',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'An 18-hole net bet on the final round, for '
                                'the golfers still out of the money after 36.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSurfaceVariant),
                              ),
                              const SizedBox(height: 8),
                              _rule(theme,
                                  'The championship money winners play it and '
                                  'show on the board, but cannot collect — '
                                  'and are not charged. Their entry comes '
                                  'back at settlement.'),
                              _rule(theme,
                                  'Mini Singles day-2 finalists are not on it '
                                  'at all. They are playing a match, not '
                                  'posting a card.'),
                              _rule(theme,
                                  'Neither is a list you pick. Both are '
                                  'settled by the 36-hole result, which is '
                                  'why nothing is collected until the '
                                  'championship closes.'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          title: 'Entry',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: _entryCtrl,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration: const InputDecoration(
                                    labelText: 'Entry per golfer',
                                    prefixText: '\$'),
                              ),
                              if (_fieldSize > 0)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    'About \$${_pool.toStringAsFixed(0)} from '
                                    '$_fieldSize golfers — an estimate, '
                                    'because the money winners\' entries come '
                                    'back out when the championship closes.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          title: 'Payouts',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              PayoutConfigField(
                                pool: _pool.round(),
                                numPayouts: _places,
                                payoutCtrls: _payoutCtrls,
                                onNumPayoutsChanged: (n) =>
                                    setState(() => _places = n),
                                onPayoutChanged: () => setState(() {}),
                                onSuggest: _suggest,
                              ),
                              if (_floor > 0) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'First prize must stay under '
                                  '\$${_floor.toStringAsFixed(0)}, the last '
                                  'paying championship place — or a golfer is '
                                  'better off losing the 36 holes than '
                                  'winning this.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: _firstPrize > _floor
                                          ? theme.colorScheme.error
                                          : theme
                                              .colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_totalRounds > 0) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Round $_roundNumber of $_totalRounds.',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed:
                              (_saving || _blocker != null) ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : Text(_blocker ?? 'Save'),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _rule(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('·  ',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.4)),
          ),
        ]),
      );
}
