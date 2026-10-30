import 'package:flutter/material.dart';

/// Scrolls its child into view when it first appears, and only as far as it
/// has to. Key it on what makes it new, and a change of key is a new reveal.
///
/// Built for the golfer being scored: the keypad takes the lower half of the
/// screen, and on a six-man card it covered the last two rows. A row already
/// in full view does not move, so the list only shifts when it must.
class RevealOnMount extends StatefulWidget {
  const RevealOnMount({super.key, required this.child});

  final Widget child;

  @override
  State<RevealOnMount> createState() => _RevealOnMountState();
}

class _RevealOnMountState extends State<RevealOnMount> {
  static const _duration = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Each is a no-op unless the row is off that edge, so at most one moves
      // the list: down as scoring advances, up when a golfer is tapped back
      // to or a new hole opens on the first one.
      for (final policy in const [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        Scrollable.ensureVisible(context,
            duration: _duration, curve: Curves.easeOut, alignmentPolicy: policy);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
