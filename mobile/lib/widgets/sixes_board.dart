/// widgets/sixes_board.dart
/// ------------------------
/// The Sixes leaderboard (`handoff-sixes-leaderboard`, 24 Oct 2026).
///
/// Four golfers, three six-hole matches, partners rotating so everyone
/// partners everyone once. The board's job is that rotation: a flat
/// team-vs-team line cannot show it, because the teams are not the same two
/// teams from one match to the next.
///
/// **Pine is side A and clay side B WITHIN A MATCH** — the colours belong to
/// the match, not to the golfer. The same man is pine in match 1 and clay in
/// match 2, which is the point of the format and the reason the legend is
/// repeated under every row rather than printed once at the top.
///
/// Its own file rather than another card inside `leaderboard_screen.dart`,
/// which is ten thousand lines and whose own notes record that string-matched
/// edits there keep landing in the wrong card.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';

/// Side B.
///
/// The packet's `#B45309`, and NOT `Halved.caution` (`#8A5216`) which is
/// close enough to be tempting. They mean different things: caution is the
/// app's voice for something needing attention, and this is simply the other
/// side of a match — half the golfers on the card are it at any moment. A
/// side colour that also means "careful" would make every second row read as
/// a warning.
const Color _sideB = Color(0xFFB45309);
const Color _sideA = Halved.pine;

/// One match, reduced to what the board draws.
///
/// A class rather than getters scattered down the widget because every card
/// on the screen asks the same five questions of the same segment, and three
/// of them (closed out, thru, to play) are easy to answer inconsistently.
class SixesMatch {
  final SixesSegment seg;
  const SixesMatch(this.seg);

  /// Holes actually PLAYED. The backend emits a segment's holes up front, so
  /// a null winner is a hole nobody has played rather than one that halved —
  /// the distinction the "not played" tile depends on.
  List<SixesHoleResult> get played =>
      seg.holes.where((h) => h.winner != null).toList();

  int get total => seg.endHole - seg.startHole + 1;
  int get thru => played.length;
  int get toPlay => (total - thru).clamp(0, total);

  bool get drawn => seg.team1.players.isNotEmpty && seg.team2.players.isNotEmpty;
  bool get isLive => seg.status == 'in_progress';
  bool get isDone => seg.status == 'complete' || seg.status == 'halved';

  /// Positive = side A up. Zero = level.
  int get margin => played.isEmpty ? 0 : played.last.margin;

  /// Side A, side B, or null when level.
  Color? get leaderColour =>
      margin == 0 ? null : (margin > 0 ? _sideA : _sideB);

  /// A match is closed out when the lead exceeds the holes left to play.
  bool get closedOut => isDone && toPlay > 0 && margin.abs() > 0;

  /// The big figure: `3 UP` live, `4 & 2` closed out, `AS` level, `Push` for
  /// a level finish.
  ///
  /// Deliberately NOT `SixesSegment.statusDisplay`, which writes a sentence
  /// (`3 UP thru 5`) for a line of body text. Here the thru sits in its own
  /// slot beside the figure, so repeating it inside would print it twice.
  String get figure {
    if (!drawn) return '—';
    if (isDone) {
      if (seg.winner == 'Halved' || margin == 0) return 'Push';
      return closedOut ? '${margin.abs()}&$toPlay' : '${margin.abs()} UP';
    }
    if (played.isEmpty) return '—';
    return margin == 0 ? 'AS' : '${margin.abs()} UP';
  }

  /// Which side won a given hole: 'A', 'B', 'halved', or null for unplayed.
  String? sideAt(int hole) {
    for (final h in seg.holes) {
      if (h.hole != hole) continue;
      return switch (h.winner) {
        'T1' => 'A',
        'T2' => 'B',
        'Halved' => 'halved',
        _ => null,
      };
    }
    return null;
  }

  /// The next hole to play, or null once the match is over.
  int? get nextHole {
    if (isDone || !drawn) return null;
    for (var h = seg.startHole; h <= seg.endHole; h++) {
      if (sideAt(h) == null) return h;
    }
    return null;
  }

