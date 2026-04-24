/// screens/sixes_setup_screen.dart
///
/// "Start of Match" setup screen for the Six's game.
///
/// Shows only once per match — if segments with teams already exist the
/// screen immediately redirects to the scoring screen.
///
/// Layout:
///   • AppBar:        "Golf Gaming"
///   • Hole info card: Hole N (par / yds / SI) + draggable player rows.
///                    Top 2 → Team A, bottom 2 → Team B.
///   • Match preview: Shows the team pairing that will be played.
///   • Start Match:   POSTs the setup (always 6 holes, or fewer if fewer
///                    holes remain) and pushes /sixes.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/round_provider.dart';

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class SixesSetupScreen extends StatefulWidget {
  final int    foursomeId;
  final int    startHole;           // first hole of this match (1, 7, or 13)
  final int    matchNumber;         // shown in the preview
  final String teamSelectMethod;    // 'long_drive', 'random', or 'remainder'

  const SixesSetupScreen({
    super.key,
    required this.foursomeId,
    this.startHole = 1,
    this.matchNumber = 1,
    this.teamSelectMethod = 'long_drive',
  });

  @override
  State<SixesSetupScreen> createState() => _SixesSetupScreenState();
}

class _SixesSetupScreenState extends State<SixesSetupScreen> {
  /// Players in drag order — positions 0 & 1 = Team A, 2 & 3 = Team B.
  late List<Membership> _orderedPlayers;

  bool _initialized   = false;
  bool _checkingSetup = true; // true while we're checking for an existing match

  // Handicap settings the user picks for this match.
  //   _handicapMode: 'net' or 'gross'
  //   _netPercent:   0–200; only used when mode == 'net'
  String _handicapMode = 'net';
  int    _netPercent   = 100;

  // Bet unit for this round (editable inline).  Pre-filled from the
  // round's current bet_unit after the round loads.  On Start Match we
  // PATCH the round if this value differs from what's on the server.
  final _betCtrl = TextEditingController();
  bool  _betCtrlInitialized = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final rp = context.read<RoundProvider>();

      // 1. Check whether sixes is already set up for this foursome.
      //    loadSixes sets _sixesStartedFoursomes if segments with teams exist.
      if (!rp.sixesIsStarted(widget.foursomeId)) {
        await rp.loadSixes(widget.foursomeId);
      }

      if (!mounted) return;

      // 2. If already started → skip setup and go straight to scoring.
      if (rp.sixesIsStarted(widget.foursomeId)) {
        Navigator.of(context).pushReplacementNamed(
          '/sixes',
          arguments: widget.foursomeId,
        );
        return;
      }

