/// widgets/standing_ribbon.dart
/// ----------------------------
/// **D2 — the standing folded into the app bar as a second line.**
///
/// From `handoff-foursome-formats/leaderboard-wayfinding.html`, chosen 22 Sep
/// 2026 over three alternatives. The problem it solves was reported from a
/// 38-person event: first-time players could not find the leaderboard, and
/// once in it they could not tell where they were or how to leave.
///
/// Three things fix that, and this carries two of them:
///
///   * **The way in carries a WORD, not a glyph.** A bare chevron — or the
///     leaderboard icon this replaces — is a weak target. `Leaderboard ›` as a
///     tinted pill is an ordinary one.
///   * **The standing is readable without going anywhere.** If the strip is
///     doing its job the tap never happens, which is the argument for putting
///     it at the top: it is drawn to be read, not tapped, and reading is
///     easier where the eye already goes when a phone comes out of a pocket.
///
/// **Why a second LINE rather than a band.** Score entry's top belongs to the
/// hole — number, par, index — and that is the header a golfer needs while
/// entering a number. A standing ROW above it makes two headers and pushes the
/// hole down the screen on every game in the app. Folding it into the bar
/// dodges that by not being a row: it costs 27px and adds no band at all,
/// against the pinned strip's 42px above a 76px hole nav.
///
/// The game name on line 1 is demoted to a centred bold 14 — **still a title,
/// just no longer the loudest thing in the bar.** A golfer knows which game he
/// is playing; he does not know where he stands.
///
/// ## The icon says which KIND of standing it is
///
/// **A trophy when the standing is a RESULT, money when it is a dollar
/// figure** — so one glance tells you what kind of number you are reading. The
/// strip appears in EVERY round and carries whatever that round's standing is;
/// this reverses design's earlier rule that it was a tournament-only feature.
///
/// The design writes the trophy case as "a place or a cup" and the money case
/// as "a casual game", which mapped the glyph to the round TYPE. Sixes is why
/// that is the wrong axis: it is a casual money game whose standing is a match
/// status — `1 UP thru 2` — and a money bag over a match score labels it as
/// the one thing it is not. The distinction is what the number IS.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

/// Which kind of standing the row is reporting — and so which glyph marks it.
enum StandingKind {
  /// The standing IS a money figure — `1 DOWN · +$10 so far`. 💰
  money,

  /// The standing is a result: a place in a field, a cup score, or a match
  /// status — `2nd of 38`, `Red 2–1`, `1 UP thru 2`. 🏆
  ///
  /// A money QUALIFIER beside it does not change the glyph. What the icon
  /// answers is what the headline number is, not whether the round has stakes.
  result,
}

class StandingRibbon extends StatelessWidget implements PreferredSizeWidget {
  final StandingKind kind;

  /// Where you stand — `1 UP thru 2`, `2nd of 38`, `Red 2–1`. Full weight: it
  /// is the reason the row exists.
  final String standing;

  /// The standing's own colour, where the game has a side to name AND that
  /// side still means on this row what it means everywhere else on the screen.
  ///
  /// Grey when null, which is the safe default and what D2 draws. A caller
  /// passes a colour only when it can say the row and the screen are about the
  /// same thing — see `SixesStanding.team` for the state where they are not.
  final Color? standingColor;

  /// The figure beside it — `+$10 so far`, `−1 · thru 4`, `4½ to win`. Muted,
  /// because it qualifies the standing rather than competing with it.
  final String figure;

  final VoidCallback onOpenLeaderboard;

  const StandingRibbon({
    super.key,
    required this.kind,
    required this.standing,
    required this.figure,
    required this.onOpenLeaderboard,
    this.standingColor,
  });

  /// 27px — the pill's 24 plus its breathing room, and the whole cost of the
  /// feature. Measured in the design; matched here rather than rounded, since
  /// the case for D2 over the pinned strip is made in exactly these pixels.
  static const double height = 27;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      // Tinted rather than white: at the top of the screen it has to separate
      // itself from the app bar above it, not from a scrolling list below.
      color: Halved.surface,
      padding: const EdgeInsets.only(left: 14, right: 8),
      child: Row(
        children: [
          Text(kind == StandingKind.money ? '💰' : '🏆',
               style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 7),
          // **The standing takes the width it needs; the slack goes in the
          // MIDDLE.** It used to sit before a `Spacer`, so the qualifier and
          // the pill were packed against it and the empty space sat to their
          // right — which truncated `Paul, Jim won 1 UP` to `Paul, Jim won…`
          // while a third of the row was blank. The money is a short fixed
          // string and belongs beside the pill; only this one ellipsises, and
          // only once there is genuinely nothing left.
          Flexible(
            child: Text(
              standing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // **Grey unless the caller can vouch for the colour.** Bold is
              // what makes the row lead; the hue is a second signal that has
              // to be earned, and in a game whose teams re-draw it is earned
              // only while this row and the rows below are about the same
              // match.
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700,
                  color: standingColor ?? Halved.muted),
            ),
          ),
          const Spacer(),
          if (figure.isNotEmpty) ...[
            Text(
              figure,
              maxLines: 1,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500,
                  color: Halved.muted),
            ),
            const SizedBox(width: 8),
          ],
          _LeaderboardPill(onTap: onOpenLeaderboard),
        ],
      ),
    );
  }
}

/// `Leaderboard ›` — 96 × 24, pine on a pine wash.
///
/// **The target is the whole row height, not the pill's own 24.** The design
/// asks for 44px of tap area that the pill does not visually occupy, padded
/// above and below into the bar. That cannot be built while the ribbon is the
/// AppBar's `bottom`: a child painted outside its parent's box does not
/// receive taps, so 44px here would need the toolbar row and this row to be
/// one render object — and the 17px it would reach upward lands under the
/// overflow button, which is its own 48px target. Two overlapping targets at
/// the same corner is a worse defect than a short one.
///
/// So the pill fills the row's 27px and takes 10px of horizontal padding
/// either side, and the REST of the row is tappable too — a miss to the left
/// lands on the same destination rather than on nothing. Short of 44
/// vertically, and deliberately so; revisit when this screen's app bar is
/// rebuilt as one widget.
class _LeaderboardPill extends StatelessWidget {
  final VoidCallback onTap;
  const _LeaderboardPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // The pine wash the app already uses for pills and readbacks.
            color: const Color(0xFFE4F2EA),
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Leaderboard',
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700,
                      color: Halved.pine)),
              SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 14, color: Halved.pine),
            ],
          ),
        ),
      ),
    );
  }
}
