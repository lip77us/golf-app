/// Rendering the skins validation rules — pure, so the board's copy is
/// testable and stated in one place.
///
/// **The words are the SERVER'S.** `summary['skin_rules']` is built by
/// `services.skin_rules.rules_line()`, and this splits it rather than
/// re-deriving it from `skin_minimum` / `birdie_steal`. One rule, one place
/// that names it: a board that spelled the rules itself could come to
/// disagree with the engine deciding them, which is the whole failure the
/// `detail` / `problems` split was about.
///
/// The slugs are still read, but only for a yes/no — whether there IS a
/// minimum — never for its wording.
library;

/// The rules in force, one chip each, in the server's own words.
///
/// `[]` when neither rule is on, which the caller draws as nothing rather
/// than as "no minimum" at a group playing plain skins.
List<String> skinRuleChips(String skinRules) {
  if (skinRules.trim().isEmpty) return const [];
  return skinRules
      .split('·')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      // Sentence case for a pill: the server writes a phrase meant to sit in
      // running text ("net par or better to win"), and a chip is a label.
      .map((p) => p[0].toUpperCase() + p.substring(1))
      .toList();
}

/// What the rules in force COST a golfer — the server's sentence, verbatim.
///
/// With a minimum on, **a hole can go unwon with nobody tied** — plain skins
/// never does that — so a player looking at a carried pot needs the reason.
/// That consequence is the point of putting any of this on the board.
///
/// It used to be derived here from the slugs, which made the client a second
/// place the rule was worded. It was worded in FIVE, and by the time Design
/// read them they disagreed: the steal's note said a gross birdie `beats a
/// lower net score`, which was never the rule — it beats a net BIRDIE, and a
/// net eagle still wins. Now `services.skin_rules.rules_note` writes it and
/// this returns it.
String skinRuleNote(String? serverNote) => (serverNote ?? '').trim();

/// One option's words, for a setup screen describing a rule nobody has
/// chosen yet — which the in-force note cannot answer. Keyed as the server
/// keys them: `net_par`, `gross_par`, `birdie_steal`.
///
/// `null` when the server did not send a catalogue, so a caller can tell
/// "no such option" from "an option with no words".
Map<String, String>? skinRuleCopy(List? catalogue, String key) {
  if (catalogue == null) return null;
  for (final row in catalogue) {
    if (row is Map && row['key'] == key) {
      return {
        'label': row['label']?.toString() ?? '',
        'note' : row['note']?.toString() ?? '',
      };
    }
  }
  return null;
}
