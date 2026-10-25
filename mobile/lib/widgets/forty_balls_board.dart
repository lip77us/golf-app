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

/// Column widths, shared by the pine header and every row beneath it.
///
/// One place because a header that disagrees with its rows is worse than no
/// header at all — it labels the wrong column, confidently.
const double _kRankW  = 26;
const double _kThruW  = 40;
const double _kTotW   = 52;
const double _kPrizeW = 56;

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
        _metaLine(context),
        const SizedBox(height: 10),
        // The rows as one TABLE rather than a stack of cards, which is what
        // lets a pine header label them. The open row is a background tint
        // now instead of a border, because a border inside a continuous
        // table reads as a seam.
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Column(children: [
            _tableHeader(context),
            for (final g in _s.results)
              _GroupRow(
                group : g,
                isOpen: g.foursomeId == _openId,
                names : widget.names,
                onTap : () => setState(() =>
                    _openId = _openId == g.foursomeId ? null : g.foursomeId),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        _ledger(context),
      ],
    );
  }

  /// `Net · best balls   40 a group   Pool $150`.
  Widget _metaLine(BuildContext context) {
    final theme = Theme.of(context);
    final mode = _s.handicapMode == 'gross'
        ? 'Gross'
        : 'Net${_s.netPercent == 100 ? '' : ' ${_s.netPercent}%'}';
    final budget = _s.results.isEmpty ? 40 : _s.results.first.budget;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Row(children: [
      Text('$mode · best balls', style: muted),
      Text('   ·   ', style: muted),
      Text('$budget a group', style: muted),
      const Spacer(),
      Text('Pool \$${_s.pool.toStringAsFixed(0)}',
          style: theme.textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.bold)),
    ]);
  }

  Widget _tableHeader(BuildContext context) => Container(
        color: Halved.pine,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: DefaultTextStyle(
          style: const TextStyle(
              color: Halved.cream, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 0.7),
          child: Row(children: [
            const SizedBox(width: _kRankW, child: Text('#')),
            const Expanded(child: Text('GROUP')),
            const SizedBox(width: _kThruW,
                child: Text('THRU', textAlign: TextAlign.end)),
            const SizedBox(width: _kTotW,
                child: Text('TOT', textAlign: TextAlign.end)),
            SizedBox(width: _kPrizeW,
                child: Text(_s.pool > 0 ? 'PRIZE' : '',
                    textAlign: TextAlign.end)),
          ]),
        ),
      );

  /// What the pot pays, and to whom.
  ///
  /// **`Projected` while any group is still out**, because a prize column on
  /// a board that can still move is a promise the round has not made. The
  /// same reason the row's figure is italic until the group finishes.
  Widget _ledger(BuildContext context) {
    final theme = Theme.of(context);
    if (_s.pool <= 0) return const SizedBox.shrink();
    final done = _s.results.every((g) => g.isFinished || g.dq);
    final paid = _s.results.where((g) => g.payout > 0).toList();

    Widget band(String text) => Container(
          width: double.infinity,
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Text(text,
              style: const TextStyle(
                  color: Halved.cream, fontSize: 11,
                  fontWeight: FontWeight.w700, letterSpacing: 0.6)),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Column(children: [
        band(done ? 'Pays the group' : 'Projected · pays the group'),
        Container(
          color: theme.colorScheme.surface,
          child: Column(children: [
            if (paid.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Nothing settled yet.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              )
            else
              for (final g in paid)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        'Group ${g.groupNumber} · ${g.splitWays} ways',
                        style: theme.textTheme.bodySmall),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Halved.brightMint.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text('\$${g.payout.toStringAsFixed(0)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold)),
                    ),
                  ]),
                ),
          ]),
        ),
        band('\$${_s.pool.toStringAsFixed(0)} pool · '
             '\$${_s.entryFee.toStringAsFixed(0)} a golfer'),
      ]),
    );
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
      decoration: BoxDecoration(
        // Open is a TINT, not a border: inside a continuous table a border
        // reads as a seam between two tables rather than as one row lifting.
        color: isOpen
            ? Halved.pine.withValues(alpha: 0.07)
            : theme.colorScheme.surface,
        border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              Row(children: [
                SizedBox(
                  width: _kRankW,
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
                  child: Text('Group ${group.groupNumber}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                // **Its own column now, under a THRU header** — still to the
                // right of the name and left of the total, which is the slot
                // that reads as belonging to the group rather than the money.
                // The header carries the word, so the cell is the bare
                // figure: `9`, not `Thru 9`.
                SizedBox(
                  width: _kThruW,
                  child: Text(thru ?? '',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                SizedBox(
                  width: _kTotW,
                  child: group.dq
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: _Tag('OUT'))
                      : Text(_total(group),
                          textAlign: TextAlign.end,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                SizedBox(
                  width: _kPrizeW,
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

  /// `12`, `F` when every hole in play is in, and nothing at all before the
  /// group starts — an empty slot rather than a `0`.
  ///
  /// **`F` is measured against the holes IN PLAY, not against 18**, because
  /// this board has the list and a nine-hole round would otherwise never
  /// finish. The shared group board still compares against 18; that is
  /// older and not this change's to fix.
  static String? _thru(FortyBallsGroup g) {
    final t = g.thru;
    if (t == null || t == 0) return null;
    final n = g.holesInPlay.length;
    // The bare figure — the pine header says THRU once, so the cell does not
    // repeat the word down every row.
    return (n > 0 && t >= n) ? 'F' : '$t';
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

    // **Full width, with a tick where an even pace would be** (reworked
    // packet, 24 Oct). The old 64px meter said how much of the budget was
    // gone; it could not say whether that was early. The gap between the
    // fill and the tick is the whole question — a group at −5 having spent
    // 34 of 40 by the 9th is in trouble the figure alone does not show.
    //
    // Ahead of pace takes the amber, because spending early is how a group
    // runs out of choices. Behind is simply room to spend.
    final holes = group.holesInPlay.isEmpty ? 18 : group.holesInPlay.length;
    final thru  = group.thru ?? 0;
    // No pace before a group starts or once it is done — there is nothing to
    // be off at either end.
    final double? evenPace = (thru <= 0 || thru >= holes || group.budget <= 0)
        ? null
        : group.budget * thru / holes;
    final int? vsPace =
        evenPace == null ? null : (group.spent - evenPace).round();
    final ahead = vsPace != null && vsPace > 0 && !group.dq;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        return SizedBox(
          height: 6,
          child: Stack(children: [
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            FractionallySizedBox(
              widthFactor: frac.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: group.dq
                      ? theme.colorScheme.error
                      : (ahead ? Halved.caution : Halved.pine),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            if (evenPace != null)
              Positioned(
                left: (w * (evenPace / group.budget)).clamp(0.0, w - 3),
                // **The tick contrasts against whatever it is standing on**,
                // which changes with the group: once the fill passes the tick
                // the group is ahead of pace, and a dark mark on the amber
                // fill was too subtle to find. Light over the fill, dark over
                // the empty track — the one mark that has to be legible on
                // both, because its whole job is to be compared with the
                // fill's edge.
                child: Container(
                  width: 3,
                  height: 6,
                  decoration: BoxDecoration(
                    color: group.spent >= evenPace
                        ? Halved.cream
                        : theme.colorScheme.onSurface,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
          ]),
        );
      }),
      const SizedBox(height: 4),
      Row(children: [
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
      if (vsPace != null && !group.dq) ...[
        const Spacer(),
        Text(
          vsPace == 0 ? 'on pace'
                      : '${vsPace > 0 ? '+' : ''}$vsPace vs pace',
          style: theme.textTheme.labelSmall?.copyWith(
              color: ahead ? Halved.caution
                           : theme.colorScheme.onSurfaceVariant,
              fontWeight: ahead ? FontWeight.w700 : FontWeight.w600),
        ),
      ],
      ]),
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
