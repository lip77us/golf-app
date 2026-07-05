/// screens/skins_setup_screen.dart
/// --------------------------------
/// Setup screen for the Skins casual game.
///
/// Skins is an individual per-hole contest for 2–4 real players.
/// Setup knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + Net % allowance
///   • Carryover toggle — tied hole carries pot to next hole, or dies
///   • Junk skins toggle — allow manual junk-skin entry per player per hole
///   • Bet unit — each player chips in this amount to the pool
///
/// Roster validation: must have 2–4 real (non-phantom) players.
/// The casual-round picker already gates this, but we double-check here
/// in case of a direct route push or mid-round roster change.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../utils/primary_handicap.dart';
import '../widgets/inherited_handicap_note.dart';
import '../widgets/stake_field.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/handicap_mode_selector.dart';

class SkinsSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const SkinsSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<SkinsSetupScreen> createState() => _SkinsSetupScreenState();
}

class _SkinsSetupScreenState extends State<SkinsSetupScreen> {
  // Casual default → Strokes-Off Low.  Existing games overwrite this
  // from their persisted mode in _load().
  String _mode       = 'strokes_off';
  int    _netPercent = 100;
  bool   _carryover  = true;
  bool   _allowJunk  = false;

  // ── Payout mode (progressive disclosure) ────────────────────────────────
  String _payoutStyle  = 'pool';   // 'pool' | 'per_point'
  String _perPointMode = 'first';  // 'average' | 'all' | 'first'
  bool _advancedOpen = false;
  bool _capEnabled   = false;
  final TextEditingController _capCtrl = TextEditingController();

  final TextEditingController _betCtrl = TextEditingController();
  bool _betCtrlInitialized = false;
  /// True once a stake is entered or "no stakes" is chosen (gates Start).
  bool _stakeOk = false;

  /// True when Skins is a SECONDARY side game (some other game owns entry).
  /// Junk is a score-entry modifier, so it's unavailable in that case.
  bool get _isSideGame {
    final rp = context.read<RoundProvider>();
    final games = rp.round?.activeGames ?? const <String>[];
    return games.contains('skins') &&
        resolvePrimary(rp.round?.primaryGame, games) != 'skins';
  }

  bool    _loading  = true;
  bool    _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool    _editing  = false;
  Object? _error;

  SkinsSummary? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      _summary = await client.getSkinsSummary(widget.foursomeId);
      if (!mounted) return;

      // A configured game reports its players even before any hole is scored
      // (the backend sends status 'pending' both when no game exists AND when
      // one exists but is unscored — a non-empty players list is the
      // "already set up" tell).
      final configured =
          _summary!.status == 'in_progress' || _summary!.players.isNotEmpty;

