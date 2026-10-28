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

/// What a golfer actually sees, which is not the same as what was configured.
///
/// With a minimum on, **a hole can go unwon with nobody tied** — plain skins
/// never does that — so a player looking at a carried pot needs the reason.
/// That consequence is the point of putting any of this on the board.
String skinRuleNote({required String minimum, required bool birdieSteal}) {
  final hasMinimum = minimum == 'net_par' || minimum == 'gross_par';
  if (hasMinimum) return 'A hole where nobody qualifies goes unwon.';
  if (birdieSteal) return 'A gross birdie beats a lower net score.';
  return '';
}
