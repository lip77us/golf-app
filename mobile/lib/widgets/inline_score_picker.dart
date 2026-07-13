import 'package:flutter/material.dart';

import 'net_score_button.dart';

/// Inline horizontal score picker used on every game's score-entry screen.
///
/// A compact, centred box showing FOUR full cells — net birdie / net par /
/// net bogey / net double — with a third of the net-eagle & net-triple cells
/// peeking in on either side.  Most scores land in birdie–double, so the common
/// case is one tap.  The box is centred on the GAP between net par and net
/// bogey (not on net par itself), and light vertical dividers between the cells
/// give each score a defined slot so nothing "floats".  The box scrolls to
/// reach the rest.  Single source of truth — every screen (score entry, Nassau,
/// Skins, Wolf, Rabbit, Points 5-3-1, Quota Nassau) renders this, so the look
/// only has to be tuned once.
///
/// [onScoreSelected] is called with the chosen gross score, or -1 to clear
/// (the "Clear" chip, shown once a score is entered).
class InlineScorePicker extends StatefulWidget {
  final int  par;
  final int  strokes;
  final int? currentScore;
  final void Function(int) onScoreSelected;

  const InlineScorePicker({
    super.key,
    required this.par,
    required this.strokes,
    required this.currentScore,
    required this.onScoreSelected,
  });

  @override
  State<InlineScorePicker> createState() => _InlineScorePickerState();
}

class _InlineScorePickerState extends State<InlineScorePicker> {
  // Modest targets.  The box is sized to show FOUR cells in full (net birdie /
  // par / bogey / double) plus a third of the net-eagle & net-triple cells
  // peeking in on either side.
  static const double _itemWidth  = 50.0;
  static const double _itemMargin = 5.0;
  static const double _itemTotal  = _itemWidth + _itemMargin * 2;

  // 4 full cells + two ~1/3 peeks on the edges (the 5th & 6th buttons).
  static const double _viewportCells = 4.67;

  // The ListView's leading horizontal content padding (see build).
  static const double _listPadLeft = 8.0;

  late final ScrollController _ctrl;

  // Edge-fade hints: fade the leading/trailing chips when there's more to
  // scroll to, so it's obvious the row continues past the visible window.
  bool _atStart = true;
  bool _atEnd   = false;

  /// Pixel offset (within the scrollable content) of the boundary between the
  /// net-par cell and the net-bogey cell — i.e. the right edge of the net-par
  /// cell.  This is the point we centre the viewport on.
  double _gapCentre(int par, int strokes) {
    final netPar = (par + strokes).clamp(1, 12);
    final idx    = netPar - 1;                 // net-par cell index (0-based)
    return _listPadLeft + (idx + 1.0) * _itemTotal;
  }

  double _estimateOffset(int par, int strokes) {
    // Pre-layout estimate that already approximates the centred position
    // (viewport ≈ 4.67 cells — see the box width in build), so there's no
    // first-frame jump; _centerOnGap() refines it once the real viewport width
    // is measured.
    const estViewport = _itemTotal * _viewportCells;
    return (_gapCentre(par, strokes) - estViewport / 2)
        .clamp(0.0, double.infinity);
  }

  /// Scroll so the net-par / net-bogey boundary sits dead-centre in the
  /// viewport, so net birdie…double sit centred as the four full cells and the
  /// net-eagle / net-triple cells peek symmetrically on the edges.  Uses the
  /// measured viewport width, so it's correct on any screen size; clamps at the
  /// ends when the gap is too close to a boundary to fully centre.
  void _centerOnGap() {
    if (!mounted || !_ctrl.hasClients) return;
    final pos    = _ctrl.position;
    final target = (_gapCentre(widget.par, widget.strokes) -
            pos.viewportDimension / 2)
        .clamp(0.0, pos.maxScrollExtent);
    _ctrl.jumpTo(target);
  }

  void _onScroll() {
    if (!_ctrl.hasClients) return;
    final atStart = _ctrl.offset <= 0.5;
    final atEnd   = _ctrl.offset >= _ctrl.position.maxScrollExtent - 0.5;
    if (atStart != _atStart || atEnd != _atEnd) {
      setState(() { _atStart = atStart; _atEnd = atEnd; });
    }
  }

