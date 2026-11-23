/// widgets/swat_gross_board.dart
/// -----------------------------
/// Oakmont SWAT's Gross tab (docs/design-review/handoff-oakmont-swat, shots
/// 14–16). **By team** works in three levels: the ranked list, a team opened
/// to its golfers, and the stacked hole-by-hole scorecard. **By player** lists
/// every golfer with his band.
///
/// The server ranks and supplies every figure; this widget only lays them out.
/// The phantom shows as a row of scores with no name, and the donor's initials
/// appear under each score only once the server sends `phantom_donors` — that
/// is, once every group has finished.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import 'forty_balls_keypad.dart' show ScoreNotation, ScoreShape, shapeForScore;

class SwatGrossBoard extends StatefulWidget {
  final Map<String, dynamic> data;
  const SwatGrossBoard({super.key, required this.data});

  @override
  State<SwatGrossBoard> createState() => _SwatGrossBoardState();
}

class _SwatGrossBoardState extends State<SwatGrossBoard> {
  bool _byTeam = true;
  bool _sortByName = false;
  int? _open;          // the team opened to its golfers
  bool _card = false;  // …and to its scorecard

  List<Map> get _teams =>
      [for (final t in (widget.data['teams'] as List? ?? const [])) t as Map];
  List<Map> get _players =>
      [for (final p in (widget.data['players'] as List? ?? const [])) p as Map];

  /// JSON object keys are strings; the model's are holes.
  static int? _at(Map? m, int hole) {
    if (m == null) return null;
    final v = m[hole] ?? m['$hole'];
    return v is num ? v.toInt() : null;
  }

  static String? _atS(Map? m, int hole) {
    if (m == null) return null;
    final v = m[hole] ?? m['$hole'];
    return v?.toString();
  }

  String _toPar(int v) => v == 0 ? 'E' : (v > 0 ? '+$v' : '−${v.abs()}');

