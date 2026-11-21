"""
services/live_activity_claremont_push.py
----------------------------------------
The Claremont lock-screen pushes (`handoff-claremont`, section 5).

One event rings, for the four golfers in the match: **a press that starts on
its own** — the top game at 2 down in a nine, the bottom at 4 points down.
Claremont has no manual presses, so there is nothing else to announce.

**Fired once**, on `NassauGame.announced` (NULL = nothing pushed yet, so the
first call records what already happened without announcing it; a round under
way when this ships does not ring four phones with its history). Same
mechanism as Nassau Nine and Annandale Friday.

Called once per posted score from `push_round`, never per recipient.
"""
import logging

logger = logging.getLogger(__name__)


def _label(people) -> str:
    return ' & '.join(((p.get('short_name') or p.get('name') or '')
                       .split(' ')[0]) for p in people)


def _down_before(summary: dict, press: dict, bottom: bool):
    """Which side was down going into the press: +1 side 1, −1 side 2, None
    if the score cannot say. Read off the hole BEFORE it starts, in play
    order, from the nine's own margin."""
    nine = press.get('nine') or 'front'
    key = ('bottom_' if bottom else '') + f'{nine}9_margin'
    holes = summary.get('holes') or []
    start = press.get('start_hole')
    prev = None
    for i, h in enumerate(holes):
        if h.get('hole') == start:
            prev = holes[i - 1] if i > 0 else None
            break
    else:
        prev = holes[-1] if holes else None
    margin = (prev or {}).get(key)
    if margin:
        return 1 if margin < 0 else -1
    return None


def _events(summary: dict) -> list:
    """`(key, build(reader_side) -> alert)` for every automatic press."""
    teams = summary.get('teams') or {}
    names = {1: _label(teams.get('team1') or []),
             -1: _label(teams.get('team2') or [])}
    stake = float(summary.get('press_unit') or summary.get('bet_unit') or 0)
    out = []
    for bottom, presses in ((False, summary.get('presses') or []),
                            (True, summary.get('bottom_presses') or [])):
        for p in presses:
            if p.get('press_type') != 'auto':
                continue
            start, end = p.get('start_hole'), p.get('end_hole')
            down = _down_before(summary, p, bottom)
            nine = p.get('nine') or 'front'

            def build(reader, down=down, bottom=bottom, start=start,
                      end=end, nine=nine):
                who = names[down] if down is not None else None
                if down == reader:
                    who = 'You'
                went = ('4 points down' if bottom else '2 down')
                game = 'the bottom' if bottom else 'the top'
                lead = (f'{who} {"are" if who == "You" else "is"} pressed on '
                        f'{game}: {went} on the {nine}, so '
                        if who else f'A press on {game}: ')
                return {
                    'title': 'Auto press',
                    'body': (f'{lead}a ${stake:,.0f} press starts on hole '
                             f'{start}. It runs to hole {end}.'),
                }
            out.append((f'{"bot" if bottom else "top"}:{nine}:{start}', build))
    return out


def claremont_alerts(round_obj) -> dict:
    """`{player_id: alert}` for the presses this posted score produced."""
    from games.models import NassauGame
    from services.nassau import nassau_summary

    alerts: dict = {}
    for game in (NassauGame.objects
                 .filter(foursome__round=round_obj, game_type='nassau',
                         variant='claremont')
                 .select_related('foursome')):
        summary = nassau_summary(game.foursome, 'nassau')
        if not summary:
            continue
        events = _events(summary)
        current = {key for key, _ in events}
        if game.announced is None:
            game.announced = sorted(current)
            game.save(update_fields=['announced'])
            continue
        seen = set(game.announced)
        fresh = [e for e in events if e[0] not in seen]
        if not fresh:
            continue
        game.announced = sorted(seen | current)
        game.save(update_fields=['announced'])
        teams = summary.get('teams') or {}
        # Several at once: the latest one is what the phone says.
        _key, build = fresh[-1]
        for reader, side in ((1, 'team1'), (-1, 'team2')):
            for p in teams.get(side) or []:
                alerts[p.get('player_id')] = build(reader)
    return alerts
