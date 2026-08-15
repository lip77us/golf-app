/// screens/survivor_setup_screen.dart
/// ----------------------------------
/// Setup screen for the Survivor casual game (exactly 3 real players).
///
/// Deliberately thin — the handicap and the stake are the ONLY things to
/// choose.  How many Survivors the round yields, how long each one runs, and
/// where its boundaries fall all come out of the scores, so there is nothing
/// else for the group to configure (see docs/survivor.md).
///
/// Entry is gated to a 3-player foursome (the casual picker enforces it; we
/// re-check here against a direct route push or roster change).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/stake_field.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/max_liability_note.dart';

class SurvivorSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const SurvivorSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<SurvivorSetupScreen> createState() => _SurvivorSetupScreenState();
}

class _SurvivorSetupScreenState extends State<SurvivorSetupScreen> {
  // Strokes-Off is the usual way this is played — the low handicap plays to
  // scratch and everyone else gets the difference.
  String _mode       = 'strokes_off';
  int    _netPercent = 100;

  final TextEditingController _betCtrl = TextEditingController();
  /// True once a stake is entered or "no stakes" is chosen (gates Start).
  bool _stakeOk = false;
  bool _betCtrlInitialized = false;

  bool   _loading  = true;
  bool   _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool   _editing  = false;
  Object? _error;
  SurvivorSummary? _summary;

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
      _summary = await client.getSurvivorSummary(widget.foursomeId);
      if (!mounted) return;

      // A Survivor game already exists → jump to the play screen instead of
      // re-showing setup (re-setup would wipe results).  The empty-default
      // summary (no game) reports 'pending' with no players.
      final configured = _summary!.status == 'in_progress' ||
          _summary!.status == 'complete' ||
          _summary!.players.isNotEmpty;

      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/survivor', arguments: widget.foursomeId);
        return;
      }

      setState(() {
        if (configured) {
          _editing    = true;
          _mode       = _summary!.handicapMode;
          _netPercent = _summary!.netPercent;
        }
        _loading = false;
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

  bool get _rosterValid => _realMembers.length == 3;

  /// The round's hole count (partial rounds < 18).  A Survivor needs two holes
  /// — except one that starts on the LAST hole, which settles there in one —
  /// so n holes yield at most (n + 1) ~/ 2.  Mirrors the engine.
  int get _holeCount {
    final rp = context.read<RoundProvider>();
    final n  = rp.round?.numHoles ?? 18;
    return n > 0 ? n : 18;
  }

  int get _maxSurvivors => (_holeCount + 1) ~/ 2;

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      final parsed = double.tryParse(_betCtrl.text.trim());
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      final summary = await client.postSurvivorSetup(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
      );
      rp.setSurvivorSummary(summary);

      if (widget.returnToHub) {
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
          '/survivor', arguments: widget.foursomeId);
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
      final b = rp.round!.betUnit;
      if (b > 0) {
        _betCtrl.text =
            b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
        _stakeOk = true;
      }
    }

    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Survivor' : 'Survivor Setup'),
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
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed: (_starting || !_rosterValid || !_stakeOk)
                              ? null : _start,
                          child: _starting
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(
                                  _editing ? 'Save Configuration' : 'Start Game',
                                  style: const TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
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
          _RosterBanner(members: _realMembers),
          const SizedBox(height: 16),

          HandicapModeSelector(
            mode:       _mode,
            netPercent: _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),
          const SizedBox(height: 16),

          StakeField(
            controller: _betCtrl,
            label: 'Stake per Survivor',
            onChanged: (v) => setState(() => _stakeOk = v)),
          MaxLiabilityNote(
            bet: double.tryParse(_betCtrl.text.trim()) ?? 0,
            multiple: _maxSurvivors,
            detail: 'up to $_maxSurvivors Survivors — everyone antes the stake '
                    'on each, and the winner takes the pot',
          ),
          const SizedBox(height: 16),

          _Card(
            title: 'How Survivor works',
            child: Text(
              'Everyone plays the first hole. The WORST score is knocked out — '
              'but if the two worst scores tie, nobody goes and the same hole '
              'plays again on the next one.\n\n'
              'The surviving two then play the next hole head-to-head: low '
              'score wins the Survivor. If they tie, they carry on to the '
              'next hole until one of them wins it outright.\n\n'
              'As soon as a Survivor is decided a new one starts on the very '
              'next hole with all three back in — so a full 18 can pay out up '
              'to nine times.\n\n'
              'On the last hole there is no room to eliminate and then decide, '
              'so it settles what is standing: with all three still in, the low '
              'ball takes it and any tie for low is no blood; with two left, a '
              'tie splits the eliminated player’s entry.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}


class _Card extends StatelessWidget {
  final String  title;
  final String? subtitle;
  final Widget  child;
  const _Card({required this.title, this.subtitle, required this.child});

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
          Text(title,
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          child,
        ]),
      ),
    );
  }
}


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
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                ok
                  ? 'Survivor is ready for this 3-player group.'
                  : 'Survivor needs exactly 3 real players.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600, color: color),
              ),
              const SizedBox(height: 4),
              Text(
                'Players: ${members.map((m) => m.player.displayShort).join(' / ')}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
