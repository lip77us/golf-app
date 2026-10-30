"""
services/live_activity_annandale_push.py
----------------------------------------
The Annandale Friday lock-screen pushes
(`handoff-annandale-friday-lock/HANDOFF.md`, *Pushes*).

Three events make a sound, and only for the golfers in that match:

* **an auto press** — `Auto press v Jim & Sam` / `You went 2 down on 6. A new
  $10 bet from hole 7 to the end of the front nine.`
* **a manual press** — the match and the holes, and the presser when the
  scores say who it was;
* **a bet closing out** — a nine or the overall, in one of YOUR matches.

**The third match never pushes.** Teams are fixed and each Nassau settles on
its own, so a match the reader is not in never changes what he settles. That
is the difference from Triple Nassau, where the third match is the other two
men's and settles three ways.

Everything else moves the card silently: a push for something the reader
watched is a phone telling him what he already knows. A press and a closed
bet are different — the arithmetic decides them, not the putt, and a golfer
who holed out does not always know that he just went two down on the nine.

**Fired once.** The events already announced live on
`AnnandaleFridayGame.announced`, written in the same call that reads them —
the card is rebuilt from scratch every request and has no memory of its own.
NULL means no push has been taken yet: the first call records what has
already happened WITHOUT announcing it, so a round already under way when
this ships does not ring six phones with the whole front nine at once.

**No "who pressed" is stored** on a press, so a manual press names its presser
only when the scores identify one (a side down on the nine); level, it names
the match and the holes alone rather than guess.
"""
import logging

logger = logging.getLogger(__name__)

_NINE = {'front': 'front nine', 'back': 'back nine'}
_BET = {'front9': 'Front nine', 'back9': 'Back nine', 'overall': 'Overall'}
_CLOSE_PRIORITY = 0
_PRESS_PRIORITY = 1


def _first(name: str) -> str:
    return (name or '').split(' ')[0].title()


def _team_name(ids, names) -> str:
    return ' & '.join(_first(names.get(i, '')) for i in ids)


def _won(bet: dict):
    """+1 if side 1 has won this bet, −1 side 2, None if it is still live or
    was halved. Closed out (`decided_margin`) counts before the ninth hole
    is in — that is the moment the match is over."""
    dm = bet.get('decided_margin')
    if dm:
        return 1 if dm > 0 else -1
    result = bet.get('result')
    if result in ('team1', 'team2'):
        return 1 if result == 'team1' else -1
    return None


def _result_text(bet: dict) -> str:
    dm, rem = bet.get('decided_margin'), bet.get('decided_remaining')
    if dm and rem:
        return f'{abs(dm)}&{rem}'
    return f'{abs(int(bet.get("margin") or dm or 0))} UP'


def _down_side(summary: dict, press: dict):
    """Which side was down on the nine when this press was called: +1 side 1,
    −1 side 2, None if level. Read off the hole played just before the press
    starts — in PLAY order, so a shotgun round finds the right one."""
    key = f'{press.get("nine")}9_margin'
    holes = summary.get('holes') or []
    start = press.get('start_hole')
    before = None
    for i, h in enumerate(holes):
        if h.get('hole') == start:
            before = holes[i - 1] if i > 0 else None
            break
    else:
        # The press's first hole is not played yet — the usual case, since a
        # press is announced the moment it fires. The hole that fired it is
        # then the last one in the list.
        before = holes[-1] if holes else None
    margin = (before or {}).get(key)
    if margin:
        return 1 if margin < 0 else -1
    return None


