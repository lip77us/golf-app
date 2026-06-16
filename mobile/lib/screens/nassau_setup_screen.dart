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
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/max_liability_note.dart';
import '../widgets/stake_field.dart';
import '../widgets/team_splitter_4.dart';

class NassauSetupScreen extends StatefulWidget {
  final int foursomeId;
  /// When true, default to an Overall-only game (a straight 18-hole match) —
  /// used by the "18-Hole Match" casual game shortcut.
  final bool overallOnly;
  const NassauSetupScreen({
    super.key, required this.foursomeId, this.overallOnly = false,
  });

  @override
  State<NassauSetupScreen> createState() => _NassauSetupScreenState();
}

class _NassauSetupScreenState extends State<NassauSetupScreen> {
  // ── UI state ────────────────────────────────────────────────────────────────
  // Casual default → Strokes-Off Low (most-asked-for setting at the
  // course).  Existing games overwrite this from their persisted mode.
  String _mode       = 'strokes_off';
  int    _netPercent = 100;
  String _pressMode  = 'none';
  /// 'none' | 'tiebreak_2nd' | 'claremont'
  String _variant    = 'none';

  /// Which of the three bets are live (Front+Back off = an 18-hole match).
  late bool _playFront   = !widget.overallOnly;
  late bool _playBack    = !widget.overallOnly;
  bool      _playOverall = true;

  final _pressUnitCtrl = TextEditingController(text: '0');
  final _betCtrl       = TextEditingController();
  bool  _stakeOk = false;
  bool  _betCtrlInitialized = false;

  // Optional per-side loss cap. Only relevant once the match can escalate
  // (presses or Claremont); otherwise max loss is a fixed bet × 3 (or × 1 for
  // an overall-only match) and we show that read-only instead.
  bool _capEnabled = false;
  final _capCtrl = TextEditingController();

  /// True when presses or Claremont are on — the only way the match can run
  /// past the fixed base bets, so the only case a cap is offered.
  bool get _canEscalate => _pressMode != 'none' || _variant == 'claremont';