  String sideLabel(bool a) {
    final t = a ? seg.team1 : seg.team2;
    final names = t.playersShort.isNotEmpty ? t.playersShort : t.players;
    return names.isEmpty ? '—' : names.join(' & ');
  }
}

class SixesBoard extends StatelessWidget {
  /// The `by_group` entry — `{group_number, summary, ...}`.
  final Map<String, dynamic> group;
  const SixesBoard({super.key, required this.group});

  SixesSummary get _s => SixesSummary.fromJson(
      (group['summary'] as Map?)?.cast<String, dynamic>() ?? const {});

  /// Standard matches only. An EXTRA segment is a spawned tie-breaker and
  /// not one of the three the format is made of, so it does not get a row in
  /// a card whose whole shape is M1/M2/M3.
  List<SixesMatch> get _matches => _s.segments
      .where((s) => !s.isExtra)
      .map(SixesMatch.new)
      .toList();

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    if (matches.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Teams are not set yet.'),
      );
    }
    final live = matches.where((m) => m.isLive).firstOrNull;
    final grid = _s.holes;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _LiveMatchCard(
          match: live ?? matches.last,
          holes: grid,
          players: _s.players,
          over: live == null,
          matchCount: matches.length),
      const SizedBox(height: 10),
      _HolesWonCard(matches: matches),
      if (live != null) ...[
        const SizedBox(height: 10),
        _StrokesCard(match: live, holes: grid, players: _s.players),
      ],
      const SizedBox(height: 10),
      _Ledger(summary: _s, matches: matches),
    ]);
  }
}

/// The match being played — or, once the round is over, the last one.
class _LiveMatchCard extends StatelessWidget {
  final SixesMatch match;
  final List<Map<String, dynamic>> holes;
  final List<Map<String, dynamic>> players;
  final bool over;
  /// How many matches the round has, for the `3 matches` the header shows in
  /// place of `Next:` once there is no next hole.
  final int matchCount;
  const _LiveMatchCard({
    required this.match, required this.holes, required this.players,
    required this.over, required this.matchCount,
  });

  int? _parOf(int hole) {
    for (final h in holes) {
      if ((h['hole'] as num?)?.toInt() == hole) return (h['par'] as num?)?.toInt();
    }
    return null;
  }

  /// `No strokes on 5` or `Strokes on 5: Paul, AD`.
  ///
  /// Read from the grid's own per-player `strokes`, which is what
  /// `sixes_player_hole_strokes` allocated — NOT re-derived from handicaps
  /// and stroke index. Sixes spreads strokes across each six-hole match
  /// under its per-segment allocation, so the generic rule gives a different
  /// answer, and the scorecard on this same screen already draws the
  /// server's dots.
  (String, bool) _strokeLine(int? next, List<Map<String, dynamic>> players) {
    if (next == null) return ('', false);
    for (final h in holes) {
      if ((h['hole'] as num?)?.toInt() != next) continue;
      final names = <String>[];
      for (final sc in (h['scores'] as List? ?? const [])) {
        final m = (sc as Map).cast<String, dynamic>();
        if (((m['strokes'] as num?)?.toInt() ?? 0) <= 0) continue;
        final pid = (m['player_id'] as num?)?.toInt();
        final who = players.firstWhere(
            (p) => (p['player_id'] as num?)?.toInt() == pid,
            orElse: () => const {});
        final n = (who['short_name'] ?? who['name'])?.toString();
        if (n != null && n.isNotEmpty) names.add(n);
      }
      return names.isEmpty
          ? ('No strokes on $next', false)
          : ('Strokes on $next: ${names.join(', ')}', true);
    }
    return ('No strokes on $next', false);
  }

