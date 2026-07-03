import 'package:flutter/material.dart';

import 'net_score_button.dart';

/// Inline horizontal score picker used on every game's score-entry screen.
///
/// A compact, centred box: birdie / net par / bogey show in full with a third
/// of the eagle & double-bogey cells peeking in on either side; net par is
/// marked with a soft sprayed green halo (it has no golf shape of its own) and
/// the box scrolls to reach the rest.  Single source of truth — every screen
/// (score entry, Nassau, Skins, Wolf, Rabbit, Points 5-3-1, Quota Nassau)
/// renders this, so the look only has to be tuned once.
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
  // Modest targets, centered on net par (most scores land within a stroke).
  // The box is sized to show birdie / net par / bogey in full plus a third of
  // the eagle & double-bogey cells peeking in on either side.
  static const double _itemWidth  = 50.0;
  static const double _itemMargin = 5.0;
  static const double _itemTotal  = _itemWidth + _itemMargin * 2;

  // The ListView's leading horizontal content padding (see build).
  static const double _listPadLeft = 8.0;

  late final ScrollController _ctrl;

  // Edge-fade hints: fade the leading/trailing chips when there's more to
  // scroll to, so it's obvious the row continues past par (e.g. a high score).
  bool _atStart = true;
  bool _atEnd   = false;

  double _estimateOffset(int par, int strokes) {
    // Pre-layout estimate that already approximates the centred position
    // (viewport ≈ 3.67 cells — see the box width in build), so there's no
    // first-frame jump; _centerOnNetPar() refines it once the real viewport
    // width is measured.
    final netPar = (par + strokes).clamp(1, 12);
    const estViewport = _itemTotal * 3.67;
    final netParCentre = _listPadLeft + (netPar - 1 + 0.5) * _itemTotal;
    return (netParCentre - estViewport / 2).clamp(0.0, double.infinity);
  }

  /// Scroll so net par sits dead-centre in the viewport, so the scores an
  /// equal distance below and above it (eagle vs double-bogey) are cut off
  /// symmetrically.  Uses the measured viewport width, so it's correct on any
  /// screen size; clamps at the ends when net par is too close to a boundary
  /// to fully centre.
  void _centerOnNetPar() {
    if (!mounted || !_ctrl.hasClients) return;
    final pos    = _ctrl.position;
    final netPar = widget.par + widget.strokes;
    final idx    = (netPar - 1).clamp(0, 11).toDouble();       // score → index
    final netParCentre = _listPadLeft + (idx + 0.5) * _itemTotal;
    final target = (netParCentre - pos.viewportDimension / 2)
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
      _centerOnNetPar();
      _onScroll();
    });
  }

  @override
  void didUpdateWidget(covariant InlineScorePicker old) {
    super.didUpdateWidget(old);
    if (old.par != widget.par || old.strokes != widget.strokes) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnNetPar());
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
      // Compact box, centred on the card: birdie / net par / bogey show in
      // full, with a third of the eagle & double-bogey cells peeking in on
      // either side (the fade hints there's more to scroll to).
      width: _itemTotal * 3.67 + 5,   // +5 covers the 2.5px border each side
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
          final s        = scores[i];
          final sel      = s == widget.currentScore;
          final isNetPar = s == widget.par + widget.strokes;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
            child: isNetPar
                ? GestureDetector(
                    onTap: () => widget.onScoreSelected(s),
                    child: Container(
                      width: _itemWidth,
                      height: 48,
                      alignment: Alignment.center,
                      // Crisp light-green tint marks net par as the anchor —
                      // no blur/glow (net par has no golf shape of its own).
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
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
                  ),
          );
        },
        ),
      ),
    ),
    );
  }
}
