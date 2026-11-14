/// The score entry app bar's title (`handoff-score-entry-template`): the
/// **course name** on top, and under it the game and where the group is —
/// `Fourball · Thru 6`.
///
/// The game used to be the title and the course sat in the hole header. The
/// template swaps them: a golfer knows which game he is playing, and which
/// course is the part that tells two rounds apart.
///
/// The stake (`$20 a man` in the design) is deliberately not drawn: it is a
/// skin in one game, a point in another and a press in a third, and a wrong
/// stake in the title is worse than none. It goes in where a game states it
/// plainly.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

class ScoreEntryTitle extends StatelessWidget {
  /// The course. Falls back to [subtitle] alone when empty.
  final String course;

  /// `Fourball · Thru 6`.
  final String subtitle;

  const ScoreEntryTitle({
    super.key,
    required this.course,
    required this.subtitle,
  });

  /// `Game · Thru 6`, or just the game before anything is scored.
  static String subtitleFor(String game, int thru) =>
      thru > 0 ? '$game · Thru $thru' : game;

  @override
  Widget build(BuildContext context) {
    final title = course.isNotEmpty ? course : subtitle;
    final under = course.isNotEmpty ? subtitle : '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Halved.sectionHead().copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                height: 1.15,
                color: Halved.deepPine)),
        if (under.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(under,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Halved.body(color: Halved.muted, weight: FontWeight.w500)
                    .copyWith(fontSize: 12, height: 1.3)),
          ),
      ],
    );
  }
}
