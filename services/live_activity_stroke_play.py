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

## The place is a place IN something, and on a flighted event that is the flight

Every figure here is measured against a population: the place, the strokes to
first, the golfer named as leading, the field size in the footer. All four read
the round's `results`, which is the whole field — so on an event cut into
flights every one of them was answering the wrong question, and a golfer
leading B flight was shown `9TH` behind a leader he is not playing against.

The card narrows to the reader's own flight (`services.flights.flight_field`)
and names it, because **each flight ranks and pays within itself**. Unflighted
rounds take the same path with an empty label and are byte-for-byte what they
were.

**Note what "flight" means where it appears below.** The packet uses the word
for the four-across strip as well, which is a layout and not this; and the
paragraph above is the packet's own vocabulary, where "the flighted states"
names a treatment this module applies to the SIGN-OFF rather than to a
flighted event. Everything added for Halved's Flights says `flight_field`,
`_field_label` or carries a letter.

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


def _rank_key(row):
    """The tie test for this board: net-to-par alone.

    NOT the sort — `results` arrives sorted on (has played, net-to-par) and
    two golfers level on net-to-par share a rank even though one has played
    more holes. `services.flights.ranked_positions` is where that distinction
    is explained; this is the Low Net half of it.

    `None` is the unplayed row, which sorts last and groups with the other
    unplayed rows — the same thing the leaderboard's own walk does, where they
    all compare as level.
    """
    return row.get('net_to_par')


def _flight(round_obj, results, player_id):
    """`(results, label)` narrowed to the reader's flight. Label '' = whole
    field, which is every casual round and every uncut tournament."""
    from services.flights import flight_field
    return flight_field(round_obj, results, player_id, rank_key=_rank_key)


def _field_label(flight: str, size: int) -> str:
    """`FIELD 14`, or `B FLIGHT 14` — the slot that says what the place is IN.

    The letter leads because golfers say "I'm in B" (`services.flights
    .flight_label`), and the count stays either way: a flight of fourteen and
    a flight of four are not the same afternoon.
    """
    return f'{flight} FLIGHT {size}' if flight else f'FIELD {size}'


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

    # Narrowed BEFORE `mine` is resolved, because every slot below is measured
    # against this list and `_sides` / `_state_slot` compare rows by identity.
    results, flight = _flight(round_obj, results, player_id)
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
        # The field is the one thing the footer's left half is for here: a
        # place means nothing without knowing what it is a place in — which is
        # also why it is the slot that names the flight rather than the
        # header. The header already carries the game and the mode; a third
        # fact there is one line two groups read differently.
        **_footer(round_obj, foursome, player_id, played,
                  _field_label(flight, len(results))),
        'thru'  : thru_line(played, gross_to_par(
            summary.get('scorecard') or summary, player_id)),
    }


def _footer(round_obj, foursome, player_id, played, field) -> dict:
    """The footer, and the Dream Round's one claim on this card.

    **The Dream Round takes the QUIET SLOT while it has news** — the same rule the
    Vegas carry follows. The card does not grow: `FIELD n` moves one place
    right, into the slot beside it, so it stays on screen exactly as the packet
    requires. When there is no news, the footer is byte-for-byte what it was.

    `field` arrives composed (`_field_label`) rather than as a size, so the two
    slots it can land in cannot disagree about whether it names a flight.

    The line is composed server-side (`live_activity_dream_round.footer_line`), and
    the STRUCTURED block rides alongside it so a later Swift build can draw the
    `DREAM ROUND` label at its own weight without the two ever disagreeing about
    which pool is being named.
    """
    plain = {'footer': {'context': field, 'money': ''}}

    tournament = getattr(round_obj, 'tournament', None)
    if tournament is None:
        return plain

    from services.live_activity_dream_round import dream_round_news, footer_line
    from services.hole_plan import play_order

    # The hole JUST POSTED — the last one in the group's own play order that
    # has a score, which off a shotgun is not `played`.
    order = play_order(round_obj, foursome)
    last_hole = order[played - 1] if 0 < played <= len(order) else None

    try:
        block = dream_round_news(tournament, round_obj, player_id, last_hole)
    except Exception:
        # A side game must never take the card down with it.
        return plain
    line = footer_line(block)
    if not line:
        return plain

    return {
        # `label` is the small-caps tag; the LINE is in `context`, composed
        # server-side. An installed build that does not know `label` draws the
        # line untagged rather than dropping it — which is why the tag and the
        # text are never the same string.
        'footer': {'context': line, 'money': field,
                   'label': 'DREAM ROUND'},
        'dream_round': block,
    }


