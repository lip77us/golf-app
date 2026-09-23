/// widgets/pinned_hole_grid.dart
///
/// A hole-by-hole grid whose LEFT COLUMN DOES NOT SCROLL, and which opens on
/// the hole being played, against the right edge.
///
/// **Why the pin.** The progress grids under score entry put their labels
/// inside the horizontal scroll view along with the holes, so scrolling to the
/// 14th took the names away with it and the rows became anonymous — four
/// unlabelled lines of numbers in a fourball, which is precisely when you need
/// to know whose ball is whose. `HoleGridScorecard` had already been fixed and
/// carries the same note; these grids were never converted. Reported from a
/// fourball on 12 Sep 2026.
///
/// **Why the right edge.** A paper scorecard is read with the holes played to
/// the left and the one in front of you at the edge of the card. The old
/// target was `(pos - 6) * cellW`, which parks the current hole in the middle
/// with six empty columns to its right — so the thing you are about to do sits
/// in the centre and the holes you have finished run off the left. Anchoring
/// the current hole to the right edge means the visible span is always the
/// round so far.
///
/// **The two halves are matched lists** — same length, same heights, same
/// order. A grid whose columns disagree by one row is worse than one that
/// scrolls, so bands and rules are added to both sides together and there is
/// no way to add to one alone.
///
/// Length and order had no way to go wrong. **Height did**: the label came
/// straight from the caller, so a band whose label was shorter than its cells
/// put the pinned column out of step, and it compounded down the grid until
/// the names no longer named the rows they sat beside. `HoleGridBand.height`
/// closes that — pass it and both halves are sized together.
library;

import 'package:flutter/material.dart';

/// One row of the grid: a pinned label and the cells that scroll beside it.
///
/// A `rule` is a hairline divider, which still has to exist on BOTH sides or
/// the halves fall out of step by its height.
class HoleGridBand {
  final Widget? label;
  final List<Widget>? cells;
  final Color? colour;
  final bool isRule;

  /// Plain vertical space between bands, when a grid separates its rows with
  /// a gap rather than a hairline. Both halves get the same height, which is
  /// the only thing that matters — they fall out of step otherwise.
  final double gapHeight;

  /// **The row's height, applied to BOTH halves.** Pass it and the label can
  /// no longer be a different height from the cells beside it.
  ///
  /// It is optional because every grid predates it and sizes its own label;
  /// it exists because one of them did not. Survivor's by-hole grid handed in
  /// a bare `Text` for each name and an empty `SizedBox` for the header, so
  /// the pinned column ran at the text's line height while the scrolling half
  /// ran at 32 — and the three names ended up stacked ABOVE the grid rather
  /// than beside their own rows. Reported from the course, 22 Sep 2026.
  ///
  /// The library's note already claimed the two halves were "same length, same
  /// heights, same order". Length and order had no way to go wrong; height
  /// did, and nothing checked it. **Prefer this over sizing a label by hand.**
  final double? height;

  const HoleGridBand(this.label, this.cells, {this.colour, this.height})
      : isRule = false,
        gapHeight = 0;
  const HoleGridBand.rule()
      : label = null,
        cells = null,
        colour = null,
        gapHeight = 0,
        height = null,
        isRule = true;
  const HoleGridBand.gap(this.gapHeight)
      : label = null,
        cells = null,
        colour = null,
        height = null,
        isRule = false;
}

class PinnedHoleGrid extends StatefulWidget {
  final List<HoleGridBand> bands;
  final double labelWidth;
  final double cellWidth;

  /// How many hole columns there are — the rule divider's width, and the
  /// bound on the scroll.
  final int holeCount;

  /// The current hole's POSITION in play order, not its number: a back-nine
  /// round's first column is hole 10. Negative means "do not scroll".
  final int currentIndex;

  /// The content's real width, when it is not simply `cellWidth * holeCount`.
  ///
  /// Only the rule dividers use it. Stroke Play interleaves OUT / IN / TOT
  /// columns among the holes, so a rule measured in hole cells alone stops
  /// short of the grid it is meant to underline.
  final double? contentWidth;

  /// Where the current hole's RIGHT EDGE sits in content coordinates, when the
  /// columns are not uniform. Same reason: with an OUT column between the
  /// nines, a back-nine hole is one summary column further right than its
  /// index suggests, and scrolling by index alone would stop short of it.
  final double? currentRightEdge;

  const PinnedHoleGrid({
    super.key,
    required this.bands,
    required this.labelWidth,
    required this.cellWidth,
    required this.holeCount,
    required this.currentIndex,
    this.contentWidth,
    this.currentRightEdge,
  });

  @override
  State<PinnedHoleGrid> createState() => _PinnedHoleGridState();
}

class _PinnedHoleGridState extends State<PinnedHoleGrid> {
  final ScrollController _ctrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(PinnedHoleGrid old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) _schedule();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _schedule() {
    if (widget.currentIndex < 0 && widget.currentRightEdge == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      // The scroller holds the hole columns ALONE — the label column is
      // outside it — so the offset is measured in cells, with no label width
      // to add back. Putting the current hole's right edge on the viewport's
      // right edge is the whole of it.
      final edge = widget.currentRightEdge ??
          (widget.currentIndex + 1) * widget.cellWidth;
      final target = (edge - _ctrl.position.viewportDimension)
          .clamp(0.0, _ctrl.position.maxScrollExtent);
      _ctrl.animateTo(target,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final labelCol = <Widget>[];
    final cellCol  = <Widget>[];

    for (final b in widget.bands) {
      if (b.gapHeight > 0) {
        labelCol.add(SizedBox(height: b.gapHeight));
        cellCol.add(SizedBox(height: b.gapHeight));
      } else if (b.isRule) {
        labelCol.add(Container(
            height: 1,
            width: widget.labelWidth,
            color: theme.colorScheme.outlineVariant,
            margin: const EdgeInsets.symmetric(vertical: 2)));
        cellCol.add(Container(
            height: 1,
            width: widget.contentWidth ??
                widget.cellWidth * widget.holeCount,
            color: theme.colorScheme.outlineVariant,
            margin: const EdgeInsets.symmetric(vertical: 2)));
      } else {
        // A declared height goes on BOTH halves, which is the only way to be
        // sure they agree. The label is also aligned left-centre for it, so a
        // caller passing a bare `Text` gets the same treatment every
        // hand-sized label already gives itself.
        labelCol.add(Container(
            color: b.colour,
            height: b.height,
            alignment: b.height == null ? null : Alignment.centerLeft,
            width: b.height == null ? null : widget.labelWidth,
            child: b.label));
        cellCol.add(Container(
            color: b.colour,
            height: b.height,
            child: Row(children: b.cells ?? [])));
      }
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: labelCol),
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: _ctrl,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: cellCol),
        ),
      ),
    ]);
  }
}
