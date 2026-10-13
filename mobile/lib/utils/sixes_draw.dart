import '../api/models.dart';

/// Which Sixes match still needs its teams, and when to ask.
///
/// **Match 2 is the group's pick, not a reveal** (`handoff-solo-games` §3).
/// It used to be decided at SETUP and stored, so the slot machine was pure
/// theatre: the reel's `winnerIndex` always pointed at the pairing the server
/// had already written, and the screen's job was to uncover it. Nothing about
/// the teams could change when it ran.
///
/// Now nothing is drawn automatically. Matches 2 and 3 arrive with no teams
/// at all, the group spins or picks when match 1 is decided, and match 3 is
/// forced to the pairing left over — so each golfer partners each other
/// golfer exactly once, which is the format.
///
/// The per-device "already shown" flag is gone with it. It was a convenience
/// standing in for the rule, and it is the wrong shape for a decision: a
/// reinstall or a second phone lost it, and a draw that has not happened yet
/// has to be openable on any phone in the group.

/// The 1-based number of the first standard match with no teams, or null when
/// every match has them.
int? sixesMatchNeedingTeams(SixesSummary? summary) {
  if (summary == null) return null;
  final segs = summary.segments.where((s) => !s.isExtra).toList();
  for (var i = 0; i < segs.length; i++) {
    if (!segs[i].team1.hasPlayers || !segs[i].team2.hasPlayers) return i + 1;
  }
  return null;
}

/// Should the picker open on its own right now?
///
/// At the moment the match BEFORE it is decided — which is when the group is
/// standing on a tee asking whose side they are on — and not later: popping a
/// picker over a match already being played interrupts it to ask a question
/// the group has answered with their feet. Once that moment passes the banner
/// and its Set teams button are the way in.
bool shouldOpenSixesTeamPicker(SixesSummary? summary) {
  final needs = sixesMatchNeedingTeams(summary);
  if (needs == null || needs < 2) return false;
  final segs = summary!.segments.where((s) => !s.isExtra).toList();
  final prev = segs[needs - 2];
  final settled = prev.status == 'complete' || prev.status == 'halved';
  if (!settled) return false;
  // A hole scored in the match that needs teams means the group has played
  // on. It is still pickable — that is what the banner is for — but it no
  // longer earns a screen of its own.
  return segs[needs - 1].holes.isEmpty;
}
