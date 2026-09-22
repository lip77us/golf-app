/// screens/better_ball_setup_screen.dart
/// --------------------------------------
/// Better Ball setup — **one control, and everything else is a read-back.**
///
/// The count is the game, so the stepper is the first thing on the screen and
/// under it the app says what the TD has just made: what the game will be
/// called, what allowance it takes, and how it will read on every hole. Nothing
/// else on this screen is a choice about the format.
///
/// **It is not Irish Rumble's screen with the variant picker removed**, and the
/// difference is the point. Rumble asks a TD to shape eighteen holes; Better
/// Ball asks him for one number. Sharing the money section is right — it is the
/// same pool paid the same way — and sharing the rules section would have been
/// wrong.
///
/// Two fields FOLLOW the count until the TD takes them over, and both say so
/// with an `Auto` tag rather than silently:
///
///   * the **name** — 1 ball is `Better Ball`, 2 `Best 2 of 4`, 3
///     `Best 3 of 4`, 4 `Aggregate`. Once he types, the app stops renaming it:
///     a name somebody chose should not move when he changes his mind about
///     the count.
///   * the **allowance** — the published table, 75/85/95/100. A default, not a
///     rule (Paul, 22 Sep 2026): the fewer balls count the more one low
///     golfer's ball carries the group, which is what it corrects for, but the
///     TD owns the number and the app stops suggesting once he moves it.
///
/// The net double-bogey cap is a RULE here, always on and stated rather than
/// switchable — the same call Irish Rumble's tournament path makes, for the
/// same reason: three switches for one rule can disagree and the leaderboard
/// cannot show which one won.
///
/// Spec: `handoff-foursome-formats/HANDOFF.md` §1.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/better_ball.dart';
import '../widgets/ball_count_grid.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/payout_config_field.dart';
import '../widgets/section_card.dart';

class BetterBallSetupScreen extends StatefulWidget {
  final int roundId;
  const BetterBallSetupScreen({super.key, required this.roundId});

  @override
  State<BetterBallSetupScreen> createState() => _BetterBallSetupScreenState();
}

class _BetterBallSetupScreenState extends State<BetterBallSetupScreen> {
  // ── The one control ───────────────────────────────────────────────────────
  int _balls = 2;

  /// The TD's own name, or empty while the app is still naming the game.
  /// **Empty is a value, not a blank waiting to be filled** — it is what the
  /// `Auto` tag is showing, and clearing the field is how he hands the naming
  /// back.
  final _nameCtrl = TextEditingController();
  bool _nameIsAuto = true;

  String _mode = 'net';
  /// Null while the allowance is still following the count.
  int? _netPercentOverride;

  final _entryCtrl = TextEditingController(text: '10');
  bool  _noStakes  = false;
  final List<TextEditingController> _payoutCtrls =
      List.generate(4, (_) => TextEditingController());
  int _payoutPlaces = 1;

  int       _numPlayers  = 0;
  List<int> _groupSizes  = const [];
  bool      _isTournamentRound = false;
  /// The other game in this pair. One round runs one of them, so when Rumble
  /// is already set this screen says why it is closed rather than letting the
  /// TD fill a form the server will refuse.
  bool      _rumbleConfigured  = false;

  /// The server's own answers, preferred over the mirrored constants once the
  /// screen has loaded. The mirror is the first-frame answer, not a second
  /// opinion — the server is what writes the config.
  Map<int, String> _namesByCount     = const {};
  Map<int, int>    _allowanceByCount = const {};

