import 'package:flutter/material.dart';

/// The `SKIPPED` tag after a golfer's CH (`handoff-score-entry-skip`): 10px
/// bold caps, ink `#8A4A1C` on `#FDF0E4`, 4px radius. Shown only while he
/// was skipped on this hole and still has no score.
class SkippedTag extends StatelessWidget {
  const SkippedTag({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFFDF0E4),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text('SKIPPED',
            style: TextStyle(
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: Color(0xFF8A4A1C))),
      );
}