  /// Independent base bets a side can lose with no escalation.
  int get _baseMultiple => widget.overallOnly ? 1 : 3;

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
    _capCtrl.dispose();
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
          _variant    = existing.variant;
          _playFront   = existing.playFront;
          _playBack    = existing.playBack;
          _playOverall = existing.playOverall;
          _pressUnitCtrl.text = existing.pressUnit.truncate().toString();
          _capEnabled = existing.lossCap != null;
          if (existing.lossCap != null) {
            _capCtrl.text = existing.lossCap! % 1 == 0
                ? existing.lossCap!.toStringAsFixed(0)
                : existing.lossCap!.toStringAsFixed(2);
          }
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
        variant:      _variant,
        playFront:    _playFront,
        playBack:     _playBack,
        playOverall:  _playOverall,
        lossCap: (_canEscalate && _capEnabled)
            ? double.tryParse(_capCtrl.text.trim())
            : null,
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
      _betCtrlInitialized = true;
    }

    return Scaffold(
      appBar: AppBar(
          title: Text(
              widget.overallOnly ? '18-Hole Match — Setup' : 'Nassau — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : Column(children: [
                  Expanded(child: _buildBody(rp)),
                  // Persistent Start Match button — in-body so it stays
                  // above the soft keyboard when the bet field is open.
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
                              : const Text('Start Match',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _buildBody(RoundProvider rp) {

    final theme   = Theme.of(context);
    final members = _realMembers;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

          // ── Team assignment card (hidden for a 1-v-1 18-hole match — the
          //     two players are simply the two sides) ──
          if (!widget.overallOnly) ...[
          SectionCard(
            title: 'Teams',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 4-player foursomes use the shared TeamSplitter4 widget so
                // the team-picking gesture matches Sixes and Sixes-extras.
                // Smaller foursomes (1v1, 1v2, 2v1) keep the simple toggle
                // since drag-and-drop is overkill for ≤3 players.
                if (members.length == 4)
                  TeamSplitter4(
                    players: _splitterOrder(members),
                    onChanged: (ordered) {
                      setState(() {
                        for (var i = 0; i < ordered.length; i++) {
                          _teamMap[ordered[i].player.id] = i < 2 ? 1 : 2;
                        }
                      });
                    },
                  )
                else ...[
                  Text(
                    'Tap a player to toggle which team they play on.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  ...members.map((m) {
                    final pid  = m.player.id;
                    final team = _teamMap[pid] ?? 1;
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
                ],

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
          ],

          // ── Handicap mode ─────────────────────────────────────────────────
          HandicapModeSelector(
            mode:             _mode,
            netPercent:       _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),

          const SizedBox(height: 16),

          // ── Press (Nassau only; an 18-hole match has no presses) ──
          if (!widget.overallOnly) ...[
          // ── Press configuration ───────────────────────────────────────────
          SectionCard(
            title: 'Press stakes',
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
                  GolfTextField(
                    controller: _pressUnitCtrl,
                    label: 'Press unit (\$)',
                    prefixIcon: Icons.attach_money,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Dollar amount per press stake (separate from the main stake).',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),
          ],

          // ── Stake ─────────────────────────────────────────────────────────
          StakeField(
            controller: _betCtrl,
            label: widget.overallOnly ? 'Stake' : 'Stake (main games)',
            helpText: widget.overallOnly
                ? 'What the 18-hole match is worth.'
                : 'Each of the three standard Nassau games '
                  '(Front 9, Back 9, Overall) is worth this amount.',
            onChanged: (v) => setState(() => _stakeOk = v),
          ),

          // ── Advanced / variant (Nassau only) ──────────────────────────────
          if (!widget.overallOnly) ...[
          _VariantCard(
            variant:       _variant,
            isFoursome:    _realMembers.length == 4,
            onChanged:     (v) => setState(() => _variant = v),
          ),

          const SizedBox(height: 16),
          ],

          // ── Loss cap (escalating) / max liability (bounded) ───────────────
          if (_canEscalate)
            SectionCard(
              title: 'Cap losses',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Presses and Claremont can run the stakes up with no fixed '
                    'ceiling, so you can cap each side’s losses. A side at the '
                    'cap can’t press (it would be free).',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Cap each side’s losses'),
                    value: _capEnabled,
                    onChanged: (v) => setState(() => _capEnabled = v),
                  ),
                  if (_capEnabled)
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _capCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          prefixText: '\$ ',
                          labelText: 'Max loss per side',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                ],
              ),
            )
          else
            MaxLiabilityNote(
              bet: double.tryParse(_betCtrl.text.trim()) ?? 0,
              multiple: _baseMultiple,
              detail: widget.overallOnly
                  ? 'the 18-hole match'
                  : 'lose all 3 (front, back, overall)',
            ),
          const SizedBox(height: 16),

          // ── Rules reminder ────────────────────────────────────────────────
          SectionCard(
            title: widget.overallOnly ? 'How the match works' : 'How Nassau works',
            child: Text(
              widget.overallOnly
                  ? 'A single 18-hole match. Each hole goes to the lower score '
                    '(per the handicap mode above); tied holes are halved. '
                    'Whoever is up after 18 holes wins the match.'
                  : 'Three simultaneous games — Front 9, Back 9, and Overall. '
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

  /// Order [members] for TeamSplitter4: T1 players first (positions 0,1)
  /// followed by T2 players (positions 2,3).  When no team has been picked
  /// yet, falls back to the original member order so the splitter has a
  /// stable initial layout.
  List<Membership> _splitterOrder(List<Membership> members) {
    final t1 = members
        .where((m) => (_teamMap[m.player.id] ?? 0) == 1)
        .toList();
    final t2 = members
        .where((m) => (_teamMap[m.player.id] ?? 0) == 2)
        .toList();
    final assigned = {...t1.map((m) => m.player.id),
                      ...t2.map((m) => m.player.id)};
    final unassigned = members
        .where((m) => !assigned.contains(m.player.id))
        .toList();
    // Fill T1 first, then T2, with the unassigned players.
    while (t1.length < 2 && unassigned.isNotEmpty) {
      t1.add(unassigned.removeAt(0));
    }
    while (t2.length < 2 && unassigned.isNotEmpty) {
      t2.add(unassigned.removeAt(0));
    }
    return [...t1, ...t2];
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
      'none'   => 'No press stakes.',
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

}

// ===========================================================================
// _VariantCard — Advanced settings: game variant picker
// ===========================================================================

class _VariantCard extends StatelessWidget {
  final String   variant;
  final bool     isFoursome;   // true only when roster is 2v2 (4 real players)
  final ValueChanged<String> onChanged;

  const _VariantCard({
    required this.variant,
    required this.isFoursome,
    required this.onChanged,
  });

  static const _descriptions = <String, String>{
    'none': 'Standard Nassau — tied holes are halved with no further comparison.',
    'tiebreak_2nd':
        '2nd-Ball Tie-Break — when best balls are equal, the 2nd best ball '
        'decides the hole winner. Eliminates most ties. Foursomes only.',
    'claremont':
        'Claremont — adds a simultaneous 2-point bottom game alongside the '
        'standard Nassau (top). Each hole: 1 pt for best ball, 1 pt for 2nd '
        'best ball. Bottom tracks its own F9/B9/Overall games with independent '
        'auto-presses at ±4 points down. Foursomes only.',
  };

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Advanced',
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
            const SizedBox(height: 10),
            Text('Game variant',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),

            // ── Variant chips ──────────────────────────────────────────────
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _chip(context, 'none',         'Standard'),
                _chip(context, 'tiebreak_2nd', '2nd Ball Tiebreak',
                    disabled: !isFoursome),
                _chip(context, 'claremont',    'Claremont',
                    disabled: !isFoursome),
              ],
            ),

            if (!isFoursome && variant == 'none') ...[
              const SizedBox(height: 8),
              Text(
                'Tiebreak and Claremont variants require a 2v2 foursome.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ],

            const SizedBox(height: 10),
            Text(
              _descriptions[variant] ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String value, String label,
      {bool disabled = false}) {
    final selected = variant == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: disabled ? null : (_) => onChanged(value),
    );
  }
}

