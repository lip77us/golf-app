/// widgets/side_game_marks.dart
/// ---------------------------
/// What a FIELD-WIDE side game adds to score entry, and nothing more
/// (`~/Downloads/design_handoff_stroke_play_side_games`).
///
/// A tournament group plays Stroke Play and carries side games the whole
/// field is in. Those games add only what the app cannot work out for itself:
///
///   • the ball game — who has the ball on this hole, and a switch to say it
///     is gone ([BallBadge], and `StrokePlayHoleTray`'s switch);
///   • Irish Rumble — nothing entered at all, just how many of the group's
///     balls count here ([RumbleCountStrip]).
///
/// **No side game RESULTS live on score entry.** Each game keeps its own
/// leaderboard tab; the packet says so twice, and a result here would be a
/// second place the money is stated.
///
/// Both marks are shared rather than private to one screen, for the reason
/// this codebase keeps relearning: *the games with their own play screen are
/// the ones that get missed.* The ball badge was drawn two different ways —
/// a secondary-coloured pill on `pink_ball_screen` and this deep-pine one on
/// score entry — for one fact.
///
/// **Spots is the packet's third side game and it needed NOTHING**, which is
/// worth saying out loud so the next reader does not "finish" the handoff by
/// building it. The packet draws a `− N +` stepper in a 74px column and calls
/// a spot "a count, not a type". That is Spots **v1**, and v1 was retired:
/// the group now ticks which spots it is playing before the round and the row
/// opens a tick sheet (`SpotsButton`, under the name). Reverting to a bare
/// count would take the names back off and make the app the authority on
/// which spots exist, which the checklist exists to avoid. Paul confirmed the
/// shipped control stands.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// Who carries the ball on this hole: a deep-pine pill with a golf ball and
/// the organiser's own name for the game ("Pink Ball", "Devil Ball", up to
/// 16 characters).
///
/// **Deep pine, because it is a ROLE and not a result** — the same reading
/// Hot Seat's gold badge gets on the same row. Carrying the ball is a fact
/// about whose score the group is relying on, which is a different question
/// from whether it was any good, so it must not borrow the win green.
///
/// Draw it only while the ball is a thing on this hole — `BallOnHole.liveHere`
/// is that one gate, and it is the server's.
class BallBadge extends StatelessWidget {
  final String gameName;

  /// Set on a row whose background is already dark, where the pill inverts.
  final bool onDark;

  const BallBadge({super.key, required this.gameName, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final ground = onDark ? Colors.white : Halved.deepPine;
    final ink = onDark ? Halved.deepPine : Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 2, 7, 2),
      decoration: BoxDecoration(
        color: ground,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _ball(ground),
        const SizedBox(width: 4),
        Text(
          gameName,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: ink,
            letterSpacing: .2,
          ),
        ),
      ]),
    );
  }

  /// A golf ball at 10px: white, a 2px ring of the pill's own ground, and a
  /// white core. The ring is what makes it read as a ball rather than a dot —
  /// on a deep pine pill a plain white circle is a bullet.
  Widget _ball(Color ground) => Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
            shape: BoxShape.circle, color: Colors.white),
        child: Center(
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: ground),
            child: Center(
              child: Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: Colors.white),
              ),
            ),
          ),
        ),
      );
}

/// The group strip over the score rows: "Your group" and, when Irish Rumble
/// is on, how many of the group's balls count on this hole.
///
/// **The caller draws it only when there IS a count** — a hole in no segment,
/// or a round not playing Irish Rumble, gets no strip at all rather than one
/// with an empty right-hand side. That is the whole reason the server sends a
/// nullable block instead of a figure with a zero: a strip reading `0 count`
/// claims a rule the calculator would not use, and a band saying only "YOUR
/// GROUP" is noise on a card whose rows are already the group.
class RumbleCountStrip extends StatelessWidget {
  /// Balls that count here, and the group's size as the calculator counts it.
  final int count;
  final bool allCount;

  /// What the left of the strip says. "Your group" on a tournament card.
  final String label;

  const RumbleCountStrip({
    super.key,
    required this.count,
    this.allCount = false,
    this.label = 'Your group',
  });

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: .4,
      color: Halved.muted,
    );
    return Container(
      color: const Color(0xFFF4F7F4),
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
      child: Row(children: [
        Expanded(child: Text(label.toUpperCase(), style: style)),
        const Text('IRISH RUMBLE', style: style),
        const SizedBox(width: 5),
        Container(
          width: 26,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Halved.deepPine,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
        const SizedBox(width: 5),
        // "all count" rather than the number again: the point of the words is
        // whether anybody's ball is idle, which is what a group checks before
        // deciding who can take a risk.
        Text(allCount ? 'ALL COUNT' : 'COUNT', style: style),
      ]),
    );
  }
}
