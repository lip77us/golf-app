/// widgets/team_play/team_handicap_step.dart
/// -----------------------------------------
/// Wizard step 5 — handicap and allowance
/// (docs/design-review/handoff-team-play/SPEC.md §6).
///
/// This is the step that decides whether anyone believes the result. A
/// scramble handicap is not four handicaps — it is **one number built from
/// four** — and the maths is unfamiliar enough that a TD who cannot see it
/// worked will not trust it.
///
/// So the screen does not ask "what allowance". It **states the allowance the
/// chosen format uses**, shows it applied to their OWN teams, and lets them
/// override the whole thing with one number if their group has its own
/// tradition. Presenting a table as an open question invites a guess.
library;

import 'package:flutter/material.dart';

import '../../theme/halved_brand.dart';
import '../../utils/team_allowance.dart';
import '../section_card.dart';
import 'team_play_bits.dart';

/// One team as this screen needs it — enough to work the allowance and name
/// the golfers it was worked on.
class TeamHandicapPreview {
  /// `Group 1` … `Group 6`. Teams name themselves from the round hub once
  /// they exist; the wizard has no business inventing six names for golfers who
  /// have not turned up yet.
  final String name;
  /// Real golfers only, in any order — the screen sorts them, because the
  /// percentage is positional and a manual order would be a lie.
  final List<({int playerId, String name, int courseHandicap})> members;

  const TeamHandicapPreview({
    required this.name, required this.members,
  });
}

class TeamHandicapStep extends StatelessWidget {
  /// Four or two. **Balance matters MORE in pairs, not less**: four handicaps
  /// average out and two do not, so a scramble pair of 3 and 22 gets 4
  /// while a pair of 9 and 23 gets 7 — three strokes on a card the field
  /// will finish inside six.
  final int    teamSize;
  final String format;               // scramble | shamble | best_ball | …
  final String handicapMode;         // net | gross
  final int?   overridePct;
  final double avgBallCount;
  /// The tee the course handicaps were computed from, named so nobody applies
  /// 25% to the wrong number.
  final String teeName;
  final List<TeamHandicapPreview> teams;
  /// What stands between the TD and a playable field — a pairs field that will
  /// not pair, named golfer by golfer. **Next waits on this**, the same way
  /// the fours flow waits on an unplaced golfer: balance is advice, a golfer
  /// with no partner is a broken tournament.
  final List<String> problems;
  /// Whether "let one team play three" is one of the ways out. Best ball only.
  final bool   threeBallAvailable;

  final ValueChanged<String> onHandicapMode;
  final ValueChanged<int?>   onOverridePct;

  const TeamHandicapStep({
    super.key,
    this.teamSize = 4,
    this.problems = const [],
    this.threeBallAvailable = false,
    required this.format,
    required this.handicapMode,
    required this.overridePct,
    required this.avgBallCount,
    required this.teeName,
    required this.teams,
    required this.onHandicapMode,
    required this.onOverridePct,
  });

  bool get _isGross    => handicapMode == 'gross';
  bool get _isPairs    => teamSize == 2;
  /// One team figure, or strokes that stay with the golfers.
  bool get _isOneBall  => playsOneBall(format);
  String get _formatName => kTeamFormatNames[format] ?? format;

  int get _shamblePct => shambleAllowancePct(avgBallCount);

  /// The percentage each golfer takes of their own, for the own-ball formats.
  int get _ownBallPct => format == 'best_ball' ? kBestBallPct : _shamblePct;

  /// The table this (size, format) states rather than asks.
  List<int> get _table => _isPairs
      ? (kPairsTables[format] ?? kPairsTables['scramble']!)
      : kScrambleTable;

