/// screens/triple_cup_setup_screen.dart
/// -------------------------------------
/// Setup screen for the One-Round Ryder Cup ("Triple Cup") casual game.
///
/// Knobs:
///   • Team assignment — tap to move each player between Team 1 / Team 2
///     For 2v2 the order within each team also picks the singles pairing
///     (team1[0] vs team2[0], team1[1] vs team2[1]).
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + Net %
///   • Alt-shot allowance (low% + high%) — defaults to USGA 50/50
///   • Phantom score mode for 2v1 fourball — net par (default) or net bogey
///   • Bet unit (round-level)
///
/// Roster: 2–4 real players, at least 1 per team.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/inline_message.dart';
import '../widgets/section_card.dart';
import '../widgets/net_double_bogey_card.dart';
import '../widgets/team_splitter_4.dart';

class TripleCupSetupScreen extends StatefulWidget {
  final int foursomeId;
  const TripleCupSetupScreen({super.key, required this.foursomeId});

  @override
  State<TripleCupSetupScreen> createState() => _TripleCupSetupScreenState();
}

class _TripleCupSetupScreenState extends State<TripleCupSetupScreen> {
  // Default to Strokes-Off Low — most common Triple Cup setup; users
  // can still pick Net or Gross.  Existing rounds overwrite this in
  // _load() from the persisted setup.
  String _mode             = 'strokes_off';
  int    _netPercent       = 100;
  int    _altLowPct        = 50;
  int    _altHighPct       = 50;
  /// Foursomes alt-shot first tee-off player IDs per team.  Null
  /// means "use the backend default" (lowest handicap on the team).
  int?   _t1FirstTee;
  int?   _t2FirstTee;

  /// playerId → team number (1 or 2)
  final Map<int, int> _teamMap = {};
  /// Ordered list of players within each team (drives singles pairing in 2v2).
  /// Falls back to membership order when unset.
  final List<int> _team1Order = [];
  final List<int> _team2Order = [];

  final _betCtrl = TextEditingController();
  bool _betCtrlInitialized = false;

