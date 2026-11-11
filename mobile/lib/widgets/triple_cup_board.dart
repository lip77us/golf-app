import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'hole_grid_scorecard.dart';
import 'triple_cup_entry.dart';

/// TripleCupBoard — the leaderboard for one Triple Cup group
/// (`handoff-triple-cup-score-entry`, 11 Nov 2026).
///
/// **The cup, the matches and the money that left score entry.** One widget
/// for every Triple Cup leaderboard, casual or team: in a team cup it is
/// drawn once a group, under the cup's own scoreboard.
///
/// **It reads `group['board']` and composes nothing.** The server writes
/// every line with the same function the score-entry tray uses, so the tray
/// on the 18th and this board cannot say one match two ways. A payload with
/// no `board` (an older server) draws nothing, and the caller falls back.
class TripleCupBoard extends StatelessWidget {
  final Map<String, dynamic> group;

  /// A line over the board naming the group — `Group 2 · 8:20 AM`, and
  /// `Your group` where it is. Null on a one-group round.
  final String? heading;
  final bool mine;

  const TripleCupBoard({
    super.key,
    required this.group,
    this.heading,
    this.mine = false,
  });

  static bool canDraw(Map<String, dynamic> group) {
    final b = group['board'];
    return b is Map && (b['blocks'] as List?)?.isNotEmpty == true;
  }

  Map<String, dynamic> get _board =>
      (group['board'] as Map).cast<String, dynamic>();

  Color _c(int side) {
    final cols = (_board['team_colours'] as List?) ?? const [null, null];
    return tripleCupSideColour(
        cols.length >= side ? cols[side - 1] as String? : null, side);
  }

