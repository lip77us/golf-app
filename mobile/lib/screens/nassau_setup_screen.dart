/// screens/nassau_setup_screen.dart
/// ---------------------------------
/// Setup screen for the Nassau casual game.
///
/// Nassau is a fixed-team 9-9-18 best-ball match for 1v1 or 2v2.
/// Setup knobs:
///   • Team assignment — tap each player to move between Team 1 / Team 2
///   • Handicap mode  (Net / Gross / Strokes-Off-Low) + Net % allowance
///   • Press mode     (None / Manual / Auto / Both)
///   • Press unit     — explicit dollar amount per press bet
///   • Bet unit       — round-level unit for the three standard bets
///
/// Roster validation: 2–4 real players, at least 1 per team.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';

class NassauSetupScreen extends StatefulWidget {
  final int foursomeId;
  const NassauSetupScreen({super.key, required this.foursomeId});

  @override
  State<NassauSetupScreen> createState() => _NassauSetupScreenState();
}

class _NassauSetupScreenState extends State<NassauSetupScreen> {
  // ── UI state ────────────────────────────────────────────────────────────────
  String _mode       = 'net';
  int    _netPercent = 100;
  String _pressMode  = 'none';

  final _pressUnitCtrl = TextEditingController(text: '5.00');
  final _betCtrl       = TextEditingController();
  bool  _betCtrlInitialized = false;

  /// playerId → team number (1 or 2)
  final Map<int, int> _teamMap = {};

