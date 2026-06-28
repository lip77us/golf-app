/// screens/points_531_setup_screen.dart
/// -------------------------------------
/// Lightweight setup screen for the Points 5-3-1 casual game.
///
/// Points 5-3-1 has no teams (it's per-player), so the setup flow is
/// drastically simpler than Sixes: pick a handicap mode (Net / Gross /
/// Strokes-Off-Low), optionally tweak the net percentage, confirm the
/// bet unit, and tap Start.  The round's bet_unit is updated as a side
/// effect so the game-level money math uses the same number as every
/// other game in the round.
///
/// We only allow entry here when the foursome has exactly three real
/// (non-phantom) players.  The casual-round game picker already gates
/// that, but we double-check here as a defense against a direct route
/// push or a mid-round roster change.  A mismatch shows a friendly
/// error instead of silently breaking the 3-way tie-splitting math.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/stake_field.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';

class Points531SetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const Points531SetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<Points531SetupScreen> createState() => _Points531SetupScreenState();
}

class _Points531SetupScreenState extends State<Points531SetupScreen> {
  // Local form state — pre-populated from the current server summary when
  // available so re-entering the screen after a setup doesn't reset
  // everyone's picks.  Casual default → Strokes-Off Low, matching the
  // other casual-game setup screens (Sixes, Nassau, Skins).
  String _mode       = 'strokes_off';
  int    _netPercent = 100;

  final TextEditingController _betCtrl = TextEditingController();
  /// True once a stake is entered or "no stakes" is chosen (gates Start).
  bool _stakeOk = false;
  bool _betCtrlInitialized = false;

  /// Optional per-player loss cap.  **Off by default** — uncapped, where the
  /// worst case is 36 × the stake (surfaced in the card so the player can
  /// decide whether to cap below it).  Turning it on pre-fills that 36 × stake
  /// max, which the player can then lower.  Entering a stake never enables it.
  bool _capEnabled = false;
  /// True once the player types their own cap, so auto-sync stops
  /// overwriting it when the stake changes.
  bool _capEdited = false;
  final TextEditingController _capCtrl = TextEditingController();

  /// You can fall at most 2 points/hole below the 3-pt mean × 18 holes,
  /// so the worst-case loss is 36 × the stake.
  static const int _maxLossMultiple = 36;

  bool   _loading   = true;
  bool   _starting  = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool   _editing   = false;
  Object? _error;

  Points531Summary? _summary;

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

  /// The stake currently in play: the edited bet field if valid, else the
  /// round's existing bet unit.  Drives the suggested 36× loss cap.
  double get _currentBet {
    final parsed = double.tryParse(_betCtrl.text.trim());
    if (parsed != null) return parsed;
    return context.read<RoundProvider>().round?.betUnit ?? 0;
  }

