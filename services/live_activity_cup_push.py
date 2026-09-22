"""
services/live_activity_cup_push.py
----------------------------------
The team cup's two pushes — and only two.

**The casual cup pushes nothing**, and it is the same reason Wolf, Points and
Stableford are silent: four men in one group, the Fourball settles in front of
all four, and a push for it is a phone telling you what you just watched.

**The team cup is the opposite case, and the one the whole pattern was written
for.** Points land in groups an hour ahead of you and you will not hear about
them. But a six-group cup has twenty-four points, and a push per point is
twenty-four pushes — at which point the golfer turns the activity off and
loses the nineteen that were worth having.

So exactly two events fire:

* **Lead change** — including into and out of level, because level *is* a
  change of who is ahead. A second point that keeps it level is not.
* **Cup decided** — the half-point that puts it out of reach. Fires once and
  the activity settles under it.

Every other settled point is already on the card, a glance away. The activity
does not also flash.

## Why this needs to remember something

A lead change is not a property of the cup score; it is a property of **two**
cup scores, and the card is rebuilt from scratch on every request. So the last
score a push went out on is stored on the cup itself (`TeamTournament.
last_cup_push`), and the comparison happens exactly once per posted score
rather than once per recipient — four phones in a group must not fire four
pushes, and the group behind must not re-fire the same one.

That marker is also what makes the decided push fire once. Without it, every
score posted after the clinch is another `Blue take the Sheldon Cup`.
"""
import logging

logger = logging.getLogger(__name__)


def _score(v) -> str:
    """`3`, `2½` — the cup's own notation, matching the card's headline."""
    whole, half = divmod(round(float(v or 0) * 2), 2)
    return f'{whole}½' if half else f'{whole}'


def _leader(t1: float, t2: float) -> str:
    """`team1` | `team2` | `level`. **Level is a state, not a missing one** —
    that is what makes going level a lead change."""
    if t1 > t2:
        return 'team1'
    if t2 > t1:
        return 'team2'
    return 'level'


def _line(t1: float, t2: float, leader: str) -> str:
    """`1–0` from the LEADER's side, whichever team number he is.

    **Card order is colour; push order is the sentence**
    (`RULINGS-team-cup-lock.md` §2). On the card, order is the only thing
    saying whose number is whose, so it has to be a fixed axis. In a push the
    sentence names the leader before the score, so the order carries no
    information — it is free to be the one that reads naturally, and the
    natural one is the leader's number first. `Blue take the lead — 0–1` is a
    title that names a team and then shows them losing, which the only
    audience that matters reads as a bug.

    Level is symmetrical, so `level` and the halved cup keep team order and
    nothing about them moves.
    """
    return (f'{_score(t2)}–{_score(t1)}' if leader == 'team2'
            else f'{_score(t1)}–{_score(t2)}')


def _team_tournament(round_obj):
    """The cup this round belongs to, or None if it is not a cup round.

    A tournament round is not automatically a cup round — the round config is
    what says it contributes points — so both are checked.
    """
    from services.cup_standings import cup_round_live_summary
    tt = getattr(getattr(round_obj, 'tournament', None),
                 'team_tournament', None)
    if tt is None:
        return None
    if cup_round_live_summary(round_obj) is None:
        return None
    return tt


def _still_out(round_obj) -> str:
    """The body line. **What is true and useful**, rather than the narrative.

    The design's body reads `Group 2 took their Foursomes. First lead change
    since the turn.` Neither half is derivable from what the cup stores: the
    resolution that caused the change is not attributed to a group by any
    existing query, and *since the turn* needs a history nothing keeps. A
    push that guesses either would be wrong on a lock screen, which is the
    one place this set refuses to be — so the body says what is still out,
    which is the thing a captain asks next anyway.
    """
    from services.live_activity_triple_cup import _groups_still_out
    return _groups_still_out(round_obj)


def cup_alert(round_obj) -> dict | None:
    """The alert this posted score earns, or None — and it records what it saw.

    Called once per `push_round`, before the per-recipient loop. Returns
    `{'title': ..., 'body': ...}` for the two events and None for everything
    else, which is almost every score.

    **It writes even when it returns None.** The marker is *the last cup score
    observed*, not the last one pushed: without that, a cup that goes 8½–8½
    (fires) and then 8½–9½ would compare the second against a stale 8½–7½ and
    report a lead change that already happened.
    """
    tt = _team_tournament(round_obj)
    if tt is None:
        return None

    from services.cup_standings import cup_standings_summary
    try:
        cup = cup_standings_summary(round_obj.tournament)
    except Exception:  # pragma: no cover - a broken cup never blocks a score
        logger.exception('cup_alert: standings failed for round %s',
                         round_obj.id)
        return None

    t1 = float(cup.get('team1_points') or 0)
    t2 = float(cup.get('team2_points') or 0)
    decided = cup.get('winner_team') in (1, 2) or cup.get('cup_status') == 'tied'
    now = {'team1': t1, 'team2': t2, 'decided': decided}

    was = tt.last_cup_push or {}
    tt.last_cup_push = now
    tt.save(update_fields=['last_cup_push'])

    # Nothing to compare against. The first score of a cup is not a lead
    # change — somebody has to be ahead of somebody first.
    if not was:
        return None

    name1 = cup.get('team1_name') or 'Team 1'
    name2 = cup.get('team2_name') or 'Team 2'

    # **Decided outranks lead change**, and it fires once. A clinch is by
    # definition also a lead change, and two pushes for one half-point is the
    # noise this whole design is avoiding.
    if decided and not was.get('decided'):
        if cup.get('cup_status') == 'tied':
            return {'title': (f'The {tt.cup_name} is halved — '
                              f'{_line(t1, t2, "level")}'),
                    'body': 'Nothing left that can separate them.'}
        winning_team = 'team1' if cup.get('winner_team') == 1 else 'team2'
        winner = name1 if winning_team == 'team1' else name2
        return {'title': (f'{winner} take the {tt.cup_name} — '
                          f'{_line(t1, t2, winning_team)}'),
                'body': 'The half-point that put it out of reach.'}

    before = _leader(float(was.get('team1') or 0), float(was.get('team2') or 0))
    after = _leader(t1, t2)
    if after == before:
        return None

    line = _line(t1, t2, after)
    if after == 'level':
        return {'title': f'All square — {line}', 'body': _still_out(round_obj)}
    taker = name1 if after == 'team1' else name2
    return {'title': f'{taker} take the lead — {line}',
            'body': _still_out(round_obj)}
