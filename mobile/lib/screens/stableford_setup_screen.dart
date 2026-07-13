/// screens/stableford_setup_screen.dart
/// Casual Stableford setup: handicap (Net% or Gross — no Strokes-Off), an
/// editable 6-bucket points table with three presets, and Low-Net-style money
/// (entry fee + paid places via the shared PayoutConfigField).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/payout_config_field.dart';

// Bucket order, top (best) to bottom.
const _kBuckets = ['albatross', 'eagle', 'birdie', 'par', 'bogey', 'double'];
const _kBucketLabels = {
  'albatross': 'Albatross or better',
  'eagle': 'Eagle',
  'birdie': 'Birdie',
  'par': 'Par',
  'bogey': 'Bogey',
  'double': 'Double bogey or worse',
};
const _kPresets = <String, Map<String, int>>{
  'Standard':       {'albatross': 5, 'eagle': 4, 'birdie': 3, 'par': 2, 'bogey': 1,  'double': 0},
  'Modified (pro)': {'albatross': 8, 'eagle': 5, 'birdie': 2, 'par': 0, 'bogey': -1, 'double': -3},
  'Reward birdies': {'albatross': 6, 'eagle': 4, 'birdie': 3, 'par': 1, 'bogey': 0,  'double': -1},
};

class StablefordSetupScreen extends StatefulWidget {
  final int roundId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const StablefordSetupScreen({
    super.key,
    required this.roundId,
    this.returnToHub = false,
  });

  @override
  State<StablefordSetupScreen> createState() => _StablefordSetupScreenState();
}

class _StablefordSetupScreenState extends State<StablefordSetupScreen> {
  String _mode = 'net';
  int _netPercent = 100;

  String _payoutStyle = 'pool';        // 'pool' | 'per_point'
  String _perPointMode = 'average';    // 'average' | 'all' | 'first'
  bool _advancedOpen = false;          // loss-cap expander (per-point)
  final _entryCtrl  = TextEditingController(text: '5');
  final _rateCtrl   = TextEditingController(text: '1'); // $/point (per_point)
  bool _noStakes = false;
  int _numPlayers = 0;

  /// Players IN the game. null = all real players (a full-foursome game); a set
  /// = a SUBSET side game (docs/parallel-games.md).
  Set<int>? _participantIds;

  /// Real (non-phantom) players in the round — the participant picker roster.
  List<({int id, String name})> get _realPlayers {
    final round = context.read<RoundProvider>().round;
    if (round == null) return const [];
    final seen = <int>{};
    final out = <({int id, String name})>[];
    for (final fs in round.foursomes) {
      for (final m in fs.memberships) {
        if (m.player.isPhantom || !seen.add(m.player.id)) continue;
        out.add((id: m.player.id, name: m.player.name));
      }
    }
    return out;
  }

  /// Player count the pool/gate use — the subset size, else all.
  int get _participantCount => _participantIds?.length ?? _numPlayers;

  bool get _participantsValid =>
      _participantIds == null || _participantIds!.length >= 2;

  /// The list to POST: empty when everyone's in (= all, backward compatible),
  /// else the chosen subset.
  List<int> _participantsToSend() {
    final all = _realPlayers.map((p) => p.id).toSet();
    final sel = _participantIds;
    if (sel == null || sel.length >= all.length) return const [];
    return sel.toList();
  }