  @override
  Widget build(BuildContext context) {
    final b = _board;
    final money = (b['money'] as Map?)?.cast<String, dynamic>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (heading != null) ...[
            Row(children: [
              Expanded(
                child: Text(heading!,
                    style: const TextStyle(
                        color: Halved.deepPine,
                        fontSize: 15,
                        fontWeight: FontWeight.w800)),
              ),
              if (mine)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Halved.pine,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('YOUR GROUP',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          letterSpacing: 0.6,
                          fontWeight: FontWeight.w800)),
                ),
            ]),
            const SizedBox(height: 8),
          ],
          _cup((b['cup'] as Map).cast<String, dynamic>()),
          const SizedBox(height: 10),
          _matches((b['blocks'] as List).cast<Map>()),
          if (money != null) ...[
            const SizedBox(height: 10),
            _money(money),
          ],
        ],
      ),
    );
  }

  static const _label = TextStyle(
      color: Halved.muted,
      fontSize: 11,
      letterSpacing: 0.8,
      fontWeight: FontWeight.w700);

  // ── 1 · The cup ─────────────────────────────────────────────────────────

  Widget _cup(Map<String, dynamic> cup) {
    final names = (_board['team_names'] as List).map((e) => '$e').toList();
    final over = cup['over'] == true;
    TextStyle score(int side) => TextStyle(
        color: _c(side),
        fontSize: 40,
        height: 1.0,
        fontWeight: FontWeight.w800);
    TextStyle name(int side) => TextStyle(
        color: _c(side),
        fontSize: 13,
        letterSpacing: 0.4,
        fontWeight: FontWeight.w800);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
        // Deep pine while the cup is live; an ordinary card once it is over.
        border: Border.all(
            color: over ? Halved.cardBorder : Halved.deepPine,
            width: over ? 1 : 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${cup['label']}'.toUpperCase(),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: _label),
          ),
          Text('${cup['right'] ?? ''}'.toUpperCase(), style: _label),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${cup['team1']}', style: score(1)),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(names[0].toUpperCase(),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: name(1)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(names[1].toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: name(2)),
            ),
          ),
          const SizedBox(width: 8),
          Text('${cup['team2']}', style: score(2)),
        ]),
        const SizedBox(height: 6),
        CupStrip(
          team1: (cup['team1_points'] as num?)?.toDouble() ?? 0,
          team2: (cup['team2_points'] as num?)?.toDouble() ?? 0,
          cells: ((cup['total'] as num?) ?? 4).round().clamp(1, 12),
          colour1: _c(1),
          colour2: _c(2),
          empty: const Color(0xFFE3E9E4),
          tick: Halved.deepPine,
          height: 12,
        ),
        const SizedBox(height: 6),
        Text('${cup['line'] ?? ''}',
            style: const TextStyle(
                color: Halved.deepPine,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }

  // ── 2 · Matches ─────────────────────────────────────────────────────────

  Widget _matches(List<Map> blocks) => Container(
        decoration: BoxDecoration(
          color: Halved.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Halved.cardBorder),
        ),
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(children: [
              Expanded(child: Text('MATCHES', style: _label)),
              Text('HOLE WON BY SIDE', style: _label),
            ]),
          ),
          for (final b in blocks) ...[
            const Divider(height: 1, color: Halved.cardBorder),
            _block(b.cast<String, dynamic>()),
          ],
        ]),
      );

  Widget _block(Map<String, dynamic> b) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text('${b['label']}',
                  style: const TextStyle(
                      color: Halved.deepPine,
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${b['sub'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Halved.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 8),
              _tag('${b['tag']}'),
            ]),
            for (final l in (b['lines'] as List).cast<Map>()) ...[
              const SizedBox(height: 8),
              _line(l.cast<String, dynamic>()),
            ],
          ],
        ),
      );

  Widget _tag(String tag) {
    final text = Text(tag.toUpperCase(),
        style: TextStyle(
            color: tag == 'playing' ? Colors.white : Halved.muted,
            fontSize: 10,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w800));
    const pad = EdgeInsets.symmetric(horizontal: 8, vertical: 3);
    if (tag == 'to come') {
      return CustomPaint(
        painter: const DashedRRect(
            color: Halved.cardBorder, width: 1.2, radius: 999),
        child: Padding(padding: pad, child: text),
      );
    }
    return Container(
      padding: pad,
      decoration: BoxDecoration(
        color: tag == 'playing' ? Halved.pine : const Color(0xFFE3E9E4),
        borderRadius: BorderRadius.circular(999),
      ),
      child: text,
    );
  }

  Widget _line(Map<String, dynamic> l) {
    final names = (l['names'] as List).map((e) => '$e').toList();
    final leader = l['leader'] as int?;
    final head = '${l['head'] ?? ''}';
    final margin = '${l['margin'] ?? ''}';
    final state = [head, margin].where((s) => s.isNotEmpty).join(' ');
    final tiles = (l['tiles'] as List? ?? const []).cast<Map>();
    return LayoutBuilder(builder: (context, box) {
      final maxWidth = box.maxWidth;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // One flexible child: the sides yield, the state never does.
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: names[0], style: TextStyle(color: _c(1))),
                const TextSpan(
                    text: ' v ', style: TextStyle(color: Halved.muted)),
                TextSpan(text: names[1], style: TextStyle(color: _c(2))),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          // Capped, and it scales rather than spilling: the state is the
          // figure the row exists for, so it shrinks before it is cut.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth * 0.62),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (state.isNotEmpty)
                  Text(state,
                      style: TextStyle(
                          color: leader == null ? Halved.deepPine : _c(leader),
                          fontSize: 14,
                          fontWeight: FontWeight.w800)),
                Text('${l['sub'] ?? ''}',
                    style: TextStyle(
                        color: Halved.muted,
                        fontSize: state.isEmpty ? 14 : 12,
                        fontWeight:
                            state.isEmpty ? FontWeight.w700 : FontWeight.w500)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(child: _tile(tiles[i].cast<String, dynamic>())),
          ],
        ]),
      ]);
    });
  }

  Widget _tile(Map<String, dynamic> t) {
    final state = '${t['state']}';
    final text = Text('${t['hole']}',
        style: TextStyle(
            color: state == 't1' || state == 't2'
                ? Colors.white
                : state == 'halved'
                    ? Halved.deepPine
                    : Halved.disabledText,
            fontSize: 12,
            fontWeight: FontWeight.w700));
    if (state == 'open' || state == 'dead') {
      return Opacity(
        opacity: state == 'dead' ? 0.45 : 1,
        child: CustomPaint(
          painter: const DashedRRect(
              color: Halved.cardBorder, width: 1.2, radius: 7),
          child: SizedBox(height: 26, child: Center(child: text)),
        ),
      );
    }
    return Container(
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: state == 't1'
            ? _c(1)
            : state == 't2'
                ? _c(2)
                : const Color(0xFFBCC8C0),
        borderRadius: BorderRadius.circular(7),
      ),
      child: text,
    );
  }

  // ── 4 · Money (a casual cup only) ───────────────────────────────────────

  Widget _money(Map<String, dynamic> m) {
    final isFinal = m['final'] == true;
    final winner = m['winner'] as int?;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Halved.cardBorder),
      ),
      child: !isFinal
          ? Row(children: [
              Expanded(
                child: Text('${m['line']}',
                    style: const TextStyle(
                        color: Halved.deepPine,
                        fontSize: 13,
                        height: 1.3,
                        fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 12),
              Text('${m['pot'] ?? ''}',
                  style: const TextStyle(
                      color: Halved.deepPine,
                      fontSize: 18,
                      fontWeight: FontWeight.w800)),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text('${m['label']}'.toUpperCase(), style: _label),
                ),
                Text('${m['stake']}'.toUpperCase(), style: _label),
              ]),
              const SizedBox(height: 6),
              if (winner != null)
                Row(children: [
                  Flexible(
                    child: Text('${m['head']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _c(winner),
                            fontSize: 16,
                            fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 10),
                  Text('${m['amount']}',
                      style: const TextStyle(
                          color: Halved.pine,
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                ]),
              if (winner != null) const SizedBox(height: 3),
              Text('${m['line']}',
                  style: TextStyle(
                      color: winner == null ? Halved.deepPine : Halved.muted,
                      fontSize: winner == null ? 15 : 13,
                      fontWeight: FontWeight.w600)),
            ]),
    );
  }
}

