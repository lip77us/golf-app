"""
services/live_activity_stroke_play.py
-------------------------------------
The Stroke Play lock screen.

Spec: `~/Downloads/handoff-lock-screens 2/personal/HANDOFF.md` and the design
file beside it. **Where the two disagree, the design file is the truth** — its
prose table says the headline is the reader's gross to par, and that is the
CASUAL state; the flighted states headline the PLACE with the score beside it
("position first, score beside it").

One of three cards with **no sides**, so nothing on it is blue or orange. The
headline is the reader's own figure, in mint.

**It pushes nothing.** One group, everything witnessed.

**The money slot fills exactly once, at the end** — a place payout resolves on
the 18th green. Never a `$0`.

## Level par is the figure, never the word

`E`, not `EVEN` and not `0`. It is the form a golfer carries in his head, and
the one the card is for.

## The header names the mode

`STROKE PLAY · GROSS` or `STROKE PLAY · NET`. The same four figures mean
different games under different modes, and a card that does not say which is a
card two groups can read differently.
"""
from services.live_activity_registry import (gross_to_par, hole_facts,
                                             hole_in_play, strip_column,
                                             thru_line)

KIND = 'stroke_play'

_MODE_LABEL = {'gross': 'GROSS', 'net': 'NET', 'strokes_off': 'STROKES OFF'}


def to_par(v) -> str:
    """`E` / `+6` / `−2`.

    A true minus sign (U+2212), not a hyphen: at 36px beside a `+` the hyphen
    is visibly the wrong length, and this is the card's one big figure.
    """
    if v is None:
        return ''
    if v == 0:
        return 'E'
    return f'+{v}' if v > 0 else f'−{abs(v)}'


def _ordinal(n: int) -> str:
    if n in (11, 12, 13):
        return f'{n}TH'
    return f'{n}{ {1: "ST", 2: "ND", 3: "RD"}.get(n % 10, "TH") }'.replace(' ', '')


def _results(summary):
    """The standings ranked in the mode the round is actually being played in.

    `results` already carries the configured mode; the `modes` block exists so
    a client can re-rank, and re-ranking here would put the card in a different
    game from the leaderboard.
    """
    return summary.get('results') or []


def _row_for(results, player_id):
    return next((r for r in results if r.get('player_id') == player_id), None)


def _state_slot(results, mine):
    """The place, and what it is worth in strokes.

    Leading: `1ST` / `1 CLEAR OF 2ND`. Chasing: `2ND` / `2 STROKES TO 1ST`.
    """
    if mine is None or not results:
        return {'word': '', 'to_play': ''}
    rank = mine.get('rank') or 0
    mine_par = mine.get('net_to_par')
    others = [r.get('net_to_par') for r in results
              if r is not mine and r.get('net_to_par') is not None]
    if mine_par is None or not others:
        return {'word': _ordinal(rank) if rank else '', 'to_play': ''}

    if rank == 1:
        gap = min(others) - mine_par
        return {'word': '1ST',
                'to_play': (f'{gap} CLEAR OF 2ND' if gap > 0 else 'TIED')}
    best = min(r.get('net_to_par') for r in results
               if r.get('net_to_par') is not None)
    gap = mine_par - best
    unit = 'STROKE' if gap == 1 else 'STROKES'
    return {'word': _ordinal(rank), 'to_play': f'{gap} {unit} TO 1ST'}


def _sides(results, mine):
    """Who is ahead, named. Not a side — this card has none — but the one line
    that turns a place into a position: `Sam Reid leads · −5`.

    Leading inverts it and names the chasers instead, because a leader's
    question is who is coming rather than who is in front.
    """
    scored = [r for r in results if r.get('net_to_par') is not None]
    if not scored:
        return []
    if mine is not None and (mine.get('rank') or 0) == 1:
        chasers = [r for r in scored if r is not mine][:2]
        text = ' · '.join(f'{r.get("name", "")} {to_par(r.get("net_to_par"))}'
                          for r in chasers)
    else:
        leader = min(scored, key=lambda r: r.get('net_to_par'))
        text = (f'{leader.get("name", "")} leads · '
                f'{to_par(leader.get("net_to_par"))}')
    # No dot. It marks a SIDE everywhere else in the set and this card has
    # none — an empty colour is how the shared frame is told that.
    return [{'names': text, 'colour': '', 'leading': False}]


def stroke_play_activity_state(round_obj, foursome, *, player_id=None,
                               thru=None) -> dict:
    """The card, right now."""
    from services.low_net_round import low_net_round_summary

    summary = low_net_round_summary(round_obj)
    results = _results(summary)
    if not results:
        return {}

    mine = _row_for(results, player_id)
    mode = summary.get('primary_mode') or summary.get('handicap_mode') or 'net'
    played = thru or 0
    hole = hole_in_play(foursome, played)

    # The reader's own to-par, in the mode the round is played in — not the
    # gross figure from the locked corner. On a net round those differ, and
    # the headline is the one the game is scored on.
    mine_par = (mine or {}).get('net_to_par')

    return {
        'kind'  : KIND,
        'header': {
            'game': f'STROKE PLAY · {_MODE_LABEL.get(mode, mode.upper())}',
            'segment': hole_facts(foursome, player_id, hole),
        },
        'who'   : (mine or {}).get('name', ''),
        'number': {'text': to_par(mine_par), 'colour': 'mint'},
        'sides' : _sides(results, mine),
        'state' : _state_slot(results, mine),
        'pips'  : [],
        'final' : None,
        # The field size is the one thing the footer's left half is for here:
        # a place means nothing without knowing what it is a place in.
        'footer': {'context': f'FIELD {len(results)}', 'money': ''},
        'thru'  : thru_line(played, gross_to_par(
            summary.get('scorecard') or summary, player_id)),
    }


def stroke_play_strip(round_obj, *, player_id=None) -> list:
    """The flight frame — **the alternative, not the default.**

    It buys *whether the gap above is one bad hole or four*, and it only works
    where the reader is mid-table: leading a flight of fourteen, the three
    columns beside him say nothing.

    The qualifier goes UNDER the figure rather than beside the name, because in
    a flight the reader is comparing positions against different amounts of
    golf played and the pair only means something read together.
    """
    from services.low_net_round import low_net_round_summary
    results = _results(low_net_round_summary(round_obj))[:4]
    return [
        strip_column(
            name=r.get('name', ''),
            figure=to_par(r.get('net_to_par')),
            label=_ordinal(r.get('rank') or 0),
            note=(f'thru {r.get("holes_played")}'
                  if r.get('holes_played') else ''),
            is_reader=r.get('player_id') == player_id,
            is_leader=(r.get('rank') or 0) == 1,
        )
        for r in results
    ]
