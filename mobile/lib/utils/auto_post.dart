/// Should the hole on screen be saved without anybody asking?
///
/// **A tray game's hole posts itself**, because the tray reports the
/// SERVER's result: a hole left unsent raises a tray with nothing in it and
/// the group sits on `Getting result…` for ever.
///
/// It used to be triggered by the KEYSTROKE — the last score fired the save
/// — and that is a race, because the condition depends on a hole card the
/// screen fetches asynchronously. A group that typed four scores before the
/// card arrived passed the gate while it was still false, and nothing ever
/// came back to try again. Reported from a Las Vegas round on 8 Nov 2026,
/// sitting on `Getting result…` with the hole missing from the scorecard.
///
/// So it is a question asked on every build instead, and
/// [pendingSignature] is what stops it being asked twice: it changes only
/// when the scores do, so a save that FAILS is not retried in a loop (the
/// snackbar carries the Retry), and a correction after one is.
bool shouldAutoPost({
  /// This hole ends in a tray — `_raisesTray` on the screen.
  required bool traysHere,

  /// 40 Balls posts when the group picks its count, not on a score.
  required bool fortyBalls,
  required bool submitting,

  /// Every golfer who is going to score the hole has.
  required bool holeReady,

  /// [pendingSignature] of the hole on screen; empty when nothing is
  /// waiting to be saved.
  required String pendingSig,

  /// The signature last posted without being asked, or null.
  required String? lastPosted,
}) =>
    traysHere &&
    !fortyBalls &&
    !submitting &&
    holeReady &&
    pendingSig.isNotEmpty &&
    pendingSig != lastPosted;

/// A stable description of what is waiting to be saved for [hole].
///
/// Empty when nothing is. Sorted, so the same edits in a different order are
/// the same signature and are not posted twice.
String pendingSignature(int hole, Map<int, int>? edits) {
  if (edits == null || edits.isEmpty) return '';
  final keys = edits.keys.toList()..sort();
  return '$hole:${keys.map((k) => '$k=${edits[k]}').join(',')}';
}