/// One segment of the scorecard, ready for [HoleGridScorecard].
typedef TripleCupCardBlock = ({
  String title,
  List<int> holes,
  List<Map<String, dynamic>> rows,
  List<Map<String, dynamic>> players,
});

/// The scorecard's three blocks, built from the summary's own per-match
/// hole data.
///
/// Pure, so the rules are testable without a widget:
///
/// * **Fourball and Singles** are a row a golfer; the Singles run in match
///   order (Paul, Pete, Hal, Wendy).
/// * **Foursomes is a row a SIDE** — one ball, the side's gross and the
///   side's strokes.
/// * A cell carries `won_team` when that score won the hole for its side:
///   the better ball in the Fourball (the server's `won`), the side's ball
///   in the Foursomes, the winner in a Single. A halved hole marks nothing.
/// * Strokes ride on every hole, played or not, so the card shows the whole
///   plan from the first tee.
List<TripleCupCardBlock> tripleCupScorecardBlocks(
    Map<String, dynamic> summary) {
  final matches =
      (summary['matches'] as List? ?? const []).cast<Map<String, dynamic>>();
  final bySegment = <String, List<Map<String, dynamic>>>{};
  final order = <String>[];
  for (final m in matches) {
    final seg = '${m['segment']}';
    if (!bySegment.containsKey(seg)) order.add(seg);
    bySegment.putIfAbsent(seg, () => []).add(m);
  }
  String first(String name) => name.trim().split(RegExp(r'\s+')).first;

  final out = <TripleCupCardBlock>[];
  for (final seg in order) {
    final ms = bySegment[seg]!;
    final holeNos = <int>[];
    final rowsByHole = <int, Map<String, dynamic>>{};
    final players = <Map<String, dynamic>>[];
    final seen = <int>{};

    for (final m in ms) {
      final teamOf = <int, int>{
        for (final p in (m['players'] as List).cast<Map>())
          p['player_id'] as int: p['team_number'] as int,
      };
      if (seg == 'foursomes') {
        for (final side in [1, 2]) {
          final id = -(m['match_number'] as int) * 10 - side;
          final names = [
            for (final p in (m['players'] as List).cast<Map>())
              if (p['team_number'] == side && p['is_phantom'] != true)
                first('${p['name']}'),
          ];
          if (seen.add(id)) {
            players.add({
              'player_id': id,
              'name': names.join(' & '),
              'short_name': names.join(' & '),
              'team': side,
            });
          }
        }
      } else {
        for (final p in (m['players'] as List).cast<Map>()) {
          final id = p['player_id'] as int;
          if (!seen.add(id)) continue;
          final phantom = p['is_phantom'] == true;
          players.add({
            'player_id': id,
            'name': phantom ? 'Phantom' : first('${p['name']}'),
            'short_name': phantom ? 'Phantom' : first('${p['name']}'),
            'team': p['team_number'],
          });
        }
      }

      for (final h in (m['holes'] as List).cast<Map>()) {
        final hole = h['hole'] as int;
        final row = rowsByHole.putIfAbsent(hole, () {
          holeNos.add(hole);
          return {
            'hole': hole,
            'par': h['par'],
            'stroke_index': h['stroke_index'],
            'winner_id': null,
            'scores': <Map<String, dynamic>>[],
          };
        });
        final scores = row['scores'] as List<Map<String, dynamic>>;
        final winner = h['winner'] == 'T1'
            ? 1
            : h['winner'] == 'T2'
                ? 2
                : null;
        if (seg == 'foursomes') {
          for (final side in [1, 2]) {
            // Where the engine states no side figure, the partners carry
            // the same allocation — take the larger.
            var strokes = (h['t${side}_team_strokes'] as num?)?.toInt();
            strokes ??= [
              0,
              for (final s in (h['scores'] as List).cast<Map>())
                if (teamOf[s['player_id']] == side)
                  (s['strokes'] as num?)?.toInt() ?? 0,
            ].reduce((a, b) => a > b ? a : b);
            scores.add({
              'player_id': -(m['match_number'] as int) * 10 - side,
              'gross': h['t${side}_team_gross'],
              'strokes': strokes,
              if (winner == side) 'won_team': side,
            });
          }
        } else {
          for (final s in (h['scores'] as List).cast<Map>()) {
            final team = teamOf[s['player_id']];
            // An older payload sends no `won`: tint the winning side.
            final won = s.containsKey('won')
                ? s['won'] == true
                : (winner != null && team == winner);
            scores.add({
              'player_id': s['player_id'],
              'gross': s['gross'],
              'strokes': s['strokes'],
              if (won && winner != null) 'won_team': winner,
            });
          }
        }
      }
    }

    final span = holeNos.isEmpty
        ? ''
        : (holeNos.length > 1 &&
                holeNos.last == holeNos.first + holeNos.length - 1)
            ? 'holes ${holeNos.first}–${holeNos.last}'
            : '';
    final label =
        seg.isEmpty ? '' : '${seg[0].toUpperCase()}${seg.substring(1)}';
    out.add((
      title: span.isEmpty ? label : '$label · $span',
      holes: holeNos,
      rows: [for (final h in holeNos) rowsByHole[h]!],
      players: players,
    ));
  }
  return out;
}

