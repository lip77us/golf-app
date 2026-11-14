"""
services/home_course.py
-----------------------
A golfer's home course sets itself after he has played a course twice.

Paul, 13 Nov 2026: *"after playing a course twice, move that course into the
user's home course if they have not selected one yet."*

The rules, each there for a stated reason:

* **Only when there is no home course.** A choice the golfer made is never
  overwritten, however often he plays somewhere else.
* **"Played" is a real score.** A round somebody set up and abandoned, or one
  he was seated in and never hit a shot in, is not a course he plays.
* **Two DISTINCT rounds**, not two scorecards in one round.
* **The course the round was just played on**, and only that one: the check
  runs when a round completes, so there is exactly one course in question and
  no scan of a golfer's whole history.
* **Linked golfers only.** `Player.home_course` is a personal preference of a
  logged-in golfer (see the field's comment); a roster guest has no one to
  prefer it.
* **Within the account.** A course is an account-owned copy, so a round
  played in a friend's account is a different `Course` row and never counts
  towards this one.

Called from `RoundCompleteView` on the flip to complete, inside a try/except:
a preference must never be able to break finishing a round.
"""
import logging

logger = logging.getLogger(__name__)

#: Rounds with a real score at one course before it becomes the home course.
ROUNDS_TO_HOME = 2


def rounds_played_at(player, course) -> int:
    """Distinct rounds in which [player] has at least one real score at
    [course]."""
    from scoring.models import HoleScore
    return (HoleScore.objects
            .filter(player=player, gross_score__isnull=False,
                    foursome__round__course=course)
            .values('foursome__round').distinct().count())


def maybe_set_home_course(player, course):
    """Make [course] the golfer's home course if the rules above say so.

    Returns the course when it was set, else None.
    """
    if player is None or course is None:
        return None
    if player.user_id is None or player.home_course_id is not None:
        return None
    if rounds_played_at(player, course) < ROUNDS_TO_HOME:
        return None
    player.home_course = course
    player.save(update_fields=['home_course'])
    return course


def promote_home_courses(round_obj) -> list:
    """Run [maybe_set_home_course] for every real, linked golfer in a round
    that has just completed. Returns `[(player, course)]` for those set."""
    from tournament.models import FoursomeMembership
    done = []
    members = (FoursomeMembership.objects
               .filter(foursome__round=round_obj, player__is_phantom=False,
                       player__user__isnull=False,
                       player__home_course__isnull=True)
               .select_related('player'))
    seen = set()
    for m in members:
        if m.player_id in seen:
            continue
        seen.add(m.player_id)
        try:
            set_to = maybe_set_home_course(m.player, round_obj.course)
        except Exception:  # pragma: no cover - a preference never blocks
            logger.exception('home_course: player %s round %s',
                             m.player_id, round_obj.id)
            continue
        if set_to is not None:
            done.append((m.player, set_to))
    return done
