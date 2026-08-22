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
/// chosen format uses**, shows it applied to his OWN teams, and lets him
/// override the whole thing with one number if his group has its own
/// tradition. Presenting a table as an open question invites a guess.
library;

import 'package:flutter/material.dart';

import '../../theme/halved_brand.dart';
import '../../utils/team_allowance.dart';
import '../section_card.dart';
import 'team_play_bits.dart';

/// One team as this screen needs it — enough to work the allowance and name
/// the men it was worked on.
class TeamHandicapPreview {
  /// `Group 1` … `Group 6`. Teams name themselves from the round hub once
  /// they exist; the wizard has no business inventing six names for men who
  /// have not turned up yet.
  final String name;
  /// Real men only, in any order — the screen sorts them, because the
  /// percentage is positional and a manual order would be a lie.
  final List<({int playerId, String name, int courseHandicap})> members;

  const TeamHandicapPreview({
    required this.name, required this.members,
  });
}

class TeamHandicapStep extends StatelessWidget {
  final String format;               // scramble | shamble
  final String handicapMode;         // net | gross
  final int?   overridePct;
  final double avgBallCount;
  /// The tee the course handicaps were computed from, named so nobody applies
  /// 25% to the wrong number.
  final String teeName;
  final List<TeamHandicapPreview> teams;

  final ValueChanged<String> onHandicapMode;
  final ValueChanged<int?>   onOverridePct;

  const TeamHandicapStep({
    super.key,
    required this.format,
    required this.handicapMode,
    required this.overridePct,
    required this.avgBallCount,
    required this.teeName,
    required this.teams,
    required this.onHandicapMode,
    required this.onOverridePct,
  });

  bool get _isScramble => format == 'scramble';
  bool get _isGross    => handicapMode == 'gross';

  int get _shamblePct => shambleAllowancePct(avgBallCount);

  TeamAllowanceResult _allowanceFor(TeamHandicapPreview team) {
    final hcaps = team.members.map((m) => m.courseHandicap).toList();
    // A three-man team is handicapped as FOUR: the phantom sorts into the
    // order like anyone else and takes its percentage like anyone else, so the
    // team's figure comes from the ordinary table with no special row.
    final phantom = hcaps.length == 3 ? phantomCourseHandicap(hcaps) : null;
    return _isScramble
        ? scrambleAllowance(hcaps,
            overridePct: overridePct, phantomHandicap: phantom)
        : shambleAllowance(hcaps,
            avgBallCount: avgBallCount, overridePct: overridePct,
            phantomHandicap: phantom);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('Scoring', style: Halved.sectionHead()),
        const SizedBox(height: 12),
        TeamRadioCard(
          title: 'Net',
          body : _isScramble
              ? "Team handicap comes off the team's gross."
              : "Each golfer plays his own ball off his own strokes.",
          selected: !_isGross,
          onTap   : () => onHandicapMode('net'),
        ),
        const SizedBox(height: 10),
        TeamRadioCard(
          title: 'Gross',
          body : 'No strokes. Straight ${_isScramble ? 'scramble' : 'shamble'}.',
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
                Text(_isScramble ? 'Scramble' : 'Shamble',
                     style: Halved.body(weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  _isScramble
                      ? 'The standard allowance for a four-man scramble, '
                        'applied to course handicap from the $teeName tees.'
                      : '$_shamblePct% of each golfer’s own course '
                        'handicap from the $teeName tees — it tracks the ball '
                        'count, which averages '
                        '${avgBallCount.toStringAsFixed(1)} a hole.',
                  style: Halved.body(color: Halved.muted),
                ),
                const SizedBox(height: 12),
                if (_isScramble)
                  Row(
                    children: [
                      for (final (pct, rank) in const [
                        (25, 'lowest'), (20, '2nd'), (15, '3rd'), (10, 'highest')
                      ])
                        Expanded(child: _PctChip(
                          pct: overridePct ?? pct, rank: rank)),
                    ],
                  )
                else
                  _PctChip(pct: overridePct ?? _shamblePct, rank: 'each golfer'),

                const SizedBox(height: 14),
                // A group's tradition beats the table — and the screen keeps
                // showing the worked result so the TD sees what he did.
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: overridePct != null,
                  onChanged: (on) => onOverridePct(
                      on ? (_isScramble ? 20 : _shamblePct) : null),
                  activeThumbColor: Halved.pine,
                  title: Text('Use my own percentage instead',
                      style: Halved.body(weight: FontWeight.w600)),
                  subtitle: Text(
                    'One flat number applied to all four.',
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
          Text('Worked on your own teams', style: Halved.sectionHead()),
          const SizedBox(height: 4),
          Text(
            'A generic illustration proves nothing. Every team is listed so an '
            'outlier is visible here rather than at the scoring table.',
            style: Halved.body(color: Halved.muted),
          ),
          const SizedBox(height: 12),
          for (final team in teams) ...[
            _WorkedTeam(
              team     : team,
              allowance: _allowanceFor(team),
              scramble : _isScramble,
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

/// The card that shows a TD his own four men, their four percentages and the
/// sum — the only numbers he will check.
class _WorkedTeam extends StatelessWidget {
  final TeamHandicapPreview team;
  final TeamAllowanceResult allowance;
  final bool scramble;

  const _WorkedTeam({
    required this.team, required this.allowance, required this.scramble,
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
          if (team.members.length == 3) ...[
            const SizedBox(height: 8),
            const TeamNote(
              'Playing three — the phantom 4th is the average of the three, so '
              'the ordinary table applies.',
            ),
          ],
          if (!scramble) ...[
            const SizedBox(height: 8),
            const TeamNote(
              'A shamble keeps handicaps per golfer — this total is for '
              'comparison, not a stroke anybody plays off.',
            ),
          ],
        ],
      ),
    );
  }
}
