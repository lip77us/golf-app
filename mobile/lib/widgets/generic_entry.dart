/// The generic hole tray: the template's frame around a `Hole / Gross` table.
///
/// For the games that have no tray of their own. See `utils/generic_tray.dart`
/// for what it does and does not say.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/generic_tray.dart';
import 'tray_frame.dart';

class GenericHoleTray extends StatelessWidget {
  /// `Hole 7 · Irish Rumble`.
  final String label;
  final List<GenericTrayRow> rows;
  final bool picking;
  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final String nextLabel;

  const GenericHoleTray({
    super.key,
    required this.label,
    required this.rows,
    required this.onEdit,
    required this.nextLabel,
    this.picking = false,
    this.onPrev,
    this.onNext,
  });

  static const Color _muted = Color(0xFFB9CCC3);

  @override
  Widget build(BuildContext context) => TrayFrame(
        label: label,
        picking: picking,
        onEdit: onEdit,
        onPrev: onPrev,
        onNext: onNext,
        nextLabel: nextLabel,
        blocks: [TrayBlock(child: _table())],
      );

  Widget _table() {
    final head = Halved.label(color: _muted, weight: FontWeight.w700)
        .copyWith(fontSize: 10.5, letterSpacing: 0.4);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 20,
        child: Row(children: [
          const Expanded(child: SizedBox()),
          SizedBox(
              width: 48,
              child: Text('HOLE', textAlign: TextAlign.right, style: head)),
          SizedBox(
              width: 56,
              child: Text('GROSS', textAlign: TextAlign.right, style: head)),
        ]),
      ),
      for (var i = 0; i < rows.length; i++)
        Container(
          height: 32,
          decoration: BoxDecoration(
            border: i == 0
                ? null
                : Border(
                    top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08))),
          ),
          child: Row(children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: rows[i].side ?? const Color(0xFFB9CCC3),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Expanded(
              child: Text(rows[i].name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Halved.body(color: Colors.white, weight: FontWeight.w600)
                      .copyWith(fontSize: 14)),
            ),
            SizedBox(
              width: 48,
              child: Text(rows[i].hole == null ? '–' : '${rows[i].hole}',
                  textAlign: TextAlign.right,
                  style: Halved.sectionHead().copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _muted)),
            ),
            SizedBox(
              width: 56,
              child: Text(rows[i].toParText,
                  textAlign: TextAlign.right,
                  style: Halved.sectionHead().copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ]),
        ),
    ]);
  }
}
