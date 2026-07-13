/// screens/sixes_setup_screen.dart
///
/// "Start of Match" setup screen for the Sixes game.
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
import '../widgets/golf_app_bar.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';
import '../widgets/max_liability_note.dart';
import '../utils/play_order.dart';
import '../widgets/stake_field.dart';
import '../widgets/team_splitter_4.dart';

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class SixesSetupScreen extends StatefulWidget {
  final int    foursomeId;
  final int    startHole;           // first hole of this match (1, 7, or 13)
  final int    matchNumber;         // shown in the preview
  final String teamSelectMethod;    // 'long_drive', 'random', or 'remainder'

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const SixesSetupScreen({
    super.key,
    required this.foursomeId,
    this.startHole = 1,
    this.matchNumber = 1,
    this.teamSelectMethod = 'long_drive',
    this.returnToHub = false,
  });

  @override
  State<SixesSetupScreen> createState() => _SixesSetupScreenState();
}

class _SixesSetupScreenState extends State<SixesSetupScreen> {
  /// Players in drag order — positions 0 & 1 = Team A, 2 & 3 = Team B.
  late List<Membership> _orderedPlayers;

  /// The group's 18 holes in play order (shotgun-aware: a casual round starting
  /// on hole 8 plays 8..18,1..7). Sixes is full-18 only, so this is always 18.
  List<int> get _order {
    final rp = context.read<RoundProvider>();
    final o = roundPlayOrder(rp.round, rp.scorecard);
    return o.length == 18 ? o : [for (int i = 0; i < 18; i++) i + 1];
  }

  /// The three Sixes segments as play-order thirds: [[8-13],[14-1],[2-7]] for a
  /// shotgun from hole 8; [[1-6],[7-12],[13-18]] for a normal start.
  List<List<int>> get _thirds {
    final o = _order;
    return [o.sublist(0, 6), o.sublist(6, 12), o.sublist(12, 18)];
  }

  /// The group's first hole played (the round's starting hole).
  int get _firstHole => _order.first;

  bool _initialized   = false;
  bool _checkingSetup = true; // true while we're checking for an existing match
  /// True when editing an already-configured match (drives Save vs Start label
  /// and the AppBar title).  Set in initState when an existing match is loaded.
  bool _editing       = false;

  // Handicap settings the user picks for this match.
  //   _handicapMode: 'net' or 'gross' or 'strokes_off'
  //   _netPercent:   0–200; only used when mode == 'net'
  // Casual default → Strokes-Off Low.
  String _handicapMode = 'strokes_off';
  int    _netPercent   = 100;

  // Scoring format: 'classic' (1 pt/hole, best ball, with extras) or
  // 'high_low' (2 pts/hole — best vs best + worst vs worst, 3 segments
  // only, strict closeout, all 18 holes played).  Default to classic.
  String _scoringFormat = 'classic';

  // Handicap allocation: 'per_segment' splits Strokes-Off across the 3
  // matches (legacy Sixes behavior).  'full_round' allocates strokes by
  // round-wide stroke index (a player with N strokes gets one on every
  // hole where SI <= N).  Only meaningful when handicap_mode is
  // 'strokes_off'.  Default to per_segment for backward compatibility.
  String _handicapAllocation = 'per_segment';

  // Bet unit for this round (editable inline).  Pre-filled from the
  // round's current bet_unit after the round loads.  On Start Match we
  // PATCH the round if this value differs from what's on the server.
  final _betCtrl = TextEditingController();
  bool  _stakeOk = false;
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