def _events(summary: dict) -> list:
    """Every announceable event the round holds right now, as
    `(key, priority, build(reader_side) -> alert)` per match."""
    names = {p.get('player_id'): p.get('name', '')
             for p in (summary.get('players') or [])}
    unit = float(summary.get('bet_unit') or 0)
    press_unit = float(summary.get('press_unit') or 0)
    out = []
    for m in summary.get('matches') or []:
        n = m.get('match')
        s = m.get('summary') or {}
        sides = {1: m.get('side1_ids') or [], -1: m.get('side2_ids') or []}

        for bet in ('front9', 'back9', 'overall'):
            won = _won(s.get(bet) or {})
            if won is None:
                continue
            text = _result_text(s.get(bet) or {})

            # Every loop value is bound as a default — a closure that reads
            # `sides` late sees the LAST match's teams, which named Sam & Tom
            # on a front nine Paul had won against Dave & Ray.
            def close(reader, won=won, text=text, bet=bet, sides=sides):
                them = _team_name(sides[-reader], names)
                if won == reader:
                    body = f'You won {text}. +${unit:,.0f} each.'
                else:
                    body = f'{them} won {text}. −${unit:,.0f} each.'
                return {'title': f'{_BET[bet]} v {them}', 'body': body}
            out.append((f'close:{n}:{bet}', _CLOSE_PRIORITY, n, close))

        for p in s.get('presses') or []:
            nine = p.get('nine')
            start, end = p.get('start_hole'), p.get('end_hole')
            down = _down_side(s, p)
            auto = p.get('press_type') == 'auto'

            def press(reader, down=down, auto=auto, start=start, end=end,
                      nine=nine, sides=sides):
                them = _team_name(sides[-reader], names)
                title = f'{"Auto press" if auto else "Press"} v {them}'
                who = None
                if down is not None:
                    who = 'You' if down == reader else them
                # A zero press stake pays nothing in the engine, so the push
                # does not invent the bet's figure for it.
                stake = (f'A new ${press_unit:,.0f} bet' if press_unit
                         else 'A new press')
                if auto:
                    went = f'{who} went 2 down' if who else 'Two down'
                    played = (start - 1) if start else None
                    lead = f'{went} on {played}. ' if played else ''
                    tail = f'from hole {start} to the end of the {_NINE.get(nine, "nine")}.'
                    return {'title': title, 'body': f'{lead}{stake} {tail}'}
                pressed = f'{who} pressed. ' if who else ''
                holes = (f'holes {start}–{end}' if end and end != start
                         else f'hole {start}')
                return {'title': title, 'body': f'{pressed}{stake} on {holes}.'}
            out.append((f'press:{n}:{nine}:{start}', _PRESS_PRIORITY, n, press))
    return out


def annandale_alerts(round_obj) -> dict:
    """`{player_id: alert}` for the events this posted score produced.

    Called ONCE per posted score, never per recipient — it records what it
    announced, so a second caller in the same request would find nothing new
    and a per-recipient loop would announce only to the first phone.
    """
    from games.models import AnnandaleFridayGame
    from services.annandale_friday import annandale_friday_summary

    alerts: dict = {}
    for game in (AnnandaleFridayGame.objects
                 .filter(foursome__round=round_obj)
                 .select_related('foursome')):
        summary = annandale_friday_summary(game.foursome)
        if not summary:
            continue
        events = _events(summary)
        current = {key for key, *_ in events}
        if game.announced is None:
            # The baseline: what has already happened is not news.
            game.announced = sorted(current)
            game.save(update_fields=['announced'])
            continue
        seen = set(game.announced)
        fresh = [e for e in events if e[0] not in seen]
        if not fresh:
            continue
        game.announced = sorted(seen | current)
        game.save(update_fields=['announced'])

        by_match = {m.get('match'): m for m in summary.get('matches') or []}
        best: dict = {}
        for key, priority, n, build in fresh:
            m = by_match.get(n) or {}
            for reader, ids in ((1, m.get('side1_ids') or []),
                                (-1, m.get('side2_ids') or [])):
                for pid in ids:
                    have = best.get(pid)
                    if have is None or priority < have[0]:
                        best[pid] = (priority, build(reader))
        alerts.update({pid: a for pid, (_, a) in best.items()})
    return alerts
