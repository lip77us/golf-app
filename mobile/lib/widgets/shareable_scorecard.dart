/// widgets/shareable_scorecard.dart
/// --------------------------------
/// A portrait, iPhone-width scorecard laid out as TWO NINES stacked (Front 9,
/// then Back 9) so it fits a phone screen and captures cleanly to an image the
/// user can text to friends.  Pure/stateless — it takes already-loaded scorecard
/// data and renders it; capture + share lives in ShareScorecardScreen.
///
/// Styling mirrors the Stroke Play scorecard: a highlighted header row, thin
/// hole dividers (TableBorder), a tinted Par row, and tinted Out/In/Tot
/// subtotal columns.  Each nine shows Hole, Par, and one GROSS row per player;
/// a net totals summary (Out/In/Tot) follows.

import 'package:flutter/material.dart';

import '../api/models.dart';

class ShareableScorecard extends StatelessWidget {
  final String courseName;
  final String dateLabel;
  final String roundLabel;
  final List<ScorecardHole> holes;
  final List<PlayerTotals> totals;

  // Fixed render width — a phone-portrait-friendly ~380pt keeps the captured
  // image consistent regardless of the device screen. Column widths are sized
  // so both nines (9 holes + two subtotal columns) fit inside with margin.
  static const double _width = 380;
  static const double _holeW = 23;
  static const double _subW  = 32; // wide enough for bold "Out" / "Tot"
  static const double _nameW = 60;

  static const Color _pine     = Color(0xFF1E5C3F);
  static const Color _muted    = Color(0xFF6B7280);
  static const Color _line     = Color(0xFFD8DED9);
  static const Color _headerBg = Color(0xFFE7EEE9);
  static const Color _parBg    = Color(0xFFF3F6F4);
  static const Color _subBg    = Color(0xFFF1F5F2);
  static const Color _under    = Color(0xFFC62828); // birdie+ red

  const ShareableScorecard({
    super.key,
    required this.courseName,
    required this.dateLabel,
    required this.roundLabel,
    required this.holes,
    required this.totals,
  });

  List<ScorecardHole> get _front =>
      (holes.where((h) => h.holeNumber <= 9).toList()
        ..sort((a, b) => a.holeNumber.compareTo(b.holeNumber)));
  List<ScorecardHole> get _back =>
      (holes.where((h) => h.holeNumber >= 10).toList()
        ..sort((a, b) => a.holeNumber.compareTo(b.holeNumber)));

  int? _gross(int playerId, int hole) => holes
      .where((x) => x.holeNumber == hole)
      .firstOrNull
      ?.scores
      .where((s) => s.playerId == playerId)
      .firstOrNull
      ?.grossScore;

  static int _sumPar(List<ScorecardHole> hs) => hs.fold(0, (a, h) => a + h.par);

  static String _shortName(String full) {
    final parts = full.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return full;
    return '${parts.first} ${parts.last[0]}.';
  }