  @override
  Widget build(BuildContext context) {
    if (_teams.isEmpty) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('The teams have not been drawn yet.')));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('By team')),
              ButtonSegment(value: false, label: Text('By player')),
            ],
            selected: {_byTeam},
            onSelectionChanged: (s) => setState(() => _byTeam = s.first),
          ),
        ),
        const SizedBox(height: 10),
        if (_byTeam) ..._teamView() else ..._playerView(),
      ],
    );
  }

  // ── By team ────────────────────────────────────────────────────────────

  List<Widget> _teamView() {
    final teams = [..._teams]..sort((a, b) {
        final pa = a['gross_place'] as int?, pb = b['gross_place'] as int?;
        if (pa == null && pb == null) return 0;
        if (pa == null) return 1;
        if (pb == null) return -1;
        return pa.compareTo(pb);
      });
    return [
      for (final t in teams)
        _box(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: () => setState(() {
                _open = _open == t['id'] ? null : t['id'] as int;
                _card = false;
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                      width: 32,
                      child: Text(
                          t['gross_place'] == null
                              ? '–'
                              : '${t['gross_tied'] == true ? 'T' : ''}${t['gross_place']}',
                          style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(
                      child: Text('${t['name']}',
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  SizedBox(
                      width: 40,
                      child: Text(t['finished'] == true ? 'F' : '${t['thru']}',
                          textAlign: TextAlign.center,
                          style: Halved.body(color: Halved.muted))),
                  SizedBox(
                      width: 44,
                      child: Text(
                          t['thru'] == 0 ? '–' : _toPar(t['best_to_par'] as int),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w800))),
                ]),
              ),
            ),
            if (_open == t['id']) ...[
              const Divider(height: 14),
              if (_card) _scorecard(t) else _totals(t),
            ],
          ]),
        ),
    ];
  }

  Widget _box({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Halved.cardBorder),
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      );

  Map? _playerRow(int id) {
    for (final p in _players) {
      if (p['id'] == id) return p;
    }
    return null;
  }

  Widget _totals(Map t) {
    final head = Halved.body(color: Halved.muted).copyWith(fontSize: 11);
    Widget row(String name, String thru, String gross, String par,
            {bool bold = false, bool dashed = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(
                child: Text(name,
                    style: TextStyle(
                        fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                        color: dashed ? Halved.muted : null))),
            SizedBox(width: 40, child: Text(thru, textAlign: TextAlign.center)),
            SizedBox(width: 48, child: Text(gross, textAlign: TextAlign.right)),
            SizedBox(width: 44, child: Text(par, textAlign: TextAlign.right)),
          ]),
        );
    final best = t['best'] as Map? ?? const {};
    final par = widget.data['par'] as Map?;
    var bestGross = 0;
    for (final e in best.entries) {
      bestGross += (e.value as num).toInt();
    }
    final ph = t['phantom'] as Map?;
    int phThru = 0, phGross = 0, phPar = 0;
    if (ph != null) {
      for (final e in ph.entries) {
        if (e.value != null) {
          phThru++;
          phGross += (e.value as num).toInt();
          phPar += _at(par, int.parse('${e.key}')) ?? 0;
        }
      }
    }
    return Column(children: [
      Row(children: [
        const Expanded(child: SizedBox()),
        SizedBox(width: 40, child: Text('THRU', textAlign: TextAlign.center, style: head)),
        SizedBox(width: 48, child: Text('GROSS', textAlign: TextAlign.right, style: head)),
        SizedBox(width: 44, child: Text('TO PAR', textAlign: TextAlign.right, style: head)),
      ]),
      for (final pl in t['players'] as List)
        Builder(builder: (_) {
          final r = _playerRow((pl as Map)['id'] as int);
          final thru = r?['thru'] as int? ?? 0;
          final g = r?['gross'] as int? ?? 0;
          final pr = r?['par'] as int? ?? 0;
          return row('${pl['name']}', thru == 0 ? '–' : '$thru',
              thru == 0 ? '–' : '$g', thru == 0 ? '–' : _toPar(g - pr));
        }),
      if (t['three'] == true)
        row('Phantom', phThru == 0 ? '–' : '$phThru',
            phThru == 0 ? '–' : '$phGross',
            phThru == 0 ? '–' : _toPar(phGross - phPar),
            dashed: true),
      const Divider(height: 10),
      row('Best ball', t['thru'] == 0 ? '–' : '${t['thru']}',
          t['thru'] == 0 ? '–' : '$bestGross',
          t['thru'] == 0 ? '–' : _toPar(t['best_to_par'] as int),
          bold: true),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
            onPressed: () => setState(() => _card = true),
            child: const Text('Hole by hole ›')),
      ),
    ]);
  }

  // ── The stacked scorecard ──────────────────────────────────────────────

  Widget _scorecard(Map t) {
    final par = widget.data['par'] as Map?;
    final si = widget.data['si'] as Map?;
    final best = t['best'] as Map? ?? const {};
    final phantom = t['phantom'] as Map?;
    final donors = t['phantom_donors'] as Map?;
    final players = [for (final p in t['players'] as List) p as Map];
    return LayoutBuilder(builder: (ctx, c) {
      const labelW = 58.0;
      final cellW = (c.maxWidth - labelW) / 10;     // 9 holes + a total
      Widget cell(Widget child, {Color? fill, bool head = false}) => Container(
            width: cellW,
            height: 26,
            alignment: Alignment.center,
            color: fill,
            child: child,
          );
      Widget txt(String s, {bool bold = false, Color? color, double size = 11.5}) =>
          Text(s, style: TextStyle(
              fontSize: size,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
              color: color));

      Widget half(int from, String sumLabel, {bool total = false}) {
        final holes = [for (var h = from; h < from + 9; h++) h];
        Widget labelCell(String s, {bool bold = false}) => SizedBox(
            width: labelW,
            height: 26,
            child: Align(
                alignment: Alignment.centerLeft,
                child: Text(s,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: bold ? FontWeight.w800 : FontWeight.w600))));

        final cs = Theme.of(ctx).colorScheme;
        Widget numRow(String label, int? Function(int) val) => Container(
            color: cs.surfaceContainerLow,
            child: Row(children: [
              labelCell(label),
              for (final h in holes)
                cell(txt(val(h)?.toString() ?? '', color: Halved.muted)),
              cell(txt('')),
            ]));

        int? sum(int? Function(int) v) {
          var s = 0;
          for (final h in holes) {
            final x = v(h);
            if (x == null) return null;
            s += x;
          }
          return s;
        }

        List<Widget> scoreRow(String label, int? Function(int) val,
            {bool isBest = false, bool isPhantom = false}) {
          final cells = <Widget>[];
          for (final h in holes) {
            final g = val(h);
            final b = _at(best, h);
            final counted = g != null && b != null && g == b && !isBest;
            Widget inner;
            if (g == null) {
              inner = const SizedBox();
            } else if (isBest) {
              // Birdie and bogey keep their shapes; par is just the number.
              final par = _at(widget.data['par'] as Map?, h) ?? 4;
              inner = shapeForScore(g, par) == ScoreShape.par
                  ? txt('$g', bold: true, size: 13)
                  : ScoreNotation(
                      score: g,
                      par: par,
                      width: cellW - 4,
                      height: 22,
                      fontSize: 11,
                      cornerRadius: 4);
            } else {
              inner = txt('$g', bold: counted);
            }
            cells.add(cell(inner,
                fill: counted ? Halved.brightMint.withValues(alpha: 0.28) : null));
          }
          final s = sum(val);
          Widget row = Row(children: [
            labelCell(label, bold: isBest),
            ...cells,
            cell(txt(s?.toString() ?? '', bold: true)),
          ]);
          if (isBest) {
            // The team's score stands apart without a shape: a rule above it.
            row = Container(
                decoration: BoxDecoration(
                    border: Border(
                        top: BorderSide(color: cs.outline, width: 1.5))),
                child: row);
          }
          if (isPhantom && donors != null) {
            return [
              row,
              Row(children: [
                const SizedBox(width: labelW),
                for (final h in holes)
                  SizedBox(
                      width: cellW,
                      child: Center(
                          child: Text(_atS(donors, h) ?? '',
                              style: Halved.body(color: Halved.muted)
                                  .copyWith(fontSize: 8.5)))),
                SizedBox(width: cellW),
              ]),
            ];
          }
          return [row];
        }

        return Column(children: [
          Container(
              color: cs.surfaceContainerHighest,
              child: Row(children: [
                labelCell('Hole', bold: true),
                for (final h in holes) cell(txt('$h', bold: true)),
                cell(txt(sumLabel, bold: true)),
              ])),
          numRow('Par', (h) => _at(par, h)),
          numRow('Index', (h) => _at(si, h)),
          for (final p in players)
            ...scoreRow('${p['short'] ?? p['name']}',
                (h) => _at((_playerRow(p['id'] as int)?['holes']) as Map?, h)),
          if (phantom != null)
            ...scoreRow('Phantom', (h) => _at(phantom, h), isPhantom: true),
          ...scoreRow('Best', (h) => _at(best, h), isBest: true),
        ]);
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        half(1, 'OUT'),
        const SizedBox(height: 10),
        half(10, 'IN'),
        const SizedBox(height: 6),
        Text(
            donors == null
                ? 'The phantom is a bottom golfer from another team. Whose '
                    'score it was is shown here once every group has finished.'
                : 'Initials under each phantom score are the golfer whose '
                    'ball it was.',
            style: Halved.body(color: Halved.muted).copyWith(fontSize: 11)),
        TextButton(
            onPressed: () => setState(() => _card = false),
            child: const Text('◂ Back to the totals')),
      ]);
    });
  }

  // ── By player ──────────────────────────────────────────────────────────

  List<Widget> _playerView() {
    final players = [..._players];
    if (_sortByName) {
      // By last name, then first: the order a list of golfers is read in.
      String key(Map p) {
        final parts = '${p['name']}'.trim().split(RegExp(r'\s+'));
        final last = parts.last.toLowerCase();
        final first = parts.length > 1 ? parts.first.toLowerCase() : '';
        return '$last\u0000$first';
      }

      players.sort((a, b) => key(a).compareTo(key(b)));
    } else {
      players.sort((a, b) {
        final ta = (a['thru'] as int) == 0, tb = (b['thru'] as int) == 0;
        if (ta != tb) return ta ? 1 : -1;
        final da = (a['gross'] as int) - (a['par'] as int);
        final db = (b['gross'] as int) - (b['par'] as int);
        return da.compareTo(db);
      });
    }
    return [
      Row(children: [
        Text('Sort', style: Halved.body(color: Halved.muted)),
        const SizedBox(width: 8),
        ChoiceChip(
            label: const Text('Score'),
            selected: !_sortByName,
            onSelected: (_) => setState(() => _sortByName = false)),
        const SizedBox(width: 6),
        ChoiceChip(
            label: const Text('Name'),
            selected: _sortByName,
            onSelected: (_) => setState(() => _sortByName = true)),
      ]),
      const SizedBox(height: 8),
      _box(
        child: Column(children: [
          Row(children: [
            const Expanded(child: SizedBox()),
            for (final h in const ['BAND', 'THRU', 'GROSS', 'PAR'])
              SizedBox(
                  width: 46,
                  child: Text(h,
                      textAlign: TextAlign.center,
                      style: Halved.body(color: Halved.muted)
                          .copyWith(fontSize: 10.5))),
          ]),
          for (final p in players)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('${p['name']}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${p['team']}',
                          style: Halved.body(color: Halved.muted)
                              .copyWith(fontSize: 11)),
                    ])),
                SizedBox(
                    width: 46,
                    child: Text('${p['band']}',
                        textAlign: TextAlign.center,
                        style: Halved.body(color: Halved.muted))),
                SizedBox(
                    width: 46,
                    child: Text((p['thru'] as int) == 0 ? '–' : '${p['thru']}',
                        textAlign: TextAlign.center)),
                SizedBox(
                    width: 46,
                    child: Text((p['thru'] as int) == 0 ? '–' : '${p['gross']}',
                        textAlign: TextAlign.center)),
                SizedBox(
                    width: 46,
                    child: Text(
                        (p['thru'] as int) == 0
                            ? '–'
                            : _toPar((p['gross'] as int) - (p['par'] as int)),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w700))),
              ]),
            ),
        ]),
      ),
    ];
  }
}
