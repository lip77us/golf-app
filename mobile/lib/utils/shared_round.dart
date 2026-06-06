import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

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
