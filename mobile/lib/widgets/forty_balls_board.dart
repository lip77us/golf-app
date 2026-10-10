/// widgets/forty_balls_board.dart
/// -----------------------------
/// The 40 Balls board — the Irish Rumble shape, plus the one thing that is new:
/// **every row carries its budget.**
///
/// A group at −5 with slack 12 is in a different position from a group at −5
/// with slack 0, which has to count every bad score to the finish. So the meter
/// and `34 of 40 · slack 6` sit under the names, for every group and not only
/// the reader's — that comparison is the point.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import '../utils/stroke_play_standing.dart';
import 'hole_grid_scorecard.dart';

class FortyBallsBoard extends StatefulWidget {
  final Map<String, dynamic> data;
  /// Names by player id, for the card's rows. Empty simply leaves them blank.
  final Map<int, String> names;
  const FortyBallsBoard({super.key, required this.data, this.names = const {}});

  @override
  State<FortyBallsBoard> createState() => _FortyBallsBoardState();
}

class _FortyBallsBoardState extends State<FortyBallsBoard> {
  late FortyBallsSummary _s = FortyBallsSummary.fromJson(widget.data);
  int? _openId;

  @override
  void didUpdateWidget(covariant FortyBallsBoard old) {
    super.didUpdateWidget(old);
    _s = FortyBallsSummary.fromJson(widget.data);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_s.results.isEmpty) {
      return const Center(child: Text('No scores yet.'));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(children: [
          _chip(context, 'Groups', '${_s.nGroups}'),
          const SizedBox(width: 12),
          _chip(context, 'Entry', '\$${_s.entryFee.toStringAsFixed(0)}'),
          const Spacer(),
          Text('Pool \$${_s.pool.toStringAsFixed(0)}',
              style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 10),
        for (final g in _s.results)
          _GroupRow(
            group : g,
            isOpen: g.foursomeId == _openId,
            names : widget.names,
            onTap : () => setState(() =>
                _openId = _openId == g.foursomeId ? null : g.foursomeId),
          ),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ', style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      Text(value, style: theme.textTheme.bodySmall
          ?.copyWith(fontWeight: FontWeight.bold)),
    ]);
  }
}

class _GroupRow extends StatelessWidget {
  final FortyBallsGroup group;
  final bool isOpen;
  final Map<int, String> names;
  final VoidCallback onTap;
  const _GroupRow({
    required this.group, required this.isOpen, required this.names,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thru = _thru(group);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isOpen ? Halved.pine : theme.colorScheme.outlineVariant,
            width: isOpen ? 1.4 : 1),
      ),
      child: Column(children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              Row(children: [
                SizedBox(
                  width: 26,
                  child: Text(
                      group.rank == null
                          ? '–'
                          : (group.tied ? 'T${group.rank}' : '${group.rank}'),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  // **Thru sits beside the group's name**, not in the budget
                  // line below it. `34 of 40 · slack 6` answers what the
                  // group has left to spend; this answers how far round they
                  // are, which is what a reader scanning the board compares
                  // one row against another with — a group at −5 thru 9 and
                  // one at −5 thru 17 are not in the same position.
                  //
                  // It is NOT `18 - holesLeft`: a hole can be fully scored
                  // and still carry no committed count, so the budget's
                  // "pending" and a golfer's "thru" are different questions.
                  // The server answers this one, along the group's own play
                  // order, so a shotgun round reads correctly.
                  child: Row(children: [
                    Flexible(
                      child: Text('Group ${group.groupNumber}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    if (thru != null) ...[
                      const SizedBox(width: 8),
                      Text(thru,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ]),
                ),
                if (group.dq) ...[
                  _Tag('OUT'),
                  const SizedBox(width: 8),
                ],
                SizedBox(
                  width: 48,
                  child: Text(_total(group),
                      textAlign: TextAlign.end,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    group.payout == 0
                        ? ''
                        : '\$${group.payout.toStringAsFixed(0)}',
                    textAlign: TextAlign.end,
                    // Projected while the round runs — italic and muted, as on
                    // every board.
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontStyle: group.isFinished
                          ? FontStyle.normal : FontStyle.italic,
                      color: group.isFinished
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              _BudgetLine(group: group),
              if (group.factor != null) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_raw(group)} on ${group.budget} balls × ${group.factor}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ]),
          ),
        ),
        if (isOpen) _card(context),
      ]),
    );
  }

  /// `Thru 12`, `F` when every hole in play is in, and nothing at all before
  /// the group starts — an empty slot rather than `Thru 0`.
  ///
  /// **`F` is measured against the holes IN PLAY, not against 18**, because
  /// this board has the list and a nine-hole round would otherwise never
  /// finish. The shared group board still compares against 18; that is
  /// older and not this change's to fix.
  static String? _thru(FortyBallsGroup g) {
    final t = g.thru;
    if (t == null || t == 0) return null;
    final n = g.holesInPlay.length;
    return (n > 0 && t >= n) ? 'F' : 'Thru $t';
  }

  /// The ranking figure — one decimal only when the 4/3 factor made it
  /// fractional. `−5.3`, but `−4` stays `−4`.
  static String _total(FortyBallsGroup g) {
    if (g.dq) return '–';
    final v = g.rankingTotal ?? 0;
    if (v == 0) return 'E';
    final whole = v == v.roundToDouble();
    final t = whole ? v.abs().toStringAsFixed(0) : v.abs().toStringAsFixed(1);
    return v > 0 ? '+$t' : '−$t';
  }

