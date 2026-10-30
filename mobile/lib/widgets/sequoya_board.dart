import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/halved_brand.dart';
import '../utils/sequoya_board_model.dart';
import 'dashed_border.dart';

/// The Sequoya 3s board — ONE widget for every Sequoya 3s leaderboard.
///
/// `~/Downloads/handoff-sequoya-leaderboard`. Four cards: the match in play
/// (or the round's end), all six matches hole by hole with their presses, the
/// strokes in the live match, and the ledger. Everything reaches it through
/// [SequoyaBoardData], which reads the engine rather than replaying the round.
///
/// **Colour is the side in THAT match**, pine for side 1 and clay for side 2.
/// The pairing rotates every third hole, so these belong to a match rather
/// than to a golfer, and each match row names its two sides under its tiles.
class SequoyaBoard extends StatelessWidget {
  const SequoyaBoard({super.key, required this.data});

  final SequoyaBoardData data;

  @override
  Widget build(BuildContext context) {
    final live = data.liveMatch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        live == null ? _RoundOver(data: data) : _LiveMatch(data: data, m: live),
        const SizedBox(height: 12),
        _Matches(data: data),
        // Gross has no strokes to lay out, and a card of empty cells would
        // read as a fetch that failed.
        if (live != null && data.handicapMode != 'gross') ...[
          const SizedBox(height: 12),
          _Strokes(data: data, m: live),
        ],
        const SizedBox(height: 12),
        _Ledger(data: data),
      ],
    );
  }
}

const _hairline = Color(0xFFEEF3EE);

Color _sideColour(int? side) => side == 1
    ? Halved.teamPine
    : side == 2
        ? Halved.teamClay
        : Halved.muted;

String _money(double v) {
  final a = v.abs();
  final n = a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
  if (v == 0) return '\$0';
  return '${v > 0 ? '+' : '−'}\$$n';
}

String _plain(double v) =>
    v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

TextStyle _display(double size, Color color) => GoogleFonts.schibstedGrotesk(
    fontSize: size, fontWeight: FontWeight.w700, color: color);

Widget _swatch(int side) => Container(
      width: 10, height: 10,
      decoration: BoxDecoration(
          color: _sideColour(side), borderRadius: BorderRadius.circular(3)),
    );

Widget _sidesLine(SequoyaBoardMatch m) => Row(children: [
      _swatch(1),
      const SizedBox(width: 6),
      Flexible(
        child: Text(m.names(1),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
                color: Halved.deepPine)),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Text('vs',
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w500,
                color: Halved.muted)),
      ),
      _swatch(2),
      const SizedBox(width: 6),
      Flexible(
        child: Text(m.names(2),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
                color: Halved.deepPine)),
      ),
    ]);

Widget _mintDot() => Container(
      width: 7, height: 7,
      decoration: BoxDecoration(
        color: Halved.brightMint,
        shape: BoxShape.circle,
        border: Border.all(color: Halved.deepPine, width: 1),
      ),
    );

// ── 1 · the match in play ───────────────────────────────────────────────

class _LiveMatch extends StatelessWidget {
  const _LiveMatch({required this.data, required this.m});
  final SequoyaBoardData data;
  final SequoyaBoardMatch m;

  @override
  Widget build(BuildContext context) {
    final head = m.head;
    final next = data.nextHole!;
    final on = data.strokesOn(next);
    final par = data.hole(next)?.par;

    // The packet writes `press still live` for every closed match, which is
    // false of one with no press running — a round with presses off, or a
    // match whose press has settled with a hole to go.
    final String status, sub;
    if (head.done) {
      status = 'match closed';
      sub = m.anyPressLive
          ? 'press still live'
          : '${m.endHole - next + 1} to play';
    } else if (head.started) {
      status = 'thru ${head.played} of ${head.holes.length}';
      sub = '${head.holes.length - head.played} to play';
    } else {
      status = 'not started';
      sub = '${head.holes.length} to play';
    }

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.deepPine, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 7, height: 7,
            decoration: const BoxDecoration(
                color: Halved.brightMint, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
                'LIVE · MATCH ${m.index} OF ${data.matches.length} · '
                'HOLES ${m.startHole}–${m.endHole}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: .4, color: Halved.pine)),
          ),
          const SizedBox(width: 8),
          Text('Next: $next${par == null ? '' : ' · par $par'}',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
        const SizedBox(height: 10),
        _sidesLine(m),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(head.value, style: _display(40, _sideColour(head.lead))),
          const Spacer(),
          Text('$status\n$sub',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
        if (head.started) ...[
          const SizedBox(height: 10),
          for (final b in m.bets) _betRow(b),
        ],
        const SizedBox(height: 8),
        Row(children: [
          if (on.isNotEmpty) ...[_mintDot(), const SizedBox(width: 6)],
          Expanded(
            child: Text(
                on.isEmpty
                    ? 'No strokes on $next'
                    : 'Strokes on $next: ${_list(on)}',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600,
                    color: Halved.muted)),
          ),
        ]),
      ]),
    );
  }

  static String _list(List<String> a) => a.length < 2
      ? a.join()
      : '${a.sublist(0, a.length - 1).join(', ')} and ${a.last}';

  Widget _betRow(SequoyaBoardBet b) {
    final label = b.isMatch
        ? 'Match'
        : b.kind == 'auto_press'
            ? 'Auto press'
            : b.calledByShort == null
                ? 'Press'
                : '${b.calledByShort}’s press';
    final lead = b.lead;
    final String state;
    final Color colour;
    if (!b.started) {
      state = 'starts ${b.holes.first}';
      colour = Halved.muted;
    } else if (lead != null) {
      state = '${m.names(lead)} ${b.value}';
      colour = _sideColour(lead);
    } else {
      state = b.done ? 'Halved' : 'AS';
      colour = b.done ? Halved.muted : Halved.deepPine;
    }
    return Container(
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _hairline))),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: Halved.deepPine)),
        const SizedBox(width: 6),
        Expanded(
          child: Text('${b.range} · \$${_plain(data.stake)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Halved.muted)),
        ),
        const SizedBox(width: 8),
        Text(state, style: _display(14, colour)),
      ]),
    );
  }
}

