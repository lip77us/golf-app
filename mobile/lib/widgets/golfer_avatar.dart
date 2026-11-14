/// The golfer avatar on the Add players screen and its sheets.
///
/// On Halved: solid pine with white initials and a small **H** badge (deep pine,
/// mint letter) at the bottom right. Not on Halved: white with pine initials and
/// a light pine ring. The badge is the same fact the Halved mark states
/// elsewhere in the app, drawn at avatar scale.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (parts.isEmpty) return '?';
  final list = parts.toList();
  if (list.length == 1) return list.first[0].toUpperCase();
  return (list.first[0] + list.last[0]).toUpperCase();
}

class GolferAvatar extends StatelessWidget {
  final String name;
  final bool onHalved;
  final double size;

  const GolferAvatar({
    super.key,
    required this.name,
    required this.onHalved,
    this.size = 42,
  });

  @override
  Widget build(BuildContext context) {
    final disc = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: onHalved ? Halved.pine : Colors.white,
        border: onHalved
            ? null
            : Border.all(color: const Color(0xFFBFD6CB), width: 1.5),
      ),
      child: Text(
        initialsOf(name),
        style: Halved.body(
                color: onHalved ? Colors.white : Halved.pine,
                weight: FontWeight.w700)
            .copyWith(fontSize: size * 0.36),
      ),
    );

    Widget avatar = disc;
    if (onHalved) {
      final b = size * 0.4;
      avatar = SizedBox(
        width: size,
        height: size,
        child: Stack(clipBehavior: Clip.none, children: [
          disc,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: b,
              height: b,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Halved.deepPine,
                border: Border.all(color: Halved.surface, width: 1.5),
              ),
              child: Text('H',
                  style: Halved.body(
                          color: Halved.brightMint, weight: FontWeight.w800)
                      .copyWith(fontSize: b * 0.6, height: 1)),
            ),
          ),
        ]),
      );
    }

    return avatar;
  }
}
