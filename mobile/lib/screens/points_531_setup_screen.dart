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
import '../widgets/error_view.dart';

class Points531SetupScreen extends StatefulWidget {
  final int foursomeId;

  const Points531SetupScreen({super.key, required this.foursomeId});

  @override
  State<Points531SetupScreen> createState() => _Points531SetupScreenState();
}

class _Points531SetupScreenState extends State<Points531SetupScreen> {
  // Local form state — pre-populated from the current server summary when
  // available so re-entering the screen after a setup doesn't reset
  // everyone's picks.
  String _mode       = 'net';
  int    _netPercent = 100;

  final TextEditingController _betCtrl = TextEditingController();
  bool _betCtrlInitialized = false;

  bool   _loading   = true;
  bool   _starting  = false;
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
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      _summary = await client.getPoints531Summary(widget.foursomeId);
      if (!mounted) return;

      // Game already started — jump straight to the entry screen.
      if (_summary!.status == 'in_progress') {
        Navigator.of(context).pushReplacementNamed(
          '/score-entry',
          arguments: widget.foursomeId,
        );
        return;
      }

      setState(() {
        _mode       = _summary!.handicapMode;
        _netPercent = _summary!.netPercent;
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
      );

      if (!mounted) return;
      // Hand off to the dedicated Points 5-3-1 entry screen — one hole
      // at a time, gaming points inline, shortcuts to the full scorecard
      // and the leaderboard in the app bar.  Score entry there drives
      // recalculation of Points 5-3-1 automatically via
      // _run_active_game_calculators on the server.
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
    // One-time seed of the bet controller once the round is available.
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrl.text = rp.round!.betUnit.formatBet();
      _betCtrlInitialized = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Points 5-3-1 — Setup')),
      body: _buildBody(),
      bottomNavigationBar: _loading ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: (_starting || !_rosterValid) ? null : _start,
              child: _starting
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Start Game',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(
        message: friendlyError(_error!),
        isNetwork: isNetworkError(_error!),
        onRetry: _load,
      );
    }

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
          _HandicapModeCard(
            mode:       _mode,
            netPercent: _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),

          const SizedBox(height: 16),

          _BetUnitCard(controller: _betCtrl),

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
                    'points breaks even.  Every point above 54 is worth one '
                    'bet unit; every point below 54 is owed.  Because each '
                    'hole pays exactly 9 points total, the three players '
                    'net to zero at the end.',
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
// _HandicapModeCard — reused shape from sixes_setup, pared down
// ===========================================================================
//
// This is a self-contained copy rather than a sibling import because
// the Sixes version lives in a private class inside sixes_setup_screen
// (underscore prefix).  Keeping a local twin keeps both screens
// independently evolvable — Sixes needs the 4th "SO/segment" footnote,
// Points 5-3-1 uses a simpler course-wide SI threshold.

class _HandicapModeCard extends StatelessWidget {
  final String mode;
  final int    netPercent;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<int>    onPercentChanged;

  const _HandicapModeCard({
    required this.mode,
    required this.netPercent,
    required this.onModeChanged,
    required this.onPercentChanged,
  });

  static const _presets = <int>[100, 90, 80, 75];

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
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'net',         label: Text('Net')),
              ButtonSegment(value: 'gross',       label: Text('Gross')),
              ButtonSegment(value: 'strokes_off', label: Text('SO')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onModeChanged(s.first),
          ),
          if (mode != 'gross') ...[
            const SizedBox(height: 12),
            Text('Handicap allowance',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8, runSpacing: 4,
              children: _presets.map((p) {
                final selected = p == netPercent;
                return ChoiceChip(
                  label: Text('$p%'),
                  selected: selected,
                  onSelected: (_) => onPercentChanged(p),
                );
              }).toList(),
            ),
          ] else if (mode == 'gross') ...[
            const SizedBox(height: 8),
            Text('No strokes given — raw scores used.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              'The lowest-handicap player plays to 0.  Every other player '
              'gets one stroke on each hole whose stroke index is ≤ their '
              '(own HCP − low HCP).  Same rule on every hole — no segments.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}

// ===========================================================================
// _BetUnitCard — same shape as in sixes_setup_screen, duplicated for
// the same reason the handicap card is (private to that file).
// ===========================================================================

class _BetUnitCard extends StatelessWidget {
  final TextEditingController controller;
  const _BetUnitCard({required this.controller});

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
          Text('Bet Unit',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Bet unit (\$)',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.attach_money),
              isDense: true,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 6),
          Text(
            'One point = one bet unit of money.  Par is 3 points / hole, '
            'so a 55-point finish (over 18 holes) wins 1 bet unit.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}