class _RoundOver extends StatelessWidget {
  const _RoundOver({required this.data});
  final SequoyaBoardData data;

  @override
  Widget build(BuildContext context) {
    final m = data.matches.last;
    final head = m.head;
    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('ROUND OVER',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: .4, color: Halved.muted)),
          ),
          Text('${data.matches.length} matches · ${data.betCount} bets',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
        const SizedBox(height: 10),
        _sidesLine(m),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(head.value, style: _display(40, _sideColour(head.lead))),
          const Spacer(),
          Text('Match ${m.index}\n${head.lead == null ? 'Push' : 'Final'}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
      ]),
    );
  }
}

// ── 2 · the matches ─────────────────────────────────────────────────────

class _Matches extends StatelessWidget {
  const _Matches({required this.data});
  final SequoyaBoardData data;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Halved.card,
          border: Border.all(color: Halved.cardBorder, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            Text('MATCHES',
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w700,
                    letterSpacing: .4, color: Halved.muted)),
            SizedBox(width: 12),
            Expanded(
              child: Text('HOLES BY SIDE · PRESSES UNDER',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700,
                      letterSpacing: .4, color: Halved.muted)),
            ),
          ]),
          for (final (i, m) in data.matches.indexed) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(height: 1, thickness: 1, color: _hairline),
              )
            else
              const SizedBox(height: 8),
            _MatchRow(data: data, m: m),
          ],
        ]),
      );
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.data, required this.m});
  final SequoyaBoardData data;
  final SequoyaBoardMatch m;

  static const double _gap = 4;
  static const double _labelWidth = 52;

  @override
  Widget build(BuildContext context) {
    final head = m.head;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: _labelWidth,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('M${m.index}',
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w700,
                        color: Halved.muted)),
                _status(head),
              ]),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final span = m.endHole - m.startHole + 1;
            final w = (c.maxWidth - _gap * (span - 1)) / span;
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    for (var h = m.startHole; h <= m.endHole; h++) ...[
                      if (h > m.startHole) const SizedBox(width: _gap),
                      SizedBox(width: w, child: _tile(h)),
                    ],
                  ]),
                  for (final b in m.presses)
                    Padding(
                      padding: EdgeInsets.only(
                          top: 3,
                          left: (b.holes.first - m.startHole) * (w + _gap)),
                      child: SizedBox(
                        width: b.holes.length * w +
                            (b.holes.length - 1) * _gap,
                        child: _pressBar(b),
                      ),
                    ),
                ]);
          }),
        ),
      ]),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.only(left: _labelWidth),
        child: Wrap(spacing: 12, runSpacing: 2, children: [
          _side(1, head),
          _side(2, head),
        ]),
      ),
    ]);
  }

  Widget _status(SequoyaBoardBet head) {
    if (!head.started) {
      return Text('${m.startHole}–${m.endHole}',
          style: const TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w600,
              color: Halved.muted));
    }
    if (!head.done) {
      return const Text('Live',
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w600,
              color: Halved.muted));
    }
    return Text(head.lead == null ? 'Push' : head.value,
        style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w700,
            color: _sideColour(head.lead)));
  }

  Widget _side(int side, SequoyaBoardBet head) {
    final won = head.done && head.lead == side;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _swatch(side),
      const SizedBox(width: 5),
      Text(m.names(side),
          style: TextStyle(
              fontSize: 12,
              fontWeight: won ? FontWeight.w700 : FontWeight.w600,
              color: won ? Halved.deepPine : Halved.muted)),
    ]);
  }

  Widget _tile(int number) {
    final h = data.hole(number);
    final isNext = data.nextHole == number;
    const height = 28.0;
    if (h == null || !h.played) {
      if (isNext) {
        return Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Halved.card,
            border: Border.all(color: Halved.deepPine, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('$number',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
        );
      }
      return CustomPaint(
        painter: const DashedRRect(color: Halved.cardBorder),
        child: SizedBox(
          height: height,
          child: Center(
            child: Text('$number',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700,
                    color: Halved.cardBorder)),
          ),
        ),
      );
    }
    final side = h.winnerSide;
    final closed = m.head.closedOn;
    // Dimmed once the match bet has closed: those holes still play for any
    // press, and no longer decide the match.
    final after = closed != null && number > closed;
    return Opacity(
      opacity: after ? .45 : 1,
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: side == null ? Halved.surface : _sideColour(side),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('$number',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700,
                color: side == null ? Halved.muted : Colors.white)),
      ),
    );
  }

  Widget _pressBar(SequoyaBoardBet b) {
    final who = b.kind == 'auto_press' ? 'Auto' : (b.calledByShort ?? 'Press');
    final lead = b.lead;
    final String tail;
    Color fill = Halved.card;
    Color ink = Halved.deepPine;
    Color? line = Halved.cardBorder;
    if (!b.started) {
      tail = b.range;
    } else if (b.done) {
      line = null;
      if (lead == null) {
        tail = 'halved';
        fill = Halved.surface;
        ink = Halved.muted;
      } else {
        tail = b.holes.length == 1 ? 'won' : 'won ${b.value}';
        fill = _sideColour(lead);
        ink = Colors.white;
      }
    } else {
      tail = b.value;
      if (lead != null) {
        line = _sideColour(lead);
        ink = _sideColour(lead);
      }
    }
    return Container(
      height: 20,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(5),
        border: line == null ? null : Border.all(color: line, width: 1.5),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text.rich(TextSpan(children: [
          TextSpan(text: who),
          TextSpan(text: ' · $tail',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
            maxLines: 1,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: ink)),
      ),
    );
  }
}

