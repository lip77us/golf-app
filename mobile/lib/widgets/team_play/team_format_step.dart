/// widgets/team_play/team_format_step.dart
/// ---------------------------------------
/// Wizard step 3 — how a team makes a score
/// (docs/design-review/handoff-team-play/SPEC.md §4).
///
/// Two formats, and the choice reaches further than any other answer in the
/// wizard: it sets **how many numbers get entered per hole** and **what the
/// handicap even is**.
///
/// The ball-count controls **expand in place under the Shamble radio**. House
/// rule from the Irish Rumble work: no game gets a second rules screen. There
/// is no extra wizard step and no back-and-forth to check what you set.
library;

import 'package:flutter/material.dart';

import '../../theme/halved_brand.dart';
import '../../utils/team_allowance.dart';
import '../ball_count_grid.dart';
import '../section_card.dart';
import 'team_play_bits.dart';

class TeamFormatStep extends StatelessWidget {
  final String format;                    // scramble | shamble
  final String ballCountMode;
  final int    ballCountFixed;
  final Map<int, int> perHoleCounts;
  final Map<int, int> parByHole;
  /// Locked once the first score lands — a one-number card cannot be re-read
  /// as four, and the screen says so before it matters rather than after.
  final bool   locked;

  final ValueChanged<String> onFormat;
  final ValueChanged<String> onMode;
  final ValueChanged<int>    onFixed;
  final void Function(int hole, int count) onPerHole;

  const TeamFormatStep({
    super.key,
    required this.format,
    required this.ballCountMode,
    required this.ballCountFixed,
    required this.perHoleCounts,
    required this.parByHole,
    required this.locked,
    required this.onFormat,
    required this.onMode,
    required this.onFixed,
    required this.onPerHole,
  });

  bool get _isShamble => format == 'shamble';

  Map<int, int> get _counts => resolveBallCounts(
        mode: ballCountMode, fixed: ballCountFixed,
        perHole: perHoleCounts, parByHole: parByHole,
      );

  /// The shared ball-count widgets take hole-1-first lists rather than maps.
  List<int> get _holes => parByHole.keys.toList()..sort();
  List<int> get _orderedCounts =>
      [for (final h in _holes) _counts[h] ?? ballCountFixed];
  List<int> get _orderedPars =>
      [for (final h in _holes) parByHole[h] ?? 4];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('How the team scores', style: Halved.sectionHead()),
        const SizedBox(height: 6),
        Text(
          'Sets the scorecard and the handicap allowance. '
          'Locked once the first score is entered.',
          style: Halved.body(color: Halved.muted),
        ),
        const SizedBox(height: 16),

        TeamRadioCard(
          title   : 'Scramble',
          body    : 'All four hit, you play the best ball, repeat. '
                    'One score per hole.',
          selected: !_isShamble,
          enabled : !locked,
          onTap   : () => onFormat('scramble'),
        ),
        const SizedBox(height: 10),
        TeamRadioCard(
          title   : 'Shamble',
          body    : 'Best drive, then everyone plays his own ball in. '
                    'Best two count.',
          selected: _isShamble,
          enabled : !locked,
          onTap   : () => onFormat('shamble'),
        ),

        // Expanded in place, under the radio — never a second rules screen.
        if (_isShamble) ...[
          const SizedBox(height: 14),
          _BallCounts(
            mode         : ballCountMode,
            fixed        : ballCountFixed,
            perHoleCounts: perHoleCounts,
            parByHole    : parByHole,
            counts       : _counts,
            locked       : locked,
            onMode       : onMode,
            onFixed      : onFixed,
            onPerHole    : onPerHole,
          ),
          const SizedBox(height: 14),
          // The same readback Irish Rumble gives, from the same widget — a
          // golfer who has set one has learned the other. Foursome Play adds
          // the totals, because `36 counted of 72 played` is the number that
          // describes the round.
          BallCountPreview(
            perHole      : _orderedCounts,
            title        : 'What that means',
            subjectSuffix: '',
            showTotals   : true,
          ),
          // Only the per-hole mode is editable — the presets are the answer,
          // not a starting point to be nudged.
          if (ballCountMode == 'per_hole') ...[
            const SizedBox(height: 14),
            BallCountGrid(
              holePars : _orderedPars,
              perHole  : _orderedCounts,
              enabled  : !locked,
              onChanged: (idx, value) => onPerHole(idx + 1, value),
            ),
          ],
        ],

        const SizedBox(height: 16),
        TeamNote(
          _isShamble
              ? 'Allowance follows the average. Set on the handicap step, from '
                'the tees you picked on step 2.'
              : 'A three-man team fields a phantom 4th at the average of the '
                'three, so the ordinary 25/20/15/10 table applies and the '
                'format is unchanged.',
        ),
        if (locked) ...[
          const SizedBox(height: 10),
          const TeamNote('The first score has been entered, so the format is '
                      'fixed for the round.', warn: true),
        ],
      ],
    );
  }
}

// ── The ball count ──────────────────────────────────────────────────────────

class _BallCounts extends StatelessWidget {
  final String mode;
  final int    fixed;
  final Map<int, int> perHoleCounts;
  final Map<int, int> parByHole;
  final Map<int, int> counts;
  final bool   locked;
  final ValueChanged<String> onMode;
  final ValueChanged<int>    onFixed;
  final void Function(int, int) onPerHole;

  const _BallCounts({
    required this.mode, required this.fixed, required this.perHoleCounts,
    required this.parByHole, required this.counts, required this.locked,
    required this.onMode, required this.onFixed, required this.onPerHole,
  });

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Balls that count',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How many of the four scores count on a hole.',
               style: Halved.body(color: Halved.muted)),
          const SizedBox(height: 12),

          TeamRadioRow(
              selected: mode == 'fixed', enabled: !locked,
              onTap: () => onMode('fixed'),
              title: 'Fixed', body: 'The same count on all 18 holes.'),
          // A preset rather than a grid recipe: "sixes" is the shape people
          // describe in words, and making them tap eighteen cells for it is
          // the app failing to listen.
          TeamRadioRow(
              selected: mode == 'escalating', enabled: !locked,
              onTap: () => onMode('escalating'),
              title: 'Escalating — by sixes',
              body: '1 ball on 1–6, 2 on 7–12, 3 on 13–18.'),
          TeamRadioRow(
              selected: mode == 'par_based', enabled: !locked,
              onTap: () => onMode('par_based'),
              title: 'Par-based', body: 'Par 3 = 3 balls, par 4 = 2, par 5 = 1.'),
          TeamRadioRow(
              selected: mode == 'per_hole', enabled: !locked,
              onTap: () => onMode('per_hole'),
              title: 'Per hole', body: 'Set all eighteen yourself.'),

          if (mode == 'fixed') ...[
            const SizedBox(height: 10),
            TeamStepper(
              label: 'Best nets counted',
              hint : 'Out of four on the team',
              value: fixed,
              min  : 1,
              max  : 4,
              enabled: !locked,
              onChanged: onFixed,
            ),
          ],

        ],
      ),
    );
  }
}
