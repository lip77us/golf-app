import 'package:flutter/material.dart';

import '../game_colors.dart';
import '../theme/halved_brand.dart';

/// The two fixed sides of a 2v2 game, on a light card and on a dark tray.
///
/// **Pine and clay** (`handoff-score-entry-template`; Paul, 14 Nov 2026). These
/// were blue and orange for a while, on the argument that green means a win and
/// must never be a team — and then Las Vegas, Fourball and Nassau each wore a
/// colour the template did not, for no reason particular to them. One set of
/// sides now: pine, clay, and slate for a third.
///
/// On the dark tray they are the template's own dark variants — bright mint and
/// `#F2A86E` — because pine on deep pine cannot be read.
///
/// Shared because Las Vegas needed it and Fourball needed the same thing an
/// hour later — second user is when a rule earns a module.
Color sideColour(int side, {bool onDark = false}) {
  if (onDark) return side == 1 ? Halved.onDark1 : Halved.onDark2;
  return side == 1 ? GameColors.team1 : GameColors.team2;
}