// ── 3 · strokes in the live match ───────────────────────────────────────

class _Strokes extends StatelessWidget {
  const _Strokes({required this.data, required this.m});
  final SequoyaBoardData data;
  final SequoyaBoardMatch m;

  static const double _nameWidth = 60;
  static const double _totalWidth = 26;

  @override
  Widget build(BuildContext context) {
    final holes = [
      for (var h = m.startHole; h <= m.endHole; h++) h,
    ];
    final bySide = {
      for (final side in [1, 2])
        side: data.rosterOrder
            .where((g) => (side == 1 ? m.side1Ids : m.side2Ids)
                .contains(g.playerId))
            .toList(),
    };
    int total(SequoyaBoardGolfer g) => holes.fold(
        0, (n, h) => n + (data.hole(h)?.strokes[g.playerId] ?? 0));
    int sideTotal(int s) => bySide[s]!.fold(0, (n, g) => n + total(g));

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('STROKES · MATCH ${m.index}',
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w700,
                  letterSpacing: .4, color: Halved.muted)),
          const Spacer(),
          Text(
              data.handicapMode == 'strokes_off'
                  ? 'OFF THE LOW'
                  : 'NET ${data.netPercent}%',
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w700,
                  letterSpacing: .4, color: Halved.muted)),
        ]),
        const SizedBox(height: 3),
        Row(children: [
          const SizedBox(width: _nameWidth),
          for (final h in holes)
            Expanded(
              child: Text('$h',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      color: h == data.nextHole
                          ? Halved.deepPine : Halved.muted)),
            ),
          const SizedBox(
            width: _totalWidth,
            child: Text('Tot',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w700,
                    color: Halved.muted)),
          ),
        ]),
        for (final side in [1, 2]) ...[
          if (side == 2)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Divider(height: 1, thickness: 1, color: _hairline),
            ),
          for (final g in bySide[side]!)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(children: [
                SizedBox(
                  width: _nameWidth,
                  child: Row(children: [
                    _swatch(side),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(g.shortName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700,
                              color: Halved.deepPine)),
                    ),
                  ]),
                ),
                for (final h in holes)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: _cell(h, g),
                    ),
                  ),
                SizedBox(
                  width: _totalWidth,
                  child: Text('${total(g)}',
                      textAlign: TextAlign.right,
                      style: _display(12.5, Halved.muted)),
                ),
              ]),
            ),
        ],
        const SizedBox(height: 4),
        Text(
            '${m.names(1)} get ${sideTotal(1)} · '
            '${m.names(2)} get ${sideTotal(2)} in this match',
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600,
                color: Halved.muted)),
      ]),
    );
  }

  Widget _cell(int hole, SequoyaBoardGolfer g) {
    final h = data.hole(hole);
    final n = h?.strokes[g.playerId] ?? 0;
    final isNext = hole == data.nextHole;
    final played = h?.played ?? false;
    return Container(
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isNext || played ? Halved.card : Halved.surface,
        borderRadius: BorderRadius.circular(5),
        border: isNext
            ? Border.all(color: Halved.deepPine, width: 2)
            : played
                ? Border.all(color: Halved.cardBorder, width: 1.5)
                : null,
      ),
      // One dot per stroke: strokes-off can give a high man two on one hole.
      child: n == 0
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < n; i++)
                Padding(
                  padding: EdgeInsets.only(left: i == 0 ? 0 : 3),
                  child: _mintDot(),
                ),
            ]),
    );
  }
}