  /// **`toParLabel`, not a local format.** The house minus is U+2212 and this
  /// widget was using it on the line above and an ASCII hyphen here, two lines
  /// apart — which a test caught before a golfer did.
  static String _raw(FortyBallsGroup g) => toParLabel(g.total);

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    // **The standard card, whole.** Gross with stroke dots, a par band and an
    // index band, the label column pinned — and the Balls and Group rows
    // INSIDE it rather than as a second scroller underneath, which is what
    // left the counts a column off the scores they describe.
    final holes = [
      for (final h in group.holes)
        {
          'hole'        : h.hole,
          'par'         : h.par,
          'stroke_index': h.strokeIndex,
          'scores'      : [
            for (final id in h.gross.keys)
              {
                'player_id': id,
                'gross'    : h.gross[id],
                'strokes'  : h.strokes[id] ?? 0,
                // The ball the group spent — this game's version of winning
                // the hole, and it wears the same green.
                'counted'  : h.countedIds.contains(id),
              },
          ],
        },
    ];
    final participants = [
      for (final p in _roster())
        {'player_id': p['player_id'], 'short_name': p['short_name'] ?? '',
         'name': p['name'] ?? ''},
    ];
    final byHole = {for (final h in group.holes) h.hole: h};

    String? ballsText(int hole) {
      final h = byHole[hole];
      if (h == null) return null;
      return h.count == null ? '·' : '${h.count}';
    }

    Color ballsColour(int hole) {
      final h = byHole[hole];
      // Zero is grey; an APP-SET count is amber, because the app set it and
      // the group did not.
      if (h == null) return theme.colorScheme.onSurfaceVariant;
      if (h.appSet) return Halved.caution;
      return h.count == 0 || h.count == null
          ? theme.colorScheme.onSurfaceVariant
          : theme.colorScheme.onSurface;
    }

    String? groupText(int hole) {
      final r = byHole[hole]?.result;
      return r == null ? '·' : toParLabel(r);
    }

    Color groupColour(int hole) {
      final r = byHole[hole]?.result;
      if (r == null || r == 0) return theme.colorScheme.onSurfaceVariant;
      return r < 0 ? Halved.pine : Halved.caution;
    }

    /// A nine's figure is an em dash until every hole in it is counted — the
    /// same rule the gross subtotals use, and for the same reason: a partial
    /// sum of a budget reads as a smaller spend than it is.
    int? sumOver(List<int> holes, int? Function(FortyBallsHole) of) {
      var t = 0;
      for (final h in holes) {
        final v = byHole[h] == null ? null : of(byHole[h]!);
        if (v == null) return null;
        t += v;
      }
      return t;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: HoleGridScorecard(
        holes       : holes,
        participants: participants,
        holesInPlay : group.holesInPlay,
        legend      : 'green = counted',
        footerRows  : [
          HoleGridFooterRow(
            label  : 'Balls',
            text   : ballsText,
            colour : ballsColour,
            summary: (hs) {
              final t = sumOver(hs, (h) => h.count);
              return t == null ? '—' : '$t';
            },
          ),
          HoleGridFooterRow(
            label  : 'Group',
            text   : groupText,
            colour : groupColour,
            summary: (hs) {
              final t = sumOver(hs, (h) => h.result);
              return t == null ? '—' : toParLabel(t);
            },
          ),
        ],
      ),
    );
  }

  /// The group's golfers. The card names them itself; [names] is the fallback
  /// for a caller that has a roster and an older payload that does not.
  List<Map<String, dynamic>> _roster() {
    if (group.players.isNotEmpty) return group.players;
    final seen = <int>{};
    for (final h in group.holes) {
      seen.addAll(h.gross.keys);
      seen.addAll(h.scores.keys);
    }
    final list = seen.toList()..sort();
    return [
      for (final id in list)
        {'player_id': id, 'short_name': names[id] ?? ''},
    ];
  }
}

/// The meter and `34 of 40 · slack 6`.
class _BudgetLine extends StatelessWidget {
  final FortyBallsGroup group;
  const _BudgetLine({required this.group});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frac = group.budget == 0 ? 0.0 : group.spent / group.budget;
    final noSlack = group.slack == 0 && group.left > 0;
    final spentOut = group.left == 0;

    String note;
    Color colour = theme.colorScheme.onSurfaceVariant;
    if (group.dq) {
      note = 'out — ${group.left} owed, room for ${group.capacity}';
      colour = theme.colorScheme.error;
    } else if (spentOut && group.holesLeft > 0) {
      note = 'all used · none count';
      colour = Halved.caution;
    } else if (spentOut) {
      note = '';                       // finished: the count says it all
    } else if (noSlack) {
      note = 'slack 0 · all count';
      colour = Halved.caution;
    } else {
      note = 'slack ${group.slack}';
    }

    return Row(children: [
      SizedBox(
        width: 64,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: frac.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(
                group.dq ? theme.colorScheme.error : Halved.pine),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text('${group.spent} of ${group.budget}',
          style: theme.textTheme.labelSmall
              ?.copyWith(fontWeight: FontWeight.w600)),
      if (note.isNotEmpty) ...[
        Text('  ·  ', style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Flexible(
          child: Text(note,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: colour, fontWeight: FontWeight.w600)),
        ),
      ],
    ]);
  }
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9, fontWeight: FontWeight.bold,
              color: theme.colorScheme.onErrorContainer)),
    );
  }
}
