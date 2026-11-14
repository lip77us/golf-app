/// The rules behind the Add players screen (`handoff-add-players`).
///
/// Everything a golfer sees decided — who the regulars are, what a search
/// finds, what the New golfer sheet says about strokes — is here and pure, so
/// it is testable without a screen and the screen cannot grow a second copy.
library;

import '../api/models.dart';

/// How many regulars get their own tile before **All golfers**.
const int kRegularsShown = 7;

/// The fewest digits of a saved mobile that count as a phone search.
const int kMinPhoneDigits = 3;

/// Digits in a complete US mobile number.
const int kMobileDigits = 10;

String digitsOf(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

/// Rounds shared with one golfer, from `GET /api/players/regulars/`.
class SharedRounds {
  final int rounds;
  final DateTime? lastPlayed;
  const SharedRounds(this.rounds, this.lastPlayed);
}

/// `{player_id: rounds}` as the screen holds it.
typedef RoundCounts = Map<int, SharedRounds>;

/// The words of [name], lower-cased.
List<String> _words(String name) => name
    .toLowerCase()
    .split(RegExp(r'[\s\-.]+'))
    .where((w) => w.isNotEmpty)
    .toList();

/// A name matches when **any word of it starts with** the query — *pa* finds
/// Samir **Pa**tel — and a multi-word query must match its words in order
/// against the name's words, so *sam pat* finds Samir Patel.
bool nameMatches(String name, String query) {
  final q = _words(query);
  if (q.isEmpty) return false;
  final w = _words(name);
  // Slide the query's words along the name's: each query word is the start of
  // a name word, consecutively.
  for (var i = 0; i + q.length <= w.length; i++) {
    var ok = true;
    for (var j = 0; j < q.length; j++) {
      if (!w[i + j].startsWith(q[j])) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

/// Three or more digits that appear in the golfer's saved mobile.
bool phoneMatches(String savedPhone, String query) {
  final q = digitsOf(query);
  if (q.length < kMinPhoneDigits) return false;
  return digitsOf(savedPhone).contains(q);
}

/// Whether what was typed is a phone search rather than a name: digits and
/// nothing but punctuation around them.
bool looksLikePhone(String q) {
  final digits = digitsOf(q);
  if (digits.length < kMinPhoneDigits) return false;
  return !RegExp(r'[A-Za-z]').hasMatch(q);
}

/// The golfers the screen offers as **Your regulars**: the seven you have
/// finished the most rounds with, most first, ties to the more recent.
///
/// Only a golfer who is in [roster] can be offered, and never [meId] or a
/// phantom. A golfer with no finished rounds is not a regular, so a new
/// account's grid is empty rather than seven strangers.
///
/// **[exclude] is who is already seated**, and the grid is built from what is
/// left: a regular leaves the grid the moment he is chosen, and the next most
/// played takes his tile, so there are still up to [limit] to choose from.
List<PlayerProfile> regularsOf(
  List<PlayerProfile> roster,
  RoundCounts counts, {
  required int? meId,
  int limit = kRegularsShown,
  Set<int> exclude = const {},
}) {
  final eligible = [
    for (final p in roster)
      if (!p.isPhantom &&
          p.id != meId &&
          !exclude.contains(p.id) &&
          (counts[p.id]?.rounds ?? 0) > 0)
        p
  ];
  eligible.sort(_byRounds(counts));
  return eligible.take(limit).toList();
}

/// Everyone in [roster] but [meId] and phantoms, regulars first then the rest,
/// most rounds first, then A–Z — the order of the All golfers sheet.
List<PlayerProfile> allGolfersOf(
    List<PlayerProfile> roster, RoundCounts counts, {required int? meId}) {
  final all = [
    for (final p in roster)
      if (!p.isPhantom && p.id != meId) p
  ];
  all.sort(_byRounds(counts));
  return all;
}

int Function(PlayerProfile, PlayerProfile) _byRounds(RoundCounts counts) =>
    (a, b) {
      final ra = counts[a.id]?.rounds ?? 0, rb = counts[b.id]?.rounds ?? 0;
      if (ra != rb) return rb.compareTo(ra);
      final da = counts[a.id]?.lastPlayed, db = counts[b.id]?.lastPlayed;
      if (da != null && db != null && da != db) return db.compareTo(da);
      if ((da == null) != (db == null)) return da == null ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    };

/// What a search for [query] finds among **your golfers**: a name match or a
/// phone match, never a phantom or [meId].
///
/// **Regulars are found too** (Paul, 14 Nov 2026). The handoff kept them out of
/// the results because they were already in the grid above; but a golfer
/// searched for is a golfer wanted NOW, wherever he happens to be listed, and a
/// seated regular has left the grid anyway.
List<PlayerProfile> searchYourGolfers(
  List<PlayerProfile> roster,
  String query, {
  required int? meId,
  RoundCounts counts = const {},
}) {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final hits = [
    for (final p in roster)
      if (!p.isPhantom &&
          p.id != meId &&
          (nameMatches(p.name, q) || phoneMatches(p.phone, q)))
        p
  ];
  hits.sort(_byRounds(counts));
  return hits;
}

/// *played once* / *played twice* / *played 5 times* / *not played yet*.
String playedLabel(int rounds) {
  if (rounds <= 0) return 'not played yet';
  if (rounds == 1) return 'played once';
  if (rounds == 2) return 'played twice';
  return 'played $rounds times';
}

/// `(415) 555-0100`, built up as digits arrive. A leading country `1` is
/// dropped so a pasted `+1 415…` formats the same; anything past ten digits
/// is ignored.
String formatMobile(String raw) {
  var d = digitsOf(raw);
  if (d.length == 11 && d.startsWith('1')) d = d.substring(1);
  if (d.length > kMobileDigits) d = d.substring(0, kMobileDigits);
  if (d.isEmpty) return '';
  if (d.length <= 3) return '($d';
  if (d.length <= 6) return '(${d.substring(0, 3)}) ${d.substring(3)}';
  return '(${d.substring(0, 3)}) ${d.substring(3, 6)}-${d.substring(6)}';
}

/// A full ten-digit mobile.
bool mobileComplete(String raw) {
  var d = digitsOf(raw);
  if (d.length == 11 && d.startsWith('1')) d = d.substring(1);
  return d.length == kMobileDigits;
}

/// `Jo` → `Jo`, `jo smith` → `Jo Smith`: each word capitalised, the rest left
/// as typed so `McCoy` survives.
String capitalizeName(String raw) => raw
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');

/// The name a new golfer is **saved** under: one name only becomes
/// *{Name} Guest* so two golfers called Jo do not collide in My Golfers.
String savedGuestName(String raw) {
  final n = capitalizeName(raw);
  if (n.isEmpty) return n;
  return n.contains(' ') ? n : '$n Guest';
}

/// The title on the dark card, which **carries what was typed**.
String newGolferCardTitle(String query) {
  final q = query.trim();
  if (q.isEmpty) return 'Add a new golfer';
  if (looksLikePhone(q)) return 'Add a new golfer with this number';
  return 'Add "${capitalizeName(q)}" as a new golfer';
}

/// What the New golfer sheet opens with for [query]: a name, or a mobile.
({String name, String mobile}) newGolferSeed(String query) {
  final q = query.trim();
  if (q.isEmpty) return (name: '', mobile: '');
  if (looksLikePhone(q)) return (name: '', mobile: formatMobile(q));
  return (name: capitalizeName(q), mobile: '');
}

/// The one button on the New golfer sheet, whose label follows the input.
String newGolferButtonLabel(String name, String mobile) {
  final n = capitalizeName(name);
  if (n.isEmpty) return 'Enter a name';
  final first = n.split(' ').first;
  return mobileComplete(mobile) ? 'Add $first & text the game' : 'Add $first';
}

/// A handicap index as typed: `12.4`, or `+2.3` for a plus handicap, which the
/// server stores as `-2.3`. Null when blank or not a number.
double? parseIndexTyped(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return null;
  var plus = false;
  if (t.startsWith('+')) {
    plus = true;
    t = t.substring(1);
  }
  final v = double.tryParse(t);
  if (v == null) return null;
  return plus ? -v.abs() : v;
}

/// The strokes line under the index field, worked out **against your index**.
///
/// Returns the sentence in three parts so the number can be drawn bold:
/// `before`, `number` (null for the sentences that have none) and `after`.
/// [slope] is the slope of the tee you will play (113 when unknown, which
/// makes the difference the plain index difference).
///
/// Two golfers on the same tee differ by `(theirs − yours) × slope / 113`, so
/// that is what is rounded; the rating and par cancel.
({String before, String? number, String after}) strokesLine({
  required double? yours,
  required String theirsTyped,
  int slope = 113,
}) {
  final theirs = parseIndexTyped(theirsTyped);
  if (theirs == null) {
    return (
      before: 'Leave blank and they play off scratch until it is set.',
      number: null,
      after: '',
    );
  }
  if (yours == null) {
    return (before: '', number: null, after: '');
  }
  final diff = ((theirs - yours) * slope / 113).round();
  if (diff == 0) return (before: 'Plays you even.', number: null, after: '');
  final n = diff.abs();
  final strokes = n == 1 ? 'stroke' : 'strokes';
  return diff > 0
      ? (before: 'Gets ', number: '$n', after: ' $strokes from you.')
      : (before: 'Gives you ', number: '$n', after: ' $strokes.');
}

/// The toast after a golfer is added. [inRound] is false on My Golfers, where
/// there is no round to start, so nothing is "texted when the round starts".
String addedToast({
  required String firstName,
  required bool hasNumber,
  required bool viaAccount,
  bool inRound = true,
}) {
  if (!inRound) {
    return viaAccount
        ? '$firstName added from Halved.'
        : '$firstName added to your golfers.';
  }
  if (viaAccount) {
    return '$firstName added from Halved. A push goes out at Start round.';
  }
  return hasNumber
      ? '$firstName added. The game is texted when the round starts.'
      : '$firstName added as a guest.';
}

/// The header over the seats: `SKINS · 3 of 4`.
String seatsHeader(String gameLabel, int seated, int seats) {
  final prefix = gameLabel.isEmpty ? '' : '${gameLabel.toUpperCase()} · ';
  return '$prefix$seated of $seats';
}

/// The right-hand side of the seats header, or null when there is none.
String seatsStatus(int seated, int seats) =>
    seated >= seats ? 'Full' : 'Add ${seats - seated} more';