  @override
  Widget build(BuildContext context) {
    final next = match.nextHole;
    final par  = next == null ? null : _parOf(next);
    final colour = match.leaderColour;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Halved.deepPine, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (!over) ...[
            Container(
              width: 7, height: 7,
              decoration: const BoxDecoration(
                  color: Halved.brightMint, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              over
                  ? 'ROUND OVER'
                  : 'LIVE · ${match.seg.label.toUpperCase()} · '
                    'HOLES ${match.seg.startHole}–${match.seg.endHole}',
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  letterSpacing: 0.7, color: Halved.deepPine),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (over)
            Text('$matchCount ${matchCount == 1 ? 'match' : 'matches'}',
                style: const TextStyle(fontSize: 11, color: Halved.muted))
          else if (next != null)
            Text('Next: $next${par == null ? '' : ' · par $par'}',
                style: const TextStyle(fontSize: 11, color: Halved.muted)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _swatch(_sideA),
          const SizedBox(width: 6),
          Flexible(child: Text(match.sideLabel(true),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: Halved.deepPine))),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('vs',
                style: TextStyle(fontSize: 12, color: Halved.muted)),
          ),
          _swatch(_sideB),
          const SizedBox(width: 6),
          Flexible(child: Text(match.sideLabel(false),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: Halved.deepPine))),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Text(match.figure,
                style: TextStyle(
                    fontSize: 40, height: 1.05, fontWeight: FontWeight.w700,
                    // Muted when level: nobody is leading, and colouring it
                    // either side would say somebody is.
                    color: colour ?? Halved.muted)),
          ),
          // Once the round is over, `thru 6 of 6 / none to play` states the
          // obvious. The slot answers a different question then: WHICH match
          // this result belongs to, since the card is no longer live.
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: over
              ? [
                  Text(match.seg.label.replaceFirst('M', 'Match '),
                      style: const TextStyle(
                          fontSize: 12, color: Halved.muted)),
                  const Text('Final',
                      style: TextStyle(fontSize: 12, color: Halved.muted)),
                ]
              : [
                  Text('thru ${match.thru} of ${match.total}',
                      style: const TextStyle(
                          fontSize: 12, color: Halved.muted)),
                  Text(match.toPlay == 0
                          ? 'none to play' : '${match.toPlay} to play',
                      style: const TextStyle(
                          fontSize: 12, color: Halved.muted)),
                ]),
        ]),
        if (!over) ...[
          const SizedBox(height: 8),
          Builder(builder: (_) {
            final (line, has) = _strokeLine(next, players);
            if (line.isEmpty) return const SizedBox.shrink();
            return Row(children: [
              if (has) ...[
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(
                      color: Halved.brightMint, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(child: Text(line,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: Halved.muted))),
            ]);
          }),
        ],
      ]),
    );
  }

  static Widget _swatch(Color c) => Container(
        width: 10, height: 10,
        decoration: BoxDecoration(color: c, borderRadius:
            BorderRadius.circular(3)),
      );
}

/// One row per match, six tiles each.
///
/// The sides legend repeats under EVERY row, which looks redundant until you
/// remember the partners rotate: the man who is pine on the first row is clay
/// on the second, so a legend printed once at the top would be wrong for two
/// thirds of the card.
class _HolesWonCard extends StatelessWidget {
  final List<SixesMatch> matches;
  const _HolesWonCard({required this.matches});

  @override
  Widget build(BuildContext context) => _shell(
        title: 'HOLES WON',
        trailing: 'BY SIDE, EACH MATCH',
        child: Column(children: [
          for (var i = 0; i < matches.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _row(matches[i]),
          ],
        ]),
      );

