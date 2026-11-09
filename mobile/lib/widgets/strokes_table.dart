import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// Where every golfer strokes, as a grid: one row a golfer, one dot a
/// stroke, a total down the right.
///
/// **A scorecard already carries stroke dots on the score cells, and that is
/// not the same question.** A dot on a cell says *this score was made with a
/// shot*; a reader asking "where do I stroke" is looking ahead, at holes
/// with no score on them yet, and has to pick the dots out of a grid of
/// numbers to do it. Sixes and Sequoya each grew a table of their own for
/// exactly that; this is that table, once, for every game (Paul, 8 Nov
/// 2026: *"I suspect we will want to make it universal for all non-gross
/// games."*).
///
/// **It gates itself on the strokes, not on a list of games.** A gross game
/// allocates none, so the table is empty and does not draw — which means a
/// game added tomorrow is covered without anybody remembering to add it,
/// and a round played off scratch does not carry eighteen blank cells.
class StrokesTable extends StatelessWidget {
  /// The scorecard's own per-hole payload:
  /// `{hole, scores: [{player_id, strokes}, …]}` — the same list
  /// [HoleGridScorecard] draws, so a board that has one of those has this.
  final List<Map<String, dynamic>> holes;

  /// `{player_id, short_name | name}`, in the order the rows should read.
  final List<Map<String, dynamic>> participants;

  /// The columns, in play order. Empty falls back to the order `holes`
  /// arrives in, which the server already sends shotgun-safe.
  final List<int> holesInPlay;

  /// Player ids grouped into sides, drawn with a rule between them. Null
  /// draws one block — which is every game that is not played in teams.
  final List<List<int>>? sides;

  /// A sentence under the grid, e.g. `Paul & Dave get 1 · Sam & Lee get 4`.
  final String? footer;

  /// The card's right-hand label.
  final String trailing;

  const StrokesTable({
    super.key,
    required this.holes,
    required this.participants,
    this.holesInPlay = const [],
    this.sides,
    this.footer,
    this.trailing = 'THIS ROUND',
  });

  /// The hole columns, in the order they are played.
  List<int> get _cols {
    if (holesInPlay.isNotEmpty) return holesInPlay;
    return [
      for (final h in holes)
        if ((h['hole'] as num?) != null) (h['hole'] as num).toInt(),
    ];
  }

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

  String _name(int pid) {
    for (final p in participants) {
      if ((p['player_id'] as num?)?.toInt() != pid) continue;
      final s = (p['short_name'] ?? p['name'])?.toString();
      if (s != null && s.isNotEmpty) return s;
    }
    return '';
  }

  int _total(int pid, List<int> cols) =>
      cols.fold(0, (a, h) => a + _strokes(pid, h));

  /// Nobody strokes — see the class doc. This is the gate.
  bool get isEmpty {
    final cols = _cols;
    for (final p in participants) {
      final pid = (p['player_id'] as num?)?.toInt();
      if (pid != null && _total(pid, cols) > 0) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final cols = _cols;
    if (cols.isEmpty || isEmpty) return const SizedBox.shrink();

    final groups = sides ??
        [[
          for (final p in participants)
            if ((p['player_id'] as num?) != null)
              (p['player_id'] as num).toInt(),
        ]];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Halved.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('STROKES',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 0.7, color: Halved.deepPine)),
          ),
          Text(trailing,
              style: const TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: Halved.muted)),
        ]),
        const SizedBox(height: 10),
        _header(cols),
        const SizedBox(height: 6),
        for (var g = 0; g < groups.length; g++) ...[
          if (g > 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Divider(height: 1, color: Halved.cardBorder),
            ),
          for (final pid in groups[g]) _row(pid, cols),
        ],
        if (footer != null && footer!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(footer!,
              style: const TextStyle(fontSize: 11, color: Halved.muted)),
        ],
      ]),
    );
  }

  Widget _header(List<int> cols) => Row(children: [
        const SizedBox(width: 62),
        for (final h in cols)
          Expanded(
            child: Text('$h',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Halved.muted)),
          ),
        const SizedBox(width: 26),
      ]);

  Widget _row(int pid, List<int> cols) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
            width: 62,
            child: Text(_name(pid),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: Halved.deepPine)),
          ),
          for (final h in cols)
            Expanded(child: Center(child: _dot(_strokes(pid, h)))),
          SizedBox(
            width: 26,
            child: Text('${_total(pid, cols)}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700,
                    color: Halved.deepPine)),
          ),
        ]),
      );

  /// **Every stroke is a filled dot** (Paul, 30 Oct 2026: *"just leave them
  /// all filled in"*).
  ///
  /// A spent stroke used to be drawn hollow, on the reasoning that the
  /// filled ones are the strokes still to come. Nobody could read it — the
  /// question that retired it was *"what are the closed circles vs the open
  /// circles"* — and it INVERTED this app's own vocabulary, where filled
  /// means settled and outlined means still live.
  ///
  /// Two strokes on one hole are two dots, because a golfer who gets two
  /// there needs to see two.
  static Widget _dot(int strokes) {
    if (strokes <= 0) return const SizedBox(width: 9, height: 9);
    // **One stroke keeps the 9px dot** the Sixes card has always drawn;
    // only a doubled hole shrinks, so the common case does not change size
    // to make room for a case that is rare.
    if (strokes == 1) return _one(9);
    return Wrap(
      spacing: 2,
      alignment: WrapAlignment.center,
      children: [for (var i = 0; i < strokes; i++) _one(7)],
    );
  }

  /// **Bright mint**, the colour the Sixes card already used. Not deep
  /// pine: this app already draws stroke dots in two places (this table and
  /// the red ones over a score box), and a third ink for one fact is one
  /// too many.
  static Widget _one(double d) => Container(
        width: d, height: d,
        decoration: const BoxDecoration(
            color: Halved.brightMint, shape: BoxShape.circle),
      );
}
