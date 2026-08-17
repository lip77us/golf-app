import 'package:flutter/widgets.dart';

/// Keeps several horizontal scroll views at the same offset.
///
/// The championship board draws one round column per round, and six rounds
/// will not fit beside a name and a total at 390px. So the round columns are
/// their own horizontal strip — and **every row has to scroll with the
/// header**, or the numbers under R4 stop being R4's.
///
/// Flutter's [ScrollController] attaches to one view at a time, so a shared
/// controller is not an option. This hands out one controller per row and
/// mirrors any movement onto the others, guarding against the feedback loop
/// that mirroring would otherwise cause.
///
/// Usage:
/// ```dart
/// final group = SyncedScrollGroup();          // dispose() with the State
/// ...
/// SingleChildScrollView(
///   scrollDirection: Axis.horizontal,
///   controller: group.attach(),
///   child: ...,
/// )
/// ```
class SyncedScrollGroup {
  final List<ScrollController> _controllers = [];
  bool _mirroring = false;

  /// The offset every member sits at. Survives rows being built and destroyed
  /// as the list scrolls vertically, so a row that scrolls into view arrives
  /// showing the same rounds as the header.
  double offset = 0;

  ScrollController attach() {
    final c = ScrollController(initialScrollOffset: offset);
    c.addListener(() => _mirror(c));
    _controllers.add(c);
    return c;
  }

  void _mirror(ScrollController source) {
    if (_mirroring || !source.hasClients) return;
    _mirroring = true;
    offset = source.offset;
    for (final c in _controllers) {
      if (identical(c, source) || !c.hasClients) continue;
      if ((c.offset - offset).abs() > 0.5) c.jumpTo(offset);
    }
    _mirroring = false;
  }

  /// Jump the whole strip to the far right.
  ///
  /// The board **opens scrolled to the most recent round**, which is what
  /// anybody opening it mid-tournament came for; the earlier rounds are a
  /// swipe to the right.
  void jumpToEnd() {
    for (final c in _controllers) {
      if (!c.hasClients) continue;
      final max = c.position.maxScrollExtent;
      if (max > 0) {
        offset = max;
        c.jumpTo(max);
      }
      break;
    }
    for (final c in _controllers) {
      if (c.hasClients && (c.offset - offset).abs() > 0.5) c.jumpTo(offset);
    }
  }

  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _controllers.clear();
  }
}
