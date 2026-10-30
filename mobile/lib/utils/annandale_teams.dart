/// utils/annandale_teams.dart
/// --------------------------
/// Annandale Friday's team rules on the phone: the default split, what is
/// wrong with a split, and the three matches a split makes.
///
/// **The server's twin is `services.annandale_friday`** (`shape_problem`,
/// `matches_for`), and the sentences here are its sentences, word for word.
/// The setup screen's matches box shows this one while the TD drags golfers
/// about, and the server shows its own if anything slips through — two
/// wordings for one refusal would read as two different problems.
/// `test/annandale_teams_test.dart` pins the strings.
library;

/// Golfers placed in order: pairs for six, a pair and a three for five.
List<List<int>> defaultTeams(List<int> ids) {
  if (ids.length == 6) {
    return [ids.sublist(0, 2), ids.sublist(2, 4), ids.sublist(4, 6)];
  }
  if (ids.length == 5) return [ids.sublist(0, 2), ids.sublist(2, 5)];
  return [List.of(ids)];
}

/// How many teams a group of [n] plays as.
int teamCountFor(int n) => n == 6 ? 3 : 2;

/// What is wrong with [teams], in a sentence — or null when it plays.
String? shapeProblem(List<List<int>> teams, {List<int>? roster}) {
  final ts = [for (final t in teams) if (t.isNotEmpty) t];
  final flat = [for (final t in ts) ...t];
  if (flat.length != flat.toSet().length) return 'A golfer is on two teams.';
  if (roster != null) {
    final r = roster.toSet();
    if (r.length != 5 && r.length != 6) {
      return 'Annandale Friday is for a group of 5 or 6 — this group has '
          '${r.length}.';
    }
    final missing = r.difference(flat.toSet()).length;
    if (missing > 0) {
      return '$missing golfer${missing > 1 ? 's are' : ' is'} not on a team.';
    }
    if (flat.toSet().difference(r).isNotEmpty) {
      return 'A team has a golfer who is not in this group.';
    }
  }
  final sizes = [for (final t in ts) t.length]..sort();
  if (flat.length == 6) {
    return _eq(sizes, [2, 2, 2]) ? null : 'Six golfers play as three pairs.';
  }
  if (flat.length == 5) {
    return _eq(sizes, [2, 3])
        ? null
        : 'Five golfers play as a pair and a three.';
  }
  return 'Annandale Friday is for a group of 5 or 6 — the teams hold '
      '${flat.length}.';
}

bool _eq(List<int> a, List<int> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]]
        .every((x) => x);

/// The three Nassaus [teams] make, in the server's match order — so the
/// preview's "match 2" is the leaderboard's match 2. Assumes a valid shape.
List<(List<int>, List<int>)> matchesFor(List<List<int>> teams) {
  final ts = [for (final t in teams) if (t.isNotEmpty) t];
  if (ts.length == 3) {
    final [a, b, c] = ts;
    return [(a, b), (a, c), (b, c)];
  }
  final pair = ts.firstWhere((t) => t.length == 2);
  final three = ts.firstWhere((t) => t.length == 3);
  final [x, y, z] = three;
  return [(pair, [x, y]), (pair, [x, z]), (pair, [y, z])];
}
