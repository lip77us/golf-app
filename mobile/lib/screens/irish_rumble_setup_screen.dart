/// screens/irish_rumble_setup_screen.dart
/// ----------------------------------------
/// Setup screen for the Irish Rumble tournament game (round-level).
///
/// Knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + Net % allowance
///   • Entry fee per foursome + explicit payout structure
///
/// The segment structure is always the standard Irish Rumble format:
///   Holes 1–6   → best 1 net per group
///   Holes 7–12  → best 2 nets per group
///   Holes 13–17 → best 3 nets per group
///   Hole 18     → all 4 nets per group
///
/// The net-double-bogey cap (per-hole net par + 2 max) honors the
/// round-level `Round.net_max_double_bogey` flag; toggle it here.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../utils/primary_handicap.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/inherited_handicap_note.dart';
import '../widgets/payout_config_field.dart';
import '../widgets/section_card.dart';
import '../widgets/net_double_bogey_card.dart';

class IrishRumbleSetupScreen extends StatefulWidget {
  final int roundId;
  const IrishRumbleSetupScreen({super.key, required this.roundId});

  @override
  State<IrishRumbleSetupScreen> createState() => _IrishRumbleSetupScreenState();
}

class _IrishRumbleSetupScreenState extends State<IrishRumbleSetupScreen> {
  String _mode       = 'net';
  int    _netPercent = 100;
  final  _entryCtrl  = TextEditingController(text: '5');
  bool _noStakes = false;

  // Payout rows: a fixed 4 controllers (only the first [_payoutPlaces] are
  // active), matching the shared PayoutConfigField.  Values are GROUP TOTALS —
  // the prize for finishing in that place, before splitting among the winning
  // group's members.  Per-player amounts show as a breakdown under each field.
  final List<TextEditingController> _payoutCtrls =
      List.generate(4, (_) => TextEditingController());
  int _payoutPlaces  = 1;
  int _numPlayers    = 0; // fetched from API for pool-balance validation
  /// Player count per foursome (e.g. [4, 3]) — drives the per-group-size
  /// per-player breakdown shown under each payout field.
  List<int> _groupSizes = const [];

  // 2-step wizard: 0 = game (variant/handicap), 1 = money (entry fee/payouts).
  int _step = 0;

  // ── Variant ───────────────────────────────────────────────────────────────
  /// One of: 'classic', 'arizona_shuffle', 'shuffle', 'custom'.
  String _variant = 'classic';
  /// Per-hole balls (1-4) for the custom variant.  Mirrors the backend's
  /// custom_balls list; ignored for named variants.  Default to 2 per
  /// hole so the picker starts in a reasonable middle state.
  List<int> _customBalls = List<int>.filled(18, 2);
  /// Course pars per hole — fetched from the API and used by the Shuffle
  /// variant preview + the Custom variant's per-hole "Par N" label.
  List<int> _holePars   = List<int>.filled(18, 4);

  bool    _loading           = true;
  bool    _saving            = false;
  Object? _error;
  bool    _configured        = false;
  /// True when this is a tournament round — handicap mode is locked at
  /// the round level and the picker is hidden in favour of a read-only chip.
  bool    _isTournamentRound = false;

