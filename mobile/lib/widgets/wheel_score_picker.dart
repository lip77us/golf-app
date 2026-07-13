import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'net_score_button.dart';

/// A vertical "drum" score picker (iOS Timer-app feel) — a Skins-only trial.
///
/// Unlike [InlineScorePicker] (a free-scroll horizontal row that lives *under*
/// the hot player), this wheel is fixed in place beside the player rows.  The
/// parent re-centres it on the ACTIVE player by rebuilding with new props: the
/// wheel snaps to that player's current score, or — if they haven't been
/// scored yet — to their net par.
///
/// Interaction: spin to bring a value toward the centre (heavy, overdamped
/// physics + a medium haptic tick as each number lands under the band), then
/// TAP any number to commit it (select-in-place, even off-centre).  Committing
/// is delegated to [onScoreSelected] (or -1 to clear); the parent then advances
/// the highlight to the next golfer and re-centres this wheel on their net par.
class WheelScorePicker extends StatefulWidget {
  /// Par for the hole.
  final int par;

  /// Strokes the ACTIVE player receives on this hole (drives net-par centring
  /// and the golf shape/colour inside each cell).
  final int strokes;

  /// The active player's current gross score, if any (drives the initial
  /// centre + snap-back).  Null → centre on net par.
  final int? currentScore;

  /// Called with the tapped gross score, or -1 to clear.
  final void Function(int) onScoreSelected;

  const WheelScorePicker({
    super.key,
    required this.par,
    required this.strokes,
    required this.currentScore,
    required this.onScoreSelected,
  });

  @override
  State<WheelScorePicker> createState() => _WheelScorePickerState();
}

class _WheelScorePickerState extends State<WheelScorePicker> {
  static const int    _minScore   = 1;
  static const int    _maxScore   = 12;
  static const double _itemExtent = 54;

  late FixedExtentScrollController _ctrl;

  /// True while an animateToItem() is running, so the per-item haptic tick
  /// (onSelectedItemChanged) doesn't fire a burst during a programmatic
  /// snap-back to the next player's net par.
  bool _programmatic = false;

  int get _netPar =>
      (widget.par + widget.strokes).clamp(_minScore, _maxScore);
  int get _target =>
      (widget.currentScore ?? _netPar).clamp(_minScore, _maxScore);
  int _indexOf(int score) => score - _minScore;

  @override
  void initState() {
    super.initState();
    _ctrl = FixedExtentScrollController(initialItem: _indexOf(_target));
  }

  @override
  void didUpdateWidget(covariant WheelScorePicker old) {
    super.didUpdateWidget(old);
    // Active player / score / strokes changed → roll the drum to the new
    // centre so the wheel always reflects who's up.
    if (old.currentScore != widget.currentScore ||
        old.strokes != widget.strokes ||
        old.par != widget.par) {
      final want = _indexOf(_target);
      if (_ctrl.hasClients && _ctrl.selectedItem != want) {
        _programmatic = true;
        _ctrl
            .animateToItem(want,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic)
            .whenComplete(() => _programmatic = false);
      }
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
    // The wheel sits on its own recessed "housing" so it reads as a defined
    // control instead of floating on the card.  The top/bottom fade must
    // dissolve the numbers into THIS colour (not the card), so it's shared.
    final housing = theme.colorScheme.surfaceContainerHighest;
    final scores = List.generate(_maxScore - _minScore + 1, (i) => _minScore + i);

    return Container(
      width: 78,
      decoration: BoxDecoration(
        color: housing,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.14),
            blurRadius: 7,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _itemExtent * 3, // centre number + one partial above & below
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Centre selection band — the white score cell sits inside it, so
            // this frames the number under the drum.
            Center(
              child: Container(
                height: _itemExtent - 4,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade100.withOpacity(0.30),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.green.shade700, width: 2),
                ),
              ),
            ),

            // The drum.
            ListWheelScrollView.useDelegate(
              controller:       _ctrl,
              itemExtent:       _itemExtent,
              physics:          const _HeavyFixedExtentPhysics(),
              diameterRatio:    1.25,   // tighter curve → more foreshortening
              perspective:      0.005,
              magnification:    1.2,
              useMagnifier:     true,
              squeeze:          1.1,
              overAndUnderCenterOpacity: 0.6, // keep the tappable ±1 legible
              onSelectedItemChanged: (_) {
                if (!_programmatic) HapticFeedback.mediumImpact();
              },
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: scores.length,
                builder: (context, i) {
                  final s = scores[i];
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onScoreSelected(s),
                    child: Center(
                      child: NetScoreButton(
                        score:    s,
                        par:      widget.par,
                        strokes:  widget.strokes,
                        selected: false,
                        width:    40,
                        height:   40,
                      ),
                    ),
                  );
                },
              ),
            ),

            // Top/bottom fade so numbers dissolve into the housing at the edges
            // (the Timer-drum look, and it hides the hard clip).
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end:   Alignment.bottomCenter,
                      colors: [
                        housing,
                        housing.withOpacity(0.0),
                        housing.withOpacity(0.0),
                        housing,
                      ],
                      stops: const [0.0, 0.2, 0.8, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A heavy, overdamped snap physics.  The score range is small (very short
/// travel), so a flick should NOT send the drum spinning — it should feel like
/// a weighted dial: resistant to being thrown, settling firmly with no bounce.
///
/// Three tunable knobs for "how heavy it feels":
///   • [_velocityFactor] — fraction of a flick's speed that's kept (lower =
///     heavier; the main "spins too fast" dial).
///   • [maxFlingVelocity] — hard cap on top speed so a hard flick can't run.
///   • [spring] mass — inertia of the final settle.
class _HeavyFixedExtentPhysics extends FixedExtentScrollPhysics {
  const _HeavyFixedExtentPhysics({super.parent});

  static const double _velocityFactor = 0.28;

  @override
  _HeavyFixedExtentPhysics applyTo(ScrollPhysics? ancestor) =>
      _HeavyFixedExtentPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass:      2.1,   // heavy → weighty, unhurried settle
        stiffness: 110,
        ratio:     1.4,   // > 1 → overdamped, no overshoot
      );

  // Cap top speed so a hard flick can't send the drum spinning.
  @override
  double get maxFlingVelocity => 900;

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    // Bleed off most of the fling velocity: short, deliberate travel instead
    // of a fast spin.  Below the fling threshold this still returns the spring
    // to the nearest item, so a nudge always snaps home.
    return super.createBallisticSimulation(position, velocity * _velocityFactor);
  }
}
