/// screens/eclectic_setup_screen.dart
/// ---------------------------------
/// Eclectic setup — the TD's two pools.
///
/// **The screen states the rules and asks for the money, and nothing else.**
/// Everything about how an eclectic is scored is fixed: hole numbers matched
/// across courses, best score to par kept, net strokes given per round at full
/// allowance. There is no handicap picker and no tiebreak picker, because there
/// is no decision behind either — so the Handicap card is read-only and says so
/// rather than offering a control that can only be set one way.
///
/// What the TD does decide is which pools are played and what each is worth.
///
/// **The availability rule comes from the server.** `available` and
/// `unavailable_reason` ride on the config, so this screen prints the reason
/// rather than owning a second copy of a rule about the event — and a round
/// added or shortened after the wizard drew its list is caught on save.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/payout_config_field.dart';

/// The four rules, verbatim from the design. They are numbered because they
/// are read in order: what is kept, what the card is, how net works, how a tie
/// pays.
const _kHowItPlays = <List<String>>[
  ['Every round counts.', ' The best score ', 'to par',
   ' on each hole number is kept.'],
  ['Those 18 bests are the golfer’s ', '', 'eclectic card',
   '. Lowest total to par wins.'],
  ['Net strokes are given ', '', 'per round',
   ', from that day’s course handicap and stroke index.'],
  ['Ties ', '', 'split the money', ' for the places they cover. No countback.'],
];

class EclecticSetupScreen extends StatefulWidget {
  final int tournamentId;
  const EclecticSetupScreen({super.key, required this.tournamentId});

  @override
  State<EclecticSetupScreen> createState() => _EclecticSetupScreenState();
}

class _EclecticSetupScreenState extends State<EclecticSetupScreen> {
  bool _grossOn = true;
  bool _netOn   = true;
  int  _numPlayers = 0;
  bool _available = true;
  String _unavailableReason = '';
  List<Map<String, dynamic>> _rounds = const [];

  final _grossEntry = TextEditingController();
  final _netEntry   = TextEditingController();
  final _grossPayouts =
      List<TextEditingController>.generate(4, (_) => TextEditingController());
  final _netPayouts =
      List<TextEditingController>.generate(4, (_) => TextEditingController());
  int _grossPlaces = 0;
  int _netPlaces   = 0;