  @override
  void initState() {
    super.initState();
    _entryCtrl.addListener(() => setState(() {
      if ((double.tryParse(_entryCtrl.text.trim()) ?? 0) > 0 && _noStakes) _noStakes = false;
    }));
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

  double get _allocated => _payoutCtrls
      .take(_payoutPlaces)
      .fold(0.0, (s, c) => s + (double.tryParse(c.text.trim()) ?? 0.0));

  /// Start gate: an entry fee entered, or "no stakes" ticked.
  bool get _stakeChosen =>
      _noStakes || (double.tryParse(_entryCtrl.text.trim()) ?? 0) > 0;

  bool get _poolBalanced {
    if (_numPlayers == 0) return true;
    if (_pool <= 0) return true;
    // Integer-dollar payouts (shared widget) — compare on rounded dollars.
    return _pool.round() == _allocated.round();
  }

  /// True when the round mixes sizes such that a true threesome will be leveled
  /// with a borrowed-4th phantom — some group has 3 real players AND another has
  /// 4 to level up to.  Matches the backend's ensure_irish_rumble_phantom guard:
  /// an all-threesome field (3-on-3-on-3) is NOT leveled, so no notice.
  bool get _hasLeveledThreesome =>
      _groupSizes.contains(3) && _groupSizes.any((n) => n >= 4);

  /// Distinct foursome sizes in this round, sorted descending (foursome,
  /// threesome, …).  Used to compute the per-player payout breakdown.
  List<int> get _distinctGroupSizes {
    final set = _groupSizes.where((n) => n > 0).toSet().toList()..sort((a, b) => b.compareTo(a));
    return set;
  }

  static String _groupSizeLabel(int n) {
    switch (n) {
      case 1: return 'solo';
      case 2: return 'twosome';
      case 3: return 'threesome';
      case 4: return 'foursome';
      default: return '$n-some';
    }
  }

  /// Per-place helper text showing the per-player split for each distinct
  /// group size, e.g. "Splits to $8.75/player (foursome) • $11.67/player
  /// (threesome)."  Returns null when the amount is zero or when the round
  /// has no configured foursomes yet.
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
      final cfg    = await client.getIrishRumbleConfig(widget.roundId);
      if (!mounted) return;

      final payouts = (cfg['payouts'] as List? ?? []);

      final groupSizes = (cfg['group_sizes'] as List? ?? [])
          .map((e) => (e as num).toInt())
          .toList();

      // Course pars — 18 values, fallback 4 if shorter for any reason.
      final holePars = <int>[
        for (var i = 0; i < 18; i++)
          (i < (cfg['hole_pars'] as List? ?? []).length)
              ? ((cfg['hole_pars'] as List)[i] as num).toInt()
              : 4,
      ];

      // Variant + custom_balls — fall back to safe defaults if missing.
      final variant     = (cfg['variant'] as String?) ?? 'classic';
      final cbRaw       = cfg['custom_balls'] as List?;
      final customBalls = cbRaw != null && cbRaw.length == 18
          ? cbRaw.map((e) => (e as num).toInt()).toList()
          : List<int>.filled(18, 2);

      setState(() {
        _configured        = cfg['configured'] as bool? ?? false;
        _isTournamentRound = cfg['is_tournament_round'] as bool? ?? false;
        _mode       = (cfg['round_handicap_mode'] ?? cfg['handicap_mode'])
                          ?.toString() ?? 'net';
        _netPercent = (cfg['round_net_percent'] ?? cfg['net_percent']) as int? ?? 100;
        _numPlayers        = cfg['num_players'] as int? ?? 0;
        _groupSizes        = groupSizes;
        _entryCtrl.text    = _fmtAmount(cfg['entry_fee'] as num? ?? 5.0);
        // Fill the fixed 4 controllers; active place count = highest non-zero.
        int places = 0;
        for (int i = 0; i < 4; i++) {
          final amt = i < payouts.length
              ? (double.tryParse(payouts[i]['amount']?.toString() ?? '') ?? 0.0)
              : 0.0;
          _payoutCtrls[i].text = amt > 0 ? _fmtAmount(amt) : '';
          if (amt > 0) places = i + 1;
        }
        _payoutPlaces      = places.clamp(1, 4);
        _variant           = variant;
        _customBalls       = customBalls;
        _holePars          = holePars;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _save() async {
    if (!_poolBalanced) {
      setState(() {
        _error = Exception(
          'Payouts total \$${_allocated.toStringAsFixed(2)}, '
          'pool is \$${_pool.toStringAsFixed(2)}.',
        );
      });
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final client   = context.read<AuthProvider>().client;
      final entryFee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
      final payouts  = <Map<String, dynamic>>[];
      for (int i = 0; i < _payoutPlaces; i++) {
        // Stored as the group total prize for that place — split among
        // the winning group's members at payout time.
        final groupTotal = double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0;
        payouts.add({'place': i + 1, 'amount': groupTotal});
      }
      await client.postIrishRumbleSetup(
        widget.roundId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        entryFee:     entryFee,
        payouts:      payouts,
        variant:      _variant,
        customBalls:  _variant == 'custom' ? _customBalls : null,
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
      appBar: AppBar(title: Text(
          _step == 0 ? 'Irish Rumble · Game' : 'Irish Rumble · Money')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _loading == false && !_saving
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : Column(children: [
                  Expanded(child: _step == 0 ? _gameBody() : _moneyBody()),
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
            onPressed: (_saving || !_poolBalanced || !_stakeChosen) ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_configured ? 'Save Changes' : 'Save Setup',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
      ]),
    );
  }

  // ── Step 1: game (variant + handicap) ──
  Widget _gameBody() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Borrowed-4th notice (mixed group sizes) ─────────────────────
          if (_hasLeveledThreesome) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.groups_2_outlined,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: const [
                        TextSpan(
                          text: 'Threesome leveling. ',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: 'This round mixes a threesome with a foursome, '
                              'so each threesome is given a 4th ball borrowed '
                              'from the rest of the field — every group then '
                              'counts the same number of balls. Tip: tee the '
                              'threesome off last so its donors have already '
                              'posted.',
                        ),
                      ]),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          // ── Variant picker + segment preview ────────────────────────────
          _VariantPicker(
            variant:  _variant,
            onChanged: (v) => setState(() => _variant = v),
          ),
          const SizedBox(height: 12),
          _SegmentPreview(
            variant:     _variant,
            holePars:    _holePars,
            customBalls: _customBalls,
          ),
          if (_variant == 'custom') ...[
            const SizedBox(height: 12),
            _CustomBallsEditor(
              holePars:    _holePars,
              customBalls: _customBalls,
              onChanged: (idx, v) => setState(() => _customBalls[idx] = v),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Each score may be capped at net par + 2 first — see the '
            'Net Double-Bogey Cap toggle below.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),

          const SizedBox(height: 16),

          // ── Handicap mode ───────────────────────────────────────────────
          if (_isTournamentRound)
            _LockedHandicapChip(mode: _mode, netPercent: _netPercent)
          else
            HandicapModeSelector(
              mode:             _mode,
              netPercent:       _netPercent,
              onModeChanged:    (m) => setState(() => _mode = m),
              onPercentChanged: (p) => setState(() => _netPercent = p),
              soNote: 'Strokes are based on the lowest handicap across all '
                  'players in the tournament round — not just within each group.',
            ),

          const SizedBox(height: 16),

          // ── Net double-bogey cap (round-level) ──────────────────────────
          Builder(builder: (ctx) {
            final round = ctx.watch<RoundProvider>().round;
            if (round == null) return const SizedBox.shrink();
            return NetDoubleBogeyCard(
              handicapMode: _mode, netPercent: _netPercent,
              value: round.netMaxDoubleBogey,
              onChanged: (v) =>
                  ctx.read<RoundProvider>().updateRoundNetMaxDoubleBogey(v),
            );
          }),
        ],
      ),
    );
  }

  // ── Step 2: money (entry fee + payouts) ──
  Widget _moneyBody() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Entry fee ───────────────────────────────────────────────────
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
                Text(
                  'Collected from each player. '
                  'Total pool = entry fee × number of players.',
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

          // ── Payout structure ────────────────────────────────────────────
          SectionCard(
            title: 'Payouts',
            // Shared payout construct. Each place is a GROUP TOTAL; the per-
            // player breakdown shows under each field since Irish Rumble is a
            // foursome-vs-foursome/threesome game.
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

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const LowNetSetupScreen({
    super.key,
    required this.roundId,
    this.returnToHub = false,
  });

  @override
  State<LowNetSetupScreen> createState() => _LowNetSetupScreenState();
}

class _LowNetSetupScreenState extends State<LowNetSetupScreen> {
  String _mode       = 'net';
  int    _netPercent = 100;
  final  _entryCtrl  = TextEditingController(text: '5');
  bool _noStakes = false;

  // Payout rows: each is a {place, amount} controller pair
  final List<TextEditingController> _payoutCtrls =
      List.generate(4, (_) => TextEditingController());
  int _payoutPlaces = 1;
  int _numPlayers   = 0; // fetched from API for pool-balance validation

  // Prize exclusions
  /// Player IDs currently toggled as excluded (cannot win prizes).
  final Set<int> _excludedIds = {};
  /// Players suggested for exclusion because they placed in the championship.
  /// Each entry: {'player_id': int, 'player_name': str, 'rank': int, 'payout': num}
  List<Map<String, dynamic>> _championshipPlacers = [];
  bool    _loading           = true;
  bool    _saving            = false;
  Object? _error;
  bool    _configured        = false;
  /// True when editing an already-configured game (drives Save label + title).
  bool    _editing           = false;
  bool    _isTournamentRound = false;

  /// True when Stroke Play is a SECONDARY side game (another game owns entry).
  /// Side games inherit the primary's handicap — no own selector.
  bool get _isSideGame {
    final games = context.read<RoundProvider>().round?.activeGames ??
        const <String>[];
    return games.contains('low_net_round') &&
        primaryGameOf(games) != 'low_net_round';
  }

  @override
  void initState() {
    super.initState();
    // Rebuild whenever entry fee changes so pool balance recalculates live.
    _entryCtrl.addListener(() => setState(() {
      if ((double.tryParse(_entryCtrl.text.trim()) ?? 0) > 0 && _noStakes) _noStakes = false;
    }));
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

  // Casual Stroke Play keeps a fixed list of 4 payout controllers (parity with
  // Stableford's PayoutConfigField) of which only the first `_payoutPlaces` are
  // active; tournament rounds size the list to the place count. Bound the sum
  // by `_payoutPlaces` so padded/stale casual slots don't count.
  double get _allocated {
    var s = 0.0;
    final n = _payoutPlaces.clamp(0, _payoutCtrls.length);
    for (var i = 0; i < n; i++) {
      s += double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0;
    }
    return s;
  }

  /// True when payouts balance the pool (or there is no pool to balance).
  /// Start gate: an entry fee entered, or "no stakes" ticked.
  bool get _stakeChosen =>
      _noStakes || (double.tryParse(_entryCtrl.text.trim()) ?? 0) > 0;

  bool get _poolBalanced {
    if (_numPlayers == 0) return true;           // round not yet set up
    if (_pool <= 0) return true;                 // no entry fee → skip check
    if (_payoutPlaces == 0) return _pool == 0;   // no places → must be free
    return (_pool - _allocated).abs() < 0.01;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final cfg    = await client.getLowNetConfig(widget.roundId);

      // Side games inherit the PRIMARY game's handicap. Stroke Play here is
      // only ever net/gross as a side game, so a strokes-off primary degrades
      // to net.
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

      // Fixed 4 controllers (shared PayoutConfigField reads the first
      // `_payoutPlaces`). Derive the active place count from the saved payouts;
      // a fresh round seeds a single place holding the whole pool.
      final payouts = (cfg['payouts'] as List? ?? []);
      final amounts = List<double>.filled(4, 0.0);
      int placesCount = 0;
      for (int i = 0; i < 4 && i < payouts.length; i++) {
        amounts[i] = double.tryParse(payouts[i]['amount']?.toString() ?? '') ?? 0.0;
        if (amounts[i] > 0) placesCount = i + 1;
      }
      if (payouts.isEmpty) {
        final pool = (cfg['entry_fee'] as num? ?? 5.0).toDouble() *
            (cfg['num_players'] as int? ?? 0);
        if (pool > 0) amounts[0] = pool.roundToDouble();
      }
      placesCount = placesCount.clamp(1, 4);

      // Prize exclusions
      final excludedList = (cfg['excluded_player_ids'] as List? ?? [])
          .map((e) => e as int)
          .toList();
      final placers = (cfg['championship_placers'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      setState(() {
        _configured        = cfg['configured'] as bool? ?? false;
        // A configured game means we're editing saved settings → drives the
        // "Save Configuration" label + "Edit Stroke Play" title.
        _editing           = _configured;
        _isTournamentRound = cfg['is_tournament_round'] as bool? ?? false;
        // For tournament rounds the mode is locked at the round level;
        // fall back to the stored game config value for casual rounds.
        _mode              = (cfg['round_handicap_mode'] ?? cfg['handicap_mode'])
                                 ?.toString() ?? 'net';
        _netPercent        = (cfg['round_net_percent'] ?? cfg['net_percent']) as int? ?? 100;
        if (inherited != null) {
          _mode       = inherited.$1;
          _netPercent = inherited.$2;
        }
        _numPlayers        = cfg['num_players'] as int? ?? 0;
        _entryCtrl.text    = _fmtAmount(cfg['entry_fee'] as num? ?? 5.0);
        _payoutPlaces      = placesCount;
        for (int i = 0; i < 4; i++) {
          _payoutCtrls[i].text = amounts[i] > 0 ? _fmtAmount(amounts[i]) : '';
        }
        // Exclusions
        _excludedIds
          ..clear()
          ..addAll(excludedList);
        _championshipPlacers = placers;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// Auto-suggest: distribute the pool across the current places using the same
  /// fixed splits as Stableford / Match Play (suggestPayouts).
  void _suggest() {
    final pool = _pool.round();
    if (pool <= 0) return;
    final amounts = suggestPayouts(pool, _payoutPlaces);
    setState(() {
      for (var i = 0; i < _payoutPlaces; i++) {
        _payoutCtrls[i].text = amounts[i] == 0 ? '' : '${amounts[i]}';
      }
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
      // Capture the provider before any await so we don't touch context
      // across the async gap in the returnToHub branch below.
      final rp       = context.read<RoundProvider>();
      final entryFee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
      final payouts  = <Map<String, dynamic>>[];
      // Only the first `_payoutPlaces` controllers are active (casual pads the
      // list to 4); tournament rounds size the list to the place count.
      final placeCount = _payoutPlaces.clamp(0, _payoutCtrls.length);
      for (int i = 0; i < placeCount; i++) {
        final amt = double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0;
        payouts.add({'place': i + 1, 'amount': amt});
      }
      await client.postLowNetSetup(
        widget.roundId,
        handicapMode:      _mode,
        netPercent:        _netPercent,
        entryFee:          entryFee,
        payouts:           payouts,
        excludedPlayerIds: _excludedIds.toList(),
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
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_editing ? 'Edit Stroke Play' : 'Stroke Play — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && !_loading && !_saving
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : Column(children: [
                  Expanded(child: _buildBody()),
                  // Persistent Save button — in-body so it stays above
                  // the soft keyboard when the entry-fee / payout fields
                  // are open.
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed:
                              (_saving || !_poolBalanced || !_stakeChosen) ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(
                                  _editing ? 'Save Configuration' : 'Save Setup',
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  // ── Ordinal helper ───────────────────────────────────────────────────────

  String _ordinal(int n) {
    if (n == 1) return '1st';
    if (n == 2) return '2nd';
    if (n == 3) return '3rd';
    return '${n}th';
  }

  // ── Prize Exclusions section ──────────────────────────────────────────────

  Widget _buildExclusionsSection(ThemeData theme) {
    // Build the full player list from the API response. Since getLowNetConfig
    // doesn't currently return the player roster, we derive it from the
    // championship placers list + any already-excluded IDs stored on config.
    // For non-placer excluded players we show just an ID (rare edge case).
    //
    // Players are shown in two groups:
    //   1. Championship placers (auto-suggested, with rank + payout info)
    //   2. Other excluded players (manually excluded, no placer data)
    final placerIds = _championshipPlacers.map((p) => p['player_id'] as int).toSet();

    // Collect non-placer excluded players (manually added exclusions)
    final nonPlacerExcluded = _excludedIds.where((id) => !placerIds.contains(id)).toList();

    final hasSuggestions = _championshipPlacers.isNotEmpty;

    return SectionCard(
      title: 'Prize Exclusions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Excluded players still appear in the standings '
            'but cannot win prize money.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),

          // ── Championship placers suggestion banner ─────────────────────
          if (hasSuggestions) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withOpacity(0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.colorScheme.secondary.withOpacity(0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.emoji_events_outlined,
                        size: 16, color: theme.colorScheme.secondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Championship placers — suggested exclusions',
                        style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.secondary,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    'These players won prize money in the Stroke Play '
                    'Championship and are suggested for exclusion from '
                    'the Day 2 Stroke Play prize.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                          color: theme.colorScheme.secondary.withOpacity(0.5)),
                    ),
                    onPressed: () => setState(() {
                      for (final p in _championshipPlacers) {
                        _excludedIds.add(p['player_id'] as int);
                      }
                    }),
                    icon: const Icon(Icons.select_all, size: 16),
                    label: const Text('Exclude all placers'),
                  ),
                ],
              ),
            ),
          ],

          // ── Toggle list for championship placers ───────────────────────
          if (hasSuggestions) ...[
            const SizedBox(height: 8),
            ...(_championshipPlacers.map((p) {
              final pid    = p['player_id'] as int;
              final name   = p['player_name'] as String? ?? 'Player $pid';
              final rank   = p['rank'] as int? ?? 0;
              final payout = p['payout'];
              final payStr = payout != null
                  ? '\$${(payout as num).toStringAsFixed(2)}'
                  : '';
              return CheckboxListTile(
                value: _excludedIds.contains(pid),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(name),
                subtitle: Text(
                  '${_ordinal(rank)} place${ payStr.isNotEmpty ? " · $payStr" : ""}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                secondary: Icon(
                  Icons.emoji_events,
                  size: 18,
                  color: theme.colorScheme.secondary.withOpacity(0.7),
                ),
                onChanged: (v) => setState(() {
                  if (v == true) _excludedIds.add(pid);
                  else           _excludedIds.remove(pid);
                }),
              );
            })),
          ],

          // ── Non-placer excluded players ────────────────────────────────
          if (nonPlacerExcluded.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Other excluded players',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            ...nonPlacerExcluded.map((pid) => CheckboxListTile(
              value: true,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('Player #$pid'),
              onChanged: (v) => setState(() {
                if (v != true) _excludedIds.remove(pid);
              }),
            )),
          ],

          if (!hasSuggestions && _excludedIds.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'No championship placers found. '
                'Run the championship Stroke Play setup first.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
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
          // Side games inherit the primary game's handicap (no own selector).
          if (_isTournamentRound)
            _LockedHandicapChip(mode: _mode, netPercent: _netPercent)
          else if (_isSideGame)
            InheritedHandicapNote(mode: _mode, netPercent: _netPercent)
          else
            HandicapModeSelector(
              mode:             _mode,
              netPercent:       _netPercent,
              onModeChanged:    (m) => setState(() => _mode = m),
              onPercentChanged: (p) => setState(() => _netPercent = p),
              soNote: 'Strokes are based on the lowest handicap across all '
                  'players in the tournament round.',
            ),

          const SizedBox(height: 16),

          // ── Net double-bogey cap (round-level) ──────────────────────────
          Builder(builder: (ctx) {
            final round = ctx.watch<RoundProvider>().round;
            if (round == null) return const SizedBox.shrink();
            return NetDoubleBogeyCard(
              handicapMode: _mode, netPercent: _netPercent,
              value: round.netMaxDoubleBogey,
              onChanged: (v) =>
                  ctx.read<RoundProvider>().updateRoundNetMaxDoubleBogey(v),
            );
          }),

          const SizedBox(height: 16),

          // ── Entry fee ───────────────────────────────────────────────────
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
                Text(
                  'Collected from each player before the round.',
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

          // ── Payout structure ────────────────────────────────────────────
          SectionCard(
            title: 'Payouts',
            // Shared payout construct (individual overall payout — no per-player
            // breakdown). Same for casual and tournament Stroke Play.
            child: PayoutConfigField(
              pool:                _pool.round(),
              numPayouts:          _payoutPlaces.clamp(1, 4),
              payoutCtrls:         _payoutCtrls,
              onNumPayoutsChanged: (n) => setState(() => _payoutPlaces = n),
              onPayoutChanged:     () => setState(() {}),
              onSuggest:           _suggest,
            ),
          ),

          // ── Prize Exclusions (tournament rounds only) ───────────────
          if (_isTournamentRound) ...[
            const SizedBox(height: 16),
            _buildExclusionsSection(theme),
          ],

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
// Variant picker + preview + per-hole editor (custom)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the per-hole balls-to-count for a variant.  Mirrors the
/// backend's `_balls_per_hole` so the preview shown in the picker matches
/// what the server will actually compute at save time.
List<int> _ballsPerHole({
  required String   variant,
  required List<int> holePars,
  required List<int> customBalls,
}) {
  switch (variant) {
    case 'arizona_shuffle':
      const pattern = [1, 2, 3, 1, 2, 3];
      return List.generate(18, (i) => pattern[i ~/ 3]);
    case 'shuffle':
      return List.generate(18, (i) {
        final par = holePars[i];
        if (par == 3) return 3;
        if (par == 4) return 2;
        if (par == 5) return 1;
        return 2;
      });
    case 'custom':
      return List<int>.from(customBalls);
    case 'classic':
    default:
      return List.generate(18, (i) {
        final h = i + 1;
        if (h <= 6) return 1;
        if (h <= 12) return 2;
        if (h <= 17) return 3;
        return 4;
      });
  }
}

/// Group an 18-element per-hole list into contiguous-same-value runs
/// for compact display ("Holes 7-9 · best 3").
List<({int start, int end, int balls})> _collapseRuns(List<int> perHole) {
  final out = <({int start, int end, int balls})>[];
  var segStart = 1;
  var curBalls = perHole[0];
  for (var i = 1; i < 18; i++) {
    if (perHole[i] != curBalls) {
      out.add((start: segStart, end: i, balls: curBalls));
      segStart = i + 1;
      curBalls = perHole[i];
    }
  }
  out.add((start: segStart, end: 18, balls: curBalls));
  return out;
}

class _VariantPicker extends StatelessWidget {
  final String variant;
  final ValueChanged<String> onChanged;
  const _VariantPicker({required this.variant, required this.onChanged});

  static const _options = [
    ('classic',         'Classic',
     'Builds up: 1 ball, then 2, then 3, then all 4 on the closer.'),
    ('arizona_shuffle', 'Arizona Shuffle',
     'Rotate every 3 holes — 1 / 2 / 3 / 1 / 2 / 3 across the 18.'),
    ('shuffle',         'Shuffle (par-based)',
     'Par 3 = 3 balls, Par 4 = 2 balls, Par 5 = 1 ball.'),
    ('custom',          'Custom (per-hole)',
     'You pick how many balls count on each of the 18 holes.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Variant',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final opt in _options)
            InkWell(
              onTap: () => onChanged(opt.$1),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Radio<String>(
                      value: opt.$1,
                      groupValue: variant,
                      onChanged: (v) { if (v != null) onChanged(v); },
                      visualDensity: VisualDensity.compact,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(opt.$2,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(opt.$3,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentPreview extends StatelessWidget {
  final String   variant;
  final List<int> holePars;
  final List<int> customBalls;
  const _SegmentPreview({
    required this.variant,
    required this.holePars,
    required this.customBalls,
  });

  @override
  Widget build(BuildContext context) {
    final perHole = _ballsPerHole(
      variant: variant, holePars: holePars, customBalls: customBalls,
    );
    final runs = _collapseRuns(perHole);
    return SectionCard(
      title: 'Segment Preview',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in runs)
            _SegmentRow(
              r.start == r.end ? 'Hole ${r.start}'
                                : 'Holes ${r.start}–${r.end}',
              r.balls == 1 ? 'Best 1 net per group'
                           : 'Best ${r.balls} nets per group',
            ),
        ],
      ),
    );
  }
}

class _CustomBallsEditor extends StatelessWidget {
  final List<int> holePars;
  final List<int> customBalls;
  final void Function(int holeIdx, int value) onChanged;
  const _CustomBallsEditor({
    required this.holePars,
    required this.customBalls,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget holeCell(int idx) {
      final hole = idx + 1;
      final par  = holePars[idx];
      final val  = customBalls[idx];
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$hole',
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text('Par $par',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10)),
            const SizedBox(height: 4),
            // Step the balls value 1→2→3→4→1 on tap.  Tight cycling
            // beats a full picker when there are 18 cells on screen.
            InkWell(
              onTap: () => onChanged(idx, val >= 4 ? 1 : val + 1),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 28, height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text('$val',
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      );
    }

    return SectionCard(
      title: 'Per-hole balls (tap to cycle 1→2→3→4)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Front 9',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Row(children: [
            for (var i = 0; i < 9; i++) Expanded(child: holeCell(i)),
          ]),
          const SizedBox(height: 10),
          Text('Back 9',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Row(children: [
            for (var i = 9; i < 18; i++) Expanded(child: holeCell(i)),
          ]),
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
      case 'strokes_off': return netPercent == 100 ? 'Strokes Off Low' : 'Strokes Off Low ($netPercent%)';
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
