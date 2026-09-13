"""
services/live_activity_triple_cup.py
------------------------------------
The Triple Cup lock screen — **one composition carrying two games.**

Spec: `~/Downloads/handoff-lock-screens 2/triple-cup/HANDOFF.md`.

One eighteen-hole round cut into thirds: Fourball (1–6), Foursomes (7–12), and
two Singles run together (13–18). Four points. **2½ wins the cup, 2–2 halves
it.**

The same format is two different products depending on who is playing it, and
the card ships in both configurations off one view model:

| | Casual cup | Team cup |
|---|---|---|
| Headline | the CUP SCORE — `0–0`, `1–1`, `3–1` | the WHOLE cup — `6½–4½` |
| Right slot | the match you are in + its segment | `12½ · TO WIN` |
| Strip | four discrete cells | one continuous needle |
| Pushes | none | lead change, cup decided |

Nothing else differs: same panel, same slot order, same type sizes.

## The headline is the cup score, including 0–0

`1–1`, not `2 UP`. Triple Cup exists to produce a cup score; the match in front
of you is a way of earning one point in it, which is a different question and
gets the smaller slot.

So the first six holes headline **`0–0`**. An earlier design pass swapped the
slots for the Fourball to avoid it, and that was wrong: **a headline that means
one thing before the first point and another after is a slot nobody can
learn.** `0–0` over four grey cells is the complete and true state of the cup
on the third tee.

## The strip is the needle, flattened

Sixes cut its pips because a round has no fixed number of matches — one ends
when it is decided, so three bars would be wrong as often as right. **Triple
Cup always has exactly four points, in a fixed order**, so four cells are the
format rather than a guess. That is why this card can carry a structure graphic
where Sixes could not.

## The two Singles are the only simultaneous state

Holes 13–18 have two matches live at once — the composition problem the format
was going to have and does not: **it happens once, for six holes, with two
matches, not four.** Both go on ONE sides line, surnames, yours first always.

A row each measured 163pt, over the ceiling on its own. **The sides line is one
row everywhere in this packet**, and that is a requirement rather than a
preference.
"""
from services.live_activity_registry import (hole_facts, hole_in_play,
                                             surname, thru_line)

KIND = 'triple_cup'

# 2½ of 4 wins it; 2–2 halves it. Derived from the points available rather
# than written down, so a format with a different shape cannot disagree.
def _to_win(points_available) -> float:
    return (points_available or 4) / 2 + 0.5


def _score(v) -> str:
    """`3`, `2½`. Halves are real points here and a `.5` reads as a decimal."""
    whole, half = divmod(round(float(v or 0) * 2), 2)
    return f'{whole}½' if half else f'{whole}'


def _live_match(summary, hole):
    """The match the group is standing in, or None once the round is done."""
    if hole is None:
        return None
    for m in (summary.get('matches') or []):
        if (m.get('start_hole') or 0) <= hole <= (m.get('end_hole') or 0):
            return m
    return None


def _singles_live(summary, hole) -> list:
    """Both singles, when the round is in them. Empty everywhere else."""
    if hole is None:
        return []
    out = [m for m in (summary.get('matches') or [])
           if m.get('segment') == 'singles'
           and (m.get('start_hole') or 0) <= hole <= (m.get('end_hole') or 0)]
    return out if len(out) > 1 else []


def _margin_text(m) -> str:
    """`2 up`, `2 dn`, `all sq` — from team 1's side, flipped for the reader."""
    up = m.get('holes_up_final')
    if up is None:
        return 'all sq'
    if up == 0:
        return 'all sq'
    return f'{abs(up)} up' if up > 0 else f'{abs(up)} dn'


def _cells(summary) -> list:
    """Four cells, left to right in play order — no labels; the state slot
    names which one is live.

    `blue` / `orange` banked, `halved` for a 50/50 hard-stop gradient, and
    `out` for a point nobody has yet.
    """
    out = []
    for m in (summary.get('matches') or []):
        status = m.get('status')
        result = m.get('result')
        if status != 'complete' or result is None:
            out.append('out')
        elif result == 'halved':
            out.append('halved')
        elif result in ('team1', 'T1'):
            out.append('blue')
        elif result in ('team2', 'T2'):
            out.append('orange')
        else:
            out.append('out')
    return out