  bool    _loading    = true;
  bool    _saving     = false;
  bool    _configured = false;
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
    _nameCtrl.dispose();
    _entryCtrl.dispose();
    for (final c in _payoutCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  // ── The two fields that follow the count ─────────────────────────────────

  String get _name =>
      _nameIsAuto ? (_namesByCount[_balls] ?? betterBallName(_balls))
                  : _nameCtrl.text.trim();

  int get _recommendedPercent =>
      _allowanceByCount[_balls] ?? betterBallAllowance(_balls);

  int get _netPercent => _netPercentOverride ?? _recommendedPercent;

  // ── Money ─────────────────────────────────────────────────────────────────

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

  /// Matches the server's levelling guard: a threesome is only given a
  /// borrowed 4th when some other group has four to level up to, so an
  /// all-threesome field gets no notice.
  bool get _hasLeveledThreesome =>
      _groupSizes.contains(3) && _groupSizes.any((n) => n >= 4);

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final cfg = await context.read<AuthProvider>().client
          .getBetterBallConfig(widget.roundId);
      if (!mounted) return;
      setState(() {
        _configured        = cfg['configured'] == true;
        _balls             = (cfg['balls_to_count'] as num?)?.toInt() ?? 2;
        _nameIsAuto        = cfg['name_is_auto'] != false;
        _nameCtrl.text     = _nameIsAuto ? '' : (cfg['name'] as String? ?? '');
        _mode              = cfg['handicap_mode'] as String? ?? 'net';
        _numPlayers        = (cfg['num_players'] as num?)?.toInt() ?? 0;
        _isTournamentRound = cfg['is_tournament_round'] == true;
        _rumbleConfigured  = cfg['irish_rumble_configured'] == true;
        _groupSizes        = ((cfg['group_sizes'] as List?) ?? [])
            .map((e) => (e as num).toInt()).toList();
        _namesByCount     = _intKeyed<String>(cfg['names_by_count']);
        _allowanceByCount = _intKeyed<int>(cfg['allowance_by_count']);
        // An allowance that matches the count's own figure is left FOLLOWING
        // it rather than pinned. A TD who set 85 at two balls and a TD who
        // never touched it are indistinguishable in the data, and the kinder
        // reading is the one where changing the count still helps him.
        final saved = (cfg['net_percent'] as num?)?.toInt();
        _netPercentOverride =
            (saved == null || saved == _recommendedPercent) ? null : saved;
        if (_configured) {
          final fee = (cfg['entry_fee'] as num?)?.toDouble() ?? 0.0;
          _entryCtrl.text = fee.toStringAsFixed(fee == fee.roundToDouble()
              ? 0 : 2);
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
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// JSON object keys arrive as strings even when the server wrote integers.
  static Map<int, T> _intKeyed<T>(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <int, T>{};
    raw.forEach((k, v) {
      final n = int.tryParse('$k');
      if (n != null && v is T) out[n] = v;
    });
    return out;
  }

  /// Fill the places from the pot with the shared split, so a TD who has one
  /// place and a pot does not do the arithmetic himself.
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
    setState(() { _saving = true; _error = null; });
    try {
      final payouts = <Map<String, dynamic>>[
        for (var i = 0; i < _payoutPlaces; i++)
          {'place': i + 1,
           'amount': double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0},
      ];
      await context.read<AuthProvider>().client.postBetterBallSetup(
        widget.roundId,
        ballsToCount: _balls,
        // Empty means "keep following the count" — the server reads it the
        // same way, which is what keeps the `Auto` tag honest across a save.
        name        : _nameIsAuto ? '' : _nameCtrl.text.trim(),
        handicapMode: _mode,
        netPercent  : _netPercentOverride,
        entryFee    : double.tryParse(_entryCtrl.text.trim()) ?? 0.0,
        payouts     : payouts,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  /// Why Save cannot fire, as the button's own label. Nothing is disabled
  /// without saying why.
  String? get _saveBlocker {
    if (_rumbleConfigured) return 'Irish Rumble is already set';
    if (!_stakeChosen)     return 'Set the entry to save';
    if (!_poolBalanced)    return 'Places must add to the pot';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Better Ball')),
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
                          if (_rumbleConfigured) ...[
                            const _ExclusionNotice(),
                            const SizedBox(height: 16),
                          ],
                          _gameSection(),
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
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(
                    _saveBlocker ??
                        (_configured ? 'Save Changes' : 'Save game'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      );

  // ── The game: one stepper, and everything under it is a read-back ────────

  Widget _gameSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasLeveledThreesome) ...[
          const _BorrowedFourthNotice(),
          const SizedBox(height: 16),
        ],

        SectionCard(
          title: 'Balls counted',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Best nets per hole',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        Text('Out of four in a group, every hole',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  _Stepper(
                    value: _balls,
                    min: 1,
                    max: 4,
                    onChanged: (v) => setState(() => _balls = v),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // The readback, right under the control that drives it — this
              // is the whole screen in one line.
              _Readback('This game will be called', _name),
            ],
          ),
        ),

        const SizedBox(height: 16),

        SectionCard(
          title: 'Name',
          trailing: _nameIsAuto
              ? Text('follows the count until you change it',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant))
              : null,
          child: Row(
            children: [
              if (_nameIsAuto) ...[
                const _AutoTag(),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: GolfTextField(
                  controller: _nameCtrl,
                  label: 'Shown on every board and receipt',
                  hint: _nameIsAuto ? _name : null,
                  onChanged: (v) => setState(() {
                    // **Typing takes it over; clearing hands it back.** Both
                    // directions matter — a TD who changes his mind about a
                    // name he typed has no other way back to the app's.
                    _nameIsAuto = v.trim().isEmpty;
                  }),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // One line, not eighteen — the count cannot change mid-round, so the
        // preview is a statement rather than a grid.
        BallCountPreview(
          perHole: List<int>.filled(18, _balls),
          allFourNote:
              'Aggregate — every net counts on every hole, so no golfer can '
              'drop a bad one.',
        ),

        const SizedBox(height: 16),

        // ── Handicap and allowance ──────────────────────────────────────────
        if (_isTournamentRound)
          _LockedModeChip(mode: _mode, netPercent: _netPercent)
        else
          HandicapModeSelector(
            mode:          _mode,
            netPercent:    _netPercent,
            onModeChanged: (m) => setState(() => _mode = m),
            // Moving the slider is what takes the allowance over. It never
            // drifts back on its own afterwards.
            onPercentChanged: (p) => setState(() => _netPercentOverride = p),
            soNote: 'Strokes are based on the lowest handicap across all '
                'players in the round — not just within each group.',
          ),

        if (_mode == 'net') ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Allowance',
            trailing: _netPercentOverride == null ? const _AutoTag() : null,
            child: Text(
              _netPercentOverride == null
                  ? '$_netPercent% — the usual figure when $_balls '
                    '${_balls == 1 ? "net counts" : "nets count"}. Change it '
                    'and it stops following the count.'
                  : 'Set by you — $_netPercent% instead of the recommended '
                    '$_recommendedPercent% at this count.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.45),
            ),
          ),
        ],

        const SizedBox(height: 16),

        SectionCard(
          title: 'Net double bogey max',
          trailing: const Chip(
            label: Text('Always on', style: TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          child: Text(
            'Every score is capped at net double bogey — par + 2 plus any '
            'strokes you get on that hole — before the best nets are picked. '
            'There is nothing to switch here.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),
        ),
      ],
    );
  }

  // ── Money — Irish Rumble's, unchanged, because it is the same pool ───────

  Widget _moneySection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Entry Fee',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GolfTextField(
                controller: _entryCtrl,
                label: 'Entry fee per player (\$)',
                prefixIcon: Icons.attach_money,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 6),
              // The pool line names its SCOPE and its COUNT, the way Irish
              // Rumble's does — two near-identical money cards over completely
              // different pots is the confusion that rule exists for.
              Text(
                _numPlayers > 0
                    ? '\$${(double.tryParse(_entryCtrl.text.trim()) ?? 0)
                        .toStringAsFixed(0)} × $_numPlayers in the field '
                      '= \$${_pool.toStringAsFixed(0)} · pays a group, '
                      'split among its real golfers'
                    : 'Collected from each golfer in the field.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                'Tied groups split the place — no countback.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
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
            pool:                _pool.round(),
            numPayouts:          _payoutPlaces,
            payoutCtrls:         _payoutCtrls,
            onNumPayoutsChanged: (n) => setState(() => _payoutPlaces = n),
            onPayoutChanged:     () => setState(() {}),
            onSuggest:           _suggest,
            placeSubtitle:       (i) => _perPlayerHelperFor(
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

  /// `splits to $23.33 each (3 ways)` — per distinct group size in the field,
  /// because a levelled threesome splits three ways and a foursome four.
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

// ── Small parts ─────────────────────────────────────────────────────────────

class _Stepper extends StatelessWidget {
  final int value, min, max;
  final ValueChanged<int> onChanged;
  const _Stepper({required this.value, required this.min, required this.max,
                  required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget btn(IconData icon, int next, bool on) => InkWell(
          onTap: on ? () => onChanged(next) : null,
          child: SizedBox(
            width: 34, height: 32,
            child: Icon(icon, size: 18,
                color: on ? theme.colorScheme.primary : Halved.disabledText),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // Clamped at both ends rather than wrapping: a stepper that jumps from
        // 1 to 4 changes the game while the TD is only nudging it.
        btn(Icons.remove, value - 1, value > min),
        SizedBox(
          width: 34,
          child: Text('$value', textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ),
        btn(Icons.add, value + 1, value < max),
      ]),
    );
  }
}

class _Readback extends StatelessWidget {
  final String label, value;
  const _Readback(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.circle, size: 8, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(label, style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(value, style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

class _AutoTag extends StatelessWidget {
  const _AutoTag();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('AUTO',
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700, letterSpacing: 0.5,
              color: theme.colorScheme.primary)),
    );
  }
}

class _LockedModeChip extends StatelessWidget {
  final String mode;
  final int netPercent;
  const _LockedModeChip({required this.mode, required this.netPercent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (mode) {
      'gross'       => 'Gross',
      'strokes_off' => 'Strokes off the low man',
      _             => 'Net $netPercent%',
    };
    return SectionCard(
      title: 'Handicap',
      trailing: const Chip(
        label: Text('Set for the round', style: TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
      child: Text(
        '$label. A tournament sets this once, at round level — a game cannot '
        'override it.',
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant, height: 1.45),
      ),
    );
  }
}

class _BorrowedFourthNotice extends StatelessWidget {
  const _BorrowedFourthNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.groups_2_outlined,
              size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              const TextSpan(children: [
                // It TELLS rather than asks — the borrowed 4th is built when
                // the round is created, and only when some other group has
                // four to level up to.
                TextSpan(text: 'Borrowed 4th. ',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(
                  text: 'This round mixes a threesome with a foursome, so each '
                      'threesome plays a borrowed 4th — a ball taken from every '
                      'real golfer in the other groups, in one fixed rotation, '
                      "scored on the donor's own net off his own tee. Nothing "
                      'to set. If that group wins, the place splits among its '
                      'three real golfers — the borrowed ball is not a person '
                      'and cannot be paid.',
                ),
              ]),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExclusionNotice extends StatelessWidget {
  const _ExclusionNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Halved.cautionGround,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: Halved.caution),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This round is already running Irish Rumble. Better Ball ranks '
              'the same groups the same way, so a round runs one or the other '
              '— turn Irish Rumble off first.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Halved.caution, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