  Widget _row(SixesMatch m) {
    final next = m.nextHole;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 44,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.seg.label,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
          Builder(builder: (_) {
            final (text, colour) = _status(m);
            return Text(text,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight:
                        colour == null ? FontWeight.w400 : FontWeight.w700,
                    color: colour ?? Halved.muted));
          }),
        ]),
      ),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            for (var h = m.seg.startHole; h <= m.seg.endHole; h++) ...[
              if (h > m.seg.startHole) const SizedBox(width: 5),
              Expanded(child: _tile(h, m.sideAt(h), h == next)),
            ],
          ]),
          const SizedBox(height: 5),
          Row(children: [
            _legend(_sideA, m.sideLabel(true), m, true),
            const SizedBox(width: 12),
            _legend(_sideB, m.sideLabel(false), m, false),
          ]),
        ],
      )),
    ]);
  }

  /// Range before it starts, `Live` while it runs, and once it is
  /// decided the RESULT itself — `2&1` — in the winning side's colour
  /// (V2, 24 Oct).
  ///
  /// `Final` was a word that said only that the match had stopped. The
  /// result says that AND what it was, in the same space, which is what
  /// a reader scanning three rows is after.
  static (String, Color?) _status(SixesMatch m) {
    if (!m.drawn) return ('Undrawn', null);
    if (m.isLive) return ('Live', null);
    if (m.isDone) {
      return m.figure == 'Push'
          ? ('Push', null)
          : (m.figure, m.leaderColour);
    }
    return ('${m.seg.startHole}–${m.seg.endHole}', null);
  }

  static Widget _tile(int hole, String? side, bool isNext) {
    final (Color fill, Color text, Color? line) = switch (side) {
      'A' => (_sideA, Halved.cream, null),
      'B' => (_sideB, Halved.cream, null),
      'halved' => (Halved.cardBorder, Halved.deepPine, null),
      // Not played: an outline, and the NEXT one in deep pine so the group
      // can see which hole the card is waiting on.
      _ => (Colors.transparent,
            isNext ? Halved.deepPine : Halved.muted,
            isNext ? Halved.deepPine : Halved.cardBorder),
    };
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(7),
        border: line == null
            ? null
            : Border.all(color: line, width: isNext ? 1.8 : 1),
      ),
      alignment: Alignment.center,
      child: Text('$hole',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: side == null && !isNext
                  ? Halved.muted.withValues(alpha: 0.55)
                  : text)),
    );
  }

  /// A side's swatch and name — and, once the match is decided, a `won 2&1`
  /// tag in that side's colour (V2, 24 Oct).
  ///
  /// The tag sits beside the WINNER rather than at the end of the row,
  /// because the partners rotate: which of the two names won is the thing
  /// being read, and a result floating at the end of the row would have to
  /// be traced back to one of them.
  static Widget _legend(Color c, String label, SixesMatch m, bool isA) {
    final decided = m.isDone && m.figure != 'Push' && m.leaderColour != null;
    final won = decided && ((m.margin > 0) == isA);
    return Flexible(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8, height: 8,
          decoration:
              BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: won ? FontWeight.w700 : FontWeight.w400,
                  color: won ? Halved.deepPine : Halved.muted)),
        ),
        if (won) ...[
          const SizedBox(width: 5),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text('won ${m.figure}',
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w700,
                    color: Halved.cream)),
          ),
        ],
      ]),
    );
  }
}

Widget _shell({
  required String title,
  String? trailing,
  required Widget child,
}) =>
    Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Halved.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  letterSpacing: 0.7, color: Halved.deepPine)),
          const Spacer(),
          if (trailing != null)
            Text(trailing,
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w700,
                    letterSpacing: 0.6, color: Halved.muted)),
        ]),
        const SizedBox(height: 12),
        child,
      ]),
    );

/// Who strokes where in the live match.
///
/// **Reads the server's allocation, never re-derives it.** The packet gives
/// the generic rule — CH minus the low handicap against stroke index — but
/// Sixes allocates its own way: under strokes-off with per-segment spread it
/// gives the strokes out across each six-hole match rather than by round-wide
/// index. The grid already carries the answer per player per hole, and the
/// scorecard further down this same screen already draws it, so deriving here
/// would be a second rule that disagrees with the dots beside it.
class _StrokesCard extends StatelessWidget {
  final SixesMatch match;
  final List<Map<String, dynamic>> holes;
  final List<Map<String, dynamic>> players;
  const _StrokesCard({
    required this.match, required this.holes, required this.players,
  });

  int _strokes(int pid, int hole) {
    for (final h in holes) {
      if ((h['hole'] as num?)?.toInt() != hole) continue;
      for (final sc in (h['scores'] as List? ?? const [])) {
        final m = (sc as Map).cast<String, dynamic>();
        if ((m['player_id'] as num?)?.toInt() == pid) {
          return (m['strokes'] as num?)?.toInt() ?? 0;
        }
      }
    }
    return 0;
  }