      // 3. Load scorecard so we can show hole info and player names.
      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      }

      setState(() => _checkingSetup = false);
    });
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<Membership> _playersFromProvider(RoundProvider rp) {
    final foursome = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (foursome != null) return foursome.realPlayers;

    final sc = rp.scorecard;
    if (sc != null && sc.holes.isNotEmpty) {
      return sc.holes.first.scores
          .map((s) => Membership(
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
              ))
          .toList();
    }
    return [];
  }

  // The old `_initials(name)` helper was removed when this screen was
  // migrated to PlayerProfile.shortName.  _MatchPreview now pulls the
  // short label directly off each Membership's player via
  // `m.player.displayShort`, which transparently falls back to a
  // name-based initials computation if short_name happens to be blank
  // (e.g. a legacy cached row that hasn't been re-fetched yet).

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _startMatch(BuildContext ctx) async {
    if (_orderedPlayers.length < 4) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
        content: Text('Need 4 players to start a match.'),
      ));
      return;
    }

    final p = _orderedPlayers;

    // Drag order: p[0]=P1, p[1]=P2, p[2]=P3, p[3]=P4.
    //
    // Match 1 (user-chosen):  P1+P2  vs  P3+P4
    //
    // There are exactly two other 2v2 pairings that give P1 a new partner:
    //   Option A:  P1+P3  vs  P2+P4
    //   Option B:  P1+P4  vs  P2+P3
    //
    // Pick one randomly for Match 2; the other becomes Match 3.
    // This guarantees P1 plays alongside every other player exactly once.
    final bool p1WithP3InMatch2 = Random().nextBool();

    // Match 2 teams
    final int p1Partner2 = p1WithP3InMatch2 ? 2 : 3; // index of P3 or P4
    final int p2Partner2 = p1WithP3InMatch2 ? 3 : 2; // the other one

    // Match 3 teams (the remaining pairing)
    final int p1Partner3 = p2Partner2; // whoever P1 didn't partner in Match 2
    final int p2Partner3 = p1Partner2;

    // All three standard segments are submitted up front with their default
    // hole ranges.  calculate_sixes will dynamically reposition them if any
    // match ends early.
    final segmentData = [
      {
        'start_hole': 1,
        'end_hole': 6,
        'team_select_method': 'long_drive',
        'team1_player_ids': [p[0].player.id, p[1].player.id],
        'team2_player_ids': [p[2].player.id, p[3].player.id],
      },
      {
        'start_hole': 7,
        'end_hole': 12,
        'team_select_method': 'random',
        'team1_player_ids': [p[0].player.id, p[p1Partner2].player.id],
        'team2_player_ids': [p[1].player.id, p[p2Partner2].player.id],
      },
      {
        'start_hole': 13,
        'end_hole': 18,
        'team_select_method': 'remainder',
        'team1_player_ids': [p[0].player.id, p[p1Partner3].player.id],
        'team2_player_ids': [p[1].player.id, p[p2Partner3].player.id],
      },
    ];

    final rp = context.read<RoundProvider>();

    // Persist the bet unit first if the user edited it.  We do this BEFORE
    // setupSixes so if the PATCH fails the user isn't left with a
    // half-configured match.  A value the user didn't touch is a no-op.
    final parsedBet = double.tryParse(_betCtrl.text);
    final currentBet = rp.round?.betUnit;
    if (parsedBet != null && currentBet != null &&
        (parsedBet - currentBet).abs() > 0.001) {
      final betOk = await rp.updateRoundBetUnit(parsedBet);
      if (!ctx.mounted) return;
      if (!betOk) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(rp.error ?? 'Failed to update bet unit.'),
          backgroundColor: Theme.of(ctx).colorScheme.error,
        ));
        return;
      }
    }

    final ok = await rp.setupSixes(
      widget.foursomeId,
      segmentData,
      handicapMode: _handicapMode,
      netPercent:   _netPercent,
    );

    if (!ctx.mounted) return;

    if (!ok) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(rp.error ?? 'Failed to save match setup.'),
        backgroundColor: Theme.of(ctx).colorScheme.error,
        action: SnackBarAction(
          label: 'Retry',
          textColor: Theme.of(ctx).colorScheme.onError,
          onPressed: () => _startMatch(ctx),
        ),
      ));
      return;
    }

    Navigator.of(ctx).pushReplacementNamed('/sixes', arguments: widget.foursomeId);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();

    // Show spinner while we check for an existing match.
    if (_checkingSetup || rp.loadingSixes) {
      return Scaffold(
        appBar: AppBar(title: const Text('Golf Gaming'), centerTitle: true),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Lazily initialise the ordered player list once data is available.
    if (!_initialized) {
      final players = _playersFromProvider(rp);
      if (players.isNotEmpty) {
        _orderedPlayers = List.from(players);
        _initialized = true;
      } else {
        _orderedPlayers = [];
      }
    }

    // Pre-fill the bet unit field from the round exactly once, as soon as
    // the round is available.  Doing this in build (rather than initState)
    // means we naturally wait for loadRound() to finish.
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrl.text = rp.round!.betUnit.toStringAsFixed(2);
      _betCtrlInitialized = true;
    }

    final holeData = rp.scorecard?.holeData(widget.startHole);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Golf Gaming'),
        centerTitle: true,
      ),
      body: rp.loadingScorecard && rp.scorecard == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Hole info card with drag-reorderable players ──
                      _HolePlayerCard(
                        holeData:       holeData,
                        startHole:      widget.startHole,
                        orderedPlayers: _orderedPlayers,
                        onReorder: (oldIdx, newIdx) {
                          setState(() {
                            if (newIdx > oldIdx) newIdx--;
                            final p = _orderedPlayers.removeAt(oldIdx);
                            _orderedPlayers.insert(newIdx, p);
                          });
                        },
                      ),
                      const SizedBox(height: 20),

                      // ── Handicap mode picker ──
                      _HandicapModeCard(
                        mode:        _handicapMode,
                        netPercent:  _netPercent,
                        onModeChanged: (m) => setState(() => _handicapMode = m),
                        onPercentChanged: (p) => setState(() => _netPercent = p),
                      ),
                      const SizedBox(height: 20),

                      // ── Bet unit (round-level, editable here) ──
                      _BetUnitCard(controller: _betCtrl),
                      const SizedBox(height: 20),

                      // ── Match preview ──
                      if (_orderedPlayers.length >= 4)
                        _MatchPreview(
                          matchNumber:  widget.matchNumber,
                          startHole:    widget.startHole,
                          teamAPlayers: _orderedPlayers.take(2).toList(),
                          teamBPlayers: _orderedPlayers.skip(2).take(2).toList(),
                          handicapMode: _handicapMode,
                          netPercent:   _netPercent,
                        ),
                    ],
                  ),
                ),
              ),

              // ── Start Match button ──
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed:
                          (rp.submitting || _orderedPlayers.length < 4)
                              ? null
                              : () => _startMatch(context),
                      child: rp.submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text(
                              'Start Match',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ),
              ),
            ]),
    );
  }
}

// ===========================================================================
// Hole info card — drag-reorderable player rows
// ===========================================================================

class _HolePlayerCard extends StatelessWidget {
  final ScorecardHole?   holeData;
  final int              startHole;
  final List<Membership> orderedPlayers;
  final void Function(int, int) onReorder;