  @override
  void initState() {
    super.initState();
    _ctrl = ScrollController(
        initialScrollOffset: _estimateOffset(widget.par, widget.strokes));
    _ctrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerOnGap();
      _onScroll();
    });
  }

  @override
  void didUpdateWidget(covariant InlineScorePicker old) {
    super.didUpdateWidget(old);
    if (old.par != widget.par || old.strokes != widget.strokes) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnGap());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final scores = List.generate(12, (i) => i + 1);

    return Center(
      child: Container(
      height: 72,
      // Compact box, centred on the card: FOUR cells (net birdie / par / bogey
      // / double) show in full, with a third of the net-eagle & net-triple
      // cells peeking in on either side (the fade hints there's more to scroll).
      width: _itemTotal * _viewportCells + 5,  // +5 covers the 2.5px border
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      // Dark-green border so the picker reads as an anchored control, not
      // floating on the card.
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.18),
        border: Border.all(color: Colors.green.shade700, width: 2.5),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final f = (16.0 / bounds.width).clamp(0.0, 0.5);
          return LinearGradient(
            begin: Alignment.centerLeft,
            end:   Alignment.centerRight,
            colors: [
              _atStart ? Colors.white : Colors.transparent,
              Colors.white,
              Colors.white,
              _atEnd ? Colors.white : Colors.transparent,
            ],
            stops: [0.0, f, 1 - f, 1.0],
          ).createShader(bounds);
        },
        child: ListView.builder(
        controller:      _ctrl,
        scrollDirection: Axis.horizontal,
        // No vertical padding: items fill the full inner height so the divider
        // lines run top-to-bottom of the bounding box.
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: scores.length + (widget.currentScore != null ? 1 : 0),
        itemBuilder: (_, i) {
          if (widget.currentScore != null && i == scores.length) {
            return Padding(
              padding: const EdgeInsets.only(left: 12),
              child: GestureDetector(
                onTap: () => widget.onScoreSelected(-1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: theme.colorScheme.error.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Clear',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      )),
                ),
              ),
            );
          }
          final s           = scores[i];
          final sel         = s == widget.currentScore;
          final isNetPar    = s == widget.par + widget.strokes;
          final isLastScore = i == scores.length - 1;

          // Each cell occupies exactly [_itemTotal] so the centring maths stay
          // exact; the score button is centred inside (5px margin each side).
          final Widget cell = isNetPar
              ? GestureDetector(
                  onTap: () => widget.onScoreSelected(s),
                  child: Container(
                    width: _itemWidth,
                    height: 48,
                    alignment: Alignment.center,
                    // Darker green tint marks net par as the anchor — no border
                    // (a dark ring reads bogey-like) and no glow (net par has no
                    // golf shape of its own).
                    decoration: BoxDecoration(
                      color: Colors.green.shade400,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: NetScoreButton(
                      score:    s,
                      par:      widget.par,
                      strokes:  widget.strokes,
                      selected: sel,
                      width:    40,
                      height:   40,
                    ),
                  ),
                )
              : NetScoreButton(
                  score:    s,
                  par:      widget.par,
                  strokes:  widget.strokes,
                  selected: sel,
                  width:    _itemWidth,
                  height:   48,
                  onTap:    () => widget.onScoreSelected(s),
                );

          // A light divider on the cell's right edge lands mid-gap between this
          // score and the next, giving each score a defined slot (kills the
          // "floating" feel).  Skipped after the last score.
          return Container(
            width: _itemTotal,
            alignment: Alignment.center,
            decoration: isLastScore
                ? null
                : BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        // A touch darker than outlineVariant — 20% of the way
                        // toward outline (100% read as too dark).
                        color: Color.lerp(
                          theme.colorScheme.outlineVariant,
                          theme.colorScheme.outline,
                          0.20,
                        )!,
                        width: 1,
                      ),
                    ),
                  ),
            child: cell,
          );
        },
        ),
      ),
    ),
    );
  }
}
