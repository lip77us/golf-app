import '../api/models.dart';

/// **Skip** for the keypad (`handoff-score-entry-skip`), shared by every
/// screen that runs its own keypad. The cursor remembers where it is: the
/// next golfer owed a score is the first one DOWN the card from the golfer
/// last scored or skipped, wrapping to the top. Both the cursor and the
/// skipped marks belong to one hole and are ignored on any other, which is
/// what resets them when the hole changes. Device-only, never saved.
class SkipCursor {
  int? _cursorHole;
  int? _afterPid;
  int? _skipHole;
  final Set<int> _skipPids = <int>{};

  /// Skipped on [hole] and (the caller checks) still without a score.
  Set<int> skippedOn(int hole) =>
      _skipHole == hole ? _skipPids : const <int>{};

  void moveFrom(int hole, int pid) {
    _cursorHole = hole;
    _afterPid = pid;
  }

  void skip(int hole, int pid) {
    mark(hole, pid);
    moveFrom(hole, pid);
  }

  /// Marks [pid] skipped on [hole] without moving the cursor.
  void mark(int hole, int pid) {
    if (_skipHole != hole) {
      _skipHole = hole;
      _skipPids.clear();
    }
    _skipPids.add(pid);
  }

  /// A row tapped (`handoff-score-entry-tap`). The caller puts [to] at the
  /// keypad; this marks the golfer being left when tapping past him was a
  /// skip. The cursor moves when [to]'s score lands, like any other.
  void tapTo(int hole,
      {required int? from,
      required int to,
      required bool Function(int) owes}) {
    if (tapSkips(from: from, to: to, owes: owes)) mark(hole, from!);
  }

  /// Index of the next golfer owed a score, walking down from the cursor.
  int hot(int hole, List<Membership> players, bool Function(Membership) owes) =>
      hotIndex(hole, [for (final p in players) p.player.id],
          (id) => owes(players.firstWhere((p) => p.player.id == id)));

  /// The same, over a plain list of ids in the order the rows are drawn.
  int hotIndex(int hole, List<int> ids, bool Function(int) owes) {
    var from = -1;
    if (_cursorHole == hole && _afterPid != null) {
      from = ids.indexOf(_afterPid!);
    }
    for (var k = 1; k <= ids.length; k++) {
      final i = (from + k) % ids.length;
      if (owes(ids[i])) return i;
    }
    return -1;
  }

  /// The next golfer owed a score after [fromIdx], never [fromIdx] himself.
  int nextOwed(
      List<Membership> players, int fromIdx, bool Function(Membership) owes) {
    for (var k = 1; k < players.length; k++) {
      final i = (fromIdx + k) % players.length;
      if (owes(players[i])) return i;
    }
    return -1;
  }
}

/// **Tapping a golfer is Skip by pointing**: leaving a golfer who is owed a
/// score for another who is owed one skips him. Leaving or opening a golfer
/// who already has a score skips nobody.
bool tapSkips(
        {required int? from,
        required int to,
        required bool Function(int) owes}) =>
    from != null && from != to && owes(from) && owes(to);

/// What the keypad needs, worked out once per build.
class SkipKeys {
  final String? label;
  final bool enabled;
  final Set<int> dots;
  final bool skippedNow;
  const SkipKeys(this.label, this.enabled, this.dots, this.skippedNow);

  static SkipKeys of({
    required SkipCursor cursor,
    required int hole,
    required List<Membership> players,
    required int activeIdx,
    required Map<int, int> scores,
  }) {
    bool owes(Membership m) => !scores.containsKey(m.player.id);
    final me = players[activeIdx].player.id;
    final owed = scores[me] == null;
    final nxt = owed ? cursor.nextOwed(players, activeIdx, owes) : -1;
    final marks = cursor.skippedOn(hole);
    return SkipKeys(
      !owed
          ? null
          : (nxt < 0
              ? 'Skip'
              : 'Skip to ${players[nxt].player.name.split(' ').first} ›'),
      nxt >= 0,
      {
        for (var i = 0; i < players.length; i++)
          if (marks.contains(players[i].player.id) &&
              scores[players[i].player.id] == null)
            i,
      },
      marks.contains(me) && owed,
    );
  }
}