/// The Scorecard tab: three blocks of six holes, in segment order, each the
/// app's own scorecard.
class TripleCupScorecard extends StatelessWidget {
  final Map<String, dynamic> group;

  /// `Scorecard · your group` in a team cup.
  final String heading;

  const TripleCupScorecard({
    super.key,
    required this.group,
    this.heading = 'Scorecard',
  });

  @override
  Widget build(BuildContext context) {
    final summary =
        (group['summary'] as Map? ?? const {}).cast<String, dynamic>();
    final board = (group['board'] as Map?)?.cast<String, dynamic>();
    final cols = (summary['team_colours'] as List?) ??
        [summary['team1_colour'], summary['team2_colour']];
    final colours = {
      1: tripleCupSideColour(cols[0] as String?, 1),
      2: tripleCupSideColour(cols[1] as String?, 2),
    };
    final blocks = tripleCupScorecardBlocks(summary);
    final thru = board == null
        ? ''
        : (board['over'] == true ? 'final' : 'thru ${board['thru']}');
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Row(children: [
            Expanded(
              child: Text(heading.toUpperCase(), style: TripleCupBoard._label),
            ),
            Text(thru.toUpperCase(), style: TripleCupBoard._label),
          ]),
        ),
        for (final b in blocks) ...[
          HoleGridScorecard(
            title: b.title,
            holes: b.rows,
            participants: b.players,
            holesInPlay: b.holes,
            wonColours: colours,
            // Six holes: an OUT after the 9th would be a sum of nothing.
            nineTotals: false,
            legend: null,
            // The dots are on the cells, on unplayed holes too.
            showStrokes: false,
          ),
          const SizedBox(height: 10),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 4, 0),
          child: Text(
            'Gross scores. A shaded score won the hole for its side. A dot '
            'is a stroke received on that hole for that segment, shown on '
            'holes not yet played too, so everyone can see where the '
            'strokes fall.',
            style: TextStyle(color: Halved.muted, fontSize: 12, height: 1.35),
          ),
        ),
      ],
    );
  }
}
