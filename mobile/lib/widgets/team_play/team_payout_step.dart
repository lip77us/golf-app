/// widgets/team_play/team_payout_step.dart
/// ---------------------------------------
/// Wizard step 7 — entry and payout
/// (docs/design-review/handoff-team-play/SPEC.md §9).
///
/// Three numbers, and they are the only ones anybody argues about after the
/// round: **what it costs, how many teams cash, and how the pot divides.**
/// They belong on one screen because changing any of them changes the other
/// two's meaning.
///
/// **Worked, not described.** Every control shows its consequence in dollars
/// as it moves — a TD setting 50/30/20 is not choosing percentages, he is
/// choosing what third place gets.
library;

import 'package:flutter/material.dart';

import '../../theme/halved_brand.dart';
import '../section_card.dart';
import 'team_play_bits.dart';

class TeamPayoutStep extends StatelessWidget {
  final int    entryFee;
  final int    placesPaid;
  final List<int> splitPcts;
  final int    golfers;
  final int    teamCount;
  /// True when a team plays three — per-man figures assume four, and the
  /// screen says so rather than quietly being wrong for one team.
  final bool   hasShortTeam;

  final ValueChanged<int> onFee;
  final ValueChanged<int> onPlaces;
  final ValueChanged<List<int>> onSplit;

  const TeamPayoutStep({
    super.key,
    required this.entryFee,
    required this.placesPaid,
    required this.splitPcts,
    required this.golfers,
    required this.teamCount,
    required this.hasShortTeam,
    required this.onFee,
    required this.onPlaces,
    required this.onSplit,
  });

  double get pool  => entryFee * golfers.toDouble();
  int    get total => splitPcts.fold(0, (a, b) => a + b);
  bool   get balances => total == 100;

  /// Presets first, custom underneath. Most TDs want 50/30/20 and should be
  /// able to tap once.
  static const Map<String, List<int>> _presets = {
    'Winner takes all': [100],
    '60 / 40'         : [60, 40],
    '50 / 30 / 20'    : [50, 30, 20],
  };

  static String _money(double v) => '\$${v.toStringAsFixed(2)}';
  static const _ordinals = ['1st', '2nd', '3rd', '4th'];

  /// Small counts read as words in a sentence — "Two places is two prizes",
  /// not "2 places is 2 prizes". Places cap at four, so the list ends there.
  /// Only the one that opens the sentence takes a capital.
  static String _words(int n, {bool capital = false}) {
    const words = ['no', 'one', 'two', 'three', 'four'];
    final w = n < words.length ? words[n] : '$n';
    return capital ? '${w[0].toUpperCase()}${w.substring(1)}' : w;
  }