  bool _loading = true;
  bool _saving  = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _grossEntry.addListener(() => setState(() {}));
    _netEntry.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _grossEntry.dispose();
    _netEntry.dispose();
    for (final c in [..._grossPayouts, ..._netPayouts]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final cfg = await context.read<AuthProvider>().client
          .getEclecticSetup(widget.tournamentId);
      if (!mounted) return;
      setState(() {
        _numPlayers = cfg['num_players'] as int? ?? 0;
        _available  = cfg['available'] as bool? ?? true;
        _unavailableReason = cfg['unavailable_reason'] as String? ?? '';
        _rounds = ((cfg['rounds'] as List?) ?? const [])
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        _grossOn = cfg['gross_on'] as bool? ?? true;
        _netOn   = cfg['net_on'] as bool? ?? true;
        _grossEntry.text = _fmt(cfg['gross_entry_fee'] as num? ?? 0);
        _netEntry.text   = _fmt(cfg['net_entry_fee'] as num? ?? 0);
        _grossPlaces = _fill(_grossPayouts, cfg['gross_payouts'] as List?);
        _netPlaces   = _fill(_netPayouts,   cfg['net_payouts'] as List?);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  int _fill(List<TextEditingController> ctrls, List? payouts) {
    final list = payouts ?? const [];
    for (var i = 0; i < 4; i++) {
      ctrls[i].text = i < list.length
          ? _fmt(double.tryParse(list[i]['amount']?.toString() ?? '') ?? 0)
          : '0';
    }
    return list.length.clamp(0, 4);
  }

  String _fmt(num n) => n == n.roundToDouble() ? n.toInt().toString() : '$n';

  double _fee(TextEditingController c) =>
      double.tryParse(c.text.trim()) ?? 0.0;
  int _pool(TextEditingController c) => (_fee(c) * _numPlayers).round();

  /// Disabled until every pool that is ON has an entry — the usual stake gate,
  /// and the button says which pool is missing rather than going grey and
  /// silent.
  String? get _blocker {
    if (!_available) return _unavailableReason;
    if (!_grossOn && !_netOn) return 'Turn a pool on';
    if (_grossOn && _fee(_grossEntry) <= 0) return 'Set the Gross entry';
    if (_netOn && _fee(_netEntry) <= 0) return 'Set the Net entry';
    return null;
  }

  List<Map<String, dynamic>> _payouts(
      List<TextEditingController> ctrls, int places) => [
        for (var i = 0; i < places; i++)
          {'place': i + 1,
           'amount': double.tryParse(ctrls[i].text.trim()) ?? 0.0},
      ];

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      await context.read<AuthProvider>().client.postEclecticSetup(
        widget.tournamentId,
        grossOn      : _grossOn,
        netOn        : _netOn,
        grossEntryFee: _fee(_grossEntry),
        grossPayouts : _payouts(_grossPayouts, _grossPlaces),
        netEntryFee  : _fee(_netEntry),
        netPayouts   : _payouts(_netPayouts, _netPlaces),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _blocker;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Eclectic'),
        actions: const [_FieldTag(), SizedBox(width: 12)],
      ),
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
                          onPressed: (_saving || blocker != null) ? null : _save,
                          child: _saving
                              ? const SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              // **The reason, not a grey button.** A disabled
                              // control that does not say why is a mystery.
                              : Text(blocker ?? 'Save game',
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _body() {
    final theme = Theme.of(context);
    final n = _rounds.length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Best of every hole', style: theme.textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          'Each golfer keeps his best score on each hole number across all '
          '$n rounds. Lowest eighteen wins.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (!_available) ...[
          const SizedBox(height: 12),
          _Card(child: Row(children: [
            Icon(Icons.info_outline, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 10),
            Expanded(child: Text(_unavailableReason,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error))),
          ])),
        ],
        const SizedBox(height: 16),

        _Card(
          title: 'How it plays',
          child: Column(children: [
            for (var i = 0; i < _kHowItPlays.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _NumberedRule(n: i + 1, parts: _kHowItPlays[i]),
            ],
          ]),
        ),
        const SizedBox(height: 16),

        _Card(
          title: 'Rounds',
          trailing: '$n ${n == 1 ? "round" : "rounds"} · '
              '${_courseCount} ${_courseCount == 1 ? "course" : "courses"} · '
              'all 18 holes',
          child: Column(children: [
            for (final r in _rounds) _roundRow(r),
            // Only when the rounds actually span courses — on one course there
            // is nothing to explain.
            if (_courseCount > 1) ...[
              const SizedBox(height: 10),
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'Different courses are matched '),
                TextSpan(text: 'by hole number',
                    style: TextStyle(fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurface)),
                const TextSpan(
                    text: '. A 4 on a par-5 5th is a birdie and beats a par '
                        'on a par-4 5th.'),
              ]), style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]),
        ),
        const SizedBox(height: 16),

        _Card(
          title: 'Pools',
          child: Column(children: [
            _poolToggle(
              label: 'Gross', on: _grossOn,
              blurb: 'Best gross to par on each hole',
              onChanged: (v) => setState(() => _grossOn = v),
            ),
            const Divider(height: 20),
            _poolToggle(
              label: 'Net', on: _netOn,
              blurb: 'Best net to par, strokes given per round',
              onChanged: (v) => setState(() => _netOn = v),
            ),
          ]),
        ),

        if (_grossOn) ...[
          const SizedBox(height: 16),
          _moneyCard('Gross', _grossEntry, _grossPayouts, _grossPlaces,
              (n) => setState(() => _grossPlaces = n)),
        ],
        if (_netOn) ...[
          const SizedBox(height: 16),
          _moneyCard('Net', _netEntry, _netPayouts, _netPlaces,
              (n) => setState(() => _netPlaces = n)),
        ],

        const SizedBox(height: 16),
        _Card(
          title: 'Handicap',
          child: Column(children: [
            // **Read-only on purpose.** There is nothing to choose: the
            // allowance is the rule, not a setting.
            _factRow('From the tournament',
                "100% of each round's course handicap", 'Inherited'),
            const Divider(height: 20),
            // Half-true before the 26 Sep ruling, and the half that was
            // missing is the half a TD needs: a golfer who misses a round is
            // still in it, but only if the rounds he DID play cover all
            // eighteen hole numbers between them.
            _factRow('Missed rounds',
                'Still eligible, with fewer scores to pick from', 'Allowed'),
            const Divider(height: 20),
            _factRow('An incomplete card',
                'Needs a score on all 18 hole numbers to be paid',
                'Required'),
          ]),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  int get _courseCount =>
      _rounds.map((r) => r['course']).toSet().length;

  Widget _roundRow(Map<String, dynamic> r) {
    final theme = Theme.of(context);
    final par = r['par'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(
          width: 30,
          child: Text('${r['label']}',
              style: theme.textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ),
        Expanded(child: Text('${r['course']}',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium)),
        Text(
          [
            if ((r['date'] as String?)?.isNotEmpty ?? false) '${r['date']}',
            if (par != null) 'par $par',
          ].join(' · '),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }

  Widget _poolToggle({
    required String label,
    required bool on,
    required String blurb,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    // **The last pool on cannot be turned off.** An eclectic with no pool is
    // not a game. The switch simply does nothing rather than showing an error,
    // which is what the design specifies — and the server refuses it too, so
    // this is a convenience rather than the rule.
    final isLastOn = on && !(label == 'Gross' ? _netOn : _grossOn);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.bold)),
          Text(blurb, style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      Switch(
        value: on,
        onChanged: isLastOn ? null : onChanged,
      ),
    ]);
  }

  Widget _moneyCard(String label, TextEditingController entry,
      List<TextEditingController> ctrls, int places,
      ValueChanged<int> onPlaces) {
    final theme = Theme.of(context);
    return _Card(
      title: label,
      trailing: '\$${_fmt(_fee(entry))} × $_numPlayers entered',
      child: Column(children: [
        Row(children: [
          const Expanded(child: Text('Per golfer')),
          SizedBox(
            width: 110,
            child: TextField(
              controller: entry,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                  prefixText: '\$ ', border: OutlineInputBorder(),
                  isDense: true),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Pool: \$${_pool(entry)}',
              style: theme.textTheme.bodySmall),
        ),
        const SizedBox(height: 8),
        PayoutConfigField(
          pool: _pool(entry),
          numPayouts: places,
          payoutCtrls: ctrls,
          onNumPayoutsChanged: onPlaces,
          onPayoutChanged: () => setState(() {}),
          onSuggest: () {
            final amounts = suggestPayouts(_pool(entry), places);
            setState(() {
              for (var i = 0; i < 4; i++) ctrls[i].text = '${amounts[i]}';
            });
          },
        ),
      ]),
    );
  }

  Widget _factRow(String label, String detail, String tag) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
          Text(detail, style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(tag, style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------

/// The `FIELD` tag in the app bar — this is a whole-field game, not a
/// foursome's.
class _FieldTag extends StatelessWidget {
  const _FieldTag();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text('FIELD',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 0.6,
            color: theme.colorScheme.primary,
          )),
    );
  }
}

class _Card extends StatelessWidget {
  final String? title;
  final String? trailing;
  final Widget child;
  const _Card({this.title, this.trailing, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null) ...[
          Row(children: [
            Text(title!, style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (trailing != null)
              Flexible(
                child: Text(trailing!,
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
          ]),
          const SizedBox(height: 10),
        ],
        child,
      ]),
    );
  }
}

/// A numbered rule: the number in the accent, the emphasis inside the sentence.
class _NumberedRule extends StatelessWidget {
  final int n;
  final List<String> parts;   // [lead, '', bold, tail]
  const _NumberedRule({required this.n, required this.parts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 22,
        child: Text('$n',
            style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary)),
      ),
      Expanded(
        child: Text.rich(TextSpan(children: [
          TextSpan(text: parts[0] + parts[1]),
          TextSpan(text: parts[2],
              style: const TextStyle(fontWeight: FontWeight.bold)),
          TextSpan(text: parts[3]),
        ]), style: theme.textTheme.bodyMedium),
      ),
    ]);
  }
}