  Widget _participantCard(ThemeData theme) {
    final players = _realPlayers;
    if (players.length < 3) return const SizedBox.shrink(); // 2 → both are in
    bool isIn(int id) => _participantIds?.contains(id) ?? true;
    return Column(children: [
      _card(theme, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Who's in the bet",
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          Text('Everyone by default — or pick a subset for a side bet.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          for (final p in players)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: isIn(p.id),
              title: Text(p.name),
              onChanged: (v) => setState(() {
                final set = _participantIds ?? players.map((e) => e.id).toSet();
                if (v == true) { set.add(p.id); } else { set.remove(p.id); }
                // Collapse to null (= all) when everyone's in.
                _participantIds = set.length == players.length ? null : set;
              }),
            ),
          if (!_participantsValid)
            Text('Pick at least 2 players.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
        ],
      )),
      const SizedBox(height: 16),
    ]);
  }

  // Optional per-player loss cap (per_point only). Off by default — unlike
  // 5-3-1 the points table is editable, so there's no fixed "max loss" to
  // pre-fill; the player opts in and sets an amount.
  bool _capEnabled = false;
  final _capCtrl = TextEditingController();

  final _points = {for (final b in _kBuckets) b: TextEditingController()};

  final _payoutCtrls =
      List<TextEditingController>.generate(4, (_) => TextEditingController());
  int _numPayouts = 0;

  bool _loading = true;
  bool _saving  = false;
  /// True when editing an already-configured game (drives Save label + title).
  bool _editing = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _entryCtrl.addListener(_onStakeChanged);
    _rateCtrl.addListener(_onStakeChanged);
    _load();
  }

  /// Re-evaluate the Start gate as the active stake field changes; entering a
  /// real amount clears the "no stakes" opt-in.
  void _onStakeChanged() {
    final ctrl = _payoutStyle == 'pool' ? _entryCtrl : _rateCtrl;
    if ((double.tryParse(ctrl.text.trim()) ?? 0) > 0 && _noStakes) {
      _noStakes = false;
    }
    setState(() {});
  }

  /// Start gate: a positive entry fee (pool) or rate (per-point) entered, or
  /// "no stakes" ticked.
  bool get _stakeChosen {
    if (_noStakes) return true;
    final ctrl = _payoutStyle == 'pool' ? _entryCtrl : _rateCtrl;
    return (double.tryParse(ctrl.text.trim()) ?? 0) > 0;
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _rateCtrl.dispose();
    _capCtrl.dispose();
    for (final c in _points.values) c.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  double get _pool { // uses the participant count (subset side game shrinks it)
    final fee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
    return fee * _participantCount;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final cfg = await client.getStablefordConfig(widget.roundId);

      if (!mounted) return;
      setState(() {
        _numPlayers = cfg['num_players'] as int? ?? 0;
        // Hydrate the participant subset (empty/absent = all players).
        final pids = (cfg['participant_player_ids'] as List?)
            ?.map((e) => e as int).toList() ?? const <int>[];
        _participantIds = pids.isEmpty ? null : pids.toSet();
        final mode = (cfg['handicap_mode']?.toString() ?? 'net');
        _mode = (mode == 'gross') ? 'gross' : 'net';
        _netPercent = cfg['net_percent'] as int? ?? 100;
        _payoutStyle = (cfg['payout_style']?.toString() == 'per_point')
            ? 'per_point' : 'pool';
        final ppm = cfg['per_point_mode']?.toString();
        _perPointMode = (ppm == 'first' || ppm == 'all') ? ppm! : 'average';
        final cap = (cfg['loss_cap'] as num?)?.toDouble();
        _capEnabled = cap != null;
        if (cap != null) _capCtrl.text = _fmt(cap);
        _rateCtrl.text   = _fmt(cfg['per_point_rate'] as num? ?? 1);
        _entryCtrl.text  = _fmt(cfg['entry_fee'] as num? ?? 5);
        for (final b in _kBuckets) {
          _points[b]!.text = '${cfg['pts_$b'] ?? _kPresets['Standard']![b]}';
        }
        final payouts = (cfg['payouts'] as List? ?? []);
        // A configured Stableford game persists a payout structure; a fresh
        // round comes back with none. Non-empty payouts is the "already set
        // up" tell → enter edit mode (Save Configuration / "Edit Stableford").
        _editing = payouts.isNotEmpty;
        if (payouts.isEmpty) {
          // Fresh round → default to winner-take-all so the pool is visibly
          // allocated; the user bumps places / re-suggests from there.
          final pool = (double.tryParse(_entryCtrl.text.trim()) ?? 0) * _participantCount;
          _numPayouts = 1;
          _payoutCtrls[0].text = _fmt(pool);
          for (var i = 1; i < 4; i++) _payoutCtrls[i].text = '0';
        } else {
          _numPayouts = payouts.length.clamp(0, 4);
          for (var i = 0; i < 4; i++) {
            _payoutCtrls[i].text = i < payouts.length
                ? _fmt(double.tryParse(payouts[i]['amount']?.toString() ?? '') ?? 0)
                : '0';
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  String _fmt(num n) => n == n.roundToDouble() ? n.toInt().toString() : '$n';

  void _applyPreset(Map<String, int> table) {
    setState(() {
      for (final b in _kBuckets) _points[b]!.text = '${table[b]}';
    });
  }

  void _suggest() {
    final amounts = suggestPayouts(_pool.round(), _numPayouts);
    setState(() {
      for (var i = 0; i < 4; i++) _payoutCtrls[i].text = '${amounts[i]}';
    });
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      // Capture the provider before any await so we don't touch context
      // across the async gap in the returnToHub branch below.
      final rp = context.read<RoundProvider>();
      final payouts = <Map<String, dynamic>>[
        for (var i = 0; i < _numPayouts; i++)
          {'place': i + 1,
           'amount': double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0},
      ];
      await context.read<AuthProvider>().client.postStablefordSetup(
        widget.roundId,
        handicapMode: _mode,
        netPercent: _netPercent,
        payoutStyle: _payoutStyle,
        perPointRate: double.tryParse(_rateCtrl.text.trim()) ?? 0.0,
        perPointMode: _perPointMode,
        lossCap: (_payoutStyle == 'per_point' && _capEnabled)
            ? double.tryParse(_capCtrl.text.trim())
            : null,
        entryFee: double.tryParse(_entryCtrl.text.trim()) ?? 0.0,
        payouts: payouts,
        pointsTable: {
          for (final b in _kBuckets) b: int.tryParse(_points[b]!.text.trim()) ?? 0,
        },
        participantPlayerIds: _participantsToSend(),
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
      // Jump straight to scoring, like the per-foursome games (5-3-1, Sixes…),
      // so the flow is consistent — there's no reconfigure step to come back
      // for. Stableford is round-level; a casual round has one foursome.
      final fs = rp.round?.foursomes;
      if (fs != null && fs.isNotEmpty) {
        Navigator.of(context)
            .pushReplacementNamed('/score-entry', arguments: fs.first.id);
      } else {
        Navigator.of(context).pop(true);   // fallback: no foursome loaded
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_editing ? 'Edit Stableford' : 'Stableford Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && !_saving)
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load)
              : Column(children: [
                  Expanded(child: _buildBody()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed:
                              (_saving || !_stakeChosen || !_participantsValid)
                                  ? null : _save,
                          child: _saving
                              ? const SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(
                                  // Hub-configured (round creation / side game)
                                  // saves and returns — never "Start Game".
                                  (_editing || widget.returnToHub)
                                      ? 'Save Configuration'
                                      : 'Start Game',
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

  // Header + bordered-card helpers so every section matches the Skins / Spots
  // / Points 5-3-1 setup screens.
  TextStyle? _cardHeader(ThemeData theme) => theme.textTheme.labelLarge
      ?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary);

  Widget _card(ThemeData theme, {required Widget child}) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: theme.colorScheme.outline),
        ),
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      );

  Widget _buildBody() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Handicap (Net%/Gross — no Strokes-Off). Every side game carries its
        //    OWN handicap now; no inheritance (docs/parallel-games.md). ──
        HandicapModeSelector(
          mode: _mode,
          netPercent: _netPercent,
          allowStrokesOff: false,
          onModeChanged: (m) => setState(() => _mode = m),
          onPercentChanged: (p) => setState(() => _netPercent = p),
        ),
        const SizedBox(height: 16),

        // ── Who's in the bet (subset side game) ──
        _participantCard(theme),

        // ── Points table ──
        _card(theme, child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Points table', style: _cardHeader(theme)),
            const SizedBox(height: 4),
            Text('Points awarded per hole by score vs par. Negatives allowed.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in _kPresets.entries)
                  ActionChip(
                    label: Text(entry.key),
                    onPressed: () => _applyPreset(entry.value),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (final b in _kBuckets)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text(_kBucketLabels[b]!)),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _points[b],
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                          signed: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
                      ],
                      decoration: const InputDecoration(
                          border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                ]),
              ),
          ],
        )),
        const SizedBox(height: 16),

        // ── Payout ──
        // ── How the money settles (mode only — the stake lives below). ──
        _card(theme, child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How the money settles', style: _cardHeader(theme)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'pool', label: Text('Pool')),
                ButtonSegment(value: 'per_point', label: Text('Per point')),
              ],
              selected: {_payoutStyle},
              onSelectionChanged: (s) => setState(() => _payoutStyle = s.first),
            ),
            const SizedBox(height: 8),
            if (_payoutStyle == 'pool')
              Text('Everyone antes the entry fee; the pool is split among the '
                  'paid places.', style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
            else ...[
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'average', label: Text('vs Average')),
                  ButtonSegment(value: 'all',     label: Text('Above you')),
                  ButtonSegment(value: 'first',   label: Text('Just first')),
                ],
                selected: {_perPointMode},
                onSelectionChanged: (s) => setState(() => _perPointMode = s.first),
              ),
              const SizedBox(height: 8),
              Text(
                switch (_perPointMode) {
                  'first' => 'Only the leader collects — everyone else pays the '
                      'leader their points deficit at the value below.',
                  'all' => 'You pay everyone above you (and collect from everyone '
                      'below) at the value below, per point of difference.',
                  _ => 'Standard: settle against the field average. Every point '
                      'above the average wins; every point below owes — at the '
                      'value below.',
                },
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              // Loss cap — tucked under Advanced, consistent with the others.
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: _advancedOpen,
                  onExpansionChanged: (v) => _advancedOpen = v,
                  childrenPadding: EdgeInsets.zero,
                  title: Text('Advanced', style: theme.textTheme.bodyMedium),
                  children: [
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Cap each player's losses"),
                      subtitle: Text(
                        _capEnabled
                            ? 'Nobody loses more than the amount below; winners '
                              'share what’s collected, pro-rata.'
                            : 'Off — per-point losses are uncapped.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                      value: _capEnabled,
                      onChanged: (v) => setState(() => _capEnabled = v),
                    ),
                    if (_capEnabled)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 180,
                          child: TextField(
                            controller: _capCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Max loss', prefixText: '\$ ',
                              border: OutlineInputBorder(), isDense: true),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        )),
        const SizedBox(height: 16),

        // ── Stake (ante for pool / value per point) + play-for-fun, mirroring
        //    the Skins / Spots / Points 5-3-1 stake card. ──
        _card(theme, child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_payoutStyle == 'pool' ? 'Ante per player' : 'Value per point',
                style: _cardHeader(theme)),
            const SizedBox(height: 8),
            if (_payoutStyle == 'pool') ...[
              TextField(
                controller: _entryCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Ante', prefixText: '\$ ',
                  border: OutlineInputBorder(), isDense: true),
              ),
            ] else ...[
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _rateCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Value per point', prefixText: '\$ ',
                    border: OutlineInputBorder(), isDense: true),
                ),
              ),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Play for fun — no stakes'),
              value: _noStakes,
              onChanged: (v) => setState(() {
                _noStakes = v ?? false;
                if (_noStakes) { _entryCtrl.text = '0'; _rateCtrl.text = '0'; }
              }),
            ),
            // Pool: show the pot total and how it splits across the paid places.
            if (_payoutStyle == 'pool') ...[
              const SizedBox(height: 2),
              Text('Pool: \$${_pool.toStringAsFixed(0)}  ($_participantCount players)',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              PayoutConfigField(
                pool: _pool.round(),
                numPayouts: _numPayouts,
                payoutCtrls: _payoutCtrls,
                onNumPayoutsChanged: (n) => setState(() => _numPayouts = n),
                onPayoutChanged: () => setState(() {}),
                onSuggest: _suggest,
              ),
            ],
          ],
        )),
        const SizedBox(height: 24),
      ],
    );
  }
}