  @override
  Widget build(BuildContext context) {
    // Six teams paying five places is a raffle — the cap is real, the advice
    // about half the field is not.
    final maxPlaces = teamCount == 0 ? 4 : teamCount.clamp(1, 4);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SectionCard(
          title: 'Entry per golfer',
          child: Column(
            children: [
              Text('Flat, collected at signup. One pool — the team '
                   'championship.',
                   style: Halved.body(color: Halved.muted)),
              const SizedBox(height: 10),
              TeamStepper(
                label: 'Entry',
                hint : 'Stepped in \$5 — nobody charges \$23',
                value: entryFee,
                min  : 0,
                max  : 500,
                step : 5,
                format: (v) => '\$$v',
                onChanged: onFee,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TeamStat(value: '$golfers',   label: 'GOLFERS'),
                  TeamStat(value: '$teamCount', label: 'TEAMS'),
                  TeamStat(value: _money(pool), label: 'IN THE POOL',
                           colour: Halved.pine),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        SectionCard(
          title: 'Places paid',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (var n = 1; n <= 4; n++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _PlaceChip(
                          n       : n,
                          selected: placesPaid == n,
                          enabled : n <= maxPlaces,
                          onTap   : () => onPlaces(n),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text('$placesPaid of $teamCount teams',
                   style: Halved.body(weight: FontWeight.w600)),
              // Advice on the screen, not a rule — winner-takes-all is a
              // legitimate choice and the preset is there.
              Text(
                teamCount > 0 && placesPaid * 2 >= teamCount
                    ? 'Half the field cashing is what keeps a one-day scramble '
                      'worth entering.'
                    : 'Fewer places, bigger prizes. Winner-takes-all is a '
                      'legitimate choice.',
                style: Halved.body(color: Halved.muted).copyWith(fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        SectionCard(
          title: 'Split',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tap a preset, or set your own below.',
                   style: Halved.body(color: Halved.muted)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  for (final entry in _presets.entries)
                    _PresetChip(
                      label   : entry.key,
                      selected: _sameList(splitPcts, entry.value),
                      onTap   : () {
                        onSplit(List<int>.from(entry.value));
                        onPlaces(entry.value.length);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),

              for (var i = 0; i < placesPaid; i++) ...[
                _PlaceRow(
                  label   : _ordinals[i],
                  pct     : i < splitPcts.length ? splitPcts[i] : 0,
                  pool    : pool,
                  onChanged: (v) {
                    final next = List<int>.filled(placesPaid, 0);
                    for (var j = 0; j < placesPaid; j++) {
                      next[j] = j < splitPcts.length ? splitPcts[j] : 0;
                    }
                    next[i] = v;
                    onSplit(next);
                  },
                ),
                const Divider(height: 14),
              ],

              Row(
                children: [
                  Expanded(
                    child: Text('Total',
                        style: Halved.body(weight: FontWeight.w700)),
                  ),
                  Text('$total%',
                      style: Halved.body(weight: FontWeight.w700).copyWith(
                          color: balances ? Halved.pine : Halved.warning)),
                  const SizedBox(width: 14),
                  Text(_money(pool * total / 100),
                      style: Halved.body(weight: FontWeight.w700)),
                ],
              ),

              if (!balances) ...[
                const SizedBox(height: 10),
                // 95% leaves money in the TD's pocket with no line explaining
                // it, so the shortfall is named in dollars.
                TeamNote(
                  total < 100
                      ? '${100 - total}% unassigned — '
                        '${_money(pool * (100 - total) / 100)}. The split has '
                        'to reach 100 or the pool will not balance at '
                        'settlement.'
                      : '${total - 100}% over — '
                        '${_money(pool * (total - 100) / 100)} more than the '
                        'pool holds.',
                  warn: true,
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 14),
        if (_lastPlaceBelowEntry()) ...[
          // Allowed, and worth knowing: a team can finish in the money and
          // still be down. Nothing here is disqualified by cashing, unlike the
          // Individual day bet, so this is a flag rather than a block.
          TeamNote(
            '${_ordinals[placesPaid - 1]} place pays less than entry — '
            '${_money(_perMan(splitPcts[placesPaid - 1]))} against '
            '${_money(entryFee.toDouble())} a golfer.',
          ),
          const SizedBox(height: 10),
        ],
        if (hasShortTeam) ...[
          const TeamNote(
            'Per-golfer figures assume four. A team playing three divides its '
            'share three ways and pays more each — the phantom 4th cannot be '
            'paid.',
          ),
          const SizedBox(height: 10),
        ],
        // Cheaper to read here than to discover at the scoring table — and it
        // has to count what the TD actually set, not the drawn example's
        // three. Winner-takes-all ties too.
        TeamNote(
          '${_words(placesPaid, capital: true)} '
          'place${placesPaid == 1 ? '' : 's'} is ${_words(placesPaid)} '
          'prize${placesPaid == 1 ? '' : 's'}, not ${_words(placesPaid)} '
          'team${placesPaid == 1 ? '' : 's'}. Whole-stroke handicaps tie '
          'often, and two teams tied for the last paying place split it '
          'between them.',
          warn: true,
        ),
      ],
    );
  }

  double _perMan(int pct) => pool * pct / 100 / 4;

  bool _lastPlaceBelowEntry() =>
      entryFee > 0 &&
      placesPaid > 0 &&
      placesPaid <= splitPcts.length &&
      _perMan(splitPcts[placesPaid - 1]) < entryFee;

  static bool _sameList(List<int> a, List<int> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);
}

/// One place: the percentage the TD moves, and the two figures that tell him
/// what he just did — the team's prize and the per-man share.
class _PlaceRow extends StatelessWidget {
  final String label;
  final int    pct;
  final double pool;
  final ValueChanged<int> onChanged;

  const _PlaceRow({
    required this.label, required this.pct,
    required this.pool, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final amount = pool * pct / 100;
    return Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(label, style: Halved.body(weight: FontWeight.w700)),
        ),
        Expanded(
          child: TeamStepper(
            label: '',
            hint : '',
            value: pct,
            min  : 0,
            max  : 100,
            step : 5,
            format: (v) => '$v%',
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('\$${amount.toStringAsFixed(2)}',
                 style: Halved.body(weight: FontWeight.w700)),
            // $287.50 to a team means nothing until it is divided. A man
            // decides by whether $25 is worth maybe winning $72.
            Text('\$${(amount / 4).toStringAsFixed(2)} a golfer',
                 style: Halved.label()),
          ],
        ),
      ],
    );
  }
}

class _PlaceChip extends StatelessWidget {
  final int  n;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _PlaceChip({
    required this.n, required this.selected,
    required this.enabled, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(Halved.rChip),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? Halved.pine
                            : (enabled ? Halved.card : Halved.disabledFill),
            borderRadius: BorderRadius.circular(Halved.rChip),
            border: Border.all(
                color: selected ? Halved.pine : Halved.cardBorder, width: 1.5),
          ),
          child: Center(
            child: Text('$n',
                style: Halved.body(weight: FontWeight.w700).copyWith(
                  color: selected ? Halved.cream
                       : (enabled ? Halved.deepPine : Halved.disabledText),
                )),
          ),
        ),
      );
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool   selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Halved.rPill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? Halved.pine : Halved.card,
            borderRadius: BorderRadius.circular(Halved.rPill),
            border: Border.all(
                color: selected ? Halved.pine : Halved.cardBorder, width: 1.5),
          ),
          child: Text(label,
              style: Halved.body(weight: FontWeight.w600).copyWith(
                  color: selected ? Halved.cream : Halved.deepPine,
                  fontSize: 13)),
        ),
      );
}
