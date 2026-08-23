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
///
/// **The FORMAT decides which rules exist**
/// (docs/design-review/handoff-team-pairs/SPEC.md §5). The same control does
/// three different jobs:
///
///   * **A record** — scramble. Compliance against a quota.
///   * **An instruction** — Scotch. The pick says who hits next, so the tap
///     happens on every hole and a quota is available ON TOP, off by default.
///   * **A rota** — alternate shot. Odd/even, set on the 1st tee, fixed for
///     eighteen. Nothing to fall short of, so no warning and no penalty.
///   * **Absent** — best ball and Chapman. Both golfers drive every hole with no
///     choice to record, and the screen says so rather than offering a rule
///     that could never be satisfied or failed.
library;

import 'package:flutter/material.dart';

import '../../theme/halved_brand.dart';
import '../../utils/team_allowance.dart';
import '../section_card.dart';
import 'team_play_bits.dart';

class TeamDriveStep extends StatelessWidget {
  /// Four or two. A quota is the team's SIZE worth of drives, not always four:
  /// one each per nine is two of nine for a pair, seven free.
  final int    teamSize;
  final String format;
  /// The rules this format may use, server-owned and passed straight through.
  final List<String> rulesAllowed;
  final String rule;               // none | per_nine | per_eighteen | alternating
  final int    drivesRequired;
  final String penalty;            // warn | two_strokes
  /// Named so the screen can say what a short team owes — it fields a phantom,
  /// so the quota is four golfers' worth and the phantom's share rotates.
  final bool   hasShortTeam;

  final ValueChanged<String> onRule;
  final ValueChanged<int>    onDrivesRequired;
  final ValueChanged<String> onPenalty;

  const TeamDriveStep({
    super.key,
    this.teamSize = 4,
    this.format = 'scramble',
    this.rulesAllowed = const ['none', 'per_nine', 'per_eighteen', 'alternating'],
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
  bool get _isPairs => teamSize == 2;
  /// Best ball and Chapman: both golfers drive every hole, so there is nothing to
  /// record and nothing to require.
  bool get _hasNoControl => rulesAllowed.length == 1 && rulesAllowed.first == 'none';
  /// Alternate shot: the rota is the rule, and it is the only one.
  bool get _isForcedRota =>
      rulesAllowed.length == 1 && rulesAllowed.first == 'alternating';
  /// Scotch: the tap happens on every hole because it says who plays next.
  /// A quota is available on top, and it is off by default.
  bool get _isScotch => format == 'scotch';

  /// A team owes its SIZE's worth — four golfers' worth for a foursome whether it
  /// fields four or three, two golfers' worth for a pair.
  int get _required => teamSize * drivesRequired;
  int get _windowHoles => _isPerNine ? 9 : 18;
  int get _free => (_windowHoles - _required).clamp(0, 18);
  int get _maxPerGolfer => maxDrivesPerGolfer(teamSize, rule);

  String get _headerBody {
    if (_hasNoControl) {
      return 'Both golfers drive every hole in ${format == 'chapman'
          ? 'Chapman' : 'best ball'}, so there is nothing to choose.';
    }
    if (_isForcedRota) {
      return 'Alternate shot runs on a rota, not a quota. The card names the '
             'tee on every hole.';
    }
    if (_isPairs) {
      return 'Optional. Adds one tap per hole to the scorecard.';
    }
    return 'Applies to both formats. Adds one tap per hole to the scorecard.';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(_hasNoControl
                 ? 'Whose tee shot is in play'
                 : 'How many drives must each golfer give',
             style: Halved.sectionHead()),
        const SizedBox(height: 6),
        Text(_headerBody, style: Halved.body(color: Halved.muted)),
        const SizedBox(height: 16),

        // Both golfers drive every hole with no choice to record. Nothing is
        // disabled without saying why, so the screen states the reason rather
        // than showing four rules that cannot apply.
        if (_hasNoControl)
          const TeamNote(
            'Nothing to set. Both golfers drive every hole, so there is no drive '
            'to choose and no quota to count. The card carries no drive row.',
          ),

        // Alternate shot: a rota, not a quota. There is nothing to fall short
        // of, so no warning and no penalty setting.
        if (_isForcedRota)
          const TeamNote(
            'The pair sets who tees on the odd holes, on the 1st tee, and it '
            'is fixed for eighteen. Not a quota — there is nothing to fall '
            'short of, so no warning and no penalty.',
          ),

        if (!_hasNoControl && !_isForcedRota) ...[
          if (_isScotch) ...[
            const TeamNote(
              'The drive tap happens on every hole in Scotch whichever rule '
              'you pick — it is what tells the pair who plays the second '
              'shot. A quota is available on top of it, and it is off unless '
              'you set one.',
            ),
            const SizedBox(height: 12),
          ],
          TeamRadioCard(
            title: 'No requirement',
            body : _isScotch
                ? 'Take the better drive every time. The tap still names who '
                  'plays next.'
                : 'Take the best drive every time.',
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
          if (rulesAllowed.contains('alternating')) ...[
            const SizedBox(height: 10),
            TeamRadioCard(
              title: 'Alternating pairs',
              body : 'Two golfers drive each hole, the other two the next. '
                     'The team picks the pairs on the 1st tee.',
              selected: rule == 'alternating',
              onTap: () => onRule('alternating'),
            ),
          ],
        ],

        // A quota is satisfied whenever you like, so the useful number is how
        // much room is LEFT. That figure is what tells a captain whether they
        // can let their long hitter drive the par 5.
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
                  max  : _maxPerGolfer,
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
                if (hasShortTeam && !_isPairs) ...[
                  const SizedBox(height: 12),
                  TeamNote(
                    'A team of three still owes $_required — it fields a '
                    "phantom, and the phantom's drive rotates through the "
                    'three.',
                  ),
                ],
                // The slack is the point of the note, so it only makes the
                // argument while there IS slack. At the ceiling every hole is
                // spoken for and the warning below says so instead.
                if (_isPairs && _free > 0) ...[
                  const SizedBox(height: 12),
                  TeamNote(
                    'Two golfers and ${_isPerNine ? 'nine' : 'eighteen'} holes is '
                    'a lot of room — $_free hole${_free == 1 ? '' : 's'} '
                    '${_free == 1 ? 'is' : 'are'} free either way. One each '
                    'per nine is the usual rule.',
                  ),
                ],
                if (_free <= 0) ...[
                  const SizedBox(height: 12),
                  const TeamNote(
                    'No slack at all — every hole has to go to a golfer who owes '
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
            title: _isPairs ? 'Who tees on the odd holes'
                            : 'Whose tee shot is in play',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isPairs
                      ? 'The pair sets the order on the 1st tee, and the card '
                        'names the tee on every hole. Fixed for eighteen once '
                        'set — a rota that can be re-cut mid-round is not a '
                        'rota.'
                      : 'The team sets the two pairs on the 1st tee, and the '
                        'app names the pair before each hole. Fixed for '
                        'eighteen holes once set.',
                  style: Halved.body(color: Halved.muted),
                ),
                const SizedBox(height: 10),
                TeamNote(
                  _isPairs
                      ? 'A pair that loses track plays a hole out of order and '
                        'the round is gone, so the card says it every time.'
                      : 'Three golfers run AB / BC / AC. Two drivers every hole; '
                        "the golfer sitting out plays the phantom's ball.",
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

        if (rule == 'none' && !_hasNoControl && !_isScotch) ...[
          const SizedBox(height: 14),
          const TeamNote('No drive row on the card, and this screen never '
                         'appears again.'),
        ],
      ],
    );
  }
}