  bool _loading = true;
  bool _starting = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // Defer until after the first frame — _load() triggers
    // provider.notifyListeners() via loadScorecard, which Flutter
    // rejects if called synchronously during the initial build pass.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    // Prefer the round's foursome roster when available; fall back to
    // the scorecard's player list when entering setup before the round
    // has been loaded into the provider (e.g. straight off the casual
    // round creation flow).  Mirrors sixes_setup_screen._playersFromProvider.
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs != null) {
      return fs.memberships.where((m) => !m.player.isPhantom).toList();
    }
    final sc = rp.scorecard;
    if (sc != null && sc.holes.isNotEmpty) {
      return sc.holes.first.scores.map((s) => Membership(
            id: s.playerId,
            player: PlayerProfile(
              id: s.playerId,
              name: s.playerName,
              handicapIndex: '0',
              isPhantom: false,
              email: '',
            ),
            courseHandicap: 0,
            playingHandicap: s.handicapStrokes,
          )).toList();
    }
    return const [];
  }

  bool get _rosterValid {
    final members = _realMembers;
    final n = members.length;
    if (n < 2 || n > 4) return false;
    final t1 = _teamMap.values.where((v) => v == 1).length;
    final t2 = _teamMap.values.where((v) => v == 2).length;
    if (!(t1 >= 1 && t2 >= 1 && (t1 + t2) == n)) return false;
    // 2v1 only valid in cup rounds (needs cross-foursome donor scores
    // for the fourball segment).  Casual 2v1 is rejected server-side
    // too; gate it client-side so the Start button stays disabled with
    // a clear message instead of bouncing off a 400.
    if (n == 3 && !_isCupRound) return false;
    return true;
  }

  bool get _isCupRound {
    return context.read<RoundProvider>().round?.isCupRound ?? false;
  }

  List<int> _orderedTeamIds(int team) {
    final order = team == 1 ? _team1Order : _team2Order;
    final present = _teamMap.entries
        .where((e) => e.value == team)
        .map((e) => e.key)
        .toSet();
    final ordered = order.where(present.contains).toList();
    for (final id in present) {
      if (!ordered.contains(id)) ordered.add(id);
    }
    return ordered;
  }

  bool get _is2v1 {
    final t1 = _teamMap.values.where((v) => v == 1).length;
    final t2 = _teamMap.values.where((v) => v == 2).length;
    return (t1 + t2) == 3 && (t1 == 1 || t2 == 1);
  }

  // ── Load ────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rp = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      // Make sure the foursome roster is in the provider — when the
      // user lands here straight from casual-round creation, rp.round
      // may not be loaded yet.  Loading the scorecard populates the
      // player list that _realMembers falls back to.
      if (rp.scorecard == null ||
          rp.activeFoursomeId != widget.foursomeId) {
        await rp.loadScorecard(widget.foursomeId);
      }

      // Pre-populate from any existing game.
      try {
        final existing = await client.getTripleCupSummary(widget.foursomeId);
        if (existing.isStarted) {
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed(
            '/triple-cup',
            arguments: widget.foursomeId,
          );
          return;
        }
        _mode          = existing.handicapMode;
        _netPercent    = existing.netPercent;
        _altLowPct     = existing.altShotLowPct;
        _altHighPct    = existing.altShotHighPct;
        // The summary's team info has names but no player IDs, so we
        // default-split instead of trying to reconstruct.  The user
        // can re-pick teams in the UI before re-starting.
        _defaultSplit(rp);
      } catch (_) {
        _defaultSplit(rp);
      }

      setState(() { _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  void _defaultSplit(RoundProvider rp) {
    final members = _realMembers;
    _teamMap.clear();
    _team1Order.clear();
    _team2Order.clear();
    for (var i = 0; i < members.length; i++) {
      final pid = members[i].player.id;
      final team = i < (members.length / 2).ceil() ? 1 : 2;
      _teamMap[pid] = team;
      (team == 1 ? _team1Order : _team2Order).add(pid);
    }
  }

  // ── Start ────────────────────────────────────────────────────────────────────

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp = context.read<RoundProvider>();

      final betText = _betCtrl.text.trim();
      final parsed  = double.tryParse(betText);
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      final ok = await rp.setupTripleCup(
        widget.foursomeId,
        team1Ids:                  _orderedTeamIds(1),
        team2Ids:                  _orderedTeamIds(2),
        handicapMode:              _mode,
        netPercent:                _netPercent,
        altShotLowPct:             _altLowPct,
        altShotHighPct:            _altHighPct,
        foursomesTeam1FirstTee:    _t1FirstTee,
        foursomesTeam2FirstTee:    _t2FirstTee,
      );

      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pushReplacementNamed(
          '/triple-cup',
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
      appBar: AppBar(title: const Text('One-Round Triple Cup — Setup')),
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
                  SafeArea(
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
            // ── Teams ────────────────────────────────────────────────
            SectionCard(
              title: 'Teams',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (members.length == 4) ...[
                    Text(
                      'Drag rows to assemble the Red and Blue teams. '
                      'In singles the top Red plays the top Blue, and '
                      'the bottom two face each other.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    TeamSplitter4(
                      players: _splitterOrder(members),
                      onChanged: (ordered) {
                        setState(() {
                          _teamMap.clear();
                          _team1Order.clear();
                          _team2Order.clear();
                          for (var i = 0; i < ordered.length; i++) {
                            final pid  = ordered[i].player.id;
                            final team = i < 2 ? 1 : 2;
                            _teamMap[pid] = team;
                            (team == 1 ? _team1Order : _team2Order).add(pid);
                          }
                        });
                      },
                    ),
                  ] else ...[
                    Text(
                      'Tap to assign each player to a team.',
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
                            segments: [
                              ButtonSegment(
                                value: 1,
                                label: const Text('Red',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold)),
                              ),
                              ButtonSegment(
                                value: 2,
                                label: const Text('Blue',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold)),
                              ),
                            ],
                            selected: {team},
                            onSelectionChanged: (s) => setState(() {
                              _teamMap[pid] = s.first;
                              _team1Order.remove(pid);
                              _team2Order.remove(pid);
                              (s.first == 1 ? _team1Order : _team2Order).add(pid);
                            }),
                            style: SegmentedButton.styleFrom(
                                visualDensity: VisualDensity.compact),
                          ),
                        ]),
                      );
                    }),
                    const SizedBox(height: 12),
                    Row(children: [
                      const _ColoredTeamChip(team: 1, label: 'Red'),
                      const SizedBox(width: 6),
                      Expanded(child: Text(_teamLabel(members, 1))),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      const _ColoredTeamChip(team: 2, label: 'Blue'),
                      const SizedBox(width: 6),
                      Expanded(child: Text(_teamLabel(members, 2))),
                    ]),
                  ],

                  if (!_rosterValid) ...[
                    const SizedBox(height: 8),
                    InlineMessage(
                      kind: InlineMessageKind.warn,
                      text: members.length < 2
                          ? 'Need at least 2 real players.'
                          : (members.length == 3 && !_isCupRound)
                              ? '2v1 Triple Cup is only available in '
                                'cup rounds (needs cross-foursome '
                                'teammates as phantom donors). Pick 2 '
                                'or 4 players for a casual round.'
                              : 'Each team must have at least 1 player.',
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Handicap mode ────────────────────────────────────────
            HandicapModeSelector(
              mode:             _mode,
              netPercent:       _netPercent,
              onModeChanged:    (m) => setState(() => _mode = m),
              onPercentChanged: (p) => setState(() => _netPercent = p),
            ),

            const SizedBox(height: 16),

            // ── Alt-shot allowance ───────────────────────────────────
            SectionCard(
              title: 'Foursomes (alt-shot) handicap',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Combined team handicap for the alt-shot segment '
                    '(holes 7–12).  USGA default is 50% low + 50% high.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _pctField('Low %', _altLowPct,
                        (v) => setState(() => _altLowPct = v))),
                    const SizedBox(width: 12),
                    Expanded(child: _pctField('High %', _altHighPct,
                        (v) => setState(() => _altHighPct = v))),
                  ]),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Foursomes tee-off (2v2 only) ─────────────────────────
            if (members.length == 4) ...[
              SectionCard(
                title: 'Foursomes (alt-shot) tee-off',
                child: _ForsomesTeeOffPicker(
                  members:      members,
                  teamMap:      _teamMap,
                  team1FirstTee: _t1FirstTee,
                  team2FirstTee: _t2FirstTee,
                  onChanged: (t1, t2) => setState(() {
                    _t1FirstTee = t1;
                    _t2FirstTee = t2;
                  }),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ── Phantom donor note (only for 2v1) ────────────────────
            if (_is2v1)
              SectionCard(
                title: '2v1 phantom partner (fourball only)',
                child: Text(
                  'The solo player gets a phantom partner for the 6 '
                  'fourball holes.  The phantom\'s score on each hole is '
                  'a randomly-assigned teammate\'s gross from another '
                  'foursome (cross-foursome donor) — same mechanism the '
                  'cup Four Ball uses.  Foursomes (alt-shot) and singles '
                  'are played by the solo alone.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),

            if (_is2v1) const SizedBox(height: 16),

            // ── Round bet unit ───────────────────────────────────────
            SectionCard(
              title: 'Stake (cup payout)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GolfTextField(
                    controller: _betCtrl,
                    label: 'Stake (\$)',
                    prefixIcon: Icons.attach_money,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'One payout for the whole cup.  Each player on the '
                    'losing side pays this amount; each player on the '
                    'winning side collects it.  A tied cup is a wash.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            if (rp.round != null)
              NetDoubleBogeyCard(
                value: rp.round!.netMaxDoubleBogey,
                onChanged: (v) {
                  context.read<RoundProvider>().updateRoundNetMaxDoubleBogey(v);
                },
              ),

            const SizedBox(height: 16),

            // ── Rules reminder ───────────────────────────────────────
            SectionCard(
              title: 'How it works',
              child: Text(
                'Three 6-hole segments: Fourball (best ball) on 1–6, '
                'Foursomes (alt-shot) on 7–12, Singles on 13–18.  In 2v2, '
                'singles plays as two simultaneous 1v1 matches — total of 4 '
                'matches per round.  In 2v1, the solo carries every segment '
                '(with a phantom partner in fourball).  In 1v1, every '
                'segment plays as singles for 3 matches total.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  // ── Small helpers ────────────────────────────────────────────────────────

  String _teamLabel(List<Membership> members, int team) {
    final ordered = _orderedTeamIds(team);
    final names = ordered.map((pid) {
      final m = members.firstWhere((x) => x.player.id == pid);
      return m.player.displayShort;
    }).toList();
    return names.isEmpty ? '—' : names.join(' & ');
  }

  /// Re-arrange members so the 4 passed to TeamSplitter4 land in the
  /// caller-intended positions: T1 players first (rows 0,1), then T2
  /// players (rows 2,3).  Unassigned members fill remaining slots.
  /// Mirrors the helper in NassauSetupScreen.
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
    while (t1.length < 2 && unassigned.isNotEmpty) {
      t1.add(unassigned.removeAt(0));
    }
    while (t2.length < 2 && unassigned.isNotEmpty) {
      t2.add(unassigned.removeAt(0));
    }
    return [...t1, ...t2];
  }

  Widget _pctField(String label, int value, ValueChanged<int> onChanged) {
    return GolfTextField(
      initialValue: value.toString(),
      label: label,
      suffixText: '%',
      keyboardType: TextInputType.number,
      onChanged: (s) {
        final v = int.tryParse(s.trim());
        if (v != null && v >= 0 && v <= 100) onChanged(v);
      },
    );
  }

}

/// Small pill rendering the team's color + label.  Used by the
/// summary rows under the per-player toggle list (1v1 mode).
class _ColoredTeamChip extends StatelessWidget {
  final int team;
  final String label;
  const _ColoredTeamChip({required this.team, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = team == 1 ? kTripleCupTeam1Color : kTripleCupTeam2Color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          )),
    );
  }
}

/// Picker for which player on each team tees off the first foursomes
/// hole.  The partner takes the next hole; alternation continues
/// through the segment.  Defaults (and falls back) to the lower-
/// handicap player on each team.
class _ForsomesTeeOffPicker extends StatelessWidget {
  final List<Membership> members;
  final Map<int, int>    teamMap;
  final int?             team1FirstTee;
  final int?             team2FirstTee;
  final void Function(int? t1, int? t2) onChanged;

  const _ForsomesTeeOffPicker({
    required this.members,
    required this.teamMap,
    required this.team1FirstTee,
    required this.team2FirstTee,
    required this.onChanged,
  });

  List<Membership> _teamMembers(int team) =>
      members.where((m) => (teamMap[m.player.id] ?? 0) == team).toList();

  int? _defaultFor(List<Membership> team) {
    if (team.length < 2) return null;
    final sorted = List<Membership>.from(team)
      ..sort((a, b) => a.playingHandicap.compareTo(b.playingHandicap));
    return sorted.first.player.id;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t1   = _teamMembers(1);
    final t2   = _teamMembers(2);
    if (t1.length < 2 || t2.length < 2) {
      return Text(
        'Pick 2 players for each team to set tee-off order.',
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final t1Selected = team1FirstTee ?? _defaultFor(t1);
    final t2Selected = team2FirstTee ?? _defaultFor(t2);

    Widget pickerRow(
      String teamLabel,
      Color teamColor,
      List<Membership> team,
      int? selected,
      void Function(int id) onPick,
    ) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
            width: 56,
            child: Text(teamLabel,
                style: TextStyle(
                    color: teamColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
          ),
          Expanded(
            child: SegmentedButton<int>(
              segments: team.map((m) => ButtonSegment<int>(
                    value: m.player.id,
                    label: Text(m.player.displayShort),
                  )).toList(),
              selected: selected == null ? <int>{} : {selected},
              emptySelectionAllowed: true,
              onSelectionChanged: (s) =>
                  s.isEmpty ? null : onPick(s.first),
              style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact),
            ),
          ),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Who tees off hole 7 for each team?  Partners alternate '
          'through the 6 alt-shot holes (7–12).',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        pickerRow('Red',  kTripleCupTeam1Color, t1, t1Selected,
            (id) => onChanged(id, team2FirstTee ?? _defaultFor(t2))),
        pickerRow('Blue', kTripleCupTeam2Color, t2, t2Selected,
            (id) => onChanged(team1FirstTee ?? _defaultFor(t1), id)),
      ],
    );
  }
}