def stroke_play_strip(round_obj, *, player_id=None) -> list:
    """The four-across frame — **the alternative, not the default**, and it has
    no production caller.

    The packet calls this the flight frame, meaning the four columns rather
    than Halved's Flights. It buys *whether the gap above is one bad hole or
    four*, and it only works where the reader is mid-table: leading a field of
    fourteen, the three columns beside him say nothing.

    The qualifier goes UNDER the figure rather than beside the name, because
    the reader is comparing positions against different amounts of golf played
    and the pair only means something read together.

    It takes the same narrowing as the card. A strip showing the top four of a
    whole flighted field would put three golfers beside the reader that he is
    not ranked against — the defect this is the alternative TO, one layout
    over.
    """
    from services.low_net_round import low_net_round_summary
    rows, _flight_label = _flight(
        round_obj, _results(low_net_round_summary(round_obj)), player_id)
    results = rows[:4]
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


def stroke_play_final_state(round_obj, foursome, *, player_id=None) -> dict:
    """Sign-off — **the place becomes the headline.**

    The running card headlines the score because that is what the golfer is
    doing something about. When there is nothing left to do about it, the
    score stops being the question and the PLACE starts being it — which is
    also the only slot on this card that was ever about money.

    So the two swap: `2ND` at 36px, and the figure that produced it moves to
    the state slot beside the mode it was scored in. That is a deliberate
    inversion of the running card, not a drift from it.
    """
    from services.low_net_round import low_net_round_summary
    from services.live_activity_registry import gross_to_par, thru_line

    summary = low_net_round_summary(round_obj)
    results = _results(summary)
    if not results:
        return {}
    results, flight = _flight(round_obj, results, player_id)
    mine = _row_for(results, player_id)
    if mine is None:
        return {}

    mode = summary.get('primary_mode') or summary.get('handicap_mode') or 'net'
    rank = mine.get('rank') or 0
    mine_par = mine.get('net_to_par')
    best = min((r.get('net_to_par') for r in results
                if r.get('net_to_par') is not None), default=None)

    # `2nd of 14, missed 1st by 1`. **Strokes, not places** — the gap is what
    # the golfer will replay in his head, and it is the only part of a placing
    # that says how close it was.
    if rank == 1:
        placed = f'1st of {len(results)}'
    elif best is not None and mine_par is not None:
        gap = mine_par - best
        placed = (f'{_ordinal(rank).lower()} of {len(results)}, '
                  f'missed 1st by {gap}')
    else:
        placed = f'{_ordinal(rank).lower()} of {len(results)}'

    # A place prize settles at the desk, not between two golfers — there is
    # no transfer to name, and inventing one would send somebody looking for a
    # man who does not owe him anything.
    #
    # **It names no amount and no place on purpose.** The payout on the row is
    # the ROUND's own table, which is not flighted — `_rank_standings` pays it
    # over the whole field — so a figure here would be a flight place beside a
    # whole-field prize. What is true either way is that he is owed something.
    if float(mine.get('payout') or 0):
        placed += ' · collect at the desk'

    # The row carries `total_net` and the per-hole detail, not a gross total
    # — the leaderboard has never needed one. Its holes are the ROW's, not the
    # summary's, so this is the one card the shared `gross_total` cannot
    # serve; the key it reads is the same one.
    gross = sum((h.get('gross') or 0) for h in (mine.get('holes') or []))
    return {
        'kind'  : KIND,
        'header': {'game': f'STROKE PLAY · {_MODE_LABEL.get(mode, mode.upper())}',
                   # The locked corner's one exception, and it has to be TRUE:
                   # `FLIGHT COMPLETE` on an uncut round named something the
                   # event does not have, and read as a feature that was
                   # handled.
                   'segment': (f'{flight} FLIGHT COMPLETE' if flight
                               else 'ROUND COMPLETE')},
        'who'   : mine.get('name', ''),
        'closed': True,
        'number': {'text': _ordinal(rank) if rank else '', 'colour': 'mint'},
        'sides' : [{'names': placed, 'colour': '', 'leading': False}],
        'state' : {'word': to_par(mine_par),
                   'to_play': _MODE_LABEL.get(mode, mode.upper())},
        'pips'  : [],
        'final' : None,
        'footer': {'context': (
            f'{flight} flight of {len(results)} settled · dismisses in 5 min'
            if flight else
            f'Field of {len(results)} settled · dismisses in 5 min'),
                   'money': ''},
        # **`GROSS 79`, not `THRU 18 · +5`.** The locked corner is the round
        # behind you, and on a net card that has been the gross all along —
        # at the end the round behind you is all of it, so it says the number
        # rather than the shape.
        'thru'  : (f'GROSS {gross:g}' if gross else thru_line(
            18, gross_to_par(summary.get('scorecard') or summary, player_id))),
    }
