import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// The rules a board is being played under, as a strip of small chips.
///
/// Asked for by Paul on 28 Oct 2026: *"It would be good to know the settings
/// that I am playing with in the leaderboard… In all games."*
///
/// **The words are the SERVER'S.** Every game block carries a `settings` list
/// built by `services/game_settings.py`, and this renders it verbatim rather
/// than deriving labels from slugs. One place names a handicap mode; twenty
/// five boards spelling it themselves is how `gross_to_par` ended up with
/// three copies and one of them wrong, and it is the same call the skins
/// rules chip already made.
///
/// **A neutral outline, never a filled or coloured chip.** Green is this
/// app's voice for something happening *to* you — strokes, bets, doubles —
/// and a handicap allowance is a fact about the round. Same reasoning as
/// `combo_tee_chip`.
class GameSettingsStrip extends StatelessWidget {
  const GameSettingsStrip(this.chips, {super.key, this.padding});

  final List<String> chips;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 5,
        children: [for (final c in chips) _Chip(c)],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: Halved.cardBorder, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: Halved.muted)),
      );
}

/// The chips on a leaderboard block or a per-group row, or `[]`.
///
/// `[]` means the game has no settings to state — an unconfigured game, or a
/// multi-group block whose groups disagree, where the server deliberately
/// leaves the block blank and puts them on each group instead.
List<String> settingsChipsOf(Map? m) {
  final raw = m?['settings'];
  if (raw is! List) return const [];
  return [for (final c in raw) if (c is String && c.isNotEmpty) c];
}
