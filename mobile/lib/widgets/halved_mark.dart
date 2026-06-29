import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Halved brand mark (H + flagstick planted in a cup), rendered as a small
/// rounded badge. Used to flag a golfer as "On Halved" — i.e. signed up /
/// connected — and, with [tooltip] overridden, as the marker for a halved hole
/// (the match-play term the app is named after) in outcome banners.
class HalvedMark extends StatelessWidget {
  final double size;
  /// Tooltip text. Defaults to the "connected golfer" meaning; pass 'Halved'
  /// (or similar) when used as a halved-hole marker.
  final String tooltip;
  const HalvedMark({super.key, this.size = 20, this.tooltip = 'On Halved'});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: SvgPicture.asset(
          'assets/icon/halved_mark.svg',
          width: size,
          height: size,
        ),
      ),
    );
  }
}