  /// Keep the cap pre-filled at 36 × stake as the stake is typed, until
  /// the player overrides it themselves.
  void _syncCapToStake() {
    if (_capEnabled && !_capEdited) {
      final sugg = _currentBet * _maxLossMultiple;
      _capCtrl.text = sugg > 0 ? sugg.toStringAsFixed(0) : '';
    }
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      _summary = await client.getPoints531Summary(widget.foursomeId);
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

      setState(() {
        // For a brand-new game (no players yet) keep the frontend's casual
        // default (Strokes-Off Low) so the user lands on the same starting
        // state as every other casual-game setup screen.  Once a game
        // exists, adopt its saved settings so editing starts from them.
        if (configured) {
          _editing    = true;
          _mode       = _summary!.handicapMode;
          _netPercent = _summary!.netPercent;
          // Adopt the saved cap state (null = the user chose uncapped).
          _capEnabled = _summary!.lossCap != null;
          if (_summary!.lossCap != null) {
            _capEdited    = true;   // don't auto-resync over a saved value
            _capCtrl.text = _summary!.lossCap!
                .toStringAsFixed(_summary!.lossCap! % 1 == 0 ? 0 : 2);
          }
        }
        _loading    = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// Real members (phantoms excluded) for the foursome this screen is
  /// scoped to.  Sourced from the shared RoundProvider, which already
  /// has the full round loaded by the time we're navigated here.
  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes.firstWhere(
      (f) => f.id == widget.foursomeId,
      orElse: () => rp.round!.foursomes.first,
    );
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  bool get _rosterValid => _realMembers.length == 3;

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      // Persist any bet-unit edit to the round first so every other
      // active game in this round sees the new value on its next calc.
      final betText = _betCtrl.text.trim();
      final parsed  = double.tryParse(betText);
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      await client.postPoints531Setup(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        // null = uncapped. An enabled-but-unparseable field also falls
        // back to uncapped rather than blocking Start.
        lossCap: _capEnabled ? double.tryParse(_capCtrl.text.trim()) : null,
      );

      // Pre-load the Points 5-3-1 summary so the score-entry status
      // widget renders immediately on first paint (configured_games on
      // the local foursome is stale right after setup).
      await rp.loadPoints531(widget.foursomeId);

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": reload the round so the
        // launch page reflects the freshly-saved game, then pop back to it
        // (rather than pushing a new /round) so a single hub stays on stack.
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
    // One-time seed of the bet controller once the round is available.
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrlInitialized = true;
      final b = rp.round!.betUnit;
      _betCtrl.text = b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
      _stakeOk = double.tryParse(_betCtrl.text) != null;
    }

    return Scaffold(
      appBar: GolfAppBar(
          title: _editing ? 'Edit Points 5-3-1' : 'Points 5-3-1 Setup'),
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
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed: (_starting || !_rosterValid || !_stakeOk) ? null : _start,
                          child: _starting
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(
                                  _editing ? 'Save Configuration' : 'Start Game',
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

  Widget _buildBody() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Roster validation banner — always visible so the state of
          // the foursome is unambiguous.
          _RosterBanner(members: _realMembers),

          const SizedBox(height: 16),

          // Handicap mode picker (same three choices the backend supports)
          HandicapModeSelector(
            mode:       _mode,
            netPercent: _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),

          const SizedBox(height: 16),

          StakeField(
            controller: _betCtrl,
            label: 'Per-point stake',
            helpText:
                'Points 5-3-1 pays per point: you win or lose this much for '
                'every point you finish above or below the 54-point average.',
            onChanged: (v) => setState(() {
              _stakeOk = v;
              _syncCapToStake();
            })),

          const SizedBox(height: 16),

          _LossCapCard(
            enabled:    _capEnabled,
            controller: _capCtrl,
            suggested:  _currentBet * _maxLossMultiple,
            onToggle: (on) => setState(() {
              _capEnabled = on;
              if (on) _syncCapToStake();
            }),
            onEdited: () => _capEdited = true,
          ),

          const SizedBox(height: 16),

          // Brief rules reminder so players know what they're signing up for.
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
                    'Each hole: 5 points for the best net score, 3 for 2nd, '
                    '1 for 3rd.  Ties split evenly — a 2-way tie at the top '
                    'is 4 / 4 / 1, a 3-way tie is 3 / 3 / 3.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Settlement: a player who finishes 18 holes with 54 '
                    'points breaks even.  Every point above 54 wins one '
                    'per-point stake; every point below 54 owes one.  Because '
                    'each hole pays exactly 9 points total, the three players '
                    'net to zero at the end.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Capping losses: with a cap on, no one loses more than the '
                    'cap. A player who would owe more stops there, and the '
                    'winners share what was actually collected in proportion '
                    'to what they were owed — so the table still nets to zero.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 80), // leave room for the bottom button
        ],
      ),
    );
  }
}

// ===========================================================================
// Roster banner — surfaces 3-player requirement status at a glance
// ===========================================================================

class _RosterBanner extends StatelessWidget {
  final List<Membership> members;

  const _RosterBanner({required this.members});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok    = members.length == 3;
    final color = ok ? theme.colorScheme.primary : theme.colorScheme.error;

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
                  Text(
                    ok
                      ? 'Points 5-3-1 is ready for this 3-player group.'
                      : 'Points 5-3-1 needs exactly 3 real players.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600, color: color),
                  ),
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

// ===========================================================================
// Loss-cap card — optional table-wide per-player loss ceiling
// ===========================================================================

class _LossCapCard extends StatelessWidget {
  final bool enabled;
  final TextEditingController controller;
  final double suggested;            // 36 × current stake
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdited;       // fired when the player types a cap

  const _LossCapCard({
    required this.enabled,
    required this.controller,
    required this.suggested,
    required this.onToggle,
    required this.onEdited,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.fromLTRB(14, 4, 8, 0),
            title: const Text('Cap losses',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              enabled
                  ? 'Nobody loses more than the amount below.'
                  : (suggested > 0
                      ? 'Off — worst case at this stake is '
                        '\$${suggested.toStringAsFixed(0)} (36 × stake). '
                        'Turn on to cap below that.'
                      : 'Off — the most you can lose is 36 × the stake.'),
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            value: enabled,
            onChanged: onToggle,
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    onChanged: (_) => onEdited(),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      prefixText: '\$',
                      labelText: 'Max loss per player',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    suggested > 0
                        ? 'Worst case at this stake is \$${suggested.toStringAsFixed(0)} '
                          '(36 × stake). Losers stop at the cap; winners share '
                          'what’s collected, pro-rata.'
                        : 'Enter a stake above to see the suggested maximum.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