  TeamAllowanceResult _allowanceFor(TeamHandicapPreview team) {
    final hcaps = team.members.map((m) => m.courseHandicap).toList();
    // A three-golfer FOURSOME is handicapped as four: the phantom sorts into the
    // order like anyone else and takes its percentage like anyone else, so the
    // team's figure comes from the ordinary table with no special row.
    //
    // **A pair never gets a phantom.** It would be an imaginary partner taking
    // half the shots in an alternate shot; an odd field is blocked instead.
    final phantom = (!_isPairs && hcaps.length == 3)
        ? phantomCourseHandicap(hcaps) : null;
    return teamAllowanceFor(
      teamSize       : teamSize,
      format         : format,
      courseHandicaps: hcaps,
      avgBallCount   : avgBallCount,
      overridePct    : overridePct,
      phantomHandicap: phantom,
    );
  }

  /// `4 – 7` — the spread across the field. Manual does not mean blind: a
  /// hand-built field is unbalanced by accident and normally discovered on the
  /// leaderboard.
  String get _balanceLabel {
    final figures = teams
        .where((t) => t.members.length >= teamSize)
        .map((t) => _allowanceFor(t).rounded)
        .toList()
      ..sort();
    if (figures.isEmpty) return '—';
    return figures.first == figures.last
        ? '${figures.first}'
        : '${figures.first} – ${figures.last}';
  }

  /// `lowest` / `2nd` / `3rd` / `highest`, sized to the table.
  String _rankLabel(int index) {
    if (index == 0) return 'lowest';
    if (index == _table.length - 1) return 'highest';
    return index == 1 ? '2nd' : '3rd';
  }

