// Share the round's watch link with a GROUP.
//
// Paul, 11 Oct 2026: "Can I just jump to my text with the watch link... that
// would allow me to send to a mix of halved users and non-halved users."
//
// **The native share sheet, not an `sms:` URL.** A bare `sms:?body=` opens a
// NEW message with no recipients, and iOS gives you no way to pick an
// existing group thread from there — you would retype the whole group. The
// share sheet puts recent conversations, group threads included, across the
// top, so the golf group is one tap away. That is the entire feature.
//
// **Nobody is recorded as a watcher here, and nobody needs to be.** A Halved
// recipient is filed by `WatchTokenResolveView` the moment they open the
// link; anyone else reads the web page, which is possession-gated and
// consults no Watcher row. `inviteWatcher` remains the tool for inviting ONE
// named spectator — it records the row up front and texts that person.
//
// The message is composed SERVER-side, like the settlement receipt: the text
// and anything else that quotes the link must not be able to disagree about
// what the round is called.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

/// Open the share sheet with the round's (or tournament's) watch link.
///
/// Pass exactly one id. Returns true when something was actually shared —
/// a dismissed sheet is not a share.
Future<bool> shareWatchLink(
  BuildContext context, {
  int? roundId,
  int? tournamentId,
}) async {
  assert((roundId == null) != (tournamentId == null),
      'Pass exactly one of roundId / tournamentId');
  final messenger = ScaffoldMessenger.of(context);
  final client = context.read<AuthProvider>().client;

  Map<String, dynamic> d;
  try {
    d = await client.getWatchLink(roundId: roundId, tournamentId: tournamentId);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    return false;
  }

  final text = (d['share_text'] as String?) ?? (d['watch_url'] as String?);
  if (text == null || text.isEmpty) {
    messenger.showSnackBar(const SnackBar(
      content: Text('This round has no watch link yet.')));
    return false;
  }

  final result = await Share.share(
    text,
    // The subject is only used by clients that have one (mail). Messages
    // ignores it, which is the common case here.
    subject: 'Follow along on Halved',
  );
  return result.status == ShareResultStatus.success;
}
