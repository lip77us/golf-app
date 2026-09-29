/// screens/forty_balls_setup_screen.dart
/// ------------------------------------
/// 40 Balls setup — **the TD sets how a score is measured, and nothing about
/// balls.**
///
/// The budget follows the group size and the counts are the group's, picked
/// hole by hole after the scores are in. So the Budget card READS the groups
/// off Groups & tees and states each one; there is no control on it. That is
/// the difference from every other game in this family, and the screen says so
/// rather than leaving a TD hunting for the setting.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/payout_config_field.dart';

/// The four rules, in reading order: who picks, what the budget is, what
/// happens when the choice runs out, and when a pick locks.
const _kHowItPlays = <List<String>>[
  ['After each hole the group picks how many nets count, ', '', '0 to 4',
   '. The best ones count.'],
  ['Over 18 holes the group counts ', '', 'exactly 40 balls',
   '. A threesome counts 30.'],
  ["When there's ", '', 'no slack left',
   ", every ball counts on every hole that's left."],
  ['A count can be changed ', '', 'until the next hole is scored',
   ". After that it's locked."],
];

class FortyBallsSetupScreen extends StatefulWidget {
  final int roundId;
  const FortyBallsSetupScreen({super.key, required this.roundId});

  @override
  State<FortyBallsSetupScreen> createState() => _FortyBallsSetupScreenState();
}

class _FortyBallsSetupScreenState extends State<FortyBallsSetupScreen> {
  String _mode = 'net';
  int    _netPercent = 100;
  bool   _cap = true;
  /// **`Default` until changed, then `Set by you`.** A TD who has not touched
  /// the scoring card should be able to see that at a glance rather than
  /// working out whether 100% is his number or ours.
  bool   _scoringTouched = false;

  int _numPlayers = 0;
  List<Map<String, dynamic>> _groups = const [];

  /// **Spent once the first count is picked.** A group chose 2 balls on the
  /// 1st having looked at four nets; change the allowance, the mode or the cap
  /// now and those are different numbers, so what it chose was a choice about
  /// something else. The server refuses it — this is the screen saying so
  /// before the TD types into a field that will not save. The MONEY stays
  /// open: an entry fee is not something a hole was played against.
  bool _scoringLocked = false;
  String _lockNote = '';