      // Normal flow: an already-set-up game jumps straight to score entry.
      // In edit mode (returnToHub — round creation / "Edit Configuration")
      // stay on the form so the user can change settings.
      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/score-entry',
          arguments: widget.foursomeId,
        );
        return;
      }

      final rp = context.read<RoundProvider>();

      // Side games never carry their own handicap config — the PRIMARY game
      // drives SO/Net/Gross. Inherit it (and force junk off).
      (String, int)? inherited;
      if (_isSideGame && rp.round != null) {
        inherited = await primaryHandicapFor(client, rp.round!, widget.foursomeId);
      }
      if (!mounted) return;

      setState(() {
        // For a brand-new game (no players yet) keep the frontend's casual
        // defaults (Strokes-Off Low, carryover on, no junk).  Once a game
        // exists, adopt its saved settings so editing starts from them.
        if (configured) {
          _editing    = true;
          _mode       = _summary!.handicapMode;
          _netPercent = _summary!.netPercent;
          _carryover  = _summary!.carryover;
          _allowJunk  = _summary!.allowJunk;
          _payoutStyle  = _summary!.payoutStyle;
          _perPointMode = _summary!.perPointMode;
          if (_summary!.lossCap != null) {
            _capEnabled   = true;
            _advancedOpen = true;
            _capCtrl.text = _summary!.lossCap!.toStringAsFixed(0);
          }
          // One value field for both modes: the pool ante (round stake) or the
          // per-skin rate.  Leave it BLANK when 0 so the user types into an
          // empty field (no "0" to erase).
          final preset = _payoutStyle == 'per_point'
              ? _summary!.perPointRate
              : (rp.round?.betUnit ?? 0);
          if (preset > 0) {
            _betCtrl.text = preset % 1 == 0
                ? preset.toStringAsFixed(0)
                : preset.toStringAsFixed(2);
            _stakeOk = true;
          }
        }
        if (inherited != null) {
          _mode       = inherited.$1;
          _netPercent = inherited.$2;
          _allowJunk  = false;
        }
        _loading    = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// Start is gated on a stake decision — a positive value OR "play for fun"
  /// — consistently across pool and per-skin (matches Spots / Points 5-3-1).
  bool get _moneyOk => _stakeOk;

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes.firstWhere(
      (f) => f.id == widget.foursomeId,
      orElse: () => rp.round!.foursomes.first,
    );
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  bool get _rosterValid {
    final n = _realMembers.length;
    return n >= 2 && n <= 4;
  }

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      // The single value field means the pool ante (→ round stake) in pool
      // mode, or the per-skin rate in per-skin mode.  Only pool writes back to
      // the shared round stake; per-skin settles on its own rate and leaves the
      // round stake untouched (it may belong to another game in the round).
      final value = double.tryParse(_betCtrl.text.trim());
      if (_payoutStyle == 'pool' &&
          value != null && rp.round != null && value != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(value);
      }

      await client.postSkinsSetup(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        carryover:    _carryover,
        allowJunk:    _isSideGame ? false : _allowJunk,
        payoutStyle:  _payoutStyle,
        perPointMode: _perPointMode,
        perPointRate: _payoutStyle == 'per_point' ? (value ?? 0.0) : 0.0,
        lossCap: (_payoutStyle == 'per_point' && _capEnabled)
            ? (double.tryParse(_capCtrl.text.trim()) ?? 0.0)
            : null,
      );

      // Pre-load the Skins summary so the score-entry status widget
      // renders immediately on first paint (configured_games on the
      // local foursome is stale right after setup).
      await rp.loadSkins(widget.foursomeId);

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": return to the launch page
        // sitting below us (Enter Scores / Edit Tee Boxes / Edit
        // Configuration).  Reload the round first so the hub reflects the
        // freshly-saved game, then pop — popping (rather than pushing a new
        // /round) keeps a single hub on the stack.
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
          '/score-entry',
          arguments: widget.foursomeId,
        );
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrlInitialized = true;
    }

    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Skins' : 'Skins Setup'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : Column(children: [
                  Expanded(child: _buildBody()),
                  // Persistent Start Game button — inside the body Column so
                  // resizeToAvoidBottomInset keeps it above the soft keyboard
                  // when the bet field's number pad is open (the keyboard
                  // covered Start when this lived in bottomNavigationBar).
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: GolfPrimaryButton(
                        label: _editing ? 'Save Configuration' : 'Start Game',
                        loading: _starting,
                        onPressed: (_rosterValid && _moneyOk) ? _start : null,
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RosterBanner(members: _realMembers),

          const SizedBox(height: 16),

          // Side games inherit the primary game's handicap (no own selector);
          // the primary drives Strokes-Off / Net / Gross for the round.
          if (_isSideGame)
            InheritedHandicapNote(mode: _mode, netPercent: _netPercent)
          else
            HandicapModeSelector(
              mode:             _mode,
              netPercent:       _netPercent,
              onModeChanged:    (m) => setState(() => _mode = m),
              onPercentChanged: (p) => setState(() => _netPercent = p),
            ),

          const SizedBox(height: 16),

          // Carryover + junk toggles
          Card(
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
                  Text('Game options',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Carryover'),
                    subtitle: Text(
                      _carryover
                          ? 'Tied holes carry the pot to the next hole.'
                          : 'Tied holes die — no skin awarded.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    value: _carryover,
                    onChanged: (v) => setState(() => _carryover = v),
                  ),
                  // Junk is only available when Skins is the PRIMARY game —
                  // it's entered hole-by-hole during scoring, which a side
                  // game can't touch.
                  if (!_isSideGame)
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Junk skins'),
                      subtitle: Text(
                        _allowJunk
                            ? 'Entry screen shows a junk counter per player per hole.'
                            : 'Regular skins only — no junk.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                      value: _allowJunk,
                      onChanged: (v) => setState(() => _allowJunk = v),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Payout mode (progressive disclosure) — Pool is the default;
          //    "Per skin" reveals the settlement flavor, with the loss cap
          //    tucked under Advanced.  The stake field below adapts to the
          //    choice (consistent with Spots / Points 5-3-1). ──
          Card(
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
                  Text('How the money settles',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'pool', label: Text('Pool')),
                      ButtonSegment(value: 'per_point', label: Text('Per skin')),
                    ],
                    selected: {_payoutStyle},
                    onSelectionChanged: (s) =>
                        setState(() => _payoutStyle = s.first),
                  ),
                  const SizedBox(height: 8),
                  if (_payoutStyle == 'pool')
                    Text(
                      'Everyone antes the stake; the pot splits by share of '
                      'total skins won.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    )
                  else ...[
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'average', label: Text('vs Average')),
                        ButtonSegment(value: 'all',     label: Text('Above you')),
                        ButtonSegment(value: 'first',   label: Text('Just leader')),
                      ],
                      selected: {_perPointMode},
                      onSelectionChanged: (s) =>
                          setState(() => _perPointMode = s.first),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (_perPointMode) {
                        'first' => 'Only the leader collects — everyone else pays '
                            'the leader their skin deficit at the value below.',
                        'all' => 'You pay everyone with more skins (and collect '
                            'from everyone below) at the value below.',
                        _ => 'Settle vs the field average: every skin above the '
                            'average wins, every skin below owes — at the value below.',
                      },
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
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
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly],
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
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Stake — always shown, adapts to the payout choice, with the shared
          // "play for fun" opt-in (consistent with Spots / Points 5-3-1).
          StakeField(
            controller: _betCtrl,
            label: _payoutStyle == 'pool' ? 'Ante per player' : 'Value per skin',
            onChanged: (v) => setState(() => _stakeOk = v),
          ),

          const SizedBox(height: 16),

          // Rules card
          Card(
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
                  Text('How scoring works',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  Text(
                    'Each player chips in the stake.  On every hole, '
                    'the player with the best score wins a skin outright.  '
                    'A tie ${_carryover ? 'carries the pot to the next hole' : 'kills the skin'}.  '
                    'At the end, the pool is split proportionally among '
                    'players based on how many total skins they won.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (_allowJunk) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Junk skins (birdies, sandies, chip-ins, etc.) are '
                      'entered manually on each hole and count alongside '
                      'regular skins in the pool split.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ===========================================================================
// Roster banner — surfaces 2–4 player requirement at a glance
// ===========================================================================

class _RosterBanner extends StatelessWidget {
  final List<Membership> members;

  const _RosterBanner({required this.members});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n     = members.length;
    final ok    = n >= 2 && n <= 4;
    final color = ok ? theme.colorScheme.primary : theme.colorScheme.error;

    String message;
    if (ok) {
      message = 'Skins is ready for this $n-player group.';
    } else if (n < 2) {
      message = 'Skins needs at least 2 players — add ${2 - n} more.';
    } else {
      message = 'Skins supports at most 4 players — remove ${n - 4}.';
    }

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
            Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
                color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600, color: color)),
                  const SizedBox(height: 4),
                  Text(
                    'Players: ${members.map((m) => m.player.displayShort).join(' / ')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
