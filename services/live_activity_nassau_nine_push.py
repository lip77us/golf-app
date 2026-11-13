"""
services/live_activity_nassau_nine_push.py
------------------------------------------
The Nassau Nine lock-screen pushes
(`handoff-lock-screens-mgskins-minisingles-nassaunine-solo`, section 3).

Two events make a sound, for the golfers in that match only:

* **a press** — auto (a side went 2 down) or called by hand;
* **the match closing out** — won before the last hole, or settled on it.

Everything else moves the card silently: a push for something the reader
watched is a phone telling him what he already knows. A press and a closed
match are different — the arithmetic decides them, not the putt.

**Fired once.** The events already announced live on `NassauGame.announced`,
written in the same call that reads them (the card is rebuilt from scratch on
every request and has no memory). NULL means nothing has been pushed yet: the
first call records what has already happened WITHOUT announcing it, so a round
under way when this ships does not ring four phones with its history.
Same mechanism as `AnnandaleFridayGame.announced`.

**No "who pressed" is stored**, so a manual press names its presser only when
the scores identify one (a side down going in); level, it says the holes alone.
"""
import logging

logger = logging.getLogger(__name__)


def _label(people) -> str:
    field = 'name' if len(people) == 1 else 'short_name'
    return ' & '.join((p.get(field) or p.get('name') or '').split(' ')[0]
                      for p in people)


def _won(bet: dict):
    """+1 side 1, −1 side 2, None while live or halved."""
    dm = bet.get('decided_margin')
    if dm:
        return 1 if dm > 0 else -1
    if bet.get('result') in ('team1', 'team2'):
        return 1 if bet['result'] == 'team1' else -1
    return None


def _result_text(bet: dict) -> str:
    dm, rem = bet.get('decided_margin'), bet.get('decided_remaining')
    if dm and rem:
        return f'{abs(dm)}&{rem}'
    return f'{abs(int(bet.get("margin") or dm or 0))} UP'


def _down_side(summary: dict, press: dict):
    """Which side was down going into this press: +1 side 1, −1 side 2, None
    if level. Read off the hole before the press starts, in PLAY order."""
    holes = summary.get('holes') or []
    start = press.get('start_hole')
    before = None
    for i, h in enumerate(holes):
        if h.get('hole') == start:
            before = holes[i - 1] if i > 0 else None
            break
    else:
        before = holes[-1] if holes else None
    margin = (before or {}).get('front9_margin')
    if margin:
        return 1 if margin < 0 else -1
    return None


def _events(summary: dict) -> list:
    """`(key, priority, build(reader_side) -> alert)` for every announceable
    event the match holds right now."""
    teams = summary.get('teams') or {}
    names = {1: _label(teams.get('team1') or []),
             -1: _label(teams.get('team2') or [])}
    unit = float(summary.get('bet_unit') or 0)
    press_unit = float(summary.get('press_unit') or 0)
    out = []

    bet = summary.get('front9') or {}
    won = _won(bet)
    if won is not None:
        text = _result_text(bet)

        def close(reader, won=won, text=text):
            them = names[-reader]
            if won == reader:
                body = f'You won {text}. +${unit:,.0f}.'
            else:
                body = f'{them} won {text}. −${unit:,.0f}.'
            return {'title': f'Match v {them}', 'body': body}
        out.append(('close', 0, close))

    for p in summary.get('presses') or []:
        start, end = p.get('start_hole'), p.get('end_hole')
        auto = p.get('press_type') == 'auto'
        down = _down_side(summary, p)

        def press(reader, down=down, auto=auto, start=start, end=end):
            them = names[-reader]
            who = None
            if down is not None:
                who = 'You' if down == reader else them
            stake = (f'A new ${press_unit:,.0f} bet' if press_unit
                     else 'A new press')
            title = f'{"Auto press" if auto else "Press"} v {them}'
            if auto:
                went = f'{who} went 2 down' if who else 'Two down'
                lead = f'{went} on {start - 1}. ' if start else ''
                return {'title': title,
                        'body': f'{lead}{stake} from hole {start}.'}
            pressed = f'{who} pressed. ' if who else ''
            holes = (f'holes {start}–{end}' if end and end != start
                     else f'hole {start}')
            return {'title': title, 'body': f'{pressed}{stake} on {holes}.'}
        out.append((f'press:{start}', 1, press))
    return out


def nassau_nine_alerts(round_obj) -> dict:
    """`{player_id: alert}` for the events this posted score produced.

    Called ONCE per posted score, never per recipient — it records what it
    announced, so a per-recipient loop would announce only to the first phone.
    """
    from games.models import NassauGame
    from services.nassau import nassau_summary

    alerts: dict = {}
    for game in (NassauGame.objects
                 .filter(foursome__round=round_obj, game_type='nassau_nine')
                 .select_related('foursome')):
        summary = nassau_summary(game.foursome, 'nassau_nine')
        if not summary:
            continue
        events = _events(summary)
        current = {key for key, *_ in events}
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
        best: dict = {}
        for _key, priority, build in fresh:
            for reader, key in ((1, 'team1'), (-1, 'team2')):
                for p in teams.get(key) or []:
                    pid = p.get('player_id')
                    have = best.get(pid)
                    if have is None or priority < have[0]:
                        best[pid] = (priority, build(reader))
        alerts.update({pid: a for pid, (_, a) in best.items()})
    return alerts
