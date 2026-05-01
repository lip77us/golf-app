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