  String get _allowanceBlurb {
    if (!_isOneBall) {
      final tail = format == 'best_ball'
          ? ' — their own ball, and the better net counts.'
          : ' — it tracks the ball count, which averages '
            '${avgBallCount.toStringAsFixed(1)} a hole.';
      return '$_ownBallPct% of each golfer\u2019s own course handicap from '
             'the $teeName tees$tail';
    }
    if (_isPairs && _table.first == _table.last) {
      // Alternate shot: 50% low + 50% high IS 50% of the combined, and
      // combined is how a pair says it out loud.
      return '${_table.first}% of the combined course handicap from the '
             '$teeName tees. One ball means both mistakes count, so it is the '
             'most generous table by a distance — and correctly so.';
    }
    if (_isPairs) {
      return '${_table.first}% of the low handicap and ${_table.last}% of the '
             'high, from the $teeName tees.';
    }
    return 'The standard allowance for a four-golfer scramble, applied to course '
           'handicap from the $teeName tees.';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // A golfer with no partner is a broken tournament, and it is the one
        // thing Next waits on. The block names the golfer, because the fix is
        // about one golfer and the TD needs to know which one is standing there.
        if (problems.isNotEmpty) ...[
          for (final problem in problems) ...[
            TeamNote(problem, warn: true),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          SectionCard(
            title: 'Ways out',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pairs need an even field. Go back to Groups & Tees and:',
                     style: Halved.body(color: Halved.muted)),
                const SizedBox(height: 8),
                const _WayOut('Add a golfer',
                    'The usual answer — partner them yourself, or add anyone '
                    'from My Golfers.'),
                const _WayOut('Take them out',
                    'He sits out, or plays a casual round alongside the '
                    'tournament.'),
                _WayOut('Let one team play three',
                    threeBallAvailable
                        ? 'Allowed in best ball — edit the group sizes so one '
                          'team has three. Each golfer still gets '
                          '$kBestBallPct% of their own.'
                        : 'Best ball only. A third ball is another option to '
                          'count — in alternate shot and Chapman it cannot '
                          'work at all, and in a scramble it is a straight '
                          'advantage.',
                    muted: !threeBallAvailable),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const TeamNote(
            'No phantom partner. In fours the phantom is a handicap device for '
            'a team that still hits four balls. In pairs it would be an '
            'imaginary partner taking half the shots.',
          ),
          const SizedBox(height: 16),
        ],

        Text('Scoring', style: Halved.sectionHead()),
        const SizedBox(height: 12),
        TeamRadioCard(
          title: 'Net',
          body : _isOneBall
              ? "${_isPairs ? 'Pair' : 'Team'} handicap comes off the "
                "${_isPairs ? "pair's" : "team's"} gross."
              : "Each golfer plays their own ball off their own strokes.",
          selected: !_isGross,
          onTap   : () => onHandicapMode('net'),
        ),
        const SizedBox(height: 10),
        TeamRadioCard(
          title: 'Gross',
          body : 'No strokes. Straight $_formatName.',
          selected: _isGross,
          onTap   : () => onHandicapMode('gross'),
        ),

        if (!_isGross) ...[
          const SizedBox(height: 16),
          SectionCard(
            title: 'Allowance',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_formatName, style: Halved.body(weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(_allowanceBlurb, style: Halved.body(color: Halved.muted)),
                const SizedBox(height: 12),
                if (_isOneBall)
                  Row(
                    children: [
                      for (var i = 0; i < _table.length; i++)
                        Expanded(child: _PctChip(
                          pct : overridePct ?? _table[i],
                          rank: _rankLabel(i))),
                    ],
                  )
                else
                  _PctChip(pct: overridePct ?? _ownBallPct, rank: 'each golfer'),

                const SizedBox(height: 14),
                // A group's tradition beats the table — and the screen keeps
                // showing the worked result so the TD sees what they did.
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: overridePct != null,
                  onChanged: (on) => onOverridePct(
                      on ? (_isOneBall ? _table.first : _ownBallPct) : null),
                  activeThumbColor: Halved.pine,
                  title: Text('Use my own percentage instead',
                      style: Halved.body(weight: FontWeight.w600)),
                  subtitle: Text(
                    'One flat number applied to ${_isPairs ? 'both golfers'
                        : 'all four'}.',
                    style: Halved.body(color: Halved.muted)
                        .copyWith(fontSize: 13),
                  ),
                ),
                if (overridePct != null)
                  TeamStepper(
                    label: 'Flat allowance',
                    hint : 'Applied to every golfer on every team',
                    value: overridePct!,
                    min  : 5,
                    max  : 150,
                    step : 5,
                    format: (v) => '$v%',
                    onChanged: (v) => onOverridePct(v),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Text(_isPairs ? 'Worked on your own pairs'
                        : 'Worked on your own teams',
               style: Halved.sectionHead()),
          const SizedBox(height: 4),
          Text(
            'A generic illustration proves nothing. Every '
            '${_isPairs ? 'pair' : 'team'} is listed so an outlier is visible '
            'here rather than at the scoring table.',
            style: Halved.body(color: Halved.muted),
          ),
          const SizedBox(height: 10),
          // The balance strip. The argument is STRONGER in pairs: four
          // handicaps average out and two do not.
          SectionCard(
            title: 'Balance',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_balanceLabel,
                     style: Halved.sectionHead().copyWith(fontSize: 26)),
                const SizedBox(height: 4),
                Text(
                  _isPairs
                      ? 'Allowance per pair. Two handicaps do not average out '
                        'the way four do — the TD is not being told what to '
                        'do, they are being told what they just did.'
                      : 'Allowance per team, across the field.',
                  style: Halved.body(color: Halved.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final team in teams) ...[
            _WorkedTeam(
              team     : team,
              allowance: _allowanceFor(team),
              scramble : _isOneBall,
              teamSize : teamSize,
            ),
            const SizedBox(height: 10),
          ],

          const SizedBox(height: 4),
          const TeamNote(
            'Rounded once, on the total — rounding each contribution first '
            'costs a stroke. Half rounds up.',
          ),
          const SizedBox(height: 8),
          const TeamNote(
            'Whole strokes mean ties are normal. Tied teams combine the places '
            'they occupy and split the money — no countback.',
          ),
        ],
      ],
    );
  }
}

/// One of the three ways out of an odd field, with the reason on it. Nothing
/// is disabled without saying why — the house rule inherited from the Cup.
class _WayOut extends StatelessWidget {
  final String title;
  final String body;
  final bool   muted;