  bool _played(int hole) => match.sideAt(hole) != null;

  String _name(int pid) {
    final p = players.firstWhere(
        (x) => (x['player_id'] as num?)?.toInt() == pid,
        orElse: () => const {});
    return (p['short_name'] ?? p['name'] ?? '—').toString();
  }

  @override
  Widget build(BuildContext context) {
    final next = match.nextHole;
    final hs = [
      for (var h = match.seg.startHole; h <= match.seg.endHole; h++) h,
    ];
    final sideA = match.seg.team1.playerIds;
    final sideB = match.seg.team2.playerIds;
    if (sideA.isEmpty && sideB.isEmpty) return const SizedBox.shrink();

    int totalFor(List<int> side) =>
        side.fold(0, (a, p) => a + hs.fold(0, (b, h) => b + _strokes(p, h)));

    return _shell(
      title: 'STROKES',
      trailing: 'THIS MATCH',
      child: Column(children: [
        Row(children: [
          const SizedBox(width: 62),
          for (final h in hs) ...[
            Expanded(child: Text('$h',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: h == next ? FontWeight.w700 : FontWeight.w400,
                    color: h == next ? Halved.deepPine : Halved.muted))),
          ],
          const SizedBox(width: 26),
        ]),
        const SizedBox(height: 6),
        for (final pid in sideA) _playerRow(pid, hs, next),
        if (sideA.isNotEmpty && sideB.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 1, color: Halved.cardBorder),
          ),
        for (final pid in sideB) _playerRow(pid, hs, next),
        const SizedBox(height: 10),
        Text(
          '${match.sideLabel(true)} get ${totalFor(sideA)} · '
          '${match.sideLabel(false)} get ${totalFor(sideB)} in this match',
          style: const TextStyle(fontSize: 11, color: Halved.muted),
        ),
      ]),
    );
  }

  Widget _playerRow(int pid, List<int> hs, int? next) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
            width: 62,
            child: Text(_name(pid),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: Halved.deepPine)),
          ),
          for (final h in hs)
            Expanded(child: Center(child: _dot(_strokes(pid, h), _played(h)))),
          SizedBox(
            width: 26,
            child: Text(
                '${hs.fold(0, (a, h) => a + _strokes(pid, h))}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700,
                    color: Halved.deepPine)),
          ),
        ]),
      );

  /// A stroke on a hole already played is OUTLINED rather than filled — it
  /// happened, and the filled dots are the ones still to come.
  static Widget _dot(int strokes, bool played) {
    if (strokes <= 0) return const SizedBox(width: 9, height: 9);
    return Container(
      width: 9, height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: played ? Colors.transparent : Halved.brightMint,
        border: played
            ? Border.all(color: Halved.brightMint, width: 1.4)
            : null,
      ),
    );
  }
}

/// What each golfer is up or down, and which match did it.
///
/// Money is **per match**: the winning side's two golfers each take the
/// stake from the losing side's two, and a pushed match pays nobody. So a
/// row's three marks and its figure are the same fact twice — which is the
/// point, because the argument afterwards is never the total, it is which
/// match it came from.
class _Ledger extends StatelessWidget {
  final SixesSummary summary;
  final List<SixesMatch> matches;
  const _Ledger({required this.summary, required this.matches});

  /// `+` won, `−` lost, `=` level, `·` not started.
  ///
  /// Null when the golfer is not in that match at all, which cannot happen
  /// in a standard four-ball Sixes — every golfer plays every match — but a
  /// spawned extra or a withdrawal can leave a side short, and an invented
  /// mark would read as a result.
  String? _mark(int pid, SixesMatch m) {
    final inA = m.seg.team1.playerIds.contains(pid);
    final inB = m.seg.team2.playerIds.contains(pid);
    if (!inA && !inB) return null;
    if (!m.drawn || m.seg.status == 'pending') return '·';
    if (!m.isDone) {
      if (m.margin == 0) return '=';
      return (m.margin > 0) == inA ? '+' : '−';
    }
    if (m.seg.winner == 'Halved' || m.margin == 0) return '=';
    return (m.margin > 0) == inA ? '+' : '−';
  }

