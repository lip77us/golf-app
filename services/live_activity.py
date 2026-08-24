"""
services/live_activity.py
-------------------------
The Sixes lock-screen state — five slots, one shape, every state
(docs/design-review/handoff-sixes-lock/SPEC.md).

This module is a **projection of `sixes_summary`**, nothing more. Sixes remains
the source of truth; if a slot wants a number Sixes does not already compute,
that is a signal the slot is wrong, not that Sixes needs a field.

It lives on the server rather than in Swift because the same five slots have to
be produced twice — once for the ActivityKit content push, once for the initial
state the app hands to `Activity.request` — and a rule implemented in two places
is a rule that will disagree with itself. The widget renders; it does not decide.

**Read-only, and deliberately.** No slot carries an action, because every action
in Sixes is group state that wants the app's confirmation and a mis-tap on a
lock screen is expensive.

The five slots
~~~~~~~~~~~~~~
    header   mark · SIXES [· HIGH-LOW] · SEGMENT n · HOLES a-b
    number   2 UP / ALL SQ / +3 PTS, in the LEADING side's colour
    sides    both pairings, leader bold, trailing at 60%
    state    DORMIE / em dash, plus "n TO PLAY"
    pips     three bars — the shape of the whole round
    footer   round context left, money right
"""

from services.sixes import sixes_summary

# The two sides' colours, fixed for the whole round. Blue is always team1 and
# orange always team2 — teams ROTATE between segments, so anything recomputed
# per segment would swap a golfer's colour at the turn.
BLUE   = 'blue'
ORANGE = 'orange'

# Mint is the app's colour, never a side's: a mint "2 UP" above a blue row and
# an orange row leaves the reader guessing which one is up.
NEUTRAL = 'neutral'


def segment_ordinal(segments, seg) -> int:
    """Which of the three this is, counting from one.

    `sixes_summary` does not emit `segment_number`, and an extra-holes stretch
    is NOT a fourth segment — so extras are skipped in the count rather than
    advancing it.
    """
    n = 0
    for s in segments:
        if s.get('is_extra'):
            if s is seg:
                return n or 1
            continue
        n += 1
        if s is seg:
            return n
    return n or 1


def _seg_label(segments, seg) -> str:
    """`SEGMENT 2 · HOLES 7-12`, or `EXTRA HOLES · 5-6` for a closed-out tail."""
    holes = f"{seg['start_hole']}-{seg['end_hole']}"
    if seg.get('is_extra'):
        return f'EXTRA HOLES · {holes}'
    return f'SEGMENT {segment_ordinal(segments, seg)} · HOLES {holes}'


def _live_segment(segments):
    """The segment the group is on: the first not complete, else the last.

    A finished round holds on its last segment rather than falling off the end —
    the final state replaces the board anyway, and a blank header in between
    would read as a fault.
    """
    for seg in segments:
        if seg.get('status') != 'complete':
            return seg
    return segments[-1] if segments else None


def _number(seg, high_low: bool):
    """The headline, and whose colour it wears.

    Classic counts holes and reads `2 UP`. High-Low scores two points a hole —
    low against low, high against high — so the same phrasing would be a lie and
    it reads `+3 PTS`. **The low/high split does not ship to the lock screen**: a
    running total is the only thing the match is decided on.
    """
    t1 = seg.get('t1_points') or 0
    t2 = seg.get('t2_points') or 0
    diff = t1 - t2

    if diff == 0:
        return {'text': 'ALL SQ', 'colour': NEUTRAL}
    colour = BLUE if diff > 0 else ORANGE
    if high_low:
        return {'text': f'+{abs(diff)} PTS', 'colour': colour}
    return {'text': f'{abs(diff)} UP', 'colour': colour}


def _state_word(seg, holes_left: int):
    """`DORMIE` when it applies, else the em dash.

    Two up with two to play is the one fact that changes how the next hole gets
    played, and it is the word golfers actually say. Everything else gets the
    dash — the slot is the state of the MATCH, never the money.
    """
    lead = abs((seg.get('t1_points') or 0) - (seg.get('t2_points') or 0))
    if holes_left > 0 and lead == holes_left:
        return 'DORMIE'
    return '—'