  const _WayOut(this.title, this.body, {this.muted = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: Halved.body(
                    weight: FontWeight.w700,
                    color: muted ? Halved.muted : Halved.deepPine)),
                if (muted) ...[
                  const SizedBox(width: 6),
                  Text('N/A', style: Halved.label()),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(body, style: Halved.body(color: Halved.muted)
                .copyWith(fontSize: 13)),
          ],
        ),
      );
}

class _PctChip extends StatelessWidget {
  final int pct;
  final String rank;
  const _PctChip({required this.pct, required this.rank});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: Halved.surface,
          borderRadius: BorderRadius.circular(Halved.rChip),
          border: Border.all(color: Halved.cardBorder),
        ),
        child: Column(
          children: [
            Text('$pct%', style: Halved.body(weight: FontWeight.w700)),
            Text(rank, style: Halved.label().copyWith(fontSize: 10)),
          ],
        ),
      );
}

/// The card that shows a TD their own four golfers, their four percentages and the
/// sum — the only numbers they will check.
class _WorkedTeam extends StatelessWidget {
  final TeamHandicapPreview team;
  final TeamAllowanceResult allowance;
  /// One team figure (the one-ball formats), rather than strokes that stay
  /// with the golfers.
  final bool scramble;
  final int  teamSize;

  const _WorkedTeam({
    required this.team, required this.allowance, required this.scramble,
    this.teamSize = 4,
  });

  @override
  Widget build(BuildContext context) {
    // Members sorted low to high, matching the allowance lines position for
    // position — the phantom included, wherever it lands.
    final sorted = [...team.members]
      ..sort((a, b) => a.courseHandicap.compareTo(b.courseHandicap));
    var realIndex = 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(Halved.rCard),
        border: Border.all(color: Halved.cardBorder, width: 1.5),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(team.name,
                    style: Halved.body(weight: FontWeight.w700)),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${allowance.rounded}',
                      style: Halved.sectionHead().copyWith(fontSize: 26)),
                  Text('RAW ${allowance.raw}', style: Halved.label()),
                ],
              ),
            ],
          ),
          const Divider(height: 18),
          for (final line in allowance.lines)
            Builder(builder: (_) {
              final isPhantom = line.isPhantom;
              final member = isPhantom || realIndex >= sorted.length
                  ? null
                  : sorted[realIndex];
              if (!isPhantom) realIndex++;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text('${line.pct}',
                          style: Halved.label(color: Halved.pine)),
                    ),
                    Expanded(
                      child: Text(
                        isPhantom ? 'Phantom 4th' : (member?.name ?? ''),
                        style: Halved.body(
                          weight: FontWeight.w600,
                          color: isPhantom ? Halved.muted : Halved.deepPine,
                        ).copyWith(
                          fontStyle: isPhantom
                              ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 34,
                      child: Text('${line.courseHandicap}',
                          textAlign: TextAlign.right,
                          style: Halved.body(color: Halved.muted)),
                    ),
                    SizedBox(
                      width: 54,
                      child: Text(line.strokes,
                          textAlign: TextAlign.right,
                          style: Halved.body(weight: FontWeight.w600)),
                    ),
                  ],
                ),
              );
            }),
          if (teamSize == 4 && team.members.length == 3) ...[
            const SizedBox(height: 8),
            const TeamNote(
              'Playing three — the phantom 4th is the average of the three, so '
              'the ordinary table applies.',
            ),
          ],
          if (teamSize == 2 && team.members.length == 3) ...[
            const SizedBox(height: 8),
            const TeamNote(
              'Playing three — best ball counts the best of three balls '
              'instead of two. No phantom.',
            ),
          ],
          if (!scramble) ...[
            const SizedBox(height: 8),
            const TeamNote(
              'Handicaps stay per golfer here — this total is for comparison, '
              'not a stroke anybody gets.',
            ),
          ],
        ],
      ),
    );
  }
}
