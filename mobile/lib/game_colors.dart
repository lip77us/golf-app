import 'package:flutter/material.dart';

import 'theme/halved_brand.dart';

/// Halved game-color standard — one source of truth so casual games stop
/// drifting. See docs/color-standard.md for the rationale.
///
/// **Sides are pine, clay and slate** (`handoff-score-entry-template`, chosen by
/// Paul 14 Nov 2026): side 1 pine, side 2 clay, a third side slate. This
/// REVERSES the old rule that green could never be a team and teams were blue
/// and orange — there was nothing special about Sixes, Las Vegas and Fourball
/// that needed colours of their own, and one set of sides across every game is
/// worth more than the collision it risked. The win/loss semantics below are
/// unchanged; the screens that show both keep them apart by shade and by
/// context (a side is a bar, a header and a tray name; a win is a figure).
class GameColors {
  GameColors._();

  // ── Sides / teams ─────────────────────────────────────────────────────────
  // Used by casual two-side games (Nassau, 18-Hole Match, Match Play, Triple
  // Cup) and by Wolf (Wolf-side vs Opponents). Deliberate deviations (see
  // docs/color-standard.md): cup games keep TD-configured team colours; Sixes
  // has no fixed team colours (partners rotate each segment).
  static const Color team1 = Halved.pine;       // Side 1 / Wolf-side
  static const Color team2 = Halved.teamClay;    // Side 2 / Opponents
  static const Color team3 = Halved.teamSlate;   // a third side (Annandale)
  /// Pale fills for chips / badges / cell backgrounds.
  static const Color team1Bg = Color(0xFFE4F2EA);
  static const Color team2Bg = Color(0xFFFBEBDB);

  // ── Semantics (meaning — never a team) ────────────────────────────────────
  static final Color win     = Colors.green.shade700;  // win / up / +money
  static final Color loss    = Colors.red.shade700;    // loss / down / −money
  static final Color neutral = Colors.grey.shade600;   // halved / push / pending
  static final Color winBg   = Colors.green.shade100;
  static final Color lossBg  = Colors.red.shade100;

  // ── Score-vs-par fill (scorecard cells + score-entry squares) ─────────────
  /// Background fill for a score relative to par, graduated so the standout
  /// results read darker: net eagle-or-better and net double-bogey-plus get the
  /// DARKER green/red, while the everyday net birdie and net bogey get a SOFTER
  /// shade. `diff` = score − baseline (net par or gross par, per the caller).
  /// `parFill` is the exact-par color, which callers vary (white square vs grey
  /// chip), so it's passed in.
  static Color scoreFill(int diff, {Color parFill = Colors.white}) {
    if (diff <= -2) return Colors.green.shade400;  // net eagle or better — dark
    if (diff == -1) return Colors.green.shade100;  // net birdie — soft
    if (diff == 0)  return parFill;                // net par
    if (diff == 1)  return Colors.red.shade100;    // net bogey — soft
    return Colors.red.shade400;                     // net double bogey+ — dark
  }
}
