/// widgets/shareable_scorecard.dart
/// --------------------------------
/// A portrait, iPhone-width scorecard laid out as TWO NINES stacked (Front 9,
/// then Back 9) so it fits a phone screen and captures cleanly to an image the
/// user can text to friends.  Pure/stateless — it takes already-loaded scorecard
/// data and renders it; capture + share lives in ShareScorecardScreen.
///
/// Each nine shows a Hole row, a Par row, and one GROSS row per player with the
/// nine's subtotal (Out / In / Tot).  Net totals (Out / In / Tot) follow in a
/// compact summary so handicap games read at a glance.

import 'package:flutter/material.dart';

import '../api/models.dart';

class ShareableScorecard extends StatelessWidget {
  final String courseName;
  final String dateLabel;
  final String roundLabel;
  final List<ScorecardHole> holes;
  final List<PlayerTotals> totals;

  /// Fixed render width — keeps the captured image consistent regardless of the
  /// device screen (a phone-portrait-friendly ~380pt). Column widths are sized
  /// so the WIDER back nine (9 holes + In + Tot) fits inside with margin:
  ///   name 60 + 9×23 + 2×26 = 319  (+ table & card padding) < 380.
  static const double _width = 380;
  static const double _holeW = 23;
  static const double _subW  = 26;
  static const double _nameW = 60;

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

  int? _gross(int playerId, int hole) {
    final h = holes.where((x) => x.holeNumber == hole).firstOrNull;
    return h?.scores
        .where((s) => s.playerId == playerId)
        .firstOrNull
        ?.grossScore;
  }

  @override
  Widget build(BuildContext context) {
    final pine   = const Color(0xFF1E5C3F); // Halved pine (brand)
    final muted  = const Color(0xFF6B7280);
    final line   = const Color(0xFFD8DED9);

    return Container(
      width: _width,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Text(courseName,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: pine)),
          const SizedBox(height: 2),
          Text('$dateLabel   ·   $roundLabel',
              style: TextStyle(fontSize: 12, color: muted)),
          const SizedBox(height: 12),

          _nineTable(_front, isFront: true, pine: pine, muted: muted, line: line),
          const SizedBox(height: 12),
          _nineTable(_back, isFront: false, pine: pine, muted: muted, line: line),

          const SizedBox(height: 12),
          _netSummary(pine: pine, muted: muted, line: line),

          const SizedBox(height: 10),
          Center(
            child: Text('Halved',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w800, color: pine)),
          ),
        ],
      ),
    );
  }

  // ── A single nine's table (Hole / Par / one gross row per player) ──────────
  Widget _nineTable(
    List<ScorecardHole> nine, {
    required bool isFront,
    required Color pine,
    required Color muted,
    required Color line,
  }) {
    final holeCells = nine.map((h) => h.holeNumber).toList();
    // Subtotal columns: Front → OUT; Back → IN + TOT.
    final subCols = isFront ? const ['Out'] : const ['In', 'Tot'];

    Widget hcell(String text, {Color? color, FontWeight? weight, double w = _holeW}) =>
        SizedBox(
          width: w,
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: weight ?? FontWeight.w500,
                  color: color ?? Colors.black87)),
        );

    // Header (hole numbers) row.
    final headerRow = Row(children: [
      SizedBox(width: _nameW, child: hcell('Hole', color: muted, weight: FontWeight.w700, w: _nameW)),
      for (final n in holeCells) hcell('$n', color: muted, weight: FontWeight.w700),
      for (final s in subCols) hcell(s, color: pine, weight: FontWeight.w800, w: _subW),
    ]);

    // Par row.
    final parRow = Row(children: [
      SizedBox(width: _nameW, child: hcell('Par', color: muted, w: _nameW)),
      for (final h in nine) hcell('${h.par}', color: muted),
      for (final s in subCols)
        hcell(
          s == 'Out'
              ? '${_sumPar(nine)}'
              : (s == 'In' ? '${_sumPar(nine)}' : '${_sumPar(_front) + _sumPar(_back)}'),
          color: muted, weight: FontWeight.w700, w: _subW),
    ]);

    // Player gross rows.
    final playerRows = <Widget>[];
    for (final t in totals) {
      playerRows.add(Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: line)),
        ),
        child: Row(children: [
          SizedBox(
            width: _nameW,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(_shortName(t.name),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
          for (final h in nine)
            () {
              final g = _gross(t.playerId, h.holeNumber);
              final under = g != null && g < h.par;
              return SizedBox(
                width: _holeW,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(g?.toString() ?? '–',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: under ? FontWeight.w800 : FontWeight.w500,
                          color: under
                              ? const Color(0xFFC62828) // birdie+ red
                              : Colors.black87)),
                ),
              );
            }(),
          for (final s in subCols)
            SizedBox(
              width: _subW,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                    s == 'Out'
                        ? '${t.frontGross}'
                        : (s == 'In' ? '${t.backGross}' : '${t.totalGross}'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: pine)),
              ),
            ),
        ]),
      ));
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [headerRow, const SizedBox(height: 2), parRow, ...playerRows],
      ),
    );
  }

  // ── Net totals summary (Out / In / Tot per player) ─────────────────────────
  Widget _netSummary({
    required Color pine,
    required Color muted,
    required Color line,
  }) {
    Widget cell(String t, {Color? color, FontWeight? weight, double w = _subW, TextAlign a = TextAlign.center}) =>
        SizedBox(
          width: w,
          child: Text(t,
              textAlign: a,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: weight ?? FontWeight.w500,
                  color: color ?? Colors.black87)),
        );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            cell('Net', color: muted, weight: FontWeight.w800, w: _nameW, a: TextAlign.left),
            cell('Out', color: pine, weight: FontWeight.w800),
            cell('In',  color: pine, weight: FontWeight.w800),
            cell('Tot', color: pine, weight: FontWeight.w800),
          ]),
          for (final t in totals)
            Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: line))),
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                cell(_shortName(t.name), weight: FontWeight.w600, w: _nameW, a: TextAlign.left),
                cell('${t.frontNet}'),
                cell('${t.backNet}'),
                cell('${t.totalNet}', weight: FontWeight.w800, color: pine),
              ]),
            ),
        ],
      ),
    );
  }

  static int _sumPar(List<ScorecardHole> hs) =>
      hs.fold(0, (a, h) => a + h.par);

  static String _shortName(String full) {
    final parts = full.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return full;
    return '${parts.first} ${parts.last[0]}.';
  }
}
