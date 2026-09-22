/// utils/match_notation.dart
/// -------------------------
/// **How this app writes a match margin**, in one place.
///
/// The vocabulary was already settled — score entry's fourball card has been
/// writing `2 UP thru 5`, `All Square thru 5` and `Paul & Mike win 3&2` since
/// it was built, and the Nassau, Pink Ball and Match Play screens all say
/// `All Square thru N`. What there was not was somewhere to READ it from, so
/// the standing row invented `1UP`, `1DN` and `2 and 5` on its first pass:
/// the same fact in a second vocabulary, on a screen that already had one.
///
/// Every surface that reports a match margin should come through here. The
/// cost of not doing it is not a typo — it is two screens describing one
/// match differently and a golfer wondering which is right.
library;

/// `1 UP` / `2 DOWN`. The space and the caps are the app's own.
///
/// Signed from whoever the caller is writing for: pass a positive number for
/// the side that is up. **A row that NAMES a side must pass that side's
/// margin** — `Jim, GL 1 DOWN` says the pair named is losing by one, which is
/// the opposite of what happened.
String marginLabel(int margin) =>
    '${margin.abs()} ${margin > 0 ? "UP" : "DOWN"}';

/// `3&2` — the tight ampersand the fourball card uses, and golf's own.
///
/// [remaining] is the holes that were left when it was decided. A match played
/// to the last hole has none, and takes [marginLabel] instead: two notations
/// because they are two different facts — how many holes were left, or that
/// there were none.
String closeOut(int margin, int remaining) => remaining > 0
    ? '${margin.abs()}&$remaining'
    : marginLabel(margin);

/// Level. Title case, as every screen in the app already writes it.
const String kAllSquare = 'All Square';

/// Nothing played yet.
///
/// **The standing row must not vanish before the first score.** The pill is
/// the way in and the whole reason D2 was chosen; losing it because there is
/// no standing to report yet would give up the feature for the stretch of the
/// round where a first-time player is most likely to go looking for the
/// leaderboard. So every game falls back to a state rather than to nothing.
///
/// `TEE OFF` is the lock screen's own word for this
/// (`services/live_activity_registry.thru_line`), which is where it comes
/// from rather than being invented here.
const String kTeeOff = 'Tee off';