  final _entryCtrl = TextEditingController();
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
    _entryCtrl.dispose();
    for (final c in _payoutCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final cfg = await context.read<AuthProvider>().client
          .getFortyBallsSetup(widget.roundId);
      if (!mounted) return;
      setState(() {
        _numPlayers = cfg['num_players'] as int? ?? 0;
        _groups = ((cfg['groups'] as List?) ?? const [])
            .map((g) => Map<String, dynamic>.from(g as Map))
            .toList();
        _mode = cfg['handicap_mode'] as String? ?? 'net';
        _netPercent = cfg['net_percent'] as int? ?? 100;
        _cap = cfg['net_max_double_bogey'] as bool? ?? true;
        _scoringTouched = cfg['configured'] as bool? ?? false;
        _scoringLocked = cfg['scoring_locked'] as bool? ?? false;
        _lockNote = cfg['scoring_lock_note'] as String? ?? '';
        _entryCtrl.text = _fmt(cfg['entry_fee'] as num? ?? 0);
        final payouts = (cfg['payouts'] as List? ?? const []);
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
  double get _fee => double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
  int get _pool => (_fee * _numPlayers).round();

  String? get _blocker {
    if (_groups.isEmpty) return 'Set the groups first';
    if (_fee <= 0) return 'Set the entry';
    return null;
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      await context.read<AuthProvider>().client.postFortyBallsSetup(
        widget.roundId,
        handicapMode     : _mode,
        netPercent       : _netPercent,
        netMaxDoubleBogey: _cap,
        entryFee         : _fee,
        payouts: [
          for (var i = 0; i < _numPayouts; i++)
            {'place': i + 1,
             'amount': double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0},
        ],
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
        title: const Text('40 Balls'),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Forty balls, your call', style: theme.textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          'Each group decides after every hole how many of its nets count. By '
          'the 18th green it must have counted exactly 40.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),

        // The exclusion, stated before it happens rather than discovered
        // afterwards on the hub.
        _Card(child: Row(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Icon(Icons.info_outline, size: 18,
              color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text.rich(TextSpan(children: [
            const TextSpan(text: 'Turning this on turns off '),
            const TextSpan(text: 'Irish Rumble',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const TextSpan(text: ' and '),
            const TextSpan(text: 'Better Ball',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const TextSpan(
                text: ' for this round. They score the same group nets.'),
          ]), style: theme.textTheme.bodySmall)),
        ])),
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
          title: 'Budget',
          trailing: 'follows the group size',
          child: Column(children: [
            for (final g in _groups) _budgetRow(g),
            if (_groups.isEmpty)
              Text('No groups yet — set them on Groups & tees.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'You set no balls. A foursome counts 40 over the round, a '
                'threesome 30, and a group can count nothing on a hole.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),

        _Card(
          title: 'Scoring',
          trailing: _scoringLocked
              ? 'Locked'
              : (_scoringTouched ? 'Set by you' : 'Default'),
          child: Column(children: [
            if (_scoringLocked) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.lock_outline, size: 16,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_lockNote,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ]),
              const SizedBox(height: 12),
            ],
            // **The app's shared control**, exactly as Irish Rumble and the
            // other twenty setup screens use it — Net / Gross and the Net %
            // slider, which already moves in steps of 5. A hand-rolled
            // segmented button and stepper was the first version of this and
            // it put a different handicap control on one screen.
            //
            // `allowStrokesOff: false` because the packet offers Net or Gross
            // and nothing else: strokes-off anchors on a low handicap, and
            // which low — the group's or the field's — is a question this game
            // does not answer.
            IgnorePointer(
              ignoring: _scoringLocked,
              child: Opacity(
                opacity: _scoringLocked ? 0.55 : 1,
                child: HandicapModeSelector(
                  mode            : _mode,
                  netPercent      : _netPercent,
                  allowStrokesOff : false,
                  wrapInCard      : false,
                  onModeChanged   : (m) => setState(() {
                    _mode = m;
                    _scoringTouched = true;
                  }),
                  onPercentChanged: (p) => setState(() {
                    _netPercent = p;
                    _scoringTouched = true;
                  }),
                ),
              ),
            ),
            const Divider(height: 20),
            // **Not `NetDoubleBogeyCard`, and the difference is real.** That
            // card is the casual convention and hides itself unless the round
            // is full Net at 100% — the cap being judged too surprising under
            // a reduced allowance. Here the packet makes it 40 Balls' own
            // setting, applied at ANY allowance and in Gross too, because it
            // lands BEFORE the group picks: a capped score is one of the
            // numbers it is choosing between, so it cannot quietly not apply.
            // **A Row and a Switch, not a `SwitchListTile`.** A ListTile paints
            // its background and ink splash on the nearest Material ancestor,
            // and `_Card` is a decorated Container — so the splash landed
            // behind the card and Flutter asserted about it on every build.
            // The pool toggles on the Dream Round setup screen are built the same
            // way, for the same reason.
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Double bogey max',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                        _mode == 'gross'
                            ? 'No score counts worse than par + 2. Applied '
                              'before the group picks.'
                            : 'No net score counts worse than net par + 2. '
                              'Applied before the group picks, so a capped '
                              'score is what it is choosing between.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: _cap,
                onChanged: _scoringLocked ? null : (v) => setState(() {
                  _cap = v;
                  _scoringTouched = true;
                }),
              ),
            ]),
          ]),
        ),
        const SizedBox(height: 16),

        _Card(
          title: 'Money',
          trailing: '\$${_fmt(_fee)} × $_numPlayers',
          child: Column(children: [
            Row(children: [
              const Expanded(child: Text('Entry per golfer')),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _entryCtrl,
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
              child: Text('Pool: \$$_pool',
                  style: theme.textTheme.bodySmall),
            ),
            const SizedBox(height: 8),
            PayoutConfigField(
              pool: _pool,
              numPayouts: _numPayouts,
              payoutCtrls: _payoutCtrls,
              onNumPayoutsChanged: (n) => setState(() => _numPayouts = n),
              onPayoutChanged: () => setState(() {}),
              onSuggest: () {
                final amounts = suggestPayouts(_pool, _numPayouts);
                setState(() {
                  for (var i = 0; i < 4; i++) {
                    _payoutCtrls[i].text = '${amounts[i]}';
                  }
                });
              },
              // A group prize, so each place says what one golfer takes.
              placeSubtitle: (i) {
                final amount =
                    double.tryParse(_payoutCtrls[i].text.trim()) ?? 0;
                if (amount <= 0 || _groups.isEmpty) return null;
                final size = _groups.first['size'] as int? ?? 4;
                return 'Splits to \$${(amount / size).toStringAsFixed(2)} '
                       'a golfer in a $size-ball';
              },
            ),
          ]),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _budgetRow(Map<String, dynamic> g) {
    final theme = Theme.of(context);
    final size = g['size'] as int? ?? 0;
    final b = g['budget'] as int? ?? 0;
    // `72 possible, so 32 to spare` — the slack a group starts with, which is
    // the number the picker counts down.
    final possible = size * 18;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 74,
          child: Text('Group ${g['group_number']}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Text('$b balls',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const Spacer(),
        Text('up to $size a hole · $possible possible · ${possible - b} spare',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------

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