// ── 4 · the ledger ──────────────────────────────────────────────────────

class _Ledger extends StatelessWidget {
  const _Ledger({required this.data});
  final SequoyaBoardData data;

  static const double _markWidth = 26;
  static const double _moneyWidth = 64;

  @override
  Widget build(BuildContext context) {
    const dim = Color(0xFFB9CCC3);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic, children: [
            Text(data.roundOver ? 'Final, each' : 'Each · now',
                style: const TextStyle(fontSize: 13, color: dim)),
            const Spacer(),
            Text('\$${_plain(data.stake)} a bet',
                style: _display(20, Colors.white)),
          ]),
        ),
        Container(
          color: Halved.card,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Row(children: [
            const Expanded(
              child: Text('PLAYER',
                  style: TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700,
                      letterSpacing: .3, color: Halved.muted)),
            ),
            for (final m in data.matches)
              SizedBox(
                width: _markWidth,
                child: Text('M${m.index}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w700,
                        color: Halved.muted)),
              ),
            const SizedBox(
              width: _moneyWidth,
              child: Text('\$',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700,
                      color: Halved.muted)),
            ),
          ]),
        ),
        for (final g in data.golfers) _row(g),
        Container(
          color: Halved.card,
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            color: Halved.deepPine,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Wrap(spacing: 14, runSpacing: 4, children: [
              _foot('Settled ', '${data.settled} of ${data.matches.length}'),
              _foot('Bets ', '${data.betCount}'),
              data.roundOver
                  ? const Text('Final',
                      style: TextStyle(fontSize: 12.5, color: dim))
                  : _foot('Left ',
                      '${data.holesLeft} '
                      '${data.holesLeft == 1 ? 'hole' : 'holes'}'),
            ]),
          ),
        ),
      ]),
    );
  }

  static Widget _foot(String label, String value) => Text.rich(
        TextSpan(children: [
          TextSpan(text: label),
          TextSpan(text: value,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
        style: const TextStyle(fontSize: 12.5, color: Color(0xFFB9CCC3)),
      );

  Widget _row(SequoyaBoardGolfer g) {
    final up = g.money > 0;
    return Container(
      color: Halved.card,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(children: [
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: g.firstName),
              if (g.surname.isNotEmpty)
                TextSpan(text: ' ${g.surname}',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w500,
                        color: Halved.muted)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600,
                color: Halved.deepPine),
          ),
        ),
        for (final mk in g.marks)
          SizedBox(width: _markWidth, child: Center(child: _mark(mk))),
        SizedBox(
          width: _moneyWidth,
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: up
                  ? const EdgeInsets.symmetric(horizontal: 7, vertical: 3)
                  : EdgeInsets.zero,
              decoration: up
                  ? BoxDecoration(
                      color: Halved.brightMint,
                      borderRadius: BorderRadius.circular(8))
                  : null,
              child: Text(_money(g.money),
                  style: _display(18, Halved.deepPine)),
            ),
          ),
        ),
      ]),
    );
  }

  /// Filled once every bet in the match is settled, outlined while live.
  Widget _mark(SequoyaBoardMark mk) {
    if (!mk.started) {
      return Text(mk.glyph,
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700,
              color: Halved.cardBorder));
    }
    final up = mk.net > 0;
    final Color? fill = mk.settled
        ? (up ? Halved.pine : Halved.surface)
        : null;
    final Color ink = mk.settled
        ? (up ? Colors.white : Halved.muted)
        : (up ? Halved.pine : Halved.muted);
    return Container(
      width: 22, height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
        border: mk.settled
            ? null
            : Border.all(
                color: up ? Halved.pine : Halved.cardBorder, width: 1.5),
      ),
      child: Text(mk.glyph,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: ink)),
    );
  }
}
