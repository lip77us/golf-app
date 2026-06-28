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
import '../widgets/max_liability_note.dart';
import '../widgets/stake_field.dart';
import '../widgets/team_splitter_4.dart';

class TripleCupSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to the game screen), and
  /// returns to the /round launch page on save instead of jumping to the game.
  final bool returnToHub;

  const TripleCupSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

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
  /// false = Fourball first (1-6) then Foursomes (7-12); true swaps them.
  /// Singles is always 13-18.
  bool   _foursomesFirst   = false;

  /// playerId → team number (1 or 2)
  final Map<int, int> _teamMap = {};
  /// Ordered list of players within each team (drives singles pairing in 2v2).
  /// Falls back to membership order when unset.
  final List<int> _team1Order = [];
  final List<int> _team2Order = [];

  final _betCtrl = TextEditingController();
  bool _stakeOk = false;
  bool _betCtrlInitialized = false;

  bool _loading = true;
  bool _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool _editing = false;
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

        // A configured game reports its matches (teams) even before any hole
        // is scored — status 'pending' is sent both when no game exists AND
        // when one exists but is unscored, so a non-empty matches list (or an
        // in_progress status) is the "already set up" tell.
        final configured =
            existing.status == 'in_progress' || existing.matches.isNotEmpty;

        // Normal flow: an already-started game jumps straight to score entry.
        // In edit mode (returnToHub — round creation / "Edit Configuration")
        // stay on the form so the user can change settings.
        if (existing.isStarted && !widget.returnToHub) {
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed(
            '/score-entry',
            arguments: widget.foursomeId,
          );
          return;
        }

        if (configured) {
          _editing       = true;
          _mode          = existing.handicapMode;
          _netPercent    = existing.netPercent;
          _altLowPct     = existing.altShotLowPct;
          _altHighPct    = existing.altShotHighPct;
          _foursomesFirst = existing.foursomesFirst;
          // Restore the saved team assignment so a re-edit starts from the
          // user's picks (not a fresh default split).
          _restoreTeams(rp, existing.team1Ids, existing.team2Ids);
        } else {
          _defaultSplit(rp);
        }
      } catch (_) {
        _defaultSplit(rp);
      }

      setState(() { _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  /// Restore the saved team split (ids in their saved order).  Any real member
  /// not covered by the saved teams (roster changed since setup) is added to
  /// the smaller side so the split stays valid; falls back to a default split
  /// when nothing usable was saved.
  void _restoreTeams(RoundProvider rp, List<int> team1Ids, List<int> team2Ids) {
    final members = _realMembers;
    final realIds = members.map((m) => m.player.id).toSet();
    final t1 = team1Ids.where(realIds.contains).toList();
    final t2 = team2Ids.where(realIds.contains).toList();
    if (t1.isEmpty && t2.isEmpty) {
      _defaultSplit(rp);
      return;
    }
    _teamMap.clear();
    _team1Order
      ..clear()
      ..addAll(t1);
    _team2Order
      ..clear()
      ..addAll(t2);
    for (final pid in t1) _teamMap[pid] = 1;
    for (final pid in t2) _teamMap[pid] = 2;
    for (final m in members) {
      final pid = m.player.id;
      if (_teamMap.containsKey(pid)) continue;
      final toTeam = _team1Order.length <= _team2Order.length ? 1 : 2;
      _teamMap[pid] = toTeam;
      (toTeam == 1 ? _team1Order : _team2Order).add(pid);
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
        foursomesFirst:            _foursomesFirst,
      );

      if (!ok) {
        if (!mounted) return;
        setState(() { _starting = false; _error = rp.error; });
        return;
      }

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": return to the launch page
        // sitting below us.  Reload the round first so the hub reflects the
        // freshly-saved game, then pop — popping (rather than pushing a new
        // /triple-cup) keeps a single hub on the stack.
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

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrlInitialized = true;
      final b = rp.round!.betUnit;
      _betCtrl.text = b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
      _stakeOk = double.tryParse(_betCtrl.text) != null;
    }

    return Scaffold(
      appBar: AppBar(
          title: Text(_editing
              ? 'Edit Triple Cup'
              : 'One-Round Triple Cup — Setup')),
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
                          onPressed: (_starting || !_rosterValid || !_stakeOk) ? null : _start,
                          child: _starting
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(_editing ? 'Save Configuration' : 'Start Match',
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
                                label: const Text('Blue',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold)),
                              ),
                              ButtonSegment(
                                value: 2,
                                label: const Text('Orange',
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
                      const _ColoredTeamChip(team: 1, label: 'Blue'),
                      const SizedBox(width: 6),
                      Expanded(child: Text(_teamLabel(members, 1))),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      const _ColoredTeamChip(team: 2, label: 'Orange'),
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

            // ── Segment order ────────────────────────────────────────
            SectionCard(
              title: 'Segment order',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _foursomesFirst
                        ? 'Foursomes 1–6  ·  Fourball 7–12  ·  Singles 13–18'
                        : 'Fourball 1–6  ·  Foursomes 7–12  ·  Singles 13–18',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Play Foursomes first'),
                    subtitle: const Text(
                        'Swap the first two segments — alt-shot on 1–6.'),
                    value: _foursomesFirst,
                    onChanged: (v) => setState(() => _foursomesFirst = v),
                  ),
                ],
              ),
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
                    '(holes ${_foursomesFirst ? '1–6' : '7–12'}).  '
                    'USGA default is 50% low + 50% high.',
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

            // Foursomes alt-shot tee-off is no longer chosen here — the
            // score-entry screen asks the team who tees off first right when
            // the foursomes segment begins.

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

            // ── Stake ────────────────────────────────────────────────
            StakeField(
              controller: _betCtrl,
              label: 'Stake (cup payout)',
              helpText: 'One payout for the whole cup.  Each player on the '
                  'losing side pays this amount; each player on the winning '
                  'side collects it.  A tied cup is a wash.',
              onChanged: (v) => setState(() => _stakeOk = v),
            ),
            MaxLiabilityNote(
              bet: double.tryParse(_betCtrl.text.trim()) ?? 0,
              multiple: 1,                   // the whole cup is one bet
              detail: 'one cup payout',
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
