/// screens/vegas_setup_screen.dart
/// --------------------------------
/// Setup for the Las Vegas casual game — fixed 2v2 teams, then the scoring
/// options. Exactly four players. If a game is already started, jumps straight
/// to score entry.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/stake_field.dart';
import '../widgets/team_splitter_4.dart';

class VegasSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const VegasSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<VegasSetupScreen> createState() => _VegasSetupScreenState();
}

class _VegasSetupScreenState extends State<VegasSetupScreen> {
  // Casual default → Strokes-Off Low (the most-asked-for course setting); an
  // existing game overwrites this from its persisted mode on load.
  String _mode        = 'strokes_off';
  int    _netPercent  = 100;
  bool   _netMaxDbl   = true;
  String _birdieMode  = 'flip';
  bool   _carryover   = false;
  bool   _capEnabled  = false;
  final  _capCtrl     = TextEditingController();
  final  _betCtrl     = TextEditingController();
  bool   _stakeOk     = false;

  List<Membership> _ordered = const [];   // [0,1] = team 1, [2,3] = team 2
  bool    _loading  = true;
  bool    _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool    _editing  = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _capCtrl.dispose();
    _betCtrl.dispose();
    super.dispose();
  }

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId).firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final rp = context.read<RoundProvider>();
      _betCtrl.text = (rp.round?.betUnit ?? 1).toStringAsFixed(
          (rp.round?.betUnit ?? 1) % 1 == 0 ? 0 : 2);
      _stakeOk = double.tryParse(_betCtrl.text) != null;

      try {
        final existing = await client.getVegasSummary(widget.foursomeId);
        // A configured game has its two teams assigned (isStarted) — even at
        // status 'pending' before any hole is scored.
        final configured = existing.status == 'in_progress' ||
            existing.status == 'complete' ||
            existing.isStarted;
        // Normal flow: an already-set-up game jumps straight to score entry.
        // In edit mode (returnToHub) stay on the form so settings can change.
        if ((existing.status == 'in_progress' ||
                existing.status == 'complete') &&
            !widget.returnToHub) {
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed(
              '/score-entry', arguments: widget.foursomeId);
          return;
        }
        if (configured) _editing = true;
        _mode       = existing.handicapMode;
        _netPercent = existing.netPercent;
        _netMaxDbl  = existing.netMaxDoubleBogey;
        _birdieMode = existing.birdieMode;
        _carryover  = existing.carryover;
        // Restore teams if assigned.
        final members = _realMembers;
        final byId = {for (final m in members) m.player.id: m};
        final t1 = existing.teams.where((t) => t.teamNumber == 1).firstOrNull;
        final t2 = existing.teams.where((t) => t.teamNumber == 2).firstOrNull;
        if (t1 != null && t2 != null &&
            t1.players.length == 2 && t2.players.length == 2) {
          _ordered = [
            for (final p in t1.players) byId[p.id],
            for (final p in t2.players) byId[p.id],
          ].whereType<Membership>().toList();
        }
      } catch (_) {/* no existing game — default split below */}

      if (_ordered.length != 4) _ordered = List.of(_realMembers);
      setState(() { _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  bool get _rosterValid => _realMembers.length == 4 && _ordered.length == 4;

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      final parsed = double.tryParse(_betCtrl.text.trim());
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      await client.postVegasSetup(
        widget.foursomeId,
        team1PlayerIds: [_ordered[0].player.id, _ordered[1].player.id],
        team2PlayerIds: [_ordered[2].player.id, _ordered[3].player.id],
        handicapMode: _mode,
        netPercent: _netPercent,
        netMaxDoubleBogey: _netMaxDbl,
        birdieMode: _birdieMode,
        carryover: _carryover,
        lossCap: _capEnabled ? double.tryParse(_capCtrl.text.trim()) : null,
      );

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
            '/score-entry', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_editing ? 'Edit Vegas' : 'Las Vegas — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load)
              : Column(children: [
                  Expanded(child: _buildBody()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: (_rosterValid && _stakeOk && !_starting)
                              ? _start : null,
                          child: _starting
                              ? const SizedBox(
                                  height: 20, width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(_editing
                                  ? 'Save Configuration'
                                  : 'Start Las Vegas'),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _buildBody() {
    if (_realMembers.length != 4) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text(
          'Las Vegas needs exactly four players (two teams of two).',
          textAlign: TextAlign.center)),
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Teams',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Drag to set the two teams — partners share a color.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TeamSplitter4(
              players: _ordered,
              onChanged: (o) => setState(() => _ordered = o),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        HandicapModeSelector(
          mode: _mode,
          netPercent: _netPercent,
          onModeChanged: (m) => setState(() => _mode = m),
          onPercentChanged: (p) => setState(() => _netPercent = p),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Birdies',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'flip', label: Text('Flip')),
                ButtonSegment(value: 'multiplier', label: Text('Multiply')),
              ],
              selected: {_birdieMode},
              onSelectionChanged: (s) => setState(() => _birdieMode = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _birdieMode == 'flip'
                  ? 'A gross birdie reverses the opponents’ number (e.g. '
                    '46 → 64) before the hole is decided — it can swing it.'
                  : 'The winning team’s best ball multiplies the points: '
                    'birdie ×2, eagle ×3 (no stacking).',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Carryover'),
          subtitle: const Text('Tied holes carry; the next win is multiplied.'),
          value: _carryover,
          onChanged: (v) => setState(() => _carryover = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Net double-bogey max'),
          subtitle: const Text('Cap each net hole score at par + 2.'),
          value: _netMaxDbl,
          onChanged: (v) => setState(() => _netMaxDbl = v),
        ),
        const SizedBox(height: 4),
        StakeField(
          controller: _betCtrl,
          onChanged: (ok) => setState(() => _stakeOk = ok),
          label: 'Stake (\$ per point, per player)',
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Cap each player’s loss'),
          value: _capEnabled,
          onChanged: (v) => setState(() => _capEnabled = v),
        ),
        if (_capEnabled)
          GolfTextField(
            controller: _capCtrl,
            label: 'Max loss per player (\$)',
            keyboardType: TextInputType.number,
          ),
      ],
    );
  }
}
