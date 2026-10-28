import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// The switch at the top of every leaderboard.
///
/// Four design packets have now specified this and none had built it — 40
/// Balls, Sixes, skins and Nassau all open with the same paragraph: *"shared
/// segmented control… Past five items it scrolls and keeps the active one
/// centred. Where boards swipe, the thumb tracks the swipe. Do not use pill
/// or underline tabs."* The leaderboard was using a Material `TabBar`, which
/// is the underline tabs that sentence rules out.
///
/// ### Why this is not `HalvedSegmented`
///
/// That control is a `Row` of equal or fixed-width segments with no scroller,
/// which is right for a closed set somebody reads in one glance — the size
/// picker, Survivors/Standings. A leaderboard carries as many games as the
/// round is playing, so this one is **sized to each label**, **scrolls**, and
/// **keeps the active game centred**. Same visual language, different job;
/// the two are split for the reason `StrokeDotRow` and `StrokeDotColumn` are.
///
/// ### The thumb tracks the swipe
///
/// It reads `TabController.animation`, which is a FRACTIONAL index while a
/// swipe is in flight, and interpolates both offset and width between the two
/// neighbouring labels. That is what the reference does (`place(p)` lerps
/// between `floor(p)` and `ceil(p)`), and it is why this takes a controller
/// rather than a selected index: an index cannot describe a half-finished
/// drag.
class GameSwitcher extends StatefulWidget {
  const GameSwitcher({
    super.key,
    required this.controller,
    required this.labels,
  });

  final TabController controller;
  final List<String> labels;

  /// Height of the control, so a caller sizing an app bar does not guess.
  ///
  /// It INCLUDES the bottom margin. Leaving that out made the row overflow
  /// its own box by 6pt, which does not look broken — it just moves the
  /// labels out of the hit area, so taps silently miss.
  static const double height = _barHeight + _pad * 2 + _marginBottom;

  static const double _barHeight = 38;
  static const double _pad = 3;
  static const double _marginBottom = 6;
  static const double _labelPad = 14;

  @override
  State<GameSwitcher> createState() => _GameSwitcherState();
}

class _GameSwitcherState extends State<GameSwitcher> {
  final _scroll = ScrollController();
  List<double> _widths = const [];
  int _lastCentred = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Measured, not laid out: the thumb has to know a label's width BEFORE the
  /// first frame, or it starts at zero and snaps.
  List<double> _measure(TextStyle style, double textScale) => [
        for (final l in widget.labels)
          (TextPainter(
            text: TextSpan(text: l, style: style),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.linear(textScale),
          )..layout())
                  .width +
              GameSwitcher._labelPad * 2,
      ];

  double _offsetOf(int i) {
    var x = GameSwitcher._pad;
    for (var j = 0; j < i && j < _widths.length; j++) {
      x += _widths[j];
    }
    return x;
  }

  void _centre(int index, double viewport) {
    if (!_scroll.hasClients || index < 0 || index >= _widths.length) return;
    final total = _widths.fold<double>(0, (a, b) => a + b) +
        GameSwitcher._pad * 2;
    if (total <= viewport) return;          // nothing to scroll
    final target = _offsetOf(index) - (viewport - _widths[index]) / 2;
    final max = total - viewport;
    _scroll.animateTo(
      target.clamp(0.0, math.max(0.0, max)),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.labels.isEmpty) return const SizedBox.shrink();

    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
    _widths = _measure(style, MediaQuery.textScalerOf(context).scale(1));
    final total =
        _widths.fold<double>(0, (a, b) => a + b) + GameSwitcher._pad * 2;

    return SizedBox(
      height: GameSwitcher.height,
      child: LayoutBuilder(builder: (context, box) {
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, GameSwitcher._marginBottom),
          decoration: BoxDecoration(
            color: Halved.cardBorder,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: SizedBox(
              width: math.max(total, box.maxWidth),
              height: GameSwitcher._barHeight + GameSwitcher._pad * 2,
              child: AnimatedBuilder(
                animation: widget.controller.animation ?? widget.controller,
                builder: (context, _) {
                  final p = widget.controller.animation?.value ??
                      widget.controller.index.toDouble();
                  final a = p.floor().clamp(0, _widths.length - 1);
                  final b = p.ceil().clamp(0, _widths.length - 1);
                  final t = p - a;
                  final left = _offsetOf(a) +
                      (_offsetOf(b) - _offsetOf(a)) * t;
                  final w = _widths[a] + (_widths[b] - _widths[a]) * t;

                  final index = widget.controller.index;
                  if (index != _lastCentred) {
                    _lastCentred = index;
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _centre(index, box.maxWidth - 32));
                  }

                  return Stack(children: [
                    Positioned(
                      left: left,
                      top: GameSwitcher._pad,
                      width: w,
                      height: GameSwitcher._barHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Halved.card,
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x240B1F1A),
                              blurRadius: 3,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(GameSwitcher._pad),
                      child: Row(children: [
                        for (var i = 0; i < widget.labels.length; i++)
                          SizedBox(
                            width: _widths[i],
                            height: GameSwitcher._barHeight,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(9),
                              onTap: () => widget.controller.animateTo(i),
                              child: Center(
                                child: Text(
                                  widget.labels[i],
                                  maxLines: 1,
                                  style: style.copyWith(
                                    // The ACTIVE label darkens as the thumb
                                    // arrives, so a half-finished swipe reads
                                    // as half-finished rather than snapping.
                                    color: Color.lerp(
                                      Halved.muted,
                                      Halved.deepPine,
                                      (1 - (p - i).abs()).clamp(0.0, 1.0),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ]);
                },
              ),
            ),
          ),
        );
      }),
    );
  }
}
