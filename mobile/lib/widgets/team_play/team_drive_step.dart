/// widgets/team_play/team_drive_step.dart
/// --------------------------------------
/// Wizard step 4 — the drive requirement
/// (docs/design-review/handoff-team-play/SPEC.md §5).
///
/// This is where a team round actually gets complicated. The scoring is
/// straightforward either way; the drives are the part groups argue about,
/// forget on the 15th tee, and work out wrong in the car park.
///
/// Four rules, and they are **not four settings of one thing**: three are
/// quotas and one is a schedule. That split decides the whole screen — a quota
/// shows its SLACK, a schedule shows the next hole and has no slack at all.
library;

import 'package:flutter/material.dart';

import '../../theme/halved_brand.dart';
import '../section_card.dart';
import 'team_play_bits.dart';

class TeamDriveStep extends StatelessWidget {
  final String rule;               // none | per_nine | per_eighteen | alternating
  final int    drivesRequired;
  final String penalty;            // warn | two_strokes
  /// Named so the screen can say what a short team owes — it fields a phantom,
  /// so the quota is four men's worth and the phantom's share rotates.
  final bool   hasShortTeam;

  final ValueChanged<String> onRule;
  final ValueChanged<int>    onDrivesRequired;
  final ValueChanged<String> onPenalty;

  const TeamDriveStep({
    super.key,
    required this.rule,
    required this.drivesRequired,
    required this.penalty,
    required this.hasShortTeam,
    required this.onRule,
    required this.onDrivesRequired,
    required this.onPenalty,
  });

  bool get _isQuota => rule == 'per_nine' || rule == 'per_eighteen';
  bool get _isPerNine => rule == 'per_nine';

  /// A team always owes four men's worth, whether it fields four men or three.
  int get _required => 4 * drivesRequired;
  int get _windowHoles => _isPerNine ? 9 : 18;
  int get _free => (_windowHoles - _required).clamp(0, 18);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('How many drives must each golfer give',
             style: Halved.sectionHead()),
        const SizedBox(height: 6),
        Text('Applies to both formats. Adds one tap per hole to the scorecard.',
             style: Halved.body(color: Halved.muted)),
        const SizedBox(height: 16),

        TeamRadioCard(
          title: 'No requirement',
          body : 'Take the best drive every time.',
          selected: rule == 'none',
          onTap: () => onRule('none'),
        ),
        const SizedBox(height: 10),
        TeamRadioCard(
          title: 'Per nine',
          body : "Each golfer's drive used on the front and again on the back.",
          selected: _isPerNine,
          onTap: () => onRule('per_nine'),
        ),
        const SizedBox(height: 10),
        TeamRadioCard(
          title: 'Per eighteen',
          body : 'A set number each across the whole round, whenever you like.',
          selected: rule == 'per_eighteen',
          onTap: () => onRule('per_eighteen'),
        ),
        const SizedBox(height: 10),
        TeamRadioCard(
          title: 'Alternating pairs',
          body : 'Two golfers drive each hole, the other two the next. '
                 'The team picks the pairs on the 1st tee.',
          selected: rule == 'alternating',
          onTap: () => onRule('alternating'),
        ),

        // A quota is satisfied whenever you like, so the useful number is how
        // much room is LEFT. That figure is what tells a captain whether he
        // can let his long hitter drive the par 5.
        if (_isQuota) ...[
          const SizedBox(height: 14),
          SectionCard(
            title: _isPerNine
                ? 'Drives per golfer, per nine'
                : 'Drives per golfer, across eighteen',
            child: Column(
              children: [
                TeamStepper(
                  label: 'Each golfer',
                  hint : _isPerNine ? 'On the front, and again on the back'
                                    : 'Anywhere in the round',
                  value: drivesRequired,
                  min  : 1,
                  max  : _isPerNine ? 2 : 4,
                  onChanged: onDrivesRequired,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    TeamStat(value: '$_required',
                        label: _isPerNine ? 'REQUIRED / NINE' : 'REQUIRED'),
                    TeamStat(value: '$_windowHoles', label: 'HOLES'),
                    TeamStat(value: '$_free',
                        label: _isPerNine ? 'FREE / NINE' : 'FREE'),
                  ],
                ),
                if (hasShortTeam) ...[
                  const SizedBox(height: 12),
                  TeamNote(
                    'A three-man team still owes $_required — it fields a '
                    "phantom, and the phantom's drive rotates through the "
                    'three.',
                  ),
                ],
                if (_free <= 0) ...[
                  const SizedBox(height: 12),
                  const TeamNote(
                    'No slack at all — every hole has to go to a man who owes '
                    'one.',
                    warn: true,
                  ),
                ],
              ],
            ),
          ),
          if (_isPerNine) ...[
            const SizedBox(height: 12),
            // The failure every group has had: three holes left, five drives
            // owed. It became impossible two holes ago and nobody noticed.
            const TeamNote(
              'The front nine does not carry to the back. A golfer who has not '
              'driven by the 9th green is short, and the card will say so on '
              'the 7th rather than the 18th.',
              warn: true,
            ),
          ],
        ],

        // A schedule has no slack. What it needs is one line on the tee.
        if (rule == 'alternating') ...[
          const SizedBox(height: 14),
          SectionCard(
            title: 'Whose tee shot is in play',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The team sets the two pairs on the 1st tee, and the app '
                  'names the pair before each hole. Fixed for eighteen holes '
                  'once set.',
                  style: Halved.body(color: Halved.muted),
                ),
                const SizedBox(height: 10),
                const TeamNote(
                  'Three men run AB / BC / AC. Two drivers every hole; the man '
                  "sitting out plays the phantom's ball.",
                ),
              ],
            ),
          ),
        ],

        // Most groups treat the requirement as honour and a shortfall as an
        // embarrassment. Silently disqualifying a team over a drive count
        // would be the worst outcome the app could produce.
        if (_isQuota) ...[
          const SizedBox(height: 14),
          SectionCard(
            title: 'If a team falls short',
            child: Column(
              children: [
                TeamRadioRow(
                  selected: penalty == 'warn',
                  title   : 'Warn only',
                  body    : 'The card flags it and the leaderboard notes it. '
                            'No score change.',
                  onTap   : () => onPenalty('warn'),
                ),
                TeamRadioRow(
                  selected: penalty == 'two_strokes',
                  title   : 'Two strokes per missing drive',
                  body    : "Added to the team's gross at the end of the round.",
                  onTap   : () => onPenalty('two_strokes'),
                ),
              ],
            ),
          ),
        ],

        if (rule == 'none') ...[
          const SizedBox(height: 14),
          const TeamNote('No drive row on the card, and this screen never '
                         'appears again.'),
        ],
      ],
    );
  }
}
