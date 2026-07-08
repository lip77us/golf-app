/// screens/wolf_setup_screen.dart
/// ------------------------------
/// Setup screen for the Wolf casual game (3 or 4 real players).
///
/// Knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + net percentage.
///   • The Wolf rotation order — drag the players into the order the Wolf
///     cycles through (player 1 is Wolf on hole 1, player 2 on hole 2, …),
///     mirroring how Pink Ball sets its carrier rotation.
///   • Point values: Lone Wolf, Blind Wolf, and per-winner team points.
///   • Options: Wolf loses ties, non-Wolf clean-win bonus, and (4-player
///     only) the holes-17/18 last-place-is-Wolf catch-up rule.
///   • Bet unit (one point = one stake).
///
/// We only allow entry when the foursome has exactly 3 or 4 real players;
/// the casual-round picker already gates that, but we re-check here as a
/// defense against a direct route push or a mid-round roster change.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/stake_field.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';

class WolfSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const WolfSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<WolfSetupScreen> createState() => _WolfSetupScreenState();
}

class _WolfSetupScreenState extends State<WolfSetupScreen> {
  // Casual default → Strokes-Off Low, matching the other casual games.
  String _mode       = 'strokes_off';
  int    _netPercent = 100;

  int  _lonePoints  = 3;
  int  _blindPoints = 6;
  int  _teamPoints  = 1;
  bool _wolfLosesTies   = false;
  bool _nonWolfBonus    = false;
  bool _lastPlace1718   = true;
  bool _requireLoneOrBlind = false;

  /// Player ids in the Wolf rotation order (drag to reorder).
  List<int> _order = [];

  final TextEditingController _betCtrl = TextEditingController();
  /// True once a stake is entered or "no stakes" is chosen (gates Start).
  bool _stakeOk = false;
  bool _betCtrlInitialized = false;

  // Optional per-player loss cap. Off by default — Wolf's point config is
  // adjustable, so there's no fixed "max loss" to pre-fill.
  bool _capEnabled = false;
  final TextEditingController _capCtrl = TextEditingController();

  bool   _loading  = true;
  bool   _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool   _editing  = false;
  Object? _error;

  WolfSummary? _summary;

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
      _summary = await client.getWolfSummary(widget.foursomeId);
      if (!mounted) return;

      // A Wolf game already exists for this foursome → go straight to the
      // play screen instead of re-showing setup (re-running setup would
      // wipe the rotation and decisions).  The empty-default summary
      // returned when no game exists has an empty wolf_order, so a
      // non-empty order is the reliable "already configured" signal —
      // and it covers the pending state (configured but no hole fully
      // resolved yet), which `status` alone can't distinguish from "no
      // game".
      final configured = _summary!.wolfOrder.isNotEmpty;

