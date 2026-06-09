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
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/stake_field.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';

class SkinsSetupScreen extends StatefulWidget {
  final int foursomeId;

  const SkinsSetupScreen({super.key, required this.foursomeId});

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

  final TextEditingController _betCtrl = TextEditingController();
  bool _betCtrlInitialized = false;
  /// True once a stake is entered or "no stakes" is chosen (gates Start).
  bool _stakeOk = false;

  bool    _loading  = true;
  bool    _starting = false;
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
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      _summary = await client.getSkinsSummary(widget.foursomeId);
      if (!mounted) return;

      // Game already started — jump straight to score entry.
      if (_summary!.status == 'in_progress') {
        Navigator.of(context).pushReplacementNamed(
          '/score-entry',
          arguments: widget.foursomeId,
        );
        return;
      }

      setState(() {
        // For 'pending' state (no game yet) the backend returns its own
        // empty defaults (mode=net, carryover=true, junk=false).  Keep the
        // frontend's casual defaults (Strokes-Off Low, carryover on, no
        // junk) instead so the user lands on the same starting state as
        // every other casual-game setup screen.  Only adopt the backend
        // values once a game actually exists (status != pending).
        if (_summary!.status != 'pending') {
          _mode       = _summary!.handicapMode;
          _netPercent = _summary!.netPercent;
          _carryover  = _summary!.carryover;
          _allowJunk  = _summary!.allowJunk;
        }
        _loading    = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

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

      // Persist any bet-unit edit to the round first.
      final betText = _betCtrl.text.trim();
      final parsed  = double.tryParse(betText);
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      await client.postSkinsSetup(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        carryover:    _carryover,
        allowJunk:    _allowJunk,
      );

      // Pre-load the Skins summary so the score-entry status widget
      // renders immediately on first paint (configured_games on the
      // local foursome is stale right after setup).
      await rp.loadSkins(widget.foursomeId);

      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        '/score-entry',
        arguments: widget.foursomeId,
      );
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
      appBar: const GolfAppBar(title: 'Skins Setup'),
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
                        label: 'Start Game',
                        loading: _starting,
                        onPressed: (_rosterValid && _stakeOk) ? _start : null,
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

          // ── Stake (kept at the bottom; Start stays disabled until it's set,
          // which guarantees the user scrolls past the carryover/junk options
          // above on the way down) ──
          StakeField(
            controller: _betCtrl,
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
