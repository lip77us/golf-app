/// utils/grouping.dart
/// --------------------
/// Group-size helpers that mirror the backend's services/round_setup.py
/// `_group_players()` logic.
///
/// Rule: fill foursomes first; put trailing threesomes at the end so no
/// group is ever smaller than 3 (except unavoidable edge cases like n=2/5).
///
/// Examples
/// --------
///  n= 8  →  [4, 4]
///  n= 9  →  [3, 3, 3]
///  n=10  →  [4, 3, 3]
///  n=11  →  [4, 4, 3]
///  n=12  →  [4, 4, 4]
///  n=13  →  [4, 3, 3, 3]
///  n=14  →  [4, 4, 3, 3]
///  n=15  →  [4, 4, 4, 3]
library;

/// Returns the list of group sizes for [n] players.
List<int> groupSizes(int n) {
  if (n <= 0) return [];
  final rem = n % 4;
  if (rem == 0) return List.filled(n ~/ 4, 4);

  // Number of trailing threesomes needed so no group is < 3:
  //   rem=3 → 1 threesome,  rem=2 → 2 threesomes,  rem=1 → 3 threesomes
  final trailing = <int, int>{3: 1, 2: 2, 1: 3}[rem]!;
  final minNeeded = trailing * 3; // minimum n for a clean split

  if (n < minNeeded) {
    // Unavoidable edge case (n=2, n=5): even distribution — can't avoid
    // a group smaller than 3.
    final ng   = (n / 4).ceil();
    final base = n ~/ ng;
    final ext  = n % ng;
    return List.generate(ng, (i) => base + (i < ext ? 1 : 0));
  }

  final fours = (n - trailing * 3) ~/ 4;
  return [...List.filled(fours, 4), ...List.filled(trailing, 3)];
}

/// Group sizes for a **pairs** field: twos all the way down, and a trailing
/// ONE when the field is odd (docs/design-review/handoff-team-pairs/SPEC.md
/// §3.1).
///
/// The odd golfer is left visible as a group of one on purpose. There is no
/// phantom partner to hide them behind — in fours the phantom is a handicap
/// device for a team that still hits four balls, and in pairs it would be an
/// imaginary partner taking half the shots in an alternate shot. So the field is
/// blocked and the block NAMES them: the fix is about one golfer, and the TD needs
/// to know which one is standing there.
///
///  n=12 → [2, 2, 2, 2, 2, 2]
///  n=13 → [2, 2, 2, 2, 2, 2, 1]
List<int> pairSizes(int n) {
  if (n <= 0) return [];
  return [...List.filled(n ~/ 2, 2), if (n.isOdd) 1];
}

/// **Playing**-group sizes for a pairs field: two pairs to a group.
///
/// A pair is the scoring unit; it is not the group that walks the course. Two
/// pairs go off each tee time as a foursome, share one scorer and one card,
/// and are scored apart — so the sheet is fours, with a twosome on the end
/// when the number of pairs is odd.
///
///  n= 4 → [4]
///  n= 6 → [4, 2]        one group of two pairs, one of a single pair
///  n=10 → [4, 4, 2]
///  n=12 → [4, 4, 4]
///  n=13 → [4, 4, 4, 1]  the odd golfer, left visible so the block can name them
List<int> pairPlayGroupSizes(int n) {
  if (n <= 0) return [];
  final pairs = n ~/ 2;
  return [
    ...List.filled(pairs ~/ 2, 4),
    if (pairs.isOdd) 2,
    if (n.isOdd) 1,
  ];
}

/// Split one playing group into its teams, by position.
///
/// The first two golfers are pair 1 and the next two are pair 2 — the order the TD
/// dragged them into on Groups & Tees, which is the same default the server
/// applies. A three-golfer group in **best ball** is ONE team of three, the
/// packet's odd-field way out and the only shape three golfers can legally take.
List<List<T>> splitIntoPairs<T>(List<T> group, {bool bestBall = false}) {
  if (group.isEmpty) return [];
  if (group.length == 3 && bestBall) return [List<T>.from(group)];
  final out = <List<T>>[];
  for (var i = 0; i < group.length; i += 2) {
    out.add(group.sublist(i, (i + 2).clamp(0, group.length)));
  }
  return out;
}

/// Whether a group of [groupSize] gets a phantom to fill it out.
///
/// [teamPlaySize] is the size a Team Play team fills to — 4 for a foursome
/// event, 2 for pairs — or null for every other shape, which fills to four.
///
/// **A pair is complete at two.** In fours the phantom is a handicap device
/// for a team that still hits four balls; in pairs it would be an imaginary
/// golfer taking half the shots in an alternate shot, so there is never one at
/// any roster size. An odd field is a problem to fix, not a gap to pad — the
/// Handicap step names the golfer standing there.
///
/// Kept here, next to the sizing rules, because "anything under four gets a
/// phantom" is an assumption that reappears wherever groups are drawn and had
/// already been written out twice.
bool groupNeedsPhantom(int groupSize, {int? teamPlaySize}) {
  if (teamPlaySize == 2) return false;
  return groupSize < (teamPlaySize ?? 4);
}

/// Returns the 1-based group number for the player at position [idx]
/// given a precomputed [sizes] list (from [groupSizes]).
int groupOf(int idx, List<int> sizes) {
  var cum = 0;
  for (var g = 0; g < sizes.length; g++) {
    cum += sizes[g];
    if (idx < cum) return g + 1;
  }
  return sizes.length;
}

/// Returns true when [idx] marks the start of a new group boundary
/// (i.e. it's the first player in a group other than group 1).
bool isGroupBoundary(int idx, List<int> sizes) {
  if (idx == 0) return false;
  var cum = 0;
  for (final s in sizes) {
    cum += s;
    if (idx == cum) return true;
    if (idx < cum) return false;
  }
  return false;
}
