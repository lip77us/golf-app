import 'package:flutter/material.dart';

/// Halved game-color standard — one source of truth so casual games stop
/// drifting. See docs/color-standard.md for the rationale.
///
/// The core rule: **green / red / grey mean *meaning* (win, loss, neutral) and
/// are never a team.** Teams use **blue / orange** — unambiguous, high-contrast,
/// colour-blind-friendly, and they never collide with the money/win semantics
/// (and they sidestep the red/blue political read).
class GameColors {
  GameColors._();

  // ── Sides / teams ─────────────────────────────────────────────────────────
  // Used by casual two-side games (Nassau, 18-Hole Match, Match Play, Triple
  // Cup) and by Wolf (Wolf-side vs Opponents). Deliberate deviations (see
  // docs/color-standard.md): cup games keep TD-configured team colours; Sixes
  // has no fixed team colours (partners rotate each segment).
  static final Color team1 = Colors.blue.shade700;     // Team 1 / Wolf-side
  static final Color team2 = Colors.orange.shade800;   // Team 2 / Opponents
  /// Pale fills for chips / badges / cell backgrounds.
  static final Color team1Bg = Colors.blue.shade50;
  static final Color team2Bg = Colors.orange.shade50;

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
