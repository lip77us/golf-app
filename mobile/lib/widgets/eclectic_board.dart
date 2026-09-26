/// widgets/eclectic_board.dart
/// --------------------------
/// The Eclectic tab: a ranked board whose rows open into the card they were
/// drawn from.
///
/// **The number is TO PAR**, not a gross total. A gross 63 means nothing across
/// two courses with different pars, and to-par is what the game is scored on
/// anyway — so the column, the Best row and the segmented control's pools all
/// read the same way.
///
/// **The row opens the card** because the question a golfer asks of a −9 is
/// *where did that come from*. So the card is every round, one row each, with
/// the kept score marked, and the eclectic itself along the bottom.
///
/// There is deliberately **no par row**. Two courses mean two pars on some
/// holes, so a single row of pars would be wrong for half the card. The
/// notation carries it instead — a circle is under par, a square is over, and
/// doubled means two or more — read against THAT round's par, or its net par in
/// the Net pool.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'score_mark.dart';
import 'stroke_dots.dart';

/// The kept cell. The packet names it as Rumble's counted-ball token; the app
/// has no such shared constant, so it is defined here with its values rather
/// than pointed at something that does not exist.
const _keptFill = Color(0xFFDCF2E4);
const _keptText = Color(0xFF0B5B44);

class EclecticBoard extends StatefulWidget {
  final Map<String, dynamic> data;

  /// The reader, for the `YOU` tag. **Passed in rather than read from a
  /// provider**: the board is then a pure function of its payload, which is
  /// what makes it testable — and what lets a surface with no signed-in user
  /// (a watch page) draw the same widget. Null simply tags nobody.
  final int? readerId;

  const EclecticBoard({super.key, required this.data, this.readerId});

  @override
  State<EclecticBoard> createState() => _EclecticBoardState();
}

class _EclecticBoardState extends State<EclecticBoard> {
  late EclecticSummary _s = EclecticSummary.fromJson(widget.data);
  String _pool = '';
  /// Which row is open. **One at a time** — the card is tall and two open at
  /// once turns the board into a scroll with no board in it.
  int? _openPid;

  @override
  void initState() {
    super.initState();
    _pool = _s.pools.isNotEmpty ? _s.pools.first : 'gross';
    _openPid = _leaderId;
  }

  @override
  void didUpdateWidget(covariant EclecticBoard old) {
    super.didUpdateWidget(old);
    // A silent refresh re-enters with fresh data; keep the open row and the
    // chosen pool rather than snapping back to the leader under the reader's
    // thumb.
    _s = EclecticSummary.fromJson(widget.data);
    if (!_s.pools.contains(_pool) && _s.pools.isNotEmpty) {
      _pool = _s.pools.first;
    }
  }

  EclecticPool? get _current => _s.poolNamed(_pool);

  int? get _leaderId {
    final rows = _current?.standings ?? const [];
    return rows.isEmpty ? null : rows.first.playerId;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pool  = _current;
    if (pool == null || pool.standings.isEmpty) {
      return const Center(child: Text('No scores yet.'));
    }
    final me = widget.readerId;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        // The switch appears ONLY when both pools are on — one pool needs no
        // choosing, and a single-segment control is a control with nothing to
        // do.
        if (_s.pools.length > 1) ...[
          _PoolSwitch(
            pools: _s.pools,
            selected: _pool,
            moneyOf: (p) => _s.poolNamed(p)?.pool ?? 0,
            onChanged: (p) => setState(() {
              _pool = p;
              // Switching resets the open row to the leader: the reader is
              // looking at a different competition, and the row that was open
              // may not be in the same place in it.
              _openPid = _leaderId;
            }),
          ),
          const SizedBox(height: 10),
        ],

        _ChipRow(summary: _s),
        const SizedBox(height: 8),
        _HeaderRow(),

        for (final row in pool.standings)
          _StandingRow(
            row     : row,
            isMe    : row.playerId == me,
            isOpen  : row.playerId == _openPid,
            isLive  : !_s.isFinal,
            subline : _subline(pool, row.playerId),
            // Tapping the OPEN row closes it, which is the only way back to a
            // board with nothing open.
            onTap   : () => setState(() =>
                _openPid = _openPid == row.playerId ? null : row.playerId),
            card    : pool.cards[row.playerId],
            legend  : _s.courseLegend,
            isNet   : _pool == 'net',
            theme   : theme,
          ),
      ],
    );
  }

  /// `R1 79 · R2 84 · R3 thru 12` — and `not started` before the first score.
  ///
  /// Built from the card's own cells rather than asking the server for a
  /// second set of totals, which would be two answers to one question.
  String _subline(EclecticPool pool, int pid) {
    final card = pool.cards[pid];
    if (card == null) return 'not started';
    final parts = <String>[];
    for (final r in card.rounds) {
      if (r.holes.isEmpty) continue;
      if (r.holes.length >= 18) {
        final gross = r.holes.values.fold<int>(0, (a, c) => a + c.gross);
        parts.add('${r.label} $gross');
      } else {
        parts.add('${r.label} thru ${r.holes.length}');
      }
    }
    return parts.isEmpty ? 'not started' : parts.join(' · ');
  }
}