  // A single cell: padded, single-line text; optional own background.
  Widget _c(String t, {
    FontWeight w = FontWeight.w500,
    Color color = Colors.black87,
    TextAlign a = TextAlign.center,
    Color? bg,
  }) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
      child: Text(t,
          textAlign: a, maxLines: 1, overflow: TextOverflow.clip,
          style: TextStyle(
              fontSize: 12, height: 1.1, fontWeight: w, color: color)),
    );
    return bg == null ? child : Container(color: bg, child: child);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _width,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(courseName,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: _pine)),
          const SizedBox(height: 2),
          Text('$dateLabel   ·   $roundLabel',
              style: const TextStyle(fontSize: 12, color: _muted)),
          const SizedBox(height: 12),

          _nineTable(_front, isFront: true),
          const SizedBox(height: 10),
          _nineTable(_back, isFront: false),

          const SizedBox(height: 10),
          _netSummary(),

          const SizedBox(height: 10),
          const Center(
            child: Text('Halved',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w800, color: _pine)),
          ),
        ],
      ),
    );
  }

  // ── One nine: Hole / Par / a gross row per player, with subtotals. ─────────
  // Front carries [Out] plus a trailing blank column so it lines up under the
  // Back nine's [In, Tot].
  Widget _nineTable(List<ScorecardHole> nine, {required bool isFront}) {
    // subtotal columns: (label, per-player value or null for a blank spacer)
    final subLabels = isFront ? const ['Out', ''] : const ['In', 'Tot'];

    final colWidths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(_nameW),
      for (int i = 1; i <= nine.length; i++) i: const FixedColumnWidth(_holeW),
      for (int i = 0; i < subLabels.length; i++)
        1 + nine.length + i: const FixedColumnWidth(_subW),
    };

    String parSub(String label) {
      if (label == 'Tot') return '${_sumPar(_front) + _sumPar(_back)}';
      if (label == 'In' || label == 'Out') return '${_sumPar(nine)}';
      return '';
    }

    String playerSub(PlayerTotals t, String label) {
      switch (label) {
        case 'Out': return '${t.frontGross}';
        case 'In':  return '${t.backGross}';
        case 'Tot': return '${t.totalGross}';
        default:    return '';
      }
    }

    final header = TableRow(
      decoration: const BoxDecoration(color: _headerBg),
      children: [
        _c('Hole', w: FontWeight.w800, color: _muted, a: TextAlign.left),
        for (final h in nine) _c('${h.holeNumber}', w: FontWeight.w800, color: _muted),
        for (final s in subLabels)
          _c(s, w: FontWeight.w800, color: s.isEmpty ? _muted : _pine),
      ],
    );

    final parRow = TableRow(
      decoration: const BoxDecoration(color: _parBg),
      children: [
        _c('Par', color: _muted, a: TextAlign.left),
        for (final h in nine) _c('${h.par}', color: _muted),
        for (final s in subLabels) _c(parSub(s), w: FontWeight.w700, color: _muted),
      ],
    );

    final playerRows = <TableRow>[
      for (final t in totals)
        TableRow(children: [
          _c(_shortName(t.name), w: FontWeight.w600, a: TextAlign.left),
          for (final h in nine)
            () {
              final g = _gross(t.playerId, h.holeNumber);
              final under = g != null && g < h.par;
              return _c(g?.toString() ?? '–',
                  w: under ? FontWeight.w800 : FontWeight.w500,
                  color: under ? _under : Colors.black87);
            }(),
          for (final s in subLabels)
            _c(playerSub(t, s),
                w: FontWeight.w800, color: _pine, bg: s.isEmpty ? null : _subBg),
        ]),
    ];

    return Table(
      columnWidths: colWidths,
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(color: _line, width: 0.5),
      children: [header, parRow, ...playerRows],
    );
  }

  // ── Net totals (Out / In / Tot per player) — same highlighted style. ───────
  Widget _netSummary() {
    const nameW = 116.0, valW = 68.0; // 116 + 3×68 = 320 ≈ grid width

    final header = TableRow(
      decoration: const BoxDecoration(color: _headerBg),
      children: [
        _c('Net', w: FontWeight.w800, color: _pine, a: TextAlign.left),
        _c('Out', w: FontWeight.w800, color: _pine),
        _c('In',  w: FontWeight.w800, color: _pine),
        _c('Tot', w: FontWeight.w800, color: _pine),
      ],
    );

    final rows = <TableRow>[
      for (final t in totals)
        TableRow(children: [
          // Full name here (the net table has room); the grids use short names.
          _c(t.name, w: FontWeight.w600, a: TextAlign.left),
          _c('${t.frontNet}'),
          _c('${t.backNet}'),
          _c('${t.totalNet}', w: FontWeight.w800, color: _pine, bg: _subBg),
        ]),
    ];

    return Table(
      columnWidths: const {
        0: FixedColumnWidth(nameW),
        1: FixedColumnWidth(valW),
        2: FixedColumnWidth(valW),
        3: FixedColumnWidth(valW),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(color: _line, width: 0.5),
      children: [header, ...rows],
    );
  }
}