      // Normal flow: an already-set-up game jumps straight to the play screen.
      // In edit mode (returnToHub — round creation / "Edit Configuration")
      // stay on the form so the user can change settings.
      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/wolf', arguments: widget.foursomeId);
        return;
      }

      setState(() {
        // Adopt saved settings when the game has been configured (a non-empty
        // wolf order is the tell — covers the pending-with-config edit case);
        // a brand-new game keeps the casual defaults above.
        if (configured || _summary!.status != 'pending') {
          if (configured) _editing = true;
          _mode          = _summary!.handicapMode;
          _netPercent    = _summary!.netPercent;
          _lonePoints    = _summary!.loneWolfPoints;
          _blindPoints   = _summary!.blindWolfPoints;
          _teamPoints    = _summary!.teamWinPoints;
          _wolfLosesTies = _summary!.wolfLosesTies;
          _nonWolfBonus  = _summary!.nonWolfBonus;
          _lastPlace1718 = _summary!.lastPlaceWolf1718;
          _requireLoneOrBlind = _summary!.requireLoneOrBlind;
          _capEnabled    = _summary!.lossCap != null;
          if (_summary!.lossCap != null) {
            _capCtrl.text = _summary!.lossCap!
                .toStringAsFixed(_summary!.lossCap! % 1 == 0 ? 0 : 2);
          }
        }
        _order   = _initialOrder(_summary!);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// Seed the rotation order from the server (if it has one), else from the
  /// current roster order.
  List<int> _initialOrder(WolfSummary summary) {
    final ids = _realMembers.map((m) => m.player.id).toList();
    final fromServer = summary.wolfOrder.where(ids.contains).toList();
    final seen = fromServer.toSet();
    for (final id in ids) {
      if (!seen.contains(id)) fromServer.add(id);
    }
    return fromServer;
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
      _realMembers.length == 3 || _realMembers.length == 4;

  bool get _isFourPlayer => _realMembers.length == 4;

  /// A partial round (< 18 holes) — the 18-hole-specific catch-up rules
  /// (last-place Wolf on 17 & 18, require Lone/Blind by hole 16) are hidden and
  /// forced off, since those hole numbers don't exist on a 9-hole / back-9 round.
  bool get _isPartial =>
      (context.read<RoundProvider>().round?.numHoles ?? 18) < 18;

  Membership? _memberById(int id) {
    for (final m in _realMembers) {
      if (m.player.id == id) return m;
    }
    return null;
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

      final summary = await client.postWolfSetup(
        widget.foursomeId,
        handicapMode:      _mode,
        netPercent:        _netPercent,
        wolfOrder:         _order,
        loneWolfPoints:    _lonePoints,
        blindWolfPoints:   _blindPoints,
        teamWinPoints:     _teamPoints,
        wolfLosesTies:     _wolfLosesTies,
        nonWolfBonus:      _nonWolfBonus,
        // The 18-hole catch-up rules don't apply to a partial round — force off
        // (their toggles are hidden there).
        lastPlaceWolf1718: _isPartial ? false : _lastPlace1718,
        requireLoneOrBlind: _isPartial ? false : _requireLoneOrBlind,
        lossCap: _capEnabled ? double.tryParse(_capCtrl.text.trim()) : null,
      );
      rp.setWolfSummary(summary);

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": reload the round so the hub
        // reflects the freshly-saved game, then pop back to the launch page.
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
          '/wolf', arguments: widget.foursomeId);
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
      // Only prefill a real, previously-set stake — a fresh round
      // (bet 0) starts empty so the user must consciously set a
      // stake or tick "Play for fun" before Start enables.
      if (b > 0) {
        _betCtrl.text =
            b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
        _stakeOk = true;
      }
    }

    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Wolf' : 'Wolf Setup'),
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
                          onPressed: (_starting || !_rosterValid || !_stakeOk) ? null : _start,
                          child: _starting
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(_editing ? 'Save Configuration' : 'Start Game',
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

          // ── Wolf rotation order ──
          _SectionCard(
            title: 'Wolf rotation',
            subtitle: 'Drag to set the order the Wolf rotates through. '
                'Player 1 is the Wolf on hole 1, player 2 on hole 2, and so '
                'on.${_isFourPlayer ? '' : ''}',
            child: _RotationList(
              order:    _order,
              memberOf: _memberById,
              onReorder: (a, b) {
                setState(() {
                  if (b > a) b -= 1;
                  final id = _order.removeAt(a);
                  _order.insert(b, id);
                });
              },
            ),
          ),
          const SizedBox(height: 16),

          HandicapModeSelector(
            mode:       _mode,
            netPercent: _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),
          const SizedBox(height: 16),

          // ── Point values ──
          _SectionCard(
            title: 'Point values',
            subtitle: 'Zero-based scoring — the winning side splits the pot, '
                'the losing side splits its negative, so every hole nets to '
                'zero.',
            child: Column(children: [
              _Stepper(
                label: 'Lone Wolf',
                help:  'Wolf goes alone after the drives',
                value: _lonePoints,
                min: 0, max: 20,
                onChanged: (v) => setState(() => _lonePoints = v),
              ),
              _Stepper(
                label: 'Blind Wolf',
                help:  'Wolf declares alone before any drives',
                value: _blindPoints,
                min: 0, max: 30,
                onChanged: (v) => setState(() => _blindPoints = v),
              ),
              if (_isFourPlayer)
                _Stepper(
                  label: 'Team win',
                  help:  'Points each winner nets on a 2-v-2 partner hole',
                  value: _teamPoints,
                  min: 0, max: 20,
                  onChanged: (v) => setState(() => _teamPoints = v),
                ),
            ]),
          ),
          const SizedBox(height: 16),

          // ── Options ──
          _SectionCard(
            title: 'Options',
            child: Column(children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Wolf loses ties'),
                subtitle: const Text(
                    'A tied hole is awarded to the non-Wolf side instead of '
                    'being a push.'),
                value: _wolfLosesTies,
                onChanged: (v) => setState(() => _wolfLosesTies = v),
              ),
              if (_isFourPlayer)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Non-Wolf clean-win bonus'),
                  subtitle: const Text(
                      'A clean win by the side without the pick advantage '
                      'pays double.'),
                  value: _nonWolfBonus,
                  onChanged: (v) => setState(() => _nonWolfBonus = v),
                ),
              if (_isFourPlayer && !_isPartial)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Last place is Wolf on 17 & 18'),
                  subtitle: const Text(
                      'A catch-up twist: whoever is losing takes the Wolf on '
                      'the last two holes.'),
                  value: _lastPlace1718,
                  onChanged: (v) => setState(() => _lastPlace1718 = v),
                ),
              if (_isFourPlayer && !_isPartial)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Must go Lone/Blind by hole 16'),
                  subtitle: const Text(
                      'Every player has to go solo at least once. After three '
                      'Wolf turns all with a partner, their last turn locks out '
                      'the partner option.'),
                  value: _requireLoneOrBlind,
                  onChanged: (v) => setState(() => _requireLoneOrBlind = v),
                ),
            ]),
          ),
          const SizedBox(height: 16),

          StakeField(
            controller: _betCtrl,
            onChanged: (v) => setState(() => _stakeOk = v)),
          const SizedBox(height: 16),

          // Optional per-player loss cap.
          _SectionCard(
            title: 'Cap losses',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Cap each player’s losses'),
                  subtitle: Text(
                    _capEnabled
                        ? 'Nobody loses more than the amount below; winners '
                          'share what’s collected, pro-rata.'
                        : 'Off — Wolf losses are uncapped.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  value: _capEnabled,
                  onChanged: (v) => setState(() => _capEnabled = v),
                ),
                if (_capEnabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _capCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          prefixText: '\$ ',
                          labelText: 'Max loss per player',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Rules reminder.
          _SectionCard(
            title: 'How Wolf works',
            child: Text(
              _isFourPlayer
                  ? 'Each hole the Wolf tees last, then either takes a partner '
                    '(2-v-2), goes Lone Wolf (1-v-3), or Blind Wolf (declared '
                    'before the drives). Best ball decides the hole.'
                  : 'Each hole the Wolf tees last, then goes Lone Wolf (1-v-2) '
                    'or Blind Wolf (declared before the drives). With three '
                    'players there are no partners.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ===========================================================================
// Rotation list — drag to reorder the Wolf seat order
// ===========================================================================

class _RotationList extends StatelessWidget {
  final List<int>                  order;
  final Membership? Function(int)  memberOf;
  final void Function(int, int)    onReorder;

  const _RotationList({
    required this.order,
    required this.memberOf,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: order.length,
      onReorder: onReorder,
      itemBuilder: (context, i) {
        final m = memberOf(order[i]);
        return Container(
          key: ValueKey(order[i]),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text('${i + 1}',
                  style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(m?.player.name ?? 'Player',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            ReorderableDragStartListener(
              index: i,
              child: Icon(Icons.drag_handle,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
        );
      },
    );
  }
}

// ===========================================================================
// Small shared widgets
// ===========================================================================

class _SectionCard extends StatelessWidget {
  final String  title;
  final String? subtitle;
  final Widget  child;
  const _SectionCard({required this.title, this.subtitle, required this.child});

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
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 10),
          child,
        ]),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final String label;
  final String help;
  final int    value;
  final int    min;
  final int    max;
  final void Function(int) onChanged;

  const _Stepper({
    required this.label,
    required this.help,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text(help,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
          width: 28,
          child: Text('$value',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ]),
    );
  }
}

class _RosterBanner extends StatelessWidget {
  final List<Membership> members;
  const _RosterBanner({required this.members});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok    = members.length == 3 || members.length == 4;
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
                      ? 'Wolf is ready for this ${members.length}-player group.'
                      : 'Wolf needs 3 or 4 real players.',
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
