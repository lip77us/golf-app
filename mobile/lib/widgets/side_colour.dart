import 'package:flutter/material.dart';

import '../game_colors.dart';
import '../theme/halved_brand.dart';

/// The two fixed sides of a 2v2 game, on a light card and on a dark tray.
///
/// **Blue and orange, not the packets' pine and clay.**
/// `docs/color-standard.md` is explicit: green, red and grey mean win, loss
/// and neutral and are never a team. The golfer rows on the score-entry
/// screen have drawn Las Vegas and Fourball that way since they shipped, and
/// a header or a tray in a different colour from the rows it describes is
/// worse than one in a different colour from the design.
///
/// `onDark3` is the tray's blue: the pale blue-grey the packets draw is
/// indistinguishable from the tray's own label grey, which is why that token
/// exists.
///
/// Shared because Las Vegas needed it and Fourball needed the same thing an
/// hour later — second user is when a rule earns a module.
Color sideColour(int side, {bool onDark = false}) {
  if (onDark) return side == 1 ? Halved.onDark3 : Halved.onDark2;
  return side == 1 ? GameColors.team1 : GameColors.team2;
}