  const _HolePlayerCard({
    required this.holeData,
    required this.startHole,
    required this.orderedPlayers,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Hole header
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Column(children: [
            Text('Hole $startHole',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            if (holeData != null)
              Text(
                'Par ${holeData!.par}  |  '
                '${holeData!.yards != null ? "${holeData!.yards} yds.  |  " : ""}'
                'SI: ${holeData!.strokeIndex}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
          ]),
        ),

        // Drag-reorderable player rows
        if (orderedPlayers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(
              height: 32,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
        else
          SizedBox(
            height: orderedPlayers.length * 56.0,
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              onReorder: onReorder,
              proxyDecorator: (child, index, animation) => Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                child: child,
              ),
              children: orderedPlayers.asMap().entries.map((entry) {
                final idx       = entry.key;
                final m         = entry.value;
                final teamLabel = idx < 2 ? 'Team A' : 'Team B';
                final teamColor = idx < 2
                    ? theme.colorScheme.primary
                    : theme.colorScheme.tertiary;

                return Container(
                  key: ValueKey(m.player.id),
                  height: 56,
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                          color: theme.colorScheme.outlineVariant),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(children: [
                    ReorderableDragStartListener(
                      index: idx,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.drag_handle,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Text('${idx + 1})  ',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.primary)),
                    Expanded(
                      child: Text(m.player.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: teamColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: teamColor.withOpacity(0.4)),
                      ),
                      child: Text(teamLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: teamColor,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                    // Placeholder score box
                    Container(
                      width: 40,
                      height: 36,
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: theme.colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ]),
                );
              }).toList(),
            ),
          ),
      ]),
    );
  }
}

// ===========================================================================
// Match preview — static summary of what will be played
// ===========================================================================

class _MatchPreview extends StatelessWidget {
  final int              matchNumber;
  final int              startHole;
  final List<Membership> teamAPlayers;
  final List<Membership> teamBPlayers;
  final String           handicapMode;   // 'net' | 'gross'
  final int              netPercent;     // only used when handicapMode == 'net'

  const _MatchPreview({
    required this.matchNumber,
    required this.startHole,
    required this.teamAPlayers,
    required this.teamBPlayers,
    required this.handicapMode,
    required this.netPercent,
  });

  String _teamLine(List<Membership> players, List<int> positions) {
    // Prefer each player's custom short_name (≤ 5 chars); fall back to
    // computed initials when unset (e.g. legacy cached rows).
    final abbr = players.map((m) => m.player.displayShort).join('/');
    final pos  = positions.map((p) => '$p').join('/');
    return '$abbr ($pos)';
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final endHole  = (startHole + 5).clamp(1, 18);
    final teamA    = _teamLine(teamAPlayers, [1, 2]);
    final teamB    = _teamLine(teamBPlayers, [3, 4]);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Match $matchNumber',
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          Text(teamA,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('v.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Text(teamB,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            'Holes $startHole–$endHole  •  Best ball, '
            '${handicapMode == 'gross' ? 'gross' : 'net ($netPercent%)'}  •  '
            'Match ends early if a team wins more holes than remain',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Handicap mode picker — Gross vs Net (+ net percentage)
// ===========================================================================

/// Small card with a single dollar-amount field for the round's bet
/// unit.  Edits here are saved back to Round.bet_unit when the user taps
/// Start Match.  No submit button of its own — the value is just read
/// off the controller by _startMatch.
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
            'Applies to every game in this round.  Edit here to update the '
            'round-level value without leaving match setup.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}


class _HandicapModeCard extends StatelessWidget {
  /// 'net', 'gross', or 'strokes_off'.
  final String mode;

  /// 0–200.  Only meaningful when mode == 'net'.
  final int netPercent;

  final ValueChanged<String> onModeChanged;
  final ValueChanged<int>    onPercentChanged;

  const _HandicapModeCard({
    required this.mode,
    required this.netPercent,
    required this.onModeChanged,
    required this.onPercentChanged,
  });

  // Common allowance presets — 100% is the default, 90% is USGA recommended
  // for 2v2 best-ball, 80% is sometimes used for bigger handicap spreads,
  // 75% for very wide spreads.  Kept to four so they fit on one row and
  // the bet unit card sits higher on the screen.
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

          // Net / Gross / SO segmented buttons.  "SO" = Strokes Off the
          // low golfer in the foursome.
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'net',         label: Text('Net')),
              ButtonSegment(value: 'gross',       label: Text('Gross')),
              ButtonSegment(value: 'strokes_off', label: Text('SO')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onModeChanged(s.first),
          ),

          // Mode-specific helper text / controls below the picker.
          if (mode == 'net') ...[
            const SizedBox(height: 12),
            Text('Handicap allowance',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
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
            // 'strokes_off'
            const SizedBox(height: 8),
            Text(
              'Low player in the foursome plays to 0. Others get '
              '(own HCP − low HCP) strokes, spread across the three '
              '6-hole matches and allocated to the hardest holes in each. '
              'Strokes planned on unreached holes die; extra-match holes '
              'use a stroke-index threshold.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}