  @override
  Widget build(BuildContext context) {
    final players = [...summary.players];
    if (players.isEmpty) return const SizedBox.shrink();

    double moneyOf(Map<String, dynamic> p) =>
        summary.moneyByPlayer[(p['player_id'] as num?)?.toInt() ?? -1] ?? 0;
    players.sort((a, b) => moneyOf(b).compareTo(moneyOf(a)));

    final settled = matches.where((m) => m.isDone).length;
    final left = matches.fold<int>(0, (a, m) => a + m.toPlay);
    final allDone = settled == matches.length;

    Widget band(String leftText, String rightText) => Container(
          width: double.infinity,
          color: Halved.deepPine,
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Row(children: [
            Text(leftText,
                style: const TextStyle(
                    color: Halved.cream, fontSize: 11,
                    fontWeight: FontWeight.w700, letterSpacing: 0.6)),
            const Spacer(),
            Text(rightText,
                style: const TextStyle(color: Halved.cream, fontSize: 11)),
          ]),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(children: [
        band(allDone ? 'FINAL, EACH' : 'EACH · NOW',
            summary.betUnit <= 0
                ? ''
                : '\$${summary.betUnit.toStringAsFixed(0)} a match'),
        Container(
          color: Halved.card,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(children: [
            Row(children: [
              const Expanded(child: Text('Player',
                  style: TextStyle(fontSize: 10, color: Halved.muted))),
              for (final m in matches)
                SizedBox(width: 30, child: Text(m.seg.label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10, color: Halved.muted))),
              const SizedBox(width: 56, child: Text('\$',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10, color: Halved.muted))),
            ]),
            const SizedBox(height: 4),
            for (final p in players) _row(p, moneyOf(p)),
          ]),
        ),
        band(allDone ? 'Final' : 'Settled $settled of ${matches.length}',
            allDone ? '' : 'Left $left holes'),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> p, double money) {
    final pid = (p['player_id'] as num?)?.toInt() ?? -1;
    final full = (p['name'] ?? '').toString().trim();
    final parts = full.split(' ');
    final first = parts.isEmpty ? '' : parts.first;
    final last = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    final up = money > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: first,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: Halved.deepPine)),
              if (last.isNotEmpty)
                TextSpan(text: ' $last',
                    style: const TextStyle(color: Halved.muted)),
            ]),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final m in matches)
          SizedBox(width: 30, child: Center(
              child: _markChip(_mark(pid, m), m.isDone))),
        SizedBox(
          width: 56,
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                // A golfer who is UP gets the highlight. Down and level are
                // plain: the board is read by four men looking for who owes
                // whom, and highlighting a loss would be a different screen.
                color: up
                    ? Halved.brightMint.withValues(alpha: 0.30)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_moneyLabel(money),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700,
                      color: Halved.deepPine)),
            ),
          ),
        ),
      ]),
    );
  }

  static String _moneyLabel(double m) {
    if (m == 0) return '—';
    final a = m.abs().toStringAsFixed(m.abs() % 1 == 0 ? 0 : 2);
    return m > 0 ? '+\$$a' : '−\$$a';
  }

  /// Filled once the match is final, outlined while it is still live — the
  /// same distinction the prize column makes everywhere else in the app.
  static Widget _markChip(String? mark, bool done) {
    if (mark == null) return const SizedBox.shrink();
    final isResult = mark == '+' || mark == '−';
    final colour = switch (mark) {
      '+' => _sideA,
      '−' => _sideB,
      _ => Halved.muted,
    };
    return Container(
      width: 20, height: 20,
      decoration: BoxDecoration(
        color: done && isResult ? colour : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: done && isResult
            ? null
            : Border.all(color: colour.withValues(alpha: 0.6)),
      ),
      alignment: Alignment.center,
      child: Text(mark,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: done && isResult ? Halved.cream : colour)),
    );
  }
}
