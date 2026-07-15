/// screens/honors_setup_screen.dart
/// ---------------------------------
/// Setup screen for the Honors side game.
///
/// Honors is a leaderboard-only overlay (always an add-on, never a primary):
/// win a hole outright net and you hold "the honor"; you keep it — and score
/// 1 point — every hole until someone else wins a hole outright.  A tied hole
/// never beats the holder.  Settlement runs through the shared wager engine on
/// the point totals, so the knobs are just the handicap policy, the settlement
/// style (vs the field average / pay everyone above you / pay the leader), and
/// the per-point stake.
///
/// Opened from the round hub's side-game buttons (returnToHub == true), so —
/// like the other side games — it stays on the form when already configured
/// and pops back to the hub on save.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/stake_field.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';

class HonorsSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true (the side-game flow), stay on the form even when the game is
  /// already configured and return to the /round hub on save instead of
  /// jumping to score entry.
  final bool returnToHub;

  const HonorsSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = true,
  });

  @override
  State<HonorsSetupScreen> createState() => _HonorsSetupScreenState();
}

class _HonorsSetupScreenState extends State<HonorsSetupScreen> {
  // Casual default → Strokes-Off Low, matching the other casual-game setup
  // screens (Sixes, Points 5-3-1, Rabbit).
  String _mode         = 'strokes_off';
  int    _netPercent   = 100;
  String _perPointMode = 'average';   // 'average' | 'all' | 'first'
  bool   _advancedOpen = false;

  /// Players IN the game. null = all real players; a set = a chosen subset.
  Set<int>? _participantIds;

  final TextEditingController _betCtrl = TextEditingController();
  bool _stakeOk = false;
  bool _betCtrlInitialized = false;

  // Optional per-player loss cap — off by default (uncapped).
  bool _capEnabled = false;
  final TextEditingController _capCtrl = TextEditingController();

  bool   _loading   = true;
  bool   _starting  = false;
  bool   _editing   = false;
  Object? _error;

  HonorsSummary? _summary;

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
      final client = context.read<AuthProvider>().client;
      _summary = await client.getHonorsSummary(widget.foursomeId);
      if (!mounted) return;

