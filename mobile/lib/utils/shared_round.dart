import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../screens/tournament_leaderboard_screen.dart';

/// Open a round shared with me (a tournament / multi-group skins game a friend
/// or TD added me to). First calls `join` — which idempotently mirrors the TD
/// into my "My Golfers" roster and copies the course into my account — then
/// opens the round so I can score my own group and see the leaderboard.
/// Join failures are non-fatal: we open the round regardless.
Future<void> openSharedRound(BuildContext context, int roundId) async {
  final auth = context.read<AuthProvider>();
  final nav  = Navigator.of(context);
  try {
    await auth.client.joinRound(roundId);
  } catch (_) {
    // Non-fatal — the round still opens; the mirror will retry next open.
  }
  await nav.pushNamed('/round', arguments: roundId);
}

/// Open a round/tournament I was invited to WATCH (read-only). Joins
/// best-effort (mirrors the inviter into My Golfers), then opens the read-only
/// LEADERBOARD — not the score-entry round screen, because a watcher observes
/// rather than plays. Mirrors the behaviour of the old "Shared with me" screen.
Future<void> openWatchedRound(
    BuildContext context, SharedRoundSummary r) async {
  final client = context.read<AuthProvider>().client;
  final nav    = Navigator.of(context);
  try {
    if (r.isTournament) {
      await client.joinTournament(r.id);
    } else {
      await client.joinRound(r.id);
    }
  } catch (_) {/* non-fatal — open the leaderboard anyway */}
  if (!context.mounted) return;
  if (r.isTournament) {
    nav.push(MaterialPageRoute(
      builder: (_) => TournamentLeaderboardScreen(
          tournamentId: r.id, tournamentName: r.groupLabel),
    ));
  } else {
    nav.pushNamed('/leaderboard', arguments: r.id);
  }
}
