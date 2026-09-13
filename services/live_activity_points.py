"""
services/live_activity_points.py
--------------------------------
The Points (5-3-1) lock screen.

Spec: `~/Downloads/handoff-lock-screens 2/personal/HANDOFF.md`.

Third of the personal cards — no sides, nothing blue or orange — but it
departs from the other two in three ways, and each is a property of the format
rather than a preference.

## Three rows stay, and a strip would be wrong

Three rows is one more than any other card carries, and it is affordable for
the reason the format is: **Points is three-handed only.** No partner to name,
no side to colour, and the row count can never grow. The nine points are
DIVIDED rather than earned, so a point you took is a point neither of the
others got — a single number cannot describe that state.

## The headline gave way, not the rows

`41 PTS` at 21px rather than 36. The card measured 182pt, and the big number
was the only slot repeating something: **the reader's own total already sits
three lines below at full weight.** That is the opposite call to Survivor,
where the 36px word was protected — the difference is duplication, not
importance.

## The money is live from the first hole

Every other card in the set keeps the money slot empty until something closes.
Here a hole IS the settlement: nine points are awarded, the standing changes,
and the money is a fact before the group reaches the next tee. **It is the one
card in the set where a running money figure is settled money rather than a
forecast.**

## It pushes nothing

One group, three men, everything witnessed.
"""
from services.live_activity_registry import hole_facts, hole_in_play, thru_line

KIND = 'points'

# The configuration screen's names, verbatim. A group that picked a setting
# reads it back unchanged; two vocabularies for one choice is how a golfer ends
# up believing the card is showing a different game. `PAY LEADER ONLY` was
# tried and rejected on that ground, and `PAY` leads the phrase because
# *vs Average* and *Above you* read as fragments alone.
_MODEL = {
    'average': 'PAY VS AVERAGE',
    'first'  : 'PAY JUST LEADER',
    'all'    : 'PAY ABOVE YOU',
}


def _cash(v) -> str:
    if v is None:
        return ''
    sign = '+' if v > 0 else ('−' if v < 0 else '')
    return f'{sign}${abs(v):,.0f}'


def _rows(summary) -> list:
    return summary.get('players') or []


def _last_hole(summary):
    """The most recent hole with a full set of scores — its awards persist."""
    best = None
    for h in (summary.get('holes') or []):
        entries = h.get('entries') or h.get('scores') or []
        if entries and all(e.get('points') is not None for e in entries):
            best = h
    return best


def _awards(summary) -> tuple:
    """`{pid: points won on the last closed hole}`, and the best of them.

    **Mint marks the best award on that hole, never the leader.** On a tied
    hole both `4`s go mint and the `1` goes dim. A leader who scrambled a 3
    while somebody else took the 5 reads dim — which is the column's whole job.
    """
    hole = _last_hole(summary)
    if not hole:
        return {}, None
    out = {}
    for e in (hole.get('entries') or hole.get('scores') or []):
        pid, pts = e.get('player_id'), e.get('points')
        if pid is not None and pts is not None:
            out[pid] = pts
    return out, (max(out.values()) if out else None)


def _fmt_award(v) -> str:
    """**No plus sign.** The card already spends a plus on `+$5` and `+7`; a
    third made the column read as a running total."""
    if v is None:
        return ''
    return f'{v:g}'


def _state_slot(summary, mine, rows):
    """The signed gap — and it follows the payoff model, because the model is
    which game is being played.

    **Behind is negative.** The footer two rows down says `−$2`, and a golfer
    reading a plus above a minus concludes one of them is a bug.
    """
    mode = (summary.get('money') or {}).get('per_point_mode') or 'average'
    if mine is None or not rows:
        return {'word': '', 'to_play': ''}
    pts = mine.get('points') or 0
    best = max((r.get('points') or 0) for r in rows)

    if mode == 'average':
        # Under *Pay vs Average* the lead is irrelevant to what you are owed,
        # so the slot shows the figure that IS the money.
        avg = sum((r.get('points') or 0) for r in rows) / len(rows)
        d = pts - avg
        return {'word': f'{d:+.0f}'.replace('-', '−'),
                'to_play': 'v. average'}

    if pts >= best:
        rest = [r.get('points') or 0 for r in rows if r is not mine]
        return {'word': 'LEADS',
                'to_play': f'BY {pts - max(rest)}' if rest else ''}
    return {'word': f'−{best - pts}', 'to_play': 'TO THE LEAD'}


def points_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The card, right now."""
    from services.points_531 import points_531_summary
    from services.live_activity_registry import gross_to_par

    summary = points_531_summary(foursome)
    rows = _rows(summary)
    if not rows:
        return {}

    mine = next((r for r in rows if r.get('player_id') == player_id), None)
    money = summary.get('money') or {}
    mode = money.get('per_point_mode') or 'average'
    awards, best_award = _awards(summary)

    played = thru or 0
    hole = hole_in_play(foursome, played)
    to_par = gross_to_par(summary, player_id)

    # A WATCHER has no row of his own — Points names all three golfers, so he
    # is the one reader with nothing on the card. He gets the leader's total as
    # the headline and the leader NAMED outright, rather than a gap with no
    # owner.
    leader = max(rows, key=lambda r: r.get('points') or 0)
    headline_row = mine or leader

    out_rows = []
    for r in rows:
        pid = r.get('player_id')
        out_rows.append({
            'label' : r.get('name', ''),
            'text'  : str(r.get('points') or 0),
            # Mint for the reader. On a watcher card NOTHING is bold — that is
            # the tell that none of it is about him.
            'colour': 'mint' if (mine is not None and pid == player_id)
                      else 'dim',
            'note'  : _cash(r.get('money')),
            'award' : _fmt_award(awards.get(pid)),
            'award_best': (best_award is not None
                           and awards.get(pid) == best_award),
        })

    if mine is None:
        state = {'word': leader.get('name', '').split()[-1].upper(),
                 'to_play': f'LEADS BY '
                            f'{(leader.get("points") or 0) - min((r.get("points") or 0) for r in rows)}'}
    else:
        state = _state_slot(summary, mine, rows)

    unit = float(money.get('bet_unit') or 0)
    if mine is None:
        # The footer trades the personal row for THE CALCULATION.
        total = sum((r.get('points') or 0) for r in rows)
        even = total / len(rows) if rows else 0
        context = f'{total:g} is {even:g} even · ${unit:,.0f} a point'
    else:
        context = f'${unit:,.0f} a point'

    return {
        'kind'  : KIND,
        'header': {
            'game': f'POINTS · {_MODEL.get(mode, mode.upper())}',
            'segment': hole_facts(foursome, player_id, hole),
        },
        'who'   : (mine or {}).get('name', '') if mine is not None else '',
        # 21px, not 36 — the size is the client's, but the CHOICE is recorded
        # here: the reader's own total already sits three lines below at full
        # weight, so the headline was the only slot repeating something.
        'number': {'text': f'{headline_row.get("points") or 0} PTS',
                   'colour': 'mint'},
        'rows'  : out_rows,
        'sides' : [],
        'state' : state,
        'pips'  : [],
        'final' : None,
        # Live from the first hole, and still SETTLED money — never a forecast.
        'footer': {'context': context,
                   'money': _cash((mine or {}).get('money')) if mine else ''},
        'thru'  : thru_line(played, to_par),
    }
