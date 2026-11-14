/// utils/nassau_team_style.dart
/// Central Nassau team styling — the colours ARE the team identity (we've
/// dropped the "T1 / T2" text everywhere in favour of colour). Team 1 = Blue,
/// Team 2 = Orange. Change the two constants here to restyle every Nassau
/// surface at once (setup swatches, name badges, won-by chips, presses strip).
/// See task #39 (eventually move off orange).

import 'package:flutter/material.dart';

import '../api/models.dart';

// The two team colours. These are compile-time consts (so const widgets like
// the presses strip can use them as defaults) that mirror GameColors.team1 /
// team2 — the shared palette every other 2-team game uses (pine and clay, since
// 14 Nov 2026). Keep them in sync with GameColors.
const Color kNassauTeam1Color = Color(0xFF0F6E56); // = GameColors.team1 (pine)
const Color kNassauTeam2Color = Color(0xFFB45309); // = GameColors.team2 (clay)

/// Team colour by 1-based team index (1 or 2).
Color nassauTeamColor(int team) =>
    team == 1 ? kNassauTeam1Color : kNassauTeam2Color;

/// Full colour name for a team ("Pine" / "Clay").
String nassauTeamColorName(int team) => team == 1 ? 'Pine' : 'Clay';

/// Single-letter colour badge ("P" / "C") for very tight spots (e.g. the
/// presses strip chips).
String nassauTeamColorShort(int team) => team == 1 ? 'P' : 'C';

/// Compact winner label for a progress grid — the winning team's initials
/// (nicer than a bare colour letter). Singles (one name): the first letter of
/// up to its first two words ("Paul Lipkin" → "PL", "Paul" → "P"). Doubles (two
/// names): each name's first initial ("PD"). Reusable across games (Nassau,
/// Fourball, …) — pass the team's player NAMES.
String teamInitialsFromNames(List<String> names) {
  final ns = names.map((n) => n.trim()).where((n) => n.isNotEmpty).toList();
  if (ns.isEmpty) return '?';
  if (ns.length == 1) return _nameInitials(ns.first);
  return ns.take(2).map((n) => n[0].toUpperCase()).join();
}

/// Nassau convenience over [teamInitialsFromNames].
String nassauTeamInitials(List<NassauPlayerInfo> members) =>
    teamInitialsFromNames(members.map((m) => m.name).toList());

String _nameInitials(String name) {
  final words =
      name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}

/// Label for a "won by" / hole-winner line: the golfer's short name when the
/// team is a single player (singles), else the colour name (doubles).
String nassauWonByLabel(int team, List<NassauPlayerInfo> members) {
  if (members.length == 1) {
    final m = members.first;
    return m.shortName.isNotEmpty ? m.shortName : m.name;
  }
  return nassauTeamColorName(team);
}

/// A small filled colour dot identifying a team.
Widget nassauTeamDot(int team, {double size = 12}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: nassauTeamColor(team),
        shape: BoxShape.circle,
      ),
    );
