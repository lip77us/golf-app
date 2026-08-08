import 'package:flutter/material.dart';

/// Canonical cup team colours — the six swatches the wizard's Teams step offers,
/// each a specific hex.  One source of truth so a side's badge is the exact
/// colour the captain picked, everywhere it is shown (wizard swatch, draft
/// board, round-groups).  Names match the server-side `TournamentTeam.colour`
/// values.
const List<(String, Color)> kCupTeamColours = <(String, Color)>[
  ('Red',    Color(0xFFB71C1C)),
  ('Blue',   Color(0xFF0D47A1)),
  ('Green',  Color(0xFF1B5E20)),
  ('Orange', Color(0xFFE65100)),
  ('Yellow', Color(0xFFF57F17)),
  ('Purple', Color(0xFF4A148C)),
];

/// Resolve a stored colour name to its swatch colour.  An unknown / legacy /
/// custom name falls back to a neutral grey so a side still shows *something*
/// rather than an invisible badge.
Color cupTeamColor(String name) {
  for (final c in kCupTeamColours) {
    if (c.$1.toLowerCase() == name.toLowerCase()) return c.$2;
  }
  return const Color(0xFF757575);
}