def _pips(segments):
    """Three bars: the shape of the whole round in one glance.

    Won segments take the winning side's colour, the live one is white at 62%,
    unplayed white at 20%. **Identical in every state** — it is the one element
    that never moves, so the eye learns where to look.

    An extra-holes stretch is NOT a fourth pip. The packet leaves the treatment
    open (split the finished segment's pip, or borrow the live one) and asks
    which; until design rules, extras borrow the live pip, which is the option
    that cannot be wrong about the segment count.
    """
    out = []
    live_taken = False
    for seg in segments:
        # An extra-holes stretch is not a fourth segment, so it takes no pip of
        # its own — it borrows the live one.
        if seg.get('is_extra'):
            continue
        if seg.get('status') == 'complete':
            if seg.get('is_void'):
                out.append('void')
            elif seg.get('winner') == 'Team 1':
                out.append(BLUE)
            elif seg.get('winner') == 'Team 2':
                out.append(ORANGE)
            else:
                out.append('halved')
        elif not live_taken:
            out.append('live')
            live_taken = True
        else:
            out.append('unplayed')
    # Sixes is always three segments; pad rather than render a short row.
    while len(out) < 3:
        out.append('unplayed')
    return out[:3]


def _sides(seg):
    """Both pairings, leader first is NOT the rule — team1 is always first so the
    rows do not swap under the reader when the lead changes. The leader is
    marked instead."""
    t1 = seg.get('team1') or {}
    t2 = seg.get('team2') or {}
    diff = (seg.get('t1_points') or 0) - (seg.get('t2_points') or 0)

    def side(team, colour, leading):
        names = team.get('players_short') or team.get('players') or []
        return {
            'names'  : ' & '.join(names),
            'colour' : colour,
            'leading': leading,
        }

    return [
        side(t1, BLUE,   diff > 0),
        side(t2, ORANGE, diff < 0),
    ]


def _money_line(summary, player_id):
    """`+$5 so far` — the second question all round, in the footer where the
    context makes a label unnecessary.

    This is the ONE personal number on an otherwise neutral board, which is why
    it sits in the quietest slot rather than the loudest.
    """
    for row in ((summary.get('money') or {}).get('by_player') or []):
        if row.get('player_id') == player_id:
            amount = row.get('amount') or 0
            sign = '+' if amount > 0 else ('-' if amount < 0 else '')
            return f'{sign}${abs(amount):,.0f} so far'
    return ''


def sixes_activity_state(foursome, *, player_id=None, thru=None) -> dict:
    """The five slots for this foursome, right now.

    ``player_id`` is whose phone this is going to — it changes ONLY the footer's
    money line. Everything else is identical on all four phones, which is the
    whole design: four golfers read the same string.
    """
    summary = sixes_summary(foursome)
    segments = summary.get('segments') or []
    if not segments:
        return {}

    seg       = _live_segment(segments)
    high_low  = (summary.get('scoring_format') == 'high_low')
    played    = len([h for h in (seg.get('holes') or []) if h.get('winner')])
    holes_left = max(0, (seg.get('num_holes') or 0) - played)

    game = 'SIXES · HIGH-LOW' if high_low else 'SIXES'
    stake = float(foursome.round.bet_unit or 0)

    return {
        'header': {'game': game, 'segment': _seg_label(segments, seg)},
        'number': _number(seg, high_low),
        'sides' : _sides(seg),
        'state' : {
            'word'      : _state_word(seg, holes_left),
            'to_play'   : f'{holes_left} TO PLAY',
        },
        'pips'  : _pips(segments),
        'footer': {
            # Thru lives HERE, not on the sides line: the headline band holds
            # three things and two cannot shrink, so "Sam & Lee · thru 4" breaks
            # after "thru". The hole count is round context, not a side.
            'context': (f'Thru {thru} · ${stake:,.0f} a match'
                        if thru is not None else f'${stake:,.0f} a match'),
            'money'  : _money_line(summary, player_id),
        },
    }


def pairing_push(seg, segments=None) -> dict:
    """The one push per round: fires when a pairing LANDS, not when the draw
    sheet opens and not per hole.

    Copy is **method-neutral** for extra holes — half the time nothing was
    drawn, the group set the teams by hand — so it says "New partners", never
    "drawn".

    The activity does not also flash: it is already showing the answer the push
    announced.
    """
    t1 = ' & '.join((seg.get('team1') or {}).get('players_short') or [])
    t2 = ' & '.join((seg.get('team2') or {}).get('players_short') or [])
    holes = f"{seg['start_hole']}-{seg['end_hole']}"

    if seg.get('is_extra'):
        return {
            'title': 'New partners — extra holes',
            'body' : f'Extra holes {holes}: {t1} v. {t2}',
        }
    n = segment_ordinal(segments or [seg], seg)
    return {
        'title': f'New partners — holes {holes}',
        'body' : f'Pairing {n}: {t1} v. {t2}',
    }
