/// screens/fourball_setup_screen.dart
/// -----------------------------------
/// Setup for the Fourball casual game — a single 18-hole 2v2 best-ball match.
/// Pick the two fixed teams of two, the handicap mode, and the match bet.
/// Exactly four players. If a game is already started, jumps straight to
/// score entry.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/stake_field.dart';
import '../widgets/team_splitter_4.dart';

class FourballSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const FourballSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<FourballSetupScreen> createState() => _FourballSetupScreenState();
}

class _FourballSetupScreenState extends State<FourballSetupScreen> {
  // Casual default → Strokes-Off Low (the most-asked-for course setting); an
  // existing game overwrites this from its persisted mode on load.
  String _mode       = 'strokes_off';
  int    _netPercent = 100;
  final  _betCtrl    = TextEditingController();
  bool   _stakeOk    = false;

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
      final bet = rp.round?.betUnit ?? 1;
      _betCtrl.text = bet.toStringAsFixed(bet % 1 == 0 ? 0 : 2);
      _stakeOk = double.tryParse(_betCtrl.text) != null;

      try {
        final existing = await client.getFourballSummary(widget.foursomeId);
        // A configured game has both teams assigned (isStarted) — even at
        // status 'pending' before any hole is scored.
        final configured = existing.status == 'in_progress' ||
            existing.status == 'complete' ||
            existing.status == 'halved' ||
            existing.isStarted;
        // Normal flow: an already-set-up game jumps straight to score entry.
        // In edit mode (returnToHub) stay on the form so settings can change.
        if ((existing.status == 'in_progress' ||
                existing.status == 'complete' ||
                existing.status == 'halved') &&
            !widget.returnToHub) {
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed(
              '/score-entry', arguments: widget.foursomeId);
          return;
        }
        if (configured) _editing = true;
        _mode       = existing.handicapMode;
        _netPercent = existing.netPercent;
        if (existing.betAmount > 0) {
          _betCtrl.text = existing.betAmount
              .toStringAsFixed(existing.betAmount % 1 == 0 ? 0 : 2);
        }
        // Restore teams if assigned.
        final members = _realMembers;
        final byId = {for (final m in members) m.player.id: m};
        if (existing.team1.playerIds.length == 2 &&
            existing.team2.playerIds.length == 2) {
          _ordered = [
            for (final id in existing.team1.playerIds) byId[id],
            for (final id in existing.team2.playerIds) byId[id],
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

      await client.postFourballSetup(
        widget.foursomeId,
        team1PlayerIds: [_ordered[0].player.id, _ordered[1].player.id],
        team2PlayerIds: [_ordered[2].player.id, _ordered[3].player.id],
        handicapMode: _mode,
        netPercent: _netPercent,
        betAmount: parsed,
      );

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": reload the round so the
        // launch page reflects the freshly-saved game, then pop back to it.
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
          title: Text(_editing ? 'Edit Fourball' : 'Fourball — Setup')),
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
                                  : 'Start Fourball'),
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
          'Fourball needs exactly four players (two teams of two).',
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
            Text('Drag to set the two teams — partners share a color. The '
                'better of each team’s two balls counts on every hole.',
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
          title: 'The Match',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('One 18-hole match decided by holes won, lost, or halved '
                '(up/down, dormie). The winning team collects the stake; a '
                'halved match is a push.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            StakeField(
              controller: _betCtrl,
              onChanged: (ok) => setState(() => _stakeOk = ok),
              label: 'Match stake (\$ per player)',
            ),
          ]),
        ),
      ],
    );
  }
}
