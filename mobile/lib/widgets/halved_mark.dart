import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Halved brand mark (H + flagstick planted in a cup), rendered as a small
/// rounded badge. Used to flag a golfer as "On Halved" — i.e. signed up /
/// connected. Compact (icon only) with a tooltip explaining it.
class HalvedMark extends StatelessWidget {
  final double size;
  const HalvedMark({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'On Halved',
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
