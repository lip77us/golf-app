/// utils/result_hold.dart
///
/// Which holes are still owed their result after a score was posted.
///
/// Annandale Friday's tray reports the hole just played, so the next-hole
/// button waits for it. The wait is bounded because the scores are already
/// saved on the phone by then: this is only how long a group is asked to look,
/// and a bad signal must never strand them on a hole.
library;

import 'dart:async';

class ResultHold {
  ResultHold({required this.wait, required this.onChanged});

  final Duration wait;
  final void Function() onChanged;

  final Map<int, int>   _inFlight = {};
  final Map<int, Timer> _timers   = {};
  final Set<int>        _answered = {};

  /// Posted, unanswered and inside the wait.
  bool pending(int hole) => _inFlight.containsKey(hole);

  /// The server has answered the latest post for this hole, which can be a
  /// moment before the local queue says so.
  bool answered(int hole) => _answered.contains(hole);

  void hold(int hole) {
    _answered.remove(hole);
    _inFlight[hole] = (_inFlight[hole] ?? 0) + 1;
    _timers[hole]?.cancel();
    _timers[hole] = Timer(wait, () {
      _inFlight.remove(hole);
      _timers.remove(hole);
      onChanged();
    });
  }

  /// One post answered. An edit made while an earlier post was in flight has
  /// its own answer coming, and the earlier one does not describe it.
  void answer(int hole) {
    final left = (_inFlight[hole] ?? 0) - 1;
    if (left > 0) {
      _inFlight[hole] = left;
      return;
    }
    _inFlight.remove(hole);
    _timers.remove(hole)?.cancel();
    _answered.add(hole);
  }

  void clear() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _inFlight.clear();
    _answered.clear();
  }
}