      // 2. If already started → normally skip setup and go straight to score
      //    entry.  In edit mode (returnToHub: round creation / "Edit
      //    Configuration") stay on the form and pre-fill the saved teams +
      //    options instead of bouncing.
      if (rp.sixesIsStarted(widget.foursomeId)) {
        if (!widget.returnToHub) {
          Navigator.of(context).pushReplacementNamed(
            '/score-entry',
            arguments: widget.foursomeId,
          );
          return;
        }
        _editing = true;
        _prefillFromSummary(rp);
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

  /// In edit mode, adopt the saved match's options (handicap mode / net % /
  /// scoring format / allocation) and remember the saved team ordering so the
  /// lazy `_orderedPlayers` init below places players back on their saved
  /// sides (segment 1: team1 → positions 0,1; team2 → positions 2,3).
  void _prefillFromSummary(RoundProvider rp) {
    final s = rp.sixesSummary;
    if (s == null) return;
    _handicapMode       = s.handicapMode;
    _netPercent         = s.netPercent;
    _scoringFormat      = s.scoringFormat;
    _handicapAllocation = s.handicapAllocation;
    if (s.segments.isNotEmpty) {
      final seg = s.segments.first;
      _savedTeamOrder = [...seg.team1.playerIds, ...seg.team2.playerIds];
    }
  }

  /// Player-id ordering from the saved match's first segment (team1 then
  /// team2), used to restore the team layout in edit mode.  Empty otherwise.
  List<int> _savedTeamOrder = const [];

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

    // All three standard segments are submitted up front as the round's
    // play-order thirds (shotgun-aware — a start on hole 8 gives 8-13/14-1/2-7).
    // calculate_sixes re-derives these from play order too and will reposition
    // them if a match ends early.
    final thirds = _thirds;
    final segmentData = [
      {
        'start_hole': thirds[0].first,
        'end_hole': thirds[0].last,
        'team_select_method': 'long_drive',
        'team1_player_ids': [p[0].player.id, p[1].player.id],
        'team2_player_ids': [p[2].player.id, p[3].player.id],
      },
      {
        'start_hole': thirds[1].first,
        'end_hole': thirds[1].last,
        'team_select_method': 'random',
        'team1_player_ids': [p[0].player.id, p[p1Partner2].player.id],
        'team2_player_ids': [p[1].player.id, p[p2Partner2].player.id],
      },
      {
        'start_hole': thirds[2].first,
        'end_hole': thirds[2].last,
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
          content: Text(rp.error ?? 'Failed to update stake.'),
          backgroundColor: Theme.of(ctx).colorScheme.error,
        ));
        return;
      }
    }

    final ok = await rp.setupSixes(
      widget.foursomeId,
      segmentData,
      handicapMode:        _handicapMode,
      netPercent:          _netPercent,
      scoringFormat:       _scoringFormat,
      handicapAllocation:  _handicapAllocation,
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

    // Pre-load the Sixes summary so the score-entry status widget renders
    // immediately on first paint — score-entry's _loadGameSummaries gates
    // on summary != null (foursome configured_games is stale right after
    // pushReplacement, so we can't rely on that signal alone).
    await rp.loadSixes(widget.foursomeId);
    if (!ctx.mounted) return;

    if (widget.returnToHub) {
      // Round creation / "Edit Configuration": return to the launch page
      // sitting below us. Reload the round first so the hub reflects the
      // freshly-saved game, then pop (rather than pushing a new /round) to
      // keep a single hub on the stack.
      await rp.loadRound(rp.round!.id);
      if (!ctx.mounted) return;
      Navigator.of(ctx).pop();
      return;
    }

    Navigator.of(ctx).pushReplacementNamed('/score-entry', arguments: widget.foursomeId);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();

    // Show spinner while we check for an existing match.
    if (_checkingSetup || rp.loadingSixes) {
      return Scaffold(
        appBar: GolfAppBar(title: _editing ? 'Edit Sixes' : 'Sixes Setup'),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Lazily initialise the ordered player list once data is available.
    if (!_initialized) {
      final players = _playersFromProvider(rp);
      if (players.isNotEmpty) {
        _orderedPlayers = List.from(players);
        // In edit mode, restore the saved team layout (segment 1: team1 first,
        // team2 second) so the splitter shows the configured pairing.
        if (_savedTeamOrder.isNotEmpty) {
          _orderedPlayers.sort((a, b) {
            final ia = _savedTeamOrder.indexOf(a.player.id);
            final ib = _savedTeamOrder.indexOf(b.player.id);
            // Unknown ids (not in the saved order) sort to the end.
            final ra = ia < 0 ? _savedTeamOrder.length : ia;
            final rb = ib < 0 ? _savedTeamOrder.length : ib;
            return ra.compareTo(rb);
          });
        }
        _initialized = true;
      } else {
        _orderedPlayers = [];
      }
    }

    // Pre-fill the bet unit field from the round's current stake exactly once,
    // as soon as the round is available.  Doing this in build (rather than
    // initState) means we naturally wait for loadRound() to finish.  Without
    // this the field came up empty when editing an existing match, so saving
    // wiped the stake.
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

    final holeData = rp.scorecard?.holeData(_firstHole);

    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Sixes' : 'Sixes Setup'),
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
                        startHole:      _firstHole,
                        orderedPlayers: _orderedPlayers,
                        onOrderChanged: (ordered) {
                          setState(() => _orderedPlayers = ordered);
                        },
                      ),
                      const SizedBox(height: 20),

                      // ── Scoring format picker (Classic vs High-Low) ──
                      _ScoringFormatPicker(
                        format: _scoringFormat,
                        onChanged: (v) => setState(() => _scoringFormat = v),
                      ),
                      const SizedBox(height: 20),

                      // ── Handicap mode picker ──
                      HandicapModeSelector(
                        mode:        _handicapMode,
                        netPercent:  _netPercent,
                        onModeChanged: (m) => setState(() => _handicapMode = m),
                        onPercentChanged: (p) => setState(() => _netPercent = p),
                      ),

                      // ── Handicap allocation picker ──
                      // Only meaningful in Strokes-Off mode (NET and GROSS
                      // already allocate by round-wide SI / not at all,
                      // respectively).  Hidden otherwise to avoid offering
                      // a knob that doesn't do anything.
                      if (_handicapMode == 'strokes_off') ...[
                        const SizedBox(height: 20),
                        _HandicapAllocationPicker(
                          allocation: _handicapAllocation,
                          onChanged: (v) =>
                              setState(() => _handicapAllocation = v),
                        ),
                      ],
                      const SizedBox(height: 20),

                      // ── Stake (round-level, editable here) ──
                      StakeField(
                        controller: _betCtrl,
                        label: 'Stake per match',
                        onChanged: (v) => setState(() => _stakeOk = v),
                      ),
                      MaxLiabilityNote(
                        bet: double.tryParse(_betCtrl.text.trim()) ?? 0,
                        // 3 standard segments + up to 2 extra matches (an early
                        // close-out immediately starts the next match), so the
                        // worst case is losing all 5.
                        multiple: 5,
                        detail: 'lose all 5 matches (3 + up to 2 extras)',
                      ),
                      const SizedBox(height: 20),

                      // ── Match preview ──
                      if (_orderedPlayers.length >= 4)
                        _MatchPreview(
                          matchNumber:  widget.matchNumber,
                          startHole:    _thirds[0].first,
                          endHole:      _thirds[0].last,
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
                  child: GolfPrimaryButton(
                    // Hub-configured setups (round creation / "Edit
                    // Configuration") save and return — never "Start Match".
                    label: (_editing || widget.returnToHub)
                        ? 'Save Configuration'
                        : 'Start Match',
                    loading: rp.submitting,
                    onPressed: (_orderedPlayers.length < 4 || !_stakeOk)
                        ? null
                        : () => _startMatch(context),
                  ),
                ),
              ),
            ]),
    );
  }
}

