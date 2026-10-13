/// utils/skins_cards.dart
///
/// Who shares a scorecard in a Multi-Group Skins round.
///
/// A group here is a `Foursome` row, which is a scorecard, which is ONE
/// person keeping the score. The pool federates across them — that is the
/// whole game — so the sizes are genuinely arbitrary: Paul's round on 12 Oct
/// 2026 was a 15-foursome shotgun whose pool was one full foursome playing
/// together, two individuals and a twosome. **4, 1, 1, 2.** Neither "everyone
/// solo" nor "fill groups of four" describes that.
///
/// The rules live here rather than in the screen because two of them decide
/// whether a round can be created at all, and a rule you can only reach by
/// building a widget is a rule nobody can test.
library;

/// The server caps a group at four — it is a foursome.
const int kMaxCardSize = 4;

/// The cards, in group order, each as the ids on it.
///
/// Keyed by the stored group number, which can have gaps (moving the last
/// golfer off card 2 leaves 1 and 3). The DISPLAY label comes from position,
/// not from this key, so the list never reads "Group 1, Group 3".
Map<int, List<int>> cardsOf(Map<int, int> playerGroups) {
  final out = <int, List<int>>{};
  final numbers = playerGroups.values.toSet().toList()..sort();
  for (final n in numbers) {
    out[n] = [
      for (final e in playerGroups.entries)
        if (e.value == n) e.key,
    ];
  }
  return out;
}

/// The lowest group number nobody is using.
int nextFreeCard(Iterable<int> used) {
  final taken = used.toSet();
  var g = 1;
  while (taken.contains(g)) {
    g++;
  }
  return g;
}

/// Can this golfer ante into the pool?
///
/// On Halved: always. Login-less: only when somebody ELSE on his scorecard
/// is — that golfer is the one who will enter his score, and without him
/// nobody can.
///
/// The per-golfer form of the rule `cardsProblem` states for a whole draw,
/// because the pool's roster screen asks it one row at a time. Both exist
/// because they are asked at different moments; neither should be the only
/// one, and they must agree.
///
/// Paul confirmed the strictness after testing (13 Oct 2026): an account
/// owner could in principle keep every card in his own round, but *"because
/// the golfers are spread throughout the course"* he is out playing and a
/// card two fairways away is not one he can keep.
bool canJoinPool({
  required bool isOnApp,
  required Iterable<bool> cardMatesOnApp,
}) =>
    isOnApp || cardMatesOnApp.any((on) => on);

/// Why this draw cannot be created yet, or null when it can.
///
/// Two rules, and the second is Paul's (13 Oct 2026), for the case where
/// Multi-Group Skins is the ONLY game being played:
///
///   *"it is only when sharing a card with somebody on halved"*
///
/// A golfer with no Halved account cannot be handed a phone to keep his own
/// score, so a solo card for him has nobody to enter it. On a card with a
/// member he is scored like any other guest — which the engine already
/// allows: `services.multi_skins.valid_participant_ids` admits host-round
/// members "(login-less OK)", and it was the PICKER that was stricter,
/// greying those golfers out entirely.
///
/// The other case Paul names — skins attached to groups that already exist —
/// is a different flow (a linked round, or a tournament foursome) and is not
/// this screen's to judge: those groups already have a scorer.
String? cardsProblem(
  Map<int, int> playerGroups, {
  required bool Function(int playerId) isOnApp,
  required String Function(int playerId) nameOf,
}) {
  final cards = cardsOf(playerGroups);

  final over = <String>[];
  for (final e in cards.entries) {
    if (e.value.length > kMaxCardSize) {
      over.add('${e.value.length} golfers on one card');
    }
  }
  if (over.isNotEmpty) {
    return 'A group is a foursome — at most $kMaxCardSize golfers share a '
        'scorecard (${over.join(', ')}).';
  }

  final stranded = <String>[];
  for (final ids in cards.values) {
    if (ids.any(isOnApp)) continue;
    stranded.addAll(ids.where((id) => !isOnApp(id)).map(nameOf));
  }
  if (stranded.isEmpty) return null;
  final who = stranded.length == 1
      ? stranded.single
      : '${stranded.take(stranded.length - 1).join(', ')} and '
          '${stranded.last}';
  final verb = stranded.length == 1 ? 'is not' : 'are not';
  return '$who $verb on Halved, so somebody has to keep their score — put '
      'them in a group with a golfer who is.';
}