// ---------------------------------------------------------------------------

class _PoolSwitch extends StatelessWidget {
  final List<String> pools;
  final String selected;
  final double Function(String) moneyOf;
  final ValueChanged<String> onChanged;
  const _PoolSwitch({
    required this.pools, required this.selected,
    required this.moneyOf, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        for (final p in pools)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(p),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: p == selected ? theme.colorScheme.surface : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(p == 'net' ? 'Net' : 'Gross',
                        style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: p == selected
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(width: 6),
                    // **Each segment carries its own pool.** They are separate
                    // competitions with separate entries, and the money is
                    // what says so.
                    Text('\$${moneyOf(p).toStringAsFixed(0)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _ChipRow extends StatelessWidget {
  final EclecticSummary summary;
  const _ChipRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Text('Rounds ', style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      Text('${summary.nRounds}', style: theme.textTheme.bodySmall
          ?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(width: 10),
      Text('Courses ', style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      Text('${summary.nCourses}', style: theme.textTheme.bodySmall
          ?.copyWith(fontWeight: FontWeight.bold)),
      const Spacer(),
      // Amber while anything can still move, because the prize below is a
      // projection until it cannot.
      if (summary.liveLabel.isNotEmpty)
        Text('${summary.liveLabel} · projected',
            style: theme.textTheme.bodySmall?.copyWith(
                color: Halved.caution, fontWeight: FontWeight.w600)),
    ]);
  }
}

class _HeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.5, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 4, 8, 4),
      child: Row(children: [
        Text('GOLFER', style: style),
        const Spacer(),
        Text('TO PAR', style: style),
        const SizedBox(width: 18),
        Text('PRIZE', style: style),
      ]),
    );
  }
}

class _StandingRow extends StatelessWidget {
  final EclecticStanding row;
  final bool isMe;
  final bool isOpen;
  final bool isLive;
  final String subline;
  final VoidCallback onTap;
  final EclecticCard? card;
  final List<Map<String, String>> legend;
  final bool isNet;
  final ThemeData theme;

  const _StandingRow({
    required this.row, required this.isMe, required this.isOpen,
    required this.isLive, required this.subline, required this.onTap,
    required this.card, required this.legend, required this.isNet,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
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
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(children: [
              SizedBox(
                width: 26,
                child: Text(row.positionLabel,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(row.playerName,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 6),
                        _Tag('YOU'),
                      ],
                      if (row.excluded) ...[
                        const SizedBox(width: 6),
                        // Ranked and visible, but cannot collect — the money
                        // column would otherwise just be empty with no reason.
                        _Tag('NOT PAID'),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(subline,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 42,
                child: Text(_toPar(row.total),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  row.payout == null || row.payout == 0
                      ? ''
                      : '\$${row.payout!.toStringAsFixed(0)}',
                  textAlign: TextAlign.end,
                  // Italic and muted while a round is open: the money is a
                  // projection until the event closes.
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontStyle: isLive ? FontStyle.italic : FontStyle.normal,
                    color: isLive
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ]),
          ),
        ),
        if (isOpen && card != null)
          EclecticCardView(card: card!, legend: legend, isNet: isNet),
      ]),
    );
  }