// ===========================================================================
// Scoring format + handicap allocation pickers
// ===========================================================================

/// Two-radio picker: Classic vs High-Low.  Each option shows a one-liner
/// describing the scoring shape so the TD can pick at a glance.
class _ScoringFormatPicker extends StatelessWidget {
  final String format;
  final ValueChanged<String> onChanged;
  const _ScoringFormatPicker({required this.format, required this.onChanged});

  static const _options = [
    ('classic',  'Classic',
     '1 point per hole — best ball vs best ball.  Early finishes roll over into extras at the end.'),
    ('high_low', 'High-Low',
     '2 points per hole — low net vs low net + high net vs high net.  Always 3 matches, closeout if a team can\'t be caught.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Scoring format',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final opt in _options)
            InkWell(
              onTap: () => onChanged(opt.$1),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Radio<String>(
                      value: opt.$1,
                      groupValue: format,
                      onChanged: (v) { if (v != null) onChanged(v); },
                      visualDensity: VisualDensity.compact,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(opt.$2,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(opt.$3,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Picker for how STROKES_OFF strokes get spread across the round.
/// Hidden in the parent build when handicap_mode != 'strokes_off' since
/// it's a no-op for NET / GROSS modes.
class _HandicapAllocationPicker extends StatelessWidget {
  final String allocation;
  final ValueChanged<String> onChanged;
  const _HandicapAllocationPicker({
    required this.allocation,
    required this.onChanged,
  });

  static const _options = [
    ('per_segment', 'Spread across 3 matches',
     'A player with 6 SO strokes gets 2 per match.  Each match\'s strokes are allocated to the hardest holes in THAT match\'s range.'),
    ('full_round',  'Straight up (round-wide)',
     'Allocate every stroke by overall course stroke index.  A player with 6 SO strokes gets one on SI 1-6, wherever those happen to be.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Handicap allocation',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final opt in _options)
            InkWell(
              onTap: () => onChanged(opt.$1),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Radio<String>(
                      value: opt.$1,
                      groupValue: allocation,
                      onChanged: (v) { if (v != null) onChanged(v); },
                      visualDensity: VisualDensity.compact,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(opt.$2,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(opt.$3,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Hole info card — drag-reorderable player rows
// ===========================================================================

class _HolePlayerCard extends StatelessWidget {
  final ScorecardHole?               holeData;
  final int                          startHole;
  final List<Membership>             orderedPlayers;
  final ValueChanged<List<Membership>> onOrderChanged;

  const _HolePlayerCard({
    required this.holeData,
    required this.startHole,
    required this.orderedPlayers,
    required this.onOrderChanged,
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

        if (orderedPlayers.length < 4)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(
              height: 32,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: TeamSplitter4(
              players: orderedPlayers,
              onChanged: onOrderChanged,
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
  final int?             endHole;        // last hole of this match (play order)
  final List<Membership> teamAPlayers;
  final List<Membership> teamBPlayers;
  final String           handicapMode;   // 'net' | 'gross'
  final int              netPercent;     // only used when handicapMode == 'net'

  const _MatchPreview({
    required this.matchNumber,
    required this.startHole,
    this.endHole,
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
    final segEnd   = endHole ?? (startHole + 5).clamp(1, 18);
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
            'Holes $startHole–$segEnd  •  Best ball, '
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