def _cannot_lose(t1, t2, available) -> bool:
    """The single moment the CUP outranks the hole.

    With one point still out at 2–1, blue cannot lose: the worst case is 2–2
    and a halved cup. That is the one override on the right-hand slot.
    """
    out = (available or 4) - t1 - t2
    lead = abs(t1 - t2)
    return out > 0 and lead >= out


def triple_cup_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The casual configuration. The team cup is a different view model over
    the same composition and is not built yet — see the module note."""
    from services.triple_cup import triple_cup_summary
    from services.live_activity_registry import gross_to_par

    summary = triple_cup_summary(foursome)
    if not summary:
        return {}

    overall = summary.get('overall') or {}
    t1 = float(overall.get('team1_points') or 0)
    t2 = float(overall.get('team2_points') or 0)
    available = overall.get('points_available') or 4

    played = thru or 0
    hole = hole_in_play(foursome, played)
    live = _live_match(summary, hole)

    # Which side the reader is on, so "yours first" and the margin can be
    # written from his side rather than team 1's.
    mine_is_t1 = player_id in set(summary.get('team1_ids') or [])

    # The headline is the CUP, and it wears the leader's colour. Never mint —
    # mint is the app's colour, not a side's.
    if t1 > t2:
        colour = 'blue'
    elif t2 > t1:
        colour = 'orange'
    else:
        colour = 'neutral'

    # The right-hand slot: the live segment and how its point is going, unless
    # the cup can no longer be lost.
    if _cannot_lose(t1, t2, available):
        state = {'word': 'CANNOT LOSE',
                 'to_play': f'{_score(available / 2)}–{_score(available / 2)} '
                            f'HALVES IT'}
    elif live is not None:
        label = (live.get('label') or live.get('segment') or '').upper()
        up = live.get('holes_up_final')
        if up is None or up == 0:
            word = 'ALL SQ'
        else:
            mine_up = up if mine_is_t1 else -up
            word = f'{abs(mine_up)} {"UP" if mine_up > 0 else "DN"}'
        state = {'word': word, 'to_play': f'IN THE {label}'}
    else:
        state = {'word': '', 'to_play': ''}

    # The sides line. One row, everywhere — a second is 18pt and puts any card
    # in this packet over the ceiling on its own.
    singles = _singles_live(summary, hole)
    if singles:
        def one(m):
            t1n = (m.get('team1') or {}).get('players') or []
            t2n = (m.get('team2') or {}).get('players') or []
            a = surname(t1n[0]) if t1n else ''
            b = surname(t2n[0]) if t2n else ''
            mine = player_id in {p.get('player_id')
                                 for p in (m.get('players') or [])}
            who = 'You' if mine else a.title()
            return f'{who} v. {b.title()} · {_margin_text(m)}'
        # **Yours first, always**, and the state slot holds yours.
        ordered = sorted(singles, key=lambda m: 0 if player_id in {
            p.get('player_id') for p in (m.get('players') or [])} else 1)
        text = ' · '.join(one(m) for m in ordered)
    else:
        text = ' v. '.join([summary.get('team1_name') or 'Blue',
                            summary.get('team2_name') or 'Orange'])
    sides = [{'names': text, 'colour': 'dim', 'leading': False}]

    unit = float((summary.get('money') or {}).get('bet_unit') or 0)
    return {
        'kind'  : KIND,
        'header': {'game': 'TRIPLE CUP',
                   'segment': hole_facts(foursome, player_id, hole)},
        'number': {'text': f'{_score(t1)}–{_score(t2)}', 'colour': colour},
        'sides' : sides,
        'state' : state,
        # Four cells are the FORMAT, not a guess — which is why this card can
        # carry a structure graphic where Sixes could not.
        'pips'  : _cells(summary),
        'final' : None,
        'footer': {'context': f'${unit:,.0f} a man' if unit else '',
                   'money': ''},
        'thru'  : thru_line(played, gross_to_par(summary, player_id)),
    }