  bool    _loading  = true;
  bool    _starting = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pressUnitCtrl.dispose();
    _betCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

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
    final members = _realMembers;
    final n = members.length;
    if (n < 2 || n > 4) return false;
    final t1 = _teamMap.values.where((v) => v == 1).length;
    final t2 = _teamMap.values.where((v) => v == 2).length;
    return t1 >= 1 && t2 >= 1;
  }

  List<int> get _team1Ids =>
      _teamMap.entries.where((e) => e.value == 1).map((e) => e.key).toList();
  List<int> get _team2Ids =>
      _teamMap.entries.where((e) => e.value == 2).map((e) => e.key).toList();

  // ── Load ────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rp = context.read<RoundProvider>();

      // Try to fetch an existing Nassau summary to pre-populate the form.
      final client = context.read<AuthProvider>().client;
      try {
        final existing = await client.getNassauSummary(widget.foursomeId);

        // If a game is already in progress jump straight to score entry.
        if (existing.status == 'in_progress' || existing.status == 'complete') {
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed(
            '/score-entry',
            arguments: widget.foursomeId,
          );
          return;
        }

        // Pre-populate from the existing (pending) game.
        setState(() {
          _mode       = existing.handicapMode;
          _netPercent = existing.netPercent;
          _pressMode  = existing.pressMode;
          _pressUnitCtrl.text = existing.pressUnit.toStringAsFixed(2);
        });

        // Restore team assignments if teams exist.
        for (final p in existing.team1) {
          _teamMap[p.playerId] = 1;
        }
        for (final p in existing.team2) {
          _teamMap[p.playerId] = 2;
        }
      } catch (_) {
        // No existing game — default team split: first half T1, rest T2.
        _defaultSplit(rp);
      }

      setState(() { _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  void _defaultSplit(RoundProvider rp) {
    final members = _realMembers;
    for (var i = 0; i < members.length; i++) {
      _teamMap[members[i].player.id] = i < (members.length / 2).ceil() ? 1 : 2;
    }
  }

  // ── Start ────────────────────────────────────────────────────────────────────

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp = context.read<RoundProvider>();

      // Update round-level bet unit if changed.
      final betText = _betCtrl.text.trim();
      final parsed  = double.tryParse(betText);
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      final pressUnit = double.tryParse(_pressUnitCtrl.text.trim()) ?? 0.0;

      final ok = await rp.setupNassau(
        widget.foursomeId,
        team1Ids:     _team1Ids,
        team2Ids:     _team2Ids,
        handicapMode: _mode,
        netPercent:   _netPercent,
        pressMode:    _pressMode,
        pressUnit:    pressUnit,
      );

      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pushReplacementNamed(
          '/score-entry',
          arguments: widget.foursomeId,
        );
      } else {
        setState(() { _starting = false; _error = rp.error; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrl.text = rp.round!.betUnit.formatBet();
      _betCtrlInitialized = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Nassau — Setup')),
      body: _buildBody(rp),
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
                  : const Text('Start Match',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(RoundProvider rp) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorView(
        message: friendlyError(_error!),
        isNetwork: isNetworkError(_error!),
        onRetry: _load,
      );
    }

    final theme   = Theme.of(context);
    final members = _realMembers;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

          // ── Team assignment card ──────────────────────────────────────────
          _sectionCard(
            theme: theme,
            title: 'Teams',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tap a player to toggle which team they play on.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                ...members.map((m) {
                  final pid  = m.player.id;
                  final team = _teamMap[pid] ?? 1;
                  final isT1 = team == 1;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.player.name,
                                style: const TextStyle(fontWeight: FontWeight.w500)),
                            Text('Hcp ${m.playingHandicap}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 1, label: Text('T1')),
                          ButtonSegment(value: 2, label: Text('T2')),
                        ],
                        selected: {team},
                        onSelectionChanged: (s) =>
                            setState(() => _teamMap[pid] = s.first),
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ]),
                  );
                }),

                const SizedBox(height: 8),

                // Team summary chips
                Row(children: [
                  const Text('T1: ', style: TextStyle(fontWeight: FontWeight.w600)),
                  Expanded(child: Text(_teamLabel(members, 1))),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  const Text('T2: ', style: TextStyle(fontWeight: FontWeight.w600)),
                  Expanded(child: Text(_teamLabel(members, 2))),
                ]),

                if (!_rosterValid) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Each team must have at least 1 player.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Handicap mode ─────────────────────────────────────────────────
          _HandicapModeCard(
            mode:             _mode,
            netPercent:       _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),

          const SizedBox(height: 16),

          // ── Press configuration ───────────────────────────────────────────
          _sectionCard(
            theme: theme,
            title: 'Press bets',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Press mode',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6, runSpacing: 4,
                  children: [
                    _pressChip('none',   'None'),
                    _pressChip('manual', 'Manual'),
                    _pressChip('auto',   'Auto at 2-down'),
                    _pressChip('both',   'Manual + Auto'),
                  ],
                ),
                const SizedBox(height: 8),
                _pressDescription(theme),
                if (_pressMode != 'none') ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _pressUnitCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Press unit (\$)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.attach_money),
                      isDense: true,
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Dollar amount per press bet (separate from the main bet).',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Bet unit ──────────────────────────────────────────────────────
          _sectionCard(
            theme: theme,
            title: 'Bet unit (main bets)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _betCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Bet unit (\$)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                    isDense: true,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
                ),
                const SizedBox(height: 6),
                Text(
                  'Each of the three standard Nassau bets '
                  '(Front 9, Back 9, Overall) is worth this amount.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Rules reminder ────────────────────────────────────────────────
          _sectionCard(
            theme: theme,
            title: 'How Nassau works',
            child: Text(
              'Three simultaneous bets — Front 9, Back 9, and Overall. '
              'Each hole is won by the team with the lower best-ball score. '
              'Tied holes are halved (no point changes). '
              'A tied nine is a push (no money changes hands). '
              'Lower score wins the hole; equal scores are halved.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),

          const SizedBox(height: 80),
        ],
      ),
    ));
  }

  // ── Small helpers ────────────────────────────────────────────────────────────

  String _teamLabel(List<Membership> members, int team) {
    final names = members
        .where((m) => (_teamMap[m.player.id] ?? 1) == team)
        .map((m) => m.player.displayShort)
        .toList();
    return names.isEmpty ? '—' : names.join(' & ');
  }

  Widget _pressChip(String value, String label) {
    final selected = _pressMode == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _pressMode = value),
    );
  }

  Widget _pressDescription(ThemeData theme) {
    final text = switch (_pressMode) {
      'none'   => 'No press bets.',
      'manual' => 'The losing team may call a press at any time. '
                  'The winning team always accepts.',
      'auto'   => 'An automatic press fires whenever a team goes 2-down '
                  'in a nine.  The press covers the remaining holes of that nine.',
      'both'   => 'Both manual presses (losing team calls, winning team must accept) '
                  'and automatic 2-down presses are active.',
      _        => '',
    };
    return Text(text,
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant));
  }

  Widget _sectionCard({
    required ThemeData theme,
    required String    title,
    required Widget    child,
  }) {
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
            Text(title,
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// _HandicapModeCard — identical to the one in skins_setup_screen.dart
// ===========================================================================

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
              '(own HCP − low HCP).',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}