      final configured =
          _summary!.status == 'in_progress' || _summary!.players.isNotEmpty;

      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/score-entry',
          arguments: widget.foursomeId,
        );
        return;
      }

      setState(() {
        if (configured) {
          _editing      = true;
          _mode         = _summary!.handicapMode;
          _netPercent   = _summary!.netPercent;
          _perPointMode = _summary!.perPointMode;
          _capEnabled   = _summary!.lossCap != null;
          if (_summary!.lossCap != null) {
            _capCtrl.text = _summary!.lossCap!
                .toStringAsFixed(_summary!.lossCap! % 1 == 0 ? 0 : 2);
          }
          // Hydrate the participant subset (empty/absent = all players).
          final pids = _summary!.participantPlayerIds;
          _participantIds = pids.isEmpty ? null : pids.toSet();
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

  bool get _rosterValid =>
      _realMembers.length >= 2 && _realMembers.length <= 4;

  /// Number of players actually in the game (subset size, else all).
  int get _participantCount => _participantIds?.length ?? _realMembers.length;

  /// A subset, when chosen, needs at least 2 players.
  bool get _participantsValid =>
      _participantIds == null || _participantIds!.length >= 2;

  /// The list to POST: empty when everyone's in (= all, backward compatible),
  /// else the chosen subset.
  List<int> _participantsToSend() {
    final all = _realMembers.map((m) => m.player.id).toSet();
    final sel = _participantIds;
    if (sel == null || sel.length >= all.length) return const [];
    return sel.toList();
  }

  /// Player-subset picker — only meaningful for 3–4 player groups (with 2,
  /// both are always in).  null = everyone.
  Widget _participantCard(ThemeData theme) {
    final members = _realMembers;
    if (members.length < 3) return const SizedBox.shrink();
    bool isIn(int id) => _participantIds?.contains(id) ?? true;
    return Card(
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
            Text("Who's playing Honors",
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            Text('Everyone by default — or pick a subset for a side bet.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            for (final m in members)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: isIn(m.player.id),
                title: Text(m.player.name),
                onChanged: (v) => setState(() {
                  final set =
                      _participantIds ?? members.map((e) => e.player.id).toSet();
                  if (v == true) {
                    set.add(m.player.id);
                  } else {
                    set.remove(m.player.id);
                  }
                  // Collapse to null (= all) when everyone's in.
                  _participantIds =
                      set.length == members.length ? null : set;
                }),
              ),
            if (!_participantsValid)
              Text('Pick at least 2 players.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
          ],
        ),
      ),
    );
  }

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      final betText = _betCtrl.text.trim();
      final parsed  = double.tryParse(betText);
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      await client.postHonorsSetup(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        payoutStyle:  'per_point',
        perPointMode: _perPointMode,
        lossCap: _capEnabled ? double.tryParse(_capCtrl.text.trim()) : null,
        participantPlayerIds: _participantsToSend(),
      );

      await rp.loadHonors(widget.foursomeId);

      if (widget.returnToHub) {
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
      final b = rp.round!.betUnit;
      if (b > 0) {
        _betCtrl.text =
            b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
        _stakeOk = true;
      }
    }

    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Honors' : 'Honors Setup'),
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
                          onPressed:
                              (_starting || !_rosterValid ||
                                      !_participantsValid || !_stakeOk)
                                  ? null
                                  : _start,
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
          _RosterBanner(members: _realMembers),

          const SizedBox(height: 16),

          HandicapModeSelector(
            mode:       _mode,
            netPercent: _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),

          const SizedBox(height: 16),

          _participantCard(theme),

          // Spacer only when the participant card is shown (3–4 players).
          if (_realMembers.length >= 3) const SizedBox(height: 16),

          _buildPayoutCard(theme),

          const SizedBox(height: 16),

          StakeField(
            controller: _betCtrl,
            label: 'Value per point',
            helpText:
                'Each honor held for a hole is 1 point. You win or lose this '
                'much per point above or below the settlement baseline.',
            onChanged: (v) => setState(() => _stakeOk = v)),

          const SizedBox(height: 16),

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
                  Text('How Honors works',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  Text(
                    'Win a hole outright (lowest ${_modeWord()}) and you take '
                    'the honor. You keep it — and score 1 point — every hole '
                    'until another player wins a hole outright. A tied hole '
                    "doesn't beat you, so the current holder keeps it.",
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'A player\'s points = the number of holes they held the '
                    'honor. The leaderboard shows the honor holder after every '
                    'hole plus the running field average.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 80),
        ],
      ),
    );
  }

  String _modeWord() => switch (_mode) {
        'gross' => 'gross score',
        'strokes_off' => 'strokes-off net',
        _ => 'net score',
      };

  Widget _buildPayoutCard(ThemeData theme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('How the money settles',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 8),
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
                'first' => 'Only the leader collects — everyone else pays the '
                    'leader their point deficit × the stake.',
                'all' => 'Pay everyone above you the point difference × the '
                    'stake (the biggest swings).',
                _ => 'Settle vs the field average — points above the mean win, '
                    'below owe, at the stake.',
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
                    subtitle: Text(
                      _capEnabled
                          ? 'Nobody loses more than the amount below.'
                          : 'Off — losses are uncapped.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    value: _capEnabled,
                    onChanged: (on) => setState(() => _capEnabled = on),
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
        ),
      ),
    );
  }
}

// ===========================================================================
// Roster banner — surfaces the 2–4 player requirement at a glance
// ===========================================================================

class _RosterBanner extends StatelessWidget {
  final List<Membership> members;

  const _RosterBanner({required this.members});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok    = members.length >= 2 && members.length <= 4;
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
                      ? 'Honors is ready for this ${members.length}-player group.'
                      : 'Honors needs 2 to 4 real players.',
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
