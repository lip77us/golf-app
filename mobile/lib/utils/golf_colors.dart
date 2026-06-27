// Standard golf-scoreboard colours for scores expressed RELATIVE TO PAR:
//
//   under par   → red
//   par / over  → null  (use the widget's default text colour, i.e. black)
//
// Returning `null` for par/over means callers don't need a theme — a `Text`
// with `color: null` just keeps its default colour.
//
// Apply these ONLY to things that are a score-vs-par (per-hole scores,
// net-to-par totals, scorecards, leaderboards).  For money, round/match status,
// validation and errors, keep normal UI semantics (red = bad) — golf's inverted
// "red = good" is a score-domain convention, not a global one.
import 'package:flutter/material.dart';

/// Red used for under-par scores.
final Color underParColor = Colors.red.shade700;

/// Colour for a raw [score] vs its hole [par] (e.g. gross 3 on a par-4 hole).
/// Under par → red; par or over → null (default text colour).
Color? scoreColor(int? score, int? par) {
  if (score == null || par == null) return null;
  return score < par ? underParColor : null;
}

/// Colour for a value already expressed RELATIVE to par ([toPar]: -2, 0, +3 …).
/// Under par (negative) → red; even or over → null (default text colour).
Color? toParColor(int? toPar) {
  if (toPar == null) return null;
  return toPar < 0 ? underParColor : null;
}