  static String _toPar(int? v) {
    if (v == null) return '–';
    if (v == 0) return 'E';
    return v > 0 ? '+$v' : '$v';
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
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.4,
              color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

// ---------------------------------------------------------------------------
// The card
// ---------------------------------------------------------------------------

/// Front and back nines, a row per round, and the eclectic along the bottom.
///
/// Public because it is the answer to "where did that −9 come from" and the
/// packet puts it on one surface today — but it is the kind of thing a
/// settlement receipt or a watch page asks for next, and a copy of it would
/// drift from this one.
class EclecticCardView extends StatelessWidget {
  final EclecticCard card;
  final List<Map<String, String>> legend;
  final bool isNet;

  const EclecticCardView({
    super.key, required this.card, required this.legend, required this.isNet,
  });

  static const _labelW = 46.0;
  static const _cellW  = 27.0;
  static const _rowH   = 26.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Eclectic card', style: theme.textTheme.labelMedium
              ?.copyWith(fontWeight: FontWeight.bold)),
          const Spacer(),
          Flexible(
            child: Text(
              legend.map((e) => '${e['key']} ${e['course']}').join(' · '),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        _nine(context, const [1, 2, 3, 4, 5, 6, 7, 8, 9], 'Front', 'Out'),
        const SizedBox(height: 10),
        _nine(context, const [10, 11, 12, 13, 14, 15, 16, 17, 18], 'Back', 'In'),
      ]),
    );
  }

  Widget _nine(BuildContext context, List<int> holes, String head, String tot) {
    final theme = Theme.of(context);
    Widget label(String t, {bool bold = false, String suffix = ''}) => SizedBox(
          width: _labelW, height: _rowH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text.rich(TextSpan(children: [
              TextSpan(text: t),
              if (suffix.isNotEmpty)
                TextSpan(text: ' $suffix',
                    style: TextStyle(
                        fontSize: 8.5,
                        color: theme.colorScheme.onSurfaceVariant)),
            ]), style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
          ),
        );

    Widget cell(Widget child, {Color? bg}) => Container(
          width: _cellW, height: _rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(3),
          ),
          child: child,
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header band — hole numbers and the nine's total column.
        Row(children: [
          label(head, bold: true),
          for (final h in holes)
            cell(Text('$h', style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant))),
          cell(Text(tot, style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant))),
        ]),

        // A row per round. The cells print GROSS, which is what a golfer
        // remembers making; the notation is read against that round's par —
        // net par in the Net pool.
        for (final r in card.rounds)
          Row(children: [
            label(r.label, suffix: r.courseInitial),
            for (final h in holes) _roundCell(context, r, h, cell),
            // **Round totals are GROSS in both pools.** A net nine total would
            // be a fourth number in a card that is already carrying gross,
            // to-par and strokes.
            cell(Text(_nineGross(r, holes),
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontWeight: FontWeight.bold))),
          ]),

        // The eclectic itself.
        Row(children: [
          label('Best', bold: true),
          for (final h in holes) _bestCell(context, h, cell),
          cell(Text(_nineBest(holes),
              style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold, color: _keptText))),
        ]),
      ]),
    );
  }

  Widget _roundCell(BuildContext context, EclecticCardRound r, int h,
      Widget Function(Widget, {Color? bg}) cell) {
    final theme = Theme.of(context);
    final c = r.holes[h];
    if (c == null) {
      return cell(Text('–', style: theme.textTheme.labelSmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)));
    }
    final style = theme.textTheme.labelSmall!.copyWith(
        fontWeight: c.kept ? FontWeight.bold : FontWeight.w500,
        color: c.kept ? _keptText : null);
    return cell(
      Stack(alignment: Alignment.center, children: [
        scoreMark(text: '${c.gross}', diff: c.toPar,
            baseStyle: style, theme: theme),
        // Net shows the same gross digit with the round's strokes above it —
        // the existing dots, so a stroke looks the same here as on any card.
        if (isNet && c.strokes > 0)
          StrokeDotColumn(strokes: c.strokes, color: theme.colorScheme.primary),
      ]),
      bg: c.kept ? _keptFill : null,
    );
  }

  Widget _bestCell(BuildContext context, int h,
      Widget Function(Widget, {Color? bg}) cell) {
    final theme = Theme.of(context);
    final v = card.best[h];
    if (v == null) {
      return cell(Text('–', style: theme.textTheme.labelSmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)));
    }
    return cell(Text(v == 0 ? 'E' : (v > 0 ? '+$v' : '$v'),
        style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            // Pine under, amber over — the same pair the Irish Rumble group
            // row uses.
            color: v < 0 ? Halved.pine
                 : v > 0 ? Halved.caution
                 : theme.colorScheme.onSurface)));
  }

  String _nineGross(EclecticCardRound r, List<int> holes) {
    var total = 0;
    for (final h in holes) {
      final c = r.holes[h];
      // A nine is a total or it is nothing — a partial sum reads as a real
      // score. Same rule every scorecard in the app uses.
      if (c == null) return '–';
      total += c.gross;
    }
    return '$total';
  }

  String _nineBest(List<int> holes) {
    var total = 0;
    var any = false;
    for (final h in holes) {
      final v = card.best[h];
      if (v == null) continue;
      total += v;
      any = true;
    }
    // Unlike the gross nine, this one sums what is THERE: a hole with no
    // candidate adds nothing to the eclectic total either, so a partial nine
    // is the honest running figure rather than a misleading one.
    if (!any) return '–';
    return total == 0 ? 'E' : (total > 0 ? '+$total' : '$total');
  }
}
