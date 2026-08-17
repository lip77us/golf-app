import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import 'net_score_button.dart';

/// Inline horizontal score picker used on every game's score-entry screen.
///
/// A compact, centred box showing FOUR full cells — birdie / par / bogey /
/// double — with a third of the eagle & triple cells peeking in on either
/// side.  Most scores land in birdie–double, so the common case is one tap.
/// The box is centred on the GAP between par and bogey (not on par itself),
/// and light vertical dividers between the cells give each score a defined
/// slot so nothing "floats".  The box scrolls to reach the rest.  Single
/// source of truth — every screen (score entry, Nassau, Skins, Wolf, Rabbit,
/// Points 5-3-1, Quota Nassau) renders this, so the look only has to be tuned
/// once.
///
/// **Which par it anchors on follows the Net Style Entry preference**, exactly
/// as [NetScoreButton]'s circle/square notation does:
///
///   * ON  — anchor is NET par (par + strokes on this hole). The four cells
///           are net birdie / net par / net bogey / net double.
///   * OFF — anchor is GROSS par, and strokes are ignored for layout. The four
///           cells are the real birdie / par / bogey / double.
///
/// The two used to disagree: the notation honoured the setting while the
/// centring was always net, so with the setting off a golfer got correct gross
/// circles around a strip still centred on net par — pushing gross par out of
/// slot 2 and into the birdie slot.
///
/// [onScoreSelected] is called with the chosen gross score, or -1 to clear
/// (the "Clear" chip, shown once a score is entered).
class InlineScorePicker extends StatefulWidget {
  final int  par;
  final int  strokes;
  final int? currentScore;
  final void Function(int) onScoreSelected;
  /// Outer box border colour — the active player's team colour (Blue/Orange)
  /// when on a team; null falls back to dark green.
  final Color? boxBorderColor;
  /// Outer box fill (wash) — matches the surrounding entry section; null falls
  /// back to the standalone light-green wash.
  final Color? boxFillColor;

  const InlineScorePicker({
    super.key,
    required this.par,
    required this.strokes,
    required this.currentScore,
    this.boxBorderColor,
    this.boxFillColor,
    required this.onScoreSelected,
  });

  @override
  State<InlineScorePicker> createState() => _InlineScorePickerState();
}

class _InlineScorePickerState extends State<InlineScorePicker> {
  // Modest targets.  The box is sized to show FOUR cells in full (birdie /
  // par / bogey / double, against the anchor par) plus a third of the eagle &
  // triple cells peeking in on either side.
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

  /// Whether the anchor is NET par or GROSS par — the Net Style Entry
  /// preference, mirrored here so [initState] can lay out before the first
  /// build and [didChangeDependencies] can re-centre when it is toggled.
  bool _netStyle = true;

  /// The strokes that count TOWARD LAYOUT. Zero when the preference is off:
  /// the golfer asked to read this card in gross, so the anchor is real par
  /// and his handicap strokes do not move the strip. (The dot strip above each
  /// cell still shows the strokes he receives — that is information, not a
  /// baseline.)
  int get _layoutStrokes => _netStyle ? widget.strokes : 0;

  /// The score the strip anchors on and highlights.
  int get _anchorScore => (widget.par + _layoutStrokes).clamp(1, 12);

  /// Pixel offset (within the scrollable content) of the boundary between the
  /// anchor-par cell and the bogey cell — i.e. the right edge of the anchor
  /// cell.  This is the point we centre the viewport on, which puts par in
  /// slot 2 of the four visible cells: birdie · par · bogey · double.
  double _gapCentre(int par, int strokes) {
    final anchor = (par + strokes).clamp(1, 12);
    final idx    = anchor - 1;                 // anchor cell index (0-based)
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

  /// Scroll so the par / bogey boundary sits dead-centre in the viewport, so
  /// birdie…double sit centred as the four full cells and the eagle / triple
  /// cells peek symmetrically on the edges.  ("par" here is the anchor — net
  /// or gross per the preference.)  Uses the measured viewport width, so it's
  /// correct on any screen size; clamps at the ends when the gap is too close
  /// to a boundary to fully centre.
  void _centerOnGap() {
    if (!mounted || !_ctrl.hasClients) return;
    final pos    = _ctrl.position;
    final target = (_gapCentre(widget.par, _layoutStrokes) -
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
    // read (not watch) — initState cannot subscribe, and
    // didChangeDependencies below keeps it in sync afterwards.
    _netStyle = context.read<SettingsProvider>().netStyleEntry;
    _ctrl = ScrollController(
        initialScrollOffset: _estimateOffset(widget.par, _layoutStrokes));
    _ctrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerOnGap();
      _onScroll();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Toggling Net Style Entry moves the anchor between net and gross par, so
    // the strip has to re-centre — otherwise the setting would only take
    // effect on the next hole.
    final next = Provider.of<SettingsProvider>(context).netStyleEntry;
    if (next != _netStyle) {
      _netStyle = next;
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnGap());
    }
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
      // Light-green fill + bold dark-green border so the picker reads as an
      // anchored control matching the active player's name box.
      decoration: BoxDecoration(
        color: widget.boxFillColor ?? Colors.green.shade50,
        border: Border.all(
            color: widget.boxBorderColor ?? Colors.green.shade700, width: 3.0),
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
          final isAnchor    = s == _anchorScore;
          final isLastScore = i == scores.length - 1;

          // Each cell occupies exactly [_itemTotal] so the centring maths stay
          // exact; the score button is centred inside (5px margin each side).
          final Widget cell = isAnchor
              ? GestureDetector(
                  onTap: () => widget.onScoreSelected(s),
                  child: Container(
                    width: _itemWidth,
                    height: 48,
                    alignment: Alignment.center,
                    // Darker green tint marks the anchor — net par or gross
                    // par, per the preference. No border (a dark ring reads
                    // bogey-like) and no glow (par has no golf shape of its
                    // own).
                    //
                    // SELECTION is a DEEPER TINT, not an added outline. Par is
                    // the one score with no shape of its own, so the 2.5px
                    // rounded border NetScoreButton draws for a selected cell
                    // had nothing to sit around except the bare digit — and a
                    // box around a digit is exactly how this card draws a
                    // bogey. Picking par made par look like a bogey.
                    decoration: BoxDecoration(
                      color: sel ? Colors.green.shade600 : Colors.green.shade400,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: NetScoreButton(
                      score:    s,
                      par:      widget.par,
                      strokes:  widget.strokes,
                      // The tint above carries the selection here.
                      selected: false,
                      width:    40,
                      height:   40,
                      // The anchor always renders as clean par (no bogey
                      // square). With the preference ON the button's own
                      // baseline is gross par, so force the net one; with it
                      // OFF the anchor IS gross par and the default baseline
                      // is already right.
                      forceNetBaseline: _netStyle,
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
